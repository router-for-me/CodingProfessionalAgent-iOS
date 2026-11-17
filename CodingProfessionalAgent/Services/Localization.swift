import Foundation
import Observation
import os

// Supported app interface languages. `.system` resolves dynamically from OS preferred languages.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .system:
            L10n.Settings.languageSystem
        case .english:
            "English"
        case .simplifiedChinese:
            "简体中文"
        }
    }

    // Resolves the effective language (`en` or `zh-Hans`) from an ordered list of BCP-47 tags.
    static func resolveSystem(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        for rawTag in preferredLanguages {
            let normalized = rawTag
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
            guard !normalized.isEmpty else { continue }
            if normalized == "en" || normalized.hasPrefix("en-") {
                return .english
            }
            if normalized == "zh-hant"
                || normalized.hasPrefix("zh-hant-")
                || normalized.hasPrefix("zh-tw")
                || normalized.hasPrefix("zh-hk")
                || normalized.hasPrefix("zh-mo")
            {
                continue
            }
            if normalized == "zh"
                || normalized == "zh-hans"
                || normalized.hasPrefix("zh-hans-")
                || normalized.hasPrefix("zh-cn")
                || normalized.hasPrefix("zh-sg")
            {
                return .simplifiedChinese
            }
        }
        return .english
    }
}

// Observable controller coordinating language persistence, SwiftUI locale updates, and L10n bundle resolution.
@MainActor
@Observable
final class LocalizationManager {
    static let shared = LocalizationManager()
    static let languageDidChangeNotification = Notification.Name("AppLocalizationLanguageDidChange")

    private let defaults: UserDefaults
    private let syncsAppleLanguages: Bool
    private let syncsGlobalL10n: Bool
    @ObservationIgnored nonisolated(unsafe) private var localeObserver: NSObjectProtocol?

    private(set) var revision = 0

    var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            persist(language)
            if syncsGlobalL10n {
                L10n.configure(language: language)
                NotificationCenter.default.post(name: Self.languageDidChangeNotification, object: self)
            }
            revision += 1
        }
    }

    var resolvedLanguage: AppLanguage {
        switch language {
        case .system:
            AppLanguage.resolveSystem()
        case .english, .simplifiedChinese:
            language
        }
    }

    var effectiveLocale: Locale {
        switch resolvedLanguage {
        case .simplifiedChinese:
            Locale(identifier: "zh-Hans")
        case .english, .system:
            Locale(identifier: "en")
        }
    }

    init(
        defaults: UserDefaults = .standard,
        syncsAppleLanguages: Bool? = nil,
        syncsGlobalL10n: Bool? = nil
    ) {
        self.defaults = defaults
        let isStandard = defaults === UserDefaults.standard
        self.syncsAppleLanguages = syncsAppleLanguages ?? isStandard
        self.syncsGlobalL10n = syncsGlobalL10n ?? isStandard

        let raw = defaults.string(forKey: PreferenceKey.appLanguage)
        let initial = raw.flatMap(AppLanguage.init(rawValue:)) ?? .system
        self.language = initial

        if self.syncsGlobalL10n {
            L10n.configure(language: initial)
        }

        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.language == .system else { return }
                if self.syncsGlobalL10n {
                    L10n.configure(language: .system)
                    NotificationCenter.default.post(name: Self.languageDidChangeNotification, object: self)
                }
                self.revision += 1
            }
        }
    }

    deinit {
        if let localeObserver {
            NotificationCenter.default.removeObserver(localeObserver)
        }
    }

    private func persist(_ language: AppLanguage) {
        if language == .system {
            defaults.removeObject(forKey: PreferenceKey.appLanguage)
            if syncsAppleLanguages {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            }
        } else {
            defaults.set(language.rawValue, forKey: PreferenceKey.appLanguage)
            if syncsAppleLanguages {
                UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
            }
        }
    }
}

// Thread-safe localization lookup shared across Views, Models, and Services.
enum L10n {
    private final class BundleToken {}

    private struct State: @unchecked Sendable {
        var configuredLanguage: AppLanguage
        var preferredLanguagesOverride: [String]?
        var cachedBundles: [String: Bundle] = [:]

        init() {
            let raw = UserDefaults.standard.string(forKey: PreferenceKey.appLanguage)
            configuredLanguage = raw.flatMap(AppLanguage.init(rawValue:)) ?? .system
        }
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func configure(language: AppLanguage, preferredLanguagesOverride: [String]? = nil) {
        state.withLock { current in
            current.configuredLanguage = language
            current.preferredLanguagesOverride = preferredLanguagesOverride
        }
    }

