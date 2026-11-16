import SwiftUI

enum DeviceFilter: Hashable {
    case all
    case device(UUID)
}

// A conversation addressed through the desktop that hosts it.
struct ThreadTarget: Identifiable, Hashable {
    let clientId: UUID
    let sessionId: String

    var id: String {
        "\(clientId.uuidString)/\(sessionId)"
    }
}

// A project addressed through the desktop that hosts it.
struct ProjectTarget: Identifiable, Hashable {
    let clientId: UUID
    let projectId: String

    var id: String {
        "\(clientId.uuidString)/\(projectId)"
    }
}

// A conversation with its desktop, for lists that mix desktops.
private struct ClientThread: Identifiable {
    let client: DesktopClient
    let thread: RemoteSession

    var id: String {
        "\(client.id.uuidString)/\(thread.id)"
    }
}

struct HomeView: View {
    @Environment(Router.self) private var router
    @Environment(ConnectionStore.self) private var store
    @State private var filter: DeviceFilter = .all
    @State private var draft = ComposerDraft()
    // Speed chosen with the "/" menu for the thread started from the home composer.
    @State private var composerSpeed: SpeedMode?
    @State private var notice: String?
    @State private var showsSettings = false
    @State private var showsSearch = false
    @State private var editor: ConnectionEditorTarget?
    @State private var showsAddConnectionDialog = false
    @State private var showsTunnelSheet = false
    @State private var expandedGroups: Set<String> = []
    // Project groups folded by tapping their row, kept across launches (newline separated keys).
    @AppStorage("home.collapsedGroups") private var collapsedGroupsStorage = ""
    @State private var renameTarget: ThreadTarget?
    @State private var renameText = ""
    @State private var removalTarget: ProjectTarget?
    @State private var editingProject: ProjectTarget?
    @State private var worktreeTarget: ThreadTarget?
    // Thread opened once the worktree sheet has been dismissed.
    @State private var pendingRoute: Route?
    @State private var errorMessage: String?
    @State private var navigationWidth: CGFloat = 0

    private let collapsedThreadLimit = 5

    private var clients: [DesktopClient] {
        store.enabledClients
    }

    private var visibleClients: [DesktopClient] {
        switch filter {
        case .all:
            clients
        case .device(let id):
            clients.filter { $0.id == id }
        }
    }

    // Desktop and project a thread started from the home composer goes to (as on the new thread screen).
    private var composerClient: DesktopClient? {
        visibleClients.first { $0.isConnected } ?? visibleClients.first
    }

    private var composerProjectPath: String? {
        guard let client = composerClient else { return nil }
        return (client.projects.first(where: \.pinned) ?? client.projects.first)?.primaryPath
    }

    private var composerSkills: [RemoteSkill] {
        composerClient?.skills(forProjectPath: composerProjectPath) ?? []
    }

    private var composerSkillTrigger: SkillTrigger {
        composerClient?.defaults.skillTrigger ?? .dollar
    }

    private var composerSkillsKey: String {
        "\(composerClient?.id.uuidString ?? "")|\(composerClient?.isConnected ?? false)|\(composerProjectPath ?? "")"
    }

    private var composerCommands: [SlashCommand] {
        guard let client = composerClient, client.isConnected else { return [] }
        // Same default model as the new thread screen, which opens on the pinned or first project.
        let model = client.preferredModel(projectId: (client.projects.first(where: \.pinned) ?? client.projects.first)?.id)
        let defaultSpeed: SpeedMode = client.defaults.speed == SpeedMode.fast.rawValue ? .fast : .standard
        let speed = composerSpeed ?? defaultSpeed
        var commands: [SlashCommand] = []
        if model?.supportsFast == true {
            commands.append(.fast(isOn: speed == .fast) {
                composerSpeed = speed == .fast ? .standard : .fast
                notice = composerSpeed == .fast ? "已开启快速模式" : "已恢复标准速度"
            })
        }
        commands.append(.model(current: model?.label) {
            router.push(.newThread(NewThreadContext(
                connectionId: client.id,
                speed: composerSpeed,
                opensModelSettings: true
            )))
        })
        return commands
    }

