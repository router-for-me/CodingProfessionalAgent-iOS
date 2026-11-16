import CryptoKit
import Foundation
import Network
import UIKit
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

    private func makeConnection(
        name: String,
        host: String = "invalid host",
        port: Int = 18080,
        isEnabled: Bool = true
    ) -> DesktopConnection {
        DesktopConnection(
            name: name,
            host: host,
            port: port,
            icon: .laptop,
            isEnabled: isEnabled
        )
    }

    func testInitActivationAndToggleRequestAuthorizationAndRegisterRemoteNotifications() async throws {
        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let router = Router()
        let notif = MockUserNotificationManager()
        let registrar = MockRemoteNotificationRegistrar()

        // 1. When preference starts disabled, init does not request authorization or register APNs.
        defaults.set(false, forKey: PreferenceKey.notifyOnTurnComplete)
        let disabledCoordinator = TurnNotificationCoordinator(
            store: store,
            router: router,
            defaults: defaults,
            notificationManager: notif,
            remoteRegistrar: registrar,
            initialActive: false
        )
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(notif.authRequestCount, 0)
        XCTAssertEqual(registrar.registerCount, 0)
        XCTAssertEqual(notif.isForegroundSuppressed?(), false)

        // 2. Enabling preference requests authorization and registers for remote notifications.
        disabledCoordinator.setNotificationsEnabled(true)
        try await waitUntil("auth and APNs registration on toggle-on") {
            notif.authRequestCount == 1 && registrar.registerCount == 1
        }

        // 3. Becoming active clears badge and re-checks authorization / registers APNs.
        let clearsBefore = notif.clearCount
        disabledCoordinator.setAppActive(true)
        try await waitUntil("clear badge and re-register on active") {
            notif.clearCount > clearsBefore && notif.authRequestCount == 2 && registrar.registerCount == 2
        }
        XCTAssertEqual(notif.isForegroundSuppressed?(), true)

        disabledCoordinator.setAppActive(false)
        XCTAssertEqual(notif.isForegroundSuppressed?(), false)

        // 4. Fresh coordinator with default enabled preference requests authorization and registers on init.
        let enabledNotif = MockUserNotificationManager()
        let enabledRegistrar = MockRemoteNotificationRegistrar()
        defaults.removeObject(forKey: PreferenceKey.notifyOnTurnComplete)
        let enabledCoordinator = TurnNotificationCoordinator(
            store: store,
            router: router,
            defaults: defaults,
            notificationManager: enabledNotif,
            remoteRegistrar: enabledRegistrar,
            initialActive: true
        )
        _ = enabledCoordinator
        try await waitUntil("auth and APNs registration on init when enabled") {
            enabledNotif.authRequestCount == 1 && enabledRegistrar.registerCount == 1 && enabledNotif.clearCount == 1
        }
        XCTAssertEqual(enabledNotif.isForegroundSuppressed?(), true)
    }

    func testPersistsStableClientIdAndSyncsRegistrationOnDeviceTokenAndSyncedEvent() async throws {
        let server1 = try MockNotificationRPCServer()
        defer { server1.stop() }
        let server2 = try MockNotificationRPCServer()
        defer { server2.stop() }

        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let conn1 = makeConnection(name: "Mac-1", host: "127.0.0.1", port: Int(server1.port))
        store.add(conn1, password: "")
        let client1 = try XCTUnwrap(store.client(for: conn1.id))
        defer { client1.stop() }

        let router = Router()
        let notif = MockUserNotificationManager()
        let registrar = MockRemoteNotificationRegistrar()
        let coordinator = TurnNotificationCoordinator(
            store: store,
            router: router,
            defaults: defaults,
            notificationManager: notif,
            remoteRegistrar: registrar,
            environmentProvider: { .sandbox },
            deviceName: "Test iPhone",
            appVersion: "2.1.0",
            initialActive: true
        )

        // Stable clientId persisted in UserDefaults.
        let expectedClientId = coordinator.clientId
        XCTAssertFalse(expectedClientId.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "notifications.apnsClientId"), expectedClientId)

        let secondCoordinator = TurnNotificationCoordinator(
            store: ConnectionStore(defaults: defaults, persistsCredentials: false),
            router: Router(),
            defaults: defaults,
            notificationManager: MockUserNotificationManager(),
            remoteRegistrar: MockRemoteNotificationRegistrar(),
            initialActive: true
        )
        XCTAssertEqual(secondCoordinator.clientId, expectedClientId)

        // Wait for conn1 to sync BEFORE deviceToken arrives -> must NOT send notification:registerClient yet.
        try await waitUntil("client1 synced without token") {
            client1.state == .connected && client1.hasSynced
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(server1.recordedNotificationRPCs.isEmpty)

        // Deliver deviceToken bytes -> converts to lowercase hex and registers on already-synced client1.
        let tokenBytes: [UInt8] = [
            0x0A, 0x1B, 0x2C, 0x3D, 0x4E, 0x5F, 0x00, 0x11,
            0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99,
            0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11,
            0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99,
        ]
        let expectedHex = "0a1b2c3d4e5f00112233445566778899aabbccddeeff00112233445566778899"
        coordinator.updateDeviceToken(Data(tokenBytes))

        try await waitUntil("client1 registered after token") {
            server1.recordedNotificationRPCs.count == 1
        }
        let call1 = try XCTUnwrap(server1.recordedNotificationRPCs.first)
        XCTAssertEqual(call1.method, "notification:registerClient")
        XCTAssertEqual(call1.args.first?["clientId"]?.stringValue, expectedClientId)
        XCTAssertEqual(call1.args.first?["connectionId"]?.stringValue, conn1.id.uuidString)
        XCTAssertEqual(call1.args.first?["deviceToken"]?.stringValue, expectedHex)
        XCTAssertEqual(call1.args.first?["environment"]?.stringValue, "sandbox")
        XCTAssertEqual(call1.args.first?["platform"]?.stringValue, "ios")
        XCTAssertEqual(call1.args.first?["deviceName"]?.stringValue, "Test iPhone")
        XCTAssertEqual(call1.args.first?["appVersion"]?.stringValue, "2.1.0")
        XCTAssertEqual(call1.args.first?["enabled"]?.boolValue, true)

        // Add conn2 after token is already available -> DesktopEvent.synced automatically registers conn2.
        let conn2 = makeConnection(name: "Mac-2", host: "127.0.0.1", port: Int(server2.port))
        store.add(conn2, password: "")
        let client2 = try XCTUnwrap(store.client(for: conn2.id))
        defer { client2.stop() }

        try await waitUntil("client2 synced and registered") {
            client2.state == .connected && client2.hasSynced && server2.recordedNotificationRPCs.count == 1
        }
        let call2 = try XCTUnwrap(server2.recordedNotificationRPCs.first)
        XCTAssertEqual(call2.method, "notification:registerClient")
        XCTAssertEqual(call2.args.first?["clientId"]?.stringValue, expectedClientId)
        XCTAssertEqual(call2.args.first?["connectionId"]?.stringValue, conn2.id.uuidString)
        XCTAssertEqual(call2.args.first?["deviceToken"]?.stringValue, expectedHex)
        XCTAssertEqual(call2.args.first?["enabled"]?.boolValue, true)
    }

    func testSetNotificationsEnabledSyncsAllConnectedClientsAndRemoveUnregistersOnlyRemovedConnection() async throws {
        // Review Focus #5
        let serverA = try MockNotificationRPCServer()
        defer { serverA.stop() }
        let serverB = try MockNotificationRPCServer()
        defer { serverB.stop() }

        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let connA = makeConnection(name: "Host-A", host: "127.0.0.1", port: Int(serverA.port))
        let connB = makeConnection(name: "Host-B", host: "127.0.0.1", port: Int(serverB.port))
        store.add(connA, password: "")
        store.add(connB, password: "")
        let clientA = try XCTUnwrap(store.client(for: connA.id))
        let clientB = try XCTUnwrap(store.client(for: connB.id))
        defer {
            clientA.stop()
            clientB.stop()
        }

        let coordinator = TurnNotificationCoordinator(
            store: store,
            router: Router(),
            defaults: defaults,
            notificationManager: MockUserNotificationManager(),
            remoteRegistrar: MockRemoteNotificationRegistrar(),
            environmentProvider: { .production },
            deviceName: "iPhone",
            appVersion: "1.0.0",
            initialActive: true
        )

        try await waitUntil("both clients synced") {
            clientA.state == .connected && clientA.hasSynced && clientB.state == .connected && clientB.hasSynced
        }

        let tokenHex = "a1b2c3d4e5f600112233445566778899aabbccddeeff00112233445566778899"
        coordinator.updateDeviceTokenHex(tokenHex)
        try await waitUntil("initial registration on both servers") {
            serverA.recordedNotificationRPCs.count == 1 && serverB.recordedNotificationRPCs.count == 1
        }

        // Toggling preference off syncs enabled=false to all connected clients.
        coordinator.setNotificationsEnabled(false)
        try await waitUntil("disabled sync on both servers") {
            serverA.recordedNotificationRPCs.count == 2 && serverB.recordedNotificationRPCs.count == 2
        }
        XCTAssertEqual(serverA.recordedNotificationRPCs.last?.method, "notification:registerClient")
        XCTAssertEqual(serverA.recordedNotificationRPCs.last?.args.first?["enabled"]?.boolValue, false)
        XCTAssertEqual(serverB.recordedNotificationRPCs.last?.method, "notification:registerClient")
        XCTAssertEqual(serverB.recordedNotificationRPCs.last?.args.first?["enabled"]?.boolValue, false)

        // Toggling preference back on syncs enabled=true to all connected clients.
        coordinator.setNotificationsEnabled(true)
        try await waitUntil("enabled sync on both servers") {
            serverA.recordedNotificationRPCs.count == 3 && serverB.recordedNotificationRPCs.count == 3
        }
        XCTAssertEqual(serverA.recordedNotificationRPCs.last?.args.first?["enabled"]?.boolValue, true)
        XCTAssertEqual(serverB.recordedNotificationRPCs.last?.args.first?["enabled"]?.boolValue, true)

        // Removing connA unregisters ONLY connA before stopping clientA; connB remains registered and connected.
        store.remove(connA.id)
        try await waitUntil("connA unregistered and stopped") {
            serverA.recordedNotificationRPCs.count == 4 && clientA.state == .disconnected
        }
        let unregisterCall = try XCTUnwrap(serverA.recordedNotificationRPCs.last)
        XCTAssertEqual(unregisterCall.method, "notification:unregisterClient")
        XCTAssertEqual(unregisterCall.args.first?["clientId"]?.stringValue, coordinator.clientId)
        XCTAssertEqual(unregisterCall.args.first?["connectionId"]?.stringValue, connA.id.uuidString)

        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(serverB.recordedNotificationRPCs.count, 3)
        XCTAssertFalse(serverB.recordedNotificationRPCs.contains { $0.method == "notification:unregisterClient" })
        XCTAssertEqual(clientB.state, .connected)
    }

    func testPermissionDeniedOrLegacyDesktopDegradesSilentlyWithoutCrashing() async throws {
        // Review Focus #3
        let server = try MockNotificationRPCServer()
        server.returnMethodNotFoundError = true
        defer { server.stop() }

        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let conn = makeConnection(name: "LegacyHost", host: "127.0.0.1", port: Int(server.port))
        store.add(conn, password: "")
        let client = try XCTUnwrap(store.client(for: conn.id))
        defer { client.stop() }

        let notif = MockUserNotificationManager()
        notif.shouldGrantAuthorization = false
        let registrar = MockRemoteNotificationRegistrar()

        let coordinator = TurnNotificationCoordinator(
            store: store,
            router: Router(),
            defaults: defaults,
            notificationManager: notif,
            remoteRegistrar: registrar,
            initialActive: true
        )

        try await waitUntil("auth denied and client synced") {
            notif.authRequestCount == 1 && client.state == .connected && client.hasSynced
        }
        XCTAssertEqual(registrar.registerCount, 0)
        XCTAssertTrue(server.recordedNotificationRPCs.isEmpty)
        XCTAssertEqual(client.state, .connected)
        XCTAssertTrue(client.hasSynced)

        // Even if a token exists and the legacy desktop rejects notification RPCs with rpc_error,
        // registration, toggle sync, and removal degrade silently without breaking the connection.
        coordinator.updateDeviceTokenHex("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
        try await waitUntil("legacy register attempted") {
            server.recordedNotificationRPCs.count == 1
        }
        XCTAssertEqual(client.state, .connected)
        XCTAssertTrue(client.hasSynced)

        coordinator.setNotificationsEnabled(false)
        try await waitUntil("legacy toggle attempted") {
            server.recordedNotificationRPCs.count == 2
        }
        XCTAssertEqual(client.state, .connected)

        store.remove(conn.id)
        try await waitUntil("legacy unregister attempted and stopped") {
            server.recordedNotificationRPCs.count == 3 && client.state == .disconnected
        }
    }

    func testConnectionRemovalStopsUnresponsiveClientWithin500msDeadline() async throws {
        let server = try MockNotificationRPCServer()
        defer { server.stop() }

        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let conn = makeConnection(name: "HangingHost", host: "127.0.0.1", port: Int(server.port))
        store.add(conn, password: "")
        let client = try XCTUnwrap(store.client(for: conn.id))
        defer { client.stop() }

        let coordinator = TurnNotificationCoordinator(
            store: store,
            router: Router(),
            defaults: defaults,
            notificationManager: MockUserNotificationManager(),
            remoteRegistrar: MockRemoteNotificationRegistrar(),
            initialActive: true
        )
        _ = coordinator

        try await waitUntil("client synced") {
            client.state == .connected && client.hasSynced
        }

        // Make notification:unregisterClient hang indefinitely without returning rpc_result.
        server.hangNotificationRPCs = true
        let start = ContinuousClock.now
        store.remove(conn.id)

        try await waitUntil("hanging removal forced client stop within deadline", timeout: 1.5) {
            client.state == .disconnected
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .seconds(1.5))
        XCTAssertEqual(server.recordedNotificationRPCs.last?.method, "notification:unregisterClient")
    }

    func testDisabledNotificationPreferencePersistsTokenAndSyncsAcrossRestartWithoutPrompt() async throws {
        let server = try MockNotificationRPCServer()
        defer { server.stop() }

        let store1 = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let conn = makeConnection(name: "Studio", host: "127.0.0.1", port: Int(server.port))
        store1.add(conn, password: "")
        let client1 = try XCTUnwrap(store1.client(for: conn.id))

        let notif1 = MockUserNotificationManager()
        let registrar1 = MockRemoteNotificationRegistrar()
        let coordinator1 = TurnNotificationCoordinator(
            store: store1,
            router: Router(),
            defaults: defaults,
            notificationManager: notif1,
            remoteRegistrar: registrar1,
            environmentProvider: { .sandbox },
            deviceName: "iPhone",
            appVersion: "1.0.0",
            initialActive: true
        )

        try await waitUntil("initial client synced") {
            client1.state == .connected && client1.hasSynced
        }

        let tokenHex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        coordinator1.updateDeviceTokenHex(tokenHex)
        try await waitUntil("initial enabled registration sent") {
            server.recordedNotificationRPCs.count == 1
        }
        XCTAssertEqual(server.recordedNotificationRPCs.last?.args.first?["enabled"]?.boolValue, true)
        XCTAssertEqual(defaults.string(forKey: "notifications.apnsDeviceToken"), tokenHex)

        // Go offline and disable notifications before restarting app.
        client1.stop()
        coordinator1.setNotificationsEnabled(false)

        // Simulate app restart with fresh ConnectionStore & TurnNotificationCoordinator sharing UserDefaults.
        let store2 = ConnectionStore(defaults: defaults, persistsCredentials: false)
        store2.add(conn, password: "")
        let client2 = try XCTUnwrap(store2.client(for: conn.id))
        defer { client2.stop() }

        let notif2 = MockUserNotificationManager()
        notif2.currentAuthorizationGranted = true
        let registrar2 = MockRemoteNotificationRegistrar()
        let coordinator2 = TurnNotificationCoordinator(
            store: store2,
            router: Router(),
            defaults: defaults,
            notificationManager: notif2,
            remoteRegistrar: registrar2,
            environmentProvider: { .sandbox },
            deviceName: "iPhone",
            appVersion: "1.0.0",
            initialActive: true
        )
        _ = coordinator2

        // Desktop reconnects and emits DesktopEvent.synced -> must sync enabled=false using persisted token
        // and silently refresh APNs token without triggering an authorization prompt.
        try await waitUntil("restarted client synced and synced disabled state") {
            client2.state == .connected && client2.hasSynced && server.recordedNotificationRPCs.count == 2
        }
        let resyncedCall = try XCTUnwrap(server.recordedNotificationRPCs.last)
        XCTAssertEqual(resyncedCall.method, "notification:registerClient")
        XCTAssertEqual(resyncedCall.args.first?["clientId"]?.stringValue, coordinator1.clientId)
        XCTAssertEqual(resyncedCall.args.first?["connectionId"]?.stringValue, conn.id.uuidString)
        XCTAssertEqual(resyncedCall.args.first?["deviceToken"]?.stringValue, tokenHex)
        XCTAssertEqual(resyncedCall.args.first?["enabled"]?.boolValue, false)
        XCTAssertEqual(notif2.authRequestCount, 0)
        XCTAssertEqual(registrar2.registerCount, 1)
    }

    func testAppDelegateBuffersDeviceTokenBeforeAndAfterWiring() {
        let delegate = AppDelegate()
        let earlyToken = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let lateToken = Data([0xCA, 0xFE, 0xBA, 0xBE])

        struct RegistrationError: Error {}
        delegate.application(UIApplication.shared, didFailToRegisterForRemoteNotificationsWithError: RegistrationError())
        delegate.application(UIApplication.shared, didRegisterForRemoteNotificationsWithDeviceToken: earlyToken)

        var received: [Data] = []
        delegate.onDeviceToken = { token in
            received.append(token)
        }
        XCTAssertEqual(received, [earlyToken])

        delegate.application(UIApplication.shared, didRegisterForRemoteNotificationsWithDeviceToken: lateToken)
        XCTAssertEqual(received, [earlyToken, lateToken])
    }

    func testTapNotificationNavigatesToThreadAndIgnoresDisabledConnection() async throws {
        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        let conn = makeConnection(name: "Studio")
        store.add(conn, password: "")
        let router = Router()
        router.push(.newThread(NewThreadContext()))

        let notif = MockUserNotificationManager()
        let coordinator = TurnNotificationCoordinator(
            store: store,
            router: router,
            defaults: defaults,
            notificationManager: notif,
            remoteRegistrar: MockRemoteNotificationRegistrar(),
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
        @MainActor final class SuppressionState {
            var suppressed = true
        }
        let suppressionState = SuppressionState()
        bridge.isForegroundSuppressed = { suppressionState.suppressed }

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

        suppressionState.suppressed = false
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

    func testNotificationClientRegistrationEncodesServerContractFields() throws {
        let registration = NotificationClientRegistration(
            clientId: "8B2F0C94-1D2E-4A3F-9C0B-1234567890AB",
            connectionId: "5A1C3D88-4E21-4F19-8D02-ABCDEF123456",
            deviceToken: "a1b2c3d4e5f600112233445566778899aabbccddeeff00112233445566778899",
            environment: .production,
            platform: "ios",
            deviceName: "iPhone 17 Pro",
            appVersion: "1.0.0",
            enabled: true
        )

        let data = try JSONEncoder().encode(registration)
        let jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(jsonObject.keys), [
            "clientId",
            "connectionId",
            "deviceToken",
            "environment",
            "platform",
            "deviceName",
            "appVersion",
            "enabled",
        ])
        XCTAssertEqual(jsonObject["clientId"] as? String, "8B2F0C94-1D2E-4A3F-9C0B-1234567890AB")
        XCTAssertEqual(jsonObject["connectionId"] as? String, "5A1C3D88-4E21-4F19-8D02-ABCDEF123456")
        XCTAssertEqual(jsonObject["deviceToken"] as? String, "a1b2c3d4e5f600112233445566778899aabbccddeeff00112233445566778899")
        XCTAssertEqual(jsonObject["environment"] as? String, "production")
        XCTAssertEqual(jsonObject["platform"] as? String, "ios")
        XCTAssertEqual(jsonObject["deviceName"] as? String, "iPhone 17 Pro")
        XCTAssertEqual(jsonObject["appVersion"] as? String, "1.0.0")
        XCTAssertEqual(jsonObject["enabled"] as? Bool, true)

        let decoded = try JSONDecoder().decode(NotificationClientRegistration.self, from: data)
        XCTAssertEqual(decoded, registration)
    }

    func testAPNsEnvironmentDetectorExtractsProvisioningProfileAndFallsBack() {
        let cmsHeader = Data([0x30, 0x82, 0x04, 0x00, 0x06, 0x09, 0x2A, 0x86])
        let cmsTrailer = Data([0xA0, 0x82, 0x01, 0x00, 0x30, 0x82])

        let devPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>AppIDName</key>
            <string>CPA</string>
            <key>Entitlements</key>
            <dict>
                <key>aps-environment</key>
                <string>development</string>
            </dict>
        </dict>
        </plist>
        """
        var devMobileProvision = cmsHeader
        devMobileProvision.append(Data(devPlist.utf8))
        devMobileProvision.append(cmsTrailer)

        XCTAssertEqual(APNsEnvironmentDetector.detect(mobileProvisionData: devMobileProvision), .sandbox)
        XCTAssertEqual(APNsEnvironmentDetector.detect(mobileProvisionData: devMobileProvision).rawValue, "sandbox")

        let prodPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Entitlements</key>
            <dict>
                <key>aps-environment</key>
                <string>production</string>
            </dict>
        </dict>
        </plist>
        """
        var prodMobileProvision = cmsHeader
        prodMobileProvision.append(Data(prodPlist.utf8))
        prodMobileProvision.append(cmsTrailer)

        XCTAssertEqual(APNsEnvironmentDetector.detect(mobileProvisionData: prodMobileProvision), .production)
        XCTAssertEqual(APNsEnvironmentDetector.detect(mobileProvisionData: prodMobileProvision).rawValue, "production")

        // Pure plist data without CMS wrapper also parses cleanly.
        let directPlist = """
        <plist version="1.0"><dict><key>aps-environment</key><string>production</string></dict></plist>
        """
        XCTAssertEqual(APNsEnvironmentDetector.detect(mobileProvisionData: Data(directPlist.utf8)), .production)

        // Missing or unparseable profile falls back cleanly according to build configuration.
        #if DEBUG
        let expectedFallback: APNsEnvironment = .sandbox
        #else
        let expectedFallback: APNsEnvironment = .production
        #endif
        XCTAssertEqual(APNsEnvironmentDetector.detect(mobileProvisionData: nil), expectedFallback)
        XCTAssertEqual(APNsEnvironmentDetector.detect(mobileProvisionData: Data("corrupted".utf8)), expectedFallback)
    }

    func testDesktopClientNotificationRPCsSendPayloadsAndDegradeSilently() async throws {
        // 1. Disconnected client returns silently without mutating state.
        let offlineClient = DesktopClient(connection: makeConnection(name: "Offline"))
        let registration = NotificationClientRegistration(
            clientId: "client-1",
            connectionId: "conn-1",
            deviceToken: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            environment: .sandbox,
            platform: "ios",
            deviceName: "iPhone",
            appVersion: "1.0.0",
            enabled: true
        )
        await offlineClient.registerNotificationClient(registration)
        await offlineClient.unregisterNotificationClient(clientId: "client-1", connectionId: "conn-1")
        XCTAssertEqual(offlineClient.state, .disconnected)

        // 2. Connected client sends expected RPC methods/args and silently ignores legacy rpc_error.
        let server = try MockNotificationRPCServer()
        defer { server.stop() }

        let connection = DesktopConnection(
            name: "Localhost",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop,
            isEnabled: true
        )
        let client = DesktopClient(connection: connection)
        defer { client.stop() }

        client.start()
        try await waitUntil("client connected and synced") {
            client.state == .connected && client.hasSynced
        }

        await client.registerNotificationClient(registration)
        await client.unregisterNotificationClient(clientId: "client-1", connectionId: "conn-1")

        let calls = server.recordedNotificationRPCs
        guard calls.count == 2 else {
            XCTFail("Expected 2 notification RPC calls, got \(calls.count)")
            return
        }
        XCTAssertEqual(calls[0].method, "notification:registerClient")
        XCTAssertEqual(calls[0].args.first?["clientId"]?.stringValue, "client-1")
        XCTAssertEqual(calls[0].args.first?["connectionId"]?.stringValue, "conn-1")
        XCTAssertEqual(calls[0].args.first?["deviceToken"]?.stringValue, registration.deviceToken)
        XCTAssertEqual(calls[0].args.first?["environment"]?.stringValue, "sandbox")
        XCTAssertEqual(calls[0].args.first?["platform"]?.stringValue, "ios")
        XCTAssertEqual(calls[0].args.first?["deviceName"]?.stringValue, "iPhone")
        XCTAssertEqual(calls[0].args.first?["appVersion"]?.stringValue, "1.0.0")
        XCTAssertEqual(calls[0].args.first?["enabled"]?.boolValue, true)

        XCTAssertEqual(calls[1].method, "notification:unregisterClient")
        XCTAssertEqual(calls[1].args.first?["clientId"]?.stringValue, "client-1")
        XCTAssertEqual(calls[1].args.first?["connectionId"]?.stringValue, "conn-1")

        // Simulate legacy desktop returning rpc_error for unknown notification methods.
        server.returnMethodNotFoundError = true
        await client.registerNotificationClient(registration)
        await client.unregisterNotificationClient(clientId: "client-1", connectionId: "conn-1")
        XCTAssertEqual(client.state, .connected)
        XCTAssertTrue(client.hasSynced)
    }

    func testNotificationDelegateBridgeBuffersColdLaunchTapBeforeWiringAndTrimsPayload() async throws {
        let bridge = NotificationDelegateBridge()
        let connectionId = UUID()
        var completionRan = false

        bridge.handleDidReceive(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: [
                "connectionId": "  \(connectionId.uuidString) \n",
                "sessionId": " sess-cold-launch ",
            ]
        ) {
            MainActor.assumeIsolated {
                completionRan = true
            }
        }
        XCTAssertTrue(completionRan)

        var opened: [(UUID, String)] = []
        bridge.onOpenSession = { cid, sid in
            opened.append((cid, sid))
        }
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.0, connectionId)
        XCTAssertEqual(opened.first?.1, "sess-cold-launch")
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
private final class MockUserNotificationManager: UserNotificationManaging {
    var onOpenSession: (@MainActor (_ connectionId: UUID, _ sessionId: String) -> Void)?
    var isForegroundSuppressed: (@MainActor () -> Bool)?
    var shouldGrantAuthorization = true
    var currentAuthorizationGranted = false
    private(set) var authRequestCount = 0
    private(set) var clearCount = 0

    func isAuthorized() async -> Bool {
        currentAuthorizationGranted
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        authRequestCount += 1
        currentAuthorizationGranted = shouldGrantAuthorization
        return shouldGrantAuthorization
    }

    func clearBadgeAndDeliveredNotifications() async {
        clearCount += 1
    }
}

@MainActor
private final class MockRemoteNotificationRegistrar: RemoteNotificationRegistering {
    private(set) var registerCount = 0

    func registerForRemoteNotifications() {
        registerCount += 1
    }
}

private final class MockNotificationRPCServer: @unchecked Sendable {
    struct RecordedRPC: Sendable {
        let method: String
        let args: [JSONValue]
    }

    private let queue = DispatchQueue(label: "test.mock-notification-rpc")
    private let listener: NWListener
    private let lock = NSLock()
    private var wsConnections: [NWConnection] = []
    private var _recordedNotificationRPCs: [RecordedRPC] = []
    private var _returnMethodNotFoundError = false
    private var _hangNotificationRPCs = false
    private(set) var port: UInt16 = 0

    var recordedNotificationRPCs: [RecordedRPC] {
        lock.withLock { _recordedNotificationRPCs }
    }

    var returnMethodNotFoundError: Bool {
        get { lock.withLock { _returnMethodNotFoundError } }
        set { lock.withLock { _returnMethodNotFoundError = newValue } }
    }

    var hangNotificationRPCs: Bool {
        get { lock.withLock { _hangNotificationRPCs } }
        set { lock.withLock { _hangNotificationRPCs = newValue } }
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
            let current = wsConnections
            wsConnections.removeAll()
            return current
        }
        for conn in conns {
            conn.cancel()
        }
        listener.cancel()
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
            for line in lines where line.lowercased().hasPrefix("sec-websocket-key:") {
                secKey = line.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces)
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
               let method = rpc["method"]?.stringValue
            {
                let args = rpc["args"]?.arrayValue ?? []
                if method == "notification:registerClient" || method == "notification:unregisterClient" {
                    lock.withLock {
                        _recordedNotificationRPCs.append(RecordedRPC(method: method, args: args))
                    }
                    if hangNotificationRPCs {
                        continue
                    }
                    if returnMethodNotFoundError {
                        let errReply: JSONValue = [
                            "type": "rpc_error",
                            "id": .string(id),
                            "error": ["message": "Method not found"],
                        ]
                        if let text = try? errReply.jsonString() {
                            sendWSText(conn: conn, text: text)
                        }
                        continue
                    }
                    let reply: JSONValue = ["type": "rpc_result", "id": .string(id), "result": ["ok": true]]
                    if let text = try? reply.jsonString() {
                        sendWSText(conn: conn, text: text)
                    }
                    continue
                }

                let result: JSONValue
                switch method {
                case "session:getActiveRuns", "session:listSessions":
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
