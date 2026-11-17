import CryptoKit
import Network
import SwiftUI
import UIKit
import XCTest
@testable import CodingProfessionalAgent

@MainActor
final class NavigationLayoutTests: XCTestCase {
    private static func effectivePresentationOpacity(of view: UIView, root: UIView) -> Float {
        var opacity: Float = 1.0
        var current: UIView? = view
        while let node = current {
            if node.isHidden || (node.layer.presentation()?.isHidden ?? node.layer.isHidden) {
                return 0
            }
            let layerOpacity = node.layer.presentation()?.opacity ?? node.layer.opacity
            opacity *= layerOpacity
            if node === root {
                break
            }
            current = node.superview
        }
        return opacity
    }

    private static func findNavigationController(in controller: UIViewController?) -> UINavigationController? {
        guard let controller else { return nil }
        if let nav = controller as? UINavigationController {
            return nav
        }
        for child in controller.children {
            if let found = findNavigationController(in: child) {
                return found
            }
        }
        return nil
    }
    func testTitleWidthUsesInheritedNavigationWidthImmediately() {
        XCTAssertEqual(NavigationLayout.titleWidth(containerWidth: 440, reservedWidth: 120), 320)
        XCTAssertEqual(NavigationLayout.titleWidth(containerWidth: 393, reservedWidth: 120), 273)
        XCTAssertEqual(NavigationLayout.titleWidth(containerWidth: 440, reservedWidth: 240), 200)
        XCTAssertEqual(NavigationLayout.titleWidth(containerWidth: 300, reservedWidth: 240), 120)
    }

    func testFallbackContainerWidthMatchesActiveWindowBeforeFirstGeometryPass() {
        let fallbackWidth = NavigationLayout.containerWidth(0)
        XCTAssertGreaterThan(fallbackWidth, 0)
        XCTAssertEqual(
            NavigationLayout.titleWidth(containerWidth: 0, reservedWidth: 120),
            max(fallbackWidth - 120, 120)
        )
    }

