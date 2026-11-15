import Foundation
import UserNotifications
import XCTest
@testable import CodingProfessionalAgent

@MainActor
final class TurnNotificationCoordinatorTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "TurnNotifTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if !suiteName.isEmpty {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
    }

    private func makeConnection(name: String, isEnabled: Bool = true) -> DesktopConnection {
        DesktopConnection(
            name: name,
            host: "invalid host",
            port: 18080,
            icon: .laptop,
            isEnabled: isEnabled
        )
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

    private func runCompleteTurn(_ client: DesktopClient, sessionId: String, runId: String, title: String) throws {
        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": .string(sessionId),
            "title": .string(title),
            "createdAt": 100,
            "updatedAt": 100,
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": .string(sessionId),
            "runId": .string(runId),
            "status": "running",
            "updatedAt": 101,
        ])
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": .string(sessionId),
            "runId": .string(runId),
            "event": [
                "type": "assistant-end",
                "entry": [
                    "id": .string("a-\(runId)"),
                    "kind": "assistant",
                    "status": "done",
                    "stopReason": "stop",
                    "createdAt": 102,
                ],
            ],
        ])
        try sendEvent(client, kind: "session:run-status", data: [
            "sessionId": .string(sessionId),
            "runId": .string(runId),
            "status": "idle",
            "updatedAt": 103,
        ])
    }

    func testForegroundSuppressesNotificationAndReturningActiveClearsBadge() async throws {
        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let conn = makeConnection(name: "Studio")
        store.add(conn, password: "")
        let client = try XCTUnwrap(store.client(for: conn.id))
        let router = Router()
        let timeline = SharedTimeline()
        let notif = MockUserNotificationManager(timeline: timeline)
        let bg = MockContinuedTurnTaskManager(timeline: timeline)

        let coordinator = TurnNotificationCoordinator(
            store: store,
            router: router,
            defaults: defaults,
            notificationManager: notif,
            continuedTaskManager: bg,
            initialActive: true
        )
        _ = coordinator

        // Active foreground: must suppress notification and keep badge at 0.
        XCTAssertEqual(notif.isForegroundSuppressed?(), true)
        try runCompleteTurn(client, sessionId: "s1", runId: "r1", title: "前台任务")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(notif.added.isEmpty)

        // Inactive/background: two completed turns increment badge 1 -> 2.
        coordinator.setAppActive(false)
        XCTAssertEqual(notif.isForegroundSuppressed?(), false)
        try runCompleteTurn(client, sessionId: "s2", runId: "r2", title: "后台任务一")
        try runCompleteTurn(client, sessionId: "s3", runId: "r3", title: "后台任务二")
        try await waitUntil("two notifications delivered") { notif.added.count == 2 }
        XCTAssertEqual(notif.added.map(\.badgeCount), [1, 2])
        XCTAssertEqual(notif.added.map(\.body), ["后台任务一 任务已经完成", "后台任务二 任务已经完成"])

        // Returning to foreground clears badge and resets counter for subsequent background runs.
        let clearsBefore = notif.clearCount
        coordinator.setAppActive(true)
        try await waitUntil("badge cleared on active") { notif.clearCount > clearsBefore }

        coordinator.setAppActive(false)
        try runCompleteTurn(client, sessionId: "s4", runId: "r4", title: "")
        try await waitUntil("third notification delivered") { notif.added.count == 3 }
        XCTAssertEqual(notif.added.last?.badgeCount, 1)
        XCTAssertEqual(notif.added.last?.body, "任务已经完成")
    }

    func testTruncatesGraphemeClusterTitleAndUsesHostDisplayNameWhenMultipleClientsEnabled() async throws {
        // Review Focus #1: 41 multi-scalar emoji grapheme clusters must truncate cleanly at 40 Characters.
        let emojiUnit = "👨‍👩‍👧‍👦"
        let fortyEmojis = String(repeating: emojiUnit, count: 40)
        let fortyOneEmojis = fortyEmojis + "🇨🇳"
        let formatted = TurnNotificationCoordinator.formatNotificationBody(sessionTitle: "  \(fortyOneEmojis)  ")
        XCTAssertEqual(formatted, "\(fortyEmojis)... 任务已经完成")
        XCTAssertFalse(formatted.contains("\u{FFFD}"))
        XCTAssertEqual(TurnNotificationCoordinator.formatNotificationBody(sessionTitle: "   "), "任务已经完成")

        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let connA = makeConnection(name: "Mac-Pro")
        let connB = makeConnection(name: "Mini-Server")
        store.add(connA, password: "")
        store.add(connB, password: "")
        let clientA = try XCTUnwrap(store.client(for: connA.id))
        let clientB = try XCTUnwrap(store.client(for: connB.id))

        let router = Router()
        let timeline = SharedTimeline()
        let notif = MockUserNotificationManager(timeline: timeline)
        let bg = MockContinuedTurnTaskManager(timeline: timeline)
        let coordinator = TurnNotificationCoordinator(
            store: store,
            router: router,
            defaults: defaults,
            notificationManager: notif,
            continuedTaskManager: bg,
            initialActive: false
        )
        _ = coordinator

        // With 2 enabled connections, notification title shows the host displayName.
        try runCompleteTurn(clientB, sessionId: "sb", runId: "rb", title: "构建镜像")
        try await waitUntil("multi-host notification") { notif.added.count == 1 }
        XCTAssertEqual(notif.added[0].title, "Mini-Server")

        // Disable second connection -> sole enabled connection uses "CPA".
        store.setEnabled(connB.id, false)
        try runCompleteTurn(clientA, sessionId: "sa", runId: "ra", title: "修复测试")
        try await waitUntil("single-host notification") { notif.added.count == 2 }
        XCTAssertEqual(notif.added[1].title, "CPA")
    }

    func testNotificationEnqueueStrictlyPrecedesBackgroundTaskFinish() async throws {
        // Review Focus #4: notification enqueue MUST complete before finishing continued task & grace task.
        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let conn = makeConnection(name: "Studio")
        store.add(conn, password: "")
        let client = try XCTUnwrap(store.client(for: conn.id))
        let router = Router()
        let timeline = SharedTimeline()
        let notif = MockUserNotificationManager(timeline: timeline)
        notif.artificialAddDelayMs = 60
        let bg = MockContinuedTurnTaskManager(timeline: timeline)

        let coordinator = TurnNotificationCoordinator(
            store: store,
            router: router,
            defaults: defaults,
            notificationManager: notif,
            continuedTaskManager: bg,
            initialActive: true
        )

        // Start a run while active -> starts continued processing task.
        try sendEvent(client, kind: "session:meta-updated", data: ["id": "s-ord", "title": "关键构建", "createdAt": 1, "updatedAt": 1])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "s-ord", "runId": "r-ord", "status": "running", "updatedAt": 2])
        XCTAssertEqual(bg.startCount, 1)
        XCTAssertEqual(bg.lastTitle, "关键构建")

        // App leaves foreground -> starts grace background task.
        coordinator.setAppActive(false)
        XCTAssertEqual(bg.graceBeginCount, 1)

        // Complete the sole run in background.
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-ord", "runId": "r-ord",
            "event": ["type": "assistant-end", "entry": ["id": "a1", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 3]],
        ])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "s-ord", "runId": "r-ord", "status": "idle", "updatedAt": 4])

        try await waitUntil("background task finished after notification") {
            bg.finishResults.count == 1
        }
        let events = timeline.events
        let addedIdx = try XCTUnwrap(events.firstIndex(of: "notification:added"))
        let finishedIdx = try XCTUnwrap(events.firstIndex(of: "bgTask:finished:true"))
        let graceEndIdx = try XCTUnwrap(events.firstIndex(of: "grace:ended"))
        XCTAssertLessThan(addedIdx, finishedIdx)
        XCTAssertLessThan(addedIdx, graceEndIdx)
    }

    func testTapNotificationNavigatesToThreadAndIgnoresDisabledConnection() async throws {
        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let conn = makeConnection(name: "Studio")
        store.add(conn, password: "")
        let router = Router()
        router.push(.newThread(NewThreadContext()))

        let timeline = SharedTimeline()
        let notif = MockUserNotificationManager(timeline: timeline)
        let bg = MockContinuedTurnTaskManager(timeline: timeline)
        let coordinator = TurnNotificationCoordinator(
            store: store,
            router: router,
            defaults: defaults,
            notificationManager: notif,
            continuedTaskManager: bg,
            initialActive: false
        )
        _ = coordinator

        let clearsBefore = notif.clearCount
        notif.onOpenSession?(conn.id, "sess-42")
        XCTAssertEqual(router.path, [.thread(connectionId: conn.id, sessionId: "sess-42")])
        XCTAssertEqual(router.externalNavigationRevision, 1)
        try await waitUntil("badge cleared on tap") { notif.clearCount > clearsBefore }

        // Disabling connection prevents stale notification tap from navigating to a disabled host.
        store.setEnabled(conn.id, false)
        router.path = []
        notif.onOpenSession?(conn.id, "sess-99")
        XCTAssertTrue(router.path.isEmpty)
    }

    func testDisablingConnectionOrPreferenceEndsContinuedTaskWithoutFalseNotification() async throws {
        // Review Focus #5
        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let conn = makeConnection(name: "Studio")
        store.add(conn, password: "")
        let client = try XCTUnwrap(store.client(for: conn.id))
        let router = Router()
        let timeline = SharedTimeline()
        let notif = MockUserNotificationManager(timeline: timeline)
        let bg = MockContinuedTurnTaskManager(timeline: timeline)

        let coordinator = TurnNotificationCoordinator(
            store: store,
            router: router,
            defaults: defaults,
            notificationManager: notif,
            continuedTaskManager: bg,
            initialActive: true
        )

        try sendEvent(client, kind: "session:meta-updated", data: ["id": "s-1", "title": "任务A", "createdAt": 1, "updatedAt": 1])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "s-1", "runId": "r-1", "status": "running", "updatedAt": 2])
        XCTAssertTrue(bg.isActive)

        // Turning off preference stops continued task immediately and suppresses subsequent completion notifications.
        coordinator.setNotificationsEnabled(false)
        XCTAssertFalse(bg.isActive)
        coordinator.setAppActive(false)
        try sendEvent(client, kind: "session:stream-event", data: [
            "sessionId": "s-1", "runId": "r-1",
            "event": ["type": "assistant-end", "entry": ["id": "a1", "kind": "assistant", "status": "done", "stopReason": "stop", "createdAt": 3]],
        ])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "s-1", "runId": "r-1", "status": "idle", "updatedAt": 4])
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(notif.added.isEmpty)

        // Re-enable preference, start another run, then disable connection mid-run -> continued task stops cleanly.
        coordinator.setAppActive(true)
        coordinator.setNotificationsEnabled(true)
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "s-1", "runId": "r-2", "status": "running", "updatedAt": 5])
        XCTAssertTrue(bg.isActive)
        store.setEnabled(conn.id, false)
        XCTAssertFalse(bg.isActive)
        XCTAssertTrue(notif.added.isEmpty)
    }

    func testExpirationHandlerCleansUpWithoutNotification() async throws {
        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let conn = makeConnection(name: "Studio")
        store.add(conn, password: "")
        let client = try XCTUnwrap(store.client(for: conn.id))
        let router = Router()
        let timeline = SharedTimeline()
        let notif = MockUserNotificationManager(timeline: timeline)
        let bg = MockContinuedTurnTaskManager(timeline: timeline)

        let coordinator = TurnNotificationCoordinator(
            store: store,
            router: router,
            defaults: defaults,
            notificationManager: notif,
            continuedTaskManager: bg,
            initialActive: true
        )

        try sendEvent(client, kind: "session:meta-updated", data: ["id": "s-exp", "title": "长任务", "createdAt": 1, "updatedAt": 1])
        try sendEvent(client, kind: "session:run-status", data: ["sessionId": "s-exp", "runId": "r-exp", "status": "running", "updatedAt": 2])
        coordinator.setAppActive(false)
        XCTAssertTrue(bg.isActive)
        XCTAssertTrue(bg.isGraceActive)

        bg.onExpiration?()
        XCTAssertEqual(bg.finishResults.last, false)
        XCTAssertFalse(bg.isActive)
        XCTAssertFalse(bg.isGraceActive)
        XCTAssertTrue(notif.added.isEmpty)
    }

    func testReturningActiveOrDisablingDuringPendingAuthOrAddPreventsStaleDeliveryAndBadge() async throws {
        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let conn = makeConnection(name: "Studio")
        store.add(conn, password: "")
        let client = try XCTUnwrap(store.client(for: conn.id))
        let router = Router()
        let timeline = SharedTimeline()
        let notif = MockUserNotificationManager(timeline: timeline)
        let bg = MockContinuedTurnTaskManager(timeline: timeline)

        let coordinator = TurnNotificationCoordinator(
            store: store,
            router: router,
            defaults: defaults,
            notificationManager: notif,
            continuedTaskManager: bg,
            initialActive: false
        )

        // 1. User returns to foreground while requestAuthorizationIfNeeded is awaiting -> must NOT enqueue notification.
        notif.artificialAuthDelayMs = 80
        try runCompleteTurn(client, sessionId: "s-race-1", runId: "r-race-1", title: "竞态一")
        try await Task.sleep(for: .milliseconds(20))
        coordinator.setAppActive(true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(notif.added.isEmpty, "Notification must be cancelled if app became active during auth")

        // 2. Returning active while addNotification is awaiting -> clear must win last so badge stays 0.
        notif.artificialAuthDelayMs = 0
        notif.artificialAddDelayMs = 80
        coordinator.setAppActive(false)
        try runCompleteTurn(client, sessionId: "s-race-2", runId: "r-race-2", title: "竞态二")
        try await Task.sleep(for: .milliseconds(20))
        coordinator.setAppActive(true)
        try await Task.sleep(for: .milliseconds(110))
        XCTAssertEqual(timeline.events.last, "notification:cleared", "Returning active during add must leave badge cleared last")

        // Next background notification starts fresh at badge 1 (not 2 or 3).
        notif.artificialAddDelayMs = 0
        coordinator.setAppActive(false)
        try runCompleteTurn(client, sessionId: "s-race-3", runId: "r-race-3", title: "竞态三")
        try await waitUntil("fresh badge 1 delivered") { notif.added.last?.identifier.contains("r-race-3") == true }
        XCTAssertEqual(notif.added.last?.badgeCount, 1)
    }

    func testOptimisticSendStartsContinuedTaskBeforeFirstServerRunStatusArrives() async throws {
        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let conn = makeConnection(name: "Studio")
        store.add(conn, password: "")
        let client = try XCTUnwrap(store.client(for: conn.id))
        let router = Router()
        let timeline = SharedTimeline()
        let notif = MockUserNotificationManager(timeline: timeline)
        let bg = MockContinuedTurnTaskManager(timeline: timeline)

        let coordinator = TurnNotificationCoordinator(
            store: store,
            router: router,
            defaults: defaults,
            notificationManager: notif,
            continuedTaskManager: bg,
            initialActive: true
        )

        try sendEvent(client, kind: "session:meta-updated", data: [
            "id": "s-imm", "title": "发送即锁屏", "createdAt": 1, "updatedAt": 1,
        ])
        // Trigger real send path (resumeSession -> callDelegateRun): optimistic run is inserted synchronously
        // while still foregrounded, before any server run-status arrives.
        try? await client.resumeSession(id: "s-imm")
        coordinator.setAppActive(false)
        XCTAssertGreaterThanOrEqual(bg.startCount, 1, "Expected continued task to start synchronously during foreground send")
    }

    func testNotificationDelegateBridgeDeliversCompletionHandlersOnMainThread() async throws {
        @MainActor
        final class CallbackResult {
            var didReceiveCompleted = false
            var didReceiveCompletionOnMainThread = false
            var dismissedCompleted = false
            var dismissedCompletionOnMainThread = false
            var optionsWhenSuppressed: UNNotificationPresentationOptions?
            var willPresentSuppressedOnMainThread = false
            var optionsWhenVisible: UNNotificationPresentationOptions?
            var willPresentVisibleOnMainThread = false
        }

        let bridge = NotificationDelegateBridge()
        XCTAssertTrue(bridge.responds(to: #selector(
            UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:)
        )))
        XCTAssertTrue(bridge.responds(to: #selector(
            UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)
        )))

        let result = CallbackResult()
        let expectedConnectionId = UUID()
        var opened: [(UUID, String)] = []
        var openIsMainThread = false
        bridge.onOpenSession = { connId, sessId in
            openIsMainThread = Thread.isMainThread
            opened.append((connId, sessId))
        }

        // 1. Background-queue didReceive callback (simulating SpringBoard/UNUserNotificationCenter background delivery)
        // must invoke both onOpenSession and completionHandler on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            bridge.handleDidReceive(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                userInfo: [
                    "connectionId": expectedConnectionId.uuidString,
                    "sessionId": "sess-bg-tap",
                ]
            ) {
                let onMain = Thread.isMainThread
                MainActor.assumeIsolated {
                    result.didReceiveCompletionOnMainThread = onMain
                    result.didReceiveCompleted = true
                }
            }
        }
        try await waitUntil("background didReceive completion") { result.didReceiveCompleted }
        XCTAssertTrue(result.didReceiveCompletionOnMainThread)
        XCTAssertTrue(openIsMainThread)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.0, expectedConnectionId)
        XCTAssertEqual(opened.first?.1, "sess-bg-tap")

        // 2. Non-default action or malformed payload must still invoke completionHandler on main thread without opening.
        DispatchQueue.global(qos: .userInitiated).async {
            bridge.handleDidReceive(
                actionIdentifier: UNNotificationDismissActionIdentifier,
                userInfo: [
                    "connectionId": expectedConnectionId.uuidString,
                    "sessionId": "sess-ignored",
                ]
            ) {
                let onMain = Thread.isMainThread
                MainActor.assumeIsolated {
                    result.dismissedCompletionOnMainThread = onMain
                    result.dismissedCompleted = true
                }
            }
        }
        try await waitUntil("dismiss didReceive completion") { result.dismissedCompleted }
        XCTAssertTrue(result.dismissedCompletionOnMainThread)
        XCTAssertEqual(opened.count, 1)

        // 3. Background-queue willPresent callback must invoke completionHandler on the main thread.
        var suppressed = true
        bridge.isForegroundSuppressed = { suppressed }

        DispatchQueue.global(qos: .userInitiated).async {
            bridge.handleWillPresent { options in
                let onMain = Thread.isMainThread
                MainActor.assumeIsolated {
                    result.willPresentSuppressedOnMainThread = onMain
                    result.optionsWhenSuppressed = options
                }
            }
        }
        try await waitUntil("willPresent suppressed completion") { result.optionsWhenSuppressed != nil }
        XCTAssertTrue(result.willPresentSuppressedOnMainThread)
        XCTAssertEqual(result.optionsWhenSuppressed, [])

        suppressed = false
        DispatchQueue.global(qos: .userInitiated).async {
            bridge.handleWillPresent { options in
                let onMain = Thread.isMainThread
                MainActor.assumeIsolated {
                    result.willPresentVisibleOnMainThread = onMain
                    result.optionsWhenVisible = options
                }
            }
        }
        try await waitUntil("willPresent visible completion") { result.optionsWhenVisible != nil }
        XCTAssertTrue(result.willPresentVisibleOnMainThread)
        XCTAssertEqual(result.optionsWhenVisible, [.banner, .list, .sound, .badge])
    }

    private func waitUntil(_ label: String, timeout: Double = 3.0, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for \(label)")
                return
            }
            try await Task.sleep(for: .milliseconds(15))
        }
    }
}

