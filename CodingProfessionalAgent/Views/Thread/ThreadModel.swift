import Foundation
import Observation

// Sub-agent whose conversation a thread model shows instead of a top-level conversation.
struct SubAgentReference: Hashable, Sendable {
    let parentSessionId: String
    let agentId: String
}

// An edited prompt the desktop accepted but ended without running, e.g. because its preflight failed.
struct FailedEdit: Identifiable, Equatable {
    let id = UUID()
    let entry: ConversationEntry
}

// Timing parameters for waiting on a waking or reconnecting desktop before showing an offline error.
struct ConnectionGraceConfiguration: Sendable {
    var failureGrace: Duration = .seconds(6)
    var connectingTimeout: Duration = .seconds(10)
    var retryInterval: Duration = .seconds(2.5)
    var pollInterval: Duration = .milliseconds(100)

    static let standard = ConnectionGraceConfiguration()
}

// Live state of one conversation: the persisted entries plus streamed updates from the desktop.
@MainActor
@Observable
final class ThreadModel {
    let client: DesktopClient
    let sessionId: String
    // Set for a sub-agent conversation, which runs inside its parent's run.
    let subAgent: SubAgentReference?
    private(set) var entries: [ConversationEntry] = []
    // Latest live details of running tools by normalized call id, e.g. nested calls of a code mode cell.
    private(set) var toolDetails: [String: JSONValue] = [:]
    private(set) var isLoading = true
    private(set) var isWaitingForConnection = false
    private(set) var connectionError: String?
    private(set) var loadError: String?
    private(set) var runningToolCallIds: Set<String> = []
    private(set) var lastRunError: String?
    private(set) var isDeleted = false
    private(set) var askRequest: AskRequest?
    // Set when the user stops an active run, mirroring `stoppedSessionId` in desktop `ComposerContainer`.
    private(set) var wasStopped = false
    private(set) var failedEdit: FailedEdit?

    private static let restartStreamingError = "Response stream ended prematurely before completion"
    private static let interruptedByRestartError = "Interrupted by session restart"

    @ObservationIgnored private let graceConfig: ConnectionGraceConfiguration
    @ObservationIgnored private var listenerToken: UUID?
    @ObservationIgnored private var reloadDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var reloadExecutionTask: Task<Void, Never>?
    @ObservationIgnored private var isReloading = false
    @ObservationIgnored private var reloadRequested = false
    @ObservationIgnored private var pendingAuthoritativeReload = false
    @ObservationIgnored private var hasLoadedEntries = false
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var graceStartTime: ContinuousClock.Instant?
    // Entries added locally or from the stream that the desktop has not persisted yet.
    @ObservationIgnored private var unpersistedIds: Set<String> = []
    // Discarded partial assistant entries removed when resuming, hidden until the desktop snapshot drops them.
    @ObservationIgnored private var removedEntryIds: Set<String> = []
    // Entries updated while a snapshot request is in flight; they are newer than that snapshot.
    @ObservationIgnored private var updatedDuringReload: Set<String>?
    @ObservationIgnored private var pendingEdit: PendingEdit?
    @ObservationIgnored private var pendingEditExpiry: Task<Void, Never>?
    // Entries dropped by edits given up on, by prompt id, in case the desktop still runs them.
    @ObservationIgnored private var abandonedEdits: [String: Set<String>] = [:]
    @ObservationIgnored private var askTask: Task<Void, Never>?
    @ObservationIgnored private var askMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var askPollingToolCallId: String?
    // Bumped whenever ask state changes so in-flight lookups cannot resurrect stale questions.
    @ObservationIgnored private var askLookupSequence = 0
    // Whether the sub-agent was running at its last state change.
    @ObservationIgnored private var subAgentWasRunning = false

    // Edit sent to the desktop. Until a snapshot shows it stored, snapshots may predate it, so the edit
    // is laid over them: the edited prompt and none of the dropped entries.
    private struct PendingEdit {
        let id = UUID()
        // The edited prompt; the desktop's version once its run started.
        var entry: ConversationEntry
        // Entries after the prompt, which the edit drops.
        let droppedIds: Set<String>
        // Set by the prompt's `user-entry` event, which the desktop sends after dropping the entries.
        var isStarted = false

        // The snapshot holds the edited prompt and none of the dropped entries.
        func isStored(in snapshot: [ConversationEntry]) -> Bool {
            guard let stored = snapshot.first(where: { $0.id == entry.id }),
                  stored.text == entry.text,
                  (stored.skillReferences ?? []) == (entry.skillReferences ?? [])
            else {
                return false
            }
            return !snapshot.contains { droppedIds.contains($0.id) }
        }
    }

    // Same wait as the optimistic run placeholder: an edit that has not started by then is left to the
    // snapshots (e.g. its outcome was missed), which show the desktop's history as it is.
    private static let pendingEditTimeout: Duration = .seconds(20)

