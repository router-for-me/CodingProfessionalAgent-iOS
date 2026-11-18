import Foundation

// Data shapes mirrored from the desktop app (CodingProfessionalAgent) RPC payloads.
// Decoding is intentionally lenient so newer desktop versions keep working.

struct RemoteProject: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String?
    let paths: [String]?
    let pinned: Bool
    let updatedAt: Double

    // Source folders in stable order without empty duplicates (desktop `getProjectPaths`).
    var allPaths: [String] {
        let values = paths?.isEmpty == false ? paths ?? [] : (path.map { [$0] } ?? [])
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !result.contains(trimmed) {
                result.append(trimmed)
            }
        }
        // A legacy primary path missing from the list still comes first.
        if let legacy = path?.trimmingCharacters(in: .whitespacesAndNewlines), !legacy.isEmpty, !result.contains(legacy) {
            result.insert(legacy, at: 0)
        }
        return result
    }

    var primaryPath: String? {
        allPaths.first
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, path, paths, pinned, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        path = try? container.decodeIfPresent(String.self, forKey: .path)
        paths = try? container.decodeIfPresent([String].self, forKey: .paths)
        pinned = (try? container.decodeIfPresent(Bool.self, forKey: .pinned)) ?? false
        updatedAt = (try? container.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? 0
    }
}

// Read state of a conversation (desktop `SessionUnreadState`).
enum UnreadState: Hashable, Sendable {
    case read
    case unread
    // The last run ended with an error.
    case error
}

struct RemoteSession: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    var projectId: String?
    var scheduleId: String?
    var parentSessionId: String?
    var branch: String?
    var baseBranch: String?
    var title: String
    var pinned: Bool
    var unread: UnreadState
    var archivedAt: Double?
    var firstPromptAt: Double?
    var modelId: String?
    var reasoningEffort: String?
    var speed: String?
    var workLocation: String?
    var worktreePath: String?
    var environmentId: String?
    // Kept verbatim so forks carry the desktop's worktree setup state unchanged.
    var worktreeSetup: JSONValue?
    var createdAt: Double
    var updatedAt: Double

    // Top-level conversations shown in the project list.
    var isVisibleInList: Bool {
        parentSessionId == nil && (archivedAt ?? 0) <= 0
    }

    var isUnread: Bool {
        unread != .read
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, scheduleId, parentSessionId, branch, baseBranch, title, pinned, unread, archivedAt, firstPromptAt
        case modelId, reasoningEffort, speed, workLocation, worktreePath, environmentId, worktreeSetup
        case createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectId = try? container.decodeIfPresent(String.self, forKey: .projectId)
        scheduleId = try? container.decodeIfPresent(String.self, forKey: .scheduleId)
        parentSessionId = try? container.decodeIfPresent(String.self, forKey: .parentSessionId)
        branch = try? container.decodeIfPresent(String.self, forKey: .branch)
        baseBranch = try? container.decodeIfPresent(String.self, forKey: .baseBranch)
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        pinned = (try? container.decodeIfPresent(Bool.self, forKey: .pinned)) ?? false
        // `true` or `"error"`; absent or `false` means read.
        switch try? container.decodeIfPresent(JSONValue.self, forKey: .unread) {
        case .bool(true)?:
            unread = .unread
        case .string("error")?:
            unread = .error
        default:
            unread = .read
        }
        archivedAt = try? container.decodeIfPresent(Double.self, forKey: .archivedAt)
        firstPromptAt = try? container.decodeIfPresent(Double.self, forKey: .firstPromptAt)
        modelId = try? container.decodeIfPresent(String.self, forKey: .modelId)
        reasoningEffort = try? container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        speed = try? container.decodeIfPresent(String.self, forKey: .speed)
        workLocation = try? container.decodeIfPresent(String.self, forKey: .workLocation)
        worktreePath = try? container.decodeIfPresent(String.self, forKey: .worktreePath)
        environmentId = try? container.decodeIfPresent(String.self, forKey: .environmentId)
        worktreeSetup = try? container.decodeIfPresent(JSONValue.self, forKey: .worktreeSetup)
        createdAt = (try? container.decodeIfPresent(Double.self, forKey: .createdAt)) ?? 0
        updatedAt = (try? container.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? createdAt
    }
}

