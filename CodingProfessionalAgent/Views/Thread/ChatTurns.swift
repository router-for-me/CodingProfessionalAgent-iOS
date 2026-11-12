import Foundation

// Conversation grouped like the desktop's folded activity view (`groupChatTurns`): each user request
// is followed by one assistant turn that merges all assistant stages and mid-turn compactions.
enum ChatTurn: Identifiable {
    case user(ConversationEntry)
    case compaction(ConversationEntry)
    case assistant(AssistantTurn)

    var id: String {
        switch self {
        case .user(let entry), .compaction(let entry):
            entry.id
        case .assistant(let turn):
            turn.id
        }
    }

    static func group(_ entries: [ConversationEntry], isRunActive: Bool) -> [ChatTurn] {
        var turns: [ChatTurn] = []
        var startedAt: Double?
        var pausedMs: Double?
        var buffer: [ConversationEntry] = []
        var bufferResults: [String: [ConversationEntry]] = [:]
        // Assistant message that receives the tool results directly following it.
        var resultOwner: String?

        func flush() {
            guard let first = buffer.first else { return }
            if buffer.contains(where: { $0.kind == .assistant }) || startedAt != nil {
                turns.append(.assistant(AssistantTurn(
                    items: buffer,
                    toolResults: bufferResults,
                    startedAt: startedAt ?? first.createdAt,
                    pausedMs: pausedMs ?? first.pausedMs ?? 0
                )))
            } else {
                // Compactions outside any request stay standalone separators.
                turns += buffer.map { .compaction($0) }
            }
            buffer.removeAll()
            bufferResults.removeAll()
            pausedMs = nil
        }

        for entry in entries {
            // Like the desktop projection, only results right after an assistant message belong to it.
            if entry.kind == .toolResult {
                if let resultOwner {
                    bufferResults[resultOwner, default: []].append(entry)
                }
                continue
            }
            resultOwner = nil
            switch entry.kind {
            case .assistant:
                buffer.append(entry)
                resultOwner = entry.id
            case .compaction:
                buffer.append(entry)
            case .user:
                flush()
                // Queued or steering prompts have not started a turn yet.
                if entry.pendingStatus == nil {
                    startedAt = entry.createdAt
                    pausedMs = (entry.pausedMs ?? 0) > 0 ? entry.pausedMs : nil
                } else {
                    startedAt = nil
                    pausedMs = nil
                }
                turns.append(.user(entry))
            case .toolResult, .unknown:
                break
            }
        }
        flush()

        guard isRunActive else { return turns }
        // The running turn is the last assistant turn; pending prompts queued behind it are skipped.
        search: for index in turns.indices.reversed() {
            switch turns[index] {
            case .assistant(var turn):
                turn.isLive = true
                turns[index] = .assistant(turn)
                return turns
            case .user(let entry) where entry.pendingStatus != nil:
                continue
            default:
                break search
            }
        }
        if case .user(let entry) = turns.last, entry.pendingStatus != nil {
            return turns
        }
        // The run started but has not produced an assistant message yet.
        turns.append(.assistant(AssistantTurn(items: [], startedAt: pendingStartedAt(turns), pausedMs: 0, isLive: true)))
        return turns
    }

    private static func pendingStartedAt(_ turns: [ChatTurn]) -> Double {
        for turn in turns.reversed() {
            switch turn {
            case .user(let entry):
                return entry.createdAt
            case .assistant(let turn):
                return turn.startedAt
            case .compaction:
                continue
            }
        }
        return Date().milliseconds
    }
}

// Outcome of an assistant turn, merged over its messages like the desktop `mergeAssistantTurn`.
enum TurnStatus {
    case running
    case done
    case aborted
    case error
}

struct AssistantTurn {
    // Assistant and compaction entries in order.
    let items: [ConversationEntry]
    // Tool results directly following each assistant message, by message id.
    var toolResults: [String: [ConversationEntry]] = [:]
    let startedAt: Double
    let pausedMs: Double
    var isLive = false

    var id: String {
        items.first?.id ?? "pending-assistant-turn"
    }

