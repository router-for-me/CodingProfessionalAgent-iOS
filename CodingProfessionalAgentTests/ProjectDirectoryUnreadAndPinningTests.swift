import CryptoKit
import Foundation
import Network
import SwiftUI
import UIKit
import XCTest
@testable import CodingProfessionalAgent

@MainActor
final class ProjectDirectoryUnreadAndPinningTests: XCTestCase {
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

    private struct RightColumnPixelScan {
        var blueDotCenterY: CGFloat?
        var redDotCentersY: [CGFloat] = []
        var firstNonWhiteIndicatorY: CGFloat?
    }

    // Renders the window in light mode and scans the trailing indicator column of project thread rows.
    private func scanRightSideIndicators(in window: UIWindow, minY: CGFloat = 180) throws -> RightColumnPixelScan {
        window.overrideUserInterfaceStyle = .light
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &raw,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Failed to create bitmap context")
            return RightColumnPixelScan()
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let startY = max(Int(minY), 0)
        // Project header has a 44pt square.and.pencil button near y ~ 190..235; scan rows below y = minY.
        let minX = max(width - 60, 0)
        let maxX = max(width - 14, minX)

        var blueRows: [Int] = []
        var redRows: [Int] = []
        var nonWhiteRows: [Int] = []

        for y in startY..<min(height - 90, height) {
            var rowHasBlue = false
            var rowHasRed = false
            var rowHasNonWhite = false
            for x in minX..<maxX {
                let offset = (y * width + x) * 4
                let r = Int(raw[offset])
                let g = Int(raw[offset + 1])
                let b = Int(raw[offset + 2])
                if b > 200, r < 80, b - r > 130 {
                    rowHasBlue = true
                } else if r > 200, g < 100, b < 100, r - b > 120 {
                    rowHasRed = true
                } else if r < 235 || g < 235 || b < 235 {
                    rowHasNonWhite = true
                }
            }
            if rowHasBlue {
                blueRows.append(y)
            }
            if rowHasRed {
                redRows.append(y)
            }
            if rowHasBlue || rowHasRed || rowHasNonWhite {
                nonWhiteRows.append(y)
            }
        }

        func clusterCenters(_ ys: [Int]) -> [CGFloat] {
            guard !ys.isEmpty else { return [] }
            var clusters: [[Int]] = [[ys[0]]]
            for y in ys.dropFirst() {
                if y - clusters[clusters.count - 1].last! <= 12 {
                    clusters[clusters.count - 1].append(y)
                } else {
                    clusters.append([y])
                }
            }
            return clusters.map { cluster in
                CGFloat(cluster.reduce(0, +)) / CGFloat(cluster.count)
            }
        }

        var scan = RightColumnPixelScan()
        scan.blueDotCenterY = clusterCenters(blueRows).first
        scan.redDotCentersY = clusterCenters(redRows)
        scan.firstNonWhiteIndicatorY = nonWhiteRows.first.map { CGFloat($0) }
        return scan
    }

    func testProjectDirectoryPinsRunningThenUnreadAboveReadThreadsByUpdatedAt() throws {
        let suiteName = "ProjectDirectoryTests.Order.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let connection = DesktopConnection(
            id: UUID(),
            name: "Studio",
            host: "127.0.0.1",
            port: 59998,
            icon: .laptop,
            isEnabled: false
        )
        store.add(connection, password: "")
        defer {
            store.remove(connection.id)
            defaults.removePersistentDomain(forName: suiteName)
        }
        // Enable in-memory without opening real network sockets by feeding messages directly after lookup.
        store.setEnabled(connection.id, true)
        let client = try XCTUnwrap(store.client(for: connection.id))
        client.stop()
        try markConnected(client)

        try sendEvent(client, kind: "projects:updated", data: [
            ["id": "p1", "name": "CPA-iOS", "pinned": false, "updatedAt": 100],
        ])