    func testPushedSubAgentKeepsFullScrollWidthAndNonOverlappingHeaderDuringTransition() throws {
        let suiteName = "NavigationLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let connection = DesktopConnection(
            id: UUID(),
            name: "Test Mac",
            host: "127.0.0.1",
            port: 59999,
            icon: .laptop,
            isEnabled: false
        )
        store.add(connection, password: "")
        defer {
            store.remove(connection.id)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let router = Router()
        struct TestHost: View {
            @Bindable var router: Router
            let store: ConnectionStore

            var body: some View {
                NavigationStack(path: $router.path) {
                    Color.clear
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case .thread(let connectionId, let sessionId):
                                ThreadView(connectionId: connectionId, sessionId: sessionId)
                            case .newThread(let context):
                                NewThreadView(context: context)
                            case .subAgent(let connectionId, let parentSessionId, let agentId, let sessionId):
                                SubAgentView(
                                    connectionId: connectionId,
                                    parentSessionId: parentSessionId,
                                    agentId: agentId,
                                    sessionId: sessionId
                                )
                            }
                        }
                }
                .environment(router)
                .environment(store)
                .environment(\.navigationWidth, 440)
            }
        }

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window: UIWindow
        if let scene = scenes.first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        }
        window.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        let host = UIHostingController(rootView: TestHost(router: router, store: store))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        router.push(.thread(connectionId: connection.id, sessionId: "parent-1"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        // Push SubAgentView and inspect mid-transition (~0.15s in) while entries are still empty.
        router.push(.subAgent(
            connectionId: connection.id,
            parentSessionId: "parent-1",
            agentId: "agent-1",
            sessionId: "child-1"
        ))
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        window.layoutIfNeeded()

        func collect<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
            var matches: [T] = []
            if let typed = view as? T {
                matches.append(typed)
            }
            for subview in view.subviews {
                matches.append(contentsOf: collect(type, in: subview))
            }
            return matches
        }

        let scrollViews = collect(UIScrollView.self, in: window).filter {
            !($0 is UITextView) && $0.window != nil && !$0.isHidden
        }
        XCTAssertGreaterThanOrEqual(scrollViews.count, 1)
        for scrollView in scrollViews {
            XCTAssertEqual(scrollView.bounds.width, 440, accuracy: 1.0)
        }

        let navBar = try XCTUnwrap(collect(UINavigationBar.self, in: window).first)
        func allDescendants(of view: UIView) -> [UIView] {
            view.subviews + view.subviews.flatMap(allDescendants(of:))
        }
        let barDescendants = allDescendants(of: navBar)
        let subAgentHeaders = barDescendants.filter {
            abs($0.bounds.width - 320) < 1 && $0.bounds.height >= 30
        }
        XCTAssertFalse(subAgentHeaders.isEmpty, "Expected 320pt-wide sub-agent header container from frame 0")
        for view in subAgentHeaders {
            // None of the 320pt header views may overflow a narrower 120pt container at negative X.
            XCTAssertGreaterThanOrEqual(view.frame.minX, 0)
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        window.layoutIfNeeded()
        let settledHeader = try XCTUnwrap(allDescendants(of: navBar).first {
            abs($0.bounds.width - 320) < 1 && $0.bounds.height >= 30 && $0.alpha > 0.99
        })
        let settledScreenRect = settledHeader.convert(settledHeader.bounds, to: window)
        XCTAssertGreaterThanOrEqual(settledScreenRect.minX, 76)

        // Simulate the first entry arriving (~0.5s after opening), flipping model.entries.isEmpty
        // from true to false; the toolbar header view must stay mounted without blinking.
        let headerIdentityBeforeLoad = ObjectIdentifier(settledHeader)
        let client = try XCTUnwrap(store.client(for: connection.id))
        client.emit(DesktopEvent(
            kind: "session:stream-event",
            payload: .object([
                "sessionId": .string("child-1"),
                "event": .object([
                    "type": .string("user-entry"),
                    "entry": .object([
                        "id": .string("u-1"),
                        "kind": .string("user"),
                        "createdAt": .number(1000),
                        "content": .array([
                            .object(["type": .string("text"), "text": .string("Investigate module")])
                        ])
                    ])
                ])
            ])
        ))
        // Sample every ~16ms frame for 0.25s after arrival to catch any transient 1-frame blink.
        for _ in 0..<16 {
            window.layoutIfNeeded()
            let headerAfterLoad = try XCTUnwrap(allDescendants(of: navBar).first {
                ObjectIdentifier($0) == headerIdentityBeforeLoad
            }, "Sub-agent toolbar header view must not be destroyed and recreated when entries arrive")
            let renderedOpacity = Self.effectivePresentationOpacity(of: headerAfterLoad, root: navBar)
            XCTAssertEqual(renderedOpacity, 1.0, accuracy: 0.02)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0))
        }
    }

    func testSubAgentHeaderDoesNotBlinkWhenEntriesArriveMidTransition() throws {
        let suiteName = "NavigationLayoutTests.Mid.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let connection = DesktopConnection(
            id: UUID(),
            name: "Test Mac",
            host: "127.0.0.1",
            port: 59999,
            icon: .laptop,
            isEnabled: false
        )
        store.add(connection, password: "")
        defer {
            store.remove(connection.id)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let router = Router()
        struct TestHost: View {
            @Bindable var router: Router
            let store: ConnectionStore

            var body: some View {
                NavigationStack(path: $router.path) {
                    Color.clear
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case .thread(let connectionId, let sessionId):
                                ThreadView(connectionId: connectionId, sessionId: sessionId)
                            case .newThread(let context):
                                NewThreadView(context: context)
                            case .subAgent(let connectionId, let parentSessionId, let agentId, let sessionId):
                                SubAgentView(
                                    connectionId: connectionId,
                                    parentSessionId: parentSessionId,
                                    agentId: agentId,
                                    sessionId: sessionId
                                )
                            }
                        }
                }
                .environment(router)
                .environment(store)
                .environment(\.navigationWidth, 440)
            }
        }

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        window.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        window.rootViewController = UIHostingController(rootView: TestHost(router: router, store: store))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        router.push(.thread(connectionId: connection.id, sessionId: "parent-mid"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        router.push(.subAgent(
            connectionId: connection.id,
            parentSessionId: "parent-mid",
            agentId: "agent-mid",
            sessionId: "child-mid"
        ))
        RunLoop.main.run(until: Date().addingTimeInterval(0.22))
        window.layoutIfNeeded()

        func allDescendants(of view: UIView) -> [UIView] {
            view.subviews + view.subviews.flatMap(allDescendants(of:))
        }
        let navController = try XCTUnwrap(Self.findNavigationController(in: window.rootViewController))
        XCTAssertNotNil(navController.transitionCoordinator, "Expected push transition to still be in progress")

        let navBar = try XCTUnwrap(allDescendants(of: window).compactMap { $0 as? UINavigationBar }.first)
        let visibleHeaderMidPush = try XCTUnwrap(allDescendants(of: navBar).first {
            abs($0.bounds.width - 320) < 1
                && $0.bounds.height >= 30
                && Self.effectivePresentationOpacity(of: $0, root: navBar) > 0.25
        })
        let identityMidPush = ObjectIdentifier(visibleHeaderMidPush)
        let baselineOpacity = Self.effectivePresentationOpacity(of: visibleHeaderMidPush, root: navBar)

        // Deliver entries mid-push (~0.22s in, matching realistic ~200-400ms network RTT).
        let client = try XCTUnwrap(store.client(for: connection.id))
        client.emit(DesktopEvent(
            kind: "session:stream-event",
            payload: .object([
                "sessionId": .string("child-mid"),
                "event": .object([
                    "type": .string("user-entry"),
                    "entry": .object([
                        "id": .string("u-mid"),
                        "kind": .string("user"),
                        "createdAt": .number(1000),
                        "content": .array([
                            .object(["type": .string("text"), "text": .string("Prompt")])
                        ])
                    ])
                ])
            ])
        ))

        // Sample every ~16ms frame across the remainder of the push transition until settled.
        var previousOpacity = baselineOpacity
        for _ in 0..<28 {
            window.layoutIfNeeded()
            let currentHeader = try XCTUnwrap(allDescendants(of: navBar).first {
                ObjectIdentifier($0) == identityMidPush
            }, "Toolbar header must keep its identity across mid-transition entry arrival")
            let currentOpacity = Self.effectivePresentationOpacity(of: currentHeader, root: navBar)
            XCTAssertGreaterThan(currentOpacity, 0.2, "Header presentation opacity must never drop to near-zero")
            XCTAssertGreaterThanOrEqual(
                currentOpacity,
                previousOpacity - 0.05,
                "Header presentation opacity must remain monotonic during push fade-in without blinking"
            )
            previousOpacity = currentOpacity
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0))
        }
        XCTAssertEqual(previousOpacity, 1.0, accuracy: 0.02)
    }

    func testOpenThreadUpdatesPathAndSettingsViewExposesTurnNotificationToggle() throws {
        let suiteName = "NavigationLayoutTests.Notif.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let connectionId = UUID()
        let router = Router()
        router.push(.newThread(NewThreadContext()))
        router.openThread(connectionId: connectionId, sessionId: "sess-9")
        XCTAssertEqual(router.path, [.thread(connectionId: connectionId, sessionId: "sess-9")])
        XCTAssertEqual(router.externalNavigationRevision, 1)

        router.openThread(connectionId: connectionId, sessionId: "sess-9")
        XCTAssertEqual(router.path, [.thread(connectionId: connectionId, sessionId: "sess-9")])
        XCTAssertEqual(router.externalNavigationRevision, 2)

        // Mount SettingsView with zero connections: 2 Composer toggles + 2 Behavior toggles = 4 UISwitch controls.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        let settingsRoot = SettingsView()
            .environment(store)
            .defaultAppStorage(defaults)
        window.rootViewController = UIHostingController(rootView: settingsRoot)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.layoutIfNeeded()

        func allDescendants(of view: UIView) -> [UIView] {
            view.subviews + view.subviews.flatMap(allDescendants(of:))
        }
        let switches = allDescendants(of: window)
            .compactMap { $0 as? UISwitch }
            .sorted { $0.convert($0.bounds.origin, to: window).y < $1.convert($1.bounds.origin, to: window).y }
        XCTAssertEqual(switches.count, 4, "Expected 4 preference toggles including 任务完成通知")

        // The 3rd switch from top is the turn-completion notification toggle (default true); flipping it updates PreferenceKey.notifyOnTurnComplete.
        let notifSwitch = switches[2]
        XCTAssertTrue(notifSwitch.isOn)
        notifSwitch.setOn(false, animated: false)
        notifSwitch.sendActions(for: .valueChanged)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(defaults.object(forKey: PreferenceKey.notifyOnTurnComplete) as? Bool, false)
    }

    func testOpenThreadReplacesActiveThreadViewIdentityAndClearsUnreadState() throws {
        let suiteName = "NavigationLayoutTests.Replace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let connection = DesktopConnection(
            id: UUID(),
            name: "Test Mac",
            host: "127.0.0.1",
            port: 59999,
            icon: .laptop,
            isEnabled: false
        )
        store.add(connection, password: "")
        defer {
            store.remove(connection.id)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let client = try XCTUnwrap(store.client(for: connection.id))
        func emitMeta(id: String, title: String, unread: Bool, timestamp: Double) throws {
            let envelope: JSONValue = [
                "type": "event",
                "event": [
                    "kind": "session:meta-updated",
                    "data": [
                        "id": .string(id),
                        "title": .string(title),
                        "unread": .bool(unread),
                        "createdAt": .number(timestamp),
                        "updatedAt": .number(timestamp),
                    ],
                ],
            ]
            client.ingestServerMessage(Data(try envelope.jsonString().utf8))
        }
        try emitMeta(id: "sess-A", title: "Session Alpha", unread: true, timestamp: 1)
        try emitMeta(id: "sess-B", title: "Session Beta", unread: true, timestamp: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(client.session(id: "sess-A")?.isUnread, true)
        XCTAssertEqual(client.session(id: "sess-B")?.isUnread, true)

        let router = Router()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        window.rootViewController = UIHostingController(
            rootView: HomeView()
                .environment(router)
                .environment(store)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let navController = try XCTUnwrap(Self.findNavigationController(in: window.rootViewController))

        router.push(.thread(connectionId: connection.id, sessionId: "sess-A"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(navController.viewControllers.count, 2)
        XCTAssertEqual(client.session(id: "sess-A")?.isUnread, false)
        XCTAssertEqual(client.session(id: "sess-B")?.isUnread, true)

        // Switching directly from an active thread via notification tap must recreate ThreadContent for sess-B
        // rather than reusing sess-A's ThreadModel or popping back to Home.
        router.openThread(connectionId: connection.id, sessionId: "sess-B")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        window.layoutIfNeeded()
        XCTAssertEqual(router.path, [.thread(connectionId: connection.id, sessionId: "sess-B")])
        XCTAssertEqual(navController.viewControllers.count, 2)
        XCTAssertEqual(client.session(id: "sess-B")?.isUnread, false)
    }

    func testNotificationEntryHoldsDesignedLoadingStateAcrossStaleSocketDropAndRendersSessionOnReconnect() async throws {
        let server = try ControllableSessionServer()
        defer { server.stop() }
        server.sessionEntries["sess-notif"] = [
            [
                "id": "u-1",
                "kind": "user",
                "createdAt": 1000,
                "content": [["type": "text", "text": "帮我检查部署脚本"]],
            ],
            [
                "id": "a-1",
                "kind": "assistant",
                "status": "done",
                "stopReason": "stop",
                "createdAt": 1100,
                "completedAt": 1200,
                "content": [["type": "text", "text": "部署脚本检查已完成，一切正常。"]],
            ],
        ]

        let suiteName = "NavigationLayoutTests.StaleWake.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let connection = DesktopConnection(
            id: UUID(),
            name: "Studio Mac",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .display,
            isEnabled: true
        )
        store.add(connection, password: "")
        let client = try XCTUnwrap(store.client(for: connection.id))
        defer {
            client.stop()
            store.remove(connection.id)
            defaults.removePersistentDomain(forName: suiteName)
        }

        try await waitUntil("initial desktop sync") {
            client.state == .connected && client.hasSynced
        }

        // Simulate waking from background via notification tap: the pre-suspension socket is stale
        // (drops as soon as session:get is sent) and Wi-Fi takes ~200ms before reconnects succeed.
        server.dropOnNextSessionGet = true
        server.rejectConnections = true

        let grace = ConnectionGraceConfiguration(
            failureGrace: .milliseconds(1200),
            connectingTimeout: .milliseconds(1600),
            retryInterval: .milliseconds(180),
            pollInterval: .milliseconds(25)
        )
        let router = Router()
        struct GraceTestHost: View {
            @Bindable var router: Router
            let store: ConnectionStore
            let grace: ConnectionGraceConfiguration

            var body: some View {
                NavigationStack(path: $router.path) {
                    Color.clear
                        .navigationDestination(for: Route.self) { route in
                            if case .thread(let connectionId, let sessionId) = route {
                                ThreadView(
                                    connectionId: connectionId,
                                    sessionId: sessionId,
                                    graceConfiguration: grace
                                )
                            }
                        }
                }
                .environment(router)
                .environment(store)
                .environment(\.navigationWidth, 440)
            }
        }

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        window.rootViewController = UIHostingController(rootView: GraceTestHost(router: router, store: store, grace: grace))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        router.openThread(connectionId: connection.id, sessionId: "sess-notif", titleHint: "部署脚本检查")
        try await waitUntil("stale socket dropped on initial session:get", timeout: 1.5) {
            window.layoutIfNeeded()
            return server.sessionGetCount >= 1 && !client.isConnected
        }
        window.layoutIfNeeded()

        // Navigation bar renders the push notification's sessionTitle hint immediately before session metadata syncs.
        let navBarTexts = Self.visibleStrings(in: window)
        XCTAssertTrue(navBarTexts.contains("部署脚本检查"), "Expected notification title hint in navigation bar, got: \(navBarTexts)")

        // Verify the loading view lays out cleanly in both connecting and syncing phases and exposes brand-aligned copy.
        let loadingHost = UIHostingController(rootView: ConversationLoadingView(
            icon: .display,
            desktopName: "Studio Mac",
            isConnected: false
        ))
        let loadingSize = loadingHost.sizeThatFits(in: CGSize(width: 390, height: 600))
        XCTAssertGreaterThan(loadingSize.width, 120)
        XCTAssertGreaterThan(loadingSize.height, 80)
        XCTAssertEqual(ConversationLoadingView.statusTitle(isConnected: false, desktopName: "Studio Mac"), L10n.Thread.loadingConnectingTitle("Studio Mac"))
        XCTAssertEqual(ConversationLoadingView.statusTitle(isConnected: true, desktopName: "Studio Mac"), L10n.Thread.loadingMessagesTitle)

        // Also verify a direct ThreadModel experiencing the exact same stale-socket drop holds the loading state
        // without flashing loadError or connectionError, and resolves the connecting composer placeholder.
        let probeServer = try ControllableSessionServer()
        defer { probeServer.stop() }
        probeServer.sessionEntries["sess-probe"] = server.sessionEntries["sess-notif"]
        let probeClient = DesktopClient(connection: DesktopConnection(
            name: "Studio Mac",
            host: "127.0.0.1",
            port: Int(probeServer.port),
            icon: .display
        ))
        defer { probeClient.stop() }
        probeClient.start()
        try await waitUntil("probe initial sync") {
            probeClient.state == .connected && probeClient.hasSynced
        }
        probeServer.dropOnNextSessionGet = true
        probeServer.rejectConnections = true
        let probeModel = ThreadModel(client: probeClient, sessionId: "sess-probe", graceConfiguration: grace)
        probeModel.activate()
        defer { probeModel.deactivate() }

        try await waitUntil("probe stale socket dropped", timeout: 1.5) {
            probeServer.sessionGetCount >= 1 && !probeClient.isConnected
        }
        XCTAssertTrue(probeModel.isWaitingForConnection)
        XCTAssertTrue(probeModel.isLoading)
        XCTAssertNil(probeModel.loadError)
        XCTAssertNil(probeModel.connectionError)
        XCTAssertEqual(ThreadView.resolvedComposerPlaceholder(model: probeModel), L10n.Home.clientConnecting("Studio Mac"))
        XCTAssertEqual(ThreadView.resolvedTitle(model: probeModel, router: router), L10n.Thread.chatTitle)

        // Allow both servers to accept reconnects inside the grace window; both ThreadView and probeModel recover cleanly.
        server.rejectConnections = false
        probeServer.rejectConnections = false
        try await waitUntil("ThreadView and probeModel reconnected and loaded entries", timeout: 3.0) {
            window.layoutIfNeeded()
            return server.sessionGetCount >= 2
                && client.isConnected
                && probeModel.entries.count == 2
                && !probeModel.isLoading
                && !probeModel.isWaitingForConnection
        }
        XCTAssertNil(probeModel.loadError)
        XCTAssertNil(probeModel.connectionError)
        XCTAssertEqual(probeModel.entries.last?.text, "部署脚本检查已完成，一切正常。")
        XCTAssertEqual(ThreadView.resolvedComposerPlaceholder(model: probeModel), L10n.Thread.workOnDesktop("Studio Mac"))
    }

    func testGenuinelyUnreachableDesktopShowsErrorOnlyAfterGracePeriodAndSupportsManualRetry() async throws {
        let server = try ControllableSessionServer()
        defer { server.stop() }
        server.rejectConnections = true
        server.sessionEntries["sess-offline"] = [
            [
                "id": "u-off-1",
                "kind": "user",
                "createdAt": 2000,
                "content": [["type": "text", "text": "恢复连接测试"]],
            ],
            [
                "id": "a-off-1",
                "kind": "assistant",
                "status": "done",
                "stopReason": "stop",
                "createdAt": 2100,
                "completedAt": 2200,
                "content": [["type": "text", "text": "重连后已成功加载会话内容。"]],
            ],
        ]

        let suiteName = "NavigationLayoutTests.OfflineGrace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let connection = DesktopConnection(
            id: UUID(),
            name: "Home Mac",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop,
            isEnabled: true
        )
        store.add(connection, password: "")
        let client = try XCTUnwrap(store.client(for: connection.id))
        defer {
            client.stop()
            store.remove(connection.id)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let grace = ConnectionGraceConfiguration(
            failureGrace: .milliseconds(350),
            connectingTimeout: .milliseconds(550),
            retryInterval: .milliseconds(140),
            pollInterval: .milliseconds(25)
        )
        let model = ThreadModel(client: client, sessionId: "sess-offline", graceConfiguration: grace)
        model.activate()
        defer { model.deactivate() }

        // Immediately and at 100ms, the model stays in the loading/grace state without surfacing connectionError.
        XCTAssertTrue(model.isWaitingForConnection)
        XCTAssertTrue(model.isLoading)
        XCTAssertNil(model.connectionError)
        XCTAssertNil(model.loadError)

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.isWaitingForConnection)
        XCTAssertNil(model.connectionError)
        XCTAssertNil(model.loadError)

        // Once the desktop remains unreachable past the grace window, connectionError is surfaced cleanly.
        try await waitUntil("connectionError surfaced after grace window", timeout: 2.0) {
            model.connectionError != nil && !model.isWaitingForConnection && !model.isLoading
        }
        XCTAssertNil(model.loadError)

        // Bringing the server online and invoking retryConnection() returns to loading and loads the entries.
        server.rejectConnections = false
        model.retryConnection()
        XCTAssertNil(model.connectionError)
        XCTAssertTrue(model.isWaitingForConnection || model.isLoading)

        try await waitUntil("entries loaded after retryConnection", timeout: 2.5) {
            model.entries.count == 2 && !model.isLoading && !model.isWaitingForConnection && model.connectionError == nil
        }
        XCTAssertEqual(model.entries.last?.text, "重连后已成功加载会话内容。")
    }

    func testTerminalWrongPasswordFailsPromptlyWithoutWaitingFullGrace() async throws {
        let server = try ControllableSessionServer()
        defer { server.stop() }
        server.requiredPassword = "correct-secret"

        let suiteName = "NavigationLayoutTests.WrongPw.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let connection = DesktopConnection(
            id: UUID(),
            name: "Locked Mac",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop,
            isEnabled: false
        )
        KeychainStore.setPassword("wrong-secret", for: connection.id)
        store.add(connection, password: "wrong-secret")
        store.setEnabled(connection.id, true)
        let client = try XCTUnwrap(store.client(for: connection.id))
        defer {
            client.stop()
            store.remove(connection.id)
            KeychainStore.deletePassword(for: connection.id)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let longGrace = ConnectionGraceConfiguration(
            failureGrace: .seconds(8),
            connectingTimeout: .seconds(12),
            retryInterval: .seconds(3),
            pollInterval: .milliseconds(30)
        )
        let model = ThreadModel(client: client, sessionId: "sess-pw", graceConfiguration: longGrace)
        let start = ContinuousClock.now
        model.activate()
        defer { model.deactivate() }

        try await waitUntil("terminal wrong-password error surfaces immediately", timeout: 1.5) {
            model.connectionError == L10n.ErrorMessage.unauthorized && !model.isWaitingForConnection && !model.isLoading
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1.5))
    }

    private static func visibleStrings(in root: UIView) -> [String] {
        var results: [String] = []
        func walk(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            if let label = view as? UILabel, let text = label.text, !text.isEmpty {
                results.append(text)
            }
            if let accessibilityLabel = view.accessibilityLabel, !accessibilityLabel.isEmpty {
                results.append(accessibilityLabel)
            }
            for subview in view.subviews {
                walk(subview)
            }
        }
        walk(root)
        return results
    }

    private func waitUntil(
        _ label: String,
        timeout: Double = 3.0,
        condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for \(label)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private final class ControllableSessionServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.controllable-session-server")
    private let listener: NWListener
    private let lock = NSLock()
    private var _rejectConnections = false
    private var _dropOnNextSessionGet = false
    private var _sessionGetCount = 0
    private var _requiredPassword: String?
    private var _sessionEntries: [String: [JSONValue]] = [:]
    private var activeConnections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    var rejectConnections: Bool {
        get { lock.withLock { _rejectConnections } }
        set { lock.withLock { _rejectConnections = newValue } }
    }

    var dropOnNextSessionGet: Bool {
        get { lock.withLock { _dropOnNextSessionGet } }
        set { lock.withLock { _dropOnNextSessionGet = newValue } }
    }

    var sessionGetCount: Int {
        lock.withLock { _sessionGetCount }
    }

    var requiredPassword: String? {
        get { lock.withLock { _requiredPassword } }
        set { lock.withLock { _requiredPassword = newValue } }
    }

    var sessionEntries: [String: [JSONValue]] {
        get { lock.withLock { _sessionEntries } }
        set { lock.withLock { _sessionEntries = newValue } }
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
            self?.handleConnection(conn)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
    }

    func stop() {
        let conns = lock.withLock { () -> [NWConnection] in
            let copy = activeConnections
            activeConnections.removeAll()
            return copy
        }
        for conn in conns {
            conn.forceCancel()
        }
        listener.cancel()
    }

    private func handleConnection(_ conn: NWConnection) {
        if rejectConnections {
            conn.forceCancel()
            return
        }
        conn.start(queue: queue)
        readHTTP(conn: conn, buffer: Data())
    }

    private func readHTTP(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var next = buffer
            if let data {
                next.append(data)
            }
            if let headerRange = next.range(of: Data("\r\n\r\n".utf8)) {
                let headerText = String(decoding: next[..<headerRange.lowerBound], as: UTF8.self)
                let bodyRemainder = Data(next[headerRange.upperBound...])
                let contentLength = Self.parseContentLength(headerText)
                if bodyRemainder.count < contentLength {
                    self.readHTTPBody(conn: conn, headerText: headerText, expectedLength: contentLength, accumulated: bodyRemainder)
                } else {
                    self.routeHTTP(conn: conn, headerText: headerText, body: Data(bodyRemainder.prefix(contentLength)), remainder: Data(bodyRemainder.dropFirst(contentLength)))
                }
                return
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.readHTTP(conn: conn, buffer: next)
        }
    }

    private func readHTTPBody(conn: NWConnection, headerText: String, expectedLength: Int, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var next = accumulated
            if let data {
                next.append(data)
            }
            if next.count >= expectedLength {
                self.routeHTTP(conn: conn, headerText: headerText, body: Data(next.prefix(expectedLength)), remainder: Data(next.dropFirst(expectedLength)))
                return
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.readHTTPBody(conn: conn, headerText: headerText, expectedLength: expectedLength, accumulated: next)
        }
    }

    private static func parseContentLength(_ headerText: String) -> Int {
        for line in headerText.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let raw = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(raw) ?? 0
            }
        }
        return 0
    }

    private func sendHTTPResponse(conn: NWConnection, head: String, body: Data) {
        conn.send(
            content: Data(head.utf8) + body,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    private func routeHTTP(conn: NWConnection, headerText: String, body: Data, remainder: Data) {
        let lines = headerText.components(separatedBy: "\r\n")
        let firstLine = lines.first ?? ""
        let pw = requiredPassword
        if firstLine.hasPrefix("GET /api/auth/status") {
            let statusBody = pw == nil
                ? Data(#"{"required":false,"authenticated":true}"#.utf8)
                : Data(#"{"required":true,"authenticated":false}"#.utf8)
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(statusBody.count)\r\nConnection: close\r\n\r\n"
            sendHTTPResponse(conn: conn, head: head, body: statusBody)
            return
        }
        if firstLine.hasPrefix("POST /api/auth/login") {
            let submitted = JSONValue.parse(body)?["password"]?.stringValue ?? ""
            if let pw, submitted != pw {
                let errBody = Data(#"{"error":"unauthorized"}"#.utf8)
                let head = "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: \(errBody.count)\r\nConnection: close\r\n\r\n"
                sendHTTPResponse(conn: conn, head: head, body: errBody)
                return
            }
            let okBody = Data(#"{"ok":true}"#.utf8)
            let head = "HTTP/1.1 200 OK\r\nSet-Cookie: sid=ok; Path=/\r\nContent-Type: application/json\r\nContent-Length: \(okBody.count)\r\nConnection: close\r\n\r\n"
            sendHTTPResponse(conn: conn, head: head, body: okBody)
            return
        }
        if firstLine.hasPrefix("GET /api/ws") {
            var secKey = ""
            for line in lines where line.lowercased().hasPrefix("sec-websocket-key:") {
                secKey = line.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces)
            }
            let magic = secKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
            let accept = Data(Insecure.SHA1.hash(data: Data(magic.utf8))).base64EncodedString()
            let handshake = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            conn.send(content: Data(handshake.utf8), completion: .contentProcessed { [weak self] err in
                guard let self, err == nil else { return }
                self.lock.withLock { self.activeConnections.append(conn) }
                self.sendWSText(conn: conn, text: #"{"type":"hello","clientId":"ctrl-c1"}"#)
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
            if opcode == 0x01,
               let rpc = JSONValue.parse(payload),
               rpc["type"]?.stringValue == "rpc",
               let id = rpc["id"]?.stringValue,
               let method = rpc["method"]?.stringValue
            {
                let args = rpc["args"]?.arrayValue ?? []
                if method == "session:get" {
                    let shouldDrop = lock.withLock { () -> Bool in
                        _sessionGetCount += 1
                        if _dropOnNextSessionGet {
                            _dropOnNextSessionGet = false
                            return true
                        }
                        return false
                    }
                    if shouldDrop {
                        conn.forceCancel()
                        return
                    }
                    let sid = args.first?.stringValue ?? ""
                    let entries = sessionEntries[sid] ?? []
                    let reply: JSONValue = [
                        "type": "rpc_result",
                        "id": .string(id),
                        "result": [
                            "entries": .array(entries),
                            "subAgents": .array([]),
                        ],
                    ]
                    if let text = try? reply.jsonString() {
                        sendWSText(conn: conn, text: text)
                    }
                    continue
                }
                let result: JSONValue
                switch method {
                case "session:getActiveRuns":
                    result = .array([])
                case "session:listSessions":
                    result = .array([])
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