    var messages: [ConversationEntry] {
        items.filter { $0.kind == .assistant }
    }

    var status: TurnStatus {
        if isLive {
            return .running
        }
        if messages.contains(where: { $0.status == "error" }) {
            return .error
        }
        if messages.contains(where: { $0.status == "aborted" || $0.stopReason == "aborted" || $0.interrupted }) {
            return .aborted
        }
        return .done
    }

    var errorMessage: String? {
        messages.last { ($0.errorMessage ?? "").isEmpty == false }?.errorMessage
    }

    // Paused time of the request, else the longest one recorded on its messages.
    var effectivePausedMs: Double {
        if pausedMs > 0 {
            return pausedMs
        }
        return messages.compactMap(\.pausedMs).filter(\.isFinite).max().map { max($0, 0) } ?? 0
    }

    // Latest completion of any message or of any tool result following it.
    var completedAt: Double? {
        var latest: Double?
        for message in messages {
            let candidates = [message.completedAt] + (toolResults[message.id] ?? []).map(\.createdAt)
            for value in candidates.compactMap({ $0 }) where value.isFinite {
                latest = max(latest ?? value, value)
            }
        }
        return latest
    }

    // Results of a message's tool calls by normalized call id; the first result of a call wins.
    func results(of message: ConversationEntry) -> [String: ConversationEntry] {
        var results: [String: ConversationEntry] = [:]
        for result in toolResults[message.id] ?? [] {
            let key = ToolActivity.normalizedId(result.toolCallId ?? "")
            if results[key] == nil {
                results[key] = result
            }
        }
        return results
    }

    // Elapsed time shown in the turn header, in milliseconds.
    func elapsedMs(now: Double, completedAt: Double?) -> Double {
        if isLive {
            return max(0, now - startedAt - effectivePausedMs)
        }
        guard let completedAt else { return 0 }
        return max(0, completedAt - startedAt - effectivePausedMs)
    }

    // Header text: "已处理 29s" while running, "已完成 4m 26s" or "执行中断，已执行 10s" afterwards.
    func headerTitle(now: Double, completedAt: Double?) -> String {
        let elapsed = elapsedMs(now: now, completedAt: completedAt)
        let time = Self.formatElapsed(elapsed)
        let hasDuration = isLive || (completedAt != nil && elapsed >= 1000)
        switch status {
        case .running:
            return "已处理 \(time)"
        case .aborted, .error:
            return hasDuration ? "执行中断，已执行 \(time)" : "执行中断"
        case .done:
            return hasDuration ? "已完成 \(time)" : "已完成"
        }
    }

    // Body text or a non-skill tool; skill reads alone keep the turn folded.
    var hasVisibleContent: Bool {
        for message in messages {
            for block in message.content {
                switch block {
                case .text(let text):
                    if !text.isBlank {
                        return true
                    }
                case .toolCall(_, let name, let arguments):
                    if ToolActivity.isSpawnAgent(name) || !ToolActivity.isSkillRead(name: name, arguments: arguments) {
                        return true
                    }
                default:
                    break
                }
            }
        }
        return false
    }

    // Final reply after the last tool or thinking block of the last message; shown when folded.
    var trailingText: String {
        guard let blocks = messages.last?.content, !blocks.isEmpty else { return "" }
        var start = 0
        for (index, block) in blocks.enumerated() {
            switch block {
            case .toolCall, .thinking:
                start = index + 1
            default:
                break
            }
        }
        let chunks = blocks[start...].compactMap { block -> String? in
            if case .text(let text) = block, !text.isEmpty {
                return text
            }
            return nil
        }
        if !chunks.isEmpty {
            return chunks.joined()
        }
        for block in blocks.reversed() {
            if case .text(let text) = block, !text.isBlank {
                return text
            }
        }
        return ""
    }

    // Messages split at mid-turn compactions.
    var sections: [TurnSection] {
        var sections: [TurnSection] = []
        var current: [ConversationEntry] = []
        for item in items {
            if item.kind == .compaction {
                if !current.isEmpty {
                    sections.append(.messages(current))
                    current = []
                }
                sections.append(.compaction(item))
            } else {
                current.append(item)
            }
        }
        if !current.isEmpty {
            sections.append(.messages(current))
        }
        return sections
    }