    init(
        client: DesktopClient,
        sessionId: String,
        subAgent: SubAgentReference? = nil,
        graceConfiguration: ConnectionGraceConfiguration = .standard
    ) {
        self.client = client
        self.sessionId = sessionId
        self.subAgent = subAgent
        self.graceConfig = graceConfiguration
        if !client.isConnected {
            if !client.connection.isEnabled {
                isLoading = false
                connectionError = L10n.ErrorMessage.connectionDisabled
            } else if client.isTerminalFailure, case .failed(let message) = client.state {
                isLoading = false
                connectionError = message
            } else {
                isWaitingForConnection = true
                isLoading = true
            }
        }
    }

    var session: RemoteSession? {
        client.session(id: sessionId)
    }

    var subAgentRecord: SubAgentRecord? {
        subAgent.flatMap { client.subAgent(parentSessionId: $0.parentSessionId, id: $0.agentId) }
    }

    var isRunning: Bool {
        if subAgent != nil {
            return subAgentRecord?.isInProgress ?? false
        }
        return client.isRunning(sessionId)
    }

    // True while the desktop reports it is synthesizing an enhanced system prompt for this run.
    var isBuildingSystemPrompt: Bool {
        subAgent == nil && client.isBuildingSystemPrompt(sessionId)
    }

    // Sub-agents launched by this conversation.
    var subAgents: [SubAgentRecord] {
        client.subAgents(parentSessionId: sessionId)
    }

    // Whether the conversation is paused/interrupted and can be continued (desktop `canResume`).
    var canResume: Bool {
        guard subAgent == nil, !isRunning, !isTurnCompleted else { return false }
        return isSessionResumable || wasStopped
    }

    // Mirrors desktop `isTurnCompleted`: true when the latest turn finished cleanly with no pending tools.
    private var isTurnCompleted: Bool {
        guard !isRunning else { return false }
        guard let lastIndex = entries.lastIndex(where: { $0.kind != .compaction && $0.kind != .unknown }) else {
            return false
        }
        let last = entries[lastIndex]
        guard last.kind == .assistant else { return false }
        if last.status == "streaming" || last.status == "aborted" || last.status == "error" || last.interrupted {
            return false
        }
        if last.stopReason == "aborted" || last.stopReason == "error" || last.stopReason == "pending" || last.stopReason == "toolUse" {
            return false
        }
        if last.errorMessage == Self.restartStreamingError || last.errorMessage == Self.interruptedByRestartError {
            return false
        }
        let toolCallIds = Self.toolCallIds(in: last)
        if !toolCallIds.isEmpty {
            let results = Self.followingResultIds(in: entries, after: lastIndex)
            if toolCallIds.contains(where: { !results.contains($0) }) {
                return false
            }
        }
        return last.status == "done"
    }

    // Mirrors desktop `isSessionResumable` in `unfinished.ts`.
    private var isSessionResumable: Bool {
        guard !entries.isEmpty else { return false }
        if subAgents.contains(where: \.isInProgress) {
            return true
        }
        guard let lastIndex = entries.lastIndex(where: { $0.kind != .compaction && $0.kind != .unknown }) else {
            return false
        }
        let last = entries[lastIndex]
        switch last.kind {
        case .user, .toolResult:
            return true
        case .assistant:
            if last.errorMessage == Self.restartStreamingError || last.errorMessage == Self.interruptedByRestartError {
                return true
            }
            if last.status == "aborted" || last.stopReason == "aborted" || last.interrupted {
                return true
            }
            if last.status == "streaming" || last.stopReason == "pending" {
                return true
            }
            let toolCallIds = Self.toolCallIds(in: last)
            if last.stopReason == "toolUse" || !toolCallIds.isEmpty {
                let results = Self.followingResultIds(in: entries, after: lastIndex)
                if toolCallIds.contains(where: { !results.contains($0) }) || toolCallIds.isEmpty {
                    return true
                }
            }
            if last.status == "error" || last.stopReason == "error" {
                return false
            }
            return last.status != "done"
        case .compaction, .unknown:
            return false
        }
    }

    private var isActive: Bool {
        listenerToken != nil
    }

    // Fraction of the model context window used by the latest assistant turn.
    var contextUsage: Double? {
        let model = client.model(id: session?.modelId) ?? client.model(id: client.defaults.modelId)
        guard let model else { return nil }
        // The max context set in the desktop model settings wins over the catalog default.
        let contextWindow = client.defaults.contextWindows[model.id] ?? model.contextWindow
        guard contextWindow > 0 else { return nil }
        guard let usage = entries.last(where: { $0.kind == .assistant && ($0.usage?.totalTokens ?? 0) > 0 })?.usage else {
            return nil
        }
        return min(usage.totalTokens / contextWindow, 1)
    }

    func activate() {
        guard listenerToken == nil else { return }
        listenerToken = client.addListener { [weak self] event in
            self?.handle(event)
        }
        subAgentWasRunning = isRunning
        if !hasLoadedEntries {
            beginConnectionOrReload(wakeIfNeeded: true)
        } else {
            scheduleReload(delay: 0, authoritative: true)
        }
        // Questions are only asked by top-level runs.
        if subAgent == nil {
            startAskMonitor()
        }
    }

