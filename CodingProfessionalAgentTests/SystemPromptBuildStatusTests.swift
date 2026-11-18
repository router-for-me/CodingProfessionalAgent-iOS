import CryptoKit
import Foundation
import Network
import SwiftUI
import UIKit
import XCTest
@testable import CodingProfessionalAgent

@MainActor
final class SystemPromptBuildStatusTests: XCTestCase {
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

    private func markConnected(_ client: DesktopClient) throws {
        let hello: JSONValue = [
            "type": "hello",
            "clientId": "test-client",
        ]
        client.ingestServerMessage(Data(try hello.jsonString().utf8))
    }

    private func makeConnectedClient(suiteName: String) throws -> (DesktopClient, ConnectionStore, UserDefaults) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let connection = DesktopConnection(
            id: UUID(),
            name: "Studio",
            host: "127.0.0.1",
            port: 59996,
            icon: .laptop,
            isEnabled: false
        )
        store.add(connection, password: "")
        store.setEnabled(connection.id, true)
        let client = try XCTUnwrap(store.client(for: connection.id))
        client.stop()
        try markConnected(client)
        return (client, store, defaults)
    }

    func testRunStatusTogglesBuildingSystemPromptWithoutAddingHistoryEntries() throws {
        let suiteName = "SystemPromptBuildStatusTests.RunStatus.\(UUID().uuidString)"
        let (client, store, defaults) = try makeConnectedClient(suiteName: suiteName)
        defer {
            client.stop()
            store.remove(client.connection.id)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let sessionId = "sess-build"
        let model = ThreadModel(client: client, sessionId: sessionId)
        model.activate()
        defer { model.deactivate() }

        XCTAssertFalse(client.isBuildingSystemPrompt(sessionId))
        XCTAssertFalse(model.isBuildingSystemPrompt)
        XCTAssertFalse(model.isRunning)

        // Desktop starts run and begins building the enhanced system prompt.
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": .string(sessionId),
            "runId": "run-1",
            "status": "running",
            "updatedAt": 1000,
        ])
        XCTAssertTrue(model.isRunning)
        XCTAssertFalse(model.isBuildingSystemPrompt)

        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": .string(sessionId),
            "runId": "run-1",
            "status": "building-system-prompt",
            "updatedAt": 1010,
        ])
        XCTAssertTrue(model.isRunning)
        XCTAssertTrue(client.isBuildingSystemPrompt(sessionId))
        XCTAssertTrue(model.isBuildingSystemPrompt)
        XCTAssertTrue(model.entries.isEmpty)

        // Sub-agent model for the same session id must not report enhanced prompt building.
        let subAgentModel = ThreadModel(
            client: client,
            sessionId: sessionId,
            subAgent: SubAgentReference(parentSessionId: "parent-1", agentId: "agent-1")
        )
        XCTAssertFalse(subAgentModel.isBuildingSystemPrompt)

        // Once prompt build finishes and run continues, only the transient prompt-build state clears.
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": .string(sessionId),
            "runId": "run-1",
            "status": "running",
            "updatedAt": 1020,
        ])
        XCTAssertTrue(model.isRunning)
        XCTAssertFalse(client.isBuildingSystemPrompt(sessionId))
        XCTAssertFalse(model.isBuildingSystemPrompt)
        XCTAssertTrue(model.entries.isEmpty)

        // Idle clears both.
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": .string(sessionId),
            "runId": "run-1",
            "status": "idle",
            "updatedAt": 1030,
        ])
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(model.isBuildingSystemPrompt)
    }

    func testResyncRestoresAndClearsBuildingSystemPromptFromActiveRunsSnapshot() async throws {
        let server = try PromptBuildMockServer()
        defer { server.stop() }
        server.activeRunsResult = [[
            "sessionId": "sess-snap",
            "runId": "run-snap",
            "clientId": "desktop-main",
            "status": "building-system-prompt",
            "updatedAt": 2000,
        ]]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Studio Mac",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .display
        ))
        defer { client.stop() }
        client.start()

        try await waitUntil("initial sync sees building-system-prompt") {
            client.state == .connected && client.hasSynced && client.isBuildingSystemPrompt("sess-snap")
        }
        XCTAssertTrue(client.isRunning("sess-snap"))

        server.activeRunsResult = [[
            "sessionId": "sess-snap",
            "runId": "run-snap",
            "clientId": "desktop-main",
            "status": "running",
            "updatedAt": 2100,
        ]]
        await client.resync()
        XCTAssertTrue(client.isRunning("sess-snap"))
        XCTAssertFalse(client.isBuildingSystemPrompt("sess-snap"))
    }

    func testFollowUpUsesDesktopModeAndClearsPendingWhenTheSamePromptStarts() async throws {
        let server = try PromptBuildMockServer()
        defer { server.stop() }
        let sessionId = "sess-follow-up"
        server.activeRunsResult = [[
            "sessionId": .string(sessionId), "runId": "run-1", "status": "running", "updatedAt": 1000,
        ]]
        server.sessionEntries = [sessionId: [[
            "id": "original", "kind": "user", "createdAt": 800,
            "content": [["type": "text", "text": "Original prompt"]],
        ]]]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Studio Mac", host: "127.0.0.1", port: Int(server.port), icon: .display
        ))
        defer { client.stop() }
        client.start()
        try await waitUntil("desktop settings and active run have synced") { client.hasSynced }

        let model = ThreadModel(client: client, sessionId: sessionId)
        model.activate()
        defer { model.deactivate() }
        try await waitUntil("initial thread snapshot") { model.entries.contains(where: { $0.id == "original" }) }
        try await model.send("Follow up", skillReferences: [])

        let request = try XCTUnwrap(server.delegateRequest)
        XCTAssertNil(request["followUpMode"], "Only the desktop should select the execution mode")
        let id = try XCTUnwrap(request["userEntryId"]?.stringValue)
        XCTAssertEqual(model.entries.first(where: { $0.id == id })?.pendingStatus, "pending")

        server.broadcastEvent(kind: "session:stream-event", data: [
            "sessionId": .string(sessionId), "runId": "run-1", "event": [
                "type": "follow-up-pending", "userEntryId": .string(id),
                "pendingStatus": "steer", "createdAt": 1500,
            ],
        ])
        try await waitUntil("desktop confirms steering mode") {
            model.entries.contains { $0.id == id && $0.pendingStatus == "steer" }
        }

        // Persistence contains the same user row but strips the live pending flag.
        server.sessionEntries = [sessionId: [[
            "id": .string(id), "kind": "user", "createdAt": 1500,
            "content": [["type": "text", "text": "Follow up"]],
        ], [
            "id": "saved", "kind": "user", "createdAt": 900,
            "content": [["type": "text", "text": "Prior prompt"]],
        ]]]
        model.refresh()
        try await waitUntil("refreshed history") { model.entries.contains(where: { $0.id == "saved" }) }
        XCTAssertEqual(model.entries.first(where: { $0.id == id })?.pendingStatus, "steer")

        server.broadcastEvent(kind: "session:stream-event", data: [
            "sessionId": .string(sessionId), "runId": "run-1", "event": [
                "type": "user-entry",
                "entry": [
                    "id": .string(id), "kind": "user", "createdAt": 2000,
                    "content": [["type": "text", "text": "Follow up"]],
                ],
            ],
        ])
        try await waitUntil("the desktop activates the same prompt") {
            model.entries.contains { $0.id == id && $0.pendingStatus == nil }
        }
        XCTAssertEqual(model.entries.filter { $0.id == id }.count, 1)
    }

    func testRenderedThreadViewShowsAndHidesNonInteractiveBuildStatus() throws {
        let previousLanguage = LocalizationManager.shared.language
        defer {
            LocalizationManager.shared.language = previousLanguage
            L10n.configure(language: previousLanguage)
        }
        LocalizationManager.shared.language = .simplifiedChinese
        L10n.configure(language: .simplifiedChinese)

        let suiteName = "SystemPromptBuildStatusTests.View.\(UUID().uuidString)"
        let (client, store, defaults) = try makeConnectedClient(suiteName: suiteName)
        defer {
            client.stop()
            store.remove(client.connection.id)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let sessionId = "sess-view"
        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": .string(sessionId),
            "title": "Prompt Build UI Test",
            "unread": false,
            "createdAt": 100,
            "updatedAt": 100,
        ])

        let router = Router()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let userEntry = ConversationEntry(localUserEntryId: "u1", text: "Hello", createdAt: 1000)
        let liveEmptyTurn = AssistantTurn(items: [], startedAt: 1001, pausedMs: 0, isLive: true)

        let host = UIHostingController(rootView: VStack(alignment: .leading, spacing: 24) {
            UserBubble(entry: userEntry, knownSkills: [])
            AssistantTurnView(
                turn: liveEmptyTurn,
                context: TurnContext(isBuildingSystemPrompt: true),
                wrapLines: true
            )
        })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        func collectAccessibilityItems(in root: AnyObject) -> [(identifier: String, label: String, isButton: Bool)] {
            var items: [(String, String, Bool)] = []
            var visited = Set<ObjectIdentifier>()
            func walk(_ object: AnyObject) {
                let oid = ObjectIdentifier(object)
                guard visited.insert(oid).inserted else { return }
                if let uiView = object as? UIView {
                    guard !uiView.isHidden, uiView.alpha > 0.01 else { return }
                    let id = uiView.accessibilityIdentifier ?? ""
                    let label = uiView.accessibilityLabel ?? (uiView as? UILabel)?.text ?? ""
                    let isButton = uiView.accessibilityTraits.contains(.button)
                    if !id.isEmpty || !label.isEmpty {
                        items.append((id, label, isButton))
                    }
                    for subview in uiView.subviews {
                        walk(subview)
                    }
                } else if let nsObject = object as? NSObject {
                    let id = (nsObject as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? ""
                    let label = nsObject.accessibilityLabel ?? ""
                    let isButton = nsObject.accessibilityTraits.contains(.button)
                    if !id.isEmpty || !label.isEmpty {
                        items.append((id, label, isButton))
                    }
                }
                if let container = object as? NSObject {
                    let count = container.accessibilityElementCount()
                    if count != NSNotFound && count > 0 {
                        for index in 0..<count {
                            if let child = container.accessibilityElement(at: index) as AnyObject? {
                                walk(child)
                            }
                        }
                    }
                }
            }
            walk(root)
            return items
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.layoutIfNeeded()

        let expectedLabel = L10n.Turn.buildingSystemPrompt
        XCTAssertEqual(expectedLabel, "正在构建增强性系统提示词")

        let activeItems = collectAccessibilityItems(in: window)
        let statusMatches = activeItems.filter {
            $0.identifier == "system-prompt-build-status" || $0.label.contains(expectedLabel)
        }
        XCTAssertFalse(statusMatches.isEmpty, "Expected system-prompt-build-status in rendered hierarchy, got: \(activeItems)")
        XCTAssertTrue(statusMatches.allSatisfy { !$0.isButton }, "Status row must be non-interactive")

        // Hide when building finishes.
        host.rootView = VStack(alignment: .leading, spacing: 24) {
            UserBubble(entry: userEntry, knownSkills: [])
            AssistantTurnView(
                turn: liveEmptyTurn,
                context: TurnContext(isBuildingSystemPrompt: false),
                wrapLines: true
            )
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        window.layoutIfNeeded()

        let hiddenItems = collectAccessibilityItems(in: window)
        XCTAssertFalse(
            hiddenItems.contains { $0.identifier == "system-prompt-build-status" || $0.label.contains(expectedLabel) },
            "Expected system-prompt-build-status to hide when build finishes, got: \(hiddenItems)"
        )

        // Also verify full ThreadView backed by PromptBuildMockServer reacts to building-system-prompt -> running.
        let server = try PromptBuildMockServer()
        defer { server.stop() }
        let liveSessionId = "sess-live-ui"
        server.sessionEntries[liveSessionId] = [[
            "id": "u-live-1",
            "kind": "user",
            "createdAt": 1000,
            "content": [["type": "text", "text": "Build prompt test"]],
        ]]
        server.activeRunsResult = [[
            "sessionId": .string(liveSessionId),
            "runId": "run-live-ui",
            "clientId": "desktop-main",
            "status": "building-system-prompt",
            "updatedAt": 2000,
        ]]

        let liveSuite = "SystemPromptBuildStatusTests.LiveView.\(UUID().uuidString)"
        let liveDefaults = try XCTUnwrap(UserDefaults(suiteName: liveSuite))
        let liveStore = ConnectionStore(defaults: liveDefaults, persistsCredentials: false)
        let liveConnection = DesktopConnection(
            id: UUID(),
            name: "Studio Mac",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .display,
            isEnabled: true
        )
        liveStore.add(liveConnection, password: "")
        let liveClient = try XCTUnwrap(liveStore.client(for: liveConnection.id))
        defer {
            liveClient.stop()
            liveStore.remove(liveConnection.id)
            liveDefaults.removePersistentDomain(forName: liveSuite)
        }

        let threadHost = UIHostingController(rootView: NavigationStack {
            ThreadView(connectionId: liveConnection.id, sessionId: liveSessionId)
                .environment(router)
                .environment(liveStore)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
        })
        window.rootViewController = threadHost
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.layoutIfNeeded()

        let deadline = Date().addingTimeInterval(3.0)
        var foundBuildStatus = false
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()
            let items = collectAccessibilityItems(in: window)
            let matches = items.filter {
                $0.identifier == "system-prompt-build-status" || $0.label.contains(expectedLabel)
            }
            if !matches.isEmpty {
                XCTAssertTrue(matches.allSatisfy { !$0.isButton })
                foundBuildStatus = true
                break
            }
        }
        XCTAssertTrue(foundBuildStatus, "Expected ThreadView to render system-prompt-build-status, got: \(collectAccessibilityItems(in: window))")

        server.broadcastEvent(kind: "session:run-status", data: [
            "sessionId": .string(liveSessionId),
            "runId": "run-live-ui",
            "status": "running",
            "updatedAt": 2010,
        ])
        let hideDeadline = Date().addingTimeInterval(3.0)
        var hidBuildStatus = false
        while Date() < hideDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()
            let items = collectAccessibilityItems(in: window)
            if !items.contains(where: { $0.identifier == "system-prompt-build-status" || $0.label.contains(expectedLabel) }) {
                hidBuildStatus = true
                break
            }
        }
        XCTAssertTrue(hidBuildStatus, "Expected ThreadView to hide system-prompt-build-status after transition to running")
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 3.0,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for: \(description)")
    }
}