    var body: some View {
        @Bindable var router = router

        NavigationStack(path: $router.path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !clients.isEmpty {
                        filterBar
                            .padding(.bottom, 14)
                    }
                    content
                }
                .padding(.top, 13)
            }
            .refreshable {
                for client in visibleClients {
                    await client.resync()
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !clients.isEmpty {
                    ComposerBar(
                        draft: $draft,
                        placeholder: "向 CPA 提问",
                        commands: composerCommands,
                        skills: composerSkills,
                        skillTrigger: composerSkillTrigger,
                        onSubmit: startThreadFromComposer
                    )
                        .padding(.horizontal, 38)
                        .padding(.bottom, 4)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .thread(let connectionId, let sessionId):
                    ThreadView(connectionId: connectionId, sessionId: sessionId)
                case .newThread(let context):
                    NewThreadView(context: context)
                case .subAgent(let connectionId, let parentSessionId, let agentId, let sessionId):
                    SubAgentView(connectionId: connectionId, parentSessionId: parentSessionId, agentId: agentId, sessionId: sessionId)
                }
            }
            .sheet(isPresented: $showsSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showsSearch, onDismiss: openPendingRoute) {
                ChatSearchView(clients: clients) { route in
                    pendingRoute = route
                }
            }
            .sheet(item: $editor) { target in
                ConnectionEditorSheet(target: target)
            }
            .sheet(isPresented: $showsTunnelSheet) {
                TunnelConnectionSheet()
            }
            .confirmationDialog("添加连接", isPresented: $showsAddConnectionDialog, titleVisibility: .visible) {
                Button("直连桌面端") {
                    editor = .add
                }
                Button("通过 CLIProxyAPI Tunnel 连接") {
                    showsTunnelSheet = true
                }
                Button("取消", role: .cancel) {}
            }
            .sheet(item: $editingProject) { target in
                if let client = store.client(for: target.clientId), let project = client.project(id: target.projectId) {
                    ProjectEditSheet(client: client, project: project)
                }
            }
            .sheet(item: $worktreeTarget, onDismiss: openPendingRoute) { target in
                if let client = store.client(for: target.clientId), let thread = client.session(id: target.sessionId) {
                    WorktreeForkSheet(client: client, session: thread) { newId in
                        // Only the sheet still on screen may open its copy once it closes.
                        guard worktreeTarget == target else { return }
                        pendingRoute = .thread(connectionId: client.id, sessionId: newId)
                        worktreeTarget = nil
                    }
                }
            }
            .alert("重命名聊天", isPresented: isPresented($renameTarget), presenting: renameTarget) { target in
                TextField("标题", text: $renameText)
                Button("取消", role: .cancel) {}
                Button("保存") {
                    rename(target)
                }
            }
            .alert(removalTitle, isPresented: isPresented($removalTarget), presenting: removalTarget) { target in
                Button("取消", role: .cancel) {}
                Button("移除项目", role: .destructive) {
                    removeProject(target)
                }
            } message: { _ in
                Text("该项目下的对话将不再归属任何项目；对话和源文件夹不会被删除。")
            }
            .alert("操作失败", isPresented: isPresented($errorMessage)) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onChange(of: clients.map(\.id)) { _, ids in
                if case .device(let id) = filter, !ids.contains(id) {
                    filter = .all
                }
            }
            .onChange(of: router.externalNavigationRevision) { _, _ in
                pendingRoute = nil
                showsSettings = false
                showsSearch = false
                editor = nil
                showsTunnelSheet = false
                showsAddConnectionDialog = false
                editingProject = nil
                worktreeTarget = nil
                renameTarget = nil
                removalTarget = nil
                errorMessage = nil
            }
            .task(id: composerSkillsKey) {
                await composerClient?.loadSkills(projectPath: composerProjectPath)
            }
            .transientNotice($notice)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            navigationWidth = width
        }
        .environment(\.navigationWidth, navigationWidth)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showsSettings = true
            } label: {
                // Template vector asset: tinted like an SF Symbol in every appearance.
                Image("MenuIcon")
            }
            .accessibilityLabel("设置")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                pendingRoute = nil
                showsSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("搜索聊天")
            .disabled(clients.isEmpty)
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.connections.isEmpty {
            EmptyStateView(
                systemImage: "display",
                title: "尚未添加桌面端",
                message: "添加运行 CPA 桌面版的电脑后，即可在手机上查看项目并继续对话。",
                actionTitle: "添加连接"
            ) {
                showsAddConnectionDialog = true
            }
        } else if clients.isEmpty {
            EmptyStateView(
                systemImage: "bolt.horizontal.circle",
                title: "所有连接均已断开",
                message: "在设置中打开桌面端连接后即可继续使用。",
                actionTitle: "打开设置"
            ) {
                showsSettings = true
            }
        } else {
            // Pinned conversations leave their projects for a section of their own, as on the desktop.
            let pinned = pinnedThreads
            if !pinned.isEmpty {
                sectionTitle("置顶")
                ForEach(pinned) { item in
                    threadRow(
                        client: item.client,
                        thread: item.thread,
                        detail: showsDevice ? item.client.connection.displayName : nil,
                        leading: 0
                    )
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 5)
            }

            sectionTitle("项目")

            ForEach(visibleClients) { client in
                clientContent(client)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 17, weight: .semibold))
            .frame(height: 48)
            .padding(.horizontal, 20)
    }

    private var showsDevice: Bool {
        filter == .all && visibleClients.count > 1
    }

    private var pinnedThreads: [ClientThread] {
        visibleClients
            .flatMap { client in
                client.sessions
                    .filter { $0.isVisibleInList && $0.pinned }
                    .map { ClientThread(client: client, thread: $0) }
            }
            .sorted { $0.thread.updatedAt > $1.thread.updatedAt }
    }

    @ViewBuilder
    private func clientContent(_ client: DesktopClient) -> some View {
        if !client.isConnected {
            ClientStatusRow(client: client)
        } else if !client.hasSynced && client.projects.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                Text("正在同步 \(client.connection.displayName)…")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 15))
            .frame(height: 48)
            .padding(.horizontal, 20)
        }

        ForEach(sortedProjects(of: client)) { project in
            projectSection(
                client: client,
                project: project,
                threads: threads(of: client, projectId: project.id),
                showsDevice: showsDevice
            )
        }

        let orphans = orphanThreads(of: client)
        if !orphans.isEmpty {
            projectSection(client: client, project: nil, threads: orphans, showsDevice: showsDevice)
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "全部", isSelected: filter == .all) {
                    filter = .all
                }
                ForEach(clients) { client in
                    FilterChip(
                        title: client.connection.displayName,
                        systemImage: client.connection.icon.systemImage,
                        dotColor: statusColor(client.state),
                        isSelected: filter == .device(client.id)
                    ) {
                        filter = .device(client.id)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func projectSection(
        client: DesktopClient,
        project: RemoteProject?,
        threads: [RemoteSession],
        showsDevice: Bool
    ) -> some View {
        let groupKey = "\(client.id.uuidString)/\(project?.id ?? "-")"
        let isCollapsed = collapsedGroups.contains(groupKey)
        let isExpanded = expandedGroups.contains(groupKey)
        let attentionCount = threads.filter { client.isRunning($0.id) || $0.isUnread }.count
        let visibleLimit = max(collapsedThreadLimit, attentionCount)
        let shownThreads = isExpanded ? threads : Array(threads.prefix(visibleLimit))

        let title = project?.name ?? "对话"
        // Tapping the project row folds its conversations, like the desktop sidebar.
        let toggle = {
            withAnimation(.snappy) {
                toggleCollapsed(groupKey)
            }
        }
        let header = HStack(spacing: 14) {
            Image(systemName: project == nil ? "bubble.left.and.bubble.right" : "folder")
                .font(.system(size: 18))
                .frame(width: 22)
            Text(title)
                .font(.system(size: 17))
                .lineLimit(1)
            if showsDevice {
                Text(client.connection.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .frame(maxHeight: .infinity)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                // The uncategorized group has no menu.
                if let project {
                    header
                        .rowMenu(
                            showsDevice ? "\(title)，\(client.connection.displayName)" : title,
                            value: isCollapsed ? "已折叠" : "已展开",
                            action: toggle
                        ) {
                            projectMenu(client: client, project: project)
                        }
                } else {
                    Button(action: toggle) {
                        header
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(isCollapsed ? "已折叠" : "已展开")
                }

                Button {
                    router.push(.newThread(NewThreadContext(connectionId: client.id, projectId: project?.id)))
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, -6)
            }
            .frame(height: 52)

            if !isCollapsed {
                ForEach(shownThreads) { thread in
                    threadRow(client: client, thread: thread, detail: nil, leading: 36)
                }
            }

            if !isCollapsed, threads.count > visibleLimit {
                Button {
                    withAnimation(.snappy) {
                        if isExpanded {
                            expandedGroups.remove(groupKey)
                        } else {
                            expandedGroups.insert(groupKey)
                        }
                    }
                } label: {
                    Text(isExpanded ? "收起" : "显示全部（\(threads.count)）")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .padding(.leading, 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 5)
    }

    private func threadRow(client: DesktopClient, thread: RemoteSession, detail: String?, leading: CGFloat) -> some View {
        let title = thread.title.isEmpty ? "新对话" : thread.title
        let accessibilityLabel = [
            title,
            detail,
            client.isRunning(thread.id) ? "正在运行" : nil,
            thread.isUnread ? (thread.unread == .error ? "未读（异常）" : "未读") : nil,
        ]
        .compactMap { $0 }
        .joined(separator: "，")
        return HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 17))
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if client.isRunning(thread.id) {
                ProgressView()
                    .controlSize(.small)
            }
            if thread.isUnread {
                Circle()
                    .fill(thread.unread == .error ? Color.red : Color.blue)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.leading, leading)
        .rowMenu(accessibilityLabel) {
            router.push(.thread(connectionId: client.id, sessionId: thread.id))
        } menu: {
            threadMenu(client: client, thread: thread)
        }
    }

    // Long-press menu of a project row (desktop project context menu).
    @ViewBuilder
    private func projectMenu(client: DesktopClient, project: RemoteProject) -> some View {
        let target = ProjectTarget(clientId: client.id, projectId: project.id)
        Button(project.pinned ? "取消置顶项目" : "置顶项目", systemImage: project.pinned ? "pin.slash" : "pin") {
            perform {
                try await client.setProjectPinned(id: project.id, pinned: !project.pinned)
            }
        }
        Button("编辑项目", systemImage: "gearshape") {
            editingProject = target
        }
        Button("移除项目", systemImage: "xmark", role: .destructive) {
            removalTarget = target
        }
    }

    // Long-press menu of a conversation row (desktop conversation context menu).
    @ViewBuilder
    private func threadMenu(client: DesktopClient, thread: RemoteSession) -> some View {
        let project = client.project(id: thread.projectId)
        let projectPath = project?.primaryPath
        let target = ThreadTarget(clientId: client.id, sessionId: thread.id)
        Section {
            Button(thread.pinned ? "取消置顶" : "置顶聊天", systemImage: thread.pinned ? "pin.slash" : "pin") {
                perform {
                    try await client.setSessionPinned(id: thread.id, pinned: !thread.pinned)
                }
            }
            Menu("移至项目", systemImage: "folder") {
                moveButton("无项目", projectId: nil, client: client, thread: thread)
                ForEach(sortedProjects(of: client)) { candidate in
                    moveButton(candidate.name, projectId: candidate.id, client: client, thread: thread)
                }
            }
            if project != nil {
                Button("从项目中移除", systemImage: "folder.badge.minus") {
                    perform {
                        try await client.moveSession(id: thread.id, toProject: nil)
                    }
                }
            }
            Button("重命名聊天", systemImage: "pencil") {
                renameText = thread.title
                renameTarget = target
            }
            Button(thread.isUnread ? "标记为已读" : "标记为未读", systemImage: thread.isUnread ? "envelope.open" : "envelope.badge") {
                perform {
                    try await client.setSessionUnread(id: thread.id, unread: !thread.isUnread)
                }
            }
            Button("归档聊天", systemImage: "archivebox", role: .destructive) {
                perform {
                    try await client.archiveSession(id: thread.id)
                }
            }
        }
        Section {
            Button("复制工作目录", systemImage: "doc.on.doc") {
                copy(projectPath)
            }
            .disabled(projectPath == nil)
            Button("复制会话 ID", systemImage: "number") {
                copy(thread.id)
            }
            Button("复制深度链接", systemImage: "link") {
                copy(client.deepLink(sessionId: thread.id))
            }
            .disabled(client.deepLink(sessionId: thread.id) == nil)
        }
        Section {
            Button("在新聊天中继续", systemImage: "plus.bubble") {
                perform(failure: "分叉会话失败") {
                    let newId = try await client.forkSession(id: thread.id)
                    router.push(.thread(connectionId: client.id, sessionId: newId))
                }
            }
            Button("在新工作树中继续", systemImage: "arrow.triangle.branch") {
                worktreeTarget = target
            }
        }
    }

    private func moveButton(_ title: String, projectId: String?, client: DesktopClient, thread: RemoteSession) -> some View {
        Button {
            guard thread.projectId != projectId else { return }
            perform {
                try await client.moveSession(id: thread.id, toProject: projectId)
            }
        } label: {
            if thread.projectId == projectId {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    // MARK: - Actions

    private var collapsedGroups: Set<String> {
        Set(collapsedGroupsStorage.split(separator: "\n").map(String.init))
    }

    private func toggleCollapsed(_ groupKey: String) {
        var groups = collapsedGroups
        if groups.contains(groupKey) {
            groups.remove(groupKey)
        } else {
            groups.insert(groupKey)
            // Folding resets "show all", as the desktop resets its page size.
            expandedGroups.remove(groupKey)
        }
        collapsedGroupsStorage = groups.sorted().joined(separator: "\n")
    }

    private func perform(failure: String? = nil, _ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                let message = error.localizedDescription
                errorMessage = failure.map { "\($0)：\(message)" } ?? message
            }
        }
    }

    private func copy(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        notice = "已复制到剪贴板"
    }

    private func rename(_ target: ThreadTarget) {
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let client = store.client(for: target.clientId) else { return }
        guard client.session(id: target.sessionId)?.title != title else { return }
        perform {
            try await client.renameSession(id: target.sessionId, title: title)
        }
    }

    private var removalTitle: String {
        guard let target = removalTarget,
              let project = store.client(for: target.clientId)?.project(id: target.projectId)
        else {
            return "移除项目？"
        }
        return "移除 \(project.name)？"
    }

    private func removeProject(_ target: ProjectTarget) {
        guard let client = store.client(for: target.clientId) else { return }
        perform(failure: "无法移除项目，请重试") {
            try await client.removeProject(id: target.projectId)
        }
    }

    private func openPendingRoute() {
        guard let route = pendingRoute else { return }
        pendingRoute = nil
        router.push(route)
    }

    // Presents an alert or sheet while the optional value is set.
    private func isPresented<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    // Pinned projects first, like the desktop sidebar.
    private func sortedProjects(of client: DesktopClient) -> [RemoteProject] {
        client.projects.filter(\.pinned) + client.projects.filter { !$0.pinned }
    }

    // Pinned conversations are listed in their own section instead of under their project.
    private func threads(of client: DesktopClient, projectId: String) -> [RemoteSession] {
        sortThreads(client.sessions.filter { $0.isVisibleInList && !$0.pinned && $0.projectId == projectId }, of: client)
    }

    // Conversations without a (known) project.
    private func orphanThreads(of client: DesktopClient) -> [RemoteSession] {
        let projectIds = Set(client.projects.map(\.id))
        return sortThreads(client.sessions.filter { session in
            guard session.isVisibleInList, !session.pinned else { return false }
            guard let projectId = session.projectId else { return true }
            return !projectIds.contains(projectId)
        }, of: client)
    }

    // Running tasks stay pinned at the top of their project, followed by unviewed completed tasks, then read tasks.
    private func sortThreads(_ sessions: [RemoteSession], of client: DesktopClient) -> [RemoteSession] {
        sessions.sorted { lhs, rhs in
            let leftRank = threadPriorityRank(lhs, of: client)
            let rightRank = threadPriorityRank(rhs, of: client)
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    private func threadPriorityRank(_ session: RemoteSession, of client: DesktopClient) -> Int {
        if client.isRunning(session.id) {
            return 0
        }
        if session.isUnread {
            return 1
        }
        return 2
    }

    private func startThreadFromComposer() {
        let payload = draft.payload(knownSkills: composerSkills, trigger: composerSkillTrigger)
        guard !payload.text.isEmpty else { return }
        draft = ComposerDraft()
        router.push(.newThread(NewThreadContext(
            connectionId: composerClient?.id,
            prompt: payload.text,
            skillReferences: payload.references,
            speed: composerSpeed
        )))
    }
}

func statusColor(_ state: ConnectionState) -> Color {
    switch state {
    case .connected: Theme.online
    case .connecting: .orange
    case .failed: .red
    case .disconnected: Color(.systemGray3)
    }
}

// Shown in place of a desktop's projects while it is not connected.
private struct ClientStatusRow: View {
    let client: DesktopClient

    var body: some View {
        HStack(spacing: 10) {
            switch client.state {
            case .connecting:
                ProgressView()
                    .controlSize(.small)
                Text("正在连接 \(client.connection.displayName)…")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("\(client.connection.displayName)：\(message)")
                    .lineLimit(2)
                Spacer()
                Button("重试") {
                    client.wake()
                }
                .font(.system(size: 15, weight: .medium))
            case .connected, .disconnected:
                Text("\(client.connection.displayName) 未连接")
            }
        }
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
        .frame(minHeight: 48)
        .padding(.horizontal, 20)
    }
}

private struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.secondary, Color.clear)
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(actionTitle, action: action)
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .padding(.top, 6)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
        .padding(.top, 140)
    }
}

// Workspace filter capsule shown under the navigation bar.
private struct FilterChip: View {
    let title: String
    var systemImage: String?
    var dotColor: Color?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                }
                if let systemImage {
                    // Palette with a clear secondary layer keeps device icons as outlines.
                    Image(systemName: systemImage)
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary, Color.clear)
                }
                Text(title)
                    .font(.system(size: 17))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 16)
            .frame(height: 43)
            .background(isSelected ? Theme.chipBackground : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// Tapping runs `action`; long-pressing shows `menu` next to the row. Unlike a context menu,
// nothing is lifted and moved to make room for the menu: the menu grows out of a clear
// overlay (hidden while open), so the row itself stays visible in place.
private struct RowMenu<MenuItems: View>: ViewModifier {
    let label: String
    let value: String
    let action: () -> Void
    let menu: MenuItems
    // Bumped by each recognized long press, for the menu haptic.
    @State private var longPressCount = 0

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(true)
            .overlay {
                Menu {
                    menu
                } label: {
                    Color.clear
                        .contentShape(Rectangle())
                } primaryAction: {
                    action()
                }
                .menuOrder(.fixed)
                .accessibilityLabel(label)
                .accessibilityValue(value)
            }
            // The menu plays no haptic of its own and reports no opening, so this approximates it:
            // with the default Haptic Touch duration the menu opens for presses held about 0.4 s
            // (measured), shorter presses being taps. A slower accessibility setting may make the
            // haptic come before the menu.
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.42).onEnded { _ in
                longPressCount += 1
            })
            .sensoryFeedback(.impact(weight: .medium), trigger: longPressCount)
    }
}

private extension View {
    func rowMenu<MenuItems: View>(
        _ label: String,
        value: String = "",
        action: @escaping () -> Void,
        @ViewBuilder menu: () -> MenuItems
    ) -> some View {
        modifier(RowMenu(label: label, value: value, action: action, menu: menu()))
    }
}

#Preview {
    HomeView()
        .environment(Router())
        .environment(ConnectionStore())
}