    // Formats durations like the desktop `formatElapsed`: "45s", "4m 26s", "1h 0m 5s".
    static func formatElapsed(_ ms: Double) -> String {
        // Clamped so corrupt timestamps cannot overflow the integer conversion.
        let totalSeconds = Int(min(max(0, ms.isFinite ? ms : 0) / 1000, 1e15))
        let seconds = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let totalHours = totalMinutes / 60
        let hours = totalHours % 24
        let totalDays = totalHours / 24
        let years = totalDays / 365
        let months = totalDays % 365 / 30
        let days = totalDays % 365 % 30

        var parts: [String] = []
        if years > 0 {
            parts.append("\(years)y")
        }
        if months > 0 {
            parts.append("\(months)mo")
        }
        if days > 0 {
            parts.append("\(days)d")
        }
        if hours > 0 || !parts.isEmpty {
            parts.append("\(hours)h")
        }
        if minutes > 0 || !parts.isEmpty {
            parts.append("\(minutes)m")
        }
        parts.append("\(seconds)s")
        return parts.joined(separator: " ")
    }
}

enum TurnSection {
    case messages([ConversationEntry])
    case compaction(ConversationEntry)
}

// A tool call with its result, as shown in the folded activity lines.
struct ToolCallItem {
    let id: String
    let name: String
    let arguments: JSONValue
    let result: ConversationEntry?
    let isRunning: Bool

    var summary: ToolActivitySummary {
        ToolActivity.summarize(name: name, arguments: arguments, isRunning: isRunning)
    }
}

// Visible pieces of a turn: reply text, a run of consecutive tool calls folded into one line, or
// sub-agent launches shown as badges.
enum ActivitySegment: Identifiable {
    case text(index: Int, String)
    case tools(index: Int, [ToolCallItem])
    case spawns(index: Int, [ToolCallItem])

    // Segments only grow at the end while streaming, so positions are stable identities.
    var id: Int {
        switch self {
        case .text(let index, _), .tools(let index, _), .spawns(let index, _):
            index
        }
    }

    // Mirrors the desktop `groupCompactActivityParts`: thinking is never shown and does not split a
    // run of tools, only reply text does; sub-agent launches are folded separately. `toolDetails`
    // are live details of running tools, by normalized call id.
    static func build(
        messages: [ConversationEntry],
        of turn: AssistantTurn,
        isLive: Bool,
        toolDetails: [String: JSONValue] = [:]
    ) -> [ActivitySegment] {
        enum Part {
            case gap
            case text(String)
            case tool(ToolCallItem)
        }

        var seen = Set<String>()
        for message in messages {
            for case .toolCall(let id, _, _) in message.content {
                seen.insert(ToolActivity.normalizedId(id))
            }
        }
        let parts: [Part] = messages.flatMap { message in
            let results = turn.results(of: message)
            return message.content.flatMap { block -> [Part] in
                switch block {
                case .text(let text):
                    return [text.isBlank ? .gap : .text(text)]
                case .toolCall(let id, let name, let arguments):
                    let key = ToolActivity.normalizedId(id)
                    let result = results[key]
                    let item = ToolCallItem(id: id, name: name, arguments: arguments, result: result, isRunning: result == nil && isLive)
                    // Sub-agents launched inside a code mode cell get badges of their own
                    // (desktop `expandNestedSubagentParts`).
                    let nested = nestedSpawns(details: toolDetails[key], result: result, isLive: isLive)
                        .filter { seen.insert(ToolActivity.normalizedId($0.id)).inserted }
                    return [.tool(item)] + nested.map { .tool($0) }
                case .thinking, .image, .unknown:
                    return [.gap]
                }
            }
        }

        var segments: [ActivitySegment] = []
        var index = 0
        while index < parts.count {
            switch parts[index] {
            case .gap:
                index += 1
            case .text(let text):
                segments.append(.text(index: segments.count, text))
                index += 1
            case .tool(let first):
                let spawns = ToolActivity.isSpawnAgent(first.name)
                var group: [ToolCallItem] = []
                collect: while index < parts.count {
                    switch parts[index] {
                    case .gap:
                        index += 1
                    case .tool(let item) where ToolActivity.isSpawnAgent(item.name) == spawns:
                        group.append(item)
                        index += 1
                    default:
                        break collect
                    }
                }
                segments.append(spawns ? .spawns(index: segments.count, group) : .tools(index: segments.count, group))
            }
        }
        return segments
    }

