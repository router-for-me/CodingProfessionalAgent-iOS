import Foundation

enum ConnectionMode: String, Codable, Hashable, Sendable {
    case direct
    case tunnel
}

// A desktop app (CodingProfessionalAgent) reachable either directly or over CLIProxyAPI Tunnel.
struct DesktopConnection: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int
    var icon: ConnectionIcon
    var isEnabled = true
    var mode: ConnectionMode = .direct
    var tunnelBaseURL = ""
    var tunnelServerUUID = ""
    var tunnelServerName = ""

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int,
        icon: ConnectionIcon,
        isEnabled: Bool = true,
        mode: ConnectionMode = .direct,
        tunnelBaseURL: String = "",
        tunnelServerUUID: String = "",
        tunnelServerName: String = ""
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.icon = icon
        self.isEnabled = isEnabled
        self.mode = mode
        self.tunnelBaseURL = tunnelBaseURL
        self.tunnelServerUUID = tunnelServerUUID
        self.tunnelServerName = tunnelServerName
    }

    static func tunnel(
        id: UUID = UUID(),
        name: String,
        tunnelBaseURL: String,
        serverUUID: String,
        serverName: String,
        icon: ConnectionIcon,
        isEnabled: Bool = true
    ) -> DesktopConnection {
        DesktopConnection(
            id: id,
            name: name,
            host: "",
            port: 0,
            icon: icon,
            isEnabled: isEnabled,
            mode: .tunnel,
            tunnelBaseURL: tunnelBaseURL,
            tunnelServerUUID: serverUUID,
            tunnelServerName: serverName
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case port
        case icon
        case isEnabled
        case mode
        case tunnelBaseURL
        case tunnelServerUUID
        case tunnelServerName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 18080
        icon = try container.decode(ConnectionIcon.self, forKey: .icon)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        mode = try container.decodeIfPresent(ConnectionMode.self, forKey: .mode) ?? .direct
        tunnelBaseURL = try container.decodeIfPresent(String.self, forKey: .tunnelBaseURL) ?? ""
        tunnelServerUUID = try container.decodeIfPresent(String.self, forKey: .tunnelServerUUID) ?? ""
        tunnelServerName = try container.decodeIfPresent(String.self, forKey: .tunnelServerName) ?? ""
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        switch mode {
        case .direct:
            return host
        case .tunnel:
            let serverName = tunnelServerName.trimmingCharacters(in: .whitespacesAndNewlines)
            return serverName.isEmpty ? tunnelServerUUID : serverName
        }
    }

    // IPv6 literals must be wrapped in brackets inside URLs.
    private var urlHost: String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    var httpBaseURL: URL? {
        guard mode == .direct else { return nil }
        return URL(string: "http://\(urlHost):\(port)")
    }

    var webSocketURL: URL? {
        guard mode == .direct else { return nil }
        return URL(string: "ws://\(urlHost):\(port)/api/ws")
    }

    // Endpoint fields whose change requires reconnecting.
    func hasSameEndpoint(as other: DesktopConnection) -> Bool {
        guard mode == other.mode else { return false }
        switch mode {
        case .direct:
            return host == other.host && port == other.port
        case .tunnel:
            let lhsEndpoint = (try? TunnelProtocol.parseEndpoint(tunnelBaseURL).get().webSocketBaseURL) ?? tunnelBaseURL
            let rhsEndpoint = (try? TunnelProtocol.parseEndpoint(other.tunnelBaseURL).get().webSocketBaseURL) ?? other.tunnelBaseURL
            return lhsEndpoint == rhsEndpoint && tunnelServerUUID == other.tunnelServerUUID
        }
    }
}

enum ConnectionIcon: String, Codable, CaseIterable, Identifiable, Sendable {
    case code
    case terminal
    case laptop
    case display

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .code: "chevron.left.forwardslash.chevron.right"
        case .terminal: "apple.terminal"
        case .laptop: "laptopcomputer"
        case .display: "display"
        }
    }
}

struct ReasoningChoice: Identifiable, Hashable {
    let id: String
    let title: String

    static func title(for id: String, fallback: String? = nil) -> String {
        switch id.lowercased() {
        case "off": "关闭"
        case "minimal": "最低"
        case "low": "低"
        case "medium": "中"
        case "high": "高"
        case "xhigh": "极高"
        case "max": "Max"
        case "ultra": "Ultra"
        default: fallback ?? id
        }
    }
}

enum SpeedMode: String, CaseIterable, Identifiable {
    case standard
    case fast

    var id: Self { self }

    var title: String {
        switch self {
        case .standard: "标准"
        case .fast: "快速"
        }
    }
}

enum WorkLocation: String, CaseIterable, Identifiable {
    case local
    case worktree

    var id: Self { self }

    var title: String {
        switch self {
        case .local: "在本地工作"
        case .worktree: "在工作树中工作"
        }
    }
}

// How a message sent while a run is active is handled by the desktop.
enum FollowUpMode: String, CaseIterable, Identifiable {
    case queue
    case steer

    var id: Self { self }

    var title: String {
        switch self {
        case .queue: "排队"
        case .steer: "引导"
        }
    }
}

enum LiveActivityMode: String, CaseIterable, Identifiable {
    case perComputer
    case perTask
    case off

    var id: Self { self }

    var title: String {
        switch self {
        case .perComputer: "每台远程电脑一张卡片"
        case .perTask: "每个任务一张卡片"
        case .off: "关闭"
        }
    }
}

// UserDefaults keys for the local preferences on the settings screen.
enum PreferenceKey {
    static let collapseKeyboardAfterSend = "composer.collapseKeyboardAfterSend"
    static let showContextUsage = "composer.showContextUsage"
    static let followUpMode = "composer.followUpMode"
    static let wrapDiffLines = "behavior.wrapDiffLines"
    static let liveActivityMode = "behavior.liveActivityMode"
    static let lastTunnelBaseURL = "tunnel.lastBaseURL"
    static let tunnelClientUUID = "tunnel.clientUUID"
}