private final class PromptBuildMockServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "PromptBuildMockServer")
    private let lock = NSLock()
    private var _activeRunsResult: [JSONValue] = []
    private var _sessionEntries: [String: [JSONValue]] = [:]
    private var _delegateRequest: JSONValue?
    private var wsConnections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    var activeRunsResult: [JSONValue] {
        get { lock.withLock { _activeRunsResult } }
        set { lock.withLock { _activeRunsResult = newValue } }
    }

    var sessionEntries: [String: [JSONValue]] {
        get { lock.withLock { _sessionEntries } }
        set { lock.withLock { _sessionEntries = newValue } }
    }

    var delegateRequest: JSONValue? {
        lock.withLock { _delegateRequest }
    }

    func broadcastEvent(kind: String, data: JSONValue) {
        let envelope: JSONValue = [
            "type": "event",
            "event": [
                "kind": .string(kind),
                "data": data,
            ],
        ]
        guard let text = try? envelope.jsonString() else { return }
        let conns = lock.withLock { wsConnections }
        for conn in conns {
            sendWSText(conn: conn, text: text)
        }
    }

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
            self?.handle(conn)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, port > 0 else {
            throw NSError(domain: "PromptBuildMockServer", code: 1)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        readHTTP(conn: conn, buffer: Data())
    }

    private func readHTTP(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data {
                buf.append(data)
            }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headerText = String(decoding: buf[..<range.lowerBound], as: UTF8.self)
                let lines = headerText.components(separatedBy: "\r\n")
                let requestLine = lines.first ?? ""
                let parts = requestLine.split(separator: " ")
                let path = parts.count >= 2 ? String(parts[1]) : "/"
                var wsKey: String?
                for line in lines {
                    let pair = line.split(separator: ":", maxSplits: 1)
                    if pair.count == 2, pair[0].lowercased() == "sec-websocket-key" {
                        wsKey = pair[1].trimmingCharacters(in: .whitespaces)
                    }
                }
                if path.hasPrefix("/api/ws"), let wsKey {
                    let accept = Self.websocketAccept(for: wsKey)
                    let upgrade = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
                    let leftover = Data(buf[range.upperBound...])
                    conn.send(content: Data(upgrade.utf8), completion: .contentProcessed { [weak self] _ in
                        guard let self else { return }
                        self.lock.withLock { self.wsConnections.append(conn) }
                        if let hello = try? JSONValue.object([
                            "type": "hello",
                            "clientId": "mock-desktop",
                        ]).jsonString() {
                            self.sendWSText(conn: conn, text: hello)
                        }
                        self.readWSLoop(conn: conn, buffer: leftover)
                    })
                    return
                }
                if path.hasPrefix("/api/auth/status") {
                    let body = #"{"required":false,"authenticated":true}"#
                    let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in
                        conn.cancel()
                    })
                    return
                }
                let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in
                    conn.cancel()
                })
                return
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.readHTTP(conn: conn, buffer: buf)
        }
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
            if opcode == 0x01,
               let rpc = JSONValue.parse(payload),
               rpc["type"]?.stringValue == "rpc",
               let id = rpc["id"]?.stringValue,
               let method = rpc["method"]?.stringValue
            {
                let args = rpc["args"]?.arrayValue ?? []
                let result: JSONValue
                switch method {
                case "session:getActiveRuns":
                    result = .array(activeRunsResult)
                case "session:get":
                    let sid = args.first?.stringValue ?? ""
                    let entries = sessionEntries[sid] ?? []
                    result = [
                        "entries": .array(entries),
                        "subAgents": .array([]),
                    ]
                case "session:listSessions":
                    result = .array([])
                case "session:delegateRun":
                    lock.withLock { _delegateRequest = args.first }
                    result = .null
                case "kvstore:get":
                    let key = args.first?.stringValue ?? ""
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
            guard big <= UInt64(Int.max) else { return nil }
            length = Int(big)
            offset += 8
        }
        var mask = [UInt8](repeating: 0, count: 4)
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            mask = Array(bytes[offset..<(offset + 4)])
            offset += 4
        }
        guard bytes.count >= offset + length else { return nil }
        var payload = Data(bytes[offset..<(offset + length)])
        if masked {
            for idx in 0..<length {
                payload[idx] ^= mask[idx % 4]
            }
        }
        return (opcode, payload, offset + length)
    }

    private static func websocketAccept(for key: String) -> String {
        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
        return Data(digest).base64EncodedString()
    }
}