    // Sub-agent launches recorded in a tool's nested calls: live details first, else the stored result.
    private static func nestedSpawns(details: JSONValue?, result: ConversationEntry?, isLive: Bool) -> [ToolCallItem] {
        var records = details?["nestedTools"]?.arrayValue ?? []
        if records.isEmpty {
            records = result?.displayMetadata?["nestedTools"]?.arrayValue ?? []
        }
        return records.compactMap { record in
            let name = record["name"]?.stringValue ?? record["toolName"]?.stringValue ?? ""
            guard ToolActivity.isSpawnAgent(name), let id = record["id"]?.stringValue, !id.isEmpty else { return nil }
            let status = record["status"]?.stringValue ?? "done"
            return ToolCallItem(
                id: id,
                name: name,
                arguments: ToolActivity.objectArguments(record["args"] ?? record["arguments"]),
                result: nil,
                isRunning: isLive && ToolActivity.isInFlight(status)
            )
        }
    }
}

// A sub-agent badge (desktop `SubAgentPills`); `record` is nil until the desktop reports the sub-agent.
struct SubAgentPill: Identifiable {
    let id: String
    let name: String
    let record: SubAgentRecord?
    var isRunning: Bool
    var isQueued: Bool

    static func build(
        items: [ToolCallItem],
        records: [SubAgentRecord],
        isStreaming: Bool,
        toolDetails: [String: JSONValue]
    ) -> [SubAgentPill] {
        var pills: [SubAgentPill] = []
        for item in items {
            let key = ToolActivity.normalizedId(item.id)
            let requestedName = item.arguments["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let record = records.first { record in
                record.parentToolCallId.map(ToolActivity.normalizedId) == key
            } ?? records.first { record in
                guard let requestedName, record.name == requestedName else { return false }
                return (record.parentToolCallId ?? "").isEmpty
            }

            // A failed launch never created a sub-agent; only pending launches show a placeholder.
            if record == nil && !(item.isRunning && item.arguments["prompt"]?.stringValue?.isBlank == false) {
                continue
            }
            let isRecordTerminal = ["completed", "error", "aborted"].contains(record?.status ?? "")
            let isTerminal = isRecordTerminal || (!item.isRunning && record?.status != "running")
            let isQueued = record?.status == "queued"
            let isRunning = isTargetedByFollowUp(record, toolDetails: toolDetails)
                || (!isTerminal && (record?.status == "running" || isQueued || item.isRunning || isStreaming))
            let id = record?.id ?? "part:\(item.id)"
            if let index = pills.firstIndex(where: { $0.id == id }) {
                pills[index].isRunning = pills[index].isRunning || isRunning
                pills[index].isQueued = pills[index].isQueued || isQueued
            } else {
                pills.append(SubAgentPill(id: id, name: record?.name ?? fallbackName(item.arguments), record: record, isRunning: isRunning, isQueued: isQueued))
            }
        }
        return pills
    }

    private static func fallbackName(_ arguments: JSONValue) -> String {
        if let name = arguments["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let prompt = arguments["prompt"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            return String(prompt.prefix(18))
        }
        return agentIdentifier(arguments) ?? "Agent"
    }

