import AVFoundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// An image or file attached in the composer (desktop `ComposerAttachment`). Images are sent to the model
// with the prompt; files are copied to the desktop and referenced as `@path`.
struct ComposerAttachment: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        case image
        case file
    }

    let id = UUID()
    let kind: Kind
    let name: String
    // Image: the bytes sent to the model; file: the original bytes.
    let data: Data
    let mimeType: String
    // Preview of an image.
    let thumbnail: UIImage?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

// Attachments of a composer, and how many picks are still being read.
struct ComposerAttachments: Equatable, Sendable {
    var items: [ComposerAttachment] = []
    var processingCount = 0

    // Desktop `composer.imageUnsupportedModel`.
    static var unsupportedImagesMessage: String {
        L10n.Attachments.unsupportedImagesModel
    }

    var isEmpty: Bool {
        items.isEmpty
    }

    var isProcessing: Bool {
        processingCount > 0
    }

    var images: [ComposerAttachment] {
        items.filter { $0.kind == .image }
    }

    var files: [ComposerAttachment] {
        items.filter { $0.kind == .file }
    }

    // Encoded in the background, as several images take a while.
    func promptImages() async -> [PromptImage] {
        let images = images
        return await Task.detached(priority: .userInitiated) {
            images.map { PromptImage(data: $0.data.base64EncodedString(), mimeType: $0.mimeType, name: $0.name) }
        }.value
    }

    var uploads: [(name: String, data: Data)] {
        files.map { ($0.name, $0.data) }
    }

    // Like the desktop composer, files are referenced by their desktop paths as `@path`. The desktop adds the
    // references only to a prompt without text; here they always follow the text so the files are never lost.
    static func promptText(_ text: String, filePaths: [String]) -> String {
        guard !filePaths.isEmpty else { return text }
        let references = filePaths.map { "@\($0)" }.joined(separator: " ")
        return text.isEmpty ? references : "\(text)\n\n\(references)"
    }
}

// Reads picked photos and files like the desktop composer: images within 2000×2000 in a format the desktop
// accepts keep their bytes; larger ones (and other formats, such as HEIC photos) become JPEG at 85% quality
// within 2000×2000.
enum AttachmentReader {
    // Desktop `MAX_IMAGE_INPUT_BYTES`. Files share it: unlike on the desktop, they are read into memory and
    // sent whole as base64 over the socket.
    static let maxBytes = 25 * 1024 * 1024
    private static let maxEdge = 2000
    private static let jpegQuality: CGFloat = 0.85
    // Pixels of the composer preview (120pt at 3x).
    private static let thumbnailEdge = 360

    enum Failure: LocalizedError {
        case imageTooLarge(String)
        case tooLarge(String)
        case unsupportedImage(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .imageTooLarge(let name): L10n.Attachments.imageTooLarge(name)
            case .tooLarge(let name): L10n.Attachments.fileTooLarge(name)
            case .unsupportedImage(let name): L10n.Attachments.unsupportedImage(name)
            case .unreadable(let name): L10n.Attachments.unreadable(name)
            }
        }
    }

    static func image(data: Data, name: String) throws -> ComposerAttachment {
        guard data.count <= maxBytes else {
            throw Failure.imageTooLarge(name)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw Failure.unsupportedImage(name)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else {
            throw Failure.unsupportedImage(name)
        }
        if let mimeType = desktopMimeType(of: data), width <= maxEdge, height <= maxEdge {
            return ComposerAttachment(kind: .image, name: name, data: data, mimeType: mimeType, thumbnail: thumbnail(of: source))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxEdge),
        ]
        guard let resized = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let jpeg = UIImage(cgImage: resized).jpegData(compressionQuality: jpegQuality)
        else {
            throw Failure.unsupportedImage(name)
        }
        return jpegAttachment(jpeg, name: name)
    }

    // A photo taken with the camera, as JPEG within 2000×2000.
    static func image(_ image: UIImage, name: String) throws -> ComposerAttachment {
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard size.width > 0, size.height > 0 else {
            throw Failure.unsupportedImage(name)
        }
        let scale = min(1, CGFloat(maxEdge) / max(size.width, size.height))
        let target = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let jpeg = rendered.jpegData(compressionQuality: jpegQuality) else {
            throw Failure.unsupportedImage(name)
        }
        return jpegAttachment(jpeg, name: name)
    }

    // A file picked in the document picker. Like the desktop's file picker, image files are attached as
    // images unless they cannot be read as one.
    static func file(at url: URL) throws -> ComposerAttachment {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let name = url.lastPathComponent
        let isImage = isImageFileName(name)
        let tooLarge = isImage ? Failure.imageTooLarge(name) : Failure.tooLarge(name)
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes {
            throw tooLarge
        }
        guard let data = try? Data(contentsOf: url) else {
            throw Failure.unreadable(name)
        }
        guard data.count <= maxBytes else {
            throw tooLarge
        }
        if isImage, let attachment = try? image(data: data, name: name) {
            return attachment
        }
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return ComposerAttachment(kind: .file, name: name, data: data, mimeType: mimeType, thumbnail: nil)
    }

    // Desktop `detectImageMimeType`: the formats the desktop accepts, by signature.
    private static func desktopMimeType(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "image/png"
        }
        if bytes.count >= 6, bytes.starts(with: [0x47, 0x49, 0x46, 0x38]), bytes[4] == 0x37 || bytes[4] == 0x39, bytes[5] == 0x61 {
            return "image/gif"
        }
        if bytes.count >= 12, bytes.starts(with: [0x52, 0x49, 0x46, 0x46]), bytes[8...].starts(with: [0x57, 0x45, 0x42, 0x50]) {
            return "image/webp"
        }
        if bytes.starts(with: [0x42, 0x4D]) {
            return "image/bmp"
        }
        return nil
    }

    // Desktop: picked files with these extensions are read as images.
    private static func isImageFileName(_ name: String) -> Bool {
        ["jpg", "jpeg", "png", "gif", "webp", "bmp"].contains((name as NSString).pathExtension.lowercased())
    }

    private static func jpegAttachment(_ jpeg: Data, name: String) -> ComposerAttachment {
        let source = CGImageSourceCreateWithData(jpeg as CFData, nil)
        return ComposerAttachment(kind: .image, name: name, data: jpeg, mimeType: "image/jpeg", thumbnail: source.flatMap(thumbnail(of:)))
    }

    private static func thumbnail(of source: CGImageSource) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailEdge,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }
}