    func deactivate() {
        if let listenerToken {
            client.removeListener(listenerToken)
        }
        listenerToken = nil
        cancelGraceWindow()
        reloadDebounceTask?.cancel()
        reloadDebounceTask = nil
        reloadExecutionTask?.cancel()
        reloadExecutionTask = nil
        askMonitorTask?.cancel()
        askMonitorTask = nil
        stopAskPolling()
    }

    // MARK: - Actions

    func send(
        _ text: String,
        skillReferences: [SkillReference],
        images: [PromptImage] = []
    ) async throws {
        wasStopped = false
        let entryId = UUID().uuidString.lowercased()
        let now = Date().milliseconds
        let session = self.session
        upsert(ConversationEntry(
            localUserEntryId: entryId,
            text: text,
            createdAt: now,
            pendingStatus: isRunning ? FollowUpStatus.pending.rawValue : nil,
            skillReferences: skillReferences,
            images: images
        ))
        let request = DelegateRunRequest(
            sessionId: sessionId,
            text: text,
            projectId: session?.projectId,
            branch: session?.branch,
            modelId: session?.modelId,
            reasoningEffort: session?.reasoningEffort,
            speed: session?.speed,
            userEntryId: entryId,
            userEntryCreatedAt: now,
            skillReferences: skillReferences,
            images: images
        )
        do {
            try await client.delegateRun(request)
        } catch {
            entries.removeAll { $0.id == entryId }
            unpersistedIds.remove(entryId)
            throw error
        }
    }

    // Resends an earlier prompt with new text, like the desktop's message editing: the desktop drops
    // everything after the prompt and runs again from it. Only offered while no run is active.
    // The desktop only queues the request here; `failedEdit` reports an edit whose run never started.
    func edit(entryId: String, text: String, skillReferences: [SkillReference]) async throws {
        guard subAgent == nil, !isRunning else {
            throw DesktopClientError.remote(L10n.ErrorMessage.editWhileRunning)
        }
        guard let index = entries.firstIndex(where: { $0.id == entryId && $0.kind == .user }) else {
            throw DesktopClientError.remote(L10n.ErrorMessage.editMessageGone)
        }
        let now = Date().milliseconds
        let session = self.session
        let previousEntries = entries
        let previousUnpersisted = unpersistedIds
        let previousEdit = pendingEdit
        wasStopped = false
        lastRunError = nil
        failedEdit = nil
        // Shown at once, since the desktop may report the run before the request returns.
        reloadDebounceTask?.cancel()
        reloadExecutionTask?.cancel()
        pendingEdit = PendingEdit(
            entry: entries[index].replacingText(text, skillReferences: skillReferences, createdAt: now),
            // An earlier edit may still be pending, with entries a snapshot can bring back.
            droppedIds: Set(entries[(index + 1)...].map(\.id)).union(previousEdit?.droppedIds ?? [])
        )
        applyPendingEdit()
        do {
            try await client.delegateRun(DelegateRunRequest(
                sessionId: sessionId,
                text: text,
                projectId: session?.projectId,
                branch: session?.branch,
                modelId: session?.modelId,
                reasoningEffort: session?.reasoningEffort,
                speed: session?.speed,
                userEntryId: entryId,
                userEntryCreatedAt: now,
                skillReferences: skillReferences,
                editMessageId: entryId,
                requestId: "edit-\(UUID().uuidString.lowercased())"
            ))
        } catch {
            // The request may still have arrived: an edit the desktop already reported on stays.
            if pendingEdit?.isStarted == false {
                pendingEdit = previousEdit
                entries = previousEntries
                unpersistedIds = previousUnpersisted
                throw error
            }
            return
        }
        expirePendingEditIfNotStarted()
    }

    func stop() async throws {
        wasStopped = true
        do {
            try await client.abortRun(sessionId: sessionId)
            markInFlightAssistantAborted()
        } catch {
            wasStopped = false
            throw error
        }
    }

    func resume() async throws {
        let previousEntries = entries
        let previousUnpersisted = unpersistedIds
        let previousRemoved = removedEntryIds
        let previousStopped = wasStopped
        wasStopped = false
        reloadDebounceTask?.cancel()
        reloadExecutionTask?.cancel()
        prepareEntriesForResume()
        do {
            try await client.resumeSession(id: sessionId)
        } catch {
            entries = previousEntries
            unpersistedIds = previousUnpersisted
            removedEntryIds = previousRemoved
            wasStopped = previousStopped
            throw error
        }
    }

    func refresh() {
        if !client.isConnected && !hasLoadedEntries {
            retryConnection()
            return
        }
        loadError = nil
        if !hasLoadedEntries {
            isLoading = true
        }
        scheduleReload(delay: 0, authoritative: true)
    }

    func retryConnection() {
        cancelGraceWindow()
        graceStartTime = ContinuousClock.now
        connectionError = nil
        loadError = nil
        beginConnectionOrReload(wakeIfNeeded: true)
    }