    private static func agentIdentifier(_ arguments: JSONValue) -> String? {
        let raw = arguments["agent_id"] ?? arguments["agentId"] ?? arguments["target"]
        guard let value = raw?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    // A running `send_message` inside a code mode cell keeps the addressed sub-agent busy.
    private static func isTargetedByFollowUp(_ record: SubAgentRecord?, toolDetails: [String: JSONValue]) -> Bool {
        guard let record else { return false }
        for details in toolDetails.values {
            for nested in details["nestedTools"]?.arrayValue ?? [] {
                let name = nested["name"]?.stringValue ?? nested["toolName"]?.stringValue ?? ""
                guard name == "send_message" || name == "send_input",
                      ToolActivity.isInFlight(nested["status"]?.stringValue ?? ""),
                      let target = agentIdentifier(ToolActivity.objectArguments(nested["args"] ?? nested["arguments"]))
                else {
                    continue
                }
                if record.id == target || record.sessionId == target || record.name.lowercased() == target.lowercased() {
                    return true
                }
            }
        }
        return false
    }
}

enum ToolActivityKind {
    case skill
    case command
    case read
    case edit
    case write
    case ask
    case other
}

struct ToolActivitySummary {
    let kind: ToolActivityKind
    let text: String
    let isRunning: Bool
}

// One-line tool summaries with the desktop's zh-CN wording (`summarizeToolActivity`).
enum ToolActivity {
    private static let aliases: [String: String] = [
        "bash": "shell",
        "pwsh": "shell",
        "powershell": "shell",
        "ask_user": "ask",
        "manage_todo_list": "todo",
        "set_session_title": "title",
        "send_input": "send_message",
        "delegate_agent": "spawn_agent",
        "subagent": "spawn_agent",
    ]

    // Running and finished wording of tools without arguments in their summary.
    private static let builtins: [String: (kind: ToolActivityKind, running: String, done: String)] = [
        "memories_read": (.read, "正在读取记忆", "已读取记忆"),
        "memories_search": (.read, "正在搜索记忆", "已搜索记忆"),
        "memories_add": (.write, "正在写入记忆", "已写入记忆"),
        "web_search": (.other, "正在在线搜索", "已在线搜索"),
        "spawn_agent": (.other, "正在启动子代理", "已启动子代理"),
        "send_message": (.other, "正在发送消息", "已发送消息"),
        "stop_agent": (.other, "正在停止子代理", "已停止子代理"),
        "session_search": (.other, "正在搜索会话", "已搜索会话"),
        "session_create": (.other, "正在创建会话", "已创建会话"),
        "create_session": (.other, "正在创建会话", "已创建会话"),
    ]

    private static let spawnAgentNames: Set<String> = ["spawn_agent", "delegate_agent", "subagent"]

    static func normalizedId(_ id: String) -> String {
        id.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? id
    }

    static func isSpawnAgent(_ name: String) -> Bool {
        spawnAgentNames.contains(name)
    }

    // Statuses of a tool call that has not finished yet.
    static func isInFlight(_ status: String) -> Bool {
        status == "queued" || status == "running" || status == "awaiting_approval"
    }

    // Arguments of a nested call record, which may be stored as a JSON string.
    static func objectArguments(_ value: JSONValue?) -> JSONValue {
        if let text = value?.stringValue, let parsed = JSONValue.parse(text), parsed.objectValue != nil {
            return parsed
        }
        return value?.objectValue != nil ? value ?? [:] : [:]
    }

    static func isSkillRead(name: String, arguments: JSONValue) -> Bool {
        guard name == "read", let path = string(arguments, "path") else { return false }
        return path.replacingOccurrences(of: "\\", with: "/").lowercased().hasSuffix("skill.md")
    }

