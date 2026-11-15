import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

@MainActor
protocol UserNotificationManaging: AnyObject {
    var onOpenSession: (@MainActor (_ connectionId: UUID, _ sessionId: String) -> Void)? { get set }
    var isForegroundSuppressed: (@MainActor () -> Bool)? { get set }
    func requestAuthorizationIfNeeded() async -> Bool
    func addNotification(
        identifier: String,
        title: String,
        body: String,
        userInfo: [String: String],
        badgeCount: Int
    ) async
    func clearBadgeAndDeliveredNotifications() async
}

@MainActor
protocol ContinuedTurnTaskManaging: AnyObject {
    var onExpiration: (@MainActor () -> Void)? { get set }
    func startIfNeeded(title: String, subtitle: String)
    func update(title: String, subtitle: String, completedUnits: Int64, totalUnits: Int64)
    func finish(success: Bool)
    func beginGraceBackgroundTask()
    func endGraceBackgroundTask()
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

    func addNotification(
        identifier: String,
        title: String,
        body: String,
        userInfo: [String: String],
        badgeCount: Int
    ) async {
        guard !(isForegroundSuppressed?() ?? false) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.badge = NSNumber(value: badgeCount)
        content.userInfo = userInfo

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await center.add(request)
        guard !(isForegroundSuppressed?() ?? false) else { return }
        try? await center.setBadgeCount(badgeCount)
    }

    func clearBadgeAndDeliveredNotifications() async {
        center.removeAllDeliveredNotifications()
        try? await center.setBadgeCount(0)
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

// Production wrapper around iOS 26 BGContinuedProcessingTask and UIApplication transition background tasks.
@MainActor
final class SystemContinuedTurnTaskManager: ContinuedTurnTaskManaging {
    var onExpiration: (@MainActor () -> Void)?

    private var currentIdentifier: String?
    private var graceTaskId: UIBackgroundTaskIdentifier = .invalid
    #if !targetEnvironment(macCatalyst)
    private var activeTask: BGContinuedProcessingTask?
    #endif

    func startIfNeeded(title: String, subtitle: String) {
        guard currentIdentifier == nil else {
            update(title: title, subtitle: subtitle, completedUnits: 50, totalUnits: 1_000)
            return
        }
        #if !targetEnvironment(macCatalyst)
        let bundleId = Bundle.main.bundleIdentifier ?? "me.router-for.CodingProfessionalAgent"
        let identifier = "\(bundleId).turn.\(UUID().uuidString)"
        currentIdentifier = identifier

        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            guard let continuedTask = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            MainActor.assumeIsolated {
                guard let self, self.currentIdentifier == identifier else {
                    continuedTask.setTaskCompleted(success: true)
                    return
                }
                self.activeTask = continuedTask
                continuedTask.progress.totalUnitCount = 1_000
                continuedTask.progress.completedUnitCount = 50
                continuedTask.expirationHandler = { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.currentIdentifier == identifier else { return }
                        self.currentIdentifier = nil
                        self.activeTask = nil
                        continuedTask.setTaskCompleted(success: false)
                        self.onExpiration?()
                    }
                }
            }
        }
        guard registered else {
            currentIdentifier = nil
            return
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title,
            subtitle: subtitle
        )
        request.strategy = .queue
        request.requiredResources = []
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulator or restricted background conditions return an error here; fall back silently.
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            currentIdentifier = nil
        }
        #endif
    }

    func update(title: String, subtitle: String, completedUnits: Int64, totalUnits: Int64) {
        #if !targetEnvironment(macCatalyst)
        guard let activeTask else { return }
        activeTask.progress.totalUnitCount = totalUnits
        activeTask.progress.completedUnitCount = min(completedUnits, totalUnits)
        if activeTask.title != title || activeTask.subtitle != subtitle {
            activeTask.updateTitle(title, subtitle: subtitle)
        }
        #endif
    }

    func finish(success: Bool) {
        guard let identifier = currentIdentifier else { return }
        currentIdentifier = nil
        #if !targetEnvironment(macCatalyst)
        if let task = activeTask {
            activeTask = nil
            if success {
                task.progress.completedUnitCount = task.progress.totalUnitCount
            }
            task.setTaskCompleted(success: success)
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        #endif
    }

    func beginGraceBackgroundTask() {
        guard graceTaskId == .invalid else { return }
        var assignedId: UIBackgroundTaskIdentifier = .invalid
        assignedId = UIApplication.shared.beginBackgroundTask(withName: "CPA.TurnCompletion") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // End only the 30s transition grace lease; any active BGContinuedProcessingTask keeps running.
                if self.graceTaskId == assignedId, self.graceTaskId != .invalid {
                    UIApplication.shared.endBackgroundTask(self.graceTaskId)
                    self.graceTaskId = .invalid
                }
            }
        }
        graceTaskId = assignedId
    }

    func endGraceBackgroundTask() {
        guard graceTaskId != .invalid else { return }
        let id = graceTaskId
        graceTaskId = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }
}