struct RemoteModel: Decodable, Identifiable, Hashable, Sendable {
    struct ReasoningOption: Decodable, Hashable, Sendable {
        let id: String
        let fallbackLabel: String?
    }

    let id: String
    let label: String
    let supportsFast: Bool
    let reasoningLevels: [ReasoningOption]
    let contextWindow: Double
    // Input modalities, e.g. ["text", "image"].
    let input: [String]

    // Like the desktop's `getSupportsImages`, images are only sent to models that accept them.
    var supportsImages: Bool {
        input.contains("image")
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, supportsFast, reasoningLevels, contextWindow, input
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let rawLabel = (try? container.decodeIfPresent(String.self, forKey: .label)) ?? ""
        label = rawLabel.isEmpty ? id : rawLabel
        supportsFast = (try? container.decodeIfPresent(Bool.self, forKey: .supportsFast)) ?? false
        reasoningLevels = (try? container.decodeIfPresent([ReasoningOption].self, forKey: .reasoningLevels)) ?? []
        contextWindow = (try? container.decodeIfPresent(Double.self, forKey: .contextWindow)) ?? 0
        input = (try? container.decodeIfPresent([String].self, forKey: .input)) ?? []
    }
}

struct ActiveRun: Decodable, Hashable, Sendable {
    let sessionId: String
    let runId: String
    let clientId: String
    let status: String
    let updatedAt: Double

    init(sessionId: String, runId: String, clientId: String = "", status: String, updatedAt: Double = Date().milliseconds) {
        self.sessionId = sessionId
        self.runId = runId
        self.clientId = clientId
        self.status = status
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, runId, clientId, status, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        runId = (try? container.decodeIfPresent(String.self, forKey: .runId)) ?? ""
        clientId = (try? container.decodeIfPresent(String.self, forKey: .clientId)) ?? ""
        status = (try? container.decodeIfPresent(String.self, forKey: .status)) ?? "idle"
        updatedAt = (try? container.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? 0
    }
}

enum ContentBlock: Decodable, Hashable, Sendable {
    case text(String)
    case thinking(String)
    case image(mimeType: String, data: String)
    case toolCall(id: String, name: String, arguments: JSONValue)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, mimeType, data, id, name, arguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? ""
        switch type {
        case "text":
            self = .text((try? container.decodeIfPresent(String.self, forKey: .text)) ?? "")
        case "thinking":
            self = .thinking((try? container.decodeIfPresent(String.self, forKey: .thinking)) ?? "")
        case "image":
            self = .image(
                mimeType: (try? container.decodeIfPresent(String.self, forKey: .mimeType)) ?? "image/png",
                data: (try? container.decodeIfPresent(String.self, forKey: .data)) ?? ""
            )
        case "toolCall":
            self = .toolCall(
                id: (try? container.decodeIfPresent(String.self, forKey: .id)) ?? "",
                name: (try? container.decodeIfPresent(String.self, forKey: .name)) ?? "",
                arguments: (try? container.decodeIfPresent(JSONValue.self, forKey: .arguments)) ?? .null
            )
        default:
            self = .unknown
        }
    }
}

struct TokenUsage: Decodable, Hashable, Sendable {
    let totalTokens: Double

    private enum CodingKeys: String, CodingKey {
        case totalTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalTokens = (try? container.decodeIfPresent(Double.self, forKey: .totalTokens)) ?? 0
    }
}

