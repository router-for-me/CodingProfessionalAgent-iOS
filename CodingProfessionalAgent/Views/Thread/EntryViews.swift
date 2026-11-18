import ImageIO
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Separator for a compacted context.
struct CompactionDivider: View {
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = locale
        HStack(spacing: 10) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
            Text(L10n.Entry.compacted)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }
}

// Sent prompt with its images above the text, like the desktop; a long press offers copy, edit (when
// `onEdit` is given) and share.
struct UserBubble: View {
    @Environment(\.locale) private var locale
    let entry: ConversationEntry
    let knownSkills: [RemoteSkill]
    var skillTrigger = SkillTrigger.dollar
    var onEdit: (() -> Void)?

    var body: some View {
        let _ = locale
        let images = entry.sentImages
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 4) {
                if !images.isEmpty {
                    SentImageGallery(images: images)
                        .opacity(entry.pendingStatus == nil ? 1 : 0.8)
                        .contextMenu {
                            menuItems
                        }
                }
                // An image-only prompt shows just its images.
                if !entry.text.isEmpty || images.isEmpty {
                    messageText
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.userBubbleText)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 11)
                        .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .contextMenu {
                            menuItems
                        }
                }

                if let pending = entry.pendingStatus {
                    Text((FollowUpStatus(rawValue: pending) ?? .pending).title)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // Chips are copied as trigger text (e.g. `$name`), like the desktop's copy action.
    @ViewBuilder
    private var menuItems: some View {
        let text = ComposerDraft.plainText(of: entry.promptParts(knownSkills: knownSkills), trigger: skillTrigger)
        if !text.isEmpty {
            Button(L10n.Entry.copy, systemImage: "doc.on.doc") {
                UIPasteboard.general.string = text
            }
        }
        if let onEdit {
            Button(L10n.Common.edit, systemImage: "pencil", action: onEdit)
        }
        if !text.isEmpty {
            ShareLink(item: text) {
                Label(L10n.Entry.shareEllipsis, systemImage: "square.and.arrow.up")
            }
        }
    }

    // Prompt text with `$name` skill tokens shown as inline chips, like the desktop message bubble.
    private var messageText: Text {
        entry.promptParts(knownSkills: knownSkills).reduce(Text(verbatim: "")) { result, part in
            switch part {
            case .text(let value):
                Text("\(result)\(Text(verbatim: value))")
            case .skill(let name):
                Text("\(result)\(Self.chip(name))")
            }
        }
    }

    // Same look as the composer chip: cube icon plus the display name in the skill accent color.
    private static func chip(_ name: String) -> Text {
        let icon = Text(Image(systemName: "cube"))
            .font(.system(size: 13, weight: .medium))
            .baselineOffset(1)
            .accessibilityLabel(L10n.Entry.skill)
        // No-break spaces keep the chip on one line.
        let label = RemoteSkill.displayName(for: name).replacingOccurrences(of: " ", with: "\u{00A0}")
        return Text("\(icon)\u{00A0}\(Text(verbatim: label).fontWeight(.medium))")
            .foregroundStyle(Theme.skillChip)
    }
}

// Replaces a sent prompt's bubble while it is edited, like the desktop: skills can be added with the
// trigger menu, return inserts a newline, and send reruns the conversation from this prompt.
struct UserMessageEditor: View {
    @Environment(\.locale) private var locale
    @Binding var draft: ComposerDraft
    let skills: [RemoteSkill]
    let skillTrigger: SkillTrigger
    let isSubmitting: Bool
    // False while the edit cannot be sent, e.g. during a run or while disconnected.
    let canSubmit: Bool
    let onCancel: () -> Void
    let onSubmit: () -> Void
    @State private var isFocused = true

