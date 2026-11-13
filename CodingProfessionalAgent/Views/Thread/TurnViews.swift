import SwiftUI

// Conversation state the turns need besides their entries.
struct TurnContext {
    // Sub-agents launched by the conversation.
    var subAgents: [SubAgentRecord] = []
    // Live details of running tools by normalized call id.
    var toolDetails: [String: JSONValue] = [:]
    var openSubAgent: (SubAgentRecord) -> Void = { _ in }
    // Forks the conversation from a message (desktop `onForkMessage`); nil hides the action.
    var onFork: ((ConversationEntry) -> Void)? = nil

    init(
        subAgents: [SubAgentRecord] = [],
        toolDetails: [String: JSONValue] = [:],
        onFork: ((ConversationEntry) -> Void)? = nil,
        openSubAgent: @escaping (SubAgentRecord) -> Void = { _ in }
    ) {
        self.subAgents = subAgents
        self.toolDetails = toolDetails
        self.onFork = onFork
        self.openSubAgent = openSubAgent
    }
}

// One assistant turn in the desktop's folded style: an elapsed-time header followed by the activity
// while running; once finished, everything except the final reply folds into the header.
struct AssistantTurnView: View {
    let turn: AssistantTurn
    let context: TurnContext
    let wrapLines: Bool
    @State private var isExpanded: Bool

    init(turn: AssistantTurn, context: TurnContext, wrapLines: Bool) {
        self.turn = turn
        self.context = context
        self.wrapLines = wrapLines
        _isExpanded = State(initialValue: turn.isLive)
    }

    var body: some View {
        let completedAt = turn.completedAt
        let status = turn.status
        let reply = turn.trailingText
        VStack(alignment: .leading, spacing: 12) {
            TurnHeader(turn: turn, completedAt: completedAt, isExpanded: isExpanded) {
                withAnimation(.snappy) {
                    isExpanded.toggle()
                }
            }

            // Only thinking or skill reads so far: the ticking header is the progress indicator.
            if !turn.isLive || turn.hasVisibleContent {
                if turn.isLive || isExpanded {
                    expandedContent
                } else {
                    collapsedContent(reply: reply)
                }
            }

            if status == .error {
                Label(turn.errorMessage ?? "生成失败", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 15))
                    .foregroundStyle(.red)
            }

            if status == .done && !reply.isEmpty {
                MessageActions(
                    text: reply,
                    createdAt: completedAt ?? turn.messages.last?.createdAt ?? 0,
                    onFork: turn.forkEntry.flatMap { entry in context.onFork.map { fork in { fork(entry) } } }
                )
            }
        }
        .onChange(of: turn.isLive) { _, isLive in
            // Running turns show their activity; finished ones fold it away.
            isExpanded = isLive
        }
    }

    private var expandedContent: some View {
        let sections = turn.sections
        return ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
            switch section {
            case .compaction:
                CompactionDivider()
            case .messages(let messages):
                // A stage cut off by a compaction is no longer running.
                let isLive = turn.isLive && index == sections.count - 1
                let segments = ActivitySegment.build(messages: messages, of: turn, isLive: isLive, toolDetails: context.toolDetails)
                ForEach(segments) { segment in
                    switch segment {
                    case .text(_, let text):
                        MarkdownText(text: text, wrapCode: wrapLines)
                    case .tools(let index, let items):
                        ToolActivityStack(items: items, isActive: isLive && index == segments.count - 1, wrapLines: wrapLines)
                    case .spawns(let index, let items):
                        SubAgentPills(
                            pills: SubAgentPill.build(
                                items: items,
                                records: context.subAgents,
                                isStreaming: isLive && index == segments.count - 1,
                                toolDetails: context.toolDetails
                            ),
                            onOpen: context.openSubAgent
                        )
                    }
                }
            }
        }
    }

    private func collapsedContent(reply: String) -> some View {
        let sections = turn.sections
        let lastMessagesIndex = sections.lastIndex { section in
            if case .messages = section {
                return true
            }
            return false
        }
        return ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
            switch section {
            case .compaction:
                CompactionDivider()
            case .messages:
                if index == lastMessagesIndex && !reply.isEmpty {
                    MarkdownText(text: reply, wrapCode: wrapLines)
                }
            }
        }
    }
}

