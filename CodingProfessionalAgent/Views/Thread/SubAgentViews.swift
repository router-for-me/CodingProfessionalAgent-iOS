import SwiftUI

// Badges of the sub-agents launched in a turn; tapping one opens its own run view.
struct SubAgentPills: View {
    let pills: [SubAgentPill]
    let onOpen: (SubAgentRecord) -> Void

    var body: some View {
        if !pills.isEmpty {
            FlowLayout(spacing: 8) {
                ForEach(pills) { pill in
                    Button {
                        if let record = pill.record {
                            onOpen(record)
                        }
                    } label: {
                        label(pill)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(pill.isQueued ? "\(pill.name)，排队中" : pill.name)
                    .accessibilityHint(pill.record == nil ? "" : "打开子智能体")
                }
            }
        }
    }

    private func label(_ pill: SubAgentPill) -> some View {
        HStack(spacing: 6) {
            SubAgentAvatar(icon: pill.record?.icon, color: pill.record?.color, size: 20)
            WidthLimit(maxWidth: 160) {
                Text(pill.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(pill.isRunning ? Color.secondary : Color.primary)
                    .modifier(Shimmer(isActive: pill.isRunning))
            }
            if pill.isQueued {
                Text("（排队中）")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 14))
        .padding(.leading, 6)
        .padding(.trailing, 11)
        .padding(.vertical, 5)
        .background(Color(.secondarySystemBackground), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color(.separator), lineWidth: 0.5)
        }
        .contentShape(Capsule())
    }
}

// Round sub-agent icon tinted with its color (desktop `SubAgentAvatar`).
struct SubAgentAvatar: View {
    let icon: String?
    let color: String?
    let size: CGFloat

    var body: some View {
        let tint = Color(hex: color ?? "") ?? Color(hex: "#9b7dff") ?? .purple
        Image(systemName: Self.symbol(for: icon))
            .font(.system(size: max(10, (size * 0.55).rounded()), weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.13), in: Circle())
            .accessibilityHidden(true)
    }

    private static func symbol(for icon: String?) -> String {
        switch icon {
        case "atom": "atom"
        case "flower": "camera.macro"
        case "sun": "sun.max"
        case "hexagon": "hexagon"
        case "orbit": "circle.dotted.circle"
        case "flame": "flame"
        case "brain": "brain"
        default: "sparkle"
        }
    }
}

// Shrinks its content to at most `maxWidth` without stretching it like a flexible frame would.
private struct WidthLimit: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? maxWidth, maxWidth)
        return subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

