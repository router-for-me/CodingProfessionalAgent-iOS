import Network
import SwiftUI
import UIKit
import XCTest
@testable import CodingProfessionalAgent

@MainActor
final class LocalizationTests: XCTestCase {
    func testSystemLanguageResolutionRules() {
        XCTAssertEqual(AppLanguage.resolveSystem(preferredLanguages: ["zh-Hans-CN", "en-US"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolveSystem(preferredLanguages: ["zh-CN"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolveSystem(preferredLanguages: ["zh-SG"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolveSystem(preferredLanguages: ["zh"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolveSystem(preferredLanguages: ["zh_Hans_CN"]), .simplifiedChinese)

        // Traditional Chinese must NOT map to Simplified Chinese; falls back to English.
        XCTAssertEqual(AppLanguage.resolveSystem(preferredLanguages: ["zh-Hant-TW"]), .english)
        XCTAssertEqual(AppLanguage.resolveSystem(preferredLanguages: ["zh-TW"]), .english)
        XCTAssertEqual(AppLanguage.resolveSystem(preferredLanguages: ["zh-HK"]), .english)
        XCTAssertEqual(AppLanguage.resolveSystem(preferredLanguages: ["zh-MO"]), .english)
        XCTAssertEqual(AppLanguage.resolveSystem(preferredLanguages: ["zh-Hant-HK", "zh-Hans-CN"]), .simplifiedChinese)

        XCTAssertEqual(AppLanguage.resolveSystem(preferredLanguages: ["en-US", "zh-Hans-CN"]), .english)
        XCTAssertEqual(AppLanguage.resolveSystem(preferredLanguages: ["ja-JP", "fr-FR"]), .english)
        XCTAssertEqual(AppLanguage.resolveSystem(preferredLanguages: []), .english)
    }

    func testManagerPersistenceAndLaunchRestoration() throws {
        let suiteName = "LocalizationTests.Persist.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = LocalizationManager(defaults: defaults, syncsAppleLanguages: false, syncsGlobalL10n: false)
        XCTAssertEqual(manager.language, .system)

        manager.language = .simplifiedChinese
        XCTAssertEqual(defaults.string(forKey: PreferenceKey.appLanguage), "zh-Hans")
        XCTAssertEqual(manager.effectiveLocale.identifier, "zh-Hans")

        let relaunchedChinese = LocalizationManager(defaults: defaults, syncsAppleLanguages: false, syncsGlobalL10n: false)
        XCTAssertEqual(relaunchedChinese.language, .simplifiedChinese)

        manager.language = .english
        XCTAssertEqual(defaults.string(forKey: PreferenceKey.appLanguage), "en")
        XCTAssertEqual(manager.effectiveLocale.identifier, "en")

        let relaunchedEnglish = LocalizationManager(defaults: defaults, syncsAppleLanguages: false, syncsGlobalL10n: false)
        XCTAssertEqual(relaunchedEnglish.language, .english)

        manager.language = .system
        XCTAssertNil(defaults.string(forKey: PreferenceKey.appLanguage))
    }

    func testCompiledLocalizationBundlesContainExpectedEnglishAndChineseStrings() throws {
        let previousLanguage = LocalizationManager.shared.language
        defer {
            LocalizationManager.shared.language = previousLanguage
            L10n.configure(language: previousLanguage)
        }

        // Verify InfoPlist.xcstrings compiled to both .lproj bundles.
        for code in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: code, ofType: "lproj"), "Missing \(code).lproj")
            let lproj = try XCTUnwrap(Bundle(path: path))
            let cameraDesc = lproj.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist")
            let localNetDesc = lproj.localizedString(forKey: "NSLocalNetworkUsageDescription", value: nil, table: "InfoPlist")
            XCTAssertNotEqual(cameraDesc, "NSCameraUsageDescription")
            XCTAssertNotEqual(localNetDesc, "NSLocalNetworkUsageDescription")
        }

        // Verify L10n lookup switches cleanly between en and zh-Hans.
        L10n.configure(language: .english)
        XCTAssertEqual(L10n.Settings.title, "Settings")
        XCTAssertEqual(L10n.Settings.language, "Language")
        XCTAssertEqual(L10n.Settings.languageSystem, "System Default")
        XCTAssertEqual(L10n.Composer.askPlaceholder, "Ask CPA")
        XCTAssertEqual(L10n.ErrorMessage.unauthorized, "Incorrect password")
        XCTAssertEqual(L10n.ErrorMessage.tunnelServerOffline, "Remote desktop is offline")
        XCTAssertEqual(L10n.Turn.processing("12s"), "Processed 12s")
        XCTAssertEqual(L10n.Turn.completed("4m"), "Completed 4m")
        XCTAssertEqual(SpeedMode.fast.title, "Fast")
        XCTAssertEqual(FollowUpMode.steer.title, "Steer")
        XCTAssertEqual(LiveActivityMode.perComputer.title, "One card per computer")

        L10n.configure(language: .simplifiedChinese)
        XCTAssertEqual(L10n.Settings.title, "设置")
        XCTAssertEqual(L10n.Settings.language, "语言")
        XCTAssertEqual(L10n.Settings.languageSystem, "跟随系统")
        XCTAssertEqual(L10n.Composer.askPlaceholder, "向 CPA 提问")
        XCTAssertEqual(L10n.ErrorMessage.unauthorized, "密码错误")
        XCTAssertEqual(L10n.ErrorMessage.tunnelServerOffline, "远程桌面端不在线")
        XCTAssertEqual(L10n.Turn.processing("12s"), "已处理 12s")
        XCTAssertEqual(L10n.Turn.completed("4m"), "已完成 4m")
        XCTAssertEqual(SpeedMode.fast.title, "快速")
        XCTAssertEqual(FollowUpMode.steer.title, "引导")
        XCTAssertEqual(LiveActivityMode.perComputer.title, "每台远程电脑一张卡片")
    }

    func testSettingsViewHotSwitchesLanguageAtRuntimeWithoutDismissing() throws {
        let manager = LocalizationManager.shared
        let previousLanguage = manager.language
        defer {
            manager.language = previousLanguage
        }
        manager.language = .english

        let suiteName = "LocalizationTests.Settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ConnectionStore(defaults: defaults, persistsCredentials: false)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        struct LiveSettingsHost: View {
            @State private var localization = LocalizationManager.shared
            let store: ConnectionStore

            var body: some View {
                SettingsView()
                    .environment(store)
                    .environment(\.locale, localization.effectiveLocale)
            }
        }

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 860)
        window.rootViewController = UIHostingController(rootView: LiveSettingsHost(store: store))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        func visibleTexts() -> [String] {
            var results: [String] = []
            var visited = Set<ObjectIdentifier>()
            func collectAccessibility(_ object: AnyObject) {
                let oid = ObjectIdentifier(object)
                guard visited.insert(oid).inserted else { return }
                if let label = (object as? NSObject)?.accessibilityLabel, !label.isEmpty {
                    results.append(label)
                }
                if let view = object as? UIView {
                    guard !view.isHidden, view.alpha > 0.01 else { return }
                    if let label = view as? UILabel, let text = label.text, !text.isEmpty {
                        results.append(text)
                    }
                    for subview in view.subviews {
                        collectAccessibility(subview)
                    }
                }
                if let container = object as? NSObject {
                    let count = container.accessibilityElementCount()
                    if count != NSNotFound && count > 0 {
                        for index in 0..<count {
                            if let child = container.accessibilityElement(at: index) as AnyObject? {
                                collectAccessibility(child)
                            }
                        }
                    }
                }
            }
            collectAccessibility(window)
            return results
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.layoutIfNeeded()
        let englishTexts = visibleTexts()
        XCTAssertTrue(englishTexts.contains("Settings"), "Expected English 'Settings', got: \(englishTexts)")
        XCTAssertTrue(englishTexts.contains("General"), "Expected English 'General', got: \(englishTexts)")
        XCTAssertTrue(englishTexts.contains("Behavior"), "Expected English 'Behavior', got: \(englishTexts)")
        XCTAssertTrue(englishTexts.contains("Task completion notifications"), "Expected English 'Task completion notifications', got: \(englishTexts)")
        XCTAssertTrue(englishTexts.contains("Queue"), "Expected English 'Queue', got: \(englishTexts)")
        XCTAssertTrue(englishTexts.contains("One card per computer"), "Expected English 'One card per computer', got: \(englishTexts)")
        XCTAssertTrue(englishTexts.contains("English"), "Expected English 'English', got: \(englishTexts)")

        // Switch language at runtime while SettingsView remains mounted.
        manager.language = .simplifiedChinese
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.layoutIfNeeded()
        let chineseTexts = visibleTexts()
        XCTAssertTrue(chineseTexts.contains("设置"), "Expected Chinese '设置', got: \(chineseTexts)")
        XCTAssertTrue(chineseTexts.contains("通用"), "Expected Chinese '通用', got: \(chineseTexts)")
        XCTAssertTrue(chineseTexts.contains("行为"), "Expected Chinese '行为', got: \(chineseTexts)")
        XCTAssertTrue(chineseTexts.contains("任务完成通知"), "Expected Chinese '任务完成通知', got: \(chineseTexts)")
        XCTAssertTrue(chineseTexts.contains("排队"), "Expected Chinese '排队', got: \(chineseTexts)")
        XCTAssertTrue(chineseTexts.contains("每台远程电脑一张卡片"), "Expected Chinese '每台远程电脑一张卡片', got: \(chineseTexts)")
        XCTAssertTrue(chineseTexts.contains("简体中文"), "Expected Chinese '简体中文', got: \(chineseTexts)")

        // Switch back to English immediately.
        manager.language = .english
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.layoutIfNeeded()
        let restoredTexts = visibleTexts()
        XCTAssertTrue(restoredTexts.contains("Settings"), "Expected restored 'Settings', got: \(restoredTexts)")
        XCTAssertTrue(restoredTexts.contains("General"), "Expected restored 'General', got: \(restoredTexts)")
        XCTAssertTrue(restoredTexts.contains("Behavior"), "Expected restored 'Behavior', got: \(restoredTexts)")
        XCTAssertTrue(restoredTexts.contains("Task completion notifications"), "Expected restored 'Task completion notifications', got: \(restoredTexts)")
        XCTAssertTrue(restoredTexts.contains("Queue"), "Expected restored 'Queue', got: \(restoredTexts)")
        XCTAssertTrue(restoredTexts.contains("One card per computer"), "Expected restored 'One card per computer', got: \(restoredTexts)")
        XCTAssertTrue(restoredTexts.contains("English"), "Expected restored 'English', got: \(restoredTexts)")
    }

    func testDesktopClientRefreshesFailedErrorStateOnRuntimeLanguageSwitch() async throws {
        let manager = LocalizationManager.shared
        let previousLanguage = manager.language
        defer {
            manager.language = previousLanguage
        }
        manager.language = .english

        let server = try MockUnauthorizedHTTPServer()
        defer { server.stop() }

        let connection = DesktopConnection(
            id: UUID(),
            name: "Auth Mac",
            host: "127.0.0.1",
            port: Int(server.port),
            icon: .laptop,
            isEnabled: true
        )
        KeychainStore.setPassword("wrong-pw", for: connection.id)
        defer { KeychainStore.deletePassword(for: connection.id) }

        let client = DesktopClient(connection: connection)
        defer { client.stop() }
        client.start()

        let deadline = Date().addingTimeInterval(3.0)
        while client.state != .failed("Incorrect password") && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(client.state, .failed("Incorrect password"))

        manager.language = .simplifiedChinese
        XCTAssertEqual(client.state, .failed("密码错误"))

        manager.language = .english
        XCTAssertEqual(client.state, .failed("Incorrect password"))
    }
}

private final class MockUnauthorizedHTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.mock-unauth-http")
    private let listener: NWListener
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            }
        }
        listener.newConnectionHandler = { conn in
            conn.start(queue: self.queue)
            self.read(conn: conn, buffer: Data())
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
    }

    func stop() {
        listener.cancel()
    }

    private func read(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
            var next = buffer
            if let data { next.append(data) }
            if let range = next.range(of: Data("\r\n\r\n".utf8)) {
                let headText = String(decoding: next[..<range.lowerBound], as: UTF8.self)
                let body: Data
                let status: String
                if headText.hasPrefix("GET /api/auth/status") {
                    status = "200 OK"
                    body = Data(#"{"required":true,"authenticated":false}"#.utf8)
                } else {
                    status = "401 Unauthorized"
                    body = Data(#"{"error":"unauthorized"}"#.utf8)
                }
                let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(response.utf8) + body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    conn.cancel()
                })
                return
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.read(conn: conn, buffer: next)
        }
    }
}
