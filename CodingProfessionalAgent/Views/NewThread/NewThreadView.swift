import SwiftUI

struct NewThreadView: View {
    @Environment(Router.self) private var router
    @Environment(ConnectionStore.self) private var store
    @State private var connectionId: UUID?
    @State private var projectId: String?
    @State private var workLocation = WorkLocation.local
    @State private var branch = ""
    @State private var branches: [String] = []
    @State private var draft: ComposerDraft
    @State private var attachments = ComposerAttachments()
    @State private var showsAttachmentMenu = false
    @State private var modelId = ""
    @State private var reasoning = ""
    @State private var speed = SpeedMode.standard
    @State private var didApplyDesktopDefaults = false
    // Desktop and project the model and reasoning level were last preselected for.
    @State private var appliedSelectionKey: String?
    @State private var showsReasoningSlider = false
    @State private var showsAdvancedSettings = false
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var isPromptFocused = false
    @State private var didOpenModelSettings = false
    private let initialSpeed: SpeedMode?
    private let opensModelSettings: Bool

    // Selection value for "no project".
    private static let noProject = ""

    init(context: NewThreadContext) {
        _connectionId = State(initialValue: context.connectionId)
        _projectId = State(initialValue: context.projectId)
        _draft = State(initialValue: ComposerDraft(text: context.prompt, references: context.skillReferences))
        initialSpeed = context.speed
        opensModelSettings = context.opensModelSettings
    }

    private var client: DesktopClient? {
        let clients = store.enabledClients
        return clients.first { $0.id == connectionId } ?? clients.first
    }

    private var models: [RemoteModel] {
        client?.availableModels ?? []
    }

    private var selectedModel: RemoteModel? {
        client?.model(id: modelId)
    }

    private var reasoningChoices: [ReasoningChoice] {
        client?.reasoningChoices(for: selectedModel) ?? []
    }

    private var reasoningTitle: String {
        reasoningChoices.first { $0.id == reasoning }?.title ?? ""
    }

    private var modelTitle: String {
        selectedModel?.label ?? "默认模型"
    }

    // Position of the selected level among the model's levels, matching the slider (lowest 0, highest 1).
    private var reasoningProgress: Double {
        let choices = reasoningChoices
        guard choices.count > 1, let index = choices.firstIndex(where: { $0.id == reasoning }) else { return 0 }
        return Double(index) / Double(choices.count - 1)
    }

    private var projectPath: String? {
        guard let client else { return nil }
        return client.project(id: effectiveProjectId(for: client))?.primaryPath
    }

    private var skills: [RemoteSkill] {
        client?.skills(forProjectPath: projectPath) ?? []
    }

    private var skillTrigger: SkillTrigger {
        client?.defaults.skillTrigger ?? .dollar
    }

    private var skillsKey: String {
        "\(client?.id.uuidString ?? "")|\(client?.isConnected ?? false)|\(projectPath ?? "")"
    }

    private var commands: [SlashCommand] {
        guard client != nil, !isSending else { return [] }
        var commands: [SlashCommand] = []
        if selectedModel?.supportsFast == true {
            commands.append(.fast(isOn: speed == .fast) {
                speed = speed == .fast ? .standard : .fast
                notice = speed == .fast ? "已开启快速模式" : "已恢复标准速度"
            })
        }
        commands.append(.model(current: selectedModel?.label) {
            showsReasoningSlider = false
            showsAdvancedSettings = true
        })
        return commands
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            if let client {
                contextSelectors(client)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 8)
            } else {
                ContentUnavailableView(
                    "没有可用的桌面端",
                    systemImage: "display",
                    description: Text("请先在设置中添加并打开桌面端连接。")
                )
                Spacer()
            }