// A single conversation entry (user, assistant, tool result or compaction summary).
struct ConversationEntry: Decodable, Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case user
        case assistant
        case toolResult
        case compaction
        case unknown
    }

    let id: String
    let kind: Kind
    var createdAt: Double
    var content: [ContentBlock]
    var status: String?
    var stopReason: String?
    let errorMessage: String?
    let usage: TokenUsage?
    let toolCallId: String?
    let toolName: String?
    let isError: Bool
    var interrupted: Bool
    let summary: String?
    var pendingStatus: String?
    // Skill chips of a user prompt; nil for older entries that predate references.
    var skillReferences: [SkillReference]?
    // When an assistant message finished, in epoch milliseconds.
    var completedAt: Double?
    // Time a resumed turn spent stopped, excluded from its elapsed time.
    var pausedMs: Double?
    // Display data of a tool result, e.g. the nested calls of a code mode cell (`nestedTools`).
    var displayMetadata: JSONValue?

    init(
        localUserEntryId id: String,
        text: String,
        createdAt: Double,
        pendingStatus: String? = nil,
        skillReferences: [SkillReference] = [],
        images: [PromptImage] = []
    ) {
        self.id = id
        self.kind = .user
        self.createdAt = createdAt
        // Like the desktop's `buildUserEntry`: the text block (when not empty), then the images.
        self.content = (text.isEmpty ? [] : [.text(text)]) + images.map { .image(mimeType: $0.mimeType, data: $0.data) }
        self.status = nil
        self.stopReason = nil
        self.errorMessage = nil
        self.usage = nil
        self.toolCallId = nil
        self.toolName = nil
        self.isError = false
        self.interrupted = false
        self.summary = nil
        self.pendingStatus = pendingStatus
        self.skillReferences = skillReferences
        self.completedAt = nil
        self.pausedMs = nil
        self.displayMetadata = nil
    }

    var text: String {
        content.compactMap { block in
            if case .text(let value) = block {
                return value
            }
            return nil
        }
        .joined(separator: "\n")
    }

    var isStreaming: Bool {
        status == "streaming"
    }

    // An edited user prompt (desktop `replaceUserEntryText`): one new text block first, images kept.
    func replacingText(_ text: String, skillReferences: [SkillReference], createdAt: Double) -> ConversationEntry {
        var entry = self
        entry.content = [.text(text)] + content.filter { block in
            if case .text = block {
                return false
            }
            return true
        }
        entry.skillReferences = skillReferences
        entry.createdAt = createdAt
        return entry
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, createdAt, content, status, stopReason, errorMessage, usage
        case toolCallId, toolName, isError, interrupted, summary, pendingStatus, skillReferences
        case completedAt, pausedMs, displayMetadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let rawKind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        kind = Kind(rawValue: rawKind) ?? .unknown
        createdAt = (try? container.decodeIfPresent(Double.self, forKey: .createdAt)) ?? 0
        content = (try? container.decodeIfPresent([ContentBlock].self, forKey: .content)) ?? []
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        stopReason = try? container.decodeIfPresent(String.self, forKey: .stopReason)
        errorMessage = try? container.decodeIfPresent(String.self, forKey: .errorMessage)
        usage = try? container.decodeIfPresent(TokenUsage.self, forKey: .usage)
        toolCallId = try? container.decodeIfPresent(String.self, forKey: .toolCallId)
        toolName = try? container.decodeIfPresent(String.self, forKey: .toolName)
        isError = (try? container.decodeIfPresent(Bool.self, forKey: .isError)) ?? false
        interrupted = (try? container.decodeIfPresent(Bool.self, forKey: .interrupted)) ?? false
        summary = try? container.decodeIfPresent(String.self, forKey: .summary)
        pendingStatus = try? container.decodeIfPresent(String.self, forKey: .pendingStatus)
        if (try? container.decodeNil(forKey: .skillReferences)) == false {
            // A damaged list shows plain text instead of guessing chips from the text.
            skillReferences = (try? container.decode([SkillReference].self, forKey: .skillReferences)) ?? []
        } else {
            skillReferences = nil
        }
        completedAt = try? container.decodeIfPresent(Double.self, forKey: .completedAt)
        pausedMs = try? container.decodeIfPresent(Double.self, forKey: .pausedMs)
        displayMetadata = try? container.decodeIfPresent(JSONValue.self, forKey: .displayMetadata)
    }
}

