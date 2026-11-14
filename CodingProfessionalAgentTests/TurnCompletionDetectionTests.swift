import CryptoKit
import Foundation
import Network
import XCTest
@testable import CodingProfessionalAgent

@MainActor
final class TurnCompletionDetectionTests: XCTestCase {
    private func makeClient() -> DesktopClient {
        DesktopClient(connection: DesktopConnection(
            name: "Studio",
            host: "127.0.0.1",
            port: 18080,
            icon: .laptop,
            isEnabled: false
        ))
    }

    private func sendEvent(_ client: DesktopClient, kind: String, data: JSONValue) throws {
        let envelope: JSONValue = [
            "type": "event",
            "event": [
                "kind": .string(kind),
                "data": data,
            ],
        ]
        client.ingestServerMessage(Data(try envelope.jsonString().utf8))
    }

    func testEmitsTurnCompletedOnlyAfterFinalDoneAssistantAndIdle() throws {
        let client = makeClient()
        var completed: [JSONValue] = []
        _ = client.addListener { event in
            if event.kind == DesktopEvent.turnCompleted {
                completed.append(event.payload)
            }
        }

        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": "s1", "title": "重构网络层", "createdAt": 100, "updatedAt": 100,
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s1", "runId": "r1", "status": "running", "updatedAt": 101,
        ])
        XCTAssertEqual(client.activeTopLevelSessions.map(\.sessionId), ["s1"])
        XCTAssertEqual(client.activeTopLevelSessions.map(\.title), ["重构网络层"])

        // Intermediate toolUse step must not mark the turn completed on its own.
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s1",
            "runId": "r1",
            "event": [
                "type": "assistant-end",
                "entry": ["id": "a1", "kind": "assistant", "status": "done", "stopReason": "toolUse", "createdAt": 102],
            ],
        ])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s1",
            "runId": "r1",
            "event": [
                "type": "assistant-end",
                "entry": ["id": "a2", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 103],
            ],
        ])
        XCTAssertTrue(completed.isEmpty)

        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s1", "runId": "r1", "status": "idle", "updatedAt": 104,
        ])
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed[0]["sessionId"]?.stringValue, "s1")
        XCTAssertEqual(completed[0]["runId"]?.stringValue, "r1")
        XCTAssertEqual(completed[0]["sessionTitle"]?.stringValue, "重构网络层")
        XCTAssertTrue(client.activeTopLevelSessions.isEmpty)

        // Duplicate idle for the same runId must not notify twice.
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s1", "runId": "r1", "status": "idle", "updatedAt": 105,
        ])
        XCTAssertEqual(completed.count, 1)
    }

    func testOptimisticRunUpgradePreservesStreamCompletionAndContinuationErrorResetsIt() throws {
        let client = makeClient()
        var completedSessionIds: [String] = []
        _ = client.addListener { event in
            if event.kind == DesktopEvent.turnCompleted,
               let id = event.payload["sessionId"]?.stringValue {
                completedSessionIds.append(id)
            }
        }

        // Case A (Review Focus #2): stream assistant-end arrives before real runId replaces optimistic placeholder.
        try sendEvent(client, kind: "session:meta-updated", data: ["id": "s-fast", "title": "快速问答", "createdAt": 1, "updatedAt": 1])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "s-fast", "runId": "ios-pending-1", "status": "running", "updatedAt": 2])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-fast", "runId": "r-real",
            "event": ["type": "assistant-end", "entry": ["id": "e1", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 3]],
        ])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "s-fast", "runId": "r-real", "status": "running", "updatedAt": 4])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "s-fast", "runId": "r-real", "status": "idle", "updatedAt": 5])
        XCTAssertEqual(completedSessionIds, ["s-fast"])

        // Case B (Review Focus #3): continuation within same runId followed by error must not notify.
        try sendEvent(client, kind: "session:meta-updated", data: ["id": "s-cont", "title": "续跑失败", "createdAt": 10, "updatedAt": 10])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "s-cont", "runId": "r-cont", "status": "running", "updatedAt": 11])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-cont", "runId": "r-cont",
            "event": ["type": "assistant-end", "entry": ["id": "e2", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 12]],
        ])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-cont", "runId": "r-cont",
            "event": ["type": "assistant-start", "entry": ["id": "e3", "kind": "assistant", "status": "streaming", "createdAt": 13]],
        ])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-cont", "runId": "r-cont",
            "event": ["type": "error", "message": "upstream reset"],
        ])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "s-cont", "runId": "r-cont", "status": "idle", "updatedAt": 14])
        XCTAssertEqual(completedSessionIds, ["s-fast"])
    }

    func testFiltersOutSubAgentsAbortsErrorsAndCompaction() throws {
        let client = makeClient()
        var completedCount = 0
        _ = client.addListener { event in
            if event.kind == DesktopEvent.turnCompleted {
                completedCount += 1
            }
        }

        // 1. Sub-agent session via parentSessionId != nil
        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": "sub-1", "parentSessionId": "root-1", "title": "Sub", "createdAt": 1, "updatedAt": 1,
        ])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "sub-1", "runId": "r-sub", "status": "running", "updatedAt": 2])
        XCTAssertTrue(client.activeTopLevelSessions.isEmpty)
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "sub-1", "runId": "r-sub",
            "event": ["type": "assistant-end", "entry": ["id": "a", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 3]],
        ])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "sub-1", "runId": "r-sub", "status": "idle", "updatedAt": 4])

        // 2. Sub-agent session discovered via session:subagent-state
        try sendEvent(client, kind: "session:subagent-state", data: [
            "agents": [[
                "id": "ag-1", "parentSessionId": "root-1", "sessionId": "sub-2", "status": "running",
                "createdAt": 1, "updatedAt": 2,
            ]],
        ])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "sub-2", "runId": "r-sub2", "status": "running", "updatedAt": 3])
        XCTAssertTrue(client.activeTopLevelSessions.isEmpty)
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "sub-2", "runId": "r-sub2",
            "event": ["type": "assistant-end", "entry": ["id": "a2", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 4]],
        ])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "sub-2", "runId": "r-sub2", "status": "idle", "updatedAt": 5])

        // 3. Aborted top-level run (session:abort-run)
        try sendEvent(client, kind: "session:meta-updated", data: ["id": "s-abort", "title": "Abort", "createdAt": 1, "updatedAt": 1])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "s-abort", "runId": "r-ab", "status": "running", "updatedAt": 2])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-abort", "runId": "r-ab",
            "event": ["type": "assistant-end", "entry": ["id": "b", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 3]],
        ])
        try sendEvent(client, kind: "session:abort-run", data: ["sessionId": "s-abort"])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "s-abort", "runId": "r-ab", "status": "idle", "updatedAt": 4])

        // 4. Meta-updated with unread == "error"
        try sendEvent(client, kind: "session:meta-updated", data: ["id": "s-err", "title": "Err", "createdAt": 1, "updatedAt": 1])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "s-err", "runId": "r-er", "status": "running", "updatedAt": 2])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-err", "runId": "r-er",
            "event": ["type": "assistant-end", "entry": ["id": "d", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 3]],
        ])
        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": "s-err", "title": "Err", "unread": "error", "createdAt": 1, "updatedAt": 4,
        ])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "s-err", "runId": "r-er", "status": "idle", "updatedAt": 5])

        // 5. Compaction (/compact emits compaction-end without assistant-end)
        try sendEvent(client, kind: "session:meta-updated", data: ["id": "s-compact", "title": "Compact", "createdAt": 1, "updatedAt": 1])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "s-compact", "runId": "r-cp", "status": "running", "updatedAt": 2])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-compact", "runId": "r-cp",
            "event": ["type": "compaction-end", "entry": ["id": "c", "kind": "compaction", "createdAt": 3]],
        ])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "s-compact", "runId": "r-cp", "status": "idle", "updatedAt": 4])

        XCTAssertEqual(PreferenceKey.notifyOnTurnComplete, "behavior.notifyOnTurnComplete")
        XCTAssertEqual(completedCount, 0)
    }

    func testResyncAfterInvoluntaryDisconnectEmitsOnceWhenUnreadBecomesTrueAndSkipsInitialSync() async throws {
        let server = try MockDirectDesktopServer()
        defer { server.stop() }

        // Initial snapshot has a historical unread session plus two active runs (s-ok and s-fail).
        server.sessions = [
            ["id": "s-history-unread", "title": "历史未读", "unread": true, "createdAt": 10, "updatedAt": 20],
            ["id": "s-ok", "title": "后台长任务", "unread": false, "createdAt": 30, "updatedAt": 30],
            ["id": "s-fail", "title": "后台报错任务", "unread": false, "createdAt": 40, "updatedAt": 40],
        ]
        server.activeRuns = [
            ["sessionId": "s-ok", "runId": "run-ok-1", "status": "running", "updatedAt": 31],
            ["sessionId": "s-fail", "runId": "run-fail-1", "status": "running", "updatedAt": 41],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        var completed: [(sessionId: String, title: String)] = []
        _ = client.addListener { event in
            if event.kind == DesktopEvent.turnCompleted {
                completed.append((
                    event.payload["sessionId"]?.stringValue ?? "",
                    event.payload["sessionTitle"]?.stringValue ?? ""
                ))
            }
        }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.activeTopLevelSessions.count == 2
        }
        // Initial sync must never notify for historical unread sessions.
        XCTAssertTrue(completed.isEmpty)

        // While disconnected, s-ok finishes normally (unread: true) and s-fail errors (unread: "error").
        server.activeRuns = []
        server.sessions = [
            ["id": "s-history-unread", "title": "历史未读", "unread": true, "createdAt": 10, "updatedAt": 20],
            ["id": "s-ok", "title": "后台长任务", "unread": true, "createdAt": 30, "updatedAt": 90],
            ["id": "s-fail", "title": "后台报错任务", "unread": "error", "createdAt": 40, "updatedAt": 91],
        ]
        server.dropActiveWebSockets()

        try await waitUntil("reconnect resync emits s-ok once") {
            completed.count == 1 && client.state == .connected && client.activeTopLevelSessions.isEmpty
        }
        XCTAssertEqual(completed.first?.sessionId, "s-ok")
        XCTAssertEqual(completed.first?.title, "后台长任务")

        // A subsequent manual resync must not re-emit for s-ok.
        await client.resync()
        XCTAssertEqual(completed.count, 1)
    }

    func testPartialResyncFailurePreservesInterruptedSnapshotUntilBothRunsAndSessionsSucceed() async throws {
        let server = try MockDirectDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-1", "title": "第一轮断连任务", "unread": false, "createdAt": 10, "updatedAt": 10],
            ["id": "s-2", "title": "第二轮断连任务", "unread": false, "createdAt": 20, "updatedAt": 20],
        ]
        server.activeRuns = [
            ["sessionId": "s-1", "runId": "run-1", "status": "running", "updatedAt": 11],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        var completedIds: [String] = []
        _ = client.addListener { event in
            if event.kind == DesktopEvent.turnCompleted,
               let id = event.payload["sessionId"]?.stringValue {
                completedIds.append(id)
            }
        }

        client.start()
        try await waitUntil("initial sync complete") {
            client.hasSynced && client.activeTopLevelSessions.map(\.sessionId) == ["s-1"]
        }

        // Case 1: s-1 finishes offline, reconnect's first session:listSessions fails -> must keep snapshot for retry.
        server.activeRuns = []
        server.sessions = [
            ["id": "s-1", "title": "第一轮断连任务", "unread": true, "createdAt": 10, "updatedAt": 50],
            ["id": "s-2", "title": "第二轮断连任务", "unread": false, "createdAt": 20, "updatedAt": 20],
        ]
        server.failListSessionsRemaining = 1
        server.dropActiveWebSockets()

        try await waitUntil("reconnected after partial resync") {
            client.state == .connected && server.failListSessionsRemaining == 0
        }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(completedIds.isEmpty)

        await client.resync()
        XCTAssertEqual(completedIds, ["s-1"])

        // Case 2: s-2 starts, then finishes offline while first session:getActiveRuns fails -> must keep snapshot for retry.
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-2", "runId": "run-2", "status": "running", "updatedAt": 60,
        ])
        server.activeRuns = []
        server.sessions = [
            ["id": "s-1", "title": "第一轮断连任务", "unread": true, "createdAt": 10, "updatedAt": 50],
            ["id": "s-2", "title": "第二轮断连任务", "unread": true, "createdAt": 20, "updatedAt": 70],
        ]
        server.failGetActiveRunsRemaining = 1
        server.dropActiveWebSockets()

        try await waitUntil("reconnected after getActiveRuns failure") {
            client.state == .connected && server.failGetActiveRunsRemaining == 0
        }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(completedIds, ["s-1"])

        await client.resync()
        XCTAssertEqual(completedIds, ["s-1", "s-2"])
    }

    private func waitUntil(_ label: String, timeout: Double = 5.0, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for \(label)")
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

// Minimal HTTP + WebSocket desktop stub for testing real DesktopClient connect/disconnect/resync cycles.
private final class MockDirectDesktopServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.mock-direct-desktop")
    private let listener: NWListener
    private let lock = NSLock()
    private var wsConnections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    var sessions: [JSONValue] {
        get { lock.withLock { _sessions } }
        set { lock.withLock { _sessions = newValue } }
    }
    var activeRuns: [JSONValue] {
        get { lock.withLock { _activeRuns } }
        set { lock.withLock { _activeRuns = newValue } }
    }
    var failGetActiveRunsRemaining: Int {
        get { lock.withLock { _failGetActiveRunsRemaining } }
        set { lock.withLock { _failGetActiveRunsRemaining = newValue } }
    }
    var failListSessionsRemaining: Int {
        get { lock.withLock { _failListSessionsRemaining } }
        set { lock.withLock { _failListSessionsRemaining = newValue } }
    }
    private var _sessions: [JSONValue] = []
    private var _activeRuns: [JSONValue] = []
    private var _failGetActiveRunsRemaining = 0
    private var _failListSessionsRemaining = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
    }

    func stop() {
        dropActiveWebSockets()
        listener.cancel()
    }

    func dropActiveWebSockets() {
        let conns = lock.withLock { () -> [NWConnection] in
            let current = wsConnections
            wsConnections.removeAll()
            return current
        }
        for conn in conns {
            conn.cancel()
        }
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        readHTTPHeader(conn: conn, accumulated: Data())
    }

    private func readHTTPHeader(conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let content {
                buffer.append(content)
            }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerText = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                let remainder = Data(buffer[range.upperBound...])
                self.routeHTTP(conn: conn, headerText: headerText, remainder: remainder)
                return
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.readHTTPHeader(conn: conn, accumulated: buffer)
        }
    }

    private func routeHTTP(conn: NWConnection, headerText: String, remainder: Data) {
        let lines = headerText.components(separatedBy: "\r\n")
        let firstLine = lines.first ?? ""
        if firstLine.hasPrefix("GET /api/auth/status") {
            let body = Data(#"{"required":false,"authenticated":true}"#.utf8)
            let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var out = Data(response.utf8)
            out.append(body)
            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
            return
        }
        if firstLine.hasPrefix("GET /api/ws") {
            var secKey = ""
            for line in lines {
                if line.lowercased().hasPrefix("sec-websocket-key:") {
                    secKey = line.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces)
                }
            }
            let magic = secKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
            let accept = Data(Insecure.SHA1.hash(data: Data(magic.utf8))).base64EncodedString()
            let handshake = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            conn.send(content: Data(handshake.utf8), completion: .contentProcessed { [weak self] err in
                guard let self, err == nil else { return }
                self.lock.withLock { self.wsConnections.append(conn) }
                self.sendWSText(conn: conn, text: #"{"type":"hello","clientId":"mock-c1"}"#)
                self.readWSLoop(conn: conn, buffer: remainder)
            })
            return
        }
        conn.cancel()
    }

    private func readWSLoop(conn: NWConnection, buffer: Data) {
        var current = buffer
        while let (opcode, payload, consumed) = Self.decodeClientWSFrame(current) {
            current.removeFirst(consumed)
            if opcode == 0x08 {
                conn.cancel()
                return
            }
            if opcode == 0x09 {
                sendWSFrame(conn: conn, opcode: 0x0A, payload: payload)
                continue
            }
            if opcode == 0x01, let rpc = JSONValue.parse(payload),
               rpc["type"]?.stringValue == "rpc",
               let id = rpc["id"]?.stringValue,
               let method = rpc["method"]?.stringValue {
                let shouldFail = lock.withLock { () -> Bool in
                    if method == "session:getActiveRuns", _failGetActiveRunsRemaining > 0 {
                        _failGetActiveRunsRemaining -= 1
                        return true
                    }
                    if method == "session:listSessions", _failListSessionsRemaining > 0 {
                        _failListSessionsRemaining -= 1
                        return true
                    }
                    return false
                }
                if shouldFail {
                    let errReply: JSONValue = [
                        "type": "rpc_error",
                        "id": .string(id),
                        "error": ["message": "simulated transient rpc failure"],
                    ]
                    if let text = try? errReply.jsonString() {
                        sendWSText(conn: conn, text: text)
                    }
                    continue
                }
                let result: JSONValue
                switch method {
                case "session:getActiveRuns":
                    result = .array(activeRuns)
                case "session:listSessions":
                    result = .array(sessions)
                case "kvstore:get":
                    let key = rpc["args"]?.arrayValue?.first?.stringValue ?? ""
                    result = (key == "projects" || key == "cachedModels") ? .array([]) : .null
                default:
                    result = .null
                }
                let reply: JSONValue = ["type": "rpc_result", "id": .string(id), "result": result]
                if let text = try? reply.jsonString() {
                    sendWSText(conn: conn, text: text)
                }
            }
        }
        let leftover = current
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                var next = leftover
                next.append(data)
                self.readWSLoop(conn: conn, buffer: next)
                return
            }
            if isComplete || error != nil {
                conn.cancel()
            }
        }
    }

    private func sendWSText(conn: NWConnection, text: String) {
        sendWSFrame(conn: conn, opcode: 0x01, payload: Data(text.utf8))
    }

    private func sendWSFrame(conn: NWConnection, opcode: UInt8, payload: Data) {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 65535 {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(payload.count) >> shift) & 0xFF))
            }
        }
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    private static func decodeClientWSFrame(_ data: Data) -> (opcode: UInt8, payload: Data, consumed: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        let opcode = bytes[0] & 0x0F
        let masked = (bytes[1] & 0x80) != 0
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= offset + 2 else { return nil }
            length = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            offset += 2
        } else if length == 127 {
            guard bytes.count >= offset + 8 else { return nil }
            var big: UInt64 = 0
            for idx in 0..<8 {
                big = (big << 8) | UInt64(bytes[offset + idx])
            }
            length = Int(big)
            offset += 8
        }
        var maskKey: [UInt8] = []
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            maskKey = Array(bytes[offset..<(offset + 4)])
            offset += 4
        }
        guard bytes.count >= offset + length else { return nil }
        var payload = Array(bytes[offset..<(offset + length)])
        if masked {
            for idx in 0..<payload.count {
                payload[idx] ^= maskKey[idx % 4]
            }
        }
        return (opcode, Data(payload), offset + length)
    }
}
