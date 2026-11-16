import os
import SwiftUI
import UIKit
import UserNotifications

// Captures APNs registration callbacks and buffers tokens delivered before SwiftUI wires the coordinator.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "me.router-for.CodingProfessionalAgent",
        category: "APNs"
    )
    private var pendingDeviceToken: Data?

    var onDeviceToken: (@MainActor (Data) -> Void)? {
        didSet {
            if let pendingDeviceToken, let onDeviceToken {
                self.pendingDeviceToken = nil
                onDeviceToken(pendingDeviceToken)
            }
        }
    }

    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Attach the shared UNUserNotificationCenter delegate before launch finishes so cold-launch taps are never missed.
        UNUserNotificationCenter.current().delegate = NotificationDelegateBridge.shared
        return true
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationDelegateBridge.shared
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        if let onDeviceToken {
            onDeviceToken(deviceToken)
        } else {
            pendingDeviceToken = deviceToken
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // APNs registration may fail on simulators or restricted environments; log the error without any token data.
        Self.logger.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }
}

@main
struct CodingProfessionalAgentApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var router: Router
    @State private var store: ConnectionStore
    @State private var notificationCoordinator: TurnNotificationCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PreferenceKey.notifyOnTurnComplete) private var notifyOnTurnComplete = true

    init() {
        let router = Router()
        let store = ConnectionStore()
        let coordinator = TurnNotificationCoordinator(
            store: store,
            router: router,
            initialActive: UIApplication.shared.applicationState == .active
        )
        _router = State(initialValue: router)
        _store = State(initialValue: store)
        _notificationCoordinator = State(initialValue: coordinator)
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(router)
                .environment(store)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            wireAppDelegateIfNeeded()
            notificationCoordinator.setAppActive(phase == .active)
            if phase == .active {
                store.wake()
            }
        }
        .onChange(of: notifyOnTurnComplete) { _, isEnabled in
            notificationCoordinator.setNotificationsEnabled(isEnabled)
        }
    }

    private func wireAppDelegateIfNeeded() {
        guard appDelegate.onDeviceToken == nil else { return }
        let coordinator = notificationCoordinator
        appDelegate.onDeviceToken = { tokenData in
            coordinator.updateDeviceToken(tokenData)
        }
    }
}