    func handleExternalNavigation() {
        guard !hasLoadedEntries else {
            if client.isConnected {
                scheduleReload(delay: 0, authoritative: true)
            } else if client.connection.isEnabled {
                client.wake()
            }
            return
        }
        retryConnection()
    }

    func answerAsk(_ decision: AskDecision) async throws {
        guard let request = askRequest else { return }
        try await client.submitAsk(sessionId: sessionId, toolCallId: request.toolCallId, decision: decision)
        if askRequest?.id == request.id {
            clearAsk()
        }
    }

    // Returns whether the desktop confirmed that the auto-selection countdown stopped.
    func cancelAskCountdown() async -> Bool {
        guard let request = askRequest else { return false }
        guard request.countdownDeadline != nil else { return true }
        guard let confirmed = try? await client.cancelAskCountdown(sessionId: sessionId, toolCallId: request.toolCallId),
              confirmed
        else {
            return false
        }
        if askRequest?.id == request.id {
            askRequest?.countdownDeadline = nil
        }
        return true
    }

    // MARK: - Loading

    private func beginConnectionOrReload(wakeIfNeeded: Bool) {
        guard client.connection.isEnabled else {
            finishGraceWithConnectionError(L10n.ErrorMessage.connectionDisabled)
            return
        }
        if client.isConnected {
            cancelGraceWindow()
            isWaitingForConnection = false
            connectionError = nil
            loadError = nil
            if !hasLoadedEntries {
                isLoading = true
            }
            scheduleReload(delay: 0, authoritative: true)
            return
        }
        if client.isTerminalFailure, case .failed(let message) = client.state {
            finishGraceWithConnectionError(message)
            return
        }
        if wakeIfNeeded {
            client.wake()
            if client.isConnected {
                cancelGraceWindow()
                isWaitingForConnection = false
                connectionError = nil
                loadError = nil
                if !hasLoadedEntries {
                    isLoading = true
                }
                scheduleReload(delay: 0, authoritative: true)
                return
            }
            if client.isTerminalFailure, case .failed(let message) = client.state {
                finishGraceWithConnectionError(message)
                return
            }
        }
        startGraceWindow(resetClock: graceStartTime == nil)
    }

