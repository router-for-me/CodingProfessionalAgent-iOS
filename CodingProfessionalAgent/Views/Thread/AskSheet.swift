import SwiftUI

// Answers a question raised by the agent's `ask` tool on the desktop.
struct AskSheet: View {
    let request: AskRequest
    let onSubmit: (AskDecision) async throws -> Void
    let onCancelCountdown: () async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var customText = ""
    @State private var isCancellingCountdown = false
    @State private var didCancelFromTyping = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(request.question)
                        .font(.system(size: 17))
                        .textSelection(.enabled)
                }

                if !request.options.isEmpty {
                    Section {
                        ForEach(Array(request.options.enumerated()), id: \.offset) { index, option in
                            Button {
                                submit(.selected(option: option, index: index))
                            } label: {
                                optionLabel(option)
                            }
                        }
                        if request.countdownDeadline != nil {
                            Button("停止自动选择") {
                                cancelCountdown()
                            }
                            .foregroundStyle(Color.secondary)
                            .disabled(isCancellingCountdown)
                        }
                    } footer: {
                        countdown
                    }
                }

                if request.allowCustom {
                    Section {
                        TextField(request.customPrompt ?? "输入你的回答", text: $customText, axis: .vertical)
                            .lineLimit(1...5)
                            .onChange(of: customText) { _, text in
                                // Typing a custom answer must not race the desktop auto-selection.
                                if !text.isEmpty && !didCancelFromTyping {
                                    didCancelFromTyping = true
                                    cancelCountdown()
                                }
                            }
                        Button("发送回答") {
                            submit(.custom(customText.trimmingCharacters(in: .whitespacesAndNewlines)))
                        }
                        .disabled(customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if request.allowSkip {
                    Section {
                        Button("跳过") {
                            submit(.skipped)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(isSubmitting)
            .navigationTitle("CPA 需要你的回答")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("稍后") {
                        dismiss()
                    }
                    .tint(Color.primary)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func optionLabel(_ option: AskOption) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(option.title)
                    .foregroundStyle(Color.primary)
                if option.recommended == true {
                    Text("推荐")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.15), in: Capsule())
                }
            }
            if let description = option.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var countdown: some View {
        if let deadline = request.countdownDeadline {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(((deadline - context.date.milliseconds) / 1000).rounded()))
                Text(remaining > 0 ? "\(remaining) 秒后将自动选择推荐项" : "即将自动选择推荐项")
            }
        }
    }

    // The countdown hides only after the desktop confirms; the model then clears the deadline.
    private func cancelCountdown() {
        guard request.countdownDeadline != nil, !isCancellingCountdown else { return }
        isCancellingCountdown = true
        errorMessage = nil
        Task {
            if !(await onCancelCountdown()) {
                errorMessage = "无法停止自动选择，请重试"
            }
            isCancellingCountdown = false
        }
    }

    private func submit(_ decision: AskDecision) {
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                try await onSubmit(decision)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }
}
