import Foundation
import Observation
import UIKit

enum TunnelSessionPhase: Equatable, Sendable {
    case connecting
    case connected
    case reconnecting(Int)
    case failed(String)
}

@MainActor
final class TunnelWebSocketStream {
    let connId: String
    let serverUUID: String
    private weak var session: TunnelSession?
    private(set) var closeCode: Int?
    private var bufferedFrames: [Data] = []
    private var waitingReceiver: CheckedContinuation<Data, Error>?
    private var terminalError: Error?
    private var closedLocally = false

    init(connId: String, serverUUID: String, session: TunnelSession) {
        self.connId = connId
        self.serverUUID = serverUUID
        self.session = session
    }

    func receive() async throws -> Data {
        if !bufferedFrames.isEmpty {
            return bufferedFrames.removeFirst()
        }
        if let terminalError {
            throw terminalError
        }
        return try await withCheckedThrowingContinuation { continuation in
            waitingReceiver = continuation
        }
    }

    func sendText(_ text: String) async throws {
        guard !closedLocally, terminalError == nil, let session else {
            throw DesktopClientError.notConnected
        }
        try session.sendWSData(connId: connId, serverUUID: serverUUID, opcode: "text", body: Data(text.utf8))
    }

    func close(code: Int = 1000, reason: String = "") {
        guard !closedLocally else { return }
        closedLocally = true
        let wasOpen = terminalError == nil
        fail(DesktopClientError.notConnected, closeCode: code)
        if wasOpen {
            session?.closeClientWSStream(connId: connId, serverUUID: serverUUID, code: code, reason: reason)
        }
    }

    fileprivate func deliver(_ data: Data) {
        guard !closedLocally, terminalError == nil else { return }
        if let receiver = waitingReceiver {
            waitingReceiver = nil
            receiver.resume(returning: data)
        } else {
            bufferedFrames.append(data)
        }
    }

    fileprivate func fail(_ error: Error, closeCode: Int? = nil) {
        if let closeCode {
            self.closeCode = closeCode
        }
        guard terminalError == nil else { return }
        terminalError = error
        if let receiver = waitingReceiver {
            waitingReceiver = nil
            receiver.resume(throwing: error)
        }
    }
}

@MainActor
@Observable
final class TunnelSession: Identifiable {
    let id = UUID()
    let endpoint: TunnelEndpoint
    private(set) var phase: TunnelSessionPhase = .connecting
    private(set) var hasReceivedInitialServerList = false
    private(set) var servers: [DiscoveredTunnelServer] = []

    @ObservationIgnored fileprivate let apiKey: String
    @ObservationIgnored private let urlSession: URLSession
    @ObservationIgnored private let delegateProxy: TunnelSessionDelegateProxy
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let initialBackoff: Double
    @ObservationIgnored private let conflictBackoff: Double
    @ObservationIgnored private let maxBackoff: Double

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var closeDrain = SocketCloseDrain()
    @ObservationIgnored private var activeClientUUID = ""
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var isDisposed = false
    @ObservationIgnored private var retryAttempt = 0
    @ObservationIgnored private var consecutive409Count = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var listRequestCounter = 0

    @ObservationIgnored private var onlineMap: [String: DiscoveredTunnelServer] = [:]
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var readinessWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    @ObservationIgnored private var pendingHTTP: [String: (serverUUID: String, continuation: CheckedContinuation<(status: Int, headers: [String: JSONValue], body: Data), Error>)] = [:]
    private struct StaleRemoteStream: Hashable {
        let connId: String
        let serverUUID: String
        let clientUUID: String
    }

    @ObservationIgnored private var pendingWSOpen: [String: (serverUUID: String, stream: TunnelWebSocketStream, continuation: CheckedContinuation<TunnelWebSocketStream, Error>)] = [:]
    @ObservationIgnored private var activeWSStreams: [String: TunnelWebSocketStream] = [:]
    @ObservationIgnored private var staleStreamsPendingCleanup: Set<StaleRemoteStream> = []