    static func summarize(name: String, arguments: JSONValue, isRunning running: Bool) -> ToolActivitySummary {
        if isSkillRead(name: name, arguments: arguments) {
            return ToolActivitySummary(kind: .skill, text: "已读取\(skillName(arguments)) 技能", isRunning: running)
        }

        switch name {
        case "bash", "shell", "pwsh", "powershell":
            if running, let command = line(string(arguments, "command") ?? string(arguments, "cmd"), limit: 64) {
                return ToolActivitySummary(kind: .command, text: "正在运行 \(command)", isRunning: running)
            }
            return ToolActivitySummary(kind: .command, text: "加载了工具运行了命令", isRunning: running)
        case "read":
            let file = fileName(arguments) ?? name
            return ToolActivitySummary(kind: .read, text: running ? "正在读取 \(file)" : "已读取 \(file)", isRunning: running)
        case "edit":
            let file = fileName(arguments) ?? name
            return ToolActivitySummary(kind: .edit, text: running ? "正在编辑 \(file)" : "已编辑 \(file)", isRunning: running)
        case "write":
            let file = fileName(arguments) ?? name
            return ToolActivitySummary(kind: .write, text: running ? "正在写入 \(file)" : "已写入 \(file)", isRunning: running)
        case "ask", "ask_user":
            let question = string(arguments, "question") ?? string(arguments, "prompt") ?? ""
            let short = question.count > 40 ? String(question.prefix(37)) + "…" : question
            let text = if running {
                short.isEmpty ? "正在等待你的回答" : "正在询问 \(short)"
            } else {
                short.isEmpty ? "已完成询问" : "已询问 \(short)"
            }
            return ToolActivitySummary(kind: .ask, text: text, isRunning: running)
        case "manage_todo_list", "todo":
            let reads = arguments["operation"]?.stringValue == "read"
            let text = if running {
                reads ? "正在读取待办事项" : "正在更新待办事项"
            } else {
                reads ? "已读取待办事项" : "已更新待办事项"
            }
            return ToolActivitySummary(kind: .other, text: text, isRunning: running)
        case "exec":
            let text = if let description = line(string(arguments, "description"), limit: 80) {
                running ? "正在执行代码模式：\(description)" : "已执行代码模式：\(description)"
            } else {
                running ? "正在执行代码模式" : "已执行代码模式"
            }
            return ToolActivitySummary(kind: .other, text: text, isRunning: running)
        case "set_session_title", "title":
            let text = if let title = line(string(arguments, "title"), limit: 64) {
                running ? "正在设置标题为 \(title)" : "设置标题为 \(title)"
            } else {
                running ? "正在设置标题" : "设置标题"
            }
            return ToolActivitySummary(kind: .other, text: text, isRunning: running)
        default:
            break
        }

        if let builtin = builtins[aliases[name] ?? name] {
            return ToolActivitySummary(kind: builtin.kind, text: running ? builtin.running : builtin.done, isRunning: running)
        }
        let displayName = humanize(name).isEmpty ? name : humanize(name)
        return ToolActivitySummary(kind: .other, text: running ? "正在使用 \(displayName)" : "已使用 \(displayName)", isRunning: running)
    }

    // Non-blank string argument, kept verbatim.
    private static func string(_ arguments: JSONValue, _ key: String) -> String? {
        guard let value = arguments[key]?.stringValue, !value.isBlank else { return nil }
        return value
    }

    // First line, trimmed and shortened with an ellipsis.
    private static func line(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let first = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard !first.isEmpty else { return nil }
        return first.count > limit ? String(first.prefix(limit - 3)) + "…" : first
    }

    private static func fileName(_ arguments: JSONValue) -> String? {
        guard let path = string(arguments, "path") ?? string(arguments, "file") else { return nil }
        return path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? path
    }

    // Skill folder name of a SKILL.md path, e.g. ".../gh-issue/SKILL.md" -> "Gh Issue".
    private static func skillName(_ arguments: JSONValue) -> String {
        guard let path = string(arguments, "path") else { return "skill" }
        let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        let last = parts.last ?? ""
        if last.lowercased() == "skill.md", parts.count >= 2 {
            return humanize(parts[parts.count - 2])
        }
        let stem = last.lowercased().hasSuffix(".md") ? String(last.dropLast(3)) : last
        return stem.isEmpty ? "skill" : humanize(stem)
    }

    // "gh-issue" -> "Gh Issue", like the desktop `humanizeToken`.
    private static func humanize(_ value: String) -> String {
        let words = value
            .replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        var result = ""
        var previousIsWord = false
        for character in words {
            let isWord = character.isASCII && (character.isLetter || character.isNumber || character == "_")
            result.append(isWord && !previousIsWord ? Character(character.uppercased()) : character)
            previousIsWord = isWord
        }
        return result
    }
}

extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