            ExpandedComposer(
                draft: $draft,
                attachments: $attachments,
                isFocused: $isPromptFocused,
                placeholder: "向 CPA 提问",
                isSending: isSending,
                commands: commands,
                skills: skills,
                skillTrigger: skillTrigger,
                onAttach: {
                    showsAttachmentMenu = true
                },
                modelName: modelTitle,
                reasoningProgress: reasoningProgress,
                onReasoning: {
                    guard !reasoningChoices.isEmpty else {
                        showsAdvancedSettings = true
                        return
                    }
                    withAnimation(.snappy) {
                        showsReasoningSlider = true
                    }
                },
                onSubmit: send
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .composerAttachmentPicker(isPresented: $showsAttachmentMenu, attachments: $attachments)
        .overlay {
            if showsReasoningSlider {
                ReasoningOverlay(
                    modelTitle: modelTitle,
                    reasoningTitle: reasoningTitle,
                    levels: reasoningChoices,
                    selection: $reasoning,
                    onOpenSettings: {
                        showsReasoningSlider = false
                        isPromptFocused = false
                        showsAdvancedSettings = true
                    },
                    onDismiss: {
                        withAnimation(.snappy) {
                            showsReasoningSlider = false
                        }
                    }
                )
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showsAdvancedSettings) {
            AdvancedSettingsSheet(
                models: models,
                modelId: $modelId,
                reasoningChoices: reasoningChoices,
                reasoning: $reasoning,
                supportsFast: selectedModel?.supportsFast ?? false,
                speed: $speed
            )
        }
        .alert("无法创建对话", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .onAppear {
            if !opensModelSettings {
                isPromptFocused = true
            }
        }
        .task {
            guard opensModelSettings, !didOpenModelSettings else { return }
            // Wait for the push transition before presenting the sheet.
            try? await Task.sleep(for: .seconds(0.4))
            guard !Task.isCancelled else { return }
            didOpenModelSettings = true
            showsAdvancedSettings = true
        }
        .task(id: selectionKey) {
            applyDefaults()
        }
        .onChange(of: client?.models) {
            applyDefaults()
        }
        .onChange(of: modelId) {
            applyDefaults()
        }
        .onChange(of: router.externalNavigationRevision) { _, _ in
            showsAttachmentMenu = false
            showsReasoningSlider = false
            showsAdvancedSettings = false
            errorMessage = nil
        }
        .task(id: branchQueryKey) {
            await loadBranches()
        }
        .task(id: skillsKey) {
            guard let client else { return }
            await client.loadSkills(projectPath: projectPath)
        }
        .transientNotice($notice)
    }

    private func contextSelectors(_ client: DesktopClient) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ContextSelector(
                systemImage: client.connection.icon.systemImage,
                title: client.connection.displayName,
                selection: Binding(get: { client.id }, set: { connectionId = $0 }),
                options: store.enabledClients.map { SelectorOption(value: $0.id, title: $0.connection.displayName) }
            )
            ContextSelector(
                systemImage: "folder",
                title: client.project(id: effectiveProjectId(for: client))?.name ?? "不使用项目",
                selection: Binding(
                    get: { effectiveProjectId(for: client) ?? Self.noProject },
                    set: { projectId = $0 }
                ),
                options: client.projects.map { SelectorOption(value: $0.id, title: $0.name) }
                    + [SelectorOption(value: Self.noProject, title: "不使用项目")]
            )
            ContextSelector(
                systemImage: "laptopcomputer",
                title: workLocation.title,
                selection: $workLocation,
                options: WorkLocation.allCases.map { SelectorOption(value: $0, title: $0.title) }
            )
            if !branches.isEmpty {
                ContextSelector(
                    systemImage: "arrow.triangle.branch",
                    title: branch,
                    selection: $branch,
                    options: branches.map { SelectorOption(value: $0, title: $0) }
                )
            }
            if !client.isConnected {
                Text(client.state == .connecting ? "正在连接桌面端…" : "桌面端未连接")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                    .frame(height: 32)
            }
        }
    }

    private func effectiveProjectId(for client: DesktopClient) -> String? {
        if let projectId {
            if projectId == Self.noProject {
                return nil
            }
            if client.projects.contains(where: { $0.id == projectId }) {
                return projectId
            }
        }
        return (client.projects.first(where: \.pinned) ?? client.projects.first)?.id
    }

    private var branchQueryKey: String {
        guard let client, client.isConnected,
              let path = client.project(id: effectiveProjectId(for: client))?.primaryPath
        else {
            return ""
        }
        return "\(client.id.uuidString)|\(path)"
    }

    private func loadBranches() async {
        // Never keep a branch of the previously selected project.
        branches = []
        branch = ""
        guard let client, client.isConnected,
              let path = client.project(id: effectiveProjectId(for: client))?.primaryPath
        else {
            return
        }
        let queryKey = branchQueryKey
        let result = await client.gitBranches(at: path)
        guard !Task.isCancelled, queryKey == branchQueryKey else { return }
        branches = result.branches
        branch = result.current ?? result.branches.first ?? ""
    }

    // Synced desktop and selected project; empty until the desktop has synced.
    private var selectionKey: String {
        guard let client, client.hasSynced else { return "" }
        return "\(client.id.uuidString)|\(effectiveProjectId(for: client) ?? Self.noProject)"
    }