// Lays out views in rows, wrapping to the next row when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = Self.size(of: subviews[index], width: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    // Each view may use up to a full row.
    private static func size(of subview: LayoutSubview, width: CGFloat) -> CGSize {
        subview.sizeThatFits(width.isFinite ? ProposedViewSize(width: width, height: nil) : .unspecified)
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = Self.size(of: subviews[index], width: maxWidth)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty && needed > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

// Read-only run view of one sub-agent (desktop `SubAgentConversation`).
struct SubAgentView: View {
    @Environment(ConnectionStore.self) private var store
    let connectionId: UUID
    let parentSessionId: String
    let agentId: String
    let sessionId: String

    var body: some View {
        if let client = store.client(for: connectionId) {
            SubAgentContent(client: client, parentSessionId: parentSessionId, agentId: agentId, sessionId: sessionId)
        } else {
            ContentUnavailableView(
                "连接不可用",
                systemImage: "bolt.horizontal.circle",
                description: Text("该桌面端连接已被删除。")
            )
        }
    }
}

private struct SubAgentContent: View {
    @Environment(Router.self) private var router
    @Environment(\.navigationWidth) private var navigationWidth
    @State private var model: ThreadModel
    // Error of the latest message fork, shown in an alert.
    @State private var forkError: String?
    @AppStorage(PreferenceKey.wrapDiffLines) private var wrapDiffLines = true

    init(client: DesktopClient, parentSessionId: String, agentId: String, sessionId: String) {
        let reference = SubAgentReference(parentSessionId: parentSessionId, agentId: agentId)
        _model = State(initialValue: ThreadModel(client: client, sessionId: sessionId, subAgent: reference))
    }

    private var client: DesktopClient {
        model.client
    }

    private var record: SubAgentRecord? {
        model.subAgentRecord
    }

    // Width left for the leading title after the back button.
    private var titleWidth: CGFloat {
        NavigationLayout.titleWidth(containerWidth: navigationWidth, reservedWidth: 120)
    }

    private var turnContext: TurnContext {
        // The fork action copies this run up to that message into a new top-level conversation and
        // opens the copy, like the desktop's message fork inside a sub-agent conversation.
        TurnContext(subAgents: model.subAgents, toolDetails: model.toolDetails, onFork: fork) { child in
            router.push(.subAgent(
                connectionId: client.id,
                parentSessionId: child.parentSessionId,
                agentId: child.id,
                sessionId: child.conversationId
            ))
        }
    }

    // Copies this run up to `entry` into a new top-level conversation and opens it.
    private func fork(fromEntry entry: ConversationEntry) {
        Task {
            do {
                let newId = try await client.forkSession(id: model.sessionId, atEntryId: entry.id)
                router.push(.thread(connectionId: client.id, sessionId: newId))
            } catch {
                forkError = error.localizedDescription
            }
        }
    }

    var body: some View {
        // Stable container so recreating the scroll view when the first entries arrive does not
        // re-register the toolbar item in UINavigationBar and blink the header.
        ZStack {
            ScrollView {
                // Not lazy, like the conversation view: jumps to the bottom need measured rows.
                VStack(alignment: .leading, spacing: 24) {
                    let context = turnContext
                    ForEach(ChatTurn.group(model.entries, isRunActive: model.isRunning)) { turn in
                        switch turn {
                        case .user(let entry):
                            UserBubble(entry: entry, knownSkills: [], skillTrigger: client.defaults.skillTrigger)
                        case .compaction:
                            CompactionDivider()
                        case .assistant(let assistantTurn):
                            AssistantTurnView(turn: assistantTurn, context: context, wrapLines: wrapDiffLines)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 13)
                .padding(.bottom, 24)
            }
            // A finished sub-agent opens at its prompt; a running one follows its output.
            .followsLatestContent(
                userMessageCount: model.entries.count { $0.kind == .user },
                showsJumpButton: true,
                startsFollowing: model.isRunning
            )
            // Recreated when the first entries arrive (also after an offline or failed first load), so the opening
            // position uses the sub-agent state at that point and the loaded prompt is not taken as a new message.
            .id(model.entries.isEmpty)

            placeholder
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                header
                    .frame(width: titleWidth, alignment: .leading)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .alert("操作失败", isPresented: Binding(get: { forkError != nil }, set: { if !$0 { forkError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(forkError ?? "")
        }
        .onAppear {
            model.activate()
        }
        .onDisappear {
            model.deactivate()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            SubAgentAvatar(icon: record?.icon, color: record?.color, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(record?.name ?? "子智能体")
                    .font(.system(size: 17, weight: .semibold))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    subtitle(now: context.date.milliseconds)
                }
            }
            .lineLimit(1)
        }
    }

    // "运行中 12s · GPT-5 · 高 ⚡︎", like the desktop sub-agent list row and conversation header.
    private func subtitle(now: Double) -> some View {
        var parts: [String] = []
        if let record {
            parts.append("\(record.statusTitle) \(AssistantTurn.formatElapsed(record.elapsedMs(now: now)))")
            let model = client.model(id: record.modelId)
            parts.append(model?.label ?? record.modelId)
            if let effort = record.reasoningEffort, !effort.isEmpty {
                let fallback = model?.reasoningLevels.first { $0.id == effort }?.fallbackLabel
                parts.append(ReasoningChoice.title(for: effort, fallback: fallback))
            }
        }
        let isFast = record.map { record in
            client.model(id: record.modelId)?.supportsFast == true && (record.speed ?? "standard") != "standard"
        } ?? false
        return HStack(spacing: 3) {
            Text(parts.filter { !$0.isEmpty }.joined(separator: " · "))
            if isFast {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(Theme.skillChip)
                    .accessibilityLabel("快速")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var placeholder: some View {
        if model.entries.isEmpty {
            if let error = model.loadError {
                ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.isLoading && client.isConnected {
                ProgressView()
            } else if !model.isRunning {
                Text("暂无消息")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension Color {
    // "#rrggbb" or "#rgb"; nil for anything else.
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }
}
