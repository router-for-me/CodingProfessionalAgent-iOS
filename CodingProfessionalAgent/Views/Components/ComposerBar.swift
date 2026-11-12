import SwiftUI

// Glass composer used at the bottom of the home and thread screens; return sends.
// Typing "/" or the skill trigger opens the command or skill menu when `commands` or `skills` are given.
struct ComposerBar: View {
    @Binding var draft: ComposerDraft
    let placeholder: String
    var isRunning = false
    var canResume = false
    var collapsesKeyboardOnSubmit = true
    var commands: [SlashCommand] = []
    var skills: [RemoteSkill] = []
    var skillTrigger = SkillTrigger.dollar
    var onAttach: () -> Void = {}
    var onSubmit: () -> Void = {}
    var onStop: () -> Void = {}
    var onResume: () -> Void = {}
    @State private var isFocused = false

    var body: some View {
        let menuItems = isFocused
            ? ComposerMenu.items(for: draft, commands: commands, skills: skills, trigger: skillTrigger)
            : []
        HStack(alignment: .bottom, spacing: 0) {
            ComposerIconButton(systemImage: "plus", action: onAttach)
            ComposerTextView(
                draft: $draft,
                isFocused: $isFocused,
                maxLines: 5,
                returnKeyType: .send,
                skillTrigger: skillTrigger
            ) {
                // Like the desktop, return picks the highlighted suggestion while a menu is open.
                if let first = menuItems.first {
                    select(first)
                } else {
                    submit()
                }
                return true
            }
            .composerPlaceholder(placeholder, isShown: draft.text.isEmpty)
            .padding(.leading, 6)
            .padding(.vertical, 12)
            ComposerActionButton(
                hasContent: hasText,
                isRunning: isRunning,
                canResume: canResume,
                onSubmit: submit,
                onStop: onStop,
                onResume: onResume
            )
        }
        .padding(2)
        // A capsule while single-line, a rounded rectangle once it grows.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .composerSuggestionMenu(menuItems, onSelect: select)
    }

    private func select(_ item: ComposerMenuItem) {
        ComposerMenu.select(item, draft: $draft, isFocused: $isFocused, trigger: skillTrigger)
    }

    private var hasText: Bool {
        !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard hasText else { return }
        onSubmit()
        if collapsesKeyboardOnSubmit {
            isFocused = false
        }
    }
}

// Multi-line composer of the new thread and thread screens; return inserts a newline.
// Attached images and files are shown above the prompt; a prompt can be sent with attachments only.
struct ExpandedComposer: View {
    @Binding var draft: ComposerDraft
    @Binding var attachments: ComposerAttachments
    @Binding var isFocused: Bool
    let placeholder: String
    var isSending = false
    var isRunning = false
    var canResume = false
    var commands: [SlashCommand] = []
    var skills: [RemoteSkill] = []
    var skillTrigger = SkillTrigger.dollar
    var onAttach: () -> Void = {}
    // Name of the selected model, shown to the left of the reasoning gauge.
    var modelName = ""
    // Relative position of the selected reasoning level, from the lowest (0) to the highest (1).
    var reasoningProgress: Double = 0
    var onReasoning: () -> Void = {}
    var onSubmit: () -> Void = {}
    var onStop: () -> Void = {}
    var onResume: () -> Void = {}