    var body: some View {
        let _ = locale
        let menuItems = isFocused
            ? ComposerMenu.items(for: draft, commands: [], skills: skills, trigger: skillTrigger)
            : []
        VStack(alignment: .trailing, spacing: 12) {
            ComposerTextView(draft: $draft, isFocused: $isFocused, maxLines: 8, skillTrigger: skillTrigger) {
                guard let first = menuItems.first else { return false }
                select(first)
                return true
            }
            .frame(minHeight: 60, alignment: .top)
            .allowsHitTesting(!isSubmitting)
            .accessibilityLabel(L10n.Entry.editMessageAccessibility)

            HStack(spacing: 8) {
                Button(L10n.Common.cancel, action: onCancel)
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                    .disabled(isSubmitting)
                Button(action: onSubmit) {
                    Text(L10n.Composer.send)
                        .opacity(isSubmitting ? 0 : 1)
                        .overlay {
                            if isSubmitting {
                                ProgressView()
                            }
                        }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(!canSubmit || draft.isBlank || isSubmitting)
            }
            .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, 15)
        .padding(.top, 13)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color(.separator), lineWidth: 0.5)
        }
        .composerSuggestionMenu(menuItems, onSelect: select)
        .onAppear {
            // The list may keep this view's state from an earlier edit, when focus was given up.
            isFocused = true
        }
    }

    private func select(_ item: ComposerMenuItem) {
        ComposerMenu.select(item, draft: $draft, isFocused: $isFocused, trigger: skillTrigger)
    }
}

extension ConversationEntry {
    // Text runs and skill chips of a user prompt, like the desktop message bubble. References index
    // the first text block, which is also the start of `text`; older prompts are parsed for skills.
    func promptParts(knownSkills: [RemoteSkill]) -> [ComposerDraft.Part] {
        if let skillReferences {
            return ComposerDraft(text: text, references: skillReferences).parts
        }
        return ComposerDraft.legacyParts(of: text, knownSkills: knownSkills)
    }

    // Images of a user prompt (desktop `buildUserEntry` image blocks), in prompt order.
    var sentImages: [SentImage] {
        var images: [SentImage] = []
        for block in content {
            guard case .image(let mimeType, let data) = block, !data.isEmpty else { continue }
            // The image position, unlike the block position, stays the same when an edit adds text first.
            images.append(SentImage(id: "\(id)#\(images.count)#\(data.utf8.count)", mimeType: mimeType, data: data))
        }
        return images
    }
}

// An image sent with a prompt, as base64 data.
struct SentImage: Identifiable, Sendable {
    // Entry id, image position and data size, which key the cached thumbnail.
    let id: String
    let mimeType: String
    let data: String
}

// Thumbnails of a prompt's images: one image as a large tile, several in rows of two. Tiles have fixed
// sizes, so loading thumbnails never moves the conversation. Tapping a tile previews the images full screen.
struct SentImageGallery: View {
    @Environment(\.locale) private var locale
    let images: [SentImage]
    @State private var previewItems: [URL] = []
    @State private var previewItem: URL?
    // Folder of the files shown in Quick Look, removed when the preview closes.
    @State private var previewDirectory: URL?
    // Writing the files of a tap; cancelled when the gallery goes away.
    @State private var preparation: Task<Void, Never>?

    var body: some View {
        let _ = locale
        let side: CGFloat = images.count == 1 ? 220 : 110
        let rows = stride(from: 0, to: images.count, by: 2).map { Array(images[$0 ..< min($0 + 2, images.count)]) }
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(rows, id: \.first?.id) { row in
                HStack(spacing: 6) {
                    ForEach(row) { image in
                        Button {
                            preview(image)
                        } label: {
                            SentImageTile(image: image, side: side)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(images.count == 1 ? L10n.Entry.image : L10n.Entry.imageNumbered((images.firstIndex { $0.id == image.id } ?? 0) + 1))
                        .accessibilityHint(L10n.Entry.viewFullImage)
                    }
                }
            }
        }
        .quickLookPreview($previewItem, in: previewItems)
        .onChange(of: previewItem) { _, item in
            if item == nil {
                closePreview()
            }
        }
        .onDisappear {
            preparation?.cancel()
            preparation = nil
            if previewItem == nil {
                closePreview()
            }
        }
    }

    // Quick Look shows files, so the images are written to temporary files first.
    private func preview(_ image: SentImage) {
        let images = images
        let request = UUID()
        SentImagePreviewFiles.latestRequest = request
        preparation?.cancel()
        preparation = Task {
            let prepared = await Task.detached(priority: .userInitiated) {
                SentImagePreviewFiles.write(images, request: request)
            }.value
            // Only the latest tap in any prompt opens a preview, and only while this gallery is shown.
            guard !Task.isCancelled, SentImagePreviewFiles.latestRequest == request, previewItem == nil,
                  let selected = prepared.files.first(where: { $0.id == image.id })
            else {
                SentImagePreviewFiles.remove(prepared.directory)
                return
            }
            SentImagePreviewFiles.remove(previewDirectory)
            previewDirectory = prepared.directory
            previewItems = prepared.files.map(\.url)
            previewItem = selected.url
        }
    }