        let sessions: [JSONValue] = [
            ["id": "s-read-1", "projectId": "p1", "title": "最新已读1", "unread": false, "createdAt": 10, "updatedAt": 904],
            ["id": "s-read-2", "projectId": "p1", "title": "最新已读2", "unread": false, "createdAt": 10, "updatedAt": 903],
            ["id": "s-read-3", "projectId": "p1", "title": "最新已读3", "unread": false, "createdAt": 10, "updatedAt": 902],
            ["id": "s-read-4", "projectId": "p1", "title": "最新已读4", "unread": false, "createdAt": 10, "updatedAt": 901],
            ["id": "s-unread-older", "projectId": "p1", "title": "较早未读蓝点", "unread": true, "createdAt": 10, "updatedAt": 200],
            ["id": "s-unread-newer", "projectId": "p1", "title": "较新异常红点", "unread": "error", "createdAt": 10, "updatedAt": 300],
            ["id": "s-running-oldest", "projectId": "p1", "title": "最早运行中任务", "unread": false, "createdAt": 10, "updatedAt": 100],
        ]
        for session in sessions {
            try sendEvent(client, kind: "session:meta-updated", data: session)
        }
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-running-oldest", "runId": "r-old", "status": "running", "updatedAt": 101,
        ])

        let router = Router()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        let root = HomeView()
            .environment(router)
            .environment(store)
            .defaultAppStorage(defaults)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        // Project header sits at y = 236..288; scan thread rows starting strictly below it at y = 290.
        let scan = try scanRightSideIndicators(in: window, minY: 290)
        let spinnerY = try XCTUnwrap(scan.firstNonWhiteIndicatorY, "Expected running task spinner in top thread row")
        let redDotY = try XCTUnwrap(scan.redDotCentersY.first, "Expected newer unread error dot pinned above read threads")
        let blueDotY = try XCTUnwrap(scan.blueDotCenterY, "Expected older unread blue dot pinned above 4 newer read threads")

        // Expected order from top to bottom: Running (updatedAt 100) -> Unread Error (300) -> Unread Blue (200) -> Read (904..901).
        XCTAssertLessThan(spinnerY + 25, redDotY, "Running row must appear above unread error row")
        XCTAssertLessThan(redDotY + 25, blueDotY, "Newer unread error row (300) must appear above older unread blue row (200)")
        // Must sit in the first 3 thread rows (row 0 spinner ~304, row 1 red ~363.5, row 2 blue ~415.5).
        XCTAssertLessThan(blueDotY, spinnerY + 130)
    }

    func testProjectDirectoryExposesAllRunningAndUnreadThreadsEvenAboveCollapsedLimit() throws {
        let suiteName = "ProjectDirectoryTests.Limit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let connection = DesktopConnection(
            id: UUID(),
            name: "Studio",
            host: "127.0.0.1",
            port: 59997,
            icon: .laptop,
            isEnabled: false
        )
        store.add(connection, password: "")
        defer {
            store.remove(connection.id)
            defaults.removePersistentDomain(forName: suiteName)
        }
        store.setEnabled(connection.id, true)
        let client = try XCTUnwrap(store.client(for: connection.id))
        client.stop()
        try markConnected(client)

        try sendEvent(client, kind: "projects:updated", data: [
            ["id": "p1", "name": "CPA-iOS", "pinned": false, "updatedAt": 100],
        ])

        // Two newer read sessions plus five error-unread sessions (201..205) plus a 6th oldest blue-unread session (50).
        // Without expanding the collapsed limit past 5 for attention threads, the 6th unread session (blue dot) is hidden.
        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": "read-1", "projectId": "p1", "title": "已读会话A", "unread": false, "createdAt": 1, "updatedAt": 900,
        ])
        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": "read-2", "projectId": "p1", "title": "已读会话B", "unread": false, "createdAt": 1, "updatedAt": 800,
        ])
        for idx in 1...5 {
            let sid = "err-\(idx)"
            try sendEvent(client, kind: "session:meta-updated", data: [
                "id": .string(sid), "projectId": "p1", "title": .string("异常未读会话\(idx)"),
                "unread": "error", "createdAt": 1, "updatedAt": .number(Double(200 + idx)),
            ])
        }
        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": "blue-6th", "projectId": "p1", "title": "第六条未读蓝点",
            "unread": true, "createdAt": 1, "updatedAt": 50,
        ])

        let router = Router()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 440, height: 1400)
        let root = HomeView()
            .environment(router)
            .environment(store)
            .defaultAppStorage(defaults)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let scan = try scanRightSideIndicators(in: window, minY: 290)
        XCTAssertEqual(scan.redDotCentersY.count, 5, "All 5 newer unread error rows must be visible")
        let sixthBlueDotY = try XCTUnwrap(scan.blueDotCenterY, "6th unread blue-dot row must not be hidden behind collapsed limit 5")
        XCTAssertGreaterThan(sixthBlueDotY, try XCTUnwrap(scan.redDotCentersY.last) + 25)
    }

    func testCompletedTopLevelRunMarksUnviewedSessionUnreadAndPersistsViaSetMeta() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s1", "projectId": "p1", "title": "后台构建任务", "unread": false, "createdAt": 100, "updatedAt": 100],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.session(id: "s1") != nil
        }
        XCTAssertEqual(client.session(id: "s1")?.unread, .read)

        // Simulate Desktop's `saveSession` updating SQLite `updated_at` to 120 without broadcasting `session:meta-updated`:
        // iOS's `session:setMeta(unread: true)` must NOT overwrite the server's newer `updatedAt: 120` with stale `100`!
        server.sessions = [
            ["id": "s1", "projectId": "p1", "title": "后台完成的任务", "unread": false, "createdAt": 100, "updatedAt": 120],
        ]

        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s1", "runId": "r1", "status": "running", "updatedAt": 110,
        ])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s1",
            "runId": "r1",
            "event": [
                "type": "assistant-end",
                "entry": ["id": "a1", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 115],
            ],
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s1", "runId": "r1", "status": "idle", "updatedAt": 120,
        ])

        // Local unread state updates synchronously on transition to idle so the row never flickers.
        XCTAssertEqual(client.session(id: "s1")?.unread, .unread)

        try await waitUntil("session:setMeta persisted unread = true without regressing updatedAt") {
            server.setMetaCalls.contains {
                $0["id"]?.stringValue == "s1"
                    && $0["unread"]?.boolValue == true
                    && $0["updatedAt"] == nil
            } && client.session(id: "s1")?.updatedAt == 120
        }
    }

    func testErroredTopLevelRunMarksUnviewedSessionErrorAndPersistsViaSetMeta() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-err", "projectId": "p1", "title": "失败任务", "unread": false, "createdAt": 50, "updatedAt": 50],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.session(id: "s-err") != nil
        }

        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-err", "runId": "r-err", "status": "running", "updatedAt": 60,
        ])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-err",
            "runId": "r-err",
            "event": ["type": "error", "message": "gateway timeout"],
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-err", "runId": "r-err", "status": "idle", "updatedAt": 70,
        ])

        XCTAssertEqual(client.session(id: "s-err")?.unread, .error)

        try await waitUntil("session:setMeta persisted unread = error") {
            server.setMetaCalls.contains {
                $0["id"]?.stringValue == "s-err" && $0["unread"]?.stringValue == "error"
            }
        }
    }

    func testViewedSessionStaysReadOnCompletionAndBeginViewingClearsUnreadImmediately() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-viewed", "title": "当前查看中", "unread": false, "createdAt": 10, "updatedAt": 10],
            ["id": "s-unviewed", "title": "后台完成待查看", "unread": false, "createdAt": 20, "updatedAt": 20],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.sessions.count == 2
        }

        // 1. Actively viewed conversation stays read when its run finishes.
        client.beginViewing(sessionId: "s-viewed")
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-viewed", "runId": "r-v", "status": "running", "updatedAt": 30,
        ])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-viewed",
            "runId": "r-v",
            "event": [
                "type": "assistant-end",
                "entry": ["id": "a-v", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 35],
            ],
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-viewed", "runId": "r-v", "status": "idle", "updatedAt": 40,
        ])
        XCTAssertEqual(client.session(id: "s-viewed")?.unread, .read)
        client.endViewing(sessionId: "s-viewed")

        // 2. Unviewed conversation becomes unread on completion, then clears immediately on beginViewing.
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-unviewed", "runId": "r-u", "status": "running", "updatedAt": 50,
        ])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-unviewed",
            "runId": "r-u",
            "event": [
                "type": "assistant-end",
                "entry": ["id": "a-u", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 55],
            ],
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-unviewed", "runId": "r-u", "status": "idle", "updatedAt": 60,
        ])
        XCTAssertEqual(client.session(id: "s-unviewed")?.unread, .unread)

        try await waitUntil("unread = true persisted") {
            server.setMetaCalls.contains {
                $0["id"]?.stringValue == "s-unviewed" && $0["unread"]?.boolValue == true
            }
        }

        // Delay setMeta reply and wait until the RPC actually arrives on the server before leaving the view.
        server.holdSetMetaReplies = true
        client.beginViewing(sessionId: "s-unviewed")
        XCTAssertEqual(client.session(id: "s-unviewed")?.unread, .read)
        try await waitUntil("mark-read setMeta in flight on server") {
            server.heldSetMetaCount == 1
        }
        client.endViewing(sessionId: "s-unviewed")
        server.releaseHeldSetMetaReplies()

        try await waitUntil("unread = false persisted even after leaving view") {
            server.setMetaCalls.contains {
                $0["id"]?.stringValue == "s-unviewed" && $0["unread"]?.boolValue == false
            }
        }
        XCTAssertFalse(server.setMetaCalls.contains {
            $0["id"]?.stringValue == "s-viewed" && $0["unread"]?.boolValue == true
        })
    }

    func testSubAgentAbortedAndCompactionRunsDoNotMarkSessionUnread() throws {
        let client = DesktopClient(connection: DesktopConnection(
            name: "Studio",
            host: "127.0.0.1",
            port: 18081,
            icon: .laptop,
            isEnabled: false
        ))

        // 1. Sub-agent
        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": "sub-1", "parentSessionId": "root-1", "title": "Sub", "unread": false, "createdAt": 1, "updatedAt": 1,
        ])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "sub-1", "runId": "r-sub", "status": "running", "updatedAt": 2])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "sub-1", "runId": "r-sub",
            "event": ["type": "assistant-end", "entry": ["id": "a1", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 3]],
        ])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "sub-1", "runId": "r-sub", "status": "idle", "updatedAt": 4])
        XCTAssertEqual(client.session(id: "sub-1")?.unread, .read)

        // 2. Aborted top-level run
        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": "s-abort", "title": "Aborted", "unread": false, "createdAt": 1, "updatedAt": 1,
        ])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "s-abort", "runId": "r-ab", "status": "running", "updatedAt": 2])
        try sendEvent(client, kind: "session:abort-run", data: ["sessionId": "s-abort"])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "s-abort", "runId": "r-ab", "status": "idle", "updatedAt": 3])
        XCTAssertEqual(client.session(id: "s-abort")?.unread, .read)

        // 3. Compaction-only run
        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": "s-compact", "title": "Compact", "unread": false, "createdAt": 1, "updatedAt": 1,
        ])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "s-compact", "runId": "r-cp", "status": "running", "updatedAt": 2])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-compact", "runId": "r-cp",
            "event": ["type": "compaction-end", "entry": ["id": "c1", "kind": "compaction", "createdAt": 3]],
        ])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "s-compact", "runId": "r-cp", "status": "idle", "updatedAt": 4])
        XCTAssertEqual(client.session(id: "s-compact")?.unread, .read)
    }

    func testPendingUnreadSurvivesStaleTitleBroadcastBeforeSetMetaLands() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-race", "title": "新对话", "unread": false, "createdAt": 100, "updatedAt": 100],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.session(id: "s-race") != nil
        }

        server.holdSetMetaReplies = true
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-race", "runId": "r-race", "status": "running", "updatedAt": 110,
        ])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-race",
            "runId": "r-race",
            "event": [
                "type": "assistant-end",
                "entry": ["id": "a-race", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 115],
            ],
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-race", "runId": "r-race", "status": "idle", "updatedAt": 120,
        ])
        XCTAssertEqual(client.session(id: "s-race")?.unread, .unread)
        try await waitUntil("mark-unread setMeta in flight on server") {
            server.heldSetMetaCount == 1
        }

        // Desktop updates title & `updatedAt: 125` in its DB and broadcasts `session:meta-updated` while our `session:setMeta(unread: true)` is genuinely in flight.
        server.sessions = [
            ["id": "s-race", "title": "自动生成的标题", "unread": false, "createdAt": 100, "updatedAt": 125],
        ]
        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": "s-race", "title": "自动生成的标题", "unread": false, "createdAt": 100, "updatedAt": 125,
        ])
        XCTAssertEqual(client.session(id: "s-race")?.title, "自动生成的标题")
        XCTAssertEqual(client.session(id: "s-race")?.unread, .unread)

        server.releaseHeldSetMetaReplies()
        try await waitUntil("setMeta completed") {
            server.setMetaCalls.contains { $0["id"]?.stringValue == "s-race" && $0["unread"]?.boolValue == true }
        }
        XCTAssertEqual(client.session(id: "s-race")?.unread, .unread)
        XCTAssertEqual(client.session(id: "s-race")?.updatedAt, 125)
    }

    func testHomeViewShowsRightSideBlueDotOnRunCompletionAndClearsOnViewing() throws {
        let suiteName = "ProjectDirectoryTests.E2E.\(UUID().uuidString)"
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
        defer {
            store.remove(connection.id)
            defaults.removePersistentDomain(forName: suiteName)
        }
        store.setEnabled(connection.id, true)
        let client = try XCTUnwrap(store.client(for: connection.id))
        client.stop()
        try markConnected(client)

        try sendEvent(client, kind: "projects:updated", data: [
            ["id": "p1", "name": "CPA-iOS", "pinned": false, "updatedAt": 100],
        ])
        for idx in 1...5 {
            try sendEvent(client, kind: "session:meta-updated", data: [
                "id": .string("read-\(idx)"), "projectId": "p1", "title": .string("较新已读\(idx)"),
                "unread": false, "createdAt": 10, "updatedAt": .number(Double(900 + idx)),
            ])
        }
        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": "s-target", "projectId": "p1", "title": "刚完成的较早对话",
            "unread": false, "createdAt": 10, "updatedAt": 50,
        ])

        let router = Router()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        let root = HomeView()
            .environment(router)
            .environment(store)
            .defaultAppStorage(defaults)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(try scanRightSideIndicators(in: window, minY: 290).blueDotCenterY)

        // Start and finish run while unviewed: must pin to top of p1 and render blue dot on right.
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-target", "runId": "r-target", "status": "running", "updatedAt": 60,
        ])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-target",
            "runId": "r-target",
            "event": [
                "type": "assistant-end",
                "entry": ["id": "a1", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 65],
            ],
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-target", "runId": "r-target", "status": "idle", "updatedAt": 70,
        ])

        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNotNil(
            try scanRightSideIndicators(in: window, minY: 290).blueDotCenterY,
            "Completed unviewed session must be pinned to top of project and display a blue dot on the right"
        )

        // Viewing the session clears the blue dot immediately.
        client.beginViewing(sessionId: "s-target")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(
            try scanRightSideIndicators(in: window, minY: 290).blueDotCenterY,
            "Viewing the session must clear the right-side blue dot"
        )
        client.endViewing(sessionId: "s-target")
    }

    func testReconnectAfterBackgroundCompletionMarksUnreadWhenUpdatedAtAdvances() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-bg", "projectId": "p1", "title": "断网期间完成", "unread": false, "createdAt": 30, "updatedAt": 30],
        ]
        server.activeRuns = [
            ["sessionId": "s-bg", "runId": "run-bg-1", "status": "running", "updatedAt": 31],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.isRunning("s-bg")
        }

        // While disconnected, desktop finishes the run (updatedAt advances, SQLite unread still false).
        server.activeRuns = []
        server.sessions = [
            ["id": "s-bg", "projectId": "p1", "title": "断网期间完成", "unread": false, "createdAt": 30, "updatedAt": 95],
        ]
        server.entriesBySession = [
            "s-bg": [
                ["id": "u-bg", "kind": "user", "createdAt": 31, "content": [["type": "text", "text": "build"]]],
                ["id": "a-bg", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 95, "content": [["type": "text", "text": "ok"]]],
            ],
        ]
        server.dropActiveWebSockets()

        try await waitUntil("reconnected and marked s-bg unread") {
            client.state == .connected && !client.isRunning("s-bg") && client.session(id: "s-bg")?.unread == .unread
        }
        try await waitUntil("persisted unread = true after reconnect") {
            server.setMetaCalls.contains { $0["id"]?.stringValue == "s-bg" && $0["unread"]?.boolValue == true }
        }
    }

    func testReconnectClassifiesOfflineErrorAndAbortEntriesWithoutFalseBlueDotOrNotification() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-ok", "projectId": "p1", "title": "离线正常完成", "unread": false, "createdAt": 30, "updatedAt": 30],
            ["id": "s-err", "projectId": "p1", "title": "离线报错结束", "unread": false, "createdAt": 30, "updatedAt": 30],
            ["id": "s-aborted", "projectId": "p1", "title": "离线被中止", "unread": false, "createdAt": 30, "updatedAt": 30],
        ]
        server.activeRuns = [
            ["sessionId": "s-ok", "runId": "r-ok", "status": "running", "updatedAt": 31],
            ["sessionId": "s-err", "runId": "r-err", "status": "running", "updatedAt": 31],
            ["sessionId": "s-aborted", "runId": "r-ab", "status": "running", "updatedAt": 31],
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
               let sid = event.payload["sessionId"]?.stringValue {
                completedIds.append(sid)
            }
        }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.activeTopLevelSessions.count == 3
        }

        server.activeRuns = []
        server.sessions = [
            ["id": "s-ok", "projectId": "p1", "title": "离线正常完成", "unread": false, "createdAt": 30, "updatedAt": 95],
            ["id": "s-err", "projectId": "p1", "title": "离线报错结束", "unread": false, "createdAt": 30, "updatedAt": 96],
            ["id": "s-aborted", "projectId": "p1", "title": "离线被中止", "unread": false, "createdAt": 30, "updatedAt": 97],
        ]
        server.entriesBySession = [
            "s-ok": [
                ["id": "u1", "kind": "user", "createdAt": 31, "content": [["type": "text", "text": "hi"]]],
                ["id": "a1", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 95, "content": [["type": "text", "text": "done"]]],
            ],
            "s-err": [
                ["id": "u2", "kind": "user", "createdAt": 31, "content": [["type": "text", "text": "hi"]]],
                ["id": "a2", "kind": "assistant", "status": "error", "stopReason": "error", "errorMessage": "upstream 500", "createdAt": 96, "content": []],
            ],
            "s-aborted": [
                ["id": "u3", "kind": "user", "createdAt": 31, "content": [["type": "text", "text": "hi"]]],
                ["id": "a3", "kind": "assistant", "status": "aborted", "stopReason": "aborted", "createdAt": 97, "content": []],
            ],
        ]
        server.dropActiveWebSockets()

        try await waitUntil("reconnected and reconciled offline outcomes") {
            client.state == .connected && client.activeTopLevelSessions.isEmpty && completedIds.count == 1
        }
        XCTAssertEqual(completedIds, ["s-ok"])
        XCTAssertEqual(client.session(id: "s-ok")?.unread, .unread)
        XCTAssertEqual(client.session(id: "s-err")?.unread, .error)
        XCTAssertEqual(client.session(id: "s-aborted")?.unread, .read)
    }

    func testSubsequentRunAfterAbortStillMarksSessionUnread() throws {
        let client = DesktopClient(connection: DesktopConnection(
            name: "Studio",
            host: "127.0.0.1",
            port: 18082,
            icon: .laptop,
            isEnabled: false
        ))

        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": "s-reuse", "title": "中止后重跑", "unread": false, "createdAt": 10, "updatedAt": 10,
        ])
        // First run is aborted.
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-reuse", "runId": "run-1", "status": "running", "updatedAt": 11,
        ])
        try sendEvent(client, kind: "session:abort-run", data: ["sessionId": "s-reuse"])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-reuse", "runId": "run-1", "status": "idle", "updatedAt": 12,
        ])
        XCTAssertEqual(client.session(id: "s-reuse")?.unread, .read)

        // Second run on the same session starts and completes normally while staying connected.
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-reuse", "runId": "run-2", "status": "running", "updatedAt": 20,
        ])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-reuse",
            "runId": "run-2",
            "event": [
                "type": "assistant-end",
                "entry": ["id": "a2", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 25],
            ],
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-reuse", "runId": "run-2", "status": "idle", "updatedAt": 26,
        ])
        XCTAssertEqual(client.session(id: "s-reuse")?.unread, .unread)
    }

    func testUnreadBroadcastDuringInFlightMarkReadTriggersFollowUpMarkRead() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-view-race", "title": "并发标记已读", "unread": true, "createdAt": 10, "updatedAt": 10],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.session(id: "s-view-race")?.unread == .unread
        }

        server.holdSetMetaReplies = true
        client.beginViewing(sessionId: "s-view-race")
        try await waitUntil("first mark-read setMeta in flight") {
            server.heldSetMetaCount == 1
        }

        // While the first unread=false write is in flight, a fresh unread=true broadcast arrives and server state flips back to true.
        server.sessions = [
            ["id": "s-view-race", "title": "并发标记已读", "unread": true, "createdAt": 10, "updatedAt": 15],
        ]
        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": "s-view-race", "title": "并发标记已读", "unread": true, "createdAt": 10, "updatedAt": 15,
        ])
        XCTAssertEqual(client.session(id: "s-view-race")?.unread, .read)

        // Complete the first setMeta (without letting it clear the newer server state before the follow-up).
        server.releaseHeldSetMetaReplies()
        try await waitUntil("follow-up mark-read setMeta sent") {
            server.setMetaCalls.filter {
                $0["id"]?.stringValue == "s-view-race" && $0["unread"]?.boolValue == false
            }.count == 2
        }
        client.endViewing(sessionId: "s-view-race")
    }

    func testOfflineCompactionMissingSessionAndMidReconcileDisconnectHandledSafely() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-compact-off", "title": "离线压缩", "unread": false, "createdAt": 10, "updatedAt": 50],
            ["id": "s-missing-off", "title": "离线被删详情", "unread": false, "createdAt": 10, "updatedAt": 50],
            ["id": "s-real-1", "title": "离线真实完成1", "unread": false, "createdAt": 10, "updatedAt": 50],
            ["id": "s-real-2", "title": "离线真实完成2", "unread": false, "createdAt": 10, "updatedAt": 50],
        ]
        server.activeRuns = [
            ["sessionId": "s-compact-off", "runId": "r-c", "status": "running", "updatedAt": 51],
            ["sessionId": "s-missing-off", "runId": "r-m", "status": "running", "updatedAt": 51],
            ["sessionId": "s-real-1", "runId": "r-1", "status": "running", "updatedAt": 51],
            ["sessionId": "s-real-2", "runId": "r-2", "status": "running", "updatedAt": 51],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        var completedIds: Set<String> = []
        _ = client.addListener { event in
            if event.kind == DesktopEvent.turnCompleted,
               let sid = event.payload["sessionId"]?.stringValue {
                completedIds.insert(sid)
            }
        }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.activeTopLevelSessions.count == 4
        }

        server.activeRuns = []
        server.sessions = [
            ["id": "s-compact-off", "title": "离线压缩", "unread": false, "createdAt": 10, "updatedAt": 90],
            ["id": "s-missing-off", "title": "离线被删详情", "unread": false, "createdAt": 10, "updatedAt": 90],
            ["id": "s-real-1", "title": "离线真实完成1", "unread": false, "createdAt": 10, "updatedAt": 91],
            ["id": "s-real-2", "title": "离线真实完成2", "unread": false, "createdAt": 10, "updatedAt": 92],
        ]
        // s-compact-off has an old read assistant entry (createdAt 40 <= 50) followed by a new compaction entry (90).
        // s-missing-off has no entries in entriesBySession, so session:get returns null.
        // s-real-1 and s-real-2 have genuine new completed assistant entries (> 50).
        server.entriesBySession = [
            "s-compact-off": [
                ["id": "u0", "kind": "user", "createdAt": 30, "content": [["type": "text", "text": "old"]]],
                ["id": "a0", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 40, "content": [["type": "text", "text": "old reply"]]],
                ["id": "c1", "kind": "compaction", "createdAt": 90, "summary": "compacted"],
            ],
            "s-real-1": [
                ["id": "u1", "kind": "user", "createdAt": 51, "content": [["type": "text", "text": "task1"]]],
                ["id": "a1", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 91, "content": [["type": "text", "text": "done1"]]],
            ],
            "s-real-2": [
                ["id": "u2", "kind": "user", "createdAt": 51, "content": [["type": "text", "text": "task2"]]],
                ["id": "a2", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 92, "content": [["type": "text", "text": "done2"]]],
            ],
        ]
        // Simulate socket dropping mid-reconciliation on the very first session:get call!
        server.dropOnSessionGetRemaining = 1
        server.dropActiveWebSockets()

        try await waitUntil("reconciled both s-real-1 and s-real-2 after mid-reconcile drop") {
            client.state == .connected && completedIds == ["s-real-1", "s-real-2"]
        }
        XCTAssertEqual(client.session(id: "s-real-1")?.unread, .unread)
        XCTAssertEqual(client.session(id: "s-real-2")?.unread, .unread)
        XCTAssertEqual(client.session(id: "s-compact-off")?.unread, .read)
        XCTAssertEqual(client.session(id: "s-missing-off")?.unread, .read)
    }

    func testDesktopAbortedStreamEventAndSilentIdleDoNotMarkSessionUnread() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-stream-abort", "title": "流式中止", "unread": false, "createdAt": 10, "updatedAt": 10],
            ["id": "s-silent-abort", "title": "静默中止", "unread": false, "createdAt": 10, "updatedAt": 10],
            ["id": "s-tail-done", "title": "中途连接收尾完成", "unread": false, "createdAt": 10, "updatedAt": 10],
        ]
        server.entriesBySession = [
            "s-silent-abort": [
                ["id": "u1", "kind": "user", "createdAt": 11, "content": [["type": "text", "text": "stop me"]]],
                ["id": "a1", "kind": "assistant", "status": "aborted", "stopReason": "aborted", "createdAt": 15, "content": []],
            ],
            "s-tail-done": [
                ["id": "u2", "kind": "user", "createdAt": 11, "content": [["type": "text", "text": "finish me"]]],
                ["id": "a2", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 18, "content": [["type": "text", "text": "done"]]],
            ],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.sessions.count == 3
        }

        // 1. Desktop broadcasts standalone `aborted` stream event before `idle`.
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-stream-abort", "runId": "r-sa", "status": "running", "updatedAt": 12,
        ])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-stream-abort",
            "runId": "r-sa",
            "event": ["type": "aborted"],
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-stream-abort", "runId": "r-sa", "status": "idle", "updatedAt": 13,
        ])
        XCTAssertEqual(client.session(id: "s-stream-abort")?.unread, .read)

        // 2. Desktop broadcasts `idle` directly after `running` with no terminal stream event:
        //    `s-silent-abort` has an aborted entry -> must stay `.read`;
        //    `s-tail-done` has a completed assistant entry -> must become `.unread`.
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-silent-abort", "runId": "r-sil", "status": "running", "updatedAt": 14,
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-silent-abort", "runId": "r-sil", "status": "idle", "updatedAt": 16,
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-tail-done", "runId": "r-tail", "status": "running", "updatedAt": 14,
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-tail-done", "runId": "r-tail", "status": "idle", "updatedAt": 19,
        ])

        try await waitUntil("s-tail-done verified via session:get and marked unread") {
            client.session(id: "s-tail-done")?.unread == .unread
        }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(client.session(id: "s-silent-abort")?.unread, .read)
        XCTAssertFalse(server.setMetaCalls.contains { $0["id"]?.stringValue == "s-silent-abort" })
    }

    func testAutoCompactionBeforeDisconnectStillRecoversOfflineAssistantCompletion() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-autocompact", "title": "自动压缩后回复", "unread": false, "createdAt": 10, "updatedAt": 40],
        ]
        server.activeRuns = [
            ["sessionId": "s-autocompact", "runId": "r-ac", "status": "running", "updatedAt": 41],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.isRunning("s-autocompact")
        }

        // Auto-compaction occurs at the beginning of a normal turn right before disconnect.
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-autocompact",
            "runId": "r-ac",
            "event": ["type": "compaction-end", "entry": ["id": "c1", "kind": "compaction", "createdAt": 45]],
        ])

        server.activeRuns = []
        server.sessions = [
            ["id": "s-autocompact", "title": "自动压缩后回复", "unread": false, "createdAt": 10, "updatedAt": 95],
        ]
        server.entriesBySession = [
            "s-autocompact": [
                ["id": "c1", "kind": "compaction", "createdAt": 45, "summary": "compacted"],
                ["id": "a-after", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 95, "content": [["type": "text", "text": "reply after compaction"]]],
            ],
        ]
        server.dropActiveWebSockets()

        try await waitUntil("s-autocompact recovered as unread after reconnect") {
            client.state == .connected && client.session(id: "s-autocompact")?.unread == .unread
        }
    }

    func testMidSessionGetViewingOrNewRunDoesNotClobberStateAfterAwait() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-view-mid", "title": "中途已查看", "unread": false, "createdAt": 10, "updatedAt": 20],
            ["id": "s-rerun-mid", "title": "中途启动新运行", "unread": false, "createdAt": 10, "updatedAt": 20],
        ]
        server.activeRuns = [
            ["sessionId": "s-view-mid", "runId": "r-old-1", "status": "running", "updatedAt": 21],
            ["sessionId": "s-rerun-mid", "runId": "r-old-2", "status": "running", "updatedAt": 21],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        var completedRunIds: [String] = []
        _ = client.addListener { event in
            if event.kind == DesktopEvent.turnCompleted,
               let rid = event.payload["runId"]?.stringValue {
                completedRunIds.append(rid)
            }
        }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.activeTopLevelSessions.count == 2
        }

        server.activeRuns = []
        server.sessions = [
            ["id": "s-view-mid", "title": "中途已查看", "unread": false, "createdAt": 10, "updatedAt": 80],
            ["id": "s-rerun-mid", "title": "中途启动新运行", "unread": false, "createdAt": 10, "updatedAt": 81],
        ]
        server.entriesBySession = [
            "s-view-mid": [
                ["id": "a-vm", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 80, "content": [["type": "text", "text": "done"]]],
            ],
            "s-rerun-mid": [
                ["id": "a-rm", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 81, "content": [["type": "text", "text": "done"]]],
            ],
        ]
        server.holdSessionGetReplies = true
        server.dropActiveWebSockets()

        try await waitUntil("session:get suspended in flight during reconcile") {
            server.heldSessionGetCount >= 1
        }

        // 1. User opens and leaves `s-view-mid` while `session:get` is suspended.
        client.beginViewing(sessionId: "s-view-mid")
        client.endViewing(sessionId: "s-view-mid")

        // 2. A brand-new run `r-new-2` starts on `s-rerun-mid` and finishes its assistant turn while `session:get` is suspended.
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-rerun-mid", "runId": "r-new-2", "status": "running", "updatedAt": 100,
        ])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-rerun-mid",
            "runId": "r-new-2",
            "event": [
                "type": "assistant-end",
                "entry": ["id": "a-new", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 105],
            ],
        ])

        // Release both held `session:get` responses (in case the second fires right after the first).
        server.releaseHeldSessionGetReplies()
        try await Task.sleep(for: .milliseconds(80))
        server.releaseHeldSessionGetReplies()
        try await Task.sleep(for: .milliseconds(80))

        // `s-view-mid` was already viewed after the offline run finished, so it must stay `.read`.
        XCTAssertEqual(client.session(id: "s-view-mid")?.unread, .read)

        // Now `r-new-2` transitions to `idle`: its `runOutcomes` must NOT have been wiped out by the stale reconcile!
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-rerun-mid", "runId": "r-new-2", "status": "idle", "updatedAt": 110,
        ])
        XCTAssertTrue(completedRunIds.contains("r-new-2"))
        XCTAssertEqual(client.session(id: "s-rerun-mid")?.unread, .unread)
    }

    func testAmbiguousIdleInterruptedBySocketDropRecoversUnreadAfterReconnect() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-amb-drop", "title": "模糊结束断线恢复", "unread": false, "createdAt": 10, "updatedAt": 10],
        ]
        server.entriesBySession = [
            "s-amb-drop": [
                ["id": "u1", "kind": "user", "createdAt": 11, "content": [["type": "text", "text": "go"]]],
                ["id": "a1", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 30, "content": [["type": "text", "text": "done"]]],
            ],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        var completedRunIds: [String] = []
        _ = client.addListener { event in
            if event.kind == DesktopEvent.turnCompleted,
               let rid = event.payload["runId"]?.stringValue {
                completedRunIds.append(rid)
            }
        }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.sessions.count == 1
        }

        // Server sessions updated to 30 while `unread` remains `false`; socket drops on the ambiguous-idle `session:get`.
        server.sessions = [
            ["id": "s-amb-drop", "title": "模糊结束断线恢复", "unread": false, "createdAt": 10, "updatedAt": 30],
        ]
        server.dropOnSessionGetRemaining = 1

        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-amb-drop", "runId": "r-amb-1", "status": "running", "updatedAt": 12,
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-amb-drop", "runId": "r-amb-1", "status": "idle", "updatedAt": 31,
        ])

        try await waitUntil("s-amb-drop recovered unread after reconnect") {
            client.state == .connected && client.session(id: "s-amb-drop")?.unread == .unread
        }
        XCTAssertEqual(completedRunIds, ["r-amb-1"])
    }

    func testStreamErrorAndPreIdleMetaUpdateRecoverAcrossDisconnect() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-err-drop", "title": "流报错后断线", "unread": false, "createdAt": 10, "updatedAt": 20],
            ["id": "s-meta-drop", "title": "元数据先到后断线", "unread": false, "createdAt": 10, "updatedAt": 20],
        ]
        server.activeRuns = [
            ["sessionId": "s-err-drop", "runId": "r-err-d", "status": "running", "updatedAt": 21],
            ["sessionId": "s-meta-drop", "runId": "r-meta-d", "status": "running", "updatedAt": 22],
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
               let sid = event.payload["sessionId"]?.stringValue {
                completedIds.append(sid)
            }
        }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.activeTopLevelSessions.count == 2
        }

        // 1. `s-err-drop` emits an error stream event before `idle`, then disconnects while server `unread` stays `false` and `updatedAt` stays `20`.
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-err-drop",
            "runId": "r-err-d",
            "event": ["type": "error", "message": "rate limit"],
        ])

        // 2. `s-meta-drop` receives its final `session:meta-updated` (`updatedAt: 85`) BEFORE `idle`, then disconnects with no further `updatedAt` bump on server!
        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": "s-meta-drop", "title": "元数据先到后断线", "unread": false, "createdAt": 10, "updatedAt": 85,
        ])

        server.activeRuns = []
        server.sessions = [
            ["id": "s-err-drop", "title": "流报错后断线", "unread": false, "createdAt": 10, "updatedAt": 20],
            ["id": "s-meta-drop", "title": "元数据先到后断线", "unread": false, "createdAt": 10, "updatedAt": 85],
        ]
        server.entriesBySession = [
            "s-meta-drop": [
                ["id": "u-m", "kind": "user", "createdAt": 21, "content": [["type": "text", "text": "hi"]]],
                ["id": "a-m", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 85, "content": [["type": "text", "text": "done"]]],
            ],
        ]
        server.dropActiveWebSockets()

        try await waitUntil("both s-err-drop and s-meta-drop reconciled after reconnect") {
            client.state == .connected
                && client.session(id: "s-err-drop")?.unread == .error
                && client.session(id: "s-meta-drop")?.unread == .unread
        }
        XCTAssertEqual(completedIds, ["s-meta-drop"])
    }

    func testInitialSyncActiveRunWithHistoricalReplyAndSupersededAmbiguousIdleDoNotMisfire() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        // `s-hist` has a historical completed assistant turn at t = 20, and an active run started at t = 50.
        server.sessions = [
            ["id": "s-hist", "title": "历史回复清理运行", "unread": false, "createdAt": 10, "updatedAt": 20],
            ["id": "s-supersede", "title": "旧运行被新运行取代", "unread": false, "createdAt": 10, "updatedAt": 10],
        ]
        server.activeRuns = [
            ["sessionId": "s-hist", "runId": "r-cleanup", "status": "running", "updatedAt": 50],
        ]
        server.entriesBySession = [
            "s-hist": [
                ["id": "u-old", "kind": "user", "createdAt": 15, "content": [["type": "text", "text": "yesterday"]]],
                ["id": "a-old", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 20, "content": [["type": "text", "text": "old reply"]]],
            ],
            "s-supersede": [
                ["id": "u-s", "kind": "user", "createdAt": 20, "content": [["type": "text", "text": "new"]]],
                ["id": "a-s", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 25, "content": [["type": "text", "text": "new reply"]]],
            ],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        var completedRunIds: [String] = []
        _ = client.addListener { event in
            if event.kind == DesktopEvent.turnCompleted,
               let rid = event.payload["runId"]?.stringValue {
                completedRunIds.append(rid)
            }
        }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.isRunning("s-hist")
        }

        // Part A: Host cleans up `r-cleanup` and broadcasts `idle` without any new assistant entry since t = 20.
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-hist", "runId": "r-cleanup", "status": "idle", "updatedAt": 55,
        ])
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(client.session(id: "s-hist")?.unread, .read)
        XCTAssertTrue(completedRunIds.isEmpty)

        // Part B: `r-old` triggers an ambiguous `idle` whose `session:get` is held; meanwhile `r-new` starts AND finishes.
        server.holdSessionGetReplies = true
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-supersede", "runId": "r-old", "status": "running", "updatedAt": 12,
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-supersede", "runId": "r-old", "status": "idle", "updatedAt": 15,
        ])
        try await waitUntil("r-old session:get held") {
            server.heldSessionGetCount == 1
        }

        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-supersede", "runId": "r-new", "status": "running", "updatedAt": 20,
        ])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-supersede",
            "runId": "r-new",
            "event": [
                "type": "assistant-end",
                "entry": ["id": "a-s", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 25],
            ],
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-supersede", "runId": "r-new", "status": "idle", "updatedAt": 26,
        ])
        XCTAssertEqual(completedRunIds, ["r-new"])

        server.releaseHeldSessionGetReplies()
        try await Task.sleep(for: .milliseconds(80))
        // `r-old`'s delayed `session:get` must NOT emit a second notification misattributed to `r-old`.
        XCTAssertEqual(completedRunIds, ["r-new"])
    }

    func testViewingRunningSessionAtDisconnectThenLeavingOfflineStillMarksUnreadOnReconnect() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-watched-running", "title": "观看运行中时断线", "unread": false, "createdAt": 10, "updatedAt": 20],
        ]
        server.activeRuns = [
            ["sessionId": "s-watched-running", "runId": "r-wr", "status": "running", "updatedAt": 21],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.isRunning("s-watched-running")
        }

        // User is viewing the running conversation when the socket drops.
        client.beginViewing(sessionId: "s-watched-running")

        server.activeRuns = []
        server.sessions = [
            ["id": "s-watched-running", "title": "观看运行中时断线", "unread": false, "createdAt": 10, "updatedAt": 90],
        ]
        server.entriesBySession = [
            "s-watched-running": [
                ["id": "u1", "kind": "user", "createdAt": 20, "content": [["type": "text", "text": "task"]]],
                ["id": "a1", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 90, "content": [["type": "text", "text": "completed offline"]]],
            ],
        ]
        // Hold `session:listSessions` on reconnect so we can deterministically leave `ThreadView` while offline/reconnecting before reconciliation.
        server.holdListSessionsReplies = true
        server.dropActiveWebSockets()

        // Wait until the client actually observes the disconnect (`snapshotInterruptedRunsIfNeeded` runs while still viewing!).
        try await waitUntil("client observed disconnect while viewing") {
            client.state != .connected
        }

        // User navigates back to `HomeView` (and even peeks at offline cached view & leaves again) while disconnected!
        client.endViewing(sessionId: "s-watched-running")
        client.beginViewing(sessionId: "s-watched-running")
        client.endViewing(sessionId: "s-watched-running")

        try await waitUntil("reconnect awaiting listSessions") {
            server.heldListSessionsCount >= 1
        }
        server.releaseHeldListSessionsReplies()

        try await waitUntil("s-watched-running marked unread after reconnect") {
            client.state == .connected && client.session(id: "s-watched-running")?.unread == .unread
        }
    }

    func testAmbiguousIdleArrivingMidResyncIsNotCancelledByStaleSyncedRuns() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-mid-resync", "title": "重同步中途结束", "unread": false, "createdAt": 10, "updatedAt": 20],
        ]
        server.activeRuns = [
            ["sessionId": "s-mid-resync", "runId": "r-mr", "status": "running", "updatedAt": 21],
        ]
        server.entriesBySession = [
            "s-mid-resync": [
                ["id": "u1", "kind": "user", "createdAt": 20, "content": [["type": "text", "text": "work"]]],
                ["id": "a1", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 60, "content": [["type": "text", "text": "finished"]]],
            ],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.isRunning("s-mid-resync")
        }

        // Start a manual `resync()` while holding `listSessions` and `session:get`.
        server.holdListSessionsReplies = true
        server.holdSessionGetReplies = true
        let resyncTask = Task { await client.resync() }

        try await waitUntil("resync paused at listSessions after getActiveRuns") {
            server.heldListSessionsCount == 1
        }

        // While `resync()` already fetched `syncedRuns` (`s-mid-resync` running), an ambiguous `idle` arrives!
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-mid-resync", "runId": "r-mr", "status": "idle", "updatedAt": 61,
        ])
        try await waitUntil("ambiguous-idle session:get held in flight") {
            server.heldSessionGetCount == 1
        }

        // Let `resync()` finish (`reconcileInterruptedRunsAfterResync` runs with stale `syncedRuns["s-mid-resync"]`) BEFORE `session:get` returns!
        server.releaseHeldListSessionsReplies()
        await resyncTask.value

        // Now release `session:get`: the mid-resync verification must NOT have been wiped out by stale `syncedRuns`!
        server.releaseHeldSessionGetReplies()
        try await waitUntil("s-mid-resync marked unread after delayed session:get") {
            client.session(id: "s-mid-resync")?.unread == .unread
        }
    }

    func testResyncReplacingErroredRunWithNewRunIdDoesNotCarryStaleErrorIntoNewIdle() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-replace-err", "title": "报错后离线开新轮", "unread": false, "createdAt": 10, "updatedAt": 20],
        ]
        server.activeRuns = [
            ["sessionId": "s-replace-err", "runId": "r-err-old", "status": "running", "updatedAt": 21],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.isRunning("s-replace-err")
        }

        // Old run emits an error stream event right before disconnect.
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-replace-err",
            "runId": "r-err-old",
            "event": ["type": "error", "message": "old failure"],
        ])

        // While disconnected, `r-err-old` ended and a brand-new run `r-clean-new` started and wrote a clean assistant reply at t = 95!
        server.activeRuns = [
            ["sessionId": "s-replace-err", "runId": "r-clean-new", "status": "running", "updatedAt": 80],
        ]
        server.sessions = [
            ["id": "s-replace-err", "title": "报错后离线开新轮", "unread": false, "createdAt": 10, "updatedAt": 95],
        ]
        server.entriesBySession = [
            "s-replace-err": [
                ["id": "u-new", "kind": "user", "createdAt": 80, "content": [["type": "text", "text": "retry"]]],
                ["id": "a-new", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 95, "content": [["type": "text", "text": "clean success"]]],
            ],
        ]
        server.dropActiveWebSockets()

        try await waitUntil("reconnected with new run active") {
            client.state == .connected && client.activeRuns["s-replace-err"]?.runId == "r-clean-new"
        }

        // Now `r-clean-new` broadcasts `idle` without repeating its already-emitted `assistant-end` stream event:
        // it must NOT inherit `sawError == true` from `r-err-old`, and must become `.unread` (blue dot, NOT `.error` red dot)!
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-replace-err", "runId": "r-clean-new", "status": "idle", "updatedAt": 96,
        ])
        try await waitUntil("s-replace-err verified as normal .unread") {
            client.session(id: "s-replace-err")?.unread == .unread
        }
    }

    func testDuplicateIdleDoesNotCancelInFlightAmbiguousIdleVerification() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-dup-idle", "title": "重复空闲广播", "unread": false, "createdAt": 10, "updatedAt": 10],
        ]
        server.entriesBySession = [
            "s-dup-idle": [
                ["id": "u1", "kind": "user", "createdAt": 11, "content": [["type": "text", "text": "go"]]],
                ["id": "a1", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 30, "content": [["type": "text", "text": "done"]]],
            ],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        var completedRunIds: [String] = []
        _ = client.addListener { event in
            if event.kind == DesktopEvent.turnCompleted,
               let rid = event.payload["runId"]?.stringValue {
                completedRunIds.append(rid)
            }
        }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.sessions.count == 1
        }

        server.holdSessionGetReplies = true
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-dup-idle", "runId": "r-di", "status": "running", "updatedAt": 12,
        ])
        // First `idle` (from `agent-end`) starts `session:get`.
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-dup-idle", "runId": "r-di", "status": "idle", "updatedAt": 31,
        ])
        try await waitUntil("session:get held") {
            server.heldSessionGetCount == 1
        }
        // Second duplicate `idle` (from `finally`) arrives while `session:get` is still in flight!
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-dup-idle", "runId": "r-di", "status": "idle", "updatedAt": 32,
        ])

        server.releaseHeldSessionGetReplies()
        try await waitUntil("s-dup-idle marked unread after delayed session:get") {
            client.session(id: "s-dup-idle")?.unread == .unread
        }
        XCTAssertEqual(completedRunIds, ["r-di"])
    }

    func testTransientSessionGetFailureDuringAmbiguousIdleRecoversOnManualResyncWithoutDisconnect() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-rpc-fail", "title": "临时查询失败重同步", "unread": false, "createdAt": 10, "updatedAt": 10],
        ]
        server.entriesBySession = [
            "s-rpc-fail": [
                ["id": "u1", "kind": "user", "createdAt": 11, "content": [["type": "text", "text": "go"]]],
                ["id": "a1", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 35, "content": [["type": "text", "text": "done"]]],
            ],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.sessions.count == 1
        }

        // First `session:get` fails with an `rpc_error` without dropping the WebSocket!
        server.failSessionGetRemaining = 1
        server.sessions = [
            ["id": "s-rpc-fail", "title": "临时查询失败重同步", "unread": false, "createdAt": 10, "updatedAt": 35],
        ]

        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-rpc-fail", "runId": "r-rf", "status": "running", "updatedAt": 12,
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-rpc-fail", "runId": "r-rf", "status": "idle", "updatedAt": 36,
        ])
        try await Task.sleep(for: .milliseconds(60))

        // Without disconnecting, an explicit `resync()` must retry the failed verification!
        await client.resync()
        try await waitUntil("s-rpc-fail marked unread after manual resync") {
            client.session(id: "s-rpc-fail")?.unread == .unread
        }
    }

    func testDelayedEntryPersistenceAfterAmbiguousIdleRecoversViaEntriesUpdated() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-delayed-save", "title": "空闲先于落盘到达", "unread": false, "createdAt": 10, "updatedAt": 10],
        ]
        // At `idle` time, SQLite still holds the in-progress `streaming` entry!
        server.entriesBySession = [
            "s-delayed-save": [
                ["id": "u1", "kind": "user", "createdAt": 11, "content": [["type": "text", "text": "go"]]],
                ["id": "a1", "kind": "assistant", "status": "streaming", "createdAt": 25, "content": [["type": "text", "text": "part"]]],
            ],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        var completedRunIds: [String] = []
        _ = client.addListener { event in
            if event.kind == DesktopEvent.turnCompleted,
               let rid = event.payload["runId"]?.stringValue {
                completedRunIds.append(rid)
            }
        }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.sessions.count == 1
        }

        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-delayed-save", "runId": "r-ds", "status": "running", "updatedAt": 12,
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-delayed-save", "runId": "r-ds", "status": "idle", "updatedAt": 26,
        ])
        try await Task.sleep(for: .milliseconds(50))
        // Not yet marked unread while entry is still `streaming`.
        XCTAssertEqual(client.session(id: "s-delayed-save")?.unread, .read)

        // Now Desktop's async persistence flushes the final `done` entry and emits `session:entries-updated`!
        server.entriesBySession = [
            "s-delayed-save": [
                ["id": "u1", "kind": "user", "createdAt": 11, "content": [["type": "text", "text": "go"]]],
                ["id": "a1", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 25, "completedAt": 28, "content": [["type": "text", "text": "complete"]]],
            ],
        ]
        try sendEvent(client, kind: "session:entries-updated", data: [
            "sessionId": "s-delayed-save",
        ])

        try await waitUntil("s-delayed-save marked unread once entries persisted") {
            client.session(id: "s-delayed-save")?.unread == .unread
        }
        XCTAssertEqual(completedRunIds, ["r-ds"])
    }

    func testLateEntryPersistenceBeyondRetryWindowStillRecoversViaEntriesUpdated() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-slow-save", "title": "超重试窗口慢落盘", "unread": false, "createdAt": 10, "updatedAt": 10],
        ]
        server.entriesBySession = [
            "s-slow-save": [
                ["id": "u1", "kind": "user", "createdAt": 11, "content": [["type": "text", "text": "go"]]],
                ["id": "a1", "kind": "assistant", "status": "streaming", "createdAt": 25, "content": [["type": "text", "text": "part"]]],
            ],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        var completedRunIds: [String] = []
        _ = client.addListener { event in
            if event.kind == DesktopEvent.turnCompleted,
               let rid = event.payload["runId"]?.stringValue {
                completedRunIds.append(rid)
            }
        }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.sessions.count == 1
        }

        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-slow-save", "runId": "r-slow", "status": "running", "updatedAt": 12,
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-slow-save", "runId": "r-slow", "status": "idle", "updatedAt": 26,
        ])
        // Wait 420ms so all short-term 120ms retries are completely exhausted while SQLite still holds `streaming`.
        try await Task.sleep(for: .milliseconds(420))
        XCTAssertEqual(client.session(id: "s-slow-save")?.unread, .read)

        // Now SQLite finishes persisting and emits `session:entries-updated`.
        server.entriesBySession = [
            "s-slow-save": [
                ["id": "u1", "kind": "user", "createdAt": 11, "content": [["type": "text", "text": "go"]]],
                ["id": "a1", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 25, "completedAt": 40, "content": [["type": "text", "text": "done"]]],
            ],
        ]
        try sendEvent(client, kind: "session:entries-updated", data: [
            "sessionId": "s-slow-save",
        ])

        try await waitUntil("s-slow-save marked unread after late session:entries-updated") {
            client.session(id: "s-slow-save")?.unread == .unread
        }
        XCTAssertEqual(completedRunIds, ["r-slow"])
    }

    func testStaleOfflineReadIntentDoesNotClearNewerOfflineCompletedTurnUnread() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-offline-new", "title": "离线旧已读不覆盖新结果", "unread": true, "createdAt": 10, "updatedAt": 20],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.session(id: "s-offline-new")?.unread == .unread
        }

        // Hold `listSessions` on reconnect so the offline view/leave happens deterministically before reconnect sessions arrive.
        server.holdListSessionsReplies = true
        server.dropActiveWebSockets()
        try await waitUntil("client disconnected") {
            client.state != .connected
        }

        // User views the old `updatedAt: 20` unread turn while disconnected, generating an offline read intent, then leaves.
        client.beginViewing(sessionId: "s-offline-new")
        client.endViewing(sessionId: "s-offline-new")

        // Meanwhile on Desktop, a brand-new turn started and completed at `updatedAt: 95` with `unread: true`!
        server.sessions = [
            ["id": "s-offline-new", "title": "离线旧已读不覆盖新结果", "unread": true, "createdAt": 10, "updatedAt": 95],
        ]
        server.entriesBySession = [
            "s-offline-new": [
                ["id": "u-new", "kind": "user", "createdAt": 90, "content": [["type": "text", "text": "follow up"]]],
                ["id": "a-new", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 95, "content": [["type": "text", "text": "fresh reply"]]],
            ],
        ]
        try await waitUntil("reconnect awaiting listSessions") {
            server.heldListSessionsCount >= 1
        }
        server.releaseHeldListSessionsReplies()

        try await waitUntil("reconnected and new turn unread preserved") {
            client.state == .connected
                && client.session(id: "s-offline-new")?.updatedAt == 95
                && client.session(id: "s-offline-new")?.unread == .unread
        }
        try await Task.sleep(for: .milliseconds(80))

        // The newer `updatedAt: 95` unread turn must remain `.unread` and must NOT be cleared on the server!
        XCTAssertEqual(client.session(id: "s-offline-new")?.unread, .unread)
        XCTAssertFalse(server.setMetaCalls.contains {
            $0["id"]?.stringValue == "s-offline-new" && $0["unread"]?.boolValue == false
        })
    }

    func testReconnectBeforeOfflineEntriesFlushStillRecoversWhenEntriesUpdatedArrives() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-reconn-unflushed", "title": "重连时落盘未完成", "unread": false, "createdAt": 10, "updatedAt": 20],
        ]
        server.activeRuns = [
            ["sessionId": "s-reconn-unflushed", "runId": "r-ru", "status": "running", "updatedAt": 21],
        ]
        server.entriesBySession = [
            "s-reconn-unflushed": [
                ["id": "u1", "kind": "user", "createdAt": 20, "content": [["type": "text", "text": "go"]]],
            ],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.isRunning("s-reconn-unflushed")
        }

        // At reconnect time, activeRuns is already empty, while `updatedAt` (20) and `entries` have NOT yet flushed!
        server.activeRuns = []
        server.dropActiveWebSockets()

        try await waitUntil("reconnected before flush") {
            client.state == .connected && !client.isRunning("s-reconn-unflushed")
        }
        try await Task.sleep(for: .milliseconds(250))

        // Now Desktop flushes the completed entry and broadcasts `session:entries-updated`!
        server.entriesBySession = [
            "s-reconn-unflushed": [
                ["id": "u1", "kind": "user", "createdAt": 20, "content": [["type": "text", "text": "go"]]],
                ["id": "a1", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 90, "content": [["type": "text", "text": "done"]]],
            ],
        ]
        try sendEvent(client, kind: "session:entries-updated", data: [
            "sessionId": "s-reconn-unflushed",
        ])

        try await waitUntil("s-reconn-unflushed marked unread once entries flushed") {
            client.session(id: "s-reconn-unflushed")?.unread == .unread
        }
    }

    func testOfflineReadIntentSurvivesMetadataRenameWhileStillPreservingTrueNewTurn() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-renamed-only", "title": "旧标题", "unread": true, "createdAt": 10, "updatedAt": 20],
        ]
        server.entriesBySession = [
            "s-renamed-only": [
                ["id": "u1", "kind": "user", "createdAt": 15, "content": [["type": "text", "text": "hi"]]],
                ["id": "a1", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 20, "content": [["type": "text", "text": "old reply"]]],
            ],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.session(id: "s-renamed-only")?.unread == .unread
        }

        server.holdListSessionsReplies = true
        server.dropActiveWebSockets()
        try await waitUntil("disconnected") {
            client.state != .connected
        }

        // User views `s-renamed-only` offline (`updatedAt: 20`) and leaves.
        client.beginViewing(sessionId: "s-renamed-only")
        client.endViewing(sessionId: "s-renamed-only")

        // On Desktop, ONLY the title was renamed (`updatedAt` bumped to 60, `entries` still ends at `t = 20`)!
        server.sessions = [
            ["id": "s-renamed-only", "title": "仅重命名的新标题", "unread": true, "createdAt": 10, "updatedAt": 60],
        ]
        try await waitUntil("reconnect awaiting listSessions") {
            server.heldListSessionsCount >= 1
        }
        server.releaseHeldListSessionsReplies()

        try await waitUntil("offline read synced to server despite rename") {
            client.state == .connected
                && client.session(id: "s-renamed-only")?.title == "仅重命名的新标题"
                && client.session(id: "s-renamed-only")?.unread == .read
                && server.setMetaCalls.contains {
                    $0["id"]?.stringValue == "s-renamed-only" && $0["unread"]?.boolValue == false
                }
        }
    }

    func testFailedManualMarkReadDoesNotRollbackToUnreadIfUserOpenedSessionMeanwhile() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-manual-open", "title": "手动标已读后打开", "unread": true, "createdAt": 10, "updatedAt": 20],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.session(id: "s-manual-open")?.unread == .unread
        }

        // Hold & fail the manual `setSessionUnread(unread: false)` RPC!
        server.holdSetMetaReplies = true
        server.failSetMetaRemaining = 1
        let manualTask = Task {
            try? await client.setSessionUnread(id: "s-manual-open", unread: false)
        }
        try await waitUntil("manual setMeta held") {
            server.heldSetMetaCount == 1
        }

        // While the manual RPC is in flight, the user opens `ThreadView`!
        client.beginViewing(sessionId: "s-manual-open")

        // Release the held manual RPC (which returns an error); the subsequent viewing read sync should succeed!
        server.releaseHeldSetMetaReplies()
        await manualTask.value

        try await waitUntil("viewing read sync persisted unread: false") {
            server.setMetaCalls.contains {
                $0["id"]?.stringValue == "s-manual-open" && $0["unread"]?.boolValue == false
            }
        }
        XCTAssertEqual(client.session(id: "s-manual-open")?.unread, .read)
        client.endViewing(sessionId: "s-manual-open")
        XCTAssertEqual(client.session(id: "s-manual-open")?.unread, .read)
    }

    func testPreviousErrorDoesNotPolluteNewCleanRunAndUnflushedNewTurnBlocksStaleReadFlush() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            // `s-prev-err` already carries `.error` from an earlier failed turn at t = 15.
            ["id": "s-prev-err", "title": "旧红点新成功", "unread": "error", "createdAt": 10, "updatedAt": 15],
            // `s-unflushed-new` has an old unread turn at t = 20.
            ["id": "s-unflushed-new", "title": "新轮尚未落盘", "unread": true, "createdAt": 10, "updatedAt": 20],
        ]
        server.entriesBySession = [
            "s-prev-err": [
                ["id": "u-pe", "kind": "user", "createdAt": 30, "content": [["type": "text", "text": "retry"]]],
                ["id": "a-pe", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 35, "content": [["type": "text", "text": "fixed"]]],
            ],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.sessions.count == 2
        }

        // Part A1: `s-prev-err` runs a new turn `r-fix` and transitions to `idle` without stream events:
        // must verify `entries` and upgrade `.error` -> `.unread` (blue dot, NOT sticky red dot)!
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-prev-err", "runId": "r-fix", "status": "running", "updatedAt": 31,
        ])
        // Mid-run title auto-generation broadcasts `session:meta-updated` while `unread` still carries old `"error"`!
        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": "s-prev-err", "title": "旧红点新成功（已生成标题）", "unread": "error", "createdAt": 10, "updatedAt": 32,
        ])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-prev-err",
            "runId": "r-fix",
            "event": [
                "type": "assistant-end",
                "entry": ["id": "a-pe", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 35],
            ],
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-prev-err", "runId": "r-fix", "status": "idle", "updatedAt": 36,
        ])
        XCTAssertEqual(client.session(id: "s-prev-err")?.unread, .unread)

        // Part B: User views `s-unflushed-new` (`updatedAt: 20`) offline and leaves; on reconnect, server reports
        // `unread: true, updatedAt: 95` while the new turn's assistant entry is STILL `streaming` (not yet flushed)!
        server.holdListSessionsReplies = true
        server.dropActiveWebSockets()
        try await waitUntil("disconnected") {
            client.state != .connected
        }
        client.beginViewing(sessionId: "s-unflushed-new")
        client.endViewing(sessionId: "s-unflushed-new")

        server.sessions = [
            ["id": "s-prev-err", "title": "旧红点新成功", "unread": true, "createdAt": 10, "updatedAt": 35],
            ["id": "s-unflushed-new", "title": "新轮尚未落盘", "unread": true, "createdAt": 10, "updatedAt": 95],
        ]
        server.entriesBySession["s-unflushed-new"] = [
            ["id": "u-un", "kind": "user", "createdAt": 90, "content": [["type": "text", "text": "new prompt"]]],
            ["id": "a-un", "kind": "assistant", "status": "streaming", "createdAt": 92, "content": [["type": "text", "text": "half"]]],
        ]
        try await waitUntil("reconnect awaiting listSessions") {
            server.heldListSessionsCount >= 1
        }
        server.releaseHeldListSessionsReplies()

        try await waitUntil("s-unflushed-new restored unread despite streaming entry") {
            client.state == .connected && client.session(id: "s-unflushed-new")?.unread == .unread
        }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(server.setMetaCalls.contains {
            $0["id"]?.stringValue == "s-unflushed-new" && $0["unread"]?.boolValue == false
        })

        // Part C: Even if ZERO entries of the new turn had hit SQLite at reconnect time (entries still only at `t = 92`),
        // once Desktop flushes the `t = 150` turn and broadcasts `session:entries-updated`, unread is restored on both client & server!
        server.holdListSessionsReplies = true
        server.dropActiveWebSockets()
        try await waitUntil("disconnected for Part C") {
            client.state != .connected
        }
        client.beginViewing(sessionId: "s-unflushed-new")
        client.endViewing(sessionId: "s-unflushed-new")

        server.sessions = [
            ["id": "s-prev-err", "title": "旧红点新成功", "unread": true, "createdAt": 10, "updatedAt": 35],
            ["id": "s-unflushed-new", "title": "新轮尚未落盘", "unread": true, "createdAt": 10, "updatedAt": 150],
        ]
        // At reconnect time, SQLite `entries` has NOT yet saved ANY entry > 95!
        try await waitUntil("reconnect awaiting listSessions for Part C") {
            server.heldListSessionsCount >= 1
        }
        server.releaseHeldListSessionsReplies()
        try await waitUntil("reconnected for Part C") {
            client.state == .connected
        }
        try await Task.sleep(for: .milliseconds(100))

        // Now SQLite finishes flushing the `t = 150` turn and broadcasts `session:entries-updated`!
        server.entriesBySession["s-unflushed-new"] = [
            ["id": "u-c", "kind": "user", "createdAt": 140, "content": [["type": "text", "text": "part c"]]],
            ["id": "a-c", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 150, "content": [["type": "text", "text": "flushed late"]]],
        ]
        try sendEvent(client, kind: "session:entries-updated", data: [
            "sessionId": "s-unflushed-new",
        ])

        try await waitUntil("s-unflushed-new restored unread on client and server after late entries-updated") {
            client.session(id: "s-unflushed-new")?.unread == .unread
                && server.sessions.first(where: { $0["id"]?.stringValue == "s-unflushed-new" })?["unread"]?.boolValue == true
        }

        // Part D: Same setup as Part C, except the socket drops BEFORE `session:entries-updated` arrives (entries flush while disconnected!):
        // reconnect `resync()` must recheck `flushedAmbiguousReads` and restore `.unread`!
        server.holdListSessionsReplies = true
        server.dropActiveWebSockets()
        try await waitUntil("disconnected for Part D setup") {
            client.state != .connected
        }
        client.beginViewing(sessionId: "s-unflushed-new")
        client.endViewing(sessionId: "s-unflushed-new")

        server.sessions = [
            ["id": "s-prev-err", "title": "旧红点新成功", "unread": true, "createdAt": 10, "updatedAt": 35],
            ["id": "s-unflushed-new", "title": "新轮尚未落盘", "unread": true, "createdAt": 10, "updatedAt": 220],
        ]
        try await waitUntil("reconnect awaiting listSessions for Part D") {
            server.heldListSessionsCount >= 1
        }
        server.releaseHeldListSessionsReplies()
        try await waitUntil("flushedAmbiguousReads recorded after temporary read write") {
            client.state == .connected
                && server.sessions.first(where: { $0["id"]?.stringValue == "s-unflushed-new" })?["unread"]?.boolValue == false
        }

        // Now drop socket BEFORE `entries-updated`, flush `t = 220` entries while offline, and let reconnect `resync()` recover!
        server.entriesBySession["s-unflushed-new"] = [
            ["id": "u-d", "kind": "user", "createdAt": 210, "content": [["type": "text", "text": "part d"]]],
            ["id": "a-d", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 220, "content": [["type": "text", "text": "flushed offline"]]],
        ]
        server.dropActiveWebSockets()

        try await waitUntil("s-unflushed-new restored unread across reconnect resync") {
            client.state == .connected
                && client.session(id: "s-unflushed-new")?.unread == .unread
                && server.sessions.first(where: { $0["id"]?.stringValue == "s-unflushed-new" })?["unread"]?.boolValue == true
        }
    }

    func testReconnectCarryOverUnreadColorAndInFlightReadFlushWithNewerTurnRepairState() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            // `s-carry-blue` already has `unread: true` from turn 1 (`t = 20`), and turn 2 is running (`r-err-2`).
            ["id": "s-carry-blue", "title": "旧蓝点新报错", "unread": true, "createdAt": 10, "updatedAt": 20],
            // `s-inflight-read` has `unread: true` at `t = 20`.
            ["id": "s-inflight-read", "title": "在途已读撞上新完成", "unread": true, "createdAt": 10, "updatedAt": 20],
        ]
        server.activeRuns = [
            ["sessionId": "s-carry-blue", "runId": "r-err-2", "status": "running", "updatedAt": 25],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.isRunning("s-carry-blue")
        }

        // Part A: `r-err-2` fails offline while server `unread` still holds old `true`: must upgrade to `.error` on reconnect!
        server.activeRuns = []
        server.sessions = [
            ["id": "s-carry-blue", "title": "旧蓝点新报错", "unread": true, "createdAt": 10, "updatedAt": 60],
            ["id": "s-inflight-read", "title": "在途已读撞上新完成", "unread": true, "createdAt": 10, "updatedAt": 20],
        ]
        server.entriesBySession = [
            "s-carry-blue": [
                ["id": "u2", "kind": "user", "createdAt": 25, "content": [["type": "text", "text": "run2"]]],
                ["id": "a2", "kind": "assistant", "status": "error", "stopReason": "error", "errorMessage": "boom", "createdAt": 60, "content": []],
            ],
            "s-inflight-read": [
                ["id": "u-new", "kind": "user", "createdAt": 80, "content": [["type": "text", "text": "new"]]],
                ["id": "a-new", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 85, "content": [["type": "text", "text": "reply"]]],
            ],
        ]
        server.dropActiveWebSockets()
        try await waitUntil("s-carry-blue upgraded from .unread to .error after reconnect") {
            client.state == .connected && client.session(id: "s-carry-blue")?.unread == .error
        }

        // Part B: Hold `setMeta(unread: false)` for `s-inflight-read` (`t = 20`); while in flight after leaving `ThreadView`,
        // a newer turn (`t = 85, unread: true`) broadcasts `session:meta-updated`, and THEN the old `setMeta(unread: false)` completes!
        server.holdSetMetaReplies = true
        client.beginViewing(sessionId: "s-inflight-read")
        client.endViewing(sessionId: "s-inflight-read")
        try await waitUntil("read setMeta held in flight") {
            server.heldSetMetaCount == 1
        }

        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": "s-inflight-read", "title": "在途已读撞上新完成", "unread": true, "createdAt": 10, "updatedAt": 85,
        ])
        server.releaseHeldSetMetaReplies()

        try await waitUntil("s-inflight-read repaired back to .unread on client and server") {
            client.session(id: "s-inflight-read")?.unread == .unread
                && server.sessions.first(where: { $0["id"]?.stringValue == "s-inflight-read" })?["unread"]?.boolValue == true
        }
    }

    func testViewingAndLeavingWhileUnreadSetMetaInFlightWithNewerServerTimestampStaysRead() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-hold-unread", "title": "挂起未读写入期间查看退出", "unread": false, "createdAt": 100, "updatedAt": 100],
        ]
        server.entriesBySession = [
            "s-hold-unread": [
                ["id": "u1", "kind": "user", "createdAt": 105, "content": [["type": "text", "text": "hi"]]],
                ["id": "a1", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 115, "content": [["type": "text", "text": "done"]]],
            ],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.session(id: "s-hold-unread") != nil
        }

        // Server DB has `updatedAt: 130` (even slightly ahead of `idle`'s `120` due to server clock), while client cached `100`.
        server.sessions = [
            ["id": "s-hold-unread", "title": "挂起未读写入期间查看退出", "unread": false, "createdAt": 100, "updatedAt": 130],
        ]
        server.holdSetMetaReplies = true

        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-hold-unread", "runId": "r-hu", "status": "running", "updatedAt": 110,
        ])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-hold-unread",
            "runId": "r-hu",
            "event": [
                "type": "assistant-end",
                "entry": ["id": "a1", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 115],
            ],
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-hold-unread", "runId": "r-hu", "status": "idle", "updatedAt": 120,
        ])
        try await waitUntil("mark-unread setMeta held on server") {
            server.heldSetMetaCount == 1
        }

        // User views the completed conversation and navigates back to HomeView while `setMeta(unread: true)` is still in flight!
        client.beginViewing(sessionId: "s-hold-unread")
        client.endViewing(sessionId: "s-hold-unread")
        XCTAssertEqual(client.session(id: "s-hold-unread")?.unread, .read)

        // Release `setMeta(unread: true)` (which echoes `session:meta-updated` with `unread: true, updatedAt: 130`).
        server.releaseHeldSetMetaReplies()

        try await waitUntil("follow-up mark-read setMeta persisted unread: false on server") {
            server.sessions.first(where: { $0["id"]?.stringValue == "s-hold-unread" })?["unread"]?.boolValue == false
        }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(client.session(id: "s-hold-unread")?.unread, .read)
    }

    func testDelayedUnreadEchoAfterViewingLiveCompletionAndStaleInFlightErrorEchoAcrossNewRun() async throws {
        let server = try MockUnreadDesktopServer()
        defer { server.stop() }

        server.sessions = [
            ["id": "s-viewed-echo", "title": "查看期间完成后延迟广播", "unread": false, "createdAt": 10, "updatedAt": 10],
            ["id": "s-stale-err-echo", "title": "旧错误在途跨新运行", "unread": false, "createdAt": 10, "updatedAt": 10],
        ]
        server.entriesBySession = [
            "s-viewed-echo": [
                ["id": "u1", "kind": "user", "createdAt": 12, "content": [["type": "text", "text": "hi"]]],
                ["id": "a1", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 18, "content": [["type": "text", "text": "done"]]],
            ],
        ]

        let client = DesktopClient(connection: DesktopConnection(
            name: "Local",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop
        ))
        defer { client.stop() }

        var completedRunIds: [String] = []
        _ = client.addListener { event in
            if event.kind == DesktopEvent.turnCompleted,
               let rid = event.payload["runId"]?.stringValue {
                completedRunIds.append(rid)
            }
        }

        client.start()
        try await waitUntil("initial sync done") {
            client.hasSynced && client.sessions.count == 2
        }

        // Part A: `s-viewed-echo` completes while user IS viewing it, then user leaves `ThreadView`,
        // and another client / Desktop broadcasts a delayed `session:meta-updated(unread: true)` for that same turn!
        client.beginViewing(sessionId: "s-viewed-echo")
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-viewed-echo", "runId": "r-ve", "status": "running", "updatedAt": 12,
        ])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-viewed-echo",
            "runId": "r-ve",
            "event": ["type": "assistant-end", "entry": ["id": "a1", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 18]],
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-viewed-echo", "runId": "r-ve", "status": "idle", "updatedAt": 20,
        ])
        client.endViewing(sessionId: "s-viewed-echo")

        // Delayed `unread: true` broadcast for the already-viewed turn (`updatedAt: 22`, no new entry after `18`):
        server.sessions = [
            ["id": "s-viewed-echo", "title": "查看期间完成后延迟广播", "unread": true, "createdAt": 10, "updatedAt": 22],
            ["id": "s-stale-err-echo", "title": "旧错误在途跨新运行", "unread": false, "createdAt": 10, "updatedAt": 10],
        ]
        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": "s-viewed-echo", "title": "查看期间完成后延迟广播", "unread": true, "createdAt": 10, "updatedAt": 22,
        ])
        try await waitUntil("delayed echo for viewed turn cleared back to false on server") {
            server.sessions.first(where: { $0["id"]?.stringValue == "s-viewed-echo" })?["unread"]?.boolValue == false
        }
        XCTAssertEqual(client.session(id: "s-viewed-echo")?.unread, .read)

        // Part B: Turn 1 on `s-stale-err-echo` errors and holds `setMeta(unread: "error")`;
        // user opens `s-stale-err-echo`, starts Turn 2 (`r-2`), leaves, old `setMeta(unread: "error")` echoes,
        // and Turn 2 finishes cleanly -> must become `.unread` (blue dot) and emit `turnCompleted` for `r-2`!
        server.holdSetMetaReplies = true
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-stale-err-echo", "runId": "r-1-err", "status": "running", "updatedAt": 30,
        ])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-stale-err-echo",
            "runId": "r-1-err",
            "event": ["type": "error", "message": "turn 1 failed"],
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-stale-err-echo", "runId": "r-1-err", "status": "idle", "updatedAt": 32,
        ])
        try await waitUntil("turn 1 error setMeta held") {
            server.heldSetMetaCount == 1
        }

        client.beginViewing(sessionId: "s-stale-err-echo")
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-stale-err-echo", "runId": "r-2-ok", "status": "running", "updatedAt": 40,
        ])
        client.endViewing(sessionId: "s-stale-err-echo")

        // Now Turn 1's held `setMeta(unread: "error")` completes and echoes `session:meta-updated(unread: "error")` during Turn 2!
        server.releaseHeldSetMetaReplies()
        try await Task.sleep(for: .milliseconds(60))

        // Turn 2 finishes cleanly:
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-stale-err-echo",
            "runId": "r-2-ok",
            "event": ["type": "assistant-end", "entry": ["id": "a2", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 50]],
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-stale-err-echo", "runId": "r-2-ok", "status": "idle", "updatedAt": 52,
        ])

        XCTAssertEqual(client.session(id: "s-stale-err-echo")?.unread, .unread)
        XCTAssertTrue(completedRunIds.contains("r-2-ok"))

        // Part C: User opens `s-stale-err-echo` AFTER Turn 2 finished (`flushReadSync` succeeds), leaves `ThreadView`,
        // and a slower second client broadcasts `unread: true` for that same Turn 2 (`entries` still ends at `t = 50`):
        server.entriesBySession["s-stale-err-echo"] = [
            ["id": "u2", "kind": "user", "createdAt": 40, "content": [["type": "text", "text": "t2"]]],
            ["id": "a2", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 50, "content": [["type": "text", "text": "ok"]]],
        ]
        client.beginViewing(sessionId: "s-stale-err-echo")
        try await waitUntil("s-stale-err-echo read synced") {
            server.sessions.first(where: { $0["id"]?.stringValue == "s-stale-err-echo" })?["unread"]?.boolValue == false
        }
        client.endViewing(sessionId: "s-stale-err-echo")
        // Wait for `flushReadSync`'s `rpc_result` to clear `readSyncIntents` on the client!
        try await Task.sleep(for: .milliseconds(60))

        server.sessions = [
            ["id": "s-viewed-echo", "title": "查看期间完成后延迟广播", "unread": false, "createdAt": 10, "updatedAt": 22],
            ["id": "s-stale-err-echo", "title": "旧错误在途跨新运行", "unread": true, "createdAt": 10, "updatedAt": 55],
        ]
        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": "s-stale-err-echo", "title": "旧错误在途跨新运行", "unread": true, "createdAt": 10, "updatedAt": 55,
        ])
        try await waitUntil("post-view delayed echo cleared back to false") {
            server.sessions.first(where: { $0["id"]?.stringValue == "s-stale-err-echo" })?["unread"]?.boolValue == false
        }
        XCTAssertEqual(client.session(id: "s-stale-err-echo")?.unread, .read)

        // Part D: Ambiguous `idle` when SQLite has flushed an auto-compaction entry (`t = 70`), while the assistant reply (`t = 75`)
        // flushes later via `session:entries-updated`:
        server.entriesBySession["s-viewed-echo"] = [
            ["id": "c-auto", "kind": "compaction", "createdAt": 70, "summary": "auto compacted"],
        ]
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-viewed-echo", "runId": "r-ac-late", "status": "running", "updatedAt": 65,
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-viewed-echo", "runId": "r-ac-late", "status": "idle", "updatedAt": 76,
        ])
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(client.session(id: "s-viewed-echo")?.unread, .read)

        server.entriesBySession["s-viewed-echo"] = [
            ["id": "c-auto", "kind": "compaction", "createdAt": 70, "summary": "auto compacted"],
            ["id": "a-after-c", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 75, "content": [["type": "text", "text": "done"]]],
        ]
        try sendEvent(client, kind: "session:entries-updated", data: [
            "sessionId": "s-viewed-echo",
        ])
        try await waitUntil("s-viewed-echo marked unread once assistant entry flushed after compaction") {
            client.session(id: "s-viewed-echo")?.unread == .unread
                && completedRunIds.contains("r-ac-late")
        }

        // Part E1: Peer manual "Mark as Unread" (`keepsUpdatedAt: true` -> `updatedAt` unchanged at `55`) on `s-stale-err-echo`
        // must NOT be auto-reverted by `viewedWatermarks`!
        server.sessions = [
            ["id": "s-viewed-echo", "title": "查看期间完成后延迟广播", "unread": true, "createdAt": 10, "updatedAt": 76],
            ["id": "s-stale-err-echo", "title": "旧错误在途跨新运行", "unread": true, "createdAt": 10, "updatedAt": 55],
        ]
        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": "s-stale-err-echo", "title": "旧错误在途跨新运行", "unread": true, "createdAt": 10, "updatedAt": 55,
        ])
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(client.session(id: "s-stale-err-echo")?.unread, .unread)

        // Part E2: Ambiguous `idle` resolved via `session:get` while viewed (`canMarkUnread == false`) still records
        // `viewedWatermarks`, suppressing a delayed peer auto-completion echo (`updatedAt: 92 > 90`) after `endViewing`!
        client.beginViewing(sessionId: "s-viewed-echo")
        server.entriesBySession["s-viewed-echo"] = [
            ["id": "u-e2", "kind": "user", "createdAt": 85, "content": [["type": "text", "text": "e2"]]],
            ["id": "a-e2", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 90, "content": [["type": "text", "text": "e2 done"]]],
        ]
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-viewed-echo", "runId": "r-amb-viewed", "status": "running", "updatedAt": 85,
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": "s-viewed-echo", "runId": "r-amb-viewed", "status": "idle", "updatedAt": 90,
        ])
        try await waitUntil("r-amb-viewed verified via session:get while viewed") {
            completedRunIds.contains("r-amb-viewed")
        }
        client.endViewing(sessionId: "s-viewed-echo")

        server.sessions = [
            ["id": "s-viewed-echo", "title": "查看期间完成后延迟广播", "unread": true, "createdAt": 10, "updatedAt": 92],
            ["id": "s-stale-err-echo", "title": "旧错误在途跨新运行", "unread": true, "createdAt": 10, "updatedAt": 55],
        ]
        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": "s-viewed-echo", "title": "查看期间完成后延迟广播", "unread": true, "createdAt": 10, "updatedAt": 92,
        ])
        try await waitUntil("delayed auto-echo after ambiguous-idle view cleared back to false") {
            server.sessions.first(where: { $0["id"]?.stringValue == "s-viewed-echo" })?["unread"]?.boolValue == false
        }
        XCTAssertEqual(client.session(id: "s-viewed-echo")?.unread, .read)
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