// Coordinates foreground suppression, local turn-completion notifications, app icon badges,
// tap-to-open-session navigation, and iOS 26 continued background processing across all enabled hosts.
@MainActor
final class TurnNotificationCoordinator {
    private static let maxSessionTitleCharacters = 40
    private static let totalProgressUnits: Int64 = 1_000
    private static let initialProgressUnits: Int64 = 50
    private static let maxInFlightProgressUnits: Int64 = 950

    private let store: ConnectionStore
    private let router: Router
    private let defaults: UserDefaults
    private let notificationManager: UserNotificationManaging
    private let continuedTaskManager: ContinuedTurnTaskManaging

    private var storeObserverToken: UUID?
    private var clientListenerTokens: [UUID: (client: DesktopClient, token: UUID)] = [:]
    private var isAppActive: Bool
    private var isNotificationsEnabled: Bool
    private var suppressionEpoch = 0
    private var unreadBadgeCount = 0
    private var inFlightNotifications = 0
    private var notificationQueue: Task<Void, Never>?
    private var hasContinuedTask = false
    private var completedProgressUnits: Int64 = 0
    private var progressHeartbeatTask: Task<Void, Never>?
    private var hasRequestedAuthForActiveRun = false

    init(
        store: ConnectionStore,
        router: Router,
        defaults: UserDefaults = .standard,
        notificationManager: UserNotificationManaging? = nil,
        continuedTaskManager: ContinuedTurnTaskManaging? = nil,
        initialActive: Bool = true
    ) {
        self.store = store
        self.router = router
        self.defaults = defaults
        self.notificationManager = notificationManager ?? SystemUserNotificationManager()
        self.continuedTaskManager = continuedTaskManager ?? SystemContinuedTurnTaskManager()
        self.isAppActive = initialActive
        self.isNotificationsEnabled = (defaults.object(forKey: PreferenceKey.notifyOnTurnComplete) as? Bool) ?? true

        self.notificationManager.isForegroundSuppressed = { [weak self] in
            self?.isAppActive ?? true
        }
        self.notificationManager.onOpenSession = { [weak self] connectionId, sessionId in
            self?.handleNotificationTap(connectionId: connectionId, sessionId: sessionId)
        }
        self.continuedTaskManager.onExpiration = { [weak self] in
            self?.handleContinuedTaskExpired()
        }

        storeObserverToken = store.addChangeObserver { [weak self] in
            self?.syncClientListeners()
            self?.reconcileBackgroundExecution()
        }
        syncClientListeners()
        if initialActive {
            clearBadge()
        }
        reconcileBackgroundExecution()
    }

    func setAppActive(_ isActive: Bool) {
        guard isAppActive != isActive else { return }
        isAppActive = isActive
        if isActive {
            suppressionEpoch += 1
            continuedTaskManager.endGraceBackgroundTask()
            clearBadge()
        }
        reconcileBackgroundExecution()
    }