// "已处理 29s" ticking while running; afterwards "已完成 4m 26s", which toggles the folded activity.
private struct TurnHeader: View {
    let turn: AssistantTurn
    let completedAt: Double?
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if turn.isLive {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    title(turn.headerTitle(now: context.date.milliseconds, completedAt: completedAt))
                }
            } else {
                Button(action: onToggle) {
                    title(turn.headerTitle(now: 0, completedAt: completedAt))
                }
                .buttonStyle(.plain)
                .accessibilityHint(isExpanded ? "收起工具记录" : "展开工具记录")
            }
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 0.5)
        }
        .padding(.bottom, 4)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

// Consecutive tool calls folded into one line showing the latest call. With several calls the line
// expands into the list of calls; tapping a call shows its arguments and result.
private struct ToolActivityStack: View {
    let items: [ToolCallItem]
    // The turn is still working on this run of tools.
    let isActive: Bool
    let wrapLines: Bool
    @State private var isHistoryOpen = false
    @State private var detailId: String?

    var body: some View {
        if let latest = items.last {
            let summary = latest.summary
            let isStackActive = isActive || items.contains(where: \.isRunning)
            VStack(alignment: .leading, spacing: 6) {
                if items.count > 1 {
                    Button {
                        withAnimation(.snappy) {
                            isHistoryOpen.toggle()
                        }
                    } label: {
                        ToolActivityLine(summary: summary, isShimmering: isStackActive, chevron: isHistoryOpen ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(isHistoryOpen ? "收起工具记录" : "展开工具记录")

                    if isHistoryOpen {
                        history(isStackActive: isStackActive)
                    }
                } else {
                    call(latest, summary: summary, isShimmering: isStackActive)
                }
            }
        }
    }

    private func history(isStackActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let summary = item.summary
                call(item, summary: summary, isShimmering: (index == items.count - 1 && isStackActive) || summary.isRunning)
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(.separator))
                .frame(width: 1)
        }
        .padding(.leading, 6)
    }

    @ViewBuilder
    private func call(_ item: ToolCallItem, summary: ToolActivitySummary, isShimmering: Bool) -> some View {
        Button {
            withAnimation(.snappy) {
                detailId = detailId == item.id ? nil : item.id
            }
        } label: {
            ToolActivityLine(summary: summary, isShimmering: isShimmering, chevron: nil)
        }
        .buttonStyle(.plain)
        .accessibilityHint(detailId == item.id ? "收起详情" : "展开详情")

        if detailId == item.id {
            if item.result?.isError == true {
                Label("错误", systemImage: "xmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }
            CodeBlock(text: Self.detail(of: item), wrapLines: wrapLines)
        }
    }

    private static func detail(of item: ToolCallItem) -> String {
        var sections: [String] = []
        if !item.arguments.isNull {
            sections.append(pretty(item.arguments))
        }
        if let result = item.result {
            let output = result.text
            sections.append(output.count > 6000 ? String(output.prefix(6000)) + "\n…" : output)
        }
        return sections.joined(separator: "\n\n")
    }

    private static func pretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        return text.count > 4000 ? String(text.prefix(4000)) + "\n…" : text
    }
}

private struct ToolActivityLine: View {
    let summary: ToolActivitySummary
    let isShimmering: Bool
    let chevron: String?

    var body: some View {
        HStack(spacing: 6) {
            if let chevron {
                Image(systemName: chevron)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 12)
            }
            Image(systemName: Self.symbol(for: summary.kind))
                .font(.system(size: 13))
                .frame(width: 18)
            Text(summary.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .modifier(Shimmer(isActive: isShimmering))
        }
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
    }

    private static func symbol(for kind: ToolActivityKind) -> String {
        switch kind {
        case .command:
            "wrench.adjustable"
        case .edit:
            "pencil.line"
        case .write:
            "doc.badge.plus"
        case .ask:
            "questionmark.circle"
        case .skill, .read, .other:
            "doc.text"
        }
    }
}

// Highlight sweeping across text that is still in progress, like the desktop `animate-text-shimmer`.
struct Shimmer: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if isActive && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let cycle = 2.0
                let progress = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
                let center = progress * 2 - 0.5
                content.foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: .secondary, location: 0),
                            .init(color: .primary, location: 0.5),
                            .init(color: .secondary, location: 1),
                        ],
                        startPoint: UnitPoint(x: center - 0.35, y: 0.5),
                        endPoint: UnitPoint(x: center + 0.35, y: 0.5)
                    )
                )
            }
        } else {
            content
        }
    }
}
