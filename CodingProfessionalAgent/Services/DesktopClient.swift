import Foundation
import Observation

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

// Native event forwarded from the desktop, with its `data` JSON string already parsed.
struct DesktopEvent: Sendable {
    // Synthetic event emitted whenever `DesktopClient.state` changes.
    static let stateChanged = "client:state-changed"
    // Synthetic event emitted after every (re)connect resynchronization.
    static let synced = "client:synced"

    let kind: String
    let payload: JSONValue
}

enum DesktopClientError: LocalizedError {
    case invalidAddress
    case notConnected
    case unauthorized
    case http(Int)
    case timeout(String)
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "地址无效"
        case .notConnected: "桌面端未连接"
        case .unauthorized: "密码错误"
        case .http(let code): "服务器返回错误（\(code)）"
        case .timeout(let method): "请求超时（\(method)）"
        case .remote(let message): message
        }
    }
}

// Client for one desktop app, speaking the same protocol as the desktop's Web frontend:
// password login (`/api/auth/login`, session cookie), JSON RPC over the `/api/ws` WebSocket,
// and native events broadcast on the same socket.
@MainActor
@Observable
final class DesktopClient: Identifiable {
    private static let optimisticRunPrefix = "ios-pending-"

    let id: UUID
    private(set) var connection: DesktopConnection
    // True when `state` failed with a non-retriable credential or configuration error.
    private(set) var isTerminalFailure = false
    private(set) var state: ConnectionState = .disconnected {
        didSet {
            if state != oldValue {
                emit(DesktopEvent(kind: DesktopEvent.stateChanged, payload: .null))
            }
        }
    }
    private(set) var projects: [RemoteProject] = []
    private(set) var sessions: [RemoteSession] = []
    private(set) var activeRuns: [String: ActiveRun] = [:]
    private(set) var models: [RemoteModel] = []
    private(set) var defaults = RemoteDefaults()
    private(set) var hasSynced = false
    // Skills discovered per project folder ("" when no project is selected).
    private(set) var skillsByProjectPath: [String: [RemoteSkill]] = [:]
    // Skill usage counts by lowercased name, from the desktop's metrics (desktop `skillUsage`).
    private(set) var skillUsageCounts: [String: Int] = [:]
    // Sub-agents of the loaded conversations, by parent session id.
    private(set) var subAgentsByParent: [String: [SubAgentRecord]] = [:]

    @ObservationIgnored private let urlSession: URLSession
    @ObservationIgnored private let tunnelManager: TunnelClientManager
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var tunnelStream: TunnelWebSocketStream?
    @ObservationIgnored private var tunnelLeaseID: UUID?
    @ObservationIgnored private var tunnelObserverID: UUID?
    @ObservationIgnored private weak var activeTunnelSession: TunnelSession?
    @ObservationIgnored private var tunnelConfigKey = ""
    @ObservationIgnored private var cookie: String?
    @ObservationIgnored private var serverClientId: String?
    @ObservationIgnored private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    @ObservationIgnored private var callSequence = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var shouldRun = false
    @ObservationIgnored private var retryCount = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var listeners: [UUID: @MainActor (DesktopEvent) -> Void] = [:]
    @ObservationIgnored private var skillScans: [String: Int] = [:]
    @ObservationIgnored private var isLoadingSkillUsage = false
    @ObservationIgnored private var needsSkillUsageReload = false
    @ObservationIgnored private var lastSkillUsageFetch = Date.distantPast
    // Conversations on screen (view count by id) and pending read/unread metadata writes.
    private struct ReadSyncIntent: Equatable {
        var revision: Int
        var maxUpdatedAt: Double
        let runSequenceAtRead: Int
        var pendingServerUnread: UnreadState?
    }

    private struct PendingUnreadSync: Equatable {
        let state: UnreadState
        let preservedUpdatedAt: Double?
        let runSequence: Int
    }

    private struct ViewedWatermark: Equatable {
        let runSequence: Int
        var updatedAt: Double
        let capturedAt: Double
    }

    private struct FlushedAmbiguousRead: Equatable {
        let maxUpdatedAt: Double
        let fallbackUnread: UnreadState
        let viewEpoch: Int
        let capturedAt: Double
    }

    @ObservationIgnored private var viewedSessionIds: [String: Int] = [:]
    @ObservationIgnored private var sessionRunSequences: [String: Int] = [:]
    @ObservationIgnored private var sessionViewEpochs: [String: Int] = [:]
    @ObservationIgnored private var readSyncIntents: [String: ReadSyncIntent] = [:]
    @ObservationIgnored private var viewedWatermarks: [String: ViewedWatermark] = [:]
    @ObservationIgnored private var flushedAmbiguousReads: [String: FlushedAmbiguousRead] = [:]
    @ObservationIgnored private var readSyncCounter = 0
    @ObservationIgnored private var pendingReadIds: Set<String> = []
    @ObservationIgnored private var pendingUnreadStates: [String: PendingUnreadSync] = [:]
    @ObservationIgnored private var inFlightUnreadSyncSequences: [String: Int] = [:]
    @ObservationIgnored private var inFlightManualReadIds: Set<String> = []
    // Tail of the serialized project list writes.
    @ObservationIgnored private var projectWrites: Task<Void, Never>?
    // RPC messages waiting for a large one encoded in the background, so they are sent in call order.
    @ObservationIgnored private var sendQueue: Task<Void, Never>?
    @ObservationIgnored private var queuedSends = 0

    private struct TrackedRunOutcome {
        var runId: String
        var baselineUpdatedAt: Double = 0
        var latestEntryTimestamp: Double = 0
        var initialUnread: UnreadState = .read
        var sawCompletedTurn = false
        var sawError = false
        var wasAborted = false
        var sawAssistantActivity = false
        var sawCompaction = false
        var isExplicitCompaction = false
    }

    private struct PendingRunVerification {
        let runId: String
        let baselineUpdatedAt: Double
        let previousUnread: UnreadState
        let runSequence: Int
        let capturedAt: Double
        var viewEpochAtCapture: Int
        var sawCompletedTurn: Bool
        var sawError: Bool
        var unreadSuppressed: Bool
        var needsReconnectReconcile: Bool
        var capturedWhileRunning: Bool
        var remainingPersistenceRetries: Int
        var isResolving = false
        var retryRequestedWhileResolving = false
    }

    private struct AbortedRunRecord {
        let runId: String?
        let timestamp: Double
    }

    private static let maxPendingVerifications = 64
    private static let abortSuppressionWindowMs: Double = 30_000
    @ObservationIgnored private var runOutcomes: [String: TrackedRunOutcome] = [:]
    @ObservationIgnored private var pendingRunVerifications: [String: PendingRunVerification] = [:]
    @ObservationIgnored private var recentlyAbortedRuns: [String: AbortedRunRecord] = [:]

    init(connection: DesktopConnection, tunnelManager: TunnelClientManager = .shared) {
        self.id = connection.id
        self.connection = connection
        self.tunnelManager = tunnelManager
        let configuration = URLSessionConfiguration.ephemeral
        // The session cookie is managed manually so connections to the same host never share it.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        urlSession = URLSession(configuration: configuration)
    }

    var isConnected: Bool {
        state == .connected
    }

    // MARK: - Lifecycle

    func start() {
        shouldRun = true
        switch state {
        case .disconnected, .failed:
            connect()
        case .connecting, .connected:
            break
        }
    }

    func stop() {
        shouldRun = false
        generation += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        resetTurnOutcomeTracking()
        closeSocket()
        releaseTunnelLease()
        isTerminalFailure = false
        state = .disconnected
    }

    func update(connection newValue: DesktopConnection, credentialsChanged: Bool) {
        let endpointChanged = !connection.hasSameEndpoint(as: newValue)
        connection = newValue
        guard endpointChanged || credentialsChanged else { return }
        cookie = nil
        // Close any active virtual or direct stream BEFORE releasing/switching tunnel leases
        // so outbound ws_close frames flush cleanly over the active tunnel.
        closeSocket()
        if newValue.mode != .tunnel || !shouldRun {
            releaseTunnelLease()
        }
        if endpointChanged {
            // Data of the previous computer must not be shown or acted on.
            projects = []
            sessions = []
            activeRuns = [:]
            models = []
            defaults = RemoteDefaults()
            skillsByProjectPath = [:]
            skillUsageCounts = [:]
            subAgentsByParent = [:]
            hasSynced = false
            resetTurnOutcomeTracking()
        }
        if shouldRun {
            retryCount = 0
            connect()
        }
    }

