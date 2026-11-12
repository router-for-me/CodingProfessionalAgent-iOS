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
}
