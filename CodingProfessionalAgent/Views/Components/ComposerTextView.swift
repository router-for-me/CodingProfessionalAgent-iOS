import SwiftUI
import UIKit

// Growing text input that shows skill references as inline chips, like the desktop Web composer.
// The SwiftUI side only sees `ComposerDraft` (chips serialized as `$name`).
struct ComposerTextView: UIViewRepresentable {
    static let font = UIFont.systemFont(ofSize: 17)
    static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: UIColor.label,
    ]

    @Binding var draft: ComposerDraft
    @Binding var isFocused: Bool
    var maxLines: Int
    var returnKeyType: UIReturnKeyType = .default
    var textContainerInset: UIEdgeInsets = .zero
    var skillTrigger = SkillTrigger.dollar
    // Called for the return key; returning true consumes it instead of inserting a newline.
    var onReturn: () -> Bool = { false }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ChipTextView {
        let view = ChipTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = Self.font
        view.textColor = .label
        view.tintColor = UIColor(Theme.accent)
        view.textContainerInset = textContainerInset
        view.textContainer.lineFragmentPadding = 0
        view.showsVerticalScrollIndicator = false
        // Pasted content is always plain text.
        view.allowsEditingTextAttributes = false
        view.returnKeyType = returnKeyType
        view.skillTrigger = skillTrigger
        view.typingAttributes = Self.baseAttributes
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.apply(draft, to: view)
        return view
    }

    func updateUIView(_ view: ChipTextView, context: Context) {
        context.coordinator.parent = self
        view.skillTrigger = skillTrigger
        if view.textContainerInset != textContainerInset {
            view.textContainerInset = textContainerInset
        }
        if view.returnKeyType != returnKeyType {
            view.returnKeyType = returnKeyType
            view.reloadInputViews()
        }
        if draft != context.coordinator.lastDraft {
            context.coordinator.apply(draft, to: view)
        }
        view.wantsFocus = isFocused
        if isFocused != view.isFirstResponder {
            let coordinator = context.coordinator
            // Responder changes must not happen during a SwiftUI update.
            DispatchQueue.main.async { [weak view] in
                guard let view, coordinator.parent.isFocused == view.wantsFocus else { return }
                if view.wantsFocus {
                    if view.window != nil, !view.isFirstResponder {
                        view.becomeFirstResponder()
                    }
                } else if view.isFirstResponder {
                    view.resignFirstResponder()
                }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ChipTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let lineHeight = ceil(Self.font.lineHeight)
        let fitting = ceil(uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        let verticalInset = textContainerInset.top + textContainerInset.bottom
        let height = min(max(fitting, lineHeight + verticalInset), lineHeight * CGFloat(maxLines) + verticalInset)
        return CGSize(width: width, height: height)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        private(set) var lastDraft = ComposerDraft()
        private var isApplying = false

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        // Replaces the text view content with an externally changed draft.
        func apply(_ draft: ComposerDraft, to view: ChipTextView) {
            isApplying = true
            defer { isApplying = false }
            if view.markedTextRange != nil {
                view.unmarkText()
            }
            view.attributedText = draft.attributedText
            view.selectedRange = NSRange(location: draft.attributedCaret, length: 0)
            view.typingAttributes = ComposerTextView.baseAttributes
            lastDraft = draft
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplying else { return }
            publish(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplying else { return }
            if textView.markedTextRange == nil {
                // Text typed right after a chip must not inherit the attachment attributes.
                textView.typingAttributes = ComposerTextView.baseAttributes
            }
            publish(textView)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n", textView.markedTextRange == nil, parent.onReturn() {
                return false
            }
            return true
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused {
                parent.isFocused = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused {
                parent.isFocused = false
            }
        }

        private func publish(_ textView: UITextView) {
            let draft = ComposerDraft(attributedText: textView.attributedText, selection: textView.selectedRange)
            guard draft != lastDraft else { return }
            lastDraft = draft
            parent.draft = draft
        }
    }
}

// Text view that copies chips as trigger text (e.g. `#name`) and can take focus as soon as it is on screen.
final class ChipTextView: UITextView {
    var wantsFocus = false
    var skillTrigger = SkillTrigger.dollar

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if wantsFocus, window != nil, !isFirstResponder {
            becomeFirstResponder()
        }
    }

    override func copy(_ sender: Any?) {
        guard let text = serializedSelection else {
            super.copy(sender)
            return
        }
        UIPasteboard.general.string = text
    }

    override func cut(_ sender: Any?) {
        guard let text = serializedSelection else {
            super.cut(sender)
            return
        }
        UIPasteboard.general.string = text
        // Deleting through the text input path keeps undo and delegate callbacks intact.
        deleteBackward()
    }

    private var serializedSelection: String? {
        let range = selectedRange
        guard range.length > 0, NSMaxRange(range) <= attributedText.length else { return nil }
        let selected = attributedText.attributedSubstring(from: range)
        return ComposerDraft(attributedText: selected, selection: NSRange(location: 0, length: 0))
            .plainText(trigger: skillTrigger)
    }
}

// Inline chip for a skill reference: cube icon plus the display name in the desktop's accent blue.
final class SkillChipAttachment: NSTextAttachment {
    let name: String

    @MainActor
    init(name: String) {
        self.name = name
        super.init(data: nil, ofType: nil)
        let font = ComposerTextView.font
        let image = Self.render(displayName: RemoteSkill.displayName(for: name), font: font)
        image.accessibilityLabel = "技能 \(RemoteSkill.displayName(for: name))"
        self.image = image
        // Bottom at the descender so the label baseline matches the surrounding text.
        bounds = CGRect(x: 0, y: font.descender, width: image.size.width, height: image.size.height)
    }

    required init?(coder: NSCoder) {
        name = ""
        super.init(coder: coder)
    }

    private static func render(displayName: String, font: UIFont) -> UIImage {
        let color = UIColor(Theme.skillChip)
        let labelFont = UIFont.systemFont(ofSize: font.pointSize, weight: .medium)
        let label = NSAttributedString(string: displayName, attributes: [.font: labelFont, .foregroundColor: color])
        let labelSize = label.size()
        let icon = UIImage(
            systemName: "cube",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        )?.withTintColor(color, renderingMode: .alwaysOriginal)
        let iconSize = icon?.size ?? .zero
        let gap: CGFloat = 4
        let height = ceil(font.lineHeight)
        let size = CGSize(width: ceil(iconSize.width + gap + labelSize.width + 1), height: height)
        return UIGraphicsImageRenderer(size: size).image { _ in
            // Center the icon on the cap height of the text line.
            let capCenter = font.ascender - font.capHeight / 2
            icon?.draw(in: CGRect(
                x: 0,
                y: capCenter - iconSize.height / 2,
                width: iconSize.width,
                height: iconSize.height
            ))
            label.draw(at: CGPoint(x: iconSize.width + gap, y: font.ascender - labelFont.ascender))
        }
    }
}

// Conversion between the text view content (chips as attachments) and the canonical draft.
extension ComposerDraft {
    init(attributedText: NSAttributedString, selection: NSRange) {
        let string = attributedText.string as NSString
        let target = NSMaxRange(selection)
        var units: [UInt16] = []
        var references: [SkillReference] = []
        var caret: Int?
        attributedText.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedText.length)
        ) { value, range, _ in
            if let chip = value as? SkillChipAttachment {
                for offset in 0..<range.length {
                    if caret == nil, range.location + offset == target {
                        caret = units.count
                    }
                    references.append(SkillReference(start: units.count, name: chip.name))
                    units += Array("$\(chip.name)".utf16)
                }
            } else {
                if caret == nil, target >= range.location, target < NSMaxRange(range) {
                    caret = units.count + target - range.location
                }
                var buffer = [UInt16](repeating: 0, count: range.length)
                string.getCharacters(&buffer, range: range)
                units += buffer
            }
        }
        self.init(
            text: String(decoding: units, as: UTF16.self),
            references: references,
            cursor: caret ?? units.count
        )
    }

    @MainActor
    var attributedText: NSAttributedString {
        let result = NSMutableAttributedString()
        for part in parts {
            switch part {
            case .text(let text):
                result.append(NSAttributedString(string: text, attributes: ComposerTextView.baseAttributes))
            case .skill(let name):
                let chip = NSMutableAttributedString(attachment: SkillChipAttachment(name: name))
                chip.addAttributes(ComposerTextView.baseAttributes, range: NSRange(location: 0, length: chip.length))
                result.append(chip)
            }
        }
        return result
    }

    // Caret position in the text view, where every chip is a single character.
    var attributedCaret: Int {
        let caret = self.caret
        var removed = 0
        for reference in validReferences {
            if reference.end <= caret {
                removed += reference.length - 1
            } else if reference.start < caret {
                // Inside a token: place the caret after the chip.
                return reference.start - removed + 1
            } else {
                break
            }
        }
        return caret - removed
    }
}
