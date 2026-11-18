import SwiftUI
import UIKit

struct ThreadView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(\.locale) private var locale
    let connectionId: UUID
    let sessionId: String
    var graceConfiguration: ConnectionGraceConfiguration = .standard

    var body: some View {
        let _ = locale
        if let client = store.client(for: connectionId) {
            // Key by connection and session so replacing a thread route in place never reuses another conversation's state.
            ThreadContent(client: client, sessionId: sessionId, graceConfiguration: graceConfiguration)
                .id("\(client.id.uuidString)/\(sessionId)")
        } else {
            ContentUnavailableView(
                L10n.Thread.connectionUnavailableTitle,
                systemImage: "bolt.horizontal.circle",
                description: Text(L10n.Thread.connectionUnavailableMessage)
            )
        }
    }

    @MainActor
    static func resolvedTitle(model: ThreadModel, router: Router) -> String {
        if let session = model.session {
            return session.title.isEmpty ? L10n.Home.newChat : session.title
        }
        if let hint = router.sessionTitleHint(connectionId: model.client.id, sessionId: model.sessionId) {
            return hint
        }
        return (model.isWaitingForConnection || model.isLoading) ? L10n.Thread.chatTitle : L10n.Home.newChat
    }

    @MainActor
    static func resolvedComposerPlaceholder(model: ThreadModel) -> String {
        let client = model.client
        if client.isConnected {
            return L10n.Thread.workOnDesktop(client.connection.displayName)
        }
        if model.isWaitingForConnection || client.state == .connecting {
            return L10n.Home.clientConnecting(client.connection.displayName)
        }
        return L10n.ErrorMessage.notConnected
    }
}

private struct ThreadContent: View {
    @Environment(Router.self) private var router
    @Environment(\.navigationWidth) private var navigationWidth
    @Environment(\.locale) private var locale
    @State private var model: ThreadModel
    @State private var draft = ComposerDraft()
    @State private var attachments = ComposerAttachments()
    @State private var showsAttachmentMenu = false
    // Prompts whose attachments are still being uploaded or prepared.
    @State private var attachmentSends = 0
    @State private var isPromptFocused = false
    @State private var showsReasoningSlider = false
    // Level picked in the reasoning slider: applied when the slider closes, shown until the desktop confirms it.
    @State private var pickedReasoning: String?
    // Bumped on every pick, so a finished update never clears a newer pick.
    @State private var reasoningPicks = 0
    // Latest reasoning level update; runs started from here wait for it so they use the new level.
    @State private var reasoningUpdate: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var showsAsk = false
    @State private var panelTab: SessionPanelTab?
    @State private var showsRename = false
    @State private var renameText = ""
    // Selection edited in the model sheet; applied to the conversation when the sheet closes.
    @State private var showsModelSheet = false
    @State private var sheetModelId = ""
    @State private var sheetReasoning = ""
    @State private var sheetSpeed = SpeedMode.standard
    @State private var sheetOriginal = ""
    // The sheet was opened during a run: like the desktop's model menu, only the reasoning level can change.
    @State private var sheetLocksModel = false
    // Sent prompt being edited in place, like the desktop's message editing.
    @State private var editingEntryId: String?
    @State private var editDraft = ComposerDraft()
    @State private var isSubmittingEdit = false
    // Bumped after an edit so the rerun is followed like a new message.
    @State private var followRequests = 0
    @AppStorage(PreferenceKey.collapseKeyboardAfterSend) private var collapseKeyboardAfterSend = true
    @AppStorage(PreferenceKey.showContextUsage) private var showContextUsage = false
    @AppStorage(PreferenceKey.followUpMode) private var followUpMode = FollowUpMode.queue
    @AppStorage(PreferenceKey.wrapDiffLines) private var wrapDiffLines = true

    init(
        client: DesktopClient,
        sessionId: String,
        graceConfiguration: ConnectionGraceConfiguration = .standard
    ) {
        _model = State(initialValue: ThreadModel(
            client: client,
            sessionId: sessionId,
            graceConfiguration: graceConfiguration
        ))
    }

    private var client: DesktopClient {
        model.client
    }

    // Width left for the leading title after the back button and trailing actions.
    private var titleWidth: CGFloat {
        NavigationLayout.titleWidth(containerWidth: navigationWidth, reservedWidth: 240)
    }

    private var title: String {
        ThreadView.resolvedTitle(model: model, router: router)
    }

    private var composerPlaceholder: String {
        ThreadView.resolvedComposerPlaceholder(model: model)
    }