// A sub-agent launched by a conversation (desktop `SubAgentRecord`); its own messages live in the
// child session `sessionId`.
struct SubAgentRecord: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let color: String?
    let icon: String?
    let parentSessionId: String
    let sessionId: String
    let modelId: String
    let reasoningEffort: String?
    let speed: String?
    // "queued", "running", "completed", "error" or "aborted".
    let status: String
    let createdAt: Double
    let updatedAt: Double
    let parentToolCallId: String?
    let errorMessage: String?
    // Only sent with live state; the desktop does not store these.
    var completedAt: Double?
    var pausedMs: Double?

    var isInProgress: Bool {
        status == "running" || status == "queued"
    }

    // Session holding the sub-agent's conversation.
    var conversationId: String {
        sessionId.isEmpty ? id : sessionId
    }

    var statusTitle: String {
        switch status {
        case "queued": L10n.SubAgent.statusQueued
        case "running": L10n.SubAgent.statusRunning
        case "completed": L10n.SubAgent.statusCompleted
        case "error": L10n.SubAgent.statusError
        case "aborted": L10n.SubAgent.statusAborted
        default: status
        }
    }

    // Run time like the desktop sub-agent list: live while running, else until completion.
    func elapsedMs(now: Double) -> Double {
        let paused = max(pausedMs ?? 0, 0)
        let end = isInProgress ? now : completedAt ?? updatedAt
        return max(0, end - createdAt - paused)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, icon, parentSessionId, sessionId, modelId, reasoningEffort, speed, status
        case createdAt, updatedAt, parentToolCallId, errorMessage, completedAt, pausedMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? "Subagent"
        color = try? container.decodeIfPresent(String.self, forKey: .color)
        icon = try? container.decodeIfPresent(String.self, forKey: .icon)
        parentSessionId = (try? container.decodeIfPresent(String.self, forKey: .parentSessionId)) ?? ""
        sessionId = (try? container.decodeIfPresent(String.self, forKey: .sessionId)) ?? ""
        modelId = (try? container.decodeIfPresent(String.self, forKey: .modelId)) ?? ""
        reasoningEffort = try? container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        speed = try? container.decodeIfPresent(String.self, forKey: .speed)
        status = (try? container.decodeIfPresent(String.self, forKey: .status)) ?? "completed"
        createdAt = (try? container.decodeIfPresent(Double.self, forKey: .createdAt)) ?? 0
        updatedAt = (try? container.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? createdAt
        parentToolCallId = try? container.decodeIfPresent(String.self, forKey: .parentToolCallId)
        errorMessage = try? container.decodeIfPresent(String.self, forKey: .errorMessage)
        completedAt = try? container.decodeIfPresent(Double.self, forKey: .completedAt)
        pausedMs = try? container.decodeIfPresent(Double.self, forKey: .pausedMs)
    }
}

// One hit of the desktop chat search (`session:search`).
struct SessionSearchResult: Decodable, Hashable, Sendable {
    let sessionId: String
    let title: String
    let projectId: String?
    let branch: String?
    let updatedAt: Double
    // Title matches rank before content matches.
    let isTitleMatch: Bool
    // Text around a content match; nil for title matches.
    let snippet: String?

