import Foundation
import UIKit
import UserNotifications

@MainActor
protocol UserNotificationManaging: AnyObject {
    var onOpenSession: (@MainActor (_ connectionId: UUID, _ sessionId: String) -> Void)? { get set }
    var isForegroundSuppressed: (@MainActor () -> Bool)? { get set }
    func isAuthorized() async -> Bool
    func requestAuthorizationIfNeeded() async -> Bool
    func clearBadgeAndDeliveredNotifications() async
}

@MainActor
protocol RemoteNotificationRegistering: AnyObject {
    func registerForRemoteNotifications()
}

// Production wrapper around UNUserNotificationCenter and its delegate callbacks.
@MainActor
final class SystemUserNotificationManager: UserNotificationManaging {
    var onOpenSession: (@MainActor (_ connectionId: UUID, _ sessionId: String) -> Void)? {
        didSet { delegateBridge.onOpenSession = onOpenSession }
    }
    var isForegroundSuppressed: (@MainActor () -> Bool)? {
        didSet { delegateBridge.isForegroundSuppressed = isForegroundSuppressed }
    }

    private let center: UNUserNotificationCenter
    private let delegateBridge: NotificationDelegateBridge
    private var hasRequestedAuthorization = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        self.delegateBridge = NotificationDelegateBridge()
        center.delegate = delegateBridge
    }

    func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            guard !hasRequestedAuthorization else { return false }
            hasRequestedAuthorization = true
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        @unknown default:
            return false
        }
    }

    func clearBadgeAndDeliveredNotifications() async {
        center.removeAllDeliveredNotifications()
        try? await center.setBadgeCount(0)
    }
}

@MainActor
final class SystemRemoteNotificationRegistrar: RemoteNotificationRegistering {
    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

// Use explicit completion-handler delegate methods instead of Swift `async` witnesses so
// UIKit's completion handlers are never invoked on the cooperative background thread pool.
final class NotificationDelegateBridge: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    @MainActor var onOpenSession: (@MainActor (_ connectionId: UUID, _ sessionId: String) -> Void)?
    @MainActor var isForegroundSuppressed: (@MainActor () -> Bool)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        handleWillPresent(completionHandler: completionHandler)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleDidReceive(
            actionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo,
            completionHandler: completionHandler
        )
    }

    func handleWillPresent(
        completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let sendableCompletion = UnsafeSendableBox(completionHandler)
        runOnMainActor { [weak self] in
            let suppressed = self?.isForegroundSuppressed?() ?? true
            sendableCompletion.value(suppressed ? [] : [.banner, .list, .sound, .badge])
        }
    }

    func handleDidReceive(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any],
        completionHandler: @escaping () -> Void
    ) {
        let target = Self.parseOpenSessionTarget(actionIdentifier: actionIdentifier, userInfo: userInfo)
        let sendableCompletion = UnsafeSendableBox(completionHandler)
        runOnMainActor { [weak self] in
            defer { sendableCompletion.value() }
            if let target {
                self?.onOpenSession?(target.connectionId, target.sessionId)
            }
        }
    }

    private static func parseOpenSessionTarget(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> (connectionId: UUID, sessionId: String)? {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier,
              let rawConnectionId = userInfo["connectionId"] as? String,
              let connectionId = UUID(uuidString: rawConnectionId),
              let sessionId = userInfo["sessionId"] as? String,
              !sessionId.isEmpty
        else {
            return nil
        }
        return (connectionId, sessionId)
    }

    private func runOnMainActor(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                work()
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    work()
                }
            }
        }
    }
}

private struct UnsafeSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) {
        self.value = value
    }
}

// Coordinates APNs token registration, desktop client registration/unregistration sync,
// foreground notification suppression, badge clearing, and tap-to-open-session navigation.
@MainActor
final class TurnNotificationCoordinator {
    private static let apnsClientIdDefaultsKey = "notifications.apnsClientId"
    private static let apnsDeviceTokenDefaultsKey = "notifications.apnsDeviceToken"

    let clientId: String

    private let store: ConnectionStore
    private let router: Router
    private let defaults: UserDefaults
    private let notificationManager: UserNotificationManaging
    private let remoteRegistrar: RemoteNotificationRegistering
    private let environmentProvider: @Sendable () -> APNsEnvironment
    private let deviceName: String?
    private let appVersion: String?

    private var storeObserverToken: UUID?
    private var willRemoveObserverToken: UUID?
    private var clientListenerTokens: [UUID: (client: DesktopClient, token: UUID)] = [:]
    private var registrationTasks: [UUID: Task<Void, Never>] = [:]
    private var isAppActive: Bool
    private var isNotificationsEnabled: Bool
    private var deviceToken: String?