    private var subtitle: String {
        var parts = [client.connection.displayName]
        if let project = client.project(id: model.session?.projectId) {
            parts.append(project.name)
        }
        return parts.joined(separator: " • ")
    }

    private var projectPath: String? {
        client.project(id: model.session?.projectId)?.primaryPath
    }

    private var skills: [RemoteSkill] {
        client.skills(forProjectPath: projectPath)
    }

    // Runtime settings of the next turn: the conversation's own values, else the desktop defaults.
    private var currentModelId: String {
        if let modelId = model.session?.modelId, !modelId.isEmpty {
            return modelId
        }
        return client.availableModels.first { $0.id == client.defaults.modelId }?.id
            ?? client.availableModels.first?.id
            ?? ""
    }

    private var currentReasoning: String {
        if let effort = model.session?.reasoningEffort, !effort.isEmpty {
            return effort
        }
        return client.defaults.reasoningLevel
    }

    private var currentSpeed: SpeedMode {
        (model.session?.speed ?? client.defaults.speed) == SpeedMode.fast.rawValue ? .fast : .standard
    }

    private var currentModel: RemoteModel? {
        client.model(id: currentModelId)
    }

    private var modelTitle: String {
        currentModel?.label ?? (currentModelId.isEmpty ? L10n.Common.defaultModel : currentModelId)
    }

    private var reasoningChoices: [ReasoningChoice] {
        client.reasoningChoices(for: currentModel)
    }

    private var shownReasoning: String {
        pickedReasoning ?? currentReasoning
    }

    private var reasoningTitle: String {
        reasoningChoices.first { $0.id == shownReasoning }?.title ?? ""
    }

    // Position of the shown level among the model's levels, matching the slider (lowest 0, highest 1).
    private var reasoningProgress: Double {
        let choices = reasoningChoices
        guard choices.count > 1, let index = choices.firstIndex(where: { $0.id == shownReasoning }) else { return 0 }
        return Double(index) / Double(choices.count - 1)
    }

    // Like the desktop's model menu, the model can only be changed while no run is active;
    // the reasoning level can be changed at any time.
    private var canChangeModel: Bool {
        !model.isRunning
    }

    // Like the desktop composer, runtime settings are locked while a run is active.
    private var commands: [SlashCommand] {
        guard client.isConnected, !model.isRunning else { return [] }
        var commands: [SlashCommand] = []
        if currentModel?.supportsFast == true {
            commands.append(.fast(isOn: currentSpeed == .fast) {
                toggleFast()
            })
        }
        // The desktop can only compact a conversation that has entries.
        if !model.entries.isEmpty {
            commands.append(.compact {
                compact()
            })
        }
        commands.append(.model(current: currentModel?.label) {
            openModelSheet()
        })
        return commands
    }

    // Sub-agent badges open the sub-agent's own run view; the fork action copies the conversation
    // up to that message and opens the copy (desktop `onForkMessage`).
    private var turnContext: TurnContext {
        TurnContext(
            subAgents: model.subAgents,
            toolDetails: model.toolDetails,
            isBuildingSystemPrompt: model.isBuildingSystemPrompt,
            onFork: fork
        ) { record in
            router.push(.subAgent(
                connectionId: client.id,
                parentSessionId: record.parentSessionId,
                agentId: record.id,
                sessionId: record.conversationId
            ))
        }
    }

    private var skillsKey: String {
        "\(client.isConnected)|\(projectPath ?? "")"
    }

    // Like the desktop, an edit reruns from the prompt; it is offered only while no run is active.
    private var canEdit: Bool {
        client.isConnected && !model.isRunning
    }

    private var isEditedEntryShown: Bool {
        model.entries.contains { $0.id == editingEntryId && $0.kind == .user }
    }

