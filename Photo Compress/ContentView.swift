import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

@Observable
class variablesManager {
    var selectedItems: [PhotosPickerItem] = []
    var image: [Image] = []
    var selectedIndices: Set<Int> = []
    var navigationPath = NavigationPath()
    var isProcessing = false
    var isLoselessOn = true
    var isOriginalPhotosOn = true
    var isMetadataOn = true
    var quality = 1.0
    var totalSavedBytes: Int64 = 0
    var formattedSavings: String {
        ByteCountFormatter.string(fromByteCount: totalSavedBytes, countStyle: .file)
    }
    func resourceSize(for asset: PHAsset) async -> Int64 {
        await withCheckedContinuation { continuation in
            let resources = PHAssetResource.assetResources(for: asset)
            if resources.isEmpty {
                continuation.resume(returning: 0)
                return
            }
            let manager = PHAssetResourceManager.default()
            var total: Int64 = 0
            var remaining = resources.count
            for res in resources {
                var bytes: Int64 = 0
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                manager.requestData(for: res, options: options) { data in
                    bytes += Int64(data.count)
                } completionHandler: { _ in
                    total += bytes
                    remaining -= 1
                    if remaining == 0 {
                        continuation.resume(returning: total)
                    }
                }
            }
        }
    }
    func saveToPhotosReturningIdentifier(data: Data, originalDate: Date?) async -> String? {
        await withCheckedContinuation { continuation in
            guard let image = UIImage(data: data) else {
                continuation.resume(returning: nil)
                return
            }
            var placeholder: PHObjectPlaceholder?
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetChangeRequest.creationRequestForAsset(from: image)
                if let date = originalDate {
                    request.creationDate = date
                }
                placeholder = request.placeholderForCreatedAsset
            }, completionHandler: { success, _ in
                continuation.resume(returning: success ? placeholder?.localIdentifier : nil)
            })
        }
    }
    func processImages() async {
        await MainActor.run {
            self.isProcessing = true
            self.totalSavedBytes = 0
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else {
            await MainActor.run { self.isProcessing = false }
            return
        }
        var assetsToDelete: [PHAsset] = []
        for (index, item) in selectedItems.enumerated() {
            guard selectedIndices.contains(index) else { continue }
            var captureDate: Date? = nil
            var originalAsset: PHAsset?
            if let identifier = item.itemIdentifier {
                let assetResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
                if let asset = assetResult.firstObject {
                    originalAsset = asset
                    captureDate = asset.creationDate
                    if !isOriginalPhotosOn { assetsToDelete.append(asset) }
                }
            }
            guard let asset = originalAsset else { continue }
            let originalBytes = await resourceSize(for: asset)
            guard let rawData = try? await item.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: rawData) else { continue }
            var originalMetadata: [AnyHashable: Any]? = nil
            if let source = CGImageSourceCreateWithData(rawData as CFData, nil) {
                originalMetadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [AnyHashable: Any]
            }
            let compressionQuality = isLoselessOn ? 1.0 : quality
            guard let finalData = getHEICData(for: uiImage, metadata: originalMetadata, quality: compressionQuality) else { continue }
            guard let newIdentifier = await saveToPhotosReturningIdentifier(data: finalData, originalDate: captureDate) else { continue }
            var newAssetBytes: Int64 = 0
            let newFetch = PHAsset.fetchAssets(withLocalIdentifiers: [newIdentifier], options: nil)
            if let newAsset = newFetch.firstObject {
                newAssetBytes = await resourceSize(for: newAsset)
            }
            let encodingSavings = max(0, originalBytes - newAssetBytes)
            await MainActor.run {
                self.totalSavedBytes += encodingSavings
            }
        }
        if !isOriginalPhotosOn && !assetsToDelete.isEmpty {
            await withCheckedContinuation { continuation in
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.deleteAssets(assetsToDelete as NSArray)
                }, completionHandler: { _, _ in
                    continuation.resume()
                })
            }
        }
        await MainActor.run {
            self.isProcessing = false
            self.navigationPath.append("CompleteView")
        }
    }
    func getHEICData(for image: UIImage, metadata: [AnyHashable: Any]?, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let cgImage = image.cgImage,
              let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
            return nil
        }
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        if isMetadataOn, let metadata = metadata {
            for (key, value) in metadata {
                if let keyString = key as? String {
                    properties[keyString as CFString] = value
                }
            }
        } else {
            properties[kCGImagePropertyExifDictionary] = [:] as CFDictionary
            properties[kCGImagePropertyIPTCDictionary] = [:] as CFDictionary
            properties[kCGImagePropertyTIFFDictionary] = [:] as CFDictionary
            properties[kCGImagePropertyGPSDictionary] = [:] as CFDictionary
            properties[kCGImagePropertyJFIFDictionary] = [:] as CFDictionary
            properties[kCGImagePropertyPNGDictionary] = [:] as CFDictionary
            properties[kCGImagePropertyRawDictionary] = [:] as CFDictionary
            properties[kCGImagePropertyMakerAppleDictionary] = [:] as CFDictionary
            properties[kCGImageDestinationEmbedThumbnail] = false
            properties[kCGImageDestinationMetadata] = kCFNull
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? (data as Data) : nil
    }
    func deleteOriginals(assets: [PHAsset]) {
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }
}