@MainActor
private final class SharedTimeline {
    var events: [String] = []
}

@MainActor
private final class MockUserNotificationManager: UserNotificationManaging {
    struct AddedNotification: Equatable {
        let identifier: String
        let title: String
        let body: String
        let userInfo: [String: String]
        let badgeCount: Int
    }

    let timeline: SharedTimeline
    var onOpenSession: (@MainActor (_ connectionId: UUID, _ sessionId: String) -> Void)?
    var isForegroundSuppressed: (@MainActor () -> Bool)?
    var artificialAuthDelayMs: Int = 0
    var artificialAddDelayMs: Int = 0
    private(set) var authRequestCount = 0
    private(set) var clearCount = 0
    private(set) var added: [AddedNotification] = []

    init(timeline: SharedTimeline) {
        self.timeline = timeline
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        if artificialAuthDelayMs > 0 {
            try? await Task.sleep(for: .milliseconds(artificialAuthDelayMs))
        }
        authRequestCount += 1
        timeline.events.append("notification:auth")
        return true
    }

    func addNotification(
        identifier: String,
        title: String,
        body: String,
        userInfo: [String: String],
        badgeCount: Int
    ) async {
        if artificialAddDelayMs > 0 {
            try? await Task.sleep(for: .milliseconds(artificialAddDelayMs))
        }
        added.append(AddedNotification(
            identifier: identifier,
            title: title,
            body: body,
            userInfo: userInfo,
            badgeCount: badgeCount
        ))
        timeline.events.append("notification:added")
    }