    var body: some View {
        let _ = locale
        return baseContent
            .onChange(of: showsReasoningSlider) { _, isShown in
                if !isShown {
                    applyPickedReasoning()
                }
            }
            .onChange(of: model.isRunning) { _, isRunning in
                if isRunning {
                    // Like the desktop's model menu, a starting run closes the model settings opened before it.
                    if !sheetLocksModel {
                        showsModelSheet = false
                    }
                } else {
                    // A finished run unlocks the open settings; closing them then applies the full selection.
                    sheetLocksModel = false
                }
            }
            .onChange(of: model.askRequest?.id) { _, id in
                showsAsk = id != nil
            }
            .onChange(of: isEditedEntryShown) { _, isShown in
                // The prompt was removed, e.g. by an edit or deletion on another client.
                if !isShown {
                    endEdit()
                }
            }
            .onChange(of: model.failedEdit) { _, failed in
                // Like the desktop composer after a failed preflight, the edited text is kept for another try.
                guard let failed, model.entries.contains(where: { $0.id == failed.entry.id }) else { return }
                editDraft = ComposerDraft(text: failed.entry.text, references: failed.entry.skillReferences ?? [])
                editingEntryId = failed.entry.id
                errorMessage = L10n.Thread.editFailedMessage
            }
            .task(id: skillsKey) {
                await client.loadSkills(projectPath: projectPath)
            }
            .onChange(of: sheetModelId) {
                normalizeSheetSelection()
            }
            .onChange(of: router.externalNavigationRevision) { _, _ in
                showsAttachmentMenu = false
                showsReasoningSlider = false
                showsModelSheet = false
                showsAsk = false
                panelTab = nil
                showsRename = false
                errorMessage = nil
                model.handleExternalNavigation()
            }
            .sheet(isPresented: $showsModelSheet, onDismiss: applyModelSheet) {
                AdvancedSettingsSheet(
                    models: client.availableModels,
                    modelId: $sheetModelId,
                    reasoningChoices: client.reasoningChoices(for: client.model(id: sheetModelId)),
                    reasoning: $sheetReasoning,
                    supportsFast: client.model(id: sheetModelId)?.supportsFast ?? false,
                    speed: $sheetSpeed,
                    isRunActive: sheetLocksModel
                )
            }
            .transientNotice($notice)
            .sheet(isPresented: $showsAsk) {
                if let request = model.askRequest {
                    AskSheet(
                        request: request,
                        onSubmit: { decision in
                            try await model.answerAsk(decision)
                        },
                        onCancelCountdown: {
                            await model.cancelAskCountdown()
                        }
                    )
                }
            }
            .sheet(item: $panelTab) { tab in
                SessionPanelSheet(client: client, session: model.session, initialTab: tab)
            }
            .alert(L10n.Thread.renameTitle, isPresented: $showsRename) {
                TextField(L10n.Common.title, text: $renameText)
                Button(L10n.Common.cancel, role: .cancel) {}
                Button(L10n.Common.save) {
                    rename()
                }
            }
            .alert(L10n.Common.actionFailed, isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button(L10n.Common.ok, role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private var baseContent: some View {
        ScrollViewReader { proxy in
            messageList(proxy)
        }
        .overlay {
            placeholderOverlay
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if model.askRequest != nil && !showsAsk {
                    AskBanner {
                        showsAsk = true
                    }
                }
                if showContextUsage, let usage = model.contextUsage {
                    Text(L10n.Thread.contextUsage(Int((usage * 100).rounded())))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 12)
                }
                // The inline editor takes the input while a prompt is edited.
                if editingEntryId == nil {
                    ExpandedComposer(
                        draft: $draft,
                        attachments: $attachments,
                        isFocused: $isPromptFocused,
                        placeholder: composerPlaceholder,
                        isSending: attachmentSends > 0,
                        isRunning: model.isRunning,
                        canResume: model.canResume,
                        commands: commands,
                        skills: skills,
                        skillTrigger: client.defaults.skillTrigger,
                        onAttach: {
                            showsAttachmentMenu = true
                        },
                        modelName: modelTitle,
                        reasoningProgress: reasoningProgress,
                        onReasoning: showReasoningSlider,
                        onSubmit: send,
                        onStop: stop,
                        onResume: resume
                    )
                }
            }
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
                    selection: Binding(
                        get: { shownReasoning },
                        set: { level in
                            pickedReasoning = level
                            reasoningPicks += 1
                        }
                    ),
                    canChangeModel: canChangeModel,
                    onOpenSettings: {
                        showsReasoningSlider = false
                        isPromptFocused = false
                        openModelSheet()
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
        .background {
            LinearGradient(
                stops: [
                    .init(color: Color(.systemBackground), location: 0.6),
                    .init(color: Color(.systemGray6), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar { toolbarContent }
        .onAppear {
            model.activate()
            client.beginViewing(sessionId: model.sessionId)
        }
        .onDisappear {
            model.deactivate()
            client.endViewing(sessionId: model.sessionId)
            // Leaving with the slider open keeps the picked level.
            if showsReasoningSlider {
                applyPickedReasoning()
            }
        }
    }

    // Conversation turns; a prompt being edited is shown as an inline editor.
    private func messageList(_ scrollProxy: ScrollViewProxy) -> some View {
        ScrollView {
            // Not lazy: jumping to the bottom past rows a lazy stack has not measured lands on estimated
            // positions, which can leave the screen blank or keep the layout busy.
            VStack(alignment: .leading, spacing: 24) {
                let context = turnContext
                let turns = ChatTurn.group(model.entries, isRunActive: model.isRunning)
                let hasLiveTurn = turns.contains {
                    if case .assistant(let assistantTurn) = $0 {
                        return assistantTurn.isLive
                    }
                    return false
                }
                ForEach(turns) { turn in
                    switch turn {
                    case .user(let entry):
                        if entry.id == editingEntryId {
                            UserMessageEditor(
                                draft: $editDraft,
                                skills: skills,
                                skillTrigger: client.defaults.skillTrigger,
                                isSubmitting: isSubmittingEdit,
                                canSubmit: canEdit,
                                onCancel: cancelEdit,
                                onSubmit: submitEdit
                            )
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.height
                            } action: { _ in
                                // Growing text must not slide the buttons under the keyboard.
                                revealEditor(scrollProxy)
                            }
                        } else {
                            UserBubble(
                                entry: entry,
                                knownSkills: skills,
                                skillTrigger: client.defaults.skillTrigger,
                                onEdit: canEdit && entry.pendingStatus == nil && !isSubmittingEdit ? { startEdit(entry) } : nil
                            )
                        }
                    case .compaction:
                        CompactionDivider()
                    case .assistant(let assistantTurn):
                        AssistantTurnView(turn: assistantTurn, context: context, wrapLines: wrapDiffLines)
                    }
                }

                if model.isBuildingSystemPrompt && !hasLiveTurn {
                    SystemPromptBuildStatusView()
                }

                if let error = model.lastRunError, !model.isRunning {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 15))
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 13)
            .padding(.bottom, 12)
        }
        // A finished conversation opens at its first prompt; a running one follows its output.
        .followsLatestContent(
            userMessageCount: model.entries.count { $0.kind == .user },
            isPaused: editingEntryId != nil,
            followRequests: followRequests,
            showsJumpButton: true,
            startsFollowing: model.isRunning
        )
        // Recreated when the first entries arrive (also after an offline or failed first load), so the opening
        // position uses the run state at that point and the loaded prompts are not taken as a new message.
        .id(model.entries.isEmpty)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            revealEditor(scrollProxy)
        }
    }

    // The inline editor is a UIKit text view, which the scroll view does not keep above the keyboard.
    private func revealEditor(_ scrollProxy: ScrollViewProxy) {
        guard let editingEntryId else { return }
        withAnimation(.snappy) {
            // Without an anchor the list scrolls only as far as needed to show the whole editor.
            scrollProxy.scrollTo(editingEntryId)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(width: titleWidth, alignment: .leading)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                router.push(.newThread(NewThreadContext(connectionId: client.id, projectId: model.session?.projectId)))
            } label: {
                Image(systemName: "square.and.pencil")
            }
            Menu {
                let pinned = model.session?.pinned ?? false
                Button(pinned ? L10n.Home.unpin : L10n.Thread.pin, systemImage: pinned ? "pin.slash" : "pin") {
                    togglePinned()
                }
                Button(L10n.Thread.rename, systemImage: "pencil") {
                    renameText = model.session?.title ?? ""
                    showsRename = true
                }
                Button(L10n.Thread.copyThreadId, systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = model.sessionId
                    notice = L10n.Common.copiedToClipboard
                }
                Button(L10n.Thread.archive, systemImage: "archivebox", role: .destructive) {
                    archive()
                }
                Section {
                    Button(L10n.Panels.changes, systemImage: "arrow.triangle.branch") {
                        panelTab = .changes
                    }
                    Button(L10n.Panels.files, systemImage: "folder") {
                        panelTab = .files
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }

    @ViewBuilder
    private var placeholderOverlay: some View {
        if model.isDeleted {
            ContentUnavailableView(L10n.Thread.deletedTitle, systemImage: "trash", description: Text(L10n.Thread.deletedMessage))
        } else if visibleEntries.isEmpty {
            if let error = model.connectionError {
                ThreadStatusPlaceholder(
                    systemImage: "bolt.horizontal.circle",
                    title: L10n.Thread.cannotConnectTitle,
                    message: ThreadStatusPlaceholder.connectionMessage(error, desktopName: client.connection.displayName),
                    actionTitle: client.connection.isEnabled ? L10n.Common.retry : nil,
                    action: { model.retryConnection() }
                )
                .transition(.opacity)
            } else if let error = model.loadError {
                ThreadStatusPlaceholder(
                    systemImage: "exclamationmark.triangle",
                    title: L10n.Thread.loadFailedTitle,
                    message: error,
                    actionTitle: L10n.Common.retry,
                    action: { model.refresh() }
                )
                .transition(.opacity)
            } else if model.isWaitingForConnection || model.isLoading {
                ConversationLoadingView(
                    icon: client.connection.icon,
                    desktopName: client.connection.displayName,
                    isConnected: client.isConnected
                )
                .transition(.opacity)
            }
        }
    }

    private var visibleEntries: [ConversationEntry] {
        model.entries.filter { $0.kind == .user || $0.kind == .assistant || $0.kind == .compaction }
    }

    private func send() {
        guard attachmentSends == 0, !attachments.isProcessing else { return }
        let payload = draft.payload(knownSkills: skills, trigger: client.defaults.skillTrigger)
        let sentAttachments = attachments
        guard !payload.text.isEmpty || !sentAttachments.isEmpty else { return }
        if !sentAttachments.images.isEmpty, currentModel?.supportsImages != true {
            errorMessage = ComposerAttachments.unsupportedImagesMessage
            return
        }
        let sentDraft = draft
        draft = ComposerDraft()
        attachments = ComposerAttachments()
        if collapseKeyboardAfterSend {
            isPromptFocused = false
        }
        let update = reasoningUpdate
        // Until it is handed to the desktop, a prompt with attachments keeps later prompts from overtaking it.
        let locks = !sentAttachments.isEmpty
        if locks {
            attachmentSends += 1
        }
        Task {
            defer {
                if locks {
                    attachmentSends -= 1
                }
            }
            await update?.value
            do {
                let filePaths = try await client.uploadAttachments(sentAttachments.uploads, sessionId: model.sessionId)
                let images = await sentAttachments.promptImages()
                // The model may have been changed while waiting; `send` takes it without suspending first.
                if !images.isEmpty, currentModel?.supportsImages != true {
                    throw DesktopClientError.remote(ComposerAttachments.unsupportedImagesMessage)
                }
                try await model.send(
                    ComposerAttachments.promptText(payload.text, filePaths: filePaths),
                    skillReferences: payload.references,
                    images: images,
                    followUpMode: followUpMode
                )
            } catch {
                // The text is restored unless something new was typed meanwhile; attachments are put back first.
                if draft.text.isEmpty {
                    draft = sentDraft
                }
                attachments.items = sentAttachments.items + attachments.items
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startEdit(_ entry: ConversationEntry) {
        editDraft = ComposerDraft(parts: entry.promptParts(knownSkills: skills))
        editingEntryId = entry.id
    }

    private func cancelEdit() {
        guard !isSubmittingEdit else { return }
        endEdit()
    }

    private func endEdit() {
        editingEntryId = nil
        editDraft = ComposerDraft()
    }

    // The editor stays open with its draft until the desktop accepts the edit request.
    private func submitEdit() {
        guard let entryId = editingEntryId, canEdit, !isSubmittingEdit else { return }
        let payload = editDraft.payload(knownSkills: skills, trigger: client.defaults.skillTrigger)
        guard !payload.text.isEmpty else { return }
        isSubmittingEdit = true
        let update = reasoningUpdate
        Task {
            await update?.value
            do {
                try await model.edit(entryId: entryId, text: payload.text, skillReferences: payload.references)
                // A failure reported meanwhile has already put the edited text back into the editor.
                if model.failedEdit == nil, editingEntryId == entryId {
                    endEdit()
                }
                followRequests += 1
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmittingEdit = false
        }
    }

    private func toggleFast() {
        let speed: SpeedMode = currentSpeed == .fast ? .standard : .fast
        Task {
            do {
                try await client.setSessionRuntime(id: model.sessionId, speed: speed.rawValue)
                notice = speed == .fast ? L10n.Composer.fastModeEnabledNotice : L10n.Composer.fastModeDisabledNotice
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func compact() {
        Task {
            do {
                try await client.compactSession(id: model.sessionId)
                notice = L10n.Thread.compactRequested
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // Without reasoning levels the model settings open instead, if the model can be changed.
    private func showReasoningSlider() {
        guard !reasoningChoices.isEmpty else {
            if canChangeModel {
                isPromptFocused = false
                openModelSheet()
            }
            return
        }
        withAnimation(.snappy) {
            showsReasoningSlider = true
        }
    }

    // Applies the level picked in the slider; allowed during a run, like the desktop's model menu.
    private func applyPickedReasoning() {
        guard let picked = pickedReasoning else { return }
        let pick = reasoningPicks
        let previous = reasoningUpdate
        let sessionId = model.sessionId
        reasoningUpdate = Task {
            // Updates reach the desktop in the order they were picked.
            await previous?.value
            do {
                try await client.setSessionRuntime(id: sessionId, reasoningEffort: picked)
            } catch {
                errorMessage = error.localizedDescription
            }
            // A level picked meanwhile is kept for its own update.
            if reasoningPicks == pick {
                pickedReasoning = nil
            }
        }
    }

    private func openModelSheet() {
        sheetLocksModel = !canChangeModel
        sheetModelId = currentModelId
        sheetReasoning = shownReasoning
        sheetSpeed = currentSpeed
        normalizeSheetSelection()
        sheetOriginal = sheetSelectionKey
        showsModelSheet = true
    }

    private var sheetSelectionKey: String {
        "\(sheetModelId)|\(sheetReasoning)|\(sheetSpeed.rawValue)"
    }

    // Keeps reasoning level and speed valid for the model picked in the sheet.
    private func normalizeSheetSelection() {
        let selected = client.model(id: sheetModelId)
        let choices = client.reasoningChoices(for: selected)
        if !choices.contains(where: { $0.id == sheetReasoning }) {
            sheetReasoning = choices.first { $0.id == client.defaults.reasoningLevel }?.id
                ?? choices.first { $0.id == "medium" }?.id
                ?? choices.last?.id
                ?? ""
        }
        if sheetSpeed == .fast, selected?.supportsFast != true {
            sheetSpeed = .standard
        }
    }

    private func applyModelSheet() {
        guard !sheetModelId.isEmpty, sheetSelectionKey != sheetOriginal else { return }
        if sheetLocksModel {
            // Only the reasoning level could change; it is applied like a level picked in the slider.
            pickedReasoning = sheetReasoning
            reasoningPicks += 1
            applyPickedReasoning()
            return
        }
        // A run started meanwhile locks the model, like the desktop's model menu.
        guard canChangeModel else { return }
        let modelChanged = sheetModelId != currentModelId
        let modelId = sheetModelId
        // Like the desktop's `normalizeModelPreferences`, a model without reasoning levels uses "off".
        let reasoning = sheetReasoning.isEmpty ? "off" : sheetReasoning
        let speed = sheetSpeed.rawValue
        let label = client.model(id: modelId)?.label ?? modelId
        let update = reasoningUpdate
        Task {
            // A level picked in the slider before opening the sheet must not land after this update.
            await update?.value
            // A run may have started while waiting.
            guard canChangeModel else { return }
            do {
                try await client.setSessionRuntime(id: model.sessionId, modelId: modelId, reasoningEffort: reasoning, speed: speed)
                notice = modelChanged ? L10n.Thread.modelSwitched(label) : L10n.Thread.modelUpdated
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // Copies the conversation up to `entry` into a new one and opens it, like the desktop's
    // message fork action (`forkSession` + navigate to the copy).
    private func fork(fromEntry entry: ConversationEntry) {
        Task {
            do {
                let newId = try await client.forkSession(id: model.sessionId, atEntryId: entry.id)
                router.push(.thread(connectionId: client.id, sessionId: newId))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func stop() {
        Task {
            do {
                try await model.stop()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func resume() {
        let update = reasoningUpdate
        Task {
            await update?.value
            // Taps queued while waiting resume only once.
            guard model.canResume else { return }
            do {
                try await model.resume()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func togglePinned() {
        let pinned = !(model.session?.pinned ?? false)
        Task {
            do {
                try await client.setSessionPinned(id: model.sessionId, pinned: pinned)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func rename() {
        let newTitle = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty else { return }
        Task {
            do {
                try await client.renameSession(id: model.sessionId, title: newTitle)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func archive() {
        Task {
            do {
                try await client.archiveSession(id: model.sessionId)
                if !router.path.isEmpty {
                    router.path.removeLast()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

extension View {
    // Keeps a short conversation at the top and follows new output while the reader stays at the bottom.
    // While paused (e.g. editing a prompt) nothing scrolls by itself; a new follow request resumes following.
    // With `showsJumpButton`, a round button above the bottom edge returns to the latest content.
    // Without `startsFollowing` (read only when the view is first created), the list opens at the top; once it is
    // taller than the screen it follows only after the reader reaches the bottom or a new user message arrives.
    func followsLatestContent(
        userMessageCount: Int,
        isPaused: Bool = false,
        followRequests: Int = 0,
        showsJumpButton: Bool = false,
        startsFollowing: Bool = true
    ) -> some View {
        modifier(LatestContentFollower(
            userMessageCount: userMessageCount,
            isPaused: isPaused,
            followRequests: followRequests,
            showsJumpButton: showsJumpButton,
            startsFollowing: startsFollowing
        ))
    }
}

// Mirrors the desktop message list: following stops once the user scrolls away from the bottom and
// resumes when they scroll back or a new user message arrives while the list is idle.
private struct LatestContentFollower: ViewModifier {
    // Same tolerance as the desktop's STICK_TO_BOTTOM_PX.
    private static let stickDistance: CGFloat = 48

    let userMessageCount: Int
    let isPaused: Bool
    let followRequests: Int
    let showsJumpButton: Bool
    @State private var position: ScrollPosition
    @State private var isFollowing: Bool
    @State private var isScrolling = false
    // Content height when the current scroll was last near the bottom.
    @State private var bottomHeight: CGFloat?
    @State private var isAwayFromBottom = false
    // Set by the jump button until its scroll ends, so that scroll always resumes following.
    @State private var isJumping = false

    init(userMessageCount: Int, isPaused: Bool, followRequests: Int, showsJumpButton: Bool, startsFollowing: Bool) {
        self.userMessageCount = userMessageCount
        self.isPaused = isPaused
        self.followRequests = followRequests
        self.showsJumpButton = showsJumpButton
        _position = State(initialValue: ScrollPosition(edge: startsFollowing ? .bottom : .top))
        _isFollowing = State(initialValue: startsFollowing)
    }

    // Hidden while the list follows by itself, so streamed output does not flash the button.
    private var isJumpButtonVisible: Bool {
        showsJumpButton && !isPaused && isAwayFromBottom && (isScrolling || !isFollowing)
    }

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .overlay(alignment: .bottom) {
                ZStack {
                    if isJumpButtonVisible {
                        JumpToBottomButton(action: jumpToBottom)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .padding(.bottom, 12)
                .animation(.snappy, value: isJumpButtonVisible)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                FollowMetrics(geometry).distance > Self.stickDistance
            } action: { _, isAway in
                isAwayFromBottom = isAway
            }
            .onScrollPhaseChange { oldPhase, newPhase, context in
                // The first callback after appearing reports idle -> idle, which is not a scroll.
                guard oldPhase != newPhase else { return }
                let metrics = FollowMetrics(context.geometry)
                if newPhase == .interacting {
                    // Touching the list takes over from the jump button.
                    isJumping = false
                }
                if oldPhase == .idle {
                    isScrolling = true
                    bottomHeight = isFollowing ? metrics.contentHeight : nil
                } else if newPhase == .idle {
                    isScrolling = false
                    // Output that arrived while scrolling at the bottom does not count as scrolling away.
                    let grown = bottomHeight.map { max(metrics.contentHeight - $0, 0) } ?? 0
                    // A jump follows even if the bottom moved during its animation (new output, estimated rows).
                    isFollowing = isJumping || metrics.distance - grown <= Self.stickDistance
                    isJumping = false
                    if isFollowing && !isPaused && metrics.distance > 0.5 {
                        position.scrollTo(edge: .bottom)
                    }
                }
            }
            .onScrollGeometryChange(for: FollowMetrics.self, of: FollowMetrics.init) { old, new in
                if isScrolling {
                    if new.distance <= Self.stickDistance {
                        bottomHeight = new.contentHeight
                    }
                } else if isFollowing, !isPaused, new.distance > 0.5, !new.hasSameLayout(as: old) {
                    // Only new or resized content is followed: a pure offset change is a scroll just starting.
                    position.scrollTo(edge: .bottom)
                } else if !isFollowing, !isPaused, new.distance <= Self.stickDistance {
                    // Content that still fits, or a reader left at the bottom, follows what comes next.
                    isFollowing = true
                }
            }
            .onChange(of: userMessageCount) { oldCount, newCount in
                // Removed messages (e.g. a failed send) do not resume, nor does a message during a scroll.
                guard newCount > oldCount, !isScrolling, !isPaused else { return }
                isFollowing = true
                position.scrollTo(edge: .bottom)
            }
            .onChange(of: isPaused) { _, paused in
                // Pausing is taking over the scroll position, like scrolling away from the bottom.
                if paused {
                    isFollowing = false
                    isJumping = false
                }
            }
            .onChange(of: followRequests) {
                guard !isScrolling, !isPaused else { return }
                isFollowing = true
                position.scrollTo(edge: .bottom)
            }
    }

    private func jumpToBottom() {
        isFollowing = true
        isJumping = true
        withAnimation(.snappy) {
            position.scrollTo(edge: .bottom)
        }
    }
}

// Round glass button like the toolbar buttons, shown above the bottom edge (or composer) while away from the bottom.
private struct JumpToBottomButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(L10n.Thread.scrollToBottom)
    }
}

// The scroll geometry that following the latest content depends on.
private struct FollowMetrics: Equatable {
    let contentHeight: CGFloat
    let containerHeight: CGFloat
    let bottomInset: CGFloat
    // Distance left to the bottom; negative while the content is shorter than the visible area.
    let distance: CGFloat

    init(_ geometry: ScrollGeometry) {
        contentHeight = geometry.contentSize.height
        containerHeight = geometry.containerSize.height
        bottomInset = geometry.contentInsets.bottom
        distance = geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY
    }

    // False when the content or the visible area (e.g. keyboard, composer) changed size.
    func hasSameLayout(as other: FollowMetrics) -> Bool {
        contentHeight == other.contentHeight && containerHeight == other.containerHeight && bottomInset == other.bottomInset
    }
}

// Shown above the composer when the agent is waiting for an answer.
private struct AskBanner: View {
    @Environment(\.locale) private var locale
    let action: () -> Void

    var body: some View {
        let _ = locale
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble")
                Text(L10n.Ask.banner)
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 16)
            .frame(height: 42)
            .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

// Centered loading indicator matching the app's coral accent, device iconography, and text shimmer.
struct ConversationLoadingView: View {
    let icon: ConnectionIcon
    let desktopName: String
    let isConnected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    static func statusTitle(isConnected: Bool, desktopName: String) -> String {
        isConnected ? L10n.Thread.loadingMessagesTitle : L10n.Thread.loadingConnectingTitle(desktopName)
    }

    static func statusDetail(isConnected: Bool) -> String {
        isConnected ? L10n.Thread.loadingMessagesDetail : L10n.Thread.loadingWaitingDetail
    }

    private var statusTitle: String {
        Self.statusTitle(isConnected: isConnected, desktopName: desktopName)
    }

    private var statusDetail: String {
        Self.statusDetail(isConnected: isConnected)
    }

    var body: some View {
        let _ = locale
        VStack(spacing: 16) {
            emblem
            VStack(spacing: 5) {
                Text(statusTitle)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .modifier(Shimmer(isActive: true))
                Text(statusDetail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .animation(.easeInOut(duration: 0.2), value: isConnected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.Thread.loadingAccessibilityLabel(statusTitle, statusDetail))
    }

    @ViewBuilder
    private var emblem: some View {
        let ringStyle = StrokeStyle(lineWidth: 2, lineCap: .round)
        ZStack {
            Circle()
                .fill(Theme.userBubble)
                .frame(width: 56, height: 56)

            Circle()
                .stroke(Theme.accent.opacity(0.18), lineWidth: 2)
                .frame(width: 56, height: 56)

            if reduceMotion {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Theme.accent, style: ringStyle)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 56, height: 56)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 60)) { context in
                    let period = 1.15
                    let angle = (context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: period) / period) * 360
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(Theme.accent, style: ringStyle)
                        .rotationEffect(.degrees(angle - 90))
                        .frame(width: 56, height: 56)
                }
            }

            ConnectionIconImage(icon: icon, color: Theme.accent)
                .font(.system(size: 22, weight: .medium))
        }
        .accessibilityHidden(true)
    }
}

// Connection or load failure placeholder styled consistently with the home screen's empty states.
struct ThreadStatusPlaceholder: View {
    @Environment(\.locale) private var locale
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    static func connectionMessage(_ rawError: String, desktopName: String) -> String {
        let trimmed = rawError.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty
            || trimmed == L10n.ErrorMessage.notConnected
            || trimmed == L10n.ErrorMessage.cannotConnect
        {
            return L10n.Thread.cannotConnectDetail(desktopName)
        }
        if trimmed.contains(desktopName) {
            return trimmed
        }
        return L10n.Common.errorWithDetail(desktopName, trimmed)
    }

    var body: some View {
        let _ = locale
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.secondary, Color.clear)
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
    }
}