    fileprivate init(
        endpoint: TunnelEndpoint,
        apiKey: String,
        urlSession: URLSession,
        delegateProxy: TunnelSessionDelegateProxy,
        userDefaults: UserDefaults,
        initialBackoff: Double,
        conflictBackoff: Double,
        maxBackoff: Double
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.urlSession = urlSession
        self.delegateProxy = delegateProxy
        self.userDefaults = userDefaults
        self.initialBackoff = initialBackoff
        self.conflictBackoff = conflictBackoff
        self.maxBackoff = maxBackoff
        Task { @MainActor [weak self] in
            guard let self, !self.isDisposed, self.epoch == 0 else { return }
            self.dial()
        }
    }

    func isServerOnline(_ serverUUID: String) -> Bool {
        onlineMap[serverUUID] != nil
    }

    func addObserver(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    func refreshServers() {
        guard let socket, phase == .connected else { return }
        listRequestCounter += 1
        guard let text = try? TunnelProtocol.encodeListServersFrame(requestId: "ios-sync-\(listRequestCounter)") else {
            return
        }
        socket.send(.string(text)) { _ in }
    }

    func retryNow() {
        guard !isDisposed else { return }
        retryAttempt = 0
        consecutive409Count = 0
        dial()
    }

    func wake() {
        guard !isDisposed else { return }
        switch phase {
        case .failed:
            return
        case .reconnecting:
            retryNow()
        case .connecting:
            if reconnectTask != nil {
                retryNow()
            }
        case .connected:
            guard let socket else {
                retryNow()
                return
            }
            let currentEpoch = epoch
            socket.sendPing { [weak self] error in
                if error != nil {
                    Task { @MainActor [weak self] in
                        guard let self, !self.isDisposed, self.epoch == currentEpoch else { return }
                        self.dial()
                    }
                } else {
                    Task { @MainActor [weak self] in
                        self?.refreshServers()
                    }
                }
            }
        }
    }

    func performHTTP(
        serverUUID: String,
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: Double = 15
    ) async throws -> (status: Int, headers: [String: JSONValue], body: Data) {
        let deadline = Date().addingTimeInterval(timeout)
        let initialBudget = deadline.timeIntervalSinceNow
        guard initialBudget > 0 else {
            throw DesktopClientError.timeout(path)
        }
        try await waitUntilReady(timeout: initialBudget, label: path)
        guard isServerOnline(serverUUID) else {
            throw DesktopClientError.remote("远程桌面端不在线")
        }
        guard let socket, phase == .connected else {
            throw DesktopClientError.notConnected
        }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            throw DesktopClientError.timeout(path)
        }

        let reqId = UUID().uuidString.lowercased()
        let muxHeaders = headers.isEmpty ? nil : headers.mapValues(JSONValue.string)
        let inner = try TunnelProtocol.encodeMuxFrame(
            meta: .httpRequest(id: reqId, method: method, path: path, headers: muxHeaders),
            body: body ?? Data()
        )
        let outer = try TunnelProtocol.encodeTunnelFrame(
            payloadType: TunnelProtocol.muxPayloadType,
            srcUUID: activeClientUUID,
            dstUUID: serverUUID,
            payload: inner
        )

        return try await withCheckedThrowingContinuation { continuation in
            pendingHTTP[reqId] = (serverUUID, continuation)
            socket.send(.data(outer)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    self?.resolveHTTP(reqId, .failure(error))
                }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(remaining))
                self?.resolveHTTP(reqId, .failure(DesktopClientError.timeout(path)))
            }
        }
    }

    func openWebSocket(
        serverUUID: String,
        path: String = "/api/ws",
        headers: [String: String] = [:],
        timeout: Double = 15
    ) async throws -> TunnelWebSocketStream {
        let deadline = Date().addingTimeInterval(timeout)
        let initialBudget = deadline.timeIntervalSinceNow
        guard initialBudget > 0 else {
            throw DesktopClientError.timeout("ws_open")
        }
        try await waitUntilReady(timeout: initialBudget, label: "ws_open")
        guard isServerOnline(serverUUID) else {
            throw DesktopClientError.remote("远程桌面端不在线")
        }
        guard let socket, phase == .connected else {
            throw DesktopClientError.notConnected
        }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            throw DesktopClientError.timeout("ws_open")
        }

        flushStaleRemoteStreamCloses(forServerUUID: serverUUID)

        let connId = UUID().uuidString.lowercased()
        let muxHeaders = headers.isEmpty ? nil : headers.mapValues(JSONValue.string)
        let inner = try TunnelProtocol.encodeMuxFrame(
            meta: .wsOpen(connId: connId, path: path, headers: muxHeaders)
        )
        let outer = try TunnelProtocol.encodeTunnelFrame(
            payloadType: TunnelProtocol.muxPayloadType,
            srcUUID: activeClientUUID,
            dstUUID: serverUUID,
            payload: inner
        )
        let stream = TunnelWebSocketStream(connId: connId, serverUUID: serverUUID, session: self)
        activeWSStreams[connId] = stream

        return try await withCheckedThrowingContinuation { continuation in
            pendingWSOpen[connId] = (serverUUID, stream, continuation)
            socket.send(.data(outer)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.activeWSStreams.removeValue(forKey: connId)
                    self.recordStaleStreamForCleanup(connId: connId, serverUUID: serverUUID)
                    self.resolveWSOpen(connId, .failure(error))
                }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(remaining))
                guard let self, self.pendingWSOpen[connId] != nil else { return }
                self.closeClientWSStream(connId: connId, serverUUID: serverUUID, code: 1000, reason: "open timeout")
                self.resolveWSOpen(connId, .failure(DesktopClientError.timeout("ws_open")))
            }
        }
    }

    fileprivate func sendWSData(connId: String, serverUUID: String, opcode: String, body: Data) throws {
        guard let socket, phase == .connected else {
            throw DesktopClientError.notConnected
        }
        let inner = try TunnelProtocol.encodeMuxFrame(
            meta: .wsData(connId: connId, opcode: opcode),
            body: body
        )
        let outer = try TunnelProtocol.encodeTunnelFrame(
            payloadType: TunnelProtocol.muxPayloadType,
            srcUUID: activeClientUUID,
            dstUUID: serverUUID,
            payload: inner
        )
        socket.send(.data(outer)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.handleSendWSDataError(connId: connId, error: error)
            }
        }
    }

    func handleSendWSDataError(connId: String, error: Error) {
        guard let stream = activeWSStreams.removeValue(forKey: connId) else { return }
        closeClientWSStream(connId: stream.connId, serverUUID: stream.serverUUID, code: 1001, reason: "send failed")
        recordStaleStreamForCleanup(connId: stream.connId, serverUUID: stream.serverUUID)
        stream.fail(error)
    }

    fileprivate func closeClientWSStream(connId: String, serverUUID: String, code: Int, reason: String) {
        activeWSStreams.removeValue(forKey: connId)
        guard let socket, phase == .connected else {
            recordStaleStreamForCleanup(connId: connId, serverUUID: serverUUID)
            return
        }
        guard let inner = try? TunnelProtocol.encodeMuxFrame(
            meta: .wsClose(connId: connId, code: code, reason: reason.isEmpty ? nil : reason)
        ),
              let outer = try? TunnelProtocol.encodeTunnelFrame(
                  payloadType: TunnelProtocol.muxPayloadType,
                  srcUUID: activeClientUUID,
                  dstUUID: serverUUID,
                  payload: inner
              )
        else {
            return
        }
        let drain = closeDrain
        let targetSocket = socket
        drain.beginWrite()
        targetSocket.send(.data(outer)) { [weak self] error in
            Task { @MainActor [weak self] in
                if error != nil {
                    self?.recordStaleStreamForCleanup(connId: connId, serverUUID: serverUUID)
                }
                drain.endWrite(socket: targetSocket)
            }
        }
    }

    fileprivate func dispose() {
        guard !isDisposed else { return }
        if phase == .connected {
            for stream in Array(activeWSStreams.values) {
                closeClientWSStream(connId: stream.connId, serverUUID: stream.serverUUID, code: 1000, reason: "")
                stream.fail(DesktopClientError.notConnected, closeCode: 1000)
            }
        }
        isDisposed = true
        epoch += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        failReadinessWaiters(DesktopClientError.notConnected)
        observers.removeAll()

        if let closingSocket = socket {
            let drain = closeDrain
            delegateProxy.unregister(taskIdentifier: closingSocket.taskIdentifier)
            socket = nil
            failAllInFlight(DesktopClientError.notConnected)
            drain.closeWhenDrained(socket: closingSocket, closeCode: .normalClosure)
        } else {
            failAllInFlight(DesktopClientError.notConnected)
        }
    }

    // MARK: - Connection State Machine

    private func waitUntilReady(timeout: Double, label: String) async throws {
        if phase == .connected, hasReceivedInitialServerList {
            return
        }
        if case .failed(let message) = phase {
            throw DesktopClientError.remote(message)
        }
        if case .reconnecting = phase {
            throw DesktopClientError.notConnected
        }

        let waiterID = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readinessWaiters[waiterID] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                if let pending = self?.readinessWaiters.removeValue(forKey: waiterID) {
                    pending.resume(throwing: DesktopClientError.timeout(label))
                }
            }
        }
    }

    private func dial() {
        guard !isDisposed else { return }
        epoch += 1
        let currentEpoch = epoch
        reconnectTask?.cancel()
        reconnectTask = nil
        tearDownSocket(closeCode: .goingAway, error: DesktopClientError.notConnected)

        hasReceivedInitialServerList = false
        onlineMap.removeAll()
        servers = []
        phase = retryAttempt > 0 ? .reconnecting(retryAttempt) : .connecting
        notifyObservers()

        let clientUUID = currentOrCreateClientUUID()
        let clientName = TunnelProtocol.sanitizeClientName(UIDevice.current.name)
        activeClientUUID = clientUUID

        let url: URL
        do {
            url = try endpoint.handshakeURL(clientUUID: clientUUID, clientName: clientName)
        } catch {
            enterTerminalFailure(error.localizedDescription)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = urlSession.webSocketTask(with: request)
        task.maximumMessageSize = TunnelProtocol.maxInboundFrameBytes
        delegateProxy.register(task: task, session: self, epoch: currentEpoch)
        closeDrain = SocketCloseDrain()
        socket = task
        task.resume()

        Task { @MainActor [weak self] in
            await self?.receiveLoop(task: task, epoch: currentEpoch)
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask, epoch expectedEpoch: Int) async {
        while !isDisposed, epoch == expectedEpoch {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                guard !isDisposed, epoch == expectedEpoch else { return }
                handleDisconnect(task: task, error: error)
                return
            }
            guard !isDisposed, epoch == expectedEpoch else { return }
            switch message {
            case .string(let text):
                handleControlFrame(Data(text.utf8))
            case .data(let data):
                handleBinaryFrame(data)
            @unknown default:
                break
            }
        }
    }

    fileprivate func handleDelegateClose(task: URLSessionWebSocketTask, epoch expectedEpoch: Int, code: Int, reason: String) {
        guard !isDisposed, epoch == expectedEpoch else { return }
        if code == 1008, reason.localizedCaseInsensitiveContains("api key revoked") {
            enterTerminalFailure("CLIProxyAPI API Key 已被吊销")
        }
    }

    private func handleDisconnect(task: URLSessionWebSocketTask, error: Error) {
        let httpStatus = (task.response as? HTTPURLResponse)?.statusCode
        let recordedClose = delegateProxy.closeInfo(for: task.taskIdentifier)
        delegateProxy.unregister(taskIdentifier: task.taskIdentifier)
        if socket === task {
            socket = nil
        }

        let wsCloseCode = recordedClose?.code ?? task.closeCode.rawValue
        let wsCloseReason = recordedClose?.reason
            ?? task.closeReason.flatMap { String(data: $0, encoding: .utf8) }
            ?? ""

        failAllInFlight(DesktopClientError.notConnected)

        if wsCloseCode == 1008, wsCloseReason.localizedCaseInsensitiveContains("api key revoked") {
            enterTerminalFailure("CLIProxyAPI API Key 已被吊销")
            return
        }

        if let httpStatus {
            switch httpStatus {
            case 401, 403:
                enterTerminalFailure("CLIProxyAPI API Key 无效或未授权")
                return
            case 400:
                enterTerminalFailure("隧道握手参数无效（400）")
                return
            case 409:
                consecutive409Count += 1
                if consecutive409Count >= 3 {
                    rotateClientUUID()
                    consecutive409Count = 0
                }
                scheduleReconnect(baseDelay: conflictBackoff, reason: "设备标识冲突，正在重试…")
                return
            default:
                break
            }
        }

        let cleanReason = TunnelProtocol.redactSecret(
            wsCloseReason.isEmpty ? error.localizedDescription : wsCloseReason,
            secret: apiKey
        )
        scheduleReconnect(baseDelay: initialBackoff, reason: cleanReason)
    }

    private func enterTerminalFailure(_ rawMessage: String) {
        reconnectTask?.cancel()
        reconnectTask = nil
        let message = TunnelProtocol.redactSecret(rawMessage, secret: apiKey)
        if socket != nil {
            tearDownSocket(closeCode: .goingAway, error: DesktopClientError.remote(message))
        } else {
            failAllInFlight(DesktopClientError.remote(message))
        }
        phase = .failed(message)
        failReadinessWaiters(DesktopClientError.remote(message))
        notifyObservers()
    }

    private func scheduleReconnect(baseDelay: Double, reason: String) {
        guard !isDisposed else { return }
        if case .failed = phase { return }
        retryAttempt += 1
        phase = .reconnecting(retryAttempt)
        failReadinessWaiters(DesktopClientError.notConnected)
        notifyObservers()

        let expDelay = min(maxBackoff, baseDelay * pow(2, Double(max(0, min(retryAttempt - 1, 5)))))
        let jitter = Double.random(in: 0.85...1.15)
        let delay = max(0.02, expDelay * jitter)
        let currentEpoch = epoch
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.isDisposed, self.epoch == currentEpoch else { return }
            if case .failed = self.phase { return }
            self.dial()
        }
    }

    // MARK: - Frame Handling

    private func handleControlFrame(_ data: Data) {
        guard let event = TunnelProtocol.decodeControlFrame(data) else { return }
        switch event {
        case .serverList(_, let incoming):
            var nextMap: [String: DiscoveredTunnelServer] = [:]
            for item in incoming {
                nextMap[item.uuid] = item
            }
            let removedUUIDs = Set(onlineMap.keys).subtracting(nextMap.keys)
            onlineMap = nextMap
            rebuildSortedServers()
            hasReceivedInitialServerList = true
            retryAttempt = 0
            consecutive409Count = 0
            phase = .connected
            flushStaleRemoteStreamCloses()
            for uuid in removedUUIDs {
                failInFlightForServer(uuid, message: "远程桌面端已离线")
            }
            resumeReadinessWaiters()
            notifyObservers()

        case .serverOnline(let server):
            onlineMap[server.uuid] = server
            rebuildSortedServers()
            notifyObservers()

        case .serverOffline(let server):
            onlineMap.removeValue(forKey: server.uuid)
            rebuildSortedServers()
            failInFlightForServer(server.uuid, message: "远程桌面端已离线")
            notifyObservers()

        case .error(let code, let targetUUID, let message):
            if let targetUUID, !targetUUID.isEmpty {
                let clean = TunnelProtocol.redactSecret(message, secret: apiKey)
                if code == "target_not_found" || code == "invalid_target_role" {
                    onlineMap.removeValue(forKey: targetUUID)
                    rebuildSortedServers()
                    failInFlightForServer(
                        targetUUID,
                        message: code == "target_not_found" ? "远程桌面端不在线" : clean,
                        sendRemoteClose: false
                    )
                    notifyObservers()
                } else {
                    // Non-fatal routing error (e.g. target_buffer_full): a frame sent to this server
                    // was dropped by the gateway, so terminate all in-flight HTTP & virtual WS streams
                    // for that server immediately (preventing hung RPCs) while sending ws_close AND
                    // queueing a retry close before the next ws_open in case congestion drops ws_close too.
                    failInFlightForServer(targetUUID, message: clean, sendRemoteClose: true)
                }
            }
        }
    }

    private func handleBinaryFrame(_ data: Data) {
        guard let outer = try? TunnelProtocol.decodeTunnelFrame(data),
              outer.dstUUID == activeClientUUID,
              outer.payloadType == TunnelProtocol.muxPayloadType,
              let mux = try? TunnelProtocol.decodeMuxFrame(outer.payload)
        else {
            return
        }

        switch mux.meta {
        case .httpResponse(let id, let status, let headers):
            guard let pending = pendingHTTP[id], pending.serverUUID == outer.srcUUID else { return }
            resolveHTTP(id, .success((status: status, headers: headers ?? [:], body: mux.body)))

        case .wsOpenResult(let connId, let ok, let status, let error, _):
            if let pending = pendingWSOpen[connId] {
                guard pending.serverUUID == outer.srcUUID else { return }
                _ = pendingWSOpen.removeValue(forKey: connId)
                if ok {
                    pending.continuation.resume(returning: pending.stream)
                } else {
                    activeWSStreams.removeValue(forKey: connId)
                    if let status {
                        pending.continuation.resume(throwing: DesktopClientError.http(status))
                    } else {
                        let clean = TunnelProtocol.redactSecret(error ?? "WebSocket 连接被拒绝", secret: apiKey)
                        pending.continuation.resume(throwing: DesktopClientError.remote(clean))
                    }
                }
                return
            }
            if ok, activeWSStreams[connId] == nil {
                closeClientWSStream(connId: connId, serverUUID: outer.srcUUID, code: 1000, reason: "stale open")
            }

        case .wsData(let connId, _):
            guard let stream = activeWSStreams[connId], stream.serverUUID == outer.srcUUID else { return }
            stream.deliver(mux.body)

        case .wsClose(let connId, let code, let reason):
            guard let stream = activeWSStreams[connId], stream.serverUUID == outer.srcUUID else { return }
            activeWSStreams.removeValue(forKey: connId)
            let clean = TunnelProtocol.redactSecret(reason ?? "", secret: apiKey)
            let err: Error = clean.isEmpty ? DesktopClientError.notConnected : DesktopClientError.remote(clean)
            stream.fail(err, closeCode: code)

        case .httpRequest, .wsOpen:
            break
        }
    }

    private func rebuildSortedServers() {
        servers = onlineMap.values.sorted { lhs, rhs in
            let cmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            return cmp == .orderedSame ? lhs.uuid < rhs.uuid : cmp == .orderedAscending
        }
    }

    // MARK: - Cleanup & Continuation Helpers

    private func tearDownSocket(closeCode: URLSessionWebSocketTask.CloseCode, error: Error) {
        if let socket {
            delegateProxy.unregister(taskIdentifier: socket.taskIdentifier)
            socket.cancel(with: closeCode, reason: nil)
            self.socket = nil
        }
        failAllInFlight(error)
    }

    private func resolveHTTP(
        _ id: String,
        _ result: Result<(status: Int, headers: [String: JSONValue], body: Data), Error>
    ) {
        pendingHTTP.removeValue(forKey: id)?.continuation.resume(with: result)
    }

    private func resolveWSOpen(_ connId: String, _ result: Result<TunnelWebSocketStream, Error>) {
        pendingWSOpen.removeValue(forKey: connId)?.continuation.resume(with: result)
    }

    private func failInFlightForServer(_ serverUUID: String, message: String, sendRemoteClose: Bool = false) {
        let error = DesktopClientError.remote(message)
        let matchingHTTP = pendingHTTP.filter { $0.value.serverUUID == serverUUID }.map(\.key)
        for id in matchingHTTP {
            resolveHTTP(id, .failure(error))
        }
        let matchingWSOpen = pendingWSOpen.filter { $0.value.serverUUID == serverUUID }.map(\.key)
        for connId in matchingWSOpen {
            if sendRemoteClose {
                closeClientWSStream(connId: connId, serverUUID: serverUUID, code: 1001, reason: "stream reset")
                recordStaleStreamForCleanup(connId: connId, serverUUID: serverUUID)
            } else {
                activeWSStreams.removeValue(forKey: connId)
            }
            resolveWSOpen(connId, .failure(error))
        }
        let matchingStreams = activeWSStreams.filter { $0.value.serverUUID == serverUUID }.map(\.key)
        for connId in matchingStreams {
            let stream = activeWSStreams.removeValue(forKey: connId)
            if sendRemoteClose {
                closeClientWSStream(connId: connId, serverUUID: serverUUID, code: 1001, reason: "stream reset")
                recordStaleStreamForCleanup(connId: connId, serverUUID: serverUUID)
            }
            stream?.fail(error)
        }
    }

    private func recordStaleStreamForCleanup(connId: String, serverUUID: String) {
        guard !isDisposed, !activeClientUUID.isEmpty, !connId.isEmpty, !serverUUID.isEmpty else { return }
        if staleStreamsPendingCleanup.count >= 128 {
            return
        }
        staleStreamsPendingCleanup.insert(StaleRemoteStream(
            connId: connId,
            serverUUID: serverUUID,
            clientUUID: activeClientUUID
        ))
    }

    private func flushStaleRemoteStreamCloses(forServerUUID targetServerUUID: String? = nil) {
        guard !staleStreamsPendingCleanup.isEmpty else { return }
        if let targetServerUUID {
            let matching = staleStreamsPendingCleanup.filter {
                $0.serverUUID == targetServerUUID || $0.clientUUID != activeClientUUID
            }
            guard !matching.isEmpty else { return }
            staleStreamsPendingCleanup.subtract(matching)
            for item in matching where item.clientUUID == activeClientUUID && item.serverUUID == targetServerUUID {
                closeClientWSStream(
                    connId: item.connId,
                    serverUUID: item.serverUUID,
                    code: 1001,
                    reason: "stream cleanup"
                )
            }
            return
        }
        let drained = staleStreamsPendingCleanup
        staleStreamsPendingCleanup.removeAll()
        for item in drained where item.clientUUID == activeClientUUID && onlineMap[item.serverUUID] != nil {
            closeClientWSStream(
                connId: item.connId,
                serverUUID: item.serverUUID,
                code: 1001,
                reason: "tunnel reconnected"
            )
        }
    }

    private func failAllInFlight(_ error: Error) {
        let allHTTP = Array(pendingHTTP.values)
        pendingHTTP.removeAll()
        for item in allHTTP {
            item.continuation.resume(throwing: error)
        }
        let allWSOpen = Array(pendingWSOpen.values)
        pendingWSOpen.removeAll()
        for item in allWSOpen {
            recordStaleStreamForCleanup(connId: item.stream.connId, serverUUID: item.serverUUID)
            item.continuation.resume(throwing: error)
        }
        let streams = Array(activeWSStreams.values)
        activeWSStreams.removeAll()
        for stream in streams {
            recordStaleStreamForCleanup(connId: stream.connId, serverUUID: stream.serverUUID)
            stream.fail(error)
        }
    }

    private func resumeReadinessWaiters() {
        let waiters = Array(readinessWaiters.values)
        readinessWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func failReadinessWaiters(_ error: Error) {
        let waiters = Array(readinessWaiters.values)
        readinessWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    private func notifyObservers() {
        for observer in Array(observers.values) {
            observer()
        }
    }

    private func currentOrCreateClientUUID() -> String {
        if let saved = userDefaults.string(forKey: PreferenceKey.tunnelClientUUID),
           TunnelProtocol.isValidUUID(saved)
        {
            return saved
        }
        let fresh = UUID().uuidString.lowercased()
        userDefaults.set(fresh, forKey: PreferenceKey.tunnelClientUUID)
        return fresh
    }

    private func rotateClientUUID() {
        let fresh = UUID().uuidString.lowercased()
        userDefaults.set(fresh, forKey: PreferenceKey.tunnelClientUUID)
        activeClientUUID = fresh
    }
}

// MARK: - Reference-Counted Tunnel Client Manager

@MainActor
final class TunnelClientManager {
    static let shared = TunnelClientManager()

    private struct SessionKey: Hashable {
        let webSocketBaseURL: String
        let apiKey: String
    }

    private struct ManagedEntry {
        let session: TunnelSession
        var leases: Set<UUID>
    }

    private let urlSession: URLSession
    private let delegateProxy: TunnelSessionDelegateProxy
    private let userDefaults: UserDefaults
    private let initialBackoff: Double
    private let conflictBackoff: Double
    private let maxBackoff: Double

    private var entries: [SessionKey: ManagedEntry] = [:]
    private var leaseToKey: [UUID: SessionKey] = [:]

    init(
        urlSession: URLSession? = nil,
        userDefaults: UserDefaults = .standard,
        initialBackoff: Double = 1.5,
        conflictBackoff: Double = 2.0,
        maxBackoff: Double = 20.0
    ) {
        let proxy = TunnelSessionDelegateProxy()
        self.delegateProxy = proxy
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            config.timeoutIntervalForRequest = 15
            config.waitsForConnectivity = false
            self.urlSession = URLSession(configuration: config, delegate: proxy, delegateQueue: .main)
        }
        self.userDefaults = userDefaults
        self.initialBackoff = initialBackoff
        self.conflictBackoff = conflictBackoff
        self.maxBackoff = maxBackoff
    }

    func acquireSession(baseURL: String, apiKey: String) throws -> (session: TunnelSession, leaseID: UUID) {
        let endpoint = try TunnelProtocol.parseEndpoint(baseURL).get()
        let validatedKey = try TunnelProtocol.validateAPIKey(apiKey).get()
        let key = SessionKey(webSocketBaseURL: endpoint.webSocketBaseURL, apiKey: validatedKey)
        let leaseID = UUID()
        leaseToKey[leaseID] = key

        if var existing = entries[key] {
            existing.leases.insert(leaseID)
            entries[key] = existing
            if case .failed = existing.session.phase {
                existing.session.retryNow()
            } else if existing.session.phase == .connected {
                existing.session.refreshServers()
            }
            return (existing.session, leaseID)
        }

        let session = TunnelSession(
            endpoint: endpoint,
            apiKey: validatedKey,
            urlSession: urlSession,
            delegateProxy: delegateProxy,
            userDefaults: userDefaults,
            initialBackoff: initialBackoff,
            conflictBackoff: conflictBackoff,
            maxBackoff: maxBackoff
        )
        entries[key] = ManagedEntry(session: session, leases: [leaseID])
        return (session, leaseID)
    }

    func releaseLease(_ leaseID: UUID) {
        guard let key = leaseToKey.removeValue(forKey: leaseID),
              var entry = entries[key]
        else {
            return
        }
        entry.leases.remove(leaseID)
        if entry.leases.isEmpty {
            entries.removeValue(forKey: key)
            entry.session.dispose()
        } else {
            entries[key] = entry
        }
    }

    var activeSessionCount: Int {
        entries.count
    }

    func wakeAll() {
        for entry in entries.values {
            entry.session.wake()
        }
    }
}