    func setNotificationsEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: PreferenceKey.notifyOnTurnComplete)
        guard isNotificationsEnabled != isEnabled else { return }
        isNotificationsEnabled = isEnabled
        if !isEnabled {
            suppressionEpoch += 1
        }
        reconcileBackgroundExecution()
    }

    static func formatNotificationBody(sessionTitle: String) -> String {
        let trimmed = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "任务已经完成"
        }
        let truncated = truncateTitle(trimmed)
        return "\(truncated) 任务已经完成"
    }

    private static func truncateTitle(_ trimmed: String) -> String {
        guard trimmed.count > maxSessionTitleCharacters else {
            return trimmed
        }
        return "\(trimmed.prefix(maxSessionTitleCharacters))..."
    }

    private func syncClientListeners() {
        let enabled = store.enabledClients
        let enabledIds = Set(enabled.map(\.id))

        for (id, entry) in clientListenerTokens where !enabledIds.contains(id) {
            entry.client.removeListener(entry.token)
            clientListenerTokens[id] = nil
        }

        for client in enabled where clientListenerTokens[client.id] == nil {
            let clientId = client.id
            let token = client.addListener { [weak self] event in
                self?.handleClientEvent(clientId: clientId, event: event)
            }
            clientListenerTokens[clientId] = (client: client, token: token)
        }
    }

    private func handleClientEvent(clientId: UUID, event: DesktopEvent) {
        switch event.kind {
        case DesktopEvent.turnCompleted:
            handleTurnCompleted(clientId: clientId, payload: event.payload)
        case DesktopEvent.localRunsChanged, "session:run-status", "session:meta-updated", "session:deleted", DesktopEvent.synced:
            reconcileBackgroundExecution()
        case "session:stream-event":
            bumpStreamActivityProgress()
        default:
            break
        }
    }

    private func isClientEligible(_ clientId: UUID) -> Bool {
        !isAppActive
            && isNotificationsEnabled
            && store.connections.first(where: { $0.id == clientId })?.isEnabled == true
            && store.client(for: clientId) != nil
    }

    private func enqueueNotificationOperation(_ operation: @escaping @MainActor () async -> Void) {
        let previous = notificationQueue
        notificationQueue = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    private func handleTurnCompleted(clientId: UUID, payload: JSONValue) {
        guard isClientEligible(clientId),
              let client = store.client(for: clientId),
              let sessionId = payload["sessionId"]?.stringValue,
              !sessionId.isEmpty
        else {
            reconcileBackgroundExecution()
            return
        }

        let payloadTitle = payload["sessionTitle"]?.stringValue ?? ""
        let rawTitle = payloadTitle.isEmpty ? (client.session(id: sessionId)?.title ?? "") : payloadTitle
        let body = Self.formatNotificationBody(sessionTitle: rawTitle)
        let title = notificationTitle(for: client)
        let runId = payload["runId"]?.stringValue ?? ""
        let identifier = "turn-completed-\(clientId.uuidString)-\(sessionId)-\(runId.isEmpty ? UUID().uuidString : runId)"
        let capturedEpoch = suppressionEpoch

        inFlightNotifications += 1
        enqueueNotificationOperation { [weak self] in
            guard let self else { return }
            defer {
                self.inFlightNotifications -= 1
                self.reconcileBackgroundExecution()
            }
            guard self.suppressionEpoch == capturedEpoch, self.isClientEligible(clientId) else {
                return
            }
            let authorized = await self.notificationManager.requestAuthorizationIfNeeded()
            guard authorized, self.suppressionEpoch == capturedEpoch, self.isClientEligible(clientId) else {
                return
            }
            self.unreadBadgeCount += 1
            let badge = self.unreadBadgeCount
            await self.notificationManager.addNotification(
                identifier: identifier,
                title: title,
                body: body,
                userInfo: [
                    "connectionId": clientId.uuidString,
                    "sessionId": sessionId,
                ],
                badgeCount: badge
            )
        }
    }

    private func notificationTitle(for client: DesktopClient) -> String {
        guard store.enabledClients.count > 1 else {
            return "CPA"
        }
        let hostName = client.connection.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return hostName.isEmpty ? "CPA" : hostName
    }

    private func handleNotificationTap(connectionId: UUID, sessionId: String) {
        suppressionEpoch += 1
        clearBadge()
        guard store.connections.first(where: { $0.id == connectionId })?.isEnabled == true,
              store.client(for: connectionId) != nil
        else {
            return
        }
        router.openThread(connectionId: connectionId, sessionId: sessionId)
    }

    private func clearBadge() {
        unreadBadgeCount = 0
        enqueueNotificationOperation { [weak self] in
            await self?.notificationManager.clearBadgeAndDeliveredNotifications()
        }
    }

    private func allActiveTopLevelSessions() -> [(sessionId: String, title: String)] {
        store.enabledClients.flatMap(\.activeTopLevelSessions)
    }

    private func summaryDisplay(for active: [(sessionId: String, title: String)]) -> (title: String, subtitle: String) {
        if active.count == 1 {
            let trimmed = active[0].title.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = trimmed.isEmpty ? "CPA" : Self.truncateTitle(trimmed)
            return (displayTitle, "正在后台运行…")
        }
        return ("CPA", "\(active.count) 个任务正在后台运行…")
    }

    private func reconcileBackgroundExecution() {
        guard isNotificationsEnabled else {
            stopBackgroundExecution(success: true)
            return
        }

        let active = allActiveTopLevelSessions()
        if active.isEmpty {
            // Wait until every queued notification has been handed to UNUserNotificationCenter before
            // releasing background execution, so iOS cannot suspend the process mid-enqueue.
            guard inFlightNotifications == 0 else { return }
            stopBackgroundExecution(success: true)
            return
        }

        if !hasRequestedAuthForActiveRun {
            hasRequestedAuthForActiveRun = true
            Task { @MainActor [weak self] in
                _ = await self?.notificationManager.requestAuthorizationIfNeeded()
            }
        }

        let summary = summaryDisplay(for: active)
        if !hasContinuedTask {
            if isAppActive {
                hasContinuedTask = true
                completedProgressUnits = Self.initialProgressUnits
                continuedTaskManager.startIfNeeded(title: summary.title, subtitle: summary.subtitle)
                startProgressHeartbeat()
            }
        } else {
            continuedTaskManager.update(
                title: summary.title,
                subtitle: summary.subtitle,
                completedUnits: completedProgressUnits,
                totalUnits: Self.totalProgressUnits
            )
        }

        if !isAppActive {
            continuedTaskManager.beginGraceBackgroundTask()
        }
    }

    private func bumpStreamActivityProgress() {
        guard hasContinuedTask else { return }
        let active = allActiveTopLevelSessions()
        guard !active.isEmpty else { return }
        completedProgressUnits = min(Self.maxInFlightProgressUnits, completedProgressUnits + 5)
        let summary = summaryDisplay(for: active)
        continuedTaskManager.update(
            title: summary.title,
            subtitle: summary.subtitle,
            completedUnits: completedProgressUnits,
            totalUnits: Self.totalProgressUnits
        )
    }

    private func startProgressHeartbeat() {
        progressHeartbeatTask?.cancel()
        progressHeartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, self.hasContinuedTask else { return }
                let active = self.allActiveTopLevelSessions()
                guard !active.isEmpty else { return }
                let remaining = Self.maxInFlightProgressUnits - self.completedProgressUnits
                let step = max(1, remaining / 40)
                self.completedProgressUnits = min(Self.maxInFlightProgressUnits, self.completedProgressUnits + step)
                let summary = self.summaryDisplay(for: active)
                self.continuedTaskManager.update(
                    title: summary.title,
                    subtitle: summary.subtitle,
                    completedUnits: self.completedProgressUnits,
                    totalUnits: Self.totalProgressUnits
                )
            }
        }
    }

    private func stopBackgroundExecution(success: Bool) {
        progressHeartbeatTask?.cancel()
        progressHeartbeatTask = nil
        if hasContinuedTask {
            hasContinuedTask = false
            completedProgressUnits = 0
            continuedTaskManager.finish(success: success)
        }
        continuedTaskManager.endGraceBackgroundTask()
    }

    private func handleContinuedTaskExpired() {
        stopBackgroundExecution(success: false)
    }
}
