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
    private(set) var state: ConnectionState = .disconnected
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
    // Conversations on screen (view count by id) and their in-flight "mark read" requests.
    @ObservationIgnored private var viewedSessionIds: [String: Int] = [:]
    @ObservationIgnored private var pendingReadIds: Set<String> = []
    // Tail of the serialized project list writes.
    @ObservationIgnored private var projectWrites: Task<Void, Never>?
    // RPC messages waiting for a large one encoded in the background, so they are sent in call order.
    @ObservationIgnored private var sendQueue: Task<Void, Never>?
    @ObservationIgnored private var queuedSends = 0

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
        closeSocket()
        releaseTunnelLease()
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
                handleMessage(Data(text.utf8))
            case .data(let data):
                handleMessage(data)
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
            handleMessage(data)
        }
    }

    private func closeSocket() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        tunnelStream?.close(code: 1000, reason: "")
        tunnelStream = nil
        serverClientId = nil
        failPending(DesktopClientError.notConnected)
    }

    private func socketClosed(error: Error, authRejected: Bool) {
        socket = nil
        tunnelStream = nil
        serverClientId = nil
        failPending(DesktopClientError.notConnected)
        guard shouldRun else {
            state = .disconnected
            return
        }
        if authRejected {
            // The desktop restarted or its password changed; log in again.
            cookie = nil
        }
        if connection.mode == .tunnel, let session = activeTunnelSession {
            if case .failed(let terminalMessage) = session.phase {
                state = .failed(terminalMessage)
                return
            }
            if session.hasReceivedInitialServerList, !session.isServerOnline(connection.tunnelServerUUID) {
                state = .failed("远程桌面端不在线")
                return
            }
        }
        scheduleReconnect(message: Self.describe(error))
    }

    private func handleConnectFailure(_ error: Error) {
        if case DesktopClientError.unauthorized = error {
            // A wrong password will not fix itself; wait for the user to edit the connection.
            state = .failed("密码错误")
            return
        }
        if error is TunnelProtocolError {
            state = .failed(error.localizedDescription)
            return
        }
        if connection.mode == .tunnel, let session = activeTunnelSession {
            if case .failed(let terminalMessage) = session.phase {
                state = .failed(terminalMessage)
                return
            }
            if session.hasReceivedInitialServerList, !session.isServerOnline(connection.tunnelServerUUID) {
                state = .failed("远程桌面端不在线")
                return
            }
        }
        scheduleReconnect(message: Self.describe(error))
    }

    private func scheduleReconnect(message: String) {
        retryCount += 1
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

    private func handleMessage(_ data: Data) {
        guard let message = JSONValue.parse(data) else { return }
        switch message["type"]?.stringValue {
        case "hello":
            serverClientId = message["clientId"]?.stringValue
            state = .connected
            retryCount = 0
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
                upsertSession(session)
            }
        case "session:deleted":
            if let sessionId = payload["sessionId"]?.stringValue {
                sessions.removeAll { $0.id == sessionId }
                activeRuns[sessionId] = nil
            }
        case "session:run-status":
            if let run = try? payload.decode(ActiveRun.self) {
                applyRunStatus(run)
            }
        case "session:entries-updated":
            // Saved entries update the desktop's skill metrics, as the desktop itself refetches here.
            refreshSkillUsage()
        case "session:subagent-state":
            for record in payload["agents"]?.decodeList(SubAgentRecord.self) ?? [] where !record.parentSessionId.isEmpty {
                upsertSubAgent(record)
            }
        default:
            break
        }

        emit(DesktopEvent(kind: kind, payload: payload))
    }

    private func upsertSession(_ incoming: RemoteSession) {
        defer {
            markReadIfViewed(incoming.id)
        }
        guard let index = sessions.firstIndex(where: { $0.id == incoming.id }) else {
            sessions.append(incoming)
            return
        }
        var merged = incoming
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
            activeRuns[run.sessionId] = run
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
        activeRuns[run.sessionId] = nil
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
        // Results of a superseded connection must not overwrite newer data.
        let current = generation
        let runsValue = try? await call("session:getActiveRuns")
        guard current == generation else { return }
        if let runsValue, runsValue.arrayValue != nil {
            var runs: [String: ActiveRun] = [:]
            for run in runsValue.decodeList(ActiveRun.self) where run.status != "idle" {
                runs[run.sessionId] = run
            }
            activeRuns = runs
        }
        let projectsValue = try? await call("kvstore:get", ["projects"])
        guard current == generation else { return }
        if let projectsValue, projectsValue.arrayValue != nil {
            projects = projectsValue.decodeList(RemoteProject.self)
        }
        let sessionsValue = try? await call("session:listSessions")
        guard current == generation else { return }
        if let sessionsValue, sessionsValue.arrayValue != nil {
            sessions = sessionsValue.decodeList(RemoteSession.self)
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
        refreshSkillUsage()
        for sessionId in viewedSessionIds.keys {
            markReadIfViewed(sessionId)
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
        try await callDelegateRun(request, sessionId: sessionId, pendingId: requestId)
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
        encodesInBackground: Bool = false
    ) async throws {
        var optimisticRunId: String?
        if activeRuns[sessionId] == nil {
            let runId = Self.optimisticRunPrefix + pendingId
            optimisticRunId = runId
            activeRuns[sessionId] = ActiveRun(sessionId: sessionId, runId: runId, status: "running")
            Task { @MainActor [weak self] in
                // Drop the placeholder if the desktop never reports the run.
                try? await Task.sleep(for: .seconds(20))
                if self?.activeRuns[sessionId]?.runId == runId {
                    self?.activeRuns[sessionId] = nil
                }
            }
        }
        do {
            _ = try await call("session:delegateRun", [request], encodesInBackground: encodesInBackground)
        } catch {
            if let optimisticRunId, activeRuns[sessionId]?.runId == optimisticRunId {
                activeRuns[sessionId] = nil
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
        try await setSessionMeta(sessionId, ["unread": .bool(unread)], keepsUpdatedAt: true)
    }

    // A shown conversation stays read, as the desktop's current conversation does. Checked again
    // whenever its metadata changes and after every resync, so failed or offline marks are retried.
    func beginViewing(sessionId: String) {
        viewedSessionIds[sessionId, default: 0] += 1
        markReadIfViewed(sessionId)
    }

    func endViewing(sessionId: String) {
        let count = (viewedSessionIds[sessionId] ?? 0) - 1
        viewedSessionIds[sessionId] = count > 0 ? count : nil
    }

    private func markReadIfViewed(_ sessionId: String) {
        guard viewedSessionIds[sessionId] != nil,
              isConnected,
              session(id: sessionId)?.isUnread == true,
              !pendingReadIds.contains(sessionId)
        else {
            return
        }
        pendingReadIds.insert(sessionId)
        Task {
            let succeeded = (try? await setSessionUnread(id: sessionId, unread: false)) != nil
            pendingReadIds.remove(sessionId)
            // Catch an unread broadcast that arrived mid-request; failures wait for the next event.
            if succeeded {
                markReadIfViewed(sessionId)
            }
        }
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