    private func closePreview() {
        SentImagePreviewFiles.remove(previewDirectory)
        previewDirectory = nil
        previewItems = []
    }
}

private struct SentImageTile: View {
    static let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    let image: SentImage
    let side: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: UIImage?
    @State private var isUnreadable = false

    var body: some View {
        let pixelSize = Int((side * displayScale).rounded(.up))
        Color(.secondarySystemFill)
            .overlay {
                if let shown = thumbnail ?? SentImageThumbnails.cached(image, pixelSize: pixelSize) {
                    Image(uiImage: shown)
                        .resizable()
                        .scaledToFill()
                } else if isUnreadable {
                    Image(systemName: "photo")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: side, height: side)
            .clipShape(Self.shape)
            .contentShape(Self.shape)
            .task(id: image.id) {
                thumbnail = await SentImageThumbnails.load(image, pixelSize: pixelSize)
                isUnreadable = thumbnail == nil
            }
    }
}

// Downsampled thumbnails, decoded in the background and kept while memory allows.
@MainActor
private enum SentImageThumbnails {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        return cache
    }()

    static func cached(_ image: SentImage, pixelSize: Int) -> UIImage? {
        cache.object(forKey: key(image, pixelSize: pixelSize))
    }

    static func load(_ image: SentImage, pixelSize: Int) async -> UIImage? {
        let key = key(image, pixelSize: pixelSize)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let data = image.data
        let thumbnail = await Task.detached(priority: .userInitiated) {
            decode(data, pixelSize: pixelSize)
        }.value
        if let thumbnail {
            cache.setObject(thumbnail, forKey: key)
        }
        return thumbnail
    }

    private static func key(_ image: SentImage, pixelSize: Int) -> NSString {
        "\(image.id)@\(pixelSize)" as NSString
    }

    private nonisolated static func decode(_ base64: String, pixelSize: Int) -> UIImage? {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }
}

// Temporary files of the images shown in Quick Look, in a folder of their own for each preview.
private enum SentImagePreviewFiles {
    @MainActor static var latestRequest: UUID?

    // Files left by a preview the app was quit in stay in the temporary folder, which the system purges.
    nonisolated static func write(_ images: [SentImage], request: UUID) -> (directory: URL, files: [(id: String, url: URL)]) {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("SentImagePreview", isDirectory: true)
            .appendingPathComponent(request.uuidString, isDirectory: true)
        guard (try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return (directory, [])
        }
        let files: [(id: String, url: URL)] = images.enumerated().compactMap { index, image in
            guard let data = Data(base64Encoded: image.data, options: .ignoreUnknownCharacters) else { return nil }
            let fileExtension = UTType(mimeType: image.mimeType)?.preferredFilenameExtension ?? "png"
            let url = directory.appendingPathComponent("\(L10n.Entry.imageNumbered(index + 1)).\(fileExtension)")
            guard (try? data.write(to: url)) != nil else { return nil }
            return (image.id, url)
        }
        return (directory, files)
    }

    nonisolated static func remove(_ directory: URL?) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

// Copy / fork actions with the message timestamp, like the desktop's assistant message actions.
struct MessageActions: View {
    @Environment(\.locale) private var locale
    let text: String
    let createdAt: Double
    var onFork: (() -> Void)? = nil

    private static let zhFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private static let enFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter
    }()

    private var activeFormatter: DateFormatter {
        L10n.currentLanguage == .simplifiedChinese ? Self.zhFormatter : Self.enFormatter
    }

    var body: some View {
        let _ = locale
        HStack(spacing: 10) {
            actionButton("square.on.square") {
                UIPasteboard.general.string = text
            }
            if let onFork {
                actionButton("arrow.triangle.branch", rotation: 90, action: onFork)
            }
            if createdAt > 0 {
                Text(activeFormatter.string(from: Date(timeIntervalSince1970: createdAt / 1000)))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
        }
    }

    private func actionButton(_ systemImage: String, rotation: Double = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .rotationEffect(.degrees(rotation))
                .foregroundStyle(.primary.opacity(0.7))
                .frame(width: 17, height: 24)
        }
        .buttonStyle(.plain)
    }
}