    init(sessionId: String, title: String, projectId: String?, branch: String?, updatedAt: Double, isTitleMatch: Bool = true, snippet: String? = nil) {
        self.sessionId = sessionId
        self.title = title
        self.projectId = projectId
        self.branch = branch
        self.updatedAt = updatedAt
        self.isTitleMatch = isTitleMatch
        self.snippet = snippet
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, title, projectId, branch, updatedAt, matchType, snippet
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        projectId = try? container.decodeIfPresent(String.self, forKey: .projectId)
        branch = try? container.decodeIfPresent(String.self, forKey: .branch)
        updatedAt = (try? container.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? 0
        isTitleMatch = (try? container.decodeIfPresent(String.self, forKey: .matchType)) != "content"
        snippet = try? container.decodeIfPresent(String.self, forKey: .snippet)
    }
}

struct AskOption: Codable, Hashable, Sendable {
    let title: String
    let description: String?
    let recommended: Bool?
}

// Pending question raised by the agent's `ask` tool on the desktop.
struct AskRequest: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let toolCallId: String
    let sessionId: String
    let question: String
    let options: [AskOption]
    let allowCustom: Bool
    let customPrompt: String?
    let allowSkip: Bool
    var countdownDeadline: Double?

    private enum CodingKeys: String, CodingKey {
        case id, toolCallId, sessionId, question, options, allowCustom, customPrompt, allowSkip, countdownDeadline
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        toolCallId = try container.decode(String.self, forKey: .toolCallId)
        sessionId = (try? container.decodeIfPresent(String.self, forKey: .sessionId)) ?? ""
        question = (try? container.decodeIfPresent(String.self, forKey: .question)) ?? ""
        options = (try? container.decodeIfPresent([AskOption].self, forKey: .options)) ?? []
        allowCustom = (try? container.decodeIfPresent(Bool.self, forKey: .allowCustom)) ?? false
        customPrompt = try? container.decodeIfPresent(String.self, forKey: .customPrompt)
        allowSkip = (try? container.decodeIfPresent(Bool.self, forKey: .allowSkip)) ?? false
        countdownDeadline = try? container.decodeIfPresent(Double.self, forKey: .countdownDeadline)
    }
}

enum AskDecision: Sendable {
    case selected(option: AskOption, index: Int)
    case custom(String)
    case skipped

    var json: JSONValue {
        switch self {
        case .selected(let option, let index):
            var optionObject: [String: JSONValue] = ["title": .string(option.title)]
            if let description = option.description {
                optionObject["description"] = .string(description)
            }
            if let recommended = option.recommended {
                optionObject["recommended"] = .bool(recommended)
            }
            return ["type": "selected", "option": .object(optionObject), "index": .number(Double(index))]
        case .custom(let text):
            return ["type": "custom", "text": .string(text)]
        case .skipped:
            return ["type": "skipped"]
        }
    }
}

// Defaults read from the desktop app settings (`app-state` key in the KV store).
struct RemoteDefaults: Sendable {
    var modelId = ""
    var reasoningLevel = ""
    var speed = "standard"
    var disabledModels: Set<String> = []
    var enabledReasoningLevels: [String: Set<String>] = [:]
    // Max context window set per model (`modelSettings.models[id].contextWindow`).
    var contextWindows: [String: Double] = [:]
    var modelOrder: [String] = []
    // Skill usage modes (`settings.skills`): "auto", "explicit" or "disabled".
    var skillDefaultMode = "auto"
    var skillModes: [String: String] = [:]
    var skillTrigger = SkillTrigger.dollar

    init() {}

    // Mirrors the desktop's `getEffectiveSkillMode`.
    func isSkillEnabled(_ name: String) -> Bool {
        let configured = skillModes[name]
        let mode = configured == nil || configured == "default" ? skillDefaultMode : configured
        return mode != "disabled"
    }