    // Whenever the synced desktop or the project changes, picks the model and reasoning level of the
    // project's last used conversation (falling back to the desktop defaults), and the desktop default
    // speed once. Otherwise only replaces selections that became invalid.
    private func applyDefaults() {
        guard let client else { return }
        let key = selectionKey
        let usesLastSelection = !key.isEmpty && key != appliedSelectionKey
        if usesLastSelection {
            appliedSelectionKey = key
        }
        let useDesktopDefaults = !didApplyDesktopDefaults && client.hasSynced
        if useDesktopDefaults {
            didApplyDesktopDefaults = true
        }
        let project = effectiveProjectId(for: client)
        if usesLastSelection || !client.availableModels.contains(where: { $0.id == modelId }) {
            modelId = client.preferredModel(projectId: project)?.id ?? ""
        }
        let model = client.model(id: modelId)
        if usesLastSelection || !client.reasoningChoices(for: model).contains(where: { $0.id == reasoning }) {
            reasoning = client.preferredReasoning(for: model, projectId: project)
        }
        if useDesktopDefaults {
            speed = initialSpeed ?? (client.defaults.speed == SpeedMode.fast.rawValue ? .fast : .standard)
        }
        if speed == .fast, client.model(id: modelId)?.supportsFast != true {
            speed = .standard
        }
    }

    private func send() {
        guard let client, !isSending, !attachments.isProcessing else { return }
        let payload = draft.payload(knownSkills: skills, trigger: skillTrigger)
        let text = payload.text
        let sentAttachments = attachments
        guard !text.isEmpty || !sentAttachments.isEmpty else { return }
        guard client.isConnected else {
            errorMessage = "桌面端未连接"
            return
        }
        if !sentAttachments.images.isEmpty, selectedModel?.supportsImages != true {
            errorMessage = ComposerAttachments.unsupportedImagesMessage
            return
        }

        isSending = true
        let sessionId = UUID().uuidString.lowercased()
        let entryId = UUID().uuidString.lowercased()
        let createdAt = Date().milliseconds
        let project = effectiveProjectId(for: client)
        let selectedBranch = branches.isEmpty || branch.isEmpty ? nil : branch
        let model = modelId.isEmpty ? nil : modelId
        let effort = reasoning.isEmpty ? nil : reasoning
        let speedValue = client.model(id: modelId)?.supportsFast == true ? speed.rawValue : SpeedMode.standard.rawValue

        Task {
            do {
                // Files go to the desktop first, so a failed upload leaves no empty conversation behind.
                let filePaths = try await client.uploadAttachments(sentAttachments.uploads, sessionId: sessionId)
                try await client.createSession(
                    id: sessionId,
                    // Like the desktop, a prompt without text is named after its first attachment.
                    title: Self.title(from: text.isEmpty ? sentAttachments.items.first?.name ?? "" : text),
                    projectId: project,
                    branch: selectedBranch,
                    workLocation: workLocation,
                    modelId: model,
                    reasoningEffort: effort,
                    speed: speedValue
                )
                try await client.delegateRun(DelegateRunRequest(
                    sessionId: sessionId,
                    text: ComposerAttachments.promptText(text, filePaths: filePaths),
                    projectId: project,
                    branch: selectedBranch,
                    modelId: model,
                    reasoningEffort: effort,
                    speed: speedValue,
                    userEntryId: entryId,
                    userEntryCreatedAt: createdAt,
                    skillReferences: payload.references,
                    images: await sentAttachments.promptImages(),
                    followUpMode: nil
                ))
                router.replaceTop(with: .thread(connectionId: client.id, sessionId: sessionId))
            } catch {
                errorMessage = error.localizedDescription
            }
            isSending = false
        }
    }

    private static func title(from text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        return firstLine.count > 50 ? String(firstLine.prefix(50)) + "…" : firstLine
    }
}

struct SelectorOption<Value: Hashable>: Hashable {
    let value: Value
    let title: String
}

// Menu-backed selector for the new thread context (device, project, mode, branch).
private struct ContextSelector<Value: Hashable>: View {
    let systemImage: String
    let title: String
    @Binding var selection: Value
    let options: [SelectorOption<Value>]

    var body: some View {
        Menu {
            Picker(selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(option.title).tag(option.value)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            // Concrete colors are required because menu labels inherit the tint color.
            HStack(spacing: 0) {
                Image(systemName: systemImage)
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.secondary, Color.clear)
                    .frame(width: 22)
                    .padding(.trailing, 13)
                Text(title)
                    .font(.system(size: 17))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.leading, 8)
            }
            .foregroundStyle(Color.secondary)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
    }
}

#Preview {
    NavigationStack {
        NewThreadView(context: NewThreadContext())
    }
    .environment(Router())
    .environment(ConnectionStore())
}