// Mock desktop HTTP + WebSocket server that records `session:setMeta` writes and broadcasts `session:meta-updated`.
private final class MockUnreadDesktopServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.mock-unread-desktop")
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
    var entriesBySession: [String: [JSONValue]] {
        get { lock.withLock { _entriesBySession } }
        set { lock.withLock { _entriesBySession = newValue } }
    }
    var setMetaCalls: [JSONValue] {
        lock.withLock { _setMetaCalls }
    }
    var holdSetMetaReplies: Bool {
        get { lock.withLock { _holdSetMetaReplies } }
        set { lock.withLock { _holdSetMetaReplies = newValue } }
    }
    var heldSetMetaCount: Int {
        lock.withLock { _heldActions.count }
    }
    var holdSessionGetReplies: Bool {
        get { lock.withLock { _holdSessionGetReplies } }
        set { lock.withLock { _holdSessionGetReplies = newValue } }
    }
    var heldSessionGetCount: Int {
        lock.withLock { _heldSessionGetActions.count }
    }
    var holdListSessionsReplies: Bool {
        get { lock.withLock { _holdListSessionsReplies } }
        set { lock.withLock { _holdListSessionsReplies = newValue } }
    }
    var heldListSessionsCount: Int {
        lock.withLock { _heldListSessionsActions.count }
    }
    var dropOnSessionGetRemaining: Int {
        get { lock.withLock { _dropOnSessionGetRemaining } }
        set { lock.withLock { _dropOnSessionGetRemaining = newValue } }
    }
    var failSessionGetRemaining: Int {
        get { lock.withLock { _failSessionGetRemaining } }
        set { lock.withLock { _failSessionGetRemaining = newValue } }
    }
    var failSetMetaRemaining: Int {
        get { lock.withLock { _failSetMetaRemaining } }
        set { lock.withLock { _failSetMetaRemaining = newValue } }
    }

    private var _sessions: [JSONValue] = []
    private var _activeRuns: [JSONValue] = []
    private var _entriesBySession: [String: [JSONValue]] = [:]
    private var _setMetaCalls: [JSONValue] = []
    private var _holdSetMetaReplies = false
    private var _heldActions: [() -> Void] = []
    private var _holdSessionGetReplies = false
    private var _heldSessionGetActions: [() -> Void] = []
    private var _holdListSessionsReplies = false
    private var _heldListSessionsActions: [() -> Void] = []
    private var _dropOnSessionGetRemaining = 0
    private var _failSessionGetRemaining = 0
    private var _failSetMetaRemaining = 0

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

    func releaseHeldSetMetaReplies() {
        let actions = lock.withLock { () -> [() -> Void] in
            _holdSetMetaReplies = false
            let pending = _heldActions
            _heldActions.removeAll()
            return pending
        }
        queue.async {
            for action in actions {
                action()
            }
        }
    }

    func releaseHeldSessionGetReplies() {
        let actions = lock.withLock { () -> [() -> Void] in
            _holdSessionGetReplies = false
            let pending = _heldSessionGetActions
            _heldSessionGetActions.removeAll()
            return pending
        }
        queue.async {
            for action in actions {
                action()
            }
        }
    }

    func releaseHeldListSessionsReplies() {
        let actions = lock.withLock { () -> [() -> Void] in
            _holdListSessionsReplies = false
            let pending = _heldListSessionsActions
            _heldListSessionsActions.removeAll()
            return pending
        }
        queue.async {
            for action in actions {
                action()
            }
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
                if method == "session:setMeta", let patch = rpc["args"]?.arrayValue?.first {
                    let completeSetMeta = { [weak self] in
                        guard let self else { return }
                        let shouldFailMeta = self.lock.withLock { () -> Bool in
                            if self._failSetMetaRemaining > 0 {
                                self._failSetMetaRemaining -= 1
                                return true
                            }
                            return false
                        }
                        if shouldFailMeta {
                            let errReply: JSONValue = ["type": "rpc_error", "id": .string(id), "error": ["message": "transient setMeta failure"]]
                            if let text = try? errReply.jsonString() {
                                self.sendWSText(conn: conn, text: text)
                            }
                            return
                        }
                        let updatedItem = self.lock.withLock { () -> JSONValue in
                            self._setMetaCalls.append(patch)
                            let sid = patch["id"]?.stringValue ?? ""
                            if let idx = self._sessions.firstIndex(where: { $0["id"]?.stringValue == sid }),
                               var existing = self._sessions[idx].objectValue,
                               let patchObj = patch.objectValue {
                                for (k, v) in patchObj {
                                    existing[k] = v
                                }
                                let merged = JSONValue.object(existing)
                                self._sessions[idx] = merged
                                return merged
                            }
                            return patch
                        }
                        let metaEvent: JSONValue = [
                            "type": "event",
                            "event": [
                                "kind": "session:meta-updated",
                                "data": updatedItem,
                            ],
                        ]
                        if let eventText = try? metaEvent.jsonString() {
                            let conns = self.lock.withLock { self.wsConnections }
                            for activeConn in conns {
                                self.sendWSText(conn: activeConn, text: eventText)
                            }
                        }
                        let reply: JSONValue = ["type": "rpc_result", "id": .string(id), "result": .null]
                        if let text = try? reply.jsonString() {
                            self.sendWSText(conn: conn, text: text)
                        }
                    }
                    let shouldHold = lock.withLock { () -> Bool in
                        if _holdSetMetaReplies {
                            _heldActions.append(completeSetMeta)
                            return true
                        }
                        return false
                    }
                    if !shouldHold {
                        completeSetMeta()
                    }
                    continue
                }

                let result: JSONValue
                switch method {
                case "session:getActiveRuns":
                    result = .array(activeRuns)
                case "session:listSessions":
                    let sendListReply = { [weak self] in
                        guard let self else { return }
                        let reply: JSONValue = ["type": "rpc_result", "id": .string(id), "result": .array(self.sessions)]
                        if let text = try? reply.jsonString() {
                            self.sendWSText(conn: conn, text: text)
                        }
                    }
                    let shouldHoldList = lock.withLock { () -> Bool in
                        if _holdListSessionsReplies {
                            _heldListSessionsActions.append(sendListReply)
                            return true
                        }
                        return false
                    }
                    if !shouldHoldList {
                        sendListReply()
                    }
                    continue
                case "session:get":
                    let shouldDrop = lock.withLock { () -> Bool in
                        if _dropOnSessionGetRemaining > 0 {
                            _dropOnSessionGetRemaining -= 1
                            return true
                        }
                        return false
                    }
                    if shouldDrop {
                        dropActiveWebSockets()
                        return
                    }
                    let shouldFail = lock.withLock { () -> Bool in
                        if _failSessionGetRemaining > 0 {
                            _failSessionGetRemaining -= 1
                            return true
                        }
                        return false
                    }
                    if shouldFail {
                        let errReply: JSONValue = ["type": "rpc_error", "id": .string(id), "error": ["message": "transient busy"]]
                        if let text = try? errReply.jsonString() {
                            sendWSText(conn: conn, text: text)
                        }
                        continue
                    }
                    let sid = rpc["args"]?.arrayValue?.first?.stringValue ?? ""
                    let sendGetReply = { [weak self] in
                        guard let self else { return }
                        let getResult: JSONValue
                        if let entries = self.entriesBySession[sid] {
                            getResult = ["id": .string(sid), "entries": .array(entries)]
                        } else {
                            getResult = .null
                        }
                        let reply: JSONValue = ["type": "rpc_result", "id": .string(id), "result": getResult]
                        if let text = try? reply.jsonString() {
                            self.sendWSText(conn: conn, text: text)
                        }
                    }
                    let shouldHoldGet = lock.withLock { () -> Bool in
                        if _holdSessionGetReplies {
                            _heldSessionGetActions.append(sendGetReply)
                            return true
                        }
                        return false
                    }
                    if !shouldHoldGet {
                        sendGetReply()
                    }
                    continue
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