    var body: some View {
        let menuItems = isFocused
            ? ComposerMenu.items(for: draft, commands: commands, skills: skills, trigger: skillTrigger)
            : []
        let showsAttachments = !attachments.isEmpty || attachments.isProcessing
        VStack(alignment: .leading, spacing: 16) {
            if showsAttachments {
                ComposerAttachmentStrip(attachments: $attachments)
                    // Attachments being sent stay as they are.
                    .disabled(isSending)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
            }
            ComposerTextView(draft: $draft, isFocused: $isFocused, maxLines: 6, skillTrigger: skillTrigger) {
                // Return picks the highlighted suggestion while a menu is open.
                guard let first = menuItems.first else { return false }
                select(first)
                return true
            }
            .composerPlaceholder(placeholder, isShown: draft.text.isEmpty)
            .padding(.horizontal, 18)
            .padding(.top, showsAttachments ? 0 : 16)

            HStack(spacing: 4) {
                ComposerIconButton(systemImage: "plus", action: onAttach)
                    .disabled(isSending)
                    .accessibilityLabel("添加附件")
                Spacer()
                Button(action: onReasoning) {
                    HStack(spacing: 2) {
                        if !modelName.isEmpty {
                            Text(modelName)
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        ReasoningGauge(progress: reasoningProgress)
                            .frame(width: 44, height: 44)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if isSending {
                    ProgressView()
                        .frame(width: 44, height: 44)
                } else {
                    ComposerActionButton(
                        hasContent: !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
                        // Like the desktop, nothing is sent while attachments are still being read.
                        canSend: !attachments.isProcessing,
                        isRunning: isRunning,
                        canResume: canResume,
                        onSubmit: onSubmit,
                        onStop: onStop,
                        onResume: onResume
                    )
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 4)
        }
        .animation(.snappy, value: showsAttachments)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .composerSuggestionMenu(menuItems, onSelect: select)
    }

    private func select(_ item: ComposerMenuItem) {
        ComposerMenu.select(item, draft: $draft, isFocused: $isFocused, trigger: skillTrigger)
    }
}

private extension View {
    func composerPlaceholder(_ placeholder: String, isShown: Bool) -> some View {
        overlay(alignment: .topLeading) {
            if isShown {
                Text(placeholder)
                    .font(.system(size: 17))
                    .foregroundStyle(Color(.placeholderText))
                    .lineLimit(1)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct ComposerIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// Trailing composer button: send when there is something to send, stop while a run is active, resume when
// paused, and an inactive send arrow otherwise (matching the desktop composer).
private struct ComposerActionButton: View {
    let hasContent: Bool
    var canSend = true
    var isRunning = false
    var canResume = false
    let onSubmit: () -> Void
    var onStop: () -> Void = {}
    var onResume: () -> Void = {}

    var body: some View {
        if hasContent {
            AccentCircleButton(systemImage: "arrow.up", action: onSubmit)
                .allowsHitTesting(canSend)
                .opacity(canSend ? 1 : 0.5)
                .accessibilityLabel("发送")
        } else if isRunning {
            AccentCircleButton(systemImage: "stop.fill", action: onStop)
                .accessibilityLabel("停止")
        } else if canResume {
            AccentCircleButton(systemImage: "play.fill", action: onResume)
                .accessibilityLabel("继续")
        } else {
            AccentCircleButton(systemImage: "arrow.up", action: {})
                .allowsHitTesting(false)
                .accessibilityLabel("发送")
        }
    }
}

// Coral circular button used for send, stop and resume actions.
struct AccentCircleButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Theme.accent, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// Speedometer-like icon that opens the reasoning level slider.
// The coral arc and the needle point at the selected level on a 270° dial open at the bottom.
struct ReasoningGauge: View {
    // Relative position of the selected level, from the lowest (0) to the highest (1).
    var progress: Double = 0

    private let size: CGFloat = 22
    private let lineWidth: CGFloat = 2
    private let hubSize: CGFloat = 5
    private let needleEnd: CGFloat = 6.8
    // The dial starts at the bottom left and sweeps 270° clockwise.
    private let startAngle = 135.0
    private let sweep = 270.0

    var body: some View {
        let clamped = min(max(progress, 0), 1)
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        ZStack {
            Group {
                Circle()
                    .trim(from: 0, to: sweep / 360)
                    .stroke(Color(.systemGray3), style: style)
                Circle()
                    .trim(from: 0, to: sweep / 360 * clamped)
                    .stroke(Theme.accent, style: style)
            }
            .rotationEffect(.degrees(startAngle))

            Circle()
                .stroke(lineWidth: lineWidth)
                .frame(width: hubSize, height: hubSize)
            // Drawn pointing right from the hub, then rotated towards the selected level.
            Path { path in
                path.move(to: CGPoint(x: size / 2 + hubSize / 2, y: size / 2))
                path.addLine(to: CGPoint(x: size / 2 + needleEnd, y: size / 2))
            }
            .stroke(style: style)
            .rotationEffect(.degrees(startAngle + sweep * clamped))
        }
        .foregroundStyle(.primary)
        .frame(width: size, height: size)
        .animation(.snappy, value: clamped)
    }
}

#Preview {
    HStack(spacing: 16) {
        ForEach([0, 1.0 / 3, 2.0 / 3, 1], id: \.self) { progress in
            ReasoningGauge(progress: progress)
        }
    }
}