// MARK: - Picker

extension View {
    // Menu of the composer's "+" button (camera, photos, files) and the pickers it opens. Picks are read in the
    // background and appended to `attachments` in the order they were made; failures are shown in an alert.
    func composerAttachmentPicker(isPresented: Binding<Bool>, attachments: Binding<ComposerAttachments>) -> some View {
        modifier(ComposerAttachmentPicker(isPresented: isPresented, attachments: attachments))
    }
}

private enum AttachmentSource: CaseIterable, Identifiable {
    case camera
    case photos
    case files

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .camera: L10n.Attachments.camera
        case .photos: L10n.Attachments.photos
        case .files: L10n.Attachments.files
        }
    }

    var systemImage: String {
        switch self {
        case .camera: "camera"
        case .photos: "photo"
        case .files: "paperclip"
        }
    }
}

private struct ComposerAttachmentPicker: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var attachments: ComposerAttachments
    @State private var showsCamera = false
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    // Picks are read one after another, so attachments keep the order they were picked in.
    @State private var reading: Task<Void, Never>?
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomLeading) {
                ZStack {
                    if isPresented {
                        AttachmentMenuOverlay(onSelect: select) {
                            isPresented = false
                        }
                        .transition(.scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: isPresented)
            }
            .fullScreenCover(isPresented: $showsCamera) {
                CameraPicker { image in
                    showsCamera = false
                    guard let image else { return }
                    read { [Result { try AttachmentReader.image(image, name: "image.jpg") }] }
                }
                .ignoresSafeArea()
            }
            .photosPicker(isPresented: $showsPhotos, selection: $photoItems, selectionBehavior: .ordered, matching: .images)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                read {
                    var results: [Result<ComposerAttachment, Error>] = []
                    for item in items {
                        do {
                            guard let data = try await item.loadTransferable(type: Data.self) else {
                                throw AttachmentReader.Failure.unreadable(L10n.Attachments.photoFallbackName)
                            }
                            results.append(.success(try AttachmentReader.image(data: data, name: "image")))
                        } catch {
                            results.append(.failure(error))
                        }
                    }
                    return results
                }
            }
            .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    read { urls.map { url in Result { try AttachmentReader.file(at: url) } } }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .alert(L10n.Attachments.addErrorTitle, isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button(L10n.Common.ok, role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func select(_ source: AttachmentSource) {
        isPresented = false
        switch source {
        case .camera:
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                errorMessage = L10n.Attachments.cameraUnavailable
                return
            }
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            guard status != .denied, status != .restricted else {
                errorMessage = L10n.Attachments.cameraPermissionDenied
                return
            }
            showsCamera = true
        case .photos:
            showsPhotos = true
        case .files:
            showsFiles = true
        }
    }

    // Reads a pick in the background after the earlier ones, then appends the attachments in order.
    private func read(_ work: @escaping @Sendable () async -> [Result<ComposerAttachment, Error>]) {
        attachments.processingCount += 1
        let previous = reading
        reading = Task {
            await previous?.value
            let results = await Task.detached(priority: .userInitiated) {
                await work()
            }.value
            for result in results {
                switch result {
                case .success(let attachment):
                    attachments.items.append(attachment)
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            attachments.processingCount -= 1
        }
    }
}

// Card over the composer's bottom-leading corner; tapping outside closes it.
private struct AttachmentMenuOverlay: View {
    let onSelect: (AttachmentSource) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(AttachmentSource.allCases) { source in
                    Button {
                        onSelect(source)
                    } label: {
                        HStack(spacing: 17) {
                            Image(systemName: source.systemImage)
                                .font(.system(size: 19, weight: .medium))
                                .frame(width: 46, height: 46)
                                .background(Color(.systemGray6), in: Circle())
                            Text(source.title)
                                .font(.system(size: 20))
                        }
                        .foregroundStyle(Color.primary)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 13)
            .frame(width: 300)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
            .padding(.leading, 15)
            .padding(.bottom, 15)
        }
    }
}

// System camera; reports the taken photo, or nil when cancelled.
private struct CameraPicker: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var onFinish: (UIImage?) -> Void

        init(onFinish: @escaping (UIImage?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}

// MARK: - Composer previews

// Picked images (thumbnails) and files (chips) above the prompt, each with a remove button.
struct ComposerAttachmentStrip: View {
    // Beyond this many files the chips scroll, so the prompt and its buttons stay on screen.
    private static let maxVisibleFiles = 3
    private static let fileRowHeight: CGFloat = 40

    @Binding var attachments: ComposerAttachments

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let images = attachments.images
            if !images.isEmpty || attachments.isProcessing {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(images) { image in
                            ImageAttachmentTile(attachment: image) {
                                remove(image)
                            }
                        }
                        if attachments.isProcessing {
                            ProgressView()
                                .frame(width: ImageAttachmentTile.size, height: ImageAttachmentTile.size)
                                .background(Color(.secondarySystemFill), in: ImageAttachmentTile.shape)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: ImageAttachmentTile.size)
            }
            let files = attachments.files
            if files.count > Self.maxVisibleFiles {
                ScrollView {
                    fileChips(files)
                }
                // Half of the next chip shows that the list scrolls.
                .frame(height: (Self.fileRowHeight + 8) * CGFloat(Self.maxVisibleFiles) + Self.fileRowHeight / 2)
            } else {
                fileChips(files)
            }
        }
    }

    // One chip per line, so long names are truncated to the composer width.
    private func fileChips(_ files: [ComposerAttachment]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(files) { file in
                FileAttachmentChip(attachment: file) {
                    remove(file)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func remove(_ attachment: ComposerAttachment) {
        withAnimation(.snappy) {
            attachments.items.removeAll { $0.id == attachment.id }
        }
    }
}

private struct ImageAttachmentTile: View {
    static let size: CGFloat = 120
    static let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    let attachment: ComposerAttachment
    let onRemove: () -> Void

    var body: some View {
        Color(.secondarySystemFill)
            .overlay {
                if let thumbnail = attachment.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: Self.size, height: Self.size)
            .clipShape(Self.shape)
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.black.opacity(0.6), in: Circle())
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.Attachments.removeImage)
            }
    }
}

private struct FileAttachmentChip: View {
    let attachment: ComposerAttachment
    let onRemove: () -> Void

    var body: some View {
        let style = FileTypeStyle(fileName: attachment.name)
        HStack(spacing: 8) {
            Image(systemName: style.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(style.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(attachment.name)
                .font(.system(size: 15))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color(.systemGray2))
                    .frame(width: 28, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.Attachments.removeNamed(attachment.name))
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .frame(height: 40)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// Icon of a file chip, by file type.
private struct FileTypeStyle {
    let systemImage: String
    let color: Color

    init(fileName: String) {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        func conforms(_ other: UTType) -> Bool {
            type?.conforms(to: other) == true
        }
        if conforms(.spreadsheet) || conforms(.commaSeparatedText) || conforms(.tabSeparatedText) || ["xls", "xlsx", "numbers"].contains(ext) {
            (systemImage, color) = ("tablecells", Color(.systemGreen))
        } else if conforms(.presentation) || ["ppt", "pptx", "key"].contains(ext) {
            (systemImage, color) = ("play.rectangle", Color(.systemOrange))
        } else if conforms(.pdf) {
            (systemImage, color) = ("doc.richtext", Color(.systemRed))
        } else if ["doc", "docx", "pages", "rtf", "odt"].contains(ext) {
            (systemImage, color) = ("doc.text", Color(.systemBlue))
        } else if conforms(.image) {
            (systemImage, color) = ("photo", Color(.systemPurple))
        } else if conforms(.movie) {
            (systemImage, color) = ("film", Color(.systemPink))
        } else if conforms(.audio) {
            (systemImage, color) = ("waveform", Color(.systemPink))
        } else if conforms(.archive) {
            (systemImage, color) = ("doc.zipper", Color(.systemBrown))
        } else if conforms(.sourceCode) || conforms(.script) || conforms(.json) || conforms(.xml) {
            (systemImage, color) = ("chevron.left.forwardslash.chevron.right", Color(.systemIndigo))
        } else if conforms(.text) {
            (systemImage, color) = ("doc.plaintext", Color(.systemGray))
        } else {
            (systemImage, color) = ("doc", Color(.systemGray))
        }
    }
}