    func clearBadgeAndDeliveredNotifications() async {
        clearCount += 1
        timeline.events.append("notification:cleared")
    }
}

@MainActor
private final class MockContinuedTurnTaskManager: ContinuedTurnTaskManaging {
    let timeline: SharedTimeline
    var onExpiration: (@MainActor () -> Void)?
    private(set) var isActive = false
    private(set) var isGraceActive = false
    private(set) var startCount = 0
    private(set) var lastTitle = ""
    private(set) var lastSubtitle = ""
    private(set) var lastCompletedUnits: Int64 = 0
    private(set) var finishResults: [Bool] = []
    private(set) var graceBeginCount = 0

    init(timeline: SharedTimeline) {
        self.timeline = timeline
    }

    func startIfNeeded(title: String, subtitle: String) {
        guard !isActive else {
            lastTitle = title
            lastSubtitle = subtitle
            return
        }
        isActive = true
        startCount += 1
        lastTitle = title
        lastSubtitle = subtitle
        timeline.events.append("bgTask:started")
    }

    func update(title: String, subtitle: String, completedUnits: Int64, totalUnits: Int64) {
        guard isActive else { return }
        lastTitle = title
        lastSubtitle = subtitle
        lastCompletedUnits = completedUnits
    }

    func finish(success: Bool) {
        guard isActive else { return }
        isActive = false
        finishResults.append(success)
        timeline.events.append("bgTask:finished:\(success)")
    }

    func beginGraceBackgroundTask() {
        guard !isGraceActive else { return }
        isGraceActive = true
        graceBeginCount += 1
        timeline.events.append("grace:began")
    }

    func endGraceBackgroundTask() {
        guard isGraceActive else { return }
        isGraceActive = false
        timeline.events.append("grace:ended")
    }
}