    init(appState: JSONValue) {
        guard let settings = appState["settings"] else { return }
        modelId = settings["modelId"]?.stringValue ?? ""
        reasoningLevel = settings["reasoningLevel"]?.stringValue ?? ""
        speed = settings["speed"]?.stringValue ?? "standard"
        if let modelSettings = settings["modelSettings"] {
            modelOrder = modelSettings["modelOrder"]?.arrayValue?.compactMap(\.stringValue) ?? []
            // Like the desktop, per-model overrides only apply when "enable all models" is off.
            let isAllEnabled = modelSettings["enableAll"]?.boolValue != false
            for (id, config) in modelSettings["models"]?.objectValue ?? [:] {
                if !isAllEnabled, let window = config["contextWindow"]?.doubleValue, window.isFinite, window > 0 {
                    contextWindows[id] = window.rounded(.down)
                }
                if config["enabled"]?.boolValue == false {
                    disabledModels.insert(id)
                }
                if let levels = config["enabledReasoningLevels"]?.arrayValue?.compactMap(\.stringValue), !levels.isEmpty {
                    enabledReasoningLevels[id] = Set(levels)
                }
            }
        }
        if let skills = settings["skills"] {
            skillDefaultMode = skills["defaultMode"]?.stringValue ?? "auto"
            skillTrigger = skills["trigger"]?.stringValue.flatMap(SkillTrigger.init(rawValue:)) ?? .dollar
            for (name, mode) in skills["skills"]?.objectValue ?? [:] {
                if let mode = mode.stringValue {
                    skillModes[name] = mode
                }
            }
        }
    }
}

// Symbol that opens the skill menu (`settings.skills.trigger`). Chips are still sent as `$name`.
enum SkillTrigger: String, Sendable {
    case dollar = "$"
    case hash = "#"
    case slash = "/"

    var unit: UInt16 {
        rawValue.utf16.first ?? 0x24
    }
}

// A skill discovered in the desktop's skill folders (a directory containing SKILL.md).
struct RemoteSkill: Identifiable, Hashable, Sendable {
    let name: String
    let description: String
    let filePath: String

    var id: String {
        name.lowercased()
    }

    var displayName: String {
        Self.displayName(for: name)
    }

    // Title-cases kebab/snake names for chip labels, like the desktop's `formatSkillDisplayName`.
    static func displayName(for name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

// Position of a `$name` skill chip in a prompt; `start` is a UTF-16 offset, as in JavaScript.
struct SkillReference: Decodable, Hashable, Sendable {
    let start: Int
    let name: String

    // Length of the `$name` token in UTF-16 code units.
    var length: Int {
        name.utf16.count + 1
    }

    var end: Int {
        start + length
    }

    var json: JSONValue {
        ["start": .number(Double(start)), "name": .string(name)]
    }
}

// Payload for `session:delegateRun`, which asks the desktop to host an agent run.
// Target of "continue in new worktree": the environment project to set up and the working branch.
struct WorktreeFork: Sendable {
    var environmentId: String?
    var branch: String
}

// Image sent with a prompt (desktop `ComposerImage`): base64 data for the model.
struct PromptImage: Hashable, Sendable {
    let data: String
    let mimeType: String
    let name: String

    var json: JSONValue {
        ["data": .string(data), "mimeType": .string(mimeType), "name": .string(name)]
    }
}

struct DelegateRunRequest: Sendable {
    var sessionId: String
    var text: String
    var projectId: String?
    var branch: String?
    var modelId: String?
    var reasoningEffort: String?
    var speed: String?
    var userEntryId: String
    var userEntryCreatedAt: Double
    var skillReferences: [SkillReference] = []
    var images: [PromptImage] = []
    // Resends this earlier user entry with the new text; the desktop drops everything after it.
    var editMessageId: String?
    // The desktop skips request ids it already ran, so edits pass a fresh one.
    var requestId: String?

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "requestId": .string(requestId ?? "req-\(userEntryId)"),
            "sessionId": .string(sessionId),
            "text": .string(text),
            "projectId": .optional(projectId),
            "branch": .optional(branch),
            "userEntryId": .string(userEntryId),
            "userEntryCreatedAt": .number(userEntryCreatedAt),
            // Always sent, like the desktop Web composer, so only chips are treated as skill references.
            "skillReferences": .array(skillReferences.map(\.json)),
        ]
        if let modelId {
            object["modelId"] = .string(modelId)
        }
        if let reasoningEffort {
            object["reasoningEffort"] = .string(reasoningEffort)
        }
        if let speed {
            object["speed"] = .string(speed)
        }
        // Omitted without images, like the desktop composer.
        if !images.isEmpty {
            object["images"] = .array(images.map(\.json))
        }
        if let editMessageId {
            object["editMessageId"] = .string(editMessageId)
        }
        return .object(object)
    }
}