struct ContentView: View {
    @State private var variables = variablesManager()
    var body: some View {
        NavigationStack(path: $variables.navigationPath) {
            VStack {
                NavigationLink(value: "SelectView") {
                    Text("Compress Photos")
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .font(.system(size: 24))
                        .frame(height: 100)
                        .background(Color(red: 95 / 255, green: 108 / 255, blue: 134 / 255))
                        .cornerRadius(20)
                }
                Spacer()
            }
            .navigationTitle("Geschenk")
            .padding()
            .navigationDestination(for: String.self) { value in
                switch value {
                case "SelectView":
                    SelectView(variables: variables)
                case "CompressView":
                    CompressView(variables: variables)
                case "CompleteView":
                    CompleteView(variables: variables)
                default:
                    EmptyView()
                }
            }
        }
    }
}

struct TransferableImage: Transferable {
    let image: Image
    
    enum TransferError: Error {
        case importFailed
    }
    
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            guard let uiImage = UIImage(data: data) else {
                throw TransferError.importFailed
            }
            let image = Image(uiImage: uiImage)
            return TransferableImage(image: image)
        }
    }
}

struct SelectView: View {
    @Bindable var variables: variablesManager
    var body: some View {
        let columns = [
            GridItem(.flexible(), spacing: 2),
            GridItem(.flexible(), spacing: 2),
            GridItem(.flexible(), spacing: 2)
        ]
        let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let screenWidth = windowScene?.screen.bounds.width ?? 393
        let itemSize = (screenWidth - 10) / 3
        VStack {
            if variables.selectedItems.isEmpty {
                ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle")
            } else {
                HStack {
                    Spacer()
                    if variables.selectedIndices.isEmpty {
                        Button{
                            variables.selectedIndices = Set(0..<variables.image.count)
                        } label: {
                            Text("Select All")
                                .foregroundColor(.primary)
                                .frame(width: 100, height: 50)
                                .glassEffect()
                        }
                        .padding(.horizontal)
                    } else {
                        Button{
                            variables.selectedIndices.removeAll()
                        } label: {
                            Text("Cancel")
                                .foregroundColor(.primary)
                                .frame(width: 80, height: 50)
                                .glassEffect()
                        }
                        .padding(.horizontal)
                    }
                }
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(Array(variables.image.enumerated()), id: \.offset) { i, img in
                            ZStack(alignment: .bottomTrailing) {
                                img
                                    .resizable()
                                    .scaledToFill()
                                    .frame(minWidth: 0, maxWidth: .infinity)
                                    .frame(height: (itemSize))
                                    .clipped()
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if variables.selectedIndices.contains(i) {
                                            variables.selectedIndices.remove(i)
                                        } else {
                                            variables.selectedIndices.insert(i)
                                        }
                                    }
                                if variables.selectedIndices.contains(i) {
                                    Color.white.opacity(0.3)
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 24))
                                        .foregroundColor(.blue)
                                        .background(Circle().fill(.white))
                                        .padding(6)
                                }
                            }
                            .onTapGesture {
                                if variables.selectedIndices.contains(i) {
                                    variables.selectedIndices.remove(i)
                                } else {
                                    variables.selectedIndices.insert(i)
                                }
                            }
                        }
                    }
                }
                if !variables.selectedIndices.isEmpty {
                    NavigationLink(value: "CompressView") {
                        Text("Continue")
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color(red: 95 / 255, green: 108 / 255, blue: 134 / 255))
                            .cornerRadius(20)
                            .padding(.vertical)
                    }
                    .padding([.horizontal, .bottom])
                }
            }
        }
        .navigationTitle(variables.selectedIndices.isEmpty ? "Select Photos" : "\(variables.selectedIndices.count) Photos Selected")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                PhotosPicker(selection: $variables.selectedItems, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: "plus")
                    }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: variables.selectedItems) {
            Task {
                var loadedImages: [Image] = []
                for item in variables.selectedItems {
                    if let loaded = try? await item.loadTransferable(type: TransferableImage.self) {
                        loadedImages.append(loaded.image)
                    }
                }
                await MainActor.run {
                    variables.selectedIndices.removeAll()
                    variables.image = loadedImages
                }
            }
        }
    }
}