    static var currentLanguage: AppLanguage {
        state.withLock { current in
            switch current.configuredLanguage {
            case .system:
                if let override = current.preferredLanguagesOverride {
                    return AppLanguage.resolveSystem(preferredLanguages: override)
                }
                return AppLanguage.resolveSystem()
            case .english, .simplifiedChinese:
                return current.configuredLanguage
            }
        }
    }

    static var currentLocale: Locale {
        switch currentLanguage {
        case .simplifiedChinese:
            Locale(identifier: "zh_CN")
        case .english, .system:
            Locale(identifier: "en_US")
        }
    }

    static func string(_ key: String) -> String {
        let bundle = activeBundle()
        return bundle.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    static func format(_ key: String, _ args: CVarArg...) -> String {
        let template = string(key)
        return String(format: template, locale: currentLocale, arguments: args)
    }

    private static func activeBundle() -> Bundle {
        let code = currentLanguage.rawValue
        return state.withLock { current in
            if let cached = current.cachedBundles[code] {
                return cached
            }
            let candidates = [Bundle.main, Bundle(for: BundleToken.self)]
            for base in candidates {
                if let path = base.path(forResource: code, ofType: "lproj"),
                   let bundle = Bundle(path: path)
                {
                    current.cachedBundles[code] = bundle
                    return bundle
                }
            }
            return Bundle.main
        }
    }

    // MARK: - Namespaced Keys

    enum Common {
        static var cancel: String { L10n.string("common.cancel") }
        static var save: String { L10n.string("common.save") }
        static var close: String { L10n.string("common.close") }
        static var done: String { L10n.string("common.done") }
        static var edit: String { L10n.string("common.edit") }
        static var ok: String { L10n.string("common.ok") }
        static var retry: String { L10n.string("common.retry") }
        static var refresh: String { L10n.string("common.refresh") }
        static var `default`: String { L10n.string("common.default") }
        static var defaultModel: String { L10n.string("common.defaultModel") }
        static var actionFailed: String { L10n.string("common.actionFailed") }
        static var title: String { L10n.string("common.title") }
        static var optional: String { L10n.string("common.optional") }
        static var required: String { L10n.string("common.required") }
        static var copiedToClipboard: String { L10n.string("common.copiedToClipboard") }
        static var comingSoon: String { L10n.string("common.comingSoon") }
        static var error: String { L10n.string("common.error") }
        static func errorWithDetail(_ prefix: String, _ detail: String) -> String {
            L10n.format("common.errorWithDetail", prefix, detail)
        }
    }

    enum Settings {
        static var title: String { L10n.string("settings.title") }
        static var connections: String { L10n.string("settings.connections") }
        static var disconnectAll: String { L10n.string("settings.disconnectAll") }
        static var addConnection: String { L10n.string("settings.addConnection") }
        static var composer: String { L10n.string("settings.composer") }
        static var collapseKeyboardAfterSend: String { L10n.string("settings.collapseKeyboardAfterSend") }
        static var showContextUsage: String { L10n.string("settings.showContextUsage") }
        static var followUpMode: String { L10n.string("settings.followUpMode") }
        static var behavior: String { L10n.string("settings.behavior") }
        static var notifyOnTurnComplete: String { L10n.string("settings.notifyOnTurnComplete") }
        static var wrapDiffLines: String { L10n.string("settings.wrapDiffLines") }
        static var liveActivityMode: String { L10n.string("settings.liveActivityMode") }
        static var general: String { L10n.string("settings.general") }
        static var language: String { L10n.string("settings.language") }
        static var languageSystem: String { L10n.string("settings.language.system") }
    }

    enum Connection {
        static var addDialogTitle: String { L10n.string("connection.addDialogTitle") }
        static var addDirect: String { L10n.string("connection.addDirect") }
        static var addTunnel: String { L10n.string("connection.addTunnel") }
        static var addTitle: String { L10n.string("connection.addTitle") }
        static var editTitle: String { L10n.string("connection.editTitle") }
        static var delete: String { L10n.string("connection.delete") }
        static var icon: String { L10n.string("connection.icon") }
        static var displayName: String { L10n.string("connection.displayName") }
        static var host: String { L10n.string("connection.host") }
        static var port: String { L10n.string("connection.port") }
        static var password: String { L10n.string("connection.password") }
        static var passwordPlaceholder: String { L10n.string("connection.passwordPlaceholder") }
        static var remoteServer: String { L10n.string("connection.remoteServer") }
        static var directHint: String { L10n.string("connection.directHint") }
        static var tunnelHint: String { L10n.string("connection.tunnelHint") }
        static var invalidHost: String { L10n.string("connection.invalidHost") }
        static func unsupportedEncryptedScheme(_ scheme: String) -> String {
            L10n.format("connection.unsupportedEncryptedScheme", scheme)
        }
        static var statusDisconnected: String { L10n.string("connection.status.disconnected") }
        static var statusConnecting: String { L10n.string("connection.status.connecting") }
        static var statusConnected: String { L10n.string("connection.status.connected") }
        static var iconCode: String { L10n.string("connection.icon.code") }
        static var iconTerminal: String { L10n.string("connection.icon.terminal") }
        static var iconLaptop: String { L10n.string("connection.icon.laptop") }
        static var iconDisplay: String { L10n.string("connection.icon.display") }
    }

    enum Tunnel {
        static var urlLabel: String { L10n.string("tunnel.urlLabel") }
        static var serviceSection: String { L10n.string("tunnel.serviceSection") }
        static var gatewayHint: String { L10n.string("tunnel.gatewayHint") }
        static var configChangedPrompt: String { L10n.string("tunnel.configChangedPrompt") }
        static var registering: String { L10n.string("tunnel.registering") }
        static func reconnectingAttempt(_ attempt: Int) -> String {
            L10n.format("tunnel.reconnectingAttempt", attempt)
        }
        static var retryConnect: String { L10n.string("tunnel.retryConnect") }
        static var syncingServers: String { L10n.string("tunnel.syncingServers") }
        static var noOnlineServers: String { L10n.string("tunnel.noOnlineServers") }
        static var onlineServersSection: String { L10n.string("tunnel.onlineServersSection") }
        static var added: String { L10n.string("tunnel.added") }
        static var searchAgain: String { L10n.string("tunnel.searchAgain") }
        static var connectAndSearch: String { L10n.string("tunnel.connectAndSearch") }
        static var switchGatewayAndSearch: String { L10n.string("tunnel.switchGatewayAndSearch") }
        static var detailPasswordHint: String { L10n.string("tunnel.detailPasswordHint") }
        static var infoSection: String { L10n.string("tunnel.infoSection") }
        static var addRemoteServerTitle: String { L10n.string("tunnel.addRemoteServerTitle") }
    }

    enum Home {
        static var settingsAccessibility: String { L10n.string("home.settingsAccessibility") }
        static var searchChatsAccessibility: String { L10n.string("home.searchChatsAccessibility") }
        static var emptyNoDesktopTitle: String { L10n.string("home.emptyNoDesktopTitle") }
        static var emptyNoDesktopMessage: String { L10n.string("home.emptyNoDesktopMessage") }
        static var emptyNoDesktopAction: String { L10n.string("home.emptyNoDesktopAction") }
        static var emptyAllDisconnectedTitle: String { L10n.string("home.emptyAllDisconnectedTitle") }
        static var emptyAllDisconnectedMessage: String { L10n.string("home.emptyAllDisconnectedMessage") }
        static var emptyAllDisconnectedAction: String { L10n.string("home.emptyAllDisconnectedAction") }
        static var pinnedSection: String { L10n.string("home.pinnedSection") }
        static var projectsSection: String { L10n.string("home.projectsSection") }
        static func syncing(_ name: String) -> String { L10n.format("home.syncing", name) }
        static var filterAll: String { L10n.string("home.filterAll") }
        static var chatsTitle: String { L10n.string("home.chatsTitle") }
        static var collapsed: String { L10n.string("home.collapsed") }
        static var expanded: String { L10n.string("home.expanded") }
        static var showLess: String { L10n.string("home.showLess") }
        static func showAll(_ count: Int) -> String { L10n.format("home.showAll", count) }
        static var newChat: String { L10n.string("home.newChat") }
        static var running: String { L10n.string("home.running") }
        static var unreadError: String { L10n.string("home.unreadError") }
        static var unread: String { L10n.string("home.unread") }
        static var accessibilityListSeparator: String { L10n.string("home.accessibilityListSeparator") }
        static var unpin: String { L10n.string("home.unpin") }
        static var pinChat: String { L10n.string("home.pinChat") }
        static var moveToProject: String { L10n.string("home.moveToProject") }
        static var noProject: String { L10n.string("home.noProject") }
        static var removeFromProject: String { L10n.string("home.removeFromProject") }
        static var renameChat: String { L10n.string("home.renameChat") }
        static var markRead: String { L10n.string("home.markRead") }
        static var markUnread: String { L10n.string("home.markUnread") }
        static var archiveChat: String { L10n.string("home.archiveChat") }
        static var copyWorkingDirectory: String { L10n.string("home.copyWorkingDirectory") }
        static var copySessionId: String { L10n.string("home.copySessionId") }
        static var copyDeepLink: String { L10n.string("home.copyDeepLink") }
        static var continueInNewChat: String { L10n.string("home.continueInNewChat") }
        static var forkFailed: String { L10n.string("home.forkFailed") }
        static var continueInNewWorktree: String { L10n.string("home.continueInNewWorktree") }
        static func clientConnecting(_ name: String) -> String { L10n.format("home.clientConnecting", name) }
        static func clientNotConnected(_ name: String) -> String { L10n.format("home.clientNotConnected", name) }
    }

    enum Search {
        static var noResults: String { L10n.string("search.noResults") }
        static var chats: String { L10n.string("search.chats") }
        static var quickActions: String { L10n.string("search.quickActions") }
        static var newChat: String { L10n.string("search.newChat") }
        static var openFolder: String { L10n.string("search.openFolder") }
        static var searchFiles: String { L10n.string("search.searchFiles") }
        static var placeholder: String { L10n.string("search.placeholder") }
        static var title: String { L10n.string("search.title") }
        static var branch: String { L10n.string("search.branch") }
    }

    enum Directory {
        static var up: String { L10n.string("directory.up") }
        static var noSubfolders: String { L10n.string("directory.noSubfolders") }
        static var filterPlaceholder: String { L10n.string("directory.filterPlaceholder") }
        static var title: String { L10n.string("directory.title") }
        static var home: String { L10n.string("directory.home") }
        static var root: String { L10n.string("directory.root") }
        static var goToPathEllipsis: String { L10n.string("directory.goToPathEllipsis") }
        static var showHidden: String { L10n.string("directory.showHidden") }
        static var selectThis: String { L10n.string("directory.selectThis") }
        static var goToPath: String { L10n.string("directory.goToPath") }
        static var go: String { L10n.string("directory.go") }
    }

    enum Project {
        static var name: String { L10n.string("project.name") }
        static var sourceFolders: String { L10n.string("project.sourceFolders") }
        static func removeSourceFolder(_ path: String) -> String { L10n.format("project.removeSourceFolder", path) }
        static var addFolder: String { L10n.string("project.addFolder") }
        static var remove: String { L10n.string("project.remove") }
        static var edit: String { L10n.string("project.edit") }
        static var pin: String { L10n.string("project.pin") }
        static var unpin: String { L10n.string("project.unpin") }
        static var removeConfirmGeneric: String { L10n.string("project.removeConfirmGeneric") }
        static func removeConfirmNamed(_ name: String) -> String { L10n.format("project.removeConfirmNamed", name) }
        static var removeConfirmMessage: String { L10n.string("project.removeConfirmMessage") }
        static var removeFailed: String { L10n.string("project.removeFailed") }
    }

    enum Worktree {
        static var branch: String { L10n.string("worktree.branch") }
        static var currentProject: String { L10n.string("worktree.currentProject") }
        static var noProjectPath: String { L10n.string("worktree.noProjectPath") }
        static var createHint: String { L10n.string("worktree.createHint") }
        static var withoutEnvTitle: String { L10n.string("worktree.withoutEnvTitle") }
        static var withoutEnvDetail: String { L10n.string("worktree.withoutEnvDetail") }
        static var environmentSection: String { L10n.string("worktree.environmentSection") }
        static var environmentFooter: String { L10n.string("worktree.environmentFooter") }
        static var title: String { L10n.string("worktree.title") }
        static var `continue`: String { L10n.string("worktree.continue") }
        static var forkFailedTitle: String { L10n.string("worktree.forkFailedTitle") }
    }

    enum NewThread {
        static var noDesktopTitle: String { L10n.string("newThread.noDesktopTitle") }
        static var noDesktopMessage: String { L10n.string("newThread.noDesktopMessage") }
        static var createFailedTitle: String { L10n.string("newThread.createFailedTitle") }
        static var noProject: String { L10n.string("newThread.noProject") }
        static var connectingDesktop: String { L10n.string("newThread.connectingDesktop") }
    }

    enum Advanced {
        static var title: String { L10n.string("advanced.title") }
        static var model: String { L10n.string("advanced.model") }
        static var reasoning: String { L10n.string("advanced.reasoning") }
        static var activeRunHint: String { L10n.string("advanced.activeRunHint") }
        static var speed: String { L10n.string("advanced.speed") }
    }

    enum Composer {
        static var askPlaceholder: String { L10n.string("composer.askPlaceholder") }
        static var fastModeEnabledNotice: String { L10n.string("composer.fastModeEnabledNotice") }
        static var fastModeDisabledNotice: String { L10n.string("composer.fastModeDisabledNotice") }
        static var addAttachment: String { L10n.string("composer.addAttachment") }
        static var send: String { L10n.string("composer.send") }
        static var stop: String { L10n.string("composer.stop") }
        static var resume: String { L10n.string("composer.resume") }
        static var fastTitle: String { L10n.string("composer.fastTitle") }
        static var fastSubtitleOn: String { L10n.string("composer.fastSubtitleOn") }
        static var fastSubtitleOff: String { L10n.string("composer.fastSubtitleOff") }
        static var compactTitle: String { L10n.string("composer.compactTitle") }
        static var compactSubtitle: String { L10n.string("composer.compactSubtitle") }
        static var modelTitle: String { L10n.string("composer.modelTitle") }
        static func modelSubtitleCurrent(_ current: String) -> String { L10n.format("composer.modelSubtitleCurrent", current) }
        static var modelSubtitleDefault: String { L10n.string("composer.modelSubtitleDefault") }
        static var commandKind: String { L10n.string("composer.commandKind") }
        static var skillKind: String { L10n.string("composer.skillKind") }
        static func skillAccessibility(_ name: String) -> String { L10n.format("composer.skillAccessibility", name) }
    }

    enum Attachments {
        static var unsupportedImagesModel: String { L10n.string("attachments.unsupportedImagesModel") }
        static func imageTooLarge(_ name: String) -> String { L10n.format("attachments.imageTooLarge", name) }
        static func fileTooLarge(_ name: String) -> String { L10n.format("attachments.fileTooLarge", name) }
        static func unsupportedImage(_ name: String) -> String { L10n.format("attachments.unsupportedImage", name) }
        static func unreadable(_ name: String) -> String { L10n.format("attachments.unreadable", name) }
        static var camera: String { L10n.string("attachments.camera") }
        static var photos: String { L10n.string("attachments.photos") }
        static var files: String { L10n.string("attachments.files") }
        static var photoFallbackName: String { L10n.string("attachments.photoFallbackName") }
        static var addErrorTitle: String { L10n.string("attachments.addErrorTitle") }
        static var cameraUnavailable: String { L10n.string("attachments.cameraUnavailable") }
        static var cameraPermissionDenied: String { L10n.string("attachments.cameraPermissionDenied") }
        static var removeImage: String { L10n.string("attachments.removeImage") }
        static func removeNamed(_ name: String) -> String { L10n.format("attachments.removeNamed", name) }
    }

    enum Thread {
        static var connectionUnavailableTitle: String { L10n.string("thread.connectionUnavailableTitle") }
        static var connectionUnavailableMessage: String { L10n.string("thread.connectionUnavailableMessage") }
        static var chatTitle: String { L10n.string("thread.chatTitle") }
        static func workOnDesktop(_ name: String) -> String { L10n.format("thread.workOnDesktop", name) }
        static func contextUsage(_ percent: Int) -> String { L10n.format("thread.contextUsage", percent) }
        static var editFailedMessage: String { L10n.string("thread.editFailedMessage") }
        static var renameTitle: String { L10n.string("thread.renameTitle") }
        static var pin: String { L10n.string("thread.pin") }
        static var rename: String { L10n.string("thread.rename") }
        static var copyThreadId: String { L10n.string("thread.copyThreadId") }
        static var archive: String { L10n.string("thread.archive") }
        static var deletedTitle: String { L10n.string("thread.deletedTitle") }
        static var deletedMessage: String { L10n.string("thread.deletedMessage") }
        static var cannotConnectTitle: String { L10n.string("thread.cannotConnectTitle") }
        static var loadFailedTitle: String { L10n.string("thread.loadFailedTitle") }
        static var compactRequested: String { L10n.string("thread.compactRequested") }
        static func modelSwitched(_ label: String) -> String { L10n.format("thread.modelSwitched", label) }
        static var modelUpdated: String { L10n.string("thread.modelUpdated") }
        static var scrollToBottom: String { L10n.string("thread.scrollToBottom") }
        static var loadingMessagesTitle: String { L10n.string("thread.loading.messagesTitle") }
        static func loadingConnectingTitle(_ name: String) -> String { L10n.format("thread.loading.connectingTitle", name) }
        static var loadingMessagesDetail: String { L10n.string("thread.loading.messagesDetail") }
        static var loadingWaitingDetail: String { L10n.string("thread.loading.waitingDetail") }
        static func loadingAccessibilityLabel(_ title: String, _ detail: String) -> String {
            L10n.format("thread.loading.accessibilityLabel", title, detail)
        }
        static func cannotConnectDetail(_ name: String) -> String { L10n.format("thread.cannotConnectDetail", name) }
    }

    enum Ask {
        static var stopAutoSelect: String { L10n.string("ask.stopAutoSelect") }
        static var customPlaceholder: String { L10n.string("ask.customPlaceholder") }
        static var sendAnswer: String { L10n.string("ask.sendAnswer") }
        static var skip: String { L10n.string("ask.skip") }
        static var title: String { L10n.string("ask.title") }
        static var later: String { L10n.string("ask.later") }
        static var recommended: String { L10n.string("ask.recommended") }
        static func countdownSeconds(_ seconds: Int) -> String { L10n.format("ask.countdownSeconds", seconds) }
        static var autoSelectNow: String { L10n.string("ask.autoSelectNow") }
        static var cancelCountdownFailed: String { L10n.string("ask.cancelCountdownFailed") }
        static var banner: String { L10n.string("ask.banner") }
    }

    enum SubAgent {
        static func pillQueuedLabel(_ name: String) -> String { L10n.format("subagent.pillQueuedLabel", name) }
        static var openHint: String { L10n.string("subagent.openHint") }
        static var queuedSuffix: String { L10n.string("subagent.queuedSuffix") }
        static var title: String { L10n.string("subagent.title") }
        static var fast: String { L10n.string("subagent.fast") }
        static var noMessages: String { L10n.string("subagent.noMessages") }
        static var statusQueued: String { L10n.string("subagent.status.queued") }
        static var statusRunning: String { L10n.string("subagent.status.running") }
        static var statusCompleted: String { L10n.string("subagent.status.completed") }
        static var statusError: String { L10n.string("subagent.status.error") }
        static var statusAborted: String { L10n.string("subagent.status.aborted") }
    }

    enum Panels {
        static var collapseAll: String { L10n.string("panels.collapseAll") }
        static var expandAll: String { L10n.string("panels.expandAll") }
        static var openFile: String { L10n.string("panels.openFile") }
        static var binaryChanged: String { L10n.string("panels.binaryChanged") }
        static var noDiff: String { L10n.string("panels.noDiff") }
        static func hunkLines(_ start: Int, _ end: Int) -> String { L10n.format("panels.hunkLines", start, end) }
        static var changes: String { L10n.string("panels.changes") }
        static var modified: String { L10n.string("panels.modified") }
        static var allFiles: String { L10n.string("panels.allFiles") }
        static var files: String { L10n.string("panels.files") }
        static var branch: String { L10n.string("panels.branch") }
        static var noProjectTitle: String { L10n.string("panels.noProjectTitle") }
        static var noProjectMessage: String { L10n.string("panels.noProjectMessage") }
        static var notGitRepo: String { L10n.string("panels.notGitRepo") }
        static var compareFailedTitle: String { L10n.string("panels.compareFailedTitle") }
        static var compareFailedMessage: String { L10n.string("panels.compareFailedMessage") }
        static var noChangesTitle: String { L10n.string("panels.noChangesTitle") }
        static var noChangesMessage: String { L10n.string("panels.noChangesMessage") }
        static var workingTreeChanges: String { L10n.string("panels.workingTreeChanges") }
        static var noMatchingFiles: String { L10n.string("panels.noMatchingFiles") }
        static var searchFiles: String { L10n.string("panels.searchFiles") }
        static var unableReadFile: String { L10n.string("panels.unableReadFile") }
        static var copyFilePath: String { L10n.string("panels.copyFilePath") }
    }

    enum Turn {
        static func processing(_ time: String) -> String { L10n.format("turn.processing", time) }
        static func interrupted(_ time: String) -> String { L10n.format("turn.interrupted", time) }
        static var interruptedBare: String { L10n.string("turn.interruptedBare") }
        static func completed(_ time: String) -> String { L10n.format("turn.completed", time) }
        static var completedBare: String { L10n.string("turn.completedBare") }
        static var generationFailed: String { L10n.string("turn.generationFailed") }
        static var collapseHistory: String { L10n.string("turn.collapseHistory") }
        static var expandHistory: String { L10n.string("turn.expandHistory") }
        static var collapseDetails: String { L10n.string("turn.collapseDetails") }
        static var expandDetails: String { L10n.string("turn.expandDetails") }
    }

    enum Tool {
        static var readingMemory: String { L10n.string("tool.readingMemory") }
        static var readMemory: String { L10n.string("tool.readMemory") }
        static var searchingMemories: String { L10n.string("tool.searchingMemories") }
        static var searchedMemories: String { L10n.string("tool.searchedMemories") }
        static var writingMemory: String { L10n.string("tool.writingMemory") }
        static var wroteMemory: String { L10n.string("tool.wroteMemory") }
        static var searchingWeb: String { L10n.string("tool.searchingWeb") }
        static var searchedWeb: String { L10n.string("tool.searchedWeb") }
        static var spawningAgent: String { L10n.string("tool.spawningAgent") }
        static var spawnedAgent: String { L10n.string("tool.spawnedAgent") }
        static var sendingMessage: String { L10n.string("tool.sendingMessage") }
        static var sentMessage: String { L10n.string("tool.sentMessage") }
        static var stoppingAgent: String { L10n.string("tool.stoppingAgent") }
        static var stoppedAgent: String { L10n.string("tool.stoppedAgent") }
        static var searchingSessions: String { L10n.string("tool.searchingSessions") }
        static var searchedSessions: String { L10n.string("tool.searchedSessions") }
        static var creatingSession: String { L10n.string("tool.creatingSession") }
        static var createdSession: String { L10n.string("tool.createdSession") }
        static func skillRead(_ name: String) -> String { L10n.format("tool.skillRead", name) }
        static func runningCommand(_ command: String) -> String { L10n.format("tool.runningCommand", command) }
        static var loadedCommand: String { L10n.string("tool.loadedCommand") }
        static func readingFile(_ name: String) -> String { L10n.format("tool.readingFile", name) }
        static func readFile(_ name: String) -> String { L10n.format("tool.readFile", name) }
        static func editingFile(_ name: String) -> String { L10n.format("tool.editingFile", name) }
        static func editedFile(_ name: String) -> String { L10n.format("tool.editedFile", name) }
        static func writingFile(_ name: String) -> String { L10n.format("tool.writingFile", name) }
        static func wroteFile(_ name: String) -> String { L10n.format("tool.wroteFile", name) }
        static var waitingAnswer: String { L10n.string("tool.waitingAnswer") }
        static func askingQuestion(_ question: String) -> String { L10n.format("tool.askingQuestion", question) }
        static var answered: String { L10n.string("tool.answered") }
        static func askedQuestion(_ question: String) -> String { L10n.format("tool.askedQuestion", question) }
        static var readingTodoList: String { L10n.string("tool.readingTodoList") }
        static var updatingTodoList: String { L10n.string("tool.updatingTodoList") }
        static var readTodoList: String { L10n.string("tool.readTodoList") }
        static var updatedTodoList: String { L10n.string("tool.updatedTodoList") }
        static func executingCode(_ description: String) -> String { L10n.format("tool.executingCode", description) }
        static func executedCode(_ description: String) -> String { L10n.format("tool.executedCode", description) }
        static var executingCodeGeneric: String { L10n.string("tool.executingCodeGeneric") }
        static var executedCodeGeneric: String { L10n.string("tool.executedCodeGeneric") }
        static func settingTitle(_ title: String) -> String { L10n.format("tool.settingTitle", title) }
        static func setTitle(_ title: String) -> String { L10n.format("tool.setTitle", title) }
        static var settingTitleGeneric: String { L10n.string("tool.settingTitleGeneric") }
        static var setTitleGeneric: String { L10n.string("tool.setTitleGeneric") }
        static func using(_ name: String) -> String { L10n.format("tool.using", name) }
        static func used(_ name: String) -> String { L10n.format("tool.used", name) }
    }

    enum Entry {
        static var compacted: String { L10n.string("entry.compacted") }
        static var steering: String { L10n.string("entry.steering") }
        static var queued: String { L10n.string("entry.queued") }
        static var copy: String { L10n.string("entry.copy") }
        static var shareEllipsis: String { L10n.string("entry.shareEllipsis") }
        static var skill: String { L10n.string("entry.skill") }
        static var editMessageAccessibility: String { L10n.string("entry.editMessageAccessibility") }
        static var image: String { L10n.string("entry.image") }
        static func imageNumbered(_ index: Int) -> String { L10n.format("entry.imageNumbered", index) }
        static var viewFullImage: String { L10n.string("entry.viewFullImage") }
    }

    enum Model {
        static var reasoningOff: String { L10n.string("model.reasoning.off") }
        static var reasoningMinimal: String { L10n.string("model.reasoning.minimal") }
        static var reasoningLow: String { L10n.string("model.reasoning.low") }
        static var reasoningMedium: String { L10n.string("model.reasoning.medium") }
        static var reasoningHigh: String { L10n.string("model.reasoning.high") }
        static var reasoningXhigh: String { L10n.string("model.reasoning.xhigh") }
        static var speedStandard: String { L10n.string("model.speed.standard") }
        static var speedFast: String { L10n.string("model.speed.fast") }
        static var workLocationLocal: String { L10n.string("model.workLocation.local") }
        static var workLocationWorktree: String { L10n.string("model.workLocation.worktree") }
        static var followUpQueue: String { L10n.string("model.followUp.queue") }
        static var followUpSteer: String { L10n.string("model.followUp.steer") }
        static var liveActivityPerComputer: String { L10n.string("model.liveActivity.perComputer") }
        static var liveActivityPerTask: String { L10n.string("model.liveActivity.perTask") }
        static var liveActivityOff: String { L10n.string("model.liveActivity.off") }
    }

    enum ErrorMessage {
        static var invalidAddress: String { L10n.string("error.desktop.invalidAddress") }
        static var notConnected: String { L10n.string("error.desktop.notConnected") }
        static var unauthorized: String { L10n.string("error.desktop.unauthorized") }
        static func http(_ code: Int) -> String { L10n.format("error.desktop.http", code) }
        static func timeout(_ method: String) -> String { L10n.format("error.desktop.timeout", method) }
        static var tunnelServerOffline: String { L10n.string("error.desktop.tunnelServerOffline") }
        static var tunnelServerDisconnected: String { L10n.string("error.desktop.tunnelServerDisconnected") }
        static var unableReadEntries: String { L10n.string("error.desktop.unableReadEntries") }
        static var cannotForkSubagent: String { L10n.string("error.desktop.cannotForkSubagent") }
        static var projectNotFound: String { L10n.string("error.desktop.projectNotFound") }
        static var unableReadProjects: String { L10n.string("error.desktop.unableReadProjects") }
        static var directoryNotFound: String { L10n.string("error.desktop.directoryNotFound") }
        static var unableReadFile: String { L10n.string("error.desktop.unableReadFile") }
        static var unableReadHomeDir: String { L10n.string("error.desktop.unableReadHomeDir") }
        static var rpcFailed: String { L10n.string("error.desktop.rpcFailed") }
        static var connectionFailed: String { L10n.string("error.desktop.connectionFailed") }
        static var cannotConnect: String { L10n.string("error.desktop.cannotConnect") }
        static var hostNotFound: String { L10n.string("error.desktop.hostNotFound") }
        static var connectionTimedOut: String { L10n.string("error.desktop.connectionTimedOut") }
        static var networkUnavailable: String { L10n.string("error.desktop.networkUnavailable") }
        static var connectionLost: String { L10n.string("error.desktop.connectionLost") }
        static var connectionDisabled: String { L10n.string("error.desktop.connectionDisabled") }
        static var editWhileRunning: String { L10n.string("error.desktop.editWhileRunning") }
        static var editMessageGone: String { L10n.string("error.desktop.editMessageGone") }
        static var threadGraceTimedOut: String { L10n.string("error.desktop.threadGraceTimedOut") }

        static var tunnelEmptyURL: String { L10n.string("error.tunnel.emptyURL") }
        static var tunnelMissingScheme: String { L10n.string("error.tunnel.missingScheme") }
        static func tunnelUnsupportedScheme(_ scheme: String) -> String { L10n.format("error.tunnel.unsupportedScheme", scheme) }
        static var tunnelEmptyAPIKey: String { L10n.string("error.tunnel.emptyAPIKey") }
        static var tunnelInvalidAPIKey: String { L10n.string("error.tunnel.invalidAPIKey") }
        static var tunnelInvalidUUID: String { L10n.string("error.tunnel.invalidUUID") }
        static var tunnelPayloadTooLarge: String { L10n.string("error.tunnel.payloadTooLarge") }
        static func tunnelMalformedFrame(_ detail: String) -> String { L10n.format("error.tunnel.malformedFrame", detail) }
        static func tunnelUnsupportedVersion(_ version: UInt8) -> String { L10n.format("error.tunnel.unsupportedVersion", Int(version)) }
        static var tunnelInvalidURL: String { L10n.string("error.tunnel.invalidURL") }
        static var tunnelUrlHasFragment: String { L10n.string("error.tunnel.urlHasFragment") }
        static var tunnelUrlHasQuery: String { L10n.string("error.tunnel.urlHasQuery") }
        static var tunnelUrlHasCredentials: String { L10n.string("error.tunnel.urlHasCredentials") }
        static var tunnelInvalidIPv6: String { L10n.string("error.tunnel.invalidIPv6") }
        static var tunnelInvalidPort: String { L10n.string("error.tunnel.invalidPort") }
        static var tunnelIPv6Brackets: String { L10n.string("error.tunnel.ipv6Brackets") }
        static var tunnelUrlHasQueryOrFragment: String { L10n.string("error.tunnel.urlHasQueryOrFragment") }
        static var tunnelInvalidHost: String { L10n.string("error.tunnel.invalidHost") }
        static var tunnelAPIKeyRevoked: String { L10n.string("error.tunnel.apiKeyRevoked") }
        static var tunnelAPIKeyInvalidOrUnauthorized: String { L10n.string("error.tunnel.apiKeyInvalidOrUnauthorized") }
        static var tunnelInvalidHandshake: String { L10n.string("error.tunnel.invalidHandshake") }
        static var tunnelConflictRetrying: String { L10n.string("error.tunnel.conflictRetrying") }
        static var tunnelWSRejected: String { L10n.string("error.tunnel.wsRejected") }
    }
}
