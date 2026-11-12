import SwiftUI

// Half-height sheet for choosing model, reasoning level and speed.
struct AdvancedSettingsSheet: View {
    let models: [RemoteModel]
    @Binding var modelId: String
    let reasoningChoices: [ReasoningChoice]
    @Binding var reasoning: String
    let supportsFast: Bool
    @Binding var speed: SpeedMode
    // Like the desktop's model menu, only the reasoning level can change while a run is active.
    var isRunActive = false

    private var modelName: String {
        models.first { $0.id == modelId }?.label ?? "默认"
    }

    private var reasoningTitle: String {
        reasoningChoices.first { $0.id == reasoning }?.title ?? "默认"
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("高级")
                .font(.system(size: 17, weight: .semibold))
                .frame(height: 44)
                .padding(.top, 20)
                .padding(.bottom, 10)

            VStack(spacing: 0) {
                SettingMenuRow(title: "模型", value: modelName, valueColor: .secondary) {
                    Picker(selection: $modelId) {
                        ForEach(models) { item in
                            Text(item.label).tag(item.id)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                }
                .disabled(models.isEmpty || isRunActive)
                .opacity(isRunActive ? 0.4 : 1)

                Divider()
                    .padding(.horizontal, 20)

                SettingMenuRow(title: "智能", value: reasoningTitle) {
                    Picker(selection: $reasoning) {
                        ForEach(reasoningChoices) { item in
                            Text(item.title).tag(item.id)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                }
                .disabled(reasoningChoices.isEmpty)
            }
            .background(Theme.groupedRow, in: RoundedRectangle(cornerRadius: 26, style: .continuous))

            if isRunActive {
                Text("会话运行中，仅可调整智能")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }

            // Like the desktop, models with only the standard speed hide the speed row.
            if supportsFast {
                SettingMenuRow(title: "速度", value: speed.title) {
                    Picker(selection: $speed) {
                        ForEach(SpeedMode.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                }
                .disabled(isRunActive)
                .opacity(isRunActive ? 0.4 : 1)
                .background(Theme.groupedRow, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .padding(.top, 34)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

private struct SettingMenuRow<MenuContent: View>: View {
    let title: String
    let value: String
    var valueColor: Color = .primary
    @ViewBuilder let menuContent: () -> MenuContent

    var body: some View {
        Menu {
            menuContent()
        } label: {
            // Concrete colors are required because menu labels inherit the tint color.
            HStack(spacing: 6) {
                Text(title)
                    .foregroundStyle(Color.primary)
                Spacer()
                Text(value)
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
            .font(.system(size: 17))
            .padding(.horizontal, 20)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
    }
}

#Preview {
    @Previewable @State var modelId = ""
    @Previewable @State var reasoning = "high"
    @Previewable @State var speed = SpeedMode.standard
    Color.clear
        .sheet(isPresented: .constant(true)) {
            AdvancedSettingsSheet(
                models: [],
                modelId: $modelId,
                reasoningChoices: ["low", "medium", "high"].map { ReasoningChoice(id: $0, title: ReasoningChoice.title(for: $0)) },
                reasoning: $reasoning,
                supportsFast: true,
                speed: $speed
            )
        }
}