// Target APNs environment sent to the desktop when registering an iOS push token.
enum APNsEnvironment: String, Codable, Hashable, Sendable {
    case production
    case sandbox
}

// Detects the active APNs environment from the app's embedded provisioning profile.
enum APNsEnvironmentDetector {
    static var fallbackEnvironment: APNsEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }

    static func detect(bundle: Bundle = .main) -> APNsEnvironment {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url)
        else {
            return fallbackEnvironment
        }
        return detect(mobileProvisionData: data)
    }

    static func detect(mobileProvisionData data: Data?) -> APNsEnvironment {
        guard let data, !data.isEmpty,
              let plistData = extractPlistData(from: data),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]
        else {
            return fallbackEnvironment
        }
        let entitlements = plist["Entitlements"] as? [String: Any]
        let apsEnvironment = (entitlements?["aps-environment"] as? String)
            ?? (plist["aps-environment"] as? String)
        guard let apsEnvironment else {
            return fallbackEnvironment
        }
        switch apsEnvironment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "development":
            return .sandbox
        case "production":
            return .production
        default:
            return fallbackEnvironment
        }
    }

    private static func extractPlistData(from data: Data) -> Data? {
        let startMarker = Data("<plist".utf8)
        let endMarker = Data("</plist>".utf8)
        if let startRange = data.range(of: startMarker),
           let endRange = data.range(of: endMarker, options: [], in: startRange.lowerBound..<data.endIndex)
        {
            return data.subdata(in: startRange.lowerBound..<endRange.upperBound)
        }
        return data
    }
}

// Payload for `notification:registerClient`, matching the desktop shared contract.
struct NotificationClientRegistration: Codable, Hashable, Sendable {
    let clientId: String
    let connectionId: String
    let deviceToken: String
    let environment: APNsEnvironment
    let platform: String
    let deviceName: String?
    let appVersion: String?
    let enabled: Bool

    init(
        clientId: String,
        connectionId: String,
        deviceToken: String,
        environment: APNsEnvironment,
        platform: String = "ios",
        deviceName: String? = nil,
        appVersion: String? = nil,
        enabled: Bool = true
    ) {
        self.clientId = clientId
        self.connectionId = connectionId
        self.deviceToken = deviceToken
        self.environment = environment
        self.platform = platform
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case clientId, connectionId, deviceToken, environment, platform, deviceName, appVersion, enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientId = try container.decode(String.self, forKey: .clientId)
        connectionId = try container.decode(String.self, forKey: .connectionId)
        deviceToken = try container.decode(String.self, forKey: .deviceToken)
        environment = try container.decode(APNsEnvironment.self, forKey: .environment)
        platform = (try? container.decodeIfPresent(String.self, forKey: .platform)) ?? "ios"
        deviceName = try? container.decodeIfPresent(String.self, forKey: .deviceName)
        appVersion = try? container.decodeIfPresent(String.self, forKey: .appVersion)
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
    }

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "clientId": .string(clientId),
            "connectionId": .string(connectionId),
            "deviceToken": .string(deviceToken),
            "environment": .string(environment.rawValue),
            "platform": .string(platform),
            "enabled": .bool(enabled),
        ]
        if let deviceName, !deviceName.isEmpty {
            object["deviceName"] = .string(deviceName)
        }
        if let appVersion, !appVersion.isEmpty {
            object["appVersion"] = .string(appVersion)
        }
        return .object(object)
    }
}