    // Called when the app returns to the foreground; sockets are usually dead after suspension.
    func wake() {
        guard shouldRun else { return }
        if connection.mode == .tunnel {
            activeTunnelSession?.wake()
            if state == .connecting, reconnectTask == nil {
                return
            }
            guard tunnelStream != nil, state == .connected else {
                retryCount = 0
                connect()
                return
            }
            Task {
                await resync()
            }
            return
        }
        if state == .connecting, reconnectTask == nil {
            // A connection attempt is already in flight.
            return
        }
        guard let socket, state == .connected else {
            retryCount = 0
            connect()
            return
        }
        let current = generation
        socket.sendPing { error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == current, self.shouldRun else { return }
                self.connect()
            }
        }
        Task {
            await resync()
        }
    }

    private func connect() {
        generation += 1
        let current = generation
        reconnectTask?.cancel()
        reconnectTask = nil
        closeSocket()
        isTerminalFailure = false
        state = .connecting
        // Snapshot endpoint and credentials so a stale attempt never mixes them with newer ones.
        let endpoint = connection
        let password = KeychainStore.password(for: id) ?? ""
        let existingCookie = cookie

        if endpoint.mode == .tunnel {
            let apiKey = KeychainStore.tunnelAPIKey(for: id) ?? ""
            let session: TunnelSession
            do {
                session = try ensureTunnelSession(baseURL: endpoint.tunnelBaseURL, apiKey: apiKey)
            } catch {
                handleConnectFailure(error)
                return
            }
            Task {
                guard current == generation, shouldRun else { return }
                do {
                    var sessionCookie = try await Self.authenticateOverTunnel(
                        session: session,
                        serverUUID: endpoint.tunnelServerUUID,
                        password: password,
                        cookie: existingCookie
                    )
                    guard current == generation, shouldRun else { return }
                    cookie = sessionCookie
                    do {
                        try await openTunnelSocket(session: session, endpoint: endpoint, generation: current)
                    } catch DesktopClientError.http(401) {
                        // Session cookie expired between status check and WS upgrade; re-login once cleanly.
                        guard current == generation, shouldRun else { return }
                        cookie = nil
                        sessionCookie = try await Self.authenticateOverTunnel(
                            session: session,
                            serverUUID: endpoint.tunnelServerUUID,
                            password: password,
                            cookie: nil
                        )
                        guard current == generation, shouldRun else { return }
                        cookie = sessionCookie
                        try await openTunnelSocket(session: session, endpoint: endpoint, generation: current)
                    }
                } catch {
                    guard current == generation, shouldRun else { return }
                    if case DesktopClientError.http(401) = error {
                        cookie = nil
                    }
                    handleConnectFailure(error)
                }
            }
            return
        }

        releaseTunnelLease()
        Task {
            guard current == generation, shouldRun else { return }
            do {
                let sessionCookie = try await Self.authenticate(
                    endpoint: endpoint,
                    password: password,
                    cookie: existingCookie,
                    urlSession: urlSession
                )
                guard current == generation, shouldRun else { return }
                cookie = sessionCookie
                try openSocket(endpoint: endpoint, generation: current)
            } catch {
                guard current == generation, shouldRun else { return }
                handleConnectFailure(error)
            }
        }
    }

    // Returns the session cookie to use, logging in only when the desktop requires it.
    private static func authenticate(
        endpoint: DesktopConnection,
        password: String,
        cookie: String?,
        urlSession: URLSession
    ) async throws -> String? {
        guard let base = endpoint.httpBaseURL else {
            throw DesktopClientError.invalidAddress
        }

        var statusRequest = URLRequest(url: base.appending(path: "api/auth/status"))
        if let cookie {
            statusRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let (statusData, statusResponse) = try await urlSession.data(for: statusRequest)
        try checkHTTP(statusResponse)
        let status = JSONValue.parse(statusData)
        let required = status?["required"]?.boolValue ?? false
        let authenticated = status?["authenticated"]?.boolValue ?? false
        guard required else { return nil }
        guard !authenticated else { return cookie }

        var loginRequest = URLRequest(url: base.appending(path: "api/auth/login"))
        loginRequest.httpMethod = "POST"
        loginRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        loginRequest.httpBody = try JSONEncoder().encode(JSONValue.object(["password": .string(password)]))
        let (_, loginResponse) = try await urlSession.data(for: loginRequest)
        guard let http = loginResponse as? HTTPURLResponse else {
            throw DesktopClientError.http(0)
        }
        if http.statusCode == 401 {
            throw DesktopClientError.unauthorized
        }
        try checkHTTP(http)
        guard let header = http.value(forHTTPHeaderField: "Set-Cookie"),
              let pair = header.split(separator: ";").first
        else {
            return nil
        }
        return pair.trimmingCharacters(in: .whitespaces)
    }

    private func openSocket(endpoint: DesktopConnection, generation current: Int) throws {
        guard let url = endpoint.webSocketURL else {
            throw DesktopClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let cookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let task = urlSession.webSocketTask(with: request)
        // Session snapshots can be large.
        task.maximumMessageSize = 64 * 1024 * 1024
        socket = task
        task.resume()
        Task {
            await receiveLoop(task, generation: current)
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, generation current: Int) async {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                guard current == generation else { return }
                let status = (task.response as? HTTPURLResponse)?.statusCode
                let authRejected = status == 401 || task.closeCode.rawValue == 4401
                socketClosed(error: error, authRejected: authRejected)
                return
            }
            guard current == generation else { return }
            switch message {
            case .string(let text):
                ingestServerMessage(Data(text.utf8))
            case .data(let data):
                ingestServerMessage(data)
            @unknown default:
                break
            }
        }
    }

    private func ensureTunnelSession(baseURL: String, apiKey: String) throws -> TunnelSession {
        guard shouldRun else {
            throw DesktopClientError.notConnected
        }
        let normalizedEndpoint = try TunnelProtocol.parseEndpoint(baseURL).get()
        let normalizedKey = try TunnelProtocol.validateAPIKey(apiKey).get()
        let nextKey = "\(normalizedEndpoint.webSocketBaseURL)\n\(normalizedKey)"
        if let active = activeTunnelSession, tunnelLeaseID != nil, tunnelConfigKey == nextKey {
            return active
        }
        releaseTunnelLease()
        let (session, leaseID) = try tunnelManager.acquireSession(baseURL: baseURL, apiKey: apiKey)
        tunnelLeaseID = leaseID
        activeTunnelSession = session
        tunnelConfigKey = nextKey
        tunnelObserverID = session.addObserver { [weak self] in
            self?.handleTunnelSessionUpdate()
        }
        return session
    }

    private func releaseTunnelLease() {
        if let observerID = tunnelObserverID {
            activeTunnelSession?.removeObserver(observerID)
            tunnelObserverID = nil
        }
        if let leaseID = tunnelLeaseID {
            tunnelManager.releaseLease(leaseID)
            tunnelLeaseID = nil
        }
        activeTunnelSession = nil
        tunnelConfigKey = ""
    }

    private func handleTunnelSessionUpdate() {
        guard shouldRun, connection.mode == .tunnel, let session = activeTunnelSession else { return }
        if case .failed(let message) = session.phase {
            reconnectTask?.cancel()
            reconnectTask = nil
            closeSocket()
            isTerminalFailure = true
            state = .failed(message)
            return
        }
        if session.phase == .connected,
           session.isServerOnline(connection.tunnelServerUUID),
           state != .connected,
           state != .failed("密码错误"),
           !(state == .connecting && reconnectTask == nil)
        {
            retryCount = 0
            connect()
        }
    }

    private static func authenticateOverTunnel(
        session: TunnelSession,
        serverUUID: String,
        password: String,
        cookie: String?
    ) async throws -> String? {
        var statusHeaders: [String: String] = [:]
        if let cookie {
            statusHeaders["Cookie"] = cookie
        }
        let statusResult = try await session.performHTTP(
            serverUUID: serverUUID,
            method: "GET",
            path: "/api/auth/status",
            headers: statusHeaders
        )
        guard (200..<300).contains(statusResult.status) else {
            throw DesktopClientError.http(statusResult.status)
        }
        let statusJSON = JSONValue.parse(statusResult.body)
        let required = statusJSON?["required"]?.boolValue ?? false
        let authenticated = statusJSON?["authenticated"]?.boolValue ?? false
        guard required else { return nil }
        guard !authenticated else { return cookie }

        let body = try JSONEncoder().encode(JSONValue.object(["password": .string(password)]))
        let loginResult = try await session.performHTTP(
            serverUUID: serverUUID,
            method: "POST",
            path: "/api/auth/login",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        if loginResult.status == 401 {
            throw DesktopClientError.unauthorized
        }
        guard (200..<300).contains(loginResult.status) else {
            throw DesktopClientError.http(loginResult.status)
        }
        guard let setCookie = TunnelProtocol.headerValue(for: "Set-Cookie", in: loginResult.headers),
              let pair = setCookie.split(separator: ";").first
        else {
            return nil
        }
        return pair.trimmingCharacters(in: .whitespaces)
    }

    private func openTunnelSocket(
        session: TunnelSession,
        endpoint: DesktopConnection,
        generation current: Int
    ) async throws {
        var headers: [String: String] = [:]
        if let cookie {
            headers["Cookie"] = cookie
        }
        let stream = try await session.openWebSocket(
            serverUUID: endpoint.tunnelServerUUID,
            path: "/api/ws",
            headers: headers
        )
        guard current == generation, shouldRun else {
            stream.close()
            return
        }
        tunnelStream = stream
        Task {
            await receiveTunnelLoop(stream, generation: current)
        }
    }

    private func receiveTunnelLoop(_ stream: TunnelWebSocketStream, generation current: Int) async {
        while true {
            let data: Data
            do {
                data = try await stream.receive()
            } catch {
                guard current == generation else { return }
                let authRejected = stream.closeCode == 4401
                socketClosed(error: error, authRejected: authRejected)
                return
            }
            guard current == generation else { return }
            ingestServerMessage(data)
        }
    }

    private func closeSocket() {
        snapshotInterruptedRunsIfNeeded()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        tunnelStream?.close(code: 1000, reason: "")
        tunnelStream = nil
        serverClientId = nil
        failPending(DesktopClientError.notConnected)
    }

    private func socketClosed(error: Error, authRejected: Bool) {
        snapshotInterruptedRunsIfNeeded()
        socket = nil
        tunnelStream = nil
        serverClientId = nil
        failPending(DesktopClientError.notConnected)
        guard shouldRun else {
            isTerminalFailure = false
            state = .disconnected
            return
        }
        if authRejected {
            // The desktop restarted or its password changed; log in again.
            cookie = nil
        }
        if connection.mode == .tunnel, let session = activeTunnelSession {
            if case .failed(let terminalMessage) = session.phase {
                isTerminalFailure = true
                state = .failed(terminalMessage)
                return
            }
            if session.hasReceivedInitialServerList, !session.isServerOnline(connection.tunnelServerUUID) {
                isTerminalFailure = false
                state = .failed("远程桌面端不在线")
                return
            }
        }
        scheduleReconnect(message: Self.describe(error))
    }

    private func handleConnectFailure(_ error: Error) {
        if case DesktopClientError.unauthorized = error {
            // A wrong password will not fix itself; wait for the user to edit the connection.
            isTerminalFailure = true
            state = .failed("密码错误")
            return
        }
        if case DesktopClientError.invalidAddress = error {
            isTerminalFailure = true
            state = .failed("地址无效")
            return
        }
        if error is TunnelProtocolError {
            isTerminalFailure = true
            state = .failed(error.localizedDescription)
            return
        }
        if connection.mode == .tunnel, let session = activeTunnelSession {
            if case .failed(let terminalMessage) = session.phase {
                isTerminalFailure = true
                state = .failed(terminalMessage)
                return
            }
            if session.hasReceivedInitialServerList, !session.isServerOnline(connection.tunnelServerUUID) {
                isTerminalFailure = false
                state = .failed("远程桌面端不在线")
                return
            }
        }
        scheduleReconnect(message: Self.describe(error))
    }

    private func scheduleReconnect(message: String) {
        retryCount += 1
        isTerminalFailure = false
        state = retryCount > 2 ? .failed(message) : .connecting
        let delay = min(1.5 * pow(2, Double(min(retryCount - 1, 4))), 20)
        let current = generation
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, current == generation, shouldRun else { return }
            connect()
        }
    }

    // MARK: - Messages

    func ingestServerMessage(_ data: Data) {
        guard let message = JSONValue.parse(data) else { return }
        switch message["type"]?.stringValue {
        case "hello":
            serverClientId = message["clientId"]?.stringValue
            retryCount = 0
            isTerminalFailure = false
            state = .connected
            Task {
                await resync()
            }
        case "rpc_result":
            if let callId = message["id"]?.stringValue {
                resolve(callId, .success(message["result"] ?? .null))
            }
        case "rpc_error":
            if let callId = message["id"]?.stringValue {
                resolve(callId, .failure(DesktopClientError.remote(Self.errorMessage(in: message))))
            }
        case "event":
            if let event = message["event"] {
                handleEvent(event)
            }
        default:
            break
        }
    }

    private func handleEvent(_ event: JSONValue) {
        guard let kind = event["kind"]?.stringValue else { return }
        var payload = event["data"] ?? .null
        if let raw = payload.stringValue, let parsed = JSONValue.parse(raw) {
            payload = parsed
        }

        switch kind {
        case "projects:updated":
            if payload.arrayValue != nil {
                projects = payload.decodeList(RemoteProject.self)
            }
        case "session:meta-updated":
            if let session = try? payload.decode(RemoteSession.self) {
                let previousUnread = self.session(id: session.id)?.unread
                let currentRunSeq = sessionRunSequences[session.id, default: 0]
                let isStaleOwnErrorEcho = inFlightUnreadSyncSequences[session.id] != nil
                    && inFlightUnreadSyncSequences[session.id] != currentRunSeq
                upsertSession(session)
                if session.unread == .error,
                   !isStaleOwnErrorEcho,
                   previousUnread != .error,
                   runOutcomes[session.id]?.initialUnread != .error,
                   runOutcomes[session.id] != nil
                {
                    runOutcomes[session.id]?.sawError = true
                }
            }
        case "session:deleted":
            if let sessionId = payload["sessionId"]?.stringValue {
                sessions.removeAll { $0.id == sessionId }
                activeRuns[sessionId] = nil
                runOutcomes[sessionId] = nil
                pendingRunVerifications[sessionId] = nil
                recentlyAbortedRuns[sessionId] = nil
                pendingUnreadStates[sessionId] = nil
                readSyncIntents[sessionId] = nil
                viewedWatermarks[sessionId] = nil
                flushedAmbiguousReads[sessionId] = nil
                sessionRunSequences[sessionId] = nil
                sessionViewEpochs[sessionId] = nil
            }
        case "session:run-status":
            if let run = try? payload.decode(ActiveRun.self) {
                applyRunStatus(run)
            }
        case "session:stream-event":
            recordStreamOutcome(payload)
        case "session:abort-run":
            if let sessionId = payload["sessionId"]?.stringValue, !sessionId.isEmpty {
                markSessionAborted(sessionId)
            }
        case "session:entries-updated":
            // Saved entries update the desktop's skill metrics, as the desktop itself refetches here.
            refreshSkillUsage()
            if let sessionId = payload["sessionId"]?.stringValue, !sessionId.isEmpty {
                let currentGen = generation
                if pendingRunVerifications[sessionId] != nil {
                    Task { @MainActor [weak self] in
                        await self?.resolvePendingRunVerification(sessionId: sessionId, generation: currentGen)
                    }
                } else if flushedAmbiguousReads[sessionId] != nil {
                    Task { @MainActor [weak self] in
                        await self?.recheckFlushedAmbiguousRead(sessionId: sessionId, generation: currentGen)
                    }
                }
            }
        case "session:subagent-state":
            for record in payload["agents"]?.decodeList(SubAgentRecord.self) ?? [] where !record.parentSessionId.isEmpty {
                upsertSubAgent(record)
                if !record.sessionId.isEmpty {
                    runOutcomes[record.sessionId] = nil
                    pendingRunVerifications[record.sessionId] = nil
                    pendingUnreadStates[record.sessionId] = nil
                    readSyncIntents[record.sessionId] = nil
                    viewedWatermarks[record.sessionId] = nil
                    flushedAmbiguousReads[record.sessionId] = nil
                    sessionRunSequences[record.sessionId] = nil
                    sessionViewEpochs[record.sessionId] = nil
                }
            }
        default:
            break
        }

        emit(DesktopEvent(kind: kind, payload: payload))
    }

    private func bumpRunSequence(_ sessionId: String) {
        sessionRunSequences[sessionId, default: 0] += 1
        viewedWatermarks[sessionId] = nil
        flushedAmbiguousReads[sessionId] = nil
    }

    private func recordViewedWatermark(_ sessionId: String, updatedAt: Double = 0) {
        let currentRunSeq = sessionRunSequences[sessionId, default: 0]
        let sessionUpdatedAt = session(id: sessionId)?.updatedAt ?? 0
        let existingUpdatedAt = viewedWatermarks[sessionId]?.runSequence == currentRunSeq
            ? (viewedWatermarks[sessionId]?.updatedAt ?? 0)
            : 0
        if viewedWatermarks[sessionId] == nil,
           viewedWatermarks.count >= Self.maxPendingVerifications,
           let oldestKey = viewedWatermarks.min(by: { $0.value.capturedAt < $1.value.capturedAt })?.key
        {
            viewedWatermarks.removeValue(forKey: oldestKey)
        }
        viewedWatermarks[sessionId] = ViewedWatermark(
            runSequence: currentRunSeq,
            updatedAt: max(existingUpdatedAt, max(sessionUpdatedAt, updatedAt)),
            capturedAt: Date().milliseconds
        )
    }

    private func bumpViewEpoch(_ sessionId: String) {
        sessionViewEpochs[sessionId, default: 0] += 1
    }

    private static func baselineTimestamp(sessionUpdatedAt: Double, runUpdatedAt: Double) -> Double {
        guard sessionUpdatedAt > 0 else { return 0 }
        return runUpdatedAt > 0 ? min(sessionUpdatedAt, runUpdatedAt) : sessionUpdatedAt
    }

    private func requestReadSync(_ sessionId: String, upTo updatedAt: Double? = nil) {
        let candidateUpdatedAt = updatedAt ?? (session(id: sessionId)?.updatedAt ?? 0)
        let maxUpdatedAt = max(candidateUpdatedAt, readSyncIntents[sessionId]?.maxUpdatedAt ?? 0)
        readSyncCounter += 1
        readSyncIntents[sessionId] = ReadSyncIntent(
            revision: readSyncCounter,
            maxUpdatedAt: maxUpdatedAt,
            runSequenceAtRead: sessionRunSequences[sessionId, default: 0],
            pendingServerUnread: nil
        )
    }

    private func applyLocalReadState(to incoming: RemoteSession) -> RemoteSession {
        var adjusted = incoming
        if viewedSessionIds[incoming.id] != nil {
            if incoming.isUnread {
                requestReadSync(incoming.id, upTo: incoming.updatedAt)
            }
            adjusted.unread = .read
        } else if let pendingUnread = pendingUnreadStates[incoming.id] {
            adjusted.unread = pendingUnread.state
        } else if var intent = readSyncIntents[incoming.id] {
            if incoming.isUnread, intent.maxUpdatedAt > 0, incoming.updatedAt > intent.maxUpdatedAt {
                if inFlightUnreadSyncSequences[incoming.id] != nil,
                   inFlightUnreadSyncSequences[incoming.id] == intent.runSequenceAtRead,
                   sessionRunSequences[incoming.id, default: 0] == intent.runSequenceAtRead
                {
                    // Echo of our own in-flight `syncPendingUnread` for the already-viewed run: absorb server clock.
                    intent.maxUpdatedAt = incoming.updatedAt
                    readSyncIntents[incoming.id] = intent
                } else {
                    readSyncCounter += 1
                    intent.revision = readSyncCounter
                    intent.pendingServerUnread = incoming.unread
                    readSyncIntents[incoming.id] = intent
                }
            }
            adjusted.unread = .read
        } else if incoming.isUnread,
                  let watermark = viewedWatermarks[incoming.id],
                  sessionRunSequences[incoming.id, default: 0] == watermark.runSequence,
                  incoming.updatedAt > (session(id: incoming.id)?.updatedAt ?? 0)
        {
            viewedWatermarks[incoming.id] = nil
            requestReadSync(incoming.id, upTo: watermark.updatedAt)
            if watermark.updatedAt > 0, incoming.updatedAt > watermark.updatedAt, var intent = readSyncIntents[incoming.id] {
                intent.pendingServerUnread = incoming.unread
                readSyncIntents[incoming.id] = intent
            }
            adjusted.unread = .read
        }
        return adjusted
    }

    private func storePendingVerification(_ verification: PendingRunVerification, for sessionId: String) {
        if pendingRunVerifications[sessionId] == nil,
           pendingRunVerifications.count >= Self.maxPendingVerifications,
           let oldestKey = pendingRunVerifications
               .filter({ !$0.value.isResolving })
               .min(by: { $0.value.capturedAt < $1.value.capturedAt })?
               .key
        {
            pendingRunVerifications.removeValue(forKey: oldestKey)
        }
        pendingRunVerifications[sessionId] = verification
    }

    private func upsertSession(_ incoming: RemoteSession) {
        let adjusted = applyLocalReadState(to: incoming)
        defer {
            syncPendingUnread(incoming.id)
            flushReadSync(incoming.id)
        }
        guard let index = sessions.firstIndex(where: { $0.id == adjusted.id }) else {
            sessions.append(adjusted)
            return
        }
        var merged = adjusted
        let existing = sessions[index]
        if merged.title.isEmpty {
            merged.title = existing.title
        }
        if merged.createdAt == 0 {
            merged.createdAt = existing.createdAt
            merged.updatedAt = existing.updatedAt
        }
        sessions[index] = merged
    }

    private func applyRunStatus(_ run: ActiveRun) {
        guard run.status == "idle" else {
            bumpRunSequence(run.sessionId)
            pendingRunVerifications[run.sessionId] = nil
            activeRuns[run.sessionId] = run
            trackActiveRunStatus(run)
            return
        }
        // Ignore a stale idle from a run that has already been replaced.
        if let current = activeRuns[run.sessionId],
           !run.runId.isEmpty,
           current.runId != run.runId,
           !current.runId.hasPrefix(Self.optimisticRunPrefix)
        {
            return
        }
        let previousRun = activeRuns.removeValue(forKey: run.sessionId)
        let outcome = runOutcomes.removeValue(forKey: run.sessionId)
        guard previousRun != nil || outcome != nil else {
            return
        }
        pendingRunVerifications[run.sessionId] = nil

        let isConfirmedRun = (previousRun != nil && !previousRun!.runId.hasPrefix(Self.optimisticRunPrefix))
            || (!run.runId.isEmpty && !run.runId.hasPrefix(Self.optimisticRunPrefix))
            || outcome?.sawCompletedTurn == true
            || outcome?.sawError == true
            || outcome?.sawAssistantActivity == true
        let isCompactionOnly = outcome?.isExplicitCompaction == true
            || (outcome?.sawCompaction == true
                && outcome?.sawAssistantActivity != true
                && outcome?.sawError != true
                && outcome?.sawCompletedTurn != true)

        let effectiveRunId = !run.runId.isEmpty ? run.runId : (outcome?.runId ?? previousRun?.runId ?? "")
        if isConfirmedRun,
           !isCompactionOnly,
           !isSubAgentSession(run.sessionId),
           outcome?.wasAborted != true,
           !isRunRecentlyAborted(sessionId: run.sessionId, runId: effectiveRunId)
        {
            let observedCompletionAt = max(run.updatedAt, outcome?.latestEntryTimestamp ?? 0)
            if outcome?.sawError == true {
                markUnreadIfUnviewed(run.sessionId, state: .error, observedUpdatedAt: observedCompletionAt)
            } else if outcome?.sawCompletedTurn == true {
                markUnreadIfUnviewed(run.sessionId, state: .unread, observedUpdatedAt: observedCompletionAt)
            } else {
                let baseline = outcome?.baselineUpdatedAt ?? Self.baselineTimestamp(
                    sessionUpdatedAt: session(id: run.sessionId)?.updatedAt ?? 0,
                    runUpdatedAt: previousRun?.updatedAt ?? 0
                )
                storePendingVerification(
                    PendingRunVerification(
                        runId: effectiveRunId,
                        baselineUpdatedAt: baseline,
                        previousUnread: outcome?.initialUnread ?? (session(id: run.sessionId)?.unread ?? .read),
                        runSequence: sessionRunSequences[run.sessionId, default: 0],
                        capturedAt: Date().milliseconds,
                        viewEpochAtCapture: sessionViewEpochs[run.sessionId, default: 0],
                        sawCompletedTurn: false,
                        sawError: false,
                        unreadSuppressed: viewedSessionIds[run.sessionId] != nil,
                        needsReconnectReconcile: false,
                        capturedWhileRunning: false,
                        remainingPersistenceRetries: 2
                    ),
                    for: run.sessionId
                )
                let currentGen = generation
                let targetSessionId = run.sessionId
                Task { @MainActor [weak self] in
                    await self?.resolvePendingRunVerification(
                        sessionId: targetSessionId,
                        generation: currentGen
                    )
                }
            }
        }

    }

    private func resolvePendingRunVerification(
        sessionId: String,
        generation current: Int,
        fallbackUpdatedAt: Double? = nil
    ) async {
        guard current == generation,
              state == .connected,
              let pending = pendingRunVerifications[sessionId]
        else {
            return
        }
        guard sessionRunSequences[sessionId, default: 0] == pending.runSequence,
              activeRuns[sessionId] == nil,
              !isSubAgentSession(sessionId),
              session(id: sessionId) != nil,
              !isRunRecentlyAborted(sessionId: sessionId, runId: pending.runId)
        else {
            if pendingRunVerifications[sessionId]?.runSequence == pending.runSequence {
                pendingRunVerifications[sessionId] = nil
            }
            return
        }

        if pending.isResolving {
            pendingRunVerifications[sessionId]?.retryRequestedWhileResolving = true
            return
        }

        if pending.sawError {
            let canMarkUnread = !pending.unreadSuppressed
                && viewedSessionIds[sessionId] == nil
                && sessionViewEpochs[sessionId, default: 0] == pending.viewEpochAtCapture
            if canMarkUnread {
                markUnreadIfUnviewed(sessionId, state: .error, preservedUpdatedAt: fallbackUpdatedAt)
            } else {
                recordViewedWatermark(sessionId, updatedAt: fallbackUpdatedAt ?? 0)
            }
            pendingRunVerifications[sessionId] = nil
            return
        }

        pendingRunVerifications[sessionId]?.isResolving = true
        pendingRunVerifications[sessionId]?.retryRequestedWhileResolving = false

        let detail = try? await call("session:get", [.string(sessionId)])
        guard current == generation, state == .connected else {
            // Socket dropped while fetching entries: preserve `pendingRunVerifications[sessionId]` for reconnect.
            if pendingRunVerifications[sessionId]?.runSequence == pending.runSequence {
                pendingRunVerifications[sessionId]?.isResolving = false
                pendingRunVerifications[sessionId]?.needsReconnectReconcile = true
            }
            return
        }
        guard let detail else {
            // Transient RPC error: mark eligible for `resync()` retry while keeping the verification record.
            if pendingRunVerifications[sessionId]?.runSequence == pending.runSequence {
                pendingRunVerifications[sessionId]?.isResolving = false
                pendingRunVerifications[sessionId]?.needsReconnectReconcile = true
            }
            return
        }
        guard let latest = pendingRunVerifications[sessionId],
              latest.runSequence == pending.runSequence,
              sessionRunSequences[sessionId, default: 0] == pending.runSequence,
              activeRuns[sessionId] == nil,
              !isSubAgentSession(sessionId),
              session(id: sessionId) != nil,
              !isRunRecentlyAborted(sessionId: sessionId, runId: pending.runId)
        else {
            if pendingRunVerifications[sessionId]?.runSequence == pending.runSequence {
                pendingRunVerifications[sessionId] = nil
            }
            return
        }

        let entries = detail["entries"]?.arrayValue != nil
            ? (detail["entries"]?.decodeList(ConversationEntry.self) ?? [])
            : nil
        let classification: OfflineTerminalOutcome = entries.map {
            Self.classifyTerminalOutcome(of: $0, after: pending.baselineUpdatedAt)
        } ?? .notYetPersisted

        let canMarkUnread = !latest.unreadSuppressed
            && viewedSessionIds[sessionId] == nil
            && sessionViewEpochs[sessionId, default: 0] == latest.viewEpochAtCapture

        let latestEntryTimestamp = entries?.map { max($0.completedAt ?? 0, $0.createdAt) }.max() ?? 0
        let offlinePreservedUpdatedAt = fallbackUpdatedAt.map { max($0, latestEntryTimestamp) }

        switch classification {
        case .completed:
            pendingRunVerifications[sessionId] = nil
            if canMarkUnread {
                markUnreadIfUnviewed(
                    sessionId,
                    state: .unread,
                    observedUpdatedAt: latestEntryTimestamp,
                    preservedUpdatedAt: offlinePreservedUpdatedAt
                )
            } else {
                if let index = sessions.firstIndex(where: { $0.id == sessionId }),
                   latestEntryTimestamp > sessions[index].updatedAt
                {
                    sessions[index].updatedAt = latestEntryTimestamp
                }
                recordViewedWatermark(sessionId, updatedAt: max(latestEntryTimestamp, fallbackUpdatedAt ?? 0))
            }

        case .error:
            pendingRunVerifications[sessionId] = nil
            if canMarkUnread {
                markUnreadIfUnviewed(
                    sessionId,
                    state: .error,
                    observedUpdatedAt: latestEntryTimestamp,
                    preservedUpdatedAt: offlinePreservedUpdatedAt
                )
            } else {
                if let index = sessions.firstIndex(where: { $0.id == sessionId }),
                   latestEntryTimestamp > sessions[index].updatedAt
                {
                    sessions[index].updatedAt = latestEntryTimestamp
                }
                recordViewedWatermark(sessionId, updatedAt: max(latestEntryTimestamp, fallbackUpdatedAt ?? 0))
            }
        case .settledIncomplete:
            pendingRunVerifications[sessionId] = nil
        case .notYetPersisted:
            let retryImmediately = latest.retryRequestedWhileResolving
            pendingRunVerifications[sessionId]?.isResolving = false
            pendingRunVerifications[sessionId]?.retryRequestedWhileResolving = false
            pendingRunVerifications[sessionId]?.needsReconnectReconcile = true
            if latest.remainingPersistenceRetries > 0 {
                pendingRunVerifications[sessionId]?.remainingPersistenceRetries -= 1
                Task { @MainActor [weak self] in
                    if !retryImmediately {
                        try? await Task.sleep(for: .milliseconds(120))
                    }
                    await self?.resolvePendingRunVerification(
                        sessionId: sessionId,
                        generation: current,
                        fallbackUpdatedAt: fallbackUpdatedAt
                    )
                }
            } else if retryImmediately {
                // Keep the verification record passive after short-term polling ends so a late
                // `session:entries-updated` or future `resync()` can still resolve it.
                Task { @MainActor [weak self] in
                    await self?.resolvePendingRunVerification(
                        sessionId: sessionId,
                        generation: current,
                        fallbackUpdatedAt: fallbackUpdatedAt
                    )
                }
            }
        }
    }

    private func isSubAgentSession(_ sessionId: String) -> Bool {
        if session(id: sessionId)?.parentSessionId != nil {
            return true
        }
        return subAgentsByParent.values.contains { records in
            records.contains { $0.sessionId == sessionId }
        }
    }

    private func trackActiveRunStatus(_ run: ActiveRun) {
        guard !isSubAgentSession(run.sessionId) else {
            runOutcomes[run.sessionId] = nil
            return
        }
        let currentSession = session(id: run.sessionId)
        let baseline = Self.baselineTimestamp(
            sessionUpdatedAt: currentSession?.updatedAt ?? 0,
            runUpdatedAt: run.updatedAt
        )
        let initialUnread = currentSession?.unread ?? .read
        guard var existing = runOutcomes[run.sessionId] else {
            if !run.runId.isEmpty, recentlyAbortedRuns[run.sessionId]?.runId != run.runId {
                recentlyAbortedRuns[run.sessionId] = nil
            }
            runOutcomes[run.sessionId] = TrackedRunOutcome(
                runId: run.runId,
                baselineUpdatedAt: baseline,
                initialUnread: initialUnread,
                sawError: run.status == "error"
            )
            return
        }
        if run.status == "error" {
            existing.sawError = true
            runOutcomes[run.sessionId] = existing
        }
        if existing.runId.isEmpty || existing.runId.hasPrefix(Self.optimisticRunPrefix) {
            if !run.runId.isEmpty {
                if recentlyAbortedRuns[run.sessionId]?.runId != run.runId {
                    recentlyAbortedRuns[run.sessionId] = nil
                }
                existing.runId = run.runId
                runOutcomes[run.sessionId] = existing
            }
            return
        }
        if !run.runId.isEmpty, run.runId != existing.runId, !run.runId.hasPrefix(Self.optimisticRunPrefix) {
            recentlyAbortedRuns[run.sessionId] = nil
            runOutcomes[run.sessionId] = TrackedRunOutcome(
                runId: run.runId,
                baselineUpdatedAt: baseline,
                initialUnread: initialUnread,
                sawError: run.status == "error"
            )
        }
    }

    private func recordStreamOutcome(_ payload: JSONValue) {
        guard let sessionId = payload["sessionId"]?.stringValue,
              !sessionId.isEmpty,
              !isSubAgentSession(sessionId),
              let event = payload["event"]
        else {
            return
        }
        if event["nested"]?.boolValue == true || event["parentToolCallId"]?.stringValue != nil {
            return
        }
        let streamRunId = payload["runId"]?.stringValue ?? event["runId"]?.stringValue ?? ""
        let currentSession = session(id: sessionId)
        let currentUpdatedAt = currentSession?.updatedAt ?? 0
        let initialUnread = currentSession?.unread ?? .read
        var outcome: TrackedRunOutcome
        if let existing = runOutcomes[sessionId] {
            if !streamRunId.isEmpty,
               !existing.runId.isEmpty,
               !existing.runId.hasPrefix(Self.optimisticRunPrefix),
               existing.runId != streamRunId
            {
                bumpRunSequence(sessionId)
                pendingRunVerifications[sessionId] = nil
                recentlyAbortedRuns[sessionId] = nil
                outcome = TrackedRunOutcome(
                    runId: streamRunId,
                    baselineUpdatedAt: currentUpdatedAt,
                    initialUnread: initialUnread
                )
            } else {
                outcome = existing
                if !streamRunId.isEmpty && (outcome.runId.isEmpty || outcome.runId.hasPrefix(Self.optimisticRunPrefix)) {
                    if recentlyAbortedRuns[sessionId]?.runId != streamRunId {
                        recentlyAbortedRuns[sessionId] = nil
                    }
                    outcome.runId = streamRunId
                }
            }
        } else {
            bumpRunSequence(sessionId)
            pendingRunVerifications[sessionId] = nil
            if !streamRunId.isEmpty, recentlyAbortedRuns[sessionId]?.runId != streamRunId {
                recentlyAbortedRuns[sessionId] = nil
            }
            outcome = TrackedRunOutcome(
                runId: streamRunId,
                baselineUpdatedAt: currentUpdatedAt,
                initialUnread: initialUnread
            )
        }

        switch event["type"]?.stringValue {
        case "assistant-start", "tool-start":
            outcome.sawAssistantActivity = true
            outcome.sawCompletedTurn = false
        case "assistant-delta", "tool-end":
            outcome.sawAssistantActivity = true
        case "compaction-start", "compaction-end":
            outcome.sawCompaction = true
        case "assistant-end":
            outcome.sawAssistantActivity = true
            let entry = event["entry"]
            let entryTs = max(entry?["completedAt"]?.doubleValue ?? 0, entry?["createdAt"]?.doubleValue ?? 0)
            if entryTs > outcome.latestEntryTimestamp {
                outcome.latestEntryTimestamp = entryTs
            }
            let status = entry?["status"]?.stringValue ?? ""
            let stopReason = entry?["stopReason"]?.stringValue ?? "stop"
            let errorMessage = entry?["errorMessage"]?.stringValue ?? ""
            if status == "aborted" || stopReason == "aborted" {
                outcome.wasAborted = true
                outcome.sawCompletedTurn = false
            } else if !errorMessage.isEmpty || status == "error" {
                outcome.sawError = true
                outcome.sawCompletedTurn = false
            } else if status == "done" && stopReason != "toolUse" {
                outcome.sawCompletedTurn = true
            } else if stopReason == "toolUse" {
                outcome.sawCompletedTurn = false
            }
        case "aborted":
            outcome.wasAborted = true
            outcome.sawCompletedTurn = false
        case "error":
            outcome.sawError = true
            outcome.sawCompletedTurn = false
        default:
            break
        }
        runOutcomes[sessionId] = outcome
    }

    private func isRunRecentlyAborted(sessionId: String, runId: String?) -> Bool {
        guard let record = recentlyAbortedRuns[sessionId] else { return false }
        if Date().milliseconds - record.timestamp >= Self.abortSuppressionWindowMs {
            recentlyAbortedRuns[sessionId] = nil
            return false
        }
        if let abortedRunId = record.runId, let runId, !runId.isEmpty, abortedRunId != runId {
            return false
        }
        return true
    }

    private func markSessionAborted(_ sessionId: String) {
        bumpRunSequence(sessionId)
        let candidateRunId = activeRuns[sessionId]?.runId ?? runOutcomes[sessionId]?.runId
        let normalizedRunId = (candidateRunId?.isEmpty == false) ? candidateRunId : nil
        recentlyAbortedRuns[sessionId] = AbortedRunRecord(runId: normalizedRunId, timestamp: Date().milliseconds)
        if runOutcomes[sessionId] != nil {
            runOutcomes[sessionId]?.wasAborted = true
            runOutcomes[sessionId]?.sawCompletedTurn = false
        } else if let active = activeRuns[sessionId] {
            runOutcomes[sessionId] = TrackedRunOutcome(runId: active.runId, wasAborted: true)
        }
        pendingRunVerifications[sessionId] = nil
    }

    private func snapshotInterruptedRunsIfNeeded() {
        guard hasSynced, shouldRun else { return }
        for sessionId in Array(pendingRunVerifications.keys) {
            pendingRunVerifications[sessionId]?.isResolving = false
            pendingRunVerifications[sessionId]?.retryRequestedWhileResolving = false
            pendingRunVerifications[sessionId]?.needsReconnectReconcile = true
        }
        for (sessionId, run) in activeRuns {
            guard !run.runId.hasPrefix(Self.optimisticRunPrefix),
                  !isSubAgentSession(sessionId),
                  pendingRunVerifications[sessionId] == nil
            else {
                continue
            }
            let outcome = runOutcomes[sessionId]
            if outcome?.wasAborted == true || outcome?.isExplicitCompaction == true {
                continue
            }
            let baseline = outcome?.baselineUpdatedAt ?? Self.baselineTimestamp(
                sessionUpdatedAt: session(id: sessionId)?.updatedAt ?? 0,
                runUpdatedAt: run.updatedAt
            )
            storePendingVerification(
                PendingRunVerification(
                    runId: run.runId,
                    baselineUpdatedAt: baseline,
                    previousUnread: outcome?.initialUnread ?? (session(id: sessionId)?.unread ?? .read),
                    runSequence: sessionRunSequences[sessionId, default: 0],
                    capturedAt: Date().milliseconds,
                    viewEpochAtCapture: sessionViewEpochs[sessionId, default: 0],
                    sawCompletedTurn: outcome?.sawCompletedTurn == true,
                    sawError: outcome?.sawError == true,
                    unreadSuppressed: false,
                    needsReconnectReconcile: true,
                    capturedWhileRunning: true,
                    remainingPersistenceRetries: 1
                ),
                for: sessionId
            )
        }
    }

    private func ensureTrackedOutcomes(for runs: [String: ActiveRun], sessionsById: [String: RemoteSession] = [:]) {
        for (sessionId, run) in runs where !isSubAgentSession(sessionId) {
            guard activeRuns[sessionId]?.runId == run.runId else {
                continue
            }
            let targetSession = sessionsById[sessionId] ?? session(id: sessionId)
            let sessUpdatedAt = targetSession?.updatedAt ?? 0
            let initialUnread = targetSession?.unread ?? .read
            let baseline = Self.baselineTimestamp(sessionUpdatedAt: sessUpdatedAt, runUpdatedAt: run.updatedAt)
            if var existing = runOutcomes[sessionId] {
                if !run.runId.isEmpty,
                   !existing.runId.isEmpty,
                   !existing.runId.hasPrefix(Self.optimisticRunPrefix),
                   existing.runId != run.runId
                {
                    bumpRunSequence(sessionId)
                    pendingRunVerifications[sessionId] = nil
                    recentlyAbortedRuns[sessionId] = nil
                    runOutcomes[sessionId] = TrackedRunOutcome(
                        runId: run.runId,
                        baselineUpdatedAt: baseline,
                        initialUnread: initialUnread,
                        sawError: run.status == "error"
                    )
                } else {
                    if !run.runId.isEmpty && (existing.runId.isEmpty || existing.runId.hasPrefix(Self.optimisticRunPrefix)) {
                        if recentlyAbortedRuns[sessionId]?.runId != run.runId {
                            recentlyAbortedRuns[sessionId] = nil
                        }
                        existing.runId = run.runId
                    }
                    if run.status == "error" {
                        existing.sawError = true
                    }
                    if existing.baselineUpdatedAt == 0, baseline > 0 {
                        existing.baselineUpdatedAt = baseline
                        existing.initialUnread = initialUnread
                    }
                    runOutcomes[sessionId] = existing
                }
            } else {
                runOutcomes[sessionId] = TrackedRunOutcome(
                    runId: run.runId,
                    baselineUpdatedAt: baseline,
                    initialUnread: initialUnread,
                    sawError: run.status == "error"
                )
            }
        }
    }

    private func reconcileInterruptedRunsAfterResync(
        currentRuns: [String: ActiveRun],
        rawSessions: [RemoteSession],
        generation current: Int
    ) async {
        let now = Date().milliseconds
        recentlyAbortedRuns = recentlyAbortedRuns.filter { now - $0.value.timestamp < Self.abortSuppressionWindowMs }

        let rawById = Dictionary(uniqueKeysWithValues: rawSessions.map { ($0.id, $0) })
        ensureTrackedOutcomes(for: currentRuns, sessionsById: rawById)

        for sessionId in Array(pendingRunVerifications.keys) where pendingRunVerifications[sessionId]?.needsReconnectReconcile == true {
            if pendingRunVerifications[sessionId]?.capturedWhileRunning == true {
                pendingRunVerifications[sessionId]?.viewEpochAtCapture = sessionViewEpochs[sessionId, default: 0]
                pendingRunVerifications[sessionId]?.capturedWhileRunning = false
            }
            if viewedSessionIds[sessionId] != nil {
                pendingRunVerifications[sessionId]?.unreadSuppressed = true
            }
        }

        let orderedVerifications = pendingRunVerifications
            .filter { $0.value.needsReconnectReconcile }
            .sorted { $0.key < $1.key }
        for (sessionId, snapshot) in orderedVerifications {
            guard let latestPending = pendingRunVerifications[sessionId],
                  latestPending.needsReconnectReconcile,
                  latestPending.runSequence == snapshot.runSequence
            else {
                continue
            }
            if activeRuns[sessionId] != nil {
                pendingRunVerifications[sessionId] = nil
                continue
            }
            if runOutcomes[sessionId]?.runId.isEmpty == true || runOutcomes[sessionId]?.runId == snapshot.runId {
                runOutcomes[sessionId] = nil
            }
            guard sessionRunSequences[sessionId, default: 0] == snapshot.runSequence,
                  !isRunRecentlyAborted(sessionId: sessionId, runId: snapshot.runId),
                  !isSubAgentSession(sessionId),
                  let rawSession = rawById[sessionId] ?? session(id: sessionId)
            else {
                pendingRunVerifications[sessionId] = nil
                continue
            }

            if rawSession.unread == .error,
               latestPending.previousUnread != .error,
               !latestPending.sawCompletedTurn
            {
                pendingRunVerifications[sessionId] = nil
                continue
            }
            if rawSession.unread == .unread,
               latestPending.previousUnread != .unread,
               !latestPending.sawError
            {
                pendingRunVerifications[sessionId] = nil
                continue
            }

            await resolvePendingRunVerification(
                sessionId: sessionId,
                generation: current,
                fallbackUpdatedAt: rawSession.updatedAt
            )
            guard current == generation, state == .connected else {
                return
            }
        }
    }

    private enum OfflineTerminalOutcome {
        case completed
        case error
        case settledIncomplete
        case notYetPersisted
    }

    private static func classifyTerminalOutcome(
        of entries: [ConversationEntry],
        after previousUpdatedAt: Double
    ) -> OfflineTerminalOutcome {
        // Do not skip trailing `.compaction`: a run ending with compaction was `/compact`, not an assistant turn.
        guard let last = entries.last(where: { $0.kind != .unknown }) else {
            return .notYetPersisted
        }
        let terminalTimestamp = max(last.completedAt ?? 0, last.createdAt)
        if previousUpdatedAt > 0, terminalTimestamp <= previousUpdatedAt {
            return .notYetPersisted
        }
        guard last.kind == .assistant else {
            return .notYetPersisted
        }
        let errorMessage = last.errorMessage ?? ""
        if last.status == "aborted"
            || last.stopReason == "aborted"
            || last.interrupted
            || errorMessage == "Response stream ended prematurely before completion"
            || errorMessage == "Interrupted by session restart"
        {
            return .settledIncomplete
        }
        if last.status == "error" || last.stopReason == "error" || !errorMessage.isEmpty {
            return .error
        }
        if last.status == "done", last.stopReason != "toolUse", last.stopReason != "pending" {
            return .completed
        }
        return .notYetPersisted
    }

    private func resetTurnOutcomeTracking() {
        runOutcomes.removeAll()
        pendingRunVerifications.removeAll()
        recentlyAbortedRuns.removeAll()
        pendingUnreadStates.removeAll()
        readSyncIntents.removeAll()
        viewedWatermarks.removeAll()
        flushedAmbiguousReads.removeAll()
        inFlightUnreadSyncSequences.removeAll()
        inFlightManualReadIds.removeAll()
        sessionRunSequences.removeAll()
        sessionViewEpochs.removeAll()
    }

    // MARK: - Listeners

    func addListener(_ handler: @escaping @MainActor (DesktopEvent) -> Void) -> UUID {
        let token = UUID()
        listeners[token] = handler
        return token
    }

    func removeListener(_ token: UUID) {
        listeners[token] = nil
    }

    func emit(_ event: DesktopEvent) {
        for listener in Array(listeners.values) {
            listener(event)
        }
    }

    // MARK: - RPC

    // `encodesInBackground` keeps large payloads (attachments) from blocking the main actor while they are
    // encoded. Messages still leave in call order: later calls wait until the earlier ones are sent.
    func call(
        _ method: String,
        _ args: [JSONValue] = [],
        timeout: Double = 30,
        encodesInBackground: Bool = false
    ) async throws -> JSONValue {
        guard (socket != nil || tunnelStream != nil), state == .connected else {
            throw DesktopClientError.notConnected
        }
        callSequence += 1
        let callId = "ios_\(callSequence)_\(Int(Date().milliseconds))"
        let payload: JSONValue = [
            "type": "rpc",
            "id": .string(callId),
            "method": .string(method),
            "args": .array(args),
            "clientId": .optional(serverClientId),
        ]
        let current = generation
        var text: String?
        if !encodesInBackground && queuedSends == 0 {
            text = try payload.jsonString()
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[callId] = continuation
            if let text {
                send(text, callId: callId, generation: current)
            } else {
                queuedSends += 1
                let previous = sendQueue
                sendQueue = Task { @MainActor [weak self] in
                    await previous?.value
                    guard let self else { return }
                    defer {
                        queuedSends -= 1
                    }
                    // A call that already ended (e.g. timed out) is neither encoded nor sent.
                    guard pending[callId] != nil else { return }
                    let encoded = await Task.detached(priority: .userInitiated) {
                        Result { try payload.jsonString() }
                    }.value
                    switch encoded {
                    case .success(let text):
                        send(text, callId: callId, generation: current)
                    case .failure(let error):
                        resolve(callId, .failure(error))
                    }
                }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.resolve(callId, .failure(DesktopClientError.timeout(method)))
            }
        }
    }

    private func send(_ text: String, callId: String, generation expected: Int) {
        // A queued message may outlive its call (e.g. timed out) or its connection.
        guard pending[callId] != nil else { return }
        guard state == .connected, generation == expected else {
            resolve(callId, .failure(DesktopClientError.notConnected))
            return
        }
        if let socket {
            socket.send(.string(text)) { error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    self?.resolve(callId, .failure(error))
                }
            }
        } else if let tunnelStream {
            Task { @MainActor [weak self] in
                do {
                    try await tunnelStream.sendText(text)
                } catch {
                    self?.resolve(callId, .failure(error))
                }
            }
        } else {
            resolve(callId, .failure(DesktopClientError.notConnected))
        }
    }

    private func resolve(_ callId: String, _ result: Result<JSONValue, Error>) {
        pending.removeValue(forKey: callId)?.resume(with: result)
    }

    private func failPending(_ error: Error) {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    // Re-fetches authoritative projects, sessions, runs, models and defaults.
    func resync() async {
        guard state == .connected else { return }
        let wasSynced = hasSynced
        if !wasSynced {
            pendingRunVerifications.removeAll()
        }
        // Results of a superseded connection must not overwrite newer data.
        let current = generation
        let runsValue = try? await call("session:getActiveRuns")
        guard current == generation else { return }
        var syncedRuns: [String: ActiveRun]?
        if let runsValue, runsValue.arrayValue != nil {
            var runs: [String: ActiveRun] = [:]
            for run in runsValue.decodeList(ActiveRun.self) where run.status != "idle" {
                runs[run.sessionId] = run
            }
            activeRuns = runs
            syncedRuns = runs
            ensureTrackedOutcomes(for: runs)
        }
        let projectsValue = try? await call("kvstore:get", ["projects"])
        guard current == generation else { return }
        if let projectsValue, projectsValue.arrayValue != nil {
            projects = projectsValue.decodeList(RemoteProject.self)
        }
        let sessionsValue = try? await call("session:listSessions")
        guard current == generation else { return }
        var syncedRawSessions: [RemoteSession]?
        if let sessionsValue, sessionsValue.arrayValue != nil {
            let decoded = sessionsValue.decodeList(RemoteSession.self)
            syncedRawSessions = decoded
            sessions = decoded.map { applyLocalReadState(to: $0) }
            if let syncedRuns {
                let rawById = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
                ensureTrackedOutcomes(for: syncedRuns, sessionsById: rawById)
            }
        }
        let modelsValue = try? await call("kvstore:get", ["cachedModels"])
        guard current == generation else { return }
        if let modelsValue, modelsValue.arrayValue != nil {
            models = modelsValue.decodeList(RemoteModel.self)
        }
        let appStateValue = try? await call("kvstore:get", ["app-state"])
        guard current == generation else { return }
        if let appStateValue, !appStateValue.isNull {
            defaults = RemoteDefaults(appState: appStateValue)
        }
        guard current == generation, state == .connected else { return }
        hasSynced = true
        if wasSynced {
            // Only reconcile and consume interrupted snapshots when both runs and sessions succeeded.
            if let syncedRuns, let syncedRawSessions {
                await reconcileInterruptedRunsAfterResync(
                    currentRuns: syncedRuns,
                    rawSessions: syncedRawSessions,
                    generation: current
                )
                guard current == generation, state == .connected else { return }
            } else if let syncedRuns {
                ensureTrackedOutcomes(for: syncedRuns)
            }
        } else if let syncedRuns {
            ensureTrackedOutcomes(for: syncedRuns)
        }
        refreshSkillUsage()
        for sessionId in Array(flushedAmbiguousReads.keys).sorted() {
            await recheckFlushedAmbiguousRead(sessionId: sessionId, generation: current)
            guard current == generation, state == .connected else { return }
        }
        for sessionId in Array(pendingUnreadStates.keys) {
            syncPendingUnread(sessionId)
        }
        for sessionId in Set(viewedSessionIds.keys).union(readSyncIntents.keys) {
            flushReadSync(sessionId)
        }
        emit(DesktopEvent(kind: DesktopEvent.synced, payload: .null))
    }

    // MARK: - Queries

    func project(id: String?) -> RemoteProject? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func session(id: String) -> RemoteSession? {
        sessions.first { $0.id == id }
    }

    // Most recently used top-level conversation with a model in a project (nil: no project).
    func lastUsedSession(projectId: String?) -> RemoteSession? {
        let target = projectId ?? ""
        return sessions
            .filter { $0.parentSessionId == nil && ($0.projectId ?? "") == target && !($0.modelId ?? "").isEmpty }
            .max { $0.updatedAt < $1.updatedAt }
    }

    // Model preselected for a new conversation in a project: the one of the project's last used
    // conversation, else the desktop default, else the first available model.
    func preferredModel(projectId: String?) -> RemoteModel? {
        let models = availableModels
        return [lastUsedSession(projectId: projectId)?.modelId, defaults.modelId]
            .compactMap { id in models.first { $0.id == id } }
            .first ?? models.first
    }

    // Reasoning level preselected for `model` in a new conversation in a project.
    func preferredReasoning(for model: RemoteModel?, projectId: String?) -> String {
        let choices = reasoningChoices(for: model)
        let lastUsed = lastUsedSession(projectId: projectId)
        // The last used level only applies to the model it was used with.
        let lastReasoning = lastUsed?.modelId == model?.id ? lastUsed?.reasoningEffort : nil
        return [lastReasoning, defaults.reasoningLevel, "medium"]
            .compactMap { id in choices.first { $0.id == id }?.id }
            .first ?? choices.last?.id ?? ""
    }

    func isRunning(_ sessionId: String) -> Bool {
        activeRuns[sessionId] != nil
    }

    // Models enabled in the desktop settings, in the desktop's configured order.
    var availableModels: [RemoteModel] {
        let enabled = models.filter { !defaults.disabledModels.contains($0.id) }
        let list = enabled.isEmpty ? models : enabled
        guard !defaults.modelOrder.isEmpty else { return list }
        var rank: [String: Int] = [:]
        for (index, id) in defaults.modelOrder.enumerated() where rank[id] == nil {
            rank[id] = index
        }
        return list.enumerated()
            .sorted { lhs, rhs in
                let left = rank[lhs.element.id] ?? Int.max
                let right = rank[rhs.element.id] ?? Int.max
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }

    func model(id: String?) -> RemoteModel? {
        guard let id else { return nil }
        return models.first { $0.id == id }
    }

    func reasoningChoices(for model: RemoteModel?) -> [ReasoningChoice] {
        guard let model else { return [] }
        let allowed = defaults.enabledReasoningLevels[model.id]
        return model.reasoningLevels
            .filter { $0.id.lowercased() != "ultra" }
            .filter { allowed?.contains($0.id) ?? true }
            .map { ReasoningChoice(id: $0.id, title: ReasoningChoice.title(for: $0.id, fallback: $0.fallbackLabel)) }
    }

    // MARK: - Sessions

    func loadEntries(sessionId: String) async throws -> [ConversationEntry] {
        let value = try await call("session:get", [.string(sessionId)])
        mergeSubAgents(parentSessionId: sessionId, snapshot: value["subAgents"]?.decodeList(SubAgentRecord.self) ?? [])
        return value["entries"]?.decodeList(ConversationEntry.self) ?? []
    }

    // Reloads the stored sub-agents of a conversation, e.g. for a sub-agent view after reconnecting.
    func refreshSubAgents(parentSessionId: String) async throws {
        let value = try await call("session:get", [.string(parentSessionId)])
        mergeSubAgents(parentSessionId: parentSessionId, snapshot: value["subAgents"]?.decodeList(SubAgentRecord.self) ?? [])
    }

    // MARK: - Sub-agents

    func subAgents(parentSessionId: String) -> [SubAgentRecord] {
        subAgentsByParent[parentSessionId] ?? []
    }

    func subAgent(parentSessionId: String, id agentId: String) -> SubAgentRecord? {
        subAgentsByParent[parentSessionId]?.first { $0.id == agentId }
    }

    // Live state from the desktop's sub-agent host (`session:subagent-state`).
    private func upsertSubAgent(_ incoming: SubAgentRecord) {
        var records = subAgentsByParent[incoming.parentSessionId] ?? []
        if let index = records.firstIndex(where: { $0.id == incoming.id }) {
            guard incoming.updatedAt >= records[index].updatedAt else { return }
            records[index] = incoming
        } else {
            records.append(incoming)
        }
        subAgentsByParent[incoming.parentSessionId] = records
    }

    // Applies the stored sub-agents of a conversation. A snapshot can be older than live state that
    // arrived while it was loading, so newer records and records it misses are kept (desktop
    // `mergeAgentsForParent`).
    private func mergeSubAgents(parentSessionId: String, snapshot: [SubAgentRecord]) {
        let existing = subAgentsByParent[parentSessionId] ?? []
        guard !snapshot.isEmpty || !existing.isEmpty else { return }
        var merged: [SubAgentRecord] = []
        for record in snapshot {
            guard let current = existing.first(where: { $0.id == record.id }) else {
                merged.append(record)
                continue
            }
            if current.updatedAt > record.updatedAt {
                merged.append(current)
            } else {
                // The desktop stores neither completion nor pause time; keep them from live state.
                var updated = record
                updated.completedAt = record.completedAt ?? current.completedAt
                updated.pausedMs = record.pausedMs ?? current.pausedMs
                merged.append(updated)
            }
        }
        let snapshotIds = Set(snapshot.map(\.id))
        merged += existing.filter { !snapshotIds.contains($0.id) }
        subAgentsByParent[parentSessionId] = merged.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Search

    // Chat search of the desktop: title matches first, then content matches with a snippet.
    func searchSessions(query: String, limit: Int) async throws -> [SessionSearchResult] {
        let value = try await call("session:search", [.string(query), .number(Double(limit))])
        return value.decodeList(SessionSearchResult.self)
    }

    // Creates the session metadata up front so the desktop picks up project, branch and work location.
    func createSession(
        id sessionId: String,
        title: String,
        projectId: String?,
        branch: String?,
        workLocation: WorkLocation,
        modelId: String?,
        reasoningEffort: String?,
        speed: String?
    ) async throws {
        let now = Date().milliseconds
        var meta: [String: JSONValue] = [
            "id": .string(sessionId),
            "title": .string(title),
            "pinned": false,
            "workLocation": .string(workLocation.rawValue),
            "createdAt": .number(now),
            "updatedAt": .number(now),
        ]
        if let projectId {
            meta["projectId"] = .string(projectId)
        }
        if let branch {
            meta["branch"] = .string(branch)
        }
        if let modelId {
            meta["modelId"] = .string(modelId)
        }
        if let reasoningEffort {
            meta["reasoningEffort"] = .string(reasoningEffort)
        }
        if let speed {
            meta["speed"] = .string(speed)
        }
        _ = try await call("session:setMeta", [.object(meta)])
    }

    // Hands the prompt to the desktop, which runs the agent and streams events back.
    func delegateRun(_ request: DelegateRunRequest) async throws {
        let current = generation
        // Repeated edits of one prompt share its entry id, so their own request id keeps placeholders apart.
        try await callDelegateRun(
            request.json,
            sessionId: request.sessionId,
            pendingId: request.requestId ?? request.userEntryId,
            encodesInBackground: !request.images.isEmpty
        )
        // Count the skills at once, like the desktop composer, until the metrics catch up.
        guard current == generation else { return }
        for reference in request.skillReferences {
            skillUsageCounts[reference.name.lowercased(), default: 0] += 1
        }
    }

    // Asks the desktop to compact the conversation context (desktop `/compact`); like a turn, it
    // reports run status and stream events. Focus text stays empty so older desktops ignore it.
    func compactSession(id sessionId: String) async throws {
        let requestId = "compact-\(UUID().uuidString.lowercased())"
        let request: JSONValue = [
            "requestId": .string(requestId),
            "sessionId": .string(sessionId),
            "text": "",
            "action": "compact",
        ]
        try await callDelegateRun(request, sessionId: sessionId, pendingId: requestId, isCompaction: true)
    }

    // Asks the desktop to resume an interrupted or paused conversation turn (desktop `resumeSession`).
    func resumeSession(id sessionId: String) async throws {
        let requestId = "resume-\(UUID().uuidString.lowercased())"
        let request: JSONValue = [
            "requestId": .string(requestId),
            "sessionId": .string(sessionId),
            "text": "",
            "action": "resume",
        ]
        try await callDelegateRun(request, sessionId: sessionId, pendingId: requestId)
    }

    // Shows the conversation as running until the desktop reports the delegated run.
    private func callDelegateRun(
        _ request: JSONValue,
        sessionId: String,
        pendingId: String,
        encodesInBackground: Bool = false,
        isCompaction: Bool = false
    ) async throws {
        bumpRunSequence(sessionId)
        recentlyAbortedRuns[sessionId] = nil
        pendingRunVerifications[sessionId] = nil
        var optimisticRunId: String?
        if activeRuns[sessionId] == nil {
            let runId = Self.optimisticRunPrefix + pendingId
            optimisticRunId = runId
            activeRuns[sessionId] = ActiveRun(sessionId: sessionId, runId: runId, status: "running")
            if !isSubAgentSession(sessionId), runOutcomes[sessionId] == nil {
                runOutcomes[sessionId] = TrackedRunOutcome(
                    runId: runId,
                    baselineUpdatedAt: session(id: sessionId)?.updatedAt ?? 0,
                    sawCompaction: isCompaction,
                    isExplicitCompaction: isCompaction
                )
            }
            Task { @MainActor [weak self] in
                // Drop the placeholder if the desktop never reports the run.
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.activeRuns[sessionId]?.runId == runId else { return }
                self.activeRuns[sessionId] = nil
                if self.runOutcomes[sessionId]?.runId == runId {
                    self.runOutcomes[sessionId] = nil
                }
            }
        }
        do {
            _ = try await call("session:delegateRun", [request], encodesInBackground: encodesInBackground)
        } catch {
            if let optimisticRunId, activeRuns[sessionId]?.runId == optimisticRunId {
                activeRuns[sessionId] = nil
                if runOutcomes[sessionId]?.runId == optimisticRunId {
                    runOutcomes[sessionId] = nil
                }
            }
            throw error
        }
    }

    // Changes the model, reasoning level or speed used for the next turns of a conversation.
    func setSessionRuntime(id sessionId: String, modelId: String? = nil, reasoningEffort: String? = nil, speed: String? = nil) async throws {
        var meta: [String: JSONValue] = ["id": .string(sessionId)]
        if let modelId {
            meta["modelId"] = .string(modelId)
        }
        if let reasoningEffort {
            meta["reasoningEffort"] = .string(reasoningEffort)
        }
        if let speed {
            meta["speed"] = .string(speed)
        }
        guard meta.count > 1 else { return }
        // No local write: the desktop broadcasts `session:meta-updated` to every client (including
        // this one) before replying, so local state only ever reflects authoritative values.
        _ = try await call("session:setMeta", [.object(meta)])
    }

    func abortRun(sessionId: String) async throws {
        markSessionAborted(sessionId)
        _ = try await call("session:abortRun", [.string(sessionId)])
        if activeRuns[sessionId]?.runId.hasPrefix(Self.optimisticRunPrefix) == true {
            activeRuns[sessionId] = nil
        }
    }

    func renameSession(id sessionId: String, title: String) async throws {
        _ = try await call("session:setMeta", [["id": .string(sessionId), "title": .string(title)]])
    }

    // Archiving keeps the list position, like the desktop's `archiveSession`.
    func archiveSession(id sessionId: String) async throws {
        try await setSessionMeta(sessionId, ["archivedAt": .number(Date().milliseconds)], keepsUpdatedAt: true)
    }

    // MARK: - Sidebar actions (desktop project and conversation menus)

    func setSessionPinned(id sessionId: String, pinned: Bool) async throws {
        try await setSessionMeta(sessionId, ["pinned": .bool(pinned)])
    }

    // Moves a conversation into a project, or out of every project when `projectId` is nil.
    func moveSession(id sessionId: String, toProject projectId: String?) async throws {
        try await setSessionMeta(sessionId, ["projectId": .optional(projectId)])
    }

    // Read state changes keep the list position (desktop `markRead` / `markUnreadManually`).
    func setSessionUnread(id sessionId: String, unread: Bool) async throws {
        bumpViewEpoch(sessionId)
        viewedWatermarks[sessionId] = nil
        flushedAmbiguousReads[sessionId] = nil
        let epochAtStart = sessionViewEpochs[sessionId, default: 0]
        let runSeqAtStart = sessionRunSequences[sessionId, default: 0]
        let genAtStart = generation
        pendingRunVerifications[sessionId]?.capturedWhileRunning = false
        pendingRunVerifications[sessionId]?.unreadSuppressed = true
        let previousPending = pendingUnreadStates.removeValue(forKey: sessionId)
        let previousReadIntent = readSyncIntents.removeValue(forKey: sessionId)
        let previousUnread = session(id: sessionId)?.unread
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[index].unread = unread ? .unread : .read
        }
        if !unread {
            inFlightManualReadIds.insert(sessionId)
        }
        do {
            try await setSessionMeta(sessionId, ["unread": .bool(unread)], keepsUpdatedAt: true)
            inFlightManualReadIds.remove(sessionId)
            if readSyncIntents[sessionId] != nil || viewedSessionIds[sessionId] != nil {
                flushReadSync(sessionId)
            }
        } catch {
            inFlightManualReadIds.remove(sessionId)
            if generation == genAtStart,
               sessionRunSequences[sessionId, default: 0] == runSeqAtStart
            {
                if viewedSessionIds[sessionId] != nil || readSyncIntents[sessionId] != nil {
                    if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
                        sessions[index].unread = .read
                    }
                    if readSyncIntents[sessionId] == nil {
                        requestReadSync(sessionId)
                    }
                    flushReadSync(sessionId)
                } else if sessionViewEpochs[sessionId, default: 0] == epochAtStart {
                    if let previousPending {
                        pendingUnreadStates[sessionId] = previousPending
                    }
                    if let previousReadIntent, readSyncIntents[sessionId] == nil {
                        readSyncIntents[sessionId] = previousReadIntent
                    }
                    if let previousUnread, let index = sessions.firstIndex(where: { $0.id == sessionId }) {
                        sessions[index].unread = previousUnread
                    }
                }
            }
            throw error
        }
    }

    // A shown conversation stays read, as the desktop's current conversation does. Checked again
    // whenever its metadata changes and after every resync, so failed or offline marks are retried.
    func beginViewing(sessionId: String) {
        if state == .connected, pendingRunVerifications[sessionId]?.capturedWhileRunning != true {
            bumpViewEpoch(sessionId)
            pendingRunVerifications[sessionId]?.unreadSuppressed = true
            flushedAmbiguousReads[sessionId] = nil
        }
        viewedSessionIds[sessionId, default: 0] += 1
        let hadPendingUnread = pendingUnreadStates.removeValue(forKey: sessionId) != nil
        let wasUnreadInList: Bool
        if let index = sessions.firstIndex(where: { $0.id == sessionId }), sessions[index].isUnread {
            sessions[index].unread = .read
            wasUnreadInList = true
        } else {
            wasUnreadInList = false
        }
        if wasUnreadInList
            || hadPendingUnread
            || inFlightUnreadSyncSequences[sessionId] != nil
            || inFlightManualReadIds.contains(sessionId)
        {
            recordViewedWatermark(sessionId)
            requestReadSync(sessionId)
        }
        flushReadSync(sessionId)
    }

    func endViewing(sessionId: String) {
        let count = (viewedSessionIds[sessionId] ?? 0) - 1
        viewedSessionIds[sessionId] = count > 0 ? count : nil
    }

    private func markUnreadIfUnviewed(
        _ sessionId: String,
        state: UnreadState,
        observedUpdatedAt: Double = 0,
        preservedUpdatedAt: Double? = nil
    ) {
        guard state != .read else { return }
        let candidateUpdatedAt = max(observedUpdatedAt, preservedUpdatedAt ?? 0)
        if let index = sessions.firstIndex(where: { $0.id == sessionId }),
           candidateUpdatedAt > sessions[index].updatedAt
        {
            sessions[index].updatedAt = candidateUpdatedAt
        }
        let currentRunSeq = sessionRunSequences[sessionId, default: 0]
        guard viewedSessionIds[sessionId] == nil else {
            recordViewedWatermark(sessionId, updatedAt: candidateUpdatedAt)
            return
        }
        viewedWatermarks[sessionId] = nil
        readSyncIntents[sessionId] = nil
        pendingUnreadStates[sessionId] = PendingUnreadSync(
            state: state,
            preservedUpdatedAt: preservedUpdatedAt,
            runSequence: currentRunSeq
        )
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[index].unread = state
        }
        syncPendingUnread(sessionId)
    }

    private func syncPendingUnread(_ sessionId: String) {
        guard viewedSessionIds[sessionId] == nil else {
            pendingUnreadStates[sessionId] = nil
            return
        }
        guard let target = pendingUnreadStates[sessionId],
              target.state != .read,
              session(id: sessionId) != nil,
              isConnected,
              inFlightUnreadSyncSequences[sessionId] == nil,
              !pendingReadIds.contains(sessionId)
        else {
            return
        }
        inFlightUnreadSyncSequences[sessionId] = target.runSequence
        let current = generation
        let rawValue: JSONValue = target.state == .error ? .string("error") : .bool(true)
        var fields: [String: JSONValue] = ["unread": rawValue]
        if let preservedUpdatedAt = target.preservedUpdatedAt, preservedUpdatedAt > 0 {
            fields["updatedAt"] = .number(preservedUpdatedAt)
        }
        Task {
            let succeeded = (try? await setSessionMeta(sessionId, fields, keepsUpdatedAt: false)) != nil
            inFlightUnreadSyncSequences[sessionId] = nil
            guard current == generation else { return }
            if succeeded, pendingUnreadStates[sessionId] == target {
                pendingUnreadStates[sessionId] = nil
            }
            if readSyncIntents[sessionId] != nil || viewedSessionIds[sessionId] != nil {
                flushReadSync(sessionId)
            } else if succeeded, pendingUnreadStates[sessionId] != nil {
                syncPendingUnread(sessionId)
            }
        }
    }

    private func flushReadSync(_ sessionId: String) {
        if viewedSessionIds[sessionId] != nil,
           let index = sessions.firstIndex(where: { $0.id == sessionId }),
           sessions[index].isUnread
        {
            let targetUpdatedAt = sessions[index].updatedAt
            sessions[index].unread = .read
            requestReadSync(sessionId, upTo: targetUpdatedAt)
        }
        guard let intentAtStart = readSyncIntents[sessionId],
              session(id: sessionId) != nil,
              isConnected,
              !pendingReadIds.contains(sessionId),
              inFlightUnreadSyncSequences[sessionId] == nil,
              !inFlightManualReadIds.contains(sessionId)
        else {
            return
        }
        pendingReadIds.insert(sessionId)
        let current = generation
        Task {
            if let serverUnread = intentAtStart.pendingServerUnread,
               viewedSessionIds[sessionId] == nil
            {
                let detail = try? await call("session:get", [.string(sessionId)])
                guard current == generation, state == .connected else {
                    pendingReadIds.remove(sessionId)
                    return
                }
                guard let detail, detail["entries"]?.arrayValue != nil else {
                    pendingReadIds.remove(sessionId)
                    return
                }
                if viewedSessionIds[sessionId] == nil,
                   readSyncIntents[sessionId]?.revision == intentAtStart.revision
                {
                    let entries = detail["entries"]?.decodeList(ConversationEntry.self) ?? []
                    let outcome = Self.classifyTerminalOutcome(of: entries, after: intentAtStart.maxUpdatedAt)
                    let hasNewerTurnActivity = entries.contains { entry in
                        guard entry.kind != .unknown, entry.kind != .compaction else { return false }
                        return max(entry.completedAt ?? 0, entry.createdAt) > intentAtStart.maxUpdatedAt
                    }
                    if outcome == .completed || outcome == .error || (hasNewerTurnActivity && outcome != .settledIncomplete) {
                        pendingReadIds.remove(sessionId)
                        readSyncIntents[sessionId] = nil
                        let restored: UnreadState = outcome == .error
                            ? .error
                            : (outcome == .completed ? .unread : serverUnread)
                        let latestEntryTimestamp = entries.map { max($0.completedAt ?? 0, $0.createdAt) }.max() ?? 0
                        let repairedUpdatedAt = max(session(id: sessionId)?.updatedAt ?? 0, latestEntryTimestamp)
                        markUnreadIfUnviewed(sessionId, state: restored, preservedUpdatedAt: repairedUpdatedAt)
                        return
                    }
                    readSyncIntents[sessionId]?.pendingServerUnread = nil
                    if flushedAmbiguousReads[sessionId] == nil,
                       flushedAmbiguousReads.count >= Self.maxPendingVerifications,
                       let oldestKey = flushedAmbiguousReads.min(by: { $0.value.capturedAt < $1.value.capturedAt })?.key
                    {
                        flushedAmbiguousReads.removeValue(forKey: oldestKey)
                    }
                    flushedAmbiguousReads[sessionId] = FlushedAmbiguousRead(
                        maxUpdatedAt: intentAtStart.maxUpdatedAt,
                        fallbackUnread: serverUnread,
                        viewEpoch: sessionViewEpochs[sessionId, default: 0],
                        capturedAt: Date().milliseconds
                    )
                }
            }

            let succeeded = (try? await setSessionMeta(sessionId, ["unread": .bool(false)], keepsUpdatedAt: true)) != nil
            pendingReadIds.remove(sessionId)
            guard current == generation else { return }
            if succeeded {
                if pendingUnreadStates[sessionId] == nil,
                   readSyncIntents[sessionId]?.revision == intentAtStart.revision
                {
                    readSyncIntents[sessionId] = nil
                    if sessionRunSequences[sessionId, default: 0] == intentAtStart.runSequenceAtRead {
                        recordViewedWatermark(sessionId, updatedAt: intentAtStart.maxUpdatedAt)
                    }
                }
                if pendingUnreadStates[sessionId] != nil, viewedSessionIds[sessionId] == nil {
                    syncPendingUnread(sessionId)
                } else if readSyncIntents[sessionId] != nil {
                    flushReadSync(sessionId)
                }
            }
        }
    }

    private func recheckFlushedAmbiguousRead(sessionId: String, generation current: Int) async {
        guard current == generation,
              state == .connected,
              let watch = flushedAmbiguousReads[sessionId],
              viewedSessionIds[sessionId] == nil,
              sessionViewEpochs[sessionId, default: 0] == watch.viewEpoch,
              activeRuns[sessionId] == nil
        else {
            return
        }
        let detail = try? await call("session:get", [.string(sessionId)])
        guard current == generation,
              state == .connected,
              flushedAmbiguousReads[sessionId] == watch,
              viewedSessionIds[sessionId] == nil,
              sessionViewEpochs[sessionId, default: 0] == watch.viewEpoch,
              activeRuns[sessionId] == nil,
              let entries = detail?["entries"]?.decodeList(ConversationEntry.self)
        else {
            return
        }
        let outcome = Self.classifyTerminalOutcome(of: entries, after: watch.maxUpdatedAt)
        let hasNewerTurnActivity = entries.contains { entry in
            guard entry.kind != .unknown, entry.kind != .compaction else { return false }
            return max(entry.completedAt ?? 0, entry.createdAt) > watch.maxUpdatedAt
        }
        guard outcome == .completed || outcome == .error || (hasNewerTurnActivity && outcome != .settledIncomplete) else {
            return
        }
        flushedAmbiguousReads[sessionId] = nil
        let restored: UnreadState = outcome == .error
            ? .error
            : (outcome == .completed ? .unread : watch.fallbackUnread)
        let latestEntryTimestamp = entries.map { max($0.completedAt ?? 0, $0.createdAt) }.max() ?? 0
        let repairedUpdatedAt = max(session(id: sessionId)?.updatedAt ?? 0, latestEntryTimestamp)
        markUnreadIfUnviewed(sessionId, state: restored, preservedUpdatedAt: repairedUpdatedAt)
    }

    // No local write: the desktop broadcasts `session:meta-updated` to every client before replying.
    private func setSessionMeta(_ sessionId: String, _ fields: [String: JSONValue], keepsUpdatedAt: Bool = false) async throws {
        var meta = fields
        meta["id"] = .string(sessionId)
        if keepsUpdatedAt, let updatedAt = session(id: sessionId)?.updatedAt, updatedAt > 0 {
            meta["updatedAt"] = .number(updatedAt)
        }
        _ = try await call("session:setMeta", [.object(meta)])
    }

    // Copies a conversation into a new one (desktop `forkSession`). With `worktree`, the copy works in
    // a new git worktree that the desktop creates from that branch before the copy's next turn runs.
    // With `atEntryId`, the copy holds only the entries up to that message and its trailing tool
    // results, like the desktop's fork from a message.
    func forkSession(id sessionId: String, atEntryId: String? = nil, worktree: WorktreeFork? = nil) async throws -> String {
        let snapshot = try await call("session:get", [.string(sessionId)])
        guard let sourceEntries = snapshot["entries"]?.arrayValue else {
            throw DesktopClientError.remote("无法读取对话内容")
        }
        // A sub-agent conversation is not in the session list (desktop `listSessions` filters
        // `is_subagent = 0`), and `session:get` does not return its project, branch or title either;
        // forking it without the desktop's `getMeta` RPC would silently drop that context, so it is
        // refused instead.
        guard let source = session(id: sessionId) else {
            throw DesktopClientError.remote("子代理对话暂不支持分叉")
        }
        let newId = UUID().uuidString.lowercased()
        // Forks from a message end after its trailing tool results; other ids (or none) copy everything.
        var sliced = sourceEntries
        if let atEntryId {
            // Like the desktop `forkSession`: the id may name an entry or a content block of an
            // assistant message (a merged turn id); an unknown id copies the whole conversation.
            let targetIndex = sourceEntries.firstIndex(where: { $0["id"]?.stringValue == atEntryId })
                ?? sourceEntries.firstIndex(where: { entry in
                    guard entry["kind"]?.stringValue == "assistant" else { return false }
                    return entry["content"]?.arrayValue?.contains { $0["id"]?.stringValue == atEntryId } ?? false
                })
            if let targetIndex {
                var endIndex = targetIndex + 1
                while endIndex < sourceEntries.count, sourceEntries[endIndex]["kind"]?.stringValue == "toolResult" {
                    endIndex += 1
                }
                sliced = Array(sourceEntries[..<endIndex])
            }
        }
        let entries = sliced.map { entry -> JSONValue in
            guard var object = entry.objectValue else { return entry }
            object["id"] = .string(UUID().uuidString.lowercased())
            object["sessionId"] = .string(newId)
            if object["kind"]?.stringValue == "assistant", object["status"]?.stringValue == "streaming" {
                object["status"] = "done"
            }
            return .object(object)
        }

        let baseTitle = source.title.isEmpty ? "Chat" : source.title
        let workLocation = worktree == nil ? source.workLocation : WorkLocation.worktree.rawValue
        // A worktree copy never shares the source's worktree; the desktop creates a new one.
        let isNewWorktree = workLocation == WorkLocation.worktree.rawValue
        let now = Date().milliseconds
        var meta: [String: JSONValue] = [
            "id": .string(newId),
            "title": .string(baseTitle.hasSuffix(" (Fork)") ? baseTitle : "\(baseTitle) (Fork)"),
            "pinned": false,
            "unread": false,
            "createdAt": .number(now),
            "updatedAt": .number(now),
        ]
        let optionalFields: [String: String?] = [
            "projectId": source.projectId,
            "branch": worktree.map(\.branch) ?? source.branch,
            "baseBranch": source.baseBranch,
            "workLocation": workLocation,
            "worktreePath": isNewWorktree ? nil : source.worktreePath,
            "environmentId": worktree == nil ? source.environmentId : worktree?.environmentId,
            "modelId": source.modelId,
            "reasoningEffort": source.reasoningEffort,
            "speed": source.speed,
        ]
        for (key, value) in optionalFields {
            if let value {
                meta[key] = .string(value)
            }
        }
        if let firstPromptAt = source.firstPromptAt, firstPromptAt > 0 {
            meta["firstPromptAt"] = .number(firstPromptAt)
        }
        if !isNewWorktree, let worktreeSetup = source.worktreeSetup {
            meta["worktreeSetup"] = worktreeSetup
        }

        var payload = meta
        payload["entries"] = .array(entries)
        _ = try await call("session:set", [.string(newId), .object(payload)], timeout: 60)
        // `session:set` only reports new entries; the metadata write announces the conversation to
        // the desktop and every client before it replies.
        _ = try await call("session:setMeta", [.object(meta)])
        return newId
    }

    func setProjectPinned(id projectId: String, pinned: Bool) async throws {
        try await updateProject(id: projectId) { project in
            project["pinned"] = .bool(pinned)
        }
    }

    // Renames a project and replaces its source folders (desktop `ProjectEditDialog`).
    func updateProject(id projectId: String, name: String, paths: [String]) async throws {
        try await updateProject(id: projectId) { project in
            project["name"] = .string(name)
            project["paths"] = .array(paths.map(JSONValue.string))
            // The legacy primary path follows the folder list.
            project["path"] = paths.first.map(JSONValue.string)
        }
    }

    // Removes a project from the app; its conversations become uncategorized and no files are deleted.
    func removeProject(id projectId: String) async throws {
        for session in sessions where session.projectId == projectId {
            try await moveSession(id: session.id, toProject: nil)
        }
        try await updateProjects { projects in
            projects.filter { $0["id"]?.stringValue != projectId }
        }
    }

    private func updateProject(id projectId: String, _ change: @escaping (inout [String: JSONValue]) -> Void) async throws {
        try await updateProjects { projects in
            guard projects.contains(where: { $0["id"]?.stringValue == projectId }) else {
                throw DesktopClientError.remote("项目不存在")
            }
            return projects.map { project in
                guard project["id"]?.stringValue == projectId, var object = project.objectValue else { return project }
                change(&object)
                object["updatedAt"] = .number(Date().milliseconds)
                return .object(object)
            }
        }
    }

    // Read-modify-write of the raw project list, so fields unknown to this app are kept. Writes from
    // this app run one at a time so they never overwrite each other. No local write: the desktop
    // broadcasts `projects:updated` to its window and every client before replying.
    private func updateProjects(_ transform: @escaping ([JSONValue]) throws -> [JSONValue]) async throws {
        let previous = projectWrites
        let write = Task {
            await previous?.value
            let stored = try await call("kvstore:get", ["projects"])
            guard let list = stored.isNull ? [] : stored.arrayValue else {
                throw DesktopClientError.remote("无法读取项目列表")
            }
            _ = try await call("kvstore:set", ["projects", .array(try transform(list))])
        }
        projectWrites = Task {
            _ = try? await write.value
        }
        try await write.value
    }

    // Link that opens the conversation in the desktop's Web frontend (desktop "copy deep link").
    func deepLink(sessionId: String) -> String? {
        guard let base = connection.httpBaseURL else { return nil }
        return "\(base.absoluteString)/#/chat/\(sessionId)"
    }

    // MARK: - Desktop folders

    func homeDirectory() async throws -> String {
        let info = try await call("native:runtimeInfo")
        guard let homeDir = info["homeDir"]?.stringValue, !homeDir.isEmpty else {
            return "/"
        }
        return homeDir
    }

    // Entries of a desktop folder (files and folders); symbolic links are skipped like the
    // desktop's browser. Names are sorted with folders first (desktop FileManager order).
    func directoryEntries(of path: String) async throws -> [(name: String, isDir: Bool)] {
        let value = try await call("native:readDir", [.string(path)], timeout: 15)
        guard let entries = value.arrayValue else {
            throw DesktopClientError.remote("文件夹不存在")
        }
        return entries
            .compactMap { entry -> (name: String, isDir: Bool)? in
                guard entry["isSymbolicLink"]?.boolValue != true,
                      let name = entry["name"]?.stringValue
                else {
                    return nil
                }
                return (name, entry["isDir"]?.boolValue == true)
            }
            .sorted { lhs, rhs in
                if lhs.isDir != rhs.isDir {
                    return lhs.isDir
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    // Reads a text file on the desktop (desktop `native:readFile`); fails for missing files.
    func readFile(at path: String) async throws -> String {
        let value = try await call("native:readFile", [.string(path)], timeout: 30)
        guard let encoded = value["dataBase64"]?.stringValue,
              let data = Data(base64Encoded: encoded)
        else {
            throw DesktopClientError.remote("无法读取文件")
        }
        return String(decoding: data, as: UTF8.self)
    }

    // Runs a git command in a desktop folder (desktop `services.process.run` used by the
    // review panel); stdout is decoded as UTF-8. Non-zero exits return nil, like the desktop
    // helper that falls back or reports "not a git repo".
    func runGit(_ args: [String], cwd: String) async -> (exitCode: Int, stdout: String)? {
        let request: JSONValue = [
            "operationId": .string("ios-git-\(UUID().uuidString)"),
            "executable": "git",
            "args": .array(args.map { .string($0) }),
            "cwd": .string(cwd),
            "env": nil,
        ]
        guard let result = try? await call("native:runProcess", [request], timeout: 30),
              let exitCode = result["exitCode"]?.doubleValue
        else {
            return nil
        }
        var stdout = ""
        if let encoded = result["stdoutBase64"]?.stringValue,
           let data = Data(base64Encoded: encoded) {
            stdout = String(decoding: data, as: UTF8.self)
        }
        return (Int(exitCode), stdout)
    }

    // Sub-folder names of a desktop folder; symbolic links are skipped like the desktop's browser.
    func subdirectories(of path: String) async throws -> [String] {
        let value = try await call("native:readDir", [.string(path)], timeout: 15)
        guard let entries = value.arrayValue else {
            throw DesktopClientError.remote("文件夹不存在")
        }
        return entries
            .compactMap { $0["isDir"]?.boolValue == true ? $0["name"]?.stringValue : nil }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Attachments

    // Copies files attached on this device to the desktop, into `<home>/<app config folder>/attachments/<session id>`,
    // and returns their desktop paths in order. Like the desktop composer's file attachments, the prompt then
    // references them as `@path` for the agent to read. Existing files are never overwritten.
    func uploadAttachments(_ files: [(name: String, data: Data)], sessionId: String) async throws -> [String] {
        guard !files.isEmpty else { return [] }
        let info = try await call("native:runtimeInfo")
        guard let homeDir = info["homeDir"]?.stringValue, !homeDir.isEmpty else {
            throw DesktopClientError.remote("无法获取桌面端主目录")
        }
        let configDirName = info["appConfigDirName"]?.stringValue
            ?? (info["isDebug"]?.boolValue == true ? ".coding-professional-agent-dev" : ".coding-professional-agent")
        let folder = "\(homeDir)/\(configDirName)/attachments/\(Self.safeFileName(sessionId))"
        var paths: [String] = []
        for file in files {
            let name = Self.safeFileName(file.name)
            var path = "\(folder)/\(name)"
            var copy = 1
            while try await call("native:fileExists", [.string(path)]).boolValue == true {
                copy += 1
                path = "\(folder)/\(Self.numberedFileName(name, copy))"
            }
            let data = file.data
            let encoded = await Task.detached(priority: .userInitiated) { data.base64EncodedString() }.value
            // Large files take a while to transfer as base64 over the socket.
            _ = try await call("native:writeFile", [.string(path), .string(encoded)], timeout: 300, encodesInBackground: true)
            paths.append(path)
        }
        return paths
    }

    // A single path component: separators and control characters become "_".
    private static func safeFileName(_ name: String) -> String {
        let cleaned = String(name.unicodeScalars.map { scalar in
            scalar == "/" || scalar == "\\" || scalar == ":" || CharacterSet.controlCharacters.contains(scalar) ? "_" : Character(scalar)
        })
        .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "file" : cleaned
    }

    // "name.ext" -> "name (2).ext".
    private static func numberedFileName(_ name: String, _ number: Int) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return ext.isEmpty || base.isEmpty ? "\(name) (\(number))" : "\(base) (\(number)).\(ext)"
    }

    // Projects with a worktree environment file (desktop `ContinueInWorktreeModal` detection).
    func environmentProjects() async -> [RemoteProject] {
        let candidates = [
            ".cpa/environments/environment.toml",
            ".codex/environments/environment.toml",
            "environment.toml",
            ".cpa/environment.toml",
            ".codex/environment.toml",
        ]
        let projects = projects
        let found = await withTaskGroup(of: String?.self) { group in
            // A few projects at a time; cancelling the caller stops further reads.
            var pending = projects.makeIterator()
            func addNext() {
                guard let project = pending.next() else { return }
                group.addTask { [weak self] in
                    for folder in project.allPaths {
                        for candidate in candidates {
                            guard !Task.isCancelled else { return nil }
                            let file = try? await self?.call("native:readFileIfExists", [.string("\(folder)/\(candidate)")], timeout: 10)
                            if file?["dataBase64"] != nil {
                                return project.id
                            }
                        }
                    }
                    return nil
                }
            }
            for _ in 0..<4 {
                addNext()
            }
            var ids: Set<String> = []
            for await id in group {
                if let id {
                    ids.insert(id)
                }
                if !Task.isCancelled {
                    addNext()
                }
            }
            return ids
        }
        return projects.filter { found.contains($0.id) }
    }

    // Lists local git branches of a project folder on the desktop.
    func gitBranches(at path: String) async -> (current: String?, branches: [String]) {
        let request: JSONValue = [
            "operationId": .string("ios-git-\(UUID().uuidString)"),
            "executable": "git",
            "args": ["branch", "--format=%(HEAD)%(refname:short)"],
            "cwd": .string(path),
            "env": nil,
        ]
        guard let result = try? await call("native:runProcess", [request], timeout: 15),
              result["exitCode"]?.doubleValue == 0,
              let encoded = result["stdoutBase64"]?.stringValue,
              let data = Data(base64Encoded: encoded)
        else {
            return (nil, [])
        }
        var current: String?
        var branches: [String] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let isCurrent = line.hasPrefix("*")
            let name = line.dropFirst().trimmingCharacters(in: .whitespaces)
            // Skip entries such as "(HEAD detached at 1a2b3c)".
            guard !name.isEmpty, !name.hasPrefix("(") else { continue }
            branches.append(name)
            if isCurrent {
                current = name
            }
        }
        return (current, branches)
    }

    // MARK: - Skills

    // Enabled skills for a project folder, most used first, then by name (desktop `buildSkillSuggestions`).
    func skills(forProjectPath projectPath: String?) -> [RemoteSkill] {
        (skillsByProjectPath[projectPath ?? ""] ?? [])
            .filter { defaults.isSkillEnabled($0.name) }
            .sorted { lhs, rhs in
                let lhsCount = skillUsageCounts[lhs.id] ?? 0
                let rhsCount = skillUsageCounts[rhs.id] ?? 0
                if lhsCount != rhsCount {
                    return lhsCount > rhsCount
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    // Re-reads usage counts from the desktop's skill metrics (desktop `fetchUsageCounts`).
    // At most one query per second; requests made meanwhile are coalesced into a single follow-up.
    func refreshSkillUsage() {
        guard isConnected else { return }
        guard !isLoadingSkillUsage else {
            needsSkillUsageReload = true
            return
        }
        isLoadingSkillUsage = true
        let current = generation
        let delay = max(0, 1 - Date().timeIntervalSince(lastSkillUsageFetch))
        Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard let self else { return }
            var value: JSONValue?
            if current == self.generation {
                self.lastSkillUsageFetch = Date()
                value = try? await self.call("session:queryMetrics", [["topSkillsLimit": 10000]])
            }
            self.applySkillUsage(value, generation: current)
        }
    }

    private func applySkillUsage(_ value: JSONValue?, generation current: Int) {
        isLoadingSkillUsage = false
        if current == generation, let topSkills = value?["summary"]?["topSkills"]?.arrayValue {
            var counts: [String: Int] = [:]
            for item in topSkills {
                guard let name = item["name"]?.stringValue, let count = item["count"]?.doubleValue else { continue }
                counts[name.lowercased()] = Int(count)
            }
            // Like the desktop store, keep local counts that the metrics have not caught up with yet.
            skillUsageCounts = counts.merging(skillUsageCounts, uniquingKeysWith: max)
        }
        if needsSkillUsageReload {
            needsSkillUsageReload = false
            refreshSkillUsage()
        }
    }

    // Scans the same skill folders as the desktop Web composer (`useComposerSkills`):
    // the app agent skills, the user's config folder and the project's `.cpa/skills`.
    func loadSkills(projectPath: String?) async {
        guard isConnected else { return }
        let key = projectPath ?? ""
        let current = generation
        // A newer scan of the same folder supersedes this one.
        let scan = (skillScans[key] ?? 0) + 1
        skillScans[key] = scan
        func isCurrent() -> Bool {
            !Task.isCancelled && current == generation && skillScans[key] == scan
        }
        guard let info = try? await call("native:runtimeInfo"), isCurrent() else { return }
        var roots: [String] = []
        if let userConfigDir = info["userConfigDir"]?.stringValue, !userConfigDir.isEmpty {
            roots.append("\(userConfigDir)/coding-professional-agent/agent/skills")
        }
        if let homeDir = info["homeDir"]?.stringValue, !homeDir.isEmpty {
            let configDirName = info["appConfigDirName"]?.stringValue
                ?? (info["isDebug"]?.boolValue == true ? ".coding-professional-agent-dev" : ".coding-professional-agent")
            roots.append("\(homeDir)/\(configDirName)/skills")
        }
        if let projectPath, !projectPath.isEmpty {
            roots.append("\(projectPath)/.cpa/skills")
        }

        var discovered: [RemoteSkill] = []
        var seenNames: Set<String> = []
        var visited: Set<String> = []
        for root in roots {
            // Depth-first in directory order, so the first skill with a given name wins as on the desktop.
            var stack = [root]
            var scannedInRoot = 0
            while let dir = stack.popLast() {
                guard isCurrent() else { return }
                // The budget is per root so a large folder never hides the following ones.
                guard !visited.contains(dir), scannedInRoot < Self.maxSkillDirectoriesPerRoot else { continue }
                visited.insert(dir)
                scannedInRoot += 1
                async let fileValue = try? call("native:readFileIfExists", [.string("\(dir)/SKILL.md")], timeout: 10)
                async let entriesValue = try? call("native:readDir", [.string(dir)], timeout: 10)
                let (file, entries) = await (fileValue, entriesValue)
                guard isCurrent() else { return }
                if let encoded = file?["dataBase64"]?.stringValue,
                   let data = Data(base64Encoded: encoded),
                   let skill = Self.parseSkill(String(decoding: data, as: UTF8.self), dir: dir),
                   seenNames.insert(skill.name.lowercased()).inserted
                {
                    discovered.append(skill)
                }
                // Symlinked directories are not followed, matching the desktop.
                let children = (entries?.arrayValue ?? []).compactMap { entry -> String? in
                    guard entry["isDir"]?.boolValue == true,
                          entry["isSymbolicLink"]?.boolValue != true,
                          let name = entry["name"]?.stringValue,
                          !Self.skippedSkillDirectories.contains(name)
                    else {
                        return nil
                    }
                    return "\(dir)/\(name)"
                }
                stack.append(contentsOf: children.reversed())
            }
        }
        guard isCurrent() else { return }
        skillsByProjectPath[key] = discovered
    }

    // Bounds the number of RPC round trips for unexpectedly large skill folders.
    private static let maxSkillDirectoriesPerRoot = 400
    private static let skippedSkillDirectories: Set<String> = ["node_modules", ".git"]

    // Reads `name` and `description` from the SKILL.md front matter, like the desktop's simple parser.
    private static func parseSkill(_ content: String, dir: String) -> RemoteSkill? {
        let directoryName = dir.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? dir
        var frontMatter: [String: String] = [:]
        if content.hasPrefix("---") {
            let body = content.dropFirst(3)
            if let end = body.range(of: "\n---") {
                for line in body[..<end.lowerBound].split(whereSeparator: \.isNewline) {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                    var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if value.count >= 2,
                       (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'"))
                    {
                        value = String(value.dropFirst().dropLast())
                    }
                    frontMatter[key] = value
                }
            }
        }
        let name = frontMatter["name"].flatMap { $0.isEmpty ? nil : $0 } ?? directoryName
        guard !name.isEmpty else { return nil }
        return RemoteSkill(name: name, description: frontMatter["description"] ?? "", filePath: "\(dir)/SKILL.md")
    }

    // MARK: - Ask tool

    // Returns nil when the session has no pending question; throws when the lookup failed.
    func askRequest(sessionId: String) async throws -> AskRequest? {
        let value = try await call("ask:getRequests", [["sessionId": .string(sessionId)]])
        return try? value["request"]?.decode(AskRequest.self)
    }

    func submitAsk(sessionId: String, toolCallId: String, decision: AskDecision) async throws {
        _ = try await call("ask:submitAnswer", [.string(sessionId), .string(toolCallId), decision.json])
    }

    // Stops the desktop from auto-selecting the recommended option while the user types.
    func cancelAskCountdown(sessionId: String, toolCallId: String) async throws -> Bool {
        try await call("ask:cancelCountdown", [.string(sessionId), .string(toolCallId)]).boolValue == true
    }

    // MARK: - Push notifications

    // Registers this iOS device token with the desktop; ignores RPC errors from older desktops.
    func registerNotificationClient(_ registration: NotificationClientRegistration) async {
        _ = try? await call("notification:registerClient", [registration.json])
    }

    // Unregisters this iOS device from the desktop; ignores RPC errors from older desktops.
    func unregisterNotificationClient(clientId: String, connectionId: String) async {
        let payload: JSONValue = [
            "clientId": .string(clientId),
            "connectionId": .string(connectionId),
        ]
        _ = try? await call("notification:unregisterClient", [payload])
    }

    // MARK: - Helpers

    private static func checkHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw DesktopClientError.http(0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DesktopClientError.http(http.statusCode)
        }
    }

    private static func errorMessage(in message: JSONValue) -> String {
        if let text = message["error"]?.stringValue {
            return text
        }
        if let text = message["error"]?["message"]?.stringValue {
            return text
        }
        if let text = message["errorDto"]?["message"]?.stringValue {
            return text
        }
        return "RPC 调用失败"
    }

    private static func describe(_ error: Error) -> String {
        if let clientError = error as? DesktopClientError {
            return clientError.errorDescription ?? "连接失败"
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .networkConnectionLost:
                return "无法连接到桌面端"
            case .cannotFindHost, .dnsLookupFailed:
                return "找不到主机"
            case .timedOut:
                return "连接超时"
            case .notConnectedToInternet:
                return "网络不可用"
            default:
                break
            }
        }
        return "连接已断开"
    }
}