    private func startGraceWindow(resetClock: Bool) {
        let clock = ContinuousClock()
        if resetClock || graceStartTime == nil {
            graceStartTime = clock.now
        }
        connectionError = nil
        loadError = nil
        isWaitingForConnection = true
        isLoading = true
        guard graceTask == nil else { return }
        let pollInterval = graceConfig.pollInterval
        graceTask = Task { [weak self] in
            guard let self else { return }
            var lastWakeAttempt = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, self.isActive, !self.hasLoadedEntries else { return }
                if self.client.isConnected {
                    self.beginConnectionOrReload(wakeIfNeeded: false)
                    return
                }
                if !self.client.connection.isEnabled {
                    self.finishGraceWithConnectionError(L10n.ErrorMessage.connectionDisabled)
                    return
                }
                if self.client.isTerminalFailure, case .failed(let message) = self.client.state {
                    self.finishGraceWithConnectionError(message)
                    return
                }
                let start = self.graceStartTime ?? clock.now
                let elapsed = clock.now - start
                switch self.client.state {
                case .failed(let message):
                    if elapsed >= self.graceConfig.failureGrace {
                        self.finishGraceWithConnectionError(message)
                        return
                    }
                    if clock.now - lastWakeAttempt >= self.graceConfig.retryInterval {
                        lastWakeAttempt = clock.now
                        self.client.wake()
                    }
                case .connecting, .disconnected:
                    if elapsed >= self.graceConfig.connectingTimeout {
                        self.finishGraceWithConnectionError(L10n.ErrorMessage.threadGraceTimedOut)
                        return
                    }
                    if clock.now - lastWakeAttempt >= self.graceConfig.retryInterval {
                        lastWakeAttempt = clock.now
                        self.client.wake()
                    }
                case .connected:
                    self.beginConnectionOrReload(wakeIfNeeded: false)
                    return
                }
            }
        }
    }

    private func cancelGraceWindow() {
        graceTask?.cancel()
        graceTask = nil
    }

    private func finishGraceWithConnectionError(_ message: String) {
        cancelGraceWindow()
        isWaitingForConnection = false
        isLoading = false
        loadError = nil
        connectionError = message
    }

    private func handleClientStateChange() {
        if client.isConnected {
            cancelGraceWindow()
            isWaitingForConnection = false
            connectionError = nil
            loadError = nil
            if !hasLoadedEntries {
                isLoading = true
            }
            scheduleReload(delay: 0, authoritative: true)
            return
        }
        guard !hasLoadedEntries else { return }
        if !client.connection.isEnabled {
            finishGraceWithConnectionError(L10n.ErrorMessage.connectionDisabled)
            return
        }
        if client.isTerminalFailure, case .failed(let message) = client.state {
            finishGraceWithConnectionError(message)
            return
        }
        if case .failed(let message) = client.state {
            if let start = graceStartTime, ContinuousClock.now - start >= graceConfig.failureGrace {
                finishGraceWithConnectionError(message)
            } else if connectionError == nil {
                startGraceWindow(resetClock: false)
            }
            return
        }
        if connectionError == nil {
            startGraceWindow(resetClock: false)
        }
    }

    private static func isConnectionTransportError(_ error: Error) -> Bool {
        if let clientError = error as? DesktopClientError {
            switch clientError {
            case .notConnected, .timeout, .tunnelServerOffline, .tunnelServerDisconnected:
                return true
            case .invalidAddress, .unauthorized, .http, .remote:
                return false
            }
        }
        if error is URLError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain || nsError.domain == NSPOSIXErrorDomain
    }

    private func scheduleReload(delay: Double = 0.3, authoritative: Bool) {
        pendingAuthoritativeReload = pendingAuthoritativeReload || authoritative
        reloadDebounceTask?.cancel()
        if delay <= 0 {
            reloadDebounceTask = nil
            startReloadExecution()
            return
        }
        reloadDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.startReloadExecution()
        }
    }

    private func startReloadExecution() {
        reloadRequested = true
        guard !isReloading else { return }
        reloadExecutionTask = Task { [weak self] in
            await self?.performReloads()
        }
    }

    // Serializes reloads so an older snapshot never lands after a newer one.
    private func performReloads() async {
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }
        while reloadRequested && !Task.isCancelled {
            reloadRequested = false
            let authoritative = pendingAuthoritativeReload
            pendingAuthoritativeReload = false
            await reload(authoritative: authoritative)
        }
    }

    private func reload(authoritative: Bool) async {
        guard client.isConnected else {
            if !hasLoadedEntries {
                beginConnectionOrReload(wakeIfNeeded: false)
            } else {
                isLoading = false
            }
            return
        }
        if !hasLoadedEntries {
            isLoading = true
        }
        updatedDuringReload = []
        do {
            // A sub-agent's own state lives with its parent and may have changed while disconnected.
            if let subAgent, authoritative {
                try? await client.refreshSubAgents(parentSessionId: subAgent.parentSessionId)
            }
            let rawPersisted = try await client.loadEntries(sessionId: sessionId)
            let rawPersistedIds = Set(rawPersisted.map(\.id))
            removedEntryIds.formIntersection(rawPersistedIds)
            let persisted = rawPersisted.filter { !removedEntryIds.contains($0.id) }
            let live = updatedDuringReload ?? []
            updatedDuringReload = nil
            let persistedIds = Set(persisted.map(\.id))
            var current: [String: ConversationEntry] = [:]
            for entry in entries {
                current[entry.id] = entry
            }
            let running = isRunning
            var merged = persisted.map { stored in
                guard let local = current[stored.id] else { return stored }
                if live.contains(stored.id) { return local }
                // The store strips pendingStatus. A matching desktop timestamp still represents
                // the waiting entry; activation publishes a new timestamp and a user-entry event.
                if running, local.createdAt == stored.createdAt,
                   local.pendingStatus == FollowUpStatus.queue.rawValue || local.pendingStatus == FollowUpStatus.steer.rawValue {
                    return local
                }
                return stored
            }
            let pendingIds = Set(entries.filter { $0.pendingStatus != nil }.map(\.id))
            // Wait for a follow-up to be stored while running, but do not retain it as normal
            // history after the desktop is idle. Preserve other live entries after a run ends.
            let keptIds = (authoritative ? live : unpersistedIds.subtracting(pendingIds).union(live))
                .union(running ? pendingIds : [])
            merged += entries.filter { keptIds.contains($0.id) && !persistedIds.contains($0.id) }
            entries = merged
            unpersistedIds = keptIds.subtracting(persistedIds)
            if pendingEdit?.isStored(in: rawPersisted) == true {
                pendingEdit = nil
            }
            applyPendingEdit()
            hasLoadedEntries = true
            connectionError = nil
            loadError = nil
            isWaitingForConnection = false
            cancelGraceWindow()
            pruneFinishedTools()
        } catch {
            updatedDuringReload = nil
            if Task.isCancelled {
                return
            }
            if !hasLoadedEntries && (!client.isConnected || Self.isConnectionTransportError(error)) {
                if client.isConnected {
                    client.wake()
                }
                startGraceWindow(resetClock: false)
                return
            }
            if entries.isEmpty {
                loadError = error.localizedDescription
            }
        }
        isLoading = false
        if subAgent == nil {
            await refreshAsk()
        }
    }

    // Events missed while inactive can leave finished tools marked as running.
    private func pruneFinishedTools() {
        let finished = Set(entries.compactMap { entry in
            entry.kind == .toolResult ? entry.toolCallId.map(ToolActivity.normalizedId) : nil
        })
        runningToolCallIds = runningToolCallIds.filter { !finished.contains(ToolActivity.normalizedId($0)) }
        toolDetails = isRunning ? toolDetails.filter { !finished.contains($0.key) } : [:]
        if subAgent != nil {
            subAgentWasRunning = isRunning
        }
    }

    // MARK: - Events

    private func handle(_ event: DesktopEvent) {
        let eventSessionId = event.payload["sessionId"]?.stringValue
        switch event.kind {
        case "session:stream-event":
            guard eventSessionId == sessionId, let runEvent = event.payload["event"] else { return }
            apply(runEvent)
        case "session:entries-updated":
            // While running the stream is authoritative; reconcile once the run is idle.
            guard eventSessionId == sessionId, !isRunning else { return }
            scheduleReload(authoritative: true)
        case "session:run-status":
            guard eventSessionId == sessionId, event.payload["status"]?.stringValue == "idle" else { return }
            if let pendingEdit, !pendingEdit.isStarted {
                // The desktop ended without running the edit; the reload below shows its history.
                self.pendingEdit = nil
                failedEdit = FailedEdit(entry: pendingEdit.entry)
            }
            runningToolCallIds.removeAll()
            toolDetails.removeAll()
            clearAsk()
            markInFlightAssistantAborted()
            scheduleReload(delay: 0.8, authoritative: false)
        case "session:subagent-state":
            // A sub-agent conversation is final once its run ends; reconcile with the stored entries.
            guard subAgent != nil else { return }
            let running = isRunning
            if subAgentWasRunning && !running {
                runningToolCallIds.removeAll()
                toolDetails.removeAll()
                scheduleReload(delay: 0.8, authoritative: false)
            }
            subAgentWasRunning = running
        case "session:deleted":
            if eventSessionId == sessionId {
                isDeleted = true
            }
        case "ask:state-changed":
            // Defensive: current desktop builds only deliver this to capability subscribers.
            guard eventSessionId == sessionId else { return }
            askLookupSequence += 1
            askRequest = try? event.payload["request"]?.decode(AskRequest.self)
        case DesktopEvent.stateChanged:
            handleClientStateChange()
        case DesktopEvent.synced:
            scheduleReload(delay: 0, authoritative: true)
        default:
            break
        }
    }

    private func apply(_ event: JSONValue) {
        // Nested sub-agent events belong to other sessions.
        if event["nested"]?.boolValue == true || event["parentToolCallId"]?.stringValue != nil {
            return
        }
        switch event["type"]?.stringValue {
        case "follow-up-pending":
            guard let id = event["userEntryId"]?.stringValue,
                  let status = event["pendingStatus"]?.stringValue,
                  status == FollowUpStatus.queue.rawValue || status == FollowUpStatus.steer.rawValue,
                  let createdAt = event["createdAt"]?.doubleValue,
                  var entry = entries.first(where: { $0.id == id && $0.kind == .user })
            else { return }
            entry.pendingStatus = status
            entry.createdAt = createdAt
            upsert(entry)
        case "follow-up-removed":
            guard let id = event["userEntryId"]?.stringValue, !id.isEmpty else { return }
            removedEntryIds.insert(id)
            unpersistedIds.remove(id)
            entries.removeAll { $0.id == id && $0.kind == .user }
        case "user-entry", "assistant-start", "assistant-update", "assistant-end", "compaction-end":
            if let entry = try? event["entry"]?.decode(ConversationEntry.self) {
                upsert(entry)
            }
            if event["type"]?.stringValue == "user-entry", let entryId = event["entry"]?["id"]?.stringValue {
                if var edit = pendingEdit, edit.entry.id == entryId {
                    // The desktop dropped the later entries and runs the edit; it may not have stored it yet.
                    if let entry = entries.first(where: { $0.id == entryId }) {
                        edit.entry = entry
                    }
                    edit.isStarted = true
                    pendingEdit = edit
                    applyPendingEdit()
                } else if let droppedIds = abandonedEdits.removeValue(forKey: entryId) {
                    // A late start of an edit given up on: the desktop has dropped these entries after all,
                    // while a snapshot in flight may still hold them.
                    if pendingEdit == nil, let entry = entries.first(where: { $0.id == entryId }) {
                        pendingEdit = PendingEdit(entry: entry, droppedIds: droppedIds, isStarted: true)
                    }
                    entries.removeAll { droppedIds.contains($0.id) }
                    unpersistedIds.subtract(droppedIds)
                }
            }
        case "tool-start":
            guard let toolCallId = event["toolCallId"]?.stringValue else { return }
            runningToolCallIds.insert(toolCallId)
            if event["toolName"]?.stringValue == "ask" && subAgent == nil {
                pollAsk(toolCallId: toolCallId)
            }
        case "tool-update":
            // Code mode cells report their nested calls (e.g. sub-agent launches) as they run.
            guard let toolCallId = event["toolCallId"]?.stringValue,
                  let details = event["result"]?["details"],
                  details["nestedTools"]?.arrayValue != nil
            else {
                return
            }
            toolDetails[ToolActivity.normalizedId(toolCallId)] = details
        case "tool-display-update":
            // A yielded code mode cell keeps reporting nested calls after its result was recorded.
            guard let toolCallId = event["toolCallId"]?.stringValue,
                  let update = event["displayMetadata"]?.objectValue
            else {
                return
            }
            let key = ToolActivity.normalizedId(toolCallId)
            guard var entry = entries.last(where: { $0.kind == .toolResult && $0.toolCallId.map(ToolActivity.normalizedId) == key }) else { return }
            entry.displayMetadata = .object((entry.displayMetadata?.objectValue ?? [:]).merging(update) { $1 })
            upsert(entry)
        case "tool-end":
            guard let toolCallId = event["toolCallId"]?.stringValue else { return }
            runningToolCallIds.remove(toolCallId)
            // The recorded result carries the final nested calls from now on.
            toolDetails[ToolActivity.normalizedId(toolCallId)] = nil
            if let entry = try? event["entry"]?.decode(ConversationEntry.self) {
                upsert(entry)
            }
            if askRequest?.toolCallId == toolCallId || askPollingToolCallId == toolCallId {
                clearAsk()
            }
        case "agent-start":
            lastRunError = nil
            wasStopped = false
            cleanUnfinishedAssistantEntry()
        case "error":
            lastRunError = event["message"]?.stringValue
        default:
            break
        }
    }

    // Gives up on an edit the desktop has not started in time (still queued, or its outcome was missed):
    // the desktop's history is shown as it is.
    private func expirePendingEditIfNotStarted() {
        pendingEditExpiry?.cancel()
        guard let id = pendingEdit?.id else { return }
        pendingEditExpiry = Task { [weak self] in
            try? await Task.sleep(for: Self.pendingEditTimeout)
            guard let self, !Task.isCancelled, let edit = pendingEdit, edit.id == id, !edit.isStarted else { return }
            pendingEdit = nil
            abandonedEdits[edit.entry.id, default: []].formUnion(edit.droppedIds)
            scheduleReload(delay: 0, authoritative: true)
        }
    }


    // Lays the pending edit over the entries: the edited prompt and none of the dropped entries.
    private func applyPendingEdit() {
        guard let pendingEdit else { return }
        entries.removeAll { pendingEdit.droppedIds.contains($0.id) }
        unpersistedIds.subtract(pendingEdit.droppedIds)
        if let index = entries.firstIndex(where: { $0.id == pendingEdit.entry.id }) {
            entries[index] = pendingEdit.entry
        }
    }

    private func upsert(_ entry: ConversationEntry) {
        unpersistedIds.insert(entry.id)
        updatedDuringReload?.insert(entry.id)
        if let index = entries.lastIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        if entry.kind == .user || entry.kind == .assistant || entry.kind == .compaction {
            connectionError = nil
            loadError = nil
            isWaitingForConnection = false
            cancelGraceWindow()
        }
    }

    // When a run stops without an `assistant-end` event (user abort), mark any assistant entry of
    // the active turn as aborted so the turn header and resume button update immediately before reload.
    private func markInFlightAssistantAborted() {
        let lastUserIndex = entries.lastIndex { $0.kind == .user && $0.pendingStatus == nil }
        guard let index = entries.lastIndex(where: { $0.kind == .assistant }),
              index > (lastUserIndex ?? -1)
        else {
            return
        }
        var target = entries[index]
        let now = Date().milliseconds
        if target.status == "streaming" {
            target.status = "aborted"
            target.stopReason = "aborted"
            target.completedAt = target.completedAt ?? now
            entries[index] = target
            updatedDuringReload?.insert(target.id)
        } else if wasStopped && !isTurnCompleted {
            target.completedAt = target.completedAt ?? now
            target.interrupted = true
            entries[index] = target
            updatedDuringReload?.insert(target.id)
        }
    }

    // Mirrors desktop `applyTurnPauseDelta` + `cleanUnfinishedEntries` when resuming a paused turn.
    private func prepareEntriesForResume() {
        if !entries.isEmpty {
            let targetIndex = entries.lastIndex { $0.kind == .user } ?? 0
            var stoppedAt: Double?
            for entry in entries[targetIndex...] {
                if let completed = entry.completedAt, completed.isFinite {
                    stoppedAt = max(stoppedAt ?? completed, completed)
                }
                if entry.createdAt.isFinite {
                    stoppedAt = max(stoppedAt ?? entry.createdAt, entry.createdAt)
                }
            }
            if let stoppedAt {
                let delta = max(0, Date().milliseconds - stoppedAt)
                if delta > 0 {
                    var target = entries[targetIndex]
                    let currentPaused = max(target.pausedMs ?? 0, 0)
                    target.pausedMs = currentPaused + delta
                    entries[targetIndex] = target
                    updatedDuringReload?.insert(target.id)
                }
            }
        }
        cleanUnfinishedAssistantEntry()
    }

    // Strips a dangling partial text assistant entry or normalizes one with tool calls (desktop `cleanUnfinishedEntries`).
    private func cleanUnfinishedAssistantEntry() {
        guard let last = entries.last, last.kind == .assistant else { return }
        let hasToolCalls = !Self.toolCallIds(in: last).isEmpty
        if hasToolCalls {
            if last.status != "done" || last.stopReason != "toolUse" {
                var updated = last
                updated.status = "done"
                updated.stopReason = "toolUse"
                entries[entries.count - 1] = updated
                updatedDuringReload?.insert(updated.id)
            }
        } else if last.status == "streaming"
            || last.stopReason == "pending"
            || last.status == "aborted"
            || last.stopReason == "aborted"
            || last.status != "done"
            || last.errorMessage == Self.restartStreamingError
            || last.errorMessage == Self.interruptedByRestartError
        {
            let removed = entries.removeLast()
            removedEntryIds.insert(removed.id)
            unpersistedIds.remove(removed.id)
            updatedDuringReload?.remove(removed.id)
        }
    }

    private static func toolCallIds(in entry: ConversationEntry) -> [String] {
        entry.content.compactMap { block in
            guard case .toolCall(let id, _, _) = block else { return nil }
            let normalized = ToolActivity.normalizedId(id)
            return normalized.isEmpty ? nil : normalized
        }
    }

    private static func followingResultIds(in entries: [ConversationEntry], after index: Int) -> Set<String> {
        guard index + 1 < entries.count else { return [] }
        return Set(entries[(index + 1)...].compactMap { entry in
            guard entry.kind == .toolResult, let id = entry.toolCallId else { return nil }
            let normalized = ToolActivity.normalizedId(id)
            return normalized.isEmpty ? nil : normalized
        })
    }

    // MARK: - Ask tool

    // Looks up the pending question, e.g. after opening the thread or reconnecting mid-run.
    private func refreshAsk() async {
        askLookupSequence += 1
        let sequence = askLookupSequence
        guard isRunning else {
            askRequest = nil
            return
        }
        guard let lookup = await lookUpAsk() else { return }
        guard sequence == askLookupSequence, isActive, isRunning else { return }
        askRequest = lookup.request
        if let request = lookup.request {
            runningToolCallIds.insert(request.toolCallId)
            pollAsk(toolCallId: request.toolCallId)
        }
    }

    // Ask events are not broadcast to Web clients, so poll while the ask tool runs:
    // quickly until the question is registered, then slowly to pick up answers from other clients.
    private func pollAsk(toolCallId: String) {
        guard isActive, askPollingToolCallId != toolCallId else { return }
        askTask?.cancel()
        askPollingToolCallId = toolCallId
        askTask = Task { [weak self] in
            var attempt = 0
            while true {
                guard let self, !Task.isCancelled else { return }
                guard runningToolCallIds.contains(toolCallId) else {
                    if askPollingToolCallId == toolCallId {
                        askPollingToolCallId = nil
                    }
                    return
                }
                askLookupSequence += 1
                let sequence = askLookupSequence
                if let lookup = await lookUpAsk(),
                   !Task.isCancelled,
                   sequence == askLookupSequence,
                   runningToolCallIds.contains(toolCallId)
                {
                    if let request = lookup.request, request.toolCallId != toolCallId {
                        // A newer question replaced this one (e.g. its tool-end was missed); follow it.
                        runningToolCallIds.remove(toolCallId)
                        askPollingToolCallId = nil
                        askRequest = request
                        runningToolCallIds.insert(request.toolCallId)
                        pollAsk(toolCallId: request.toolCallId)
                        return
                    } else if let request = lookup.request {
                        askRequest = request
                    } else if askRequest?.toolCallId == toolCallId {
                        // Answered or cancelled from another client.
                        askRequest = nil
                    }
                }
                attempt += 1
                try? await Task.sleep(for: .seconds(attempt < 6 && askRequest == nil ? 0.5 : 3))
            }
        }
    }

    // Low-frequency discovery while the page is open, for questions whose `tool-start` was missed
    // (e.g. opened or reconnected mid-run) or whose first lookup failed.
    private func startAskMonitor() {
        askMonitorTask?.cancel()
        askMonitorTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                guard isRunning, askRequest == nil, askPollingToolCallId == nil else { continue }
                askLookupSequence += 1
                let sequence = askLookupSequence
                guard let lookup = await lookUpAsk(), let request = lookup.request,
                      !Task.isCancelled, sequence == askLookupSequence, isActive, isRunning
                else {
                    continue
                }
                askRequest = request
                runningToolCallIds.insert(request.toolCallId)
                pollAsk(toolCallId: request.toolCallId)
            }
        }
    }

    private struct AskLookup {
        let request: AskRequest?
    }

    // Lets callers tell "no pending question" (request == nil) from a failed lookup (nil result).
    private func lookUpAsk() async -> AskLookup? {
        do {
            return AskLookup(request: try await client.askRequest(sessionId: sessionId))
        } catch {
            return nil
        }
    }

    private func stopAskPolling() {
        askTask?.cancel()
        askTask = nil
        askPollingToolCallId = nil
        askLookupSequence += 1
    }

    private func clearAsk() {
        stopAskPolling()
        askRequest = nil
    }
}