    init(
        store: ConnectionStore,
        router: Router,
        defaults: UserDefaults = .standard,
        notificationManager: UserNotificationManaging? = nil,
        remoteRegistrar: RemoteNotificationRegistering? = nil,
        environmentProvider: (@Sendable () -> APNsEnvironment)? = nil,
        deviceName: String? = nil,
        appVersion: String? = nil,
        initialActive: Bool = true
    ) {
        self.store = store
        self.router = router
        self.defaults = defaults
        self.notificationManager = notificationManager ?? SystemUserNotificationManager()
        self.remoteRegistrar = remoteRegistrar ?? SystemRemoteNotificationRegistrar()
        self.environmentProvider = environmentProvider ?? { APNsEnvironmentDetector.detect() }
        self.deviceName = deviceName ?? UIDevice.current.name
        self.appVersion = appVersion ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        self.isAppActive = initialActive
        self.isNotificationsEnabled = (defaults.object(forKey: PreferenceKey.notifyOnTurnComplete) as? Bool) ?? true

        if let existing = defaults.string(forKey: Self.apnsClientIdDefaultsKey),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            self.clientId = existing
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: Self.apnsClientIdDefaultsKey)
            self.clientId = generated
        }

        if let savedToken = defaults.string(forKey: Self.apnsDeviceTokenDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !savedToken.isEmpty
        {
            self.deviceToken = savedToken
        }

        self.notificationManager.isForegroundSuppressed = { [weak self] in
            self?.isAppActive ?? true
        }
        self.notificationManager.onOpenSession = { [weak self] connectionId, sessionId in
            self?.handleNotificationTap(connectionId: connectionId, sessionId: sessionId)
        }

        storeObserverToken = store.addChangeObserver { [weak self] in
            self?.syncClientListeners()
        }
        willRemoveObserverToken = store.addWillRemoveObserver { [weak self] connectionId in
            self?.handleConnectionRemoved(connectionId)
        }
        syncClientListeners()
        if initialActive {
            clearBadge()
        }
        refreshRemoteRegistration()
    }

    func updateDeviceToken(_ tokenData: Data) {
        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
        updateDeviceTokenHex(hex)
    }

    func updateDeviceTokenHex(_ hex: String) {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        defaults.set(normalized, forKey: Self.apnsDeviceTokenDefaultsKey)
        guard deviceToken != normalized else { return }
        deviceToken = normalized
        syncRegistrationToAllConnectedClients()
    }

    func setAppActive(_ isActive: Bool) {
        guard isAppActive != isActive else { return }
        isAppActive = isActive
        if isActive {
            clearBadge()
            refreshRemoteRegistration()
        }
    }

    func setNotificationsEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: PreferenceKey.notifyOnTurnComplete)
        guard isNotificationsEnabled != isEnabled else { return }
        isNotificationsEnabled = isEnabled
        if isEnabled {
            refreshRemoteRegistration()
        }
        if deviceToken != nil {
            syncRegistrationToAllConnectedClients()
        }
    }

    @discardableResult
    func handleConnectionRemoved(_ connectionId: UUID) -> Task<Void, Never>? {
        let client = clientListenerTokens[connectionId]?.client ?? store.client(for: connectionId)
        if let entry = clientListenerTokens.removeValue(forKey: connectionId) {
            entry.client.removeListener(entry.token)
        }
        let previous = registrationTasks.removeValue(forKey: connectionId)
        guard let client, client.state == .connected else {
            return nil
        }
        let apnsClientId = clientId
        let connectionIdString = connectionId.uuidString
        return Task { @MainActor in
            _ = await previous?.value
            guard client.state == .connected else { return }
            await client.unregisterNotificationClient(
                clientId: apnsClientId,
                connectionId: connectionIdString
            )
        }
    }

    private func refreshRemoteRegistration() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.isNotificationsEnabled {
                let authorized = await self.notificationManager.requestAuthorizationIfNeeded()
                guard self.isNotificationsEnabled, authorized else { return }
                self.remoteRegistrar.registerForRemoteNotifications()
            } else if await self.notificationManager.isAuthorized() {
                // Refresh APNs token silently when previously authorized so disabled preference still syncs.
                self.remoteRegistrar.registerForRemoteNotifications()
            }
        }
    }

    private func syncClientListeners() {
        let enabled = store.enabledClients
        let enabledIds = Set(enabled.map(\.id))

        for (id, entry) in clientListenerTokens where !enabledIds.contains(id) {
            entry.client.removeListener(entry.token)
            clientListenerTokens[id] = nil
            registrationTasks[id] = nil
        }

        for client in enabled where clientListenerTokens[client.id] == nil {
            let connectionId = client.id
            let token = client.addListener { [weak self] event in
                self?.handleClientEvent(connectionId: connectionId, event: event)
            }
            clientListenerTokens[connectionId] = (client: client, token: token)
            if client.state == .connected && client.hasSynced && deviceToken != nil {
                syncRegistration(for: client)
            }
        }
    }

    private func handleClientEvent(connectionId: UUID, event: DesktopEvent) {
        guard event.kind == DesktopEvent.synced else { return }
        guard let client = store.client(for: connectionId) else { return }
        syncRegistration(for: client)
    }

    private func syncRegistrationToAllConnectedClients() {
        guard deviceToken != nil else { return }
        for client in store.enabledClients where client.state == .connected && client.hasSynced {
            syncRegistration(for: client)
        }
    }

    private func syncRegistration(for client: DesktopClient) {
        guard let deviceToken, client.state == .connected, client.hasSynced else { return }
        let connectionId = client.id
        let registration = NotificationClientRegistration(
            clientId: clientId,
            connectionId: connectionId.uuidString,
            deviceToken: deviceToken,
            environment: environmentProvider(),
            platform: "ios",
            deviceName: deviceName,
            appVersion: appVersion,
            enabled: isNotificationsEnabled
        )
        let previous = registrationTasks[connectionId]
        registrationTasks[connectionId] = Task { @MainActor in
            _ = await previous?.value
            guard client.state == .connected else { return }
            await client.registerNotificationClient(registration)
        }
    }

    private func handleNotificationTap(connectionId: UUID, sessionId: String) {
        clearBadge()
        guard store.connections.first(where: { $0.id == connectionId })?.isEnabled == true,
              store.client(for: connectionId) != nil
        else {
            return
        }
        router.openThread(connectionId: connectionId, sessionId: sessionId)
    }

    private func clearBadge() {
        Task { @MainActor [weak self] in
            await self?.notificationManager.clearBadgeAndDeliveredNotifications()
        }
    }
}