@MainActor
private final class SocketCloseDrain {
    private var pendingWrites = 0
    private var waitingCloseCode: URLSessionWebSocketTask.CloseCode?
    private var hasClosed = false

    func beginWrite() {
        guard !hasClosed else { return }
        pendingWrites += 1
    }

    func endWrite(socket: URLSessionWebSocketTask) {
        guard !hasClosed else { return }
        pendingWrites = max(0, pendingWrites - 1)
        if pendingWrites == 0, let closeCode = waitingCloseCode {
            hasClosed = true
            socket.cancel(with: closeCode, reason: nil)
        }
    }

    func closeWhenDrained(socket: URLSessionWebSocketTask, closeCode: URLSessionWebSocketTask.CloseCode) {
        guard !hasClosed else { return }
        if pendingWrites == 0 {
            hasClosed = true
            socket.cancel(with: closeCode, reason: nil)
            return
        }
        waitingCloseCode = closeCode
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !self.hasClosed else { return }
            self.hasClosed = true
            socket.cancel(with: closeCode, reason: nil)
        }
    }
}

// MARK: - URLSessionWebSocketDelegate Proxy

private final class TunnelSessionDelegateProxy: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private struct Registration {
        weak var session: TunnelSession?
        let epoch: Int
    }

    private let lock = NSLock()
    private var registrations: [Int: Registration] = [:]
    private var closes: [Int: (code: Int, reason: String)] = [:]

    func register(task: URLSessionWebSocketTask, session: TunnelSession, epoch: Int) {
        lock.lock()
        registrations[task.taskIdentifier] = Registration(session: session, epoch: epoch)
        closes.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
    }

    func unregister(taskIdentifier: Int) {
        lock.lock()
        registrations.removeValue(forKey: taskIdentifier)
        closes.removeValue(forKey: taskIdentifier)
        lock.unlock()
    }

    func closeInfo(for taskIdentifier: Int) -> (code: Int, reason: String)? {
        lock.lock()
        defer { lock.unlock() }
        return closes[taskIdentifier]
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let code = closeCode.rawValue
        lock.lock()
        closes[webSocketTask.taskIdentifier] = (code, reasonText)
        let reg = registrations[webSocketTask.taskIdentifier]
        lock.unlock()

        guard let reg else { return }
        Task { @MainActor in
            reg.session?.handleDelegateClose(task: webSocketTask, epoch: reg.epoch, code: code, reason: reasonText)
        }
    }
}