struct CompressView: View {
    @Bindable var variables: variablesManager
    let rows = [
        GridItem(.fixed(200))
    ]
    var body: some View {
        ZStack {
            VStack {
                HStack {
                    Text("\(variables.selectedIndices.count) Photos Selected")
                        .fontWeight(.bold)
                        .font(.system(size: 32))
                        .padding([.top, .leading])
                    Spacer()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: rows, spacing: 10) {
                        ForEach(Array(variables.selectedIndices).sorted(), id: \.self) { i in
                            if i < variables.image.count {
                                variables.image[i]
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 200, height: 200)
                                    .clipped()
                                    .cornerRadius(15)
                            }
                        }
                    }
                    .padding([.top, .horizontal])
                }
                .frame(height: 200)
                List {
                    Section {
                        Toggle("Loseless Quality", isOn: $variables.isLoselessOn)
                        Toggle("Keep Original Photos", isOn: $variables.isOriginalPhotosOn)
                        Toggle("Keep Metadata", isOn: $variables.isMetadataOn)
                    }
                    if !variables.isLoselessOn {
                        Section(header: Text("Compress Quality")) {
                            HStack {
                                Slider(
                                    value: $variables.quality,
                                    in: 0...1,
                                )
                                Text(variables.quality, format: .percent.precision(.fractionLength(0)))
                                    .padding(.leading)
                            }
                        }
                    }
                    
                }
                .scrollDisabled(true)
                .scrollContentBackground(.hidden)
                Spacer()
                Button (action: {
                    Task {
                        await variables.processImages()
                    }}) {
                    Text("Continue")
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color(red: 95 / 255, green: 108 / 255, blue: 134 / 255))
                        .cornerRadius(20)
                        .padding(.vertical)
                    }
                    .padding([.horizontal, .bottom])
            }
            .navigationTitle("Compress Settings")
            .disabled(variables.isProcessing)
            .blur(radius: variables.isProcessing ? 3 : 0)
            if variables.isProcessing {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(2)
                        .tint(.white)
                    Text("Compressing...")
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .padding(.top, 30)
                .padding(.bottom, 20)
                .padding(.horizontal)
                .background(.ultraThinMaterial)
                .cornerRadius(20)
            }
        }
    }
}

struct CompleteView: View {
    @Bindable var variables: variablesManager
    var body: some View {
        VStack {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)
            Text("Storage Saved")
                .font(.system(size: 36, weight: .bold))
                .padding(.vertical, 5)
            Text(variables.formattedSavings)
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundColor(.green)
            Spacer()
            Button(action: {
                variables.navigationPath = NavigationPath()
            }) {
                Text("Done")
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color(red: 95 / 255, green: 108 / 255, blue: 134 / 255))
                    .cornerRadius(20)
                    .padding(.vertical)
            }
            .padding([.horizontal, .bottom])
        }
        .navigationBarBackButtonHidden(true)
    }
}

#Preview {
    ContentView()
}
