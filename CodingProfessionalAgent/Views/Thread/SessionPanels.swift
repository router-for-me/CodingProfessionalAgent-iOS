import SwiftUI
import UIKit

// Applies the glass effect in a capsule (shared two-button pill) or a circle (lone
// close button), matching the screenshot chrome.
private struct GlassCapsule: ViewModifier {
    let circular: Bool
    func body(content: Content) -> some View {
        if circular {
            content.glassEffect(.regular, in: .circle)
        } else {
            content.glassEffect(.regular, in: .capsule)
        }
    }
}

// MARK: - Panel tab

// The "更改" and "文件" menu items open the same panel on different tabs, like the
// desktop's right sidebar where the review and file manager are sibling panels.
enum SessionPanelTab: String, Identifiable {
    case changes
    case files
    var id: String { rawValue }
}

// MARK: - Shared helpers

// Working directory of the conversation: an explicit override (project picked in the
// title menu), then the session's worktree, then its project's primary folder
// (desktop `effectiveProjectPath`).
@MainActor
private func sessionWorkingPath(client: DesktopClient, session: RemoteSession?, override: RemoteProject?) -> String? {
    if let override {
        return override.primaryPath
    }
    return session?.worktreePath ?? client.project(id: session?.projectId)?.primaryPath
}

private extension String {
    var pathFileName: String {
        RemotePath.lastComponent(of: self)
    }

    var pathDirectory: String {
        let normalized = replacingOccurrences(of: "\\", with: "/")
        guard let slash = normalized.lastIndex(of: "/") else { return "" }
        return String(normalized[..<slash])
    }
}

private extension GitDiffHunk {
    var additions: Int { lines.count { $0.type == .add } }
    var deletions: Int { lines.count { $0.type == .delete } }
}

// MARK: - Sheet header and tabs

// Centered panel chrome like the reference sheets: title (with optional project
// chevron menu and branch subtitle) and trailing expand-all/close buttons.
private struct PanelHeader: View {
    let title: String
    var subtitle: String?
    var additions: Int?
    var deletions: Int?
    /// When set, the title becomes a project switcher menu like the screenshot's ⌄.
    var projects: [RemoteProject] = []
    var onSelectProject: ((RemoteProject) -> Void)?
    /// Second button from the right, only on the changes tab: expands or collapses
    /// every diff card (screenshots IMG_5472 vs IMG_5473).
    var allExpanded: Bool?
    var onToggleAllExpanded: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 2) {
                if projects.isEmpty {
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(1)
                } else {
                    Menu {
                        ForEach(projects) { project in
                            Button {
                                onSelectProject?(project)
                            } label: {
                                if project.name == title {
                                    Label(project.name, systemImage: "checkmark")
                                } else {
                                    Text(project.name)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(title)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                    }
                    .tint(.primary)
                }
                HStack(spacing: 6) {
                    if let subtitle {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                    }
                    if let additions {
                        Text("+\(additions)")
                            .foregroundStyle(.green)
                    }
                    if let deletions {
                        Text("-\(deletions)")
                            .foregroundStyle(.red)
                    }
                }
                .font(.system(size: 14))
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 110)

            let hasExpandButton = allExpanded != nil && onToggleAllExpanded != nil
            // Both buttons share one glass capsule on the changes tab; on the files
            // tab the lone close button is a circle, like the screenshots.
            HStack(spacing: 0) {
                if let allExpanded, let onToggleAllExpanded {
                    Button(action: onToggleAllExpanded) {
                        // Expanded shows the inward arrows (tap collapses); collapsed
                        // shows the outward arrows (tap expands), like the screenshots.
                        Image(systemName: allExpanded
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 50, height: 44)
                            .contentShape(Rectangle())
                    }
                    .tint(.primary)
                    .accessibilityLabel(allExpanded ? "折叠全部" : "展开全部")
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: hasExpandButton ? 50 : 44, height: 44)
                        .contentShape(Rectangle())
                }
                .tint(.primary)
                .accessibilityLabel("关闭")
            }
            .modifier(GlassCapsule(circular: !hasExpandButton))
            .padding(.trailing, 20)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.top, 16)
        .padding(.bottom, 26)
    }
}

// Segmented control like the screenshots: 已修改 / 所有文件, full width.
private struct PanelTabs: View {
    let leftTitle: String
    let rightTitle: String
    @Binding var isRightSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            tab(leftTitle, selected: !isRightSelected) {
                withAnimation(.snappy) { isRightSelected = false }
            }
            tab(rightTitle, selected: isRightSelected) {
                withAnimation(.snappy) { isRightSelected = true }
            }
        }
        .padding(2)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background {
                    if selected {
                        Capsule()
                            .fill(Color(.systemBackground))
                            .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Diff lines

// One line of a diff hunk like the screenshots: the line number sits on a darker
// gutter strip at the left edge, the code wraps below its own leading edge, and the
// row background is tinted green/red for added/deleted lines.
private struct DiffLineRow: View {
    let line: GitDiffLine
    let fileName: String
    @Environment(\.colorScheme) private var colorScheme

    private var palette: CodeHighlighter.Palette {
        colorScheme == .dark ? .dark : .light
    }

    private var lineNumber: String {
        if let n = line.newLineNumber { return "\(n)" }
        if let n = line.oldLineNumber { return "\(n)" }
        return ""
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(lineNumber)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(numberColor)
                .frame(width: 34, alignment: .trailing)
                .padding(.trailing, 8)
                .padding(.top, 2)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(gutterBackground)
            Text(CodeHighlighter.highlight(line.content, fileName: fileName, palette: palette))
                .font(.system(size: 13, design: .monospaced))
                .padding(.leading, 6)
                .padding(.trailing, 8)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(rowBackground)
    }

    private var rowBackground: Color {
        switch line.type {
        case .add: return Color.green.opacity(colorScheme == .dark ? 0.20 : 0.12)
        case .delete: return Color.red.opacity(colorScheme == .dark ? 0.18 : 0.10)
        case .normal: return Color(.systemBackground)
        }
    }

    private var gutterBackground: Color {
        switch line.type {
        case .add: return Color.green.opacity(colorScheme == .dark ? 0.32 : 0.24)
        case .delete: return Color.red.opacity(colorScheme == .dark ? 0.30 : 0.20)
        case .normal: return Color(.systemGray6).opacity(0.6)
        }
    }

    private var numberColor: Color {
        switch line.type {
        case .add: return Color.green.opacity(0.95)
        case .delete: return Color.red.opacity(0.95)
        case .normal: return Color.secondary.opacity(0.8)
        }
    }
}

// Card of one changed file like the screenshots: a gray rounded card whose header row
// (bold name, gray directory, +add -del counts, open-file button) toggles the diff
// content - a gray "第 X-Y 行" hunk header and edge-to-edge colored diff rows.
private struct DiffFileCard: View {
    let file: GitDiffFile
    let isExpanded: Bool
    let onToggle: () -> Void
    let onOpen: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.displayPath.pathFileName)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(file.displayPath.pathDirectory)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 12)
                    diffStat(file.additions, file.deletions)
                    Button {
                        onOpen(file.displayPath)
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 20))
                            .foregroundStyle(.primary)
                            .frame(width: 38, height: 38)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开文件")
                }
                .padding(.leading, 16)
                .padding(.trailing, 10)
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedContent
            }
        }
        // Explicit gray (systemGray6/5 blend) so the card reads as a gray rounded
        // card on the white panel in both light and dark mode, like the screenshots.
        .background(Color(.systemGray6).opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var expandedContent: some View {
        if file.isBinary {
            Text("二进制文件已修改")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(.systemBackground))
        } else if file.hunks.isEmpty {
            Text("无差异")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(.systemBackground))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                    hunkHeader(hunk)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                            DiffLineRow(line: line, fileName: file.displayPath)
                        }
                    }
                }
            }
            .background(Color(.systemBackground))
        }
    }

    private func hunkHeader(_ hunk: GitDiffHunk) -> some View {
        HStack {
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("第 \(hunk.newStart)-\(hunk.newStart + max(hunk.newLines - 1, 0)) 行")
                .font(.system(size: 14))
                .foregroundStyle(.primary)
            Spacer()
            diffStat(hunk.additions, hunk.deletions)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(.systemGray5).opacity(0.7))
    }

    private func diffStat(_ additions: Int, _ deletions: Int) -> some View {
        HStack(spacing: 5) {
            Text("+\(additions)").foregroundStyle(.green)
            Text("-\(deletions)").foregroundStyle(.red)
        }
        .font(.system(size: 14, weight: .medium).monospacedDigit())
    }
}

// MARK: - Session panel sheet

// One sheet shared by the "更改" and "文件" menu items: the header/tabs switch between
// the diff view (已修改, project title + branch stats + expand-all button + branch
// bar) and the file tree (所有文件, "文件" title + floating search), like the
// screenshots and the desktop's sibling right-panel views.
struct SessionPanelSheet: View {
    @Environment(\.dismiss) private var dismiss
    let client: DesktopClient
    let session: RemoteSession?
    let initialTab: SessionPanelTab

    // Files larger than this are not auto-expanded, keeping huge diffs responsive
    // (desktop large-diff guard).
    private static let largeFileLineThreshold = 400

    @State private var showsAllFiles: Bool
    @State private var isLoading = true
    @State private var isGitRepo = true
    @State private var summary = GitDiffSummary()
    @State private var repoDetails: GitRepoDetails?
    @State private var expandedPaths: Set<String> = []
    @State private var baseBranch: String
    @State private var compareTarget: String
    // false = working-tree diff (desktop default); true = base...target comparison.
    @State private var comparesBranches = false
    @State private var compareFailed = false
    @State private var openedFile: OpenedFile?
    @State private var errorMessage: String?
    @State private var projectOverride: RemoteProject?

    init(client: DesktopClient, session: RemoteSession?, initialTab: SessionPanelTab) {
        self.client = client
        self.session = session
        self.initialTab = initialTab
        _showsAllFiles = State(initialValue: initialTab == .files)
        _baseBranch = State(initialValue: session?.baseBranch ?? "main")
        _compareTarget = State(initialValue: session?.branch ?? "")
    }

    private var workingPath: String? {
        sessionWorkingPath(client: client, session: session, override: projectOverride)
    }

    private var sessionProject: RemoteProject? {
        client.project(id: session?.projectId)
    }

    private var projectName: String {
        projectOverride?.name
            ?? sessionProject?.name
            ?? session?.worktreePath?.pathFileName
            ?? workingPath?.pathFileName
            ?? "更改"
    }

    private var allExpanded: Bool {
        !summary.files.isEmpty && expandedPaths.count >= summary.files.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            PanelTabs(leftTitle: "已修改", rightTitle: "所有文件", isRightSelected: $showsAllFiles)
                .padding(.bottom, 8)

            if showsAllFiles {
                SessionFileTree(client: client, rootPath: workingPath) { path in
                    openedFile = OpenedFile(
                        absolutePath: path,
                        relativePath: relativePath(for: path),
                        name: path.pathFileName
                    )
                }
            } else {
                diffContent
                    // The branch bar overlays the bottom so diff rows scroll behind
                    // its translucent material, like the screenshot.
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        bottomBar
                    }
            }
        }
        .background(Color(.systemBackground))
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .task(id: taskKey) {
            await loadDiff()
        }
        .sheet(item: $openedFile) { file in
            FilePreviewSheet(client: client, file: file)
        }
        .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var header: some View {
        if showsAllFiles {
            PanelHeader(
                title: "文件",
                onClose: { dismiss() }
            )
        } else {
            PanelHeader(
                title: projectName,
                subtitle: "分支",
                additions: summary.totalAdditions,
                deletions: summary.totalDeletions,
                projects: client.projects,
                onSelectProject: { project in
                    // Re-selecting the shown project keeps the loaded diff; only a
                    // real switch resets state (otherwise taskKey never changes and
                    // the loading view would stick).
                    let newOverride = project == sessionProject ? nil : project
                    guard newOverride?.id != projectOverride?.id else { return }
                    // A new repository needs fresh compare state: the previous
                    // session's branch/base may not exist there, and its diff paths
                    // must not be opened against the new repo root while reloading.
                    projectOverride = newOverride
                    comparesBranches = false
                    compareTarget = ""
                    baseBranch = "main"
                    expandedPaths = []
                    summary = GitDiffSummary()
                    repoDetails = nil
                    compareFailed = false
                    isLoading = true
                },
                allExpanded: allExpanded,
                onToggleAllExpanded: toggleAllExpanded,
                onClose: { dismiss() }
            )
        }
    }

    private var taskKey: String {
        "\(workingPath ?? "")|\(baseBranch)|\(compareTarget)|\(comparesBranches)"
    }

    @ViewBuilder
    private var diffContent: some View {
        if workingPath == nil {
            ContentUnavailableView("未选择项目", systemImage: "folder", description: Text("该对话没有关联的项目目录。"))
        } else if isLoading && summary.files.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !isGitRepo {
            ContentUnavailableView("当前项目不是 Git 仓库", systemImage: "exclamationmark.triangle", description: Text(workingPath ?? ""))
        } else if compareFailed {
            ContentUnavailableView("无法比较分支", systemImage: "exclamationmark.triangle", description: Text("请检查基准分支是否存在。"))
        } else if summary.files.isEmpty {
            ContentUnavailableView("暂无代码更改", systemImage: "arrow.triangle.branch", description: Text("当前工作区与对比目标代码一致。"))
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(summary.files) { file in
                        DiffFileCard(
                            file: file,
                            isExpanded: expandedPaths.contains(file.displayPath),
                            onToggle: {
                                if expandedPaths.contains(file.displayPath) {
                                    expandedPaths.remove(file.displayPath)
                                } else {
                                    expandedPaths.insert(file.displayPath)
                                }
                            },
                            onOpen: openFile
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Text(shownTarget)
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            Menu {
                Button {
                    comparesBranches = false
                } label: {
                    if !comparesBranches {
                        Label("工作区更改", systemImage: "checkmark")
                    } else {
                        Text("工作区更改")
                    }
                }
                Divider()
                ForEach(branchChoices, id: \.self) { name in
                    Button {
                        baseBranch = name
                        comparesBranches = true
                    } label: {
                        if comparesBranches, name == baseBranch {
                            Label("origin/\(name)", systemImage: "checkmark")
                        } else {
                            Text("origin/\(name)")
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("origin/\(baseBranch)")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
        }
        .font(.system(size: 16))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var shownTarget: String {
        if comparesBranches {
            return compareTarget.isEmpty ? (repoDetails?.currentBranch ?? "HEAD") : compareTarget
        }
        return repoDetails?.currentBranch ?? session?.branch ?? "HEAD"
    }

    private var branchChoices: [String] {
        var names = repoDetails?.branches ?? []
        for extra in [repoDetails?.defaultBranch, session?.baseBranch, "main"].compactMap({ $0 }) {
            if !extra.isEmpty, !names.contains(extra) {
                names.append(extra)
            }
        }
        return names.sorted()
    }

    private func toggleAllExpanded() {
        if allExpanded {
            expandedPaths = []
        } else {
            expandedPaths = Set(summary.files.map(\.displayPath))
        }
    }

    private func openFile(_ relativePath: String) {
        // Diff paths are relative to the repository root, which can differ from the
        // project folder when that folder is a subdirectory of the repository.
        guard let root = repoDetails?.repoRoot ?? workingPath else { return }
        openedFile = OpenedFile(
            absolutePath: RemotePath.join(root, relativePath),
            relativePath: relativePath,
            name: relativePath.pathFileName
        )
    }

    private func relativePath(for path: String) -> String {
        guard let root = workingPath else { return path.pathFileName }
        let normalizedRoot = root.replacingOccurrences(of: "\\", with: "/")
        let normalizedPath = path.replacingOccurrences(of: "\\", with: "/")
        if normalizedPath.hasPrefix(normalizedRoot + "/") {
            return String(normalizedPath.dropFirst(normalizedRoot.count + 1))
        }
        return path.pathFileName
    }

    private func loadDiff() async {
        guard let path = workingPath else {
            isLoading = false
            return
        }
        isLoading = true
        let loader = GitDiffLoader(client: client, cwd: path)
        let details = await loader.loadRepoDetails()
        guard !Task.isCancelled else { return }
        guard let details else {
            isGitRepo = false
            isLoading = false
            return
        }
        repoDetails = details
        isGitRepo = true

        // Like the desktop panel the default is the working-tree diff; picking a base
        // branch in the bottom bar switches to a `origin/base...target` comparison.
        // Results land in locals first so a cancelled request cannot overwrite state.
        var result = GitDiffSummary()
        var failed = false
        if comparesBranches {
            let target = compareTarget.isEmpty ? (details.currentBranch ?? "HEAD") : compareTarget
            if let diff = await loader.loadBranchDiff(base: baseBranch, target: target) {
                result = diff
            } else {
                failed = true
            }
        } else {
            result = await loader.loadWorkingTreeDiff(repoRoot: details.repoRoot)
        }
        guard !Task.isCancelled else { return }
        compareFailed = failed
        summary = result
        let validPaths = Set(result.files.map(\.displayPath))
        expandedPaths = expandedPaths.intersection(validPaths)
        // The first file opens expanded like the screenshot's default view, unless it
        // is large enough that rendering every line at once would stall the panel.
        if expandedPaths.isEmpty,
           let first = result.files.first,
           first.hunks.map(\.lines.count).reduce(0, +) <= Self.largeFileLineThreshold {
            expandedPaths = [first.displayPath]
        }
        isLoading = false
    }
}

// MARK: - File tree

struct OpenedFile: Identifiable, Hashable {
    let absolutePath: String
    let relativePath: String
    let name: String
    var id: String { absolutePath }
}

private struct FileTreeEntry: Identifiable, Hashable {
    let name: String
    let isDir: Bool
    let path: String
    var id: String { path }
}

// Expandable file tree of the project folder (desktop FileManager tree): directories
// load lazily, files open in the preview. The .git and build folders are skipped (same
// list as the desktop filter); a floating capsule at the bottom filters by name.
private struct SessionFileTree: View {
    let client: DesktopClient
    let rootPath: String?
    let onOpen: (String) -> Void

    @State private var entries: [FileTreeEntry] = []
    @State private var children: [String: [FileTreeEntry]] = [:]
    @State private var expandedDirs: Set<String> = []
    @State private var isLoading = false
    @State private var query = ""
    @State private var loadGeneration = 0

    private static let skippedNames: Set<String> = [".git", "node_modules", "dist", ".next", "coverage"]

    var body: some View {
        Group {
            if rootPath == nil {
                ContentUnavailableView("未选择项目", systemImage: "folder")
            } else if isLoading && entries.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredEntries.isEmpty {
                ContentUnavailableView("未找到匹配的文件", systemImage: "doc.magnifyingglass")
            } else {
                List {
                    ForEach(filteredEntries) { entry in
                        FileTreeRow(
                            entry: entry,
                            level: 0,
                            expandedDirs: $expandedDirs,
                            children: children,
                            query: query,
                            onToggleDir: toggleDir,
                            onOpen: onOpen
                        )
                    }
                }
                .listStyle(.plain)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索文件", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .font(.system(size: 15))
            .padding(.horizontal, 16)
            .frame(height: 44)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .task(id: rootPath ?? "") {
            await loadRoot()
        }
    }

    private var filteredEntries: [FileTreeEntry] {
        filter(entries, for: query)
    }

    // A directory stays listed when any loaded descendant matches (whether or not it
    // is expanded), so the matching file can be reached once its children are known.
    private func filter(_ list: [FileTreeEntry], for query: String) -> [FileTreeEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return list }
        return list.filter { entry in
            if entry.name.localizedCaseInsensitiveContains(trimmed) {
                return true
            }
            guard entry.isDir else { return false }
            return !filter(children[entry.path] ?? [], for: trimmed).isEmpty
        }
    }

    private func loadRoot() async {
        guard let rootPath else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        let loaded = (try? await client.directoryEntries(of: rootPath)) ?? []
        guard generation == loadGeneration else { return }
        entries = loaded
            .filter { !Self.skippedNames.contains($0.name) }
            .map { FileTreeEntry(name: $0.name, isDir: $0.isDir, path: RemotePath.join(rootPath, $0.name)) }
        isLoading = false
    }

    private func toggleDir(_ entry: FileTreeEntry) {
        if expandedDirs.contains(entry.path) {
            expandedDirs.remove(entry.path)
            return
        }
        expandedDirs.insert(entry.path)
        guard children[entry.path] == nil else { return }
        Task {
            let loaded = (try? await client.directoryEntries(of: entry.path)) ?? []
            children[entry.path] = loaded
                .filter { !Self.skippedNames.contains($0.name) }
                .map { FileTreeEntry(name: $0.name, isDir: $0.isDir, path: RemotePath.join(entry.path, $0.name)) }
        }
    }
}

private struct FileTreeRow: View {
    let entry: FileTreeEntry
    let level: Int
    @Binding var expandedDirs: Set<String>
    let children: [String: [FileTreeEntry]]
    let query: String
    let onToggleDir: (FileTreeEntry) -> Void
    let onOpen: (String) -> Void

    private var isExpanded: Bool {
        expandedDirs.contains(entry.path)
    }

    private var visibleChildren: [FileTreeEntry] {
        let list = children[entry.path] ?? []
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return list }
        return list.filter { child in
            if child.name.localizedCaseInsensitiveContains(trimmed) {
                return true
            }
            guard child.isDir else { return false }
            return !visibleChildren(of: child.path).isEmpty
        }
    }

    private func visibleChildren(of path: String) -> [FileTreeEntry] {
        let list = children[path] ?? []
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return list }
        return list.filter { child in
            if child.name.localizedCaseInsensitiveContains(trimmed) {
                return true
            }
            guard child.isDir else { return false }
            return !visibleChildren(of: child.path).isEmpty
        }
    }

    var body: some View {
        Button {
            if entry.isDir {
                onToggleDir(entry)
            } else {
                onOpen(entry.path)
            }
        } label: {
            HStack(spacing: 10) {
                // The chevron is lighter than the folder/file icon, like the
                // screenshot; secondaryLabel adapts to dark mode unlike darkGray.
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(.systemGray))
                    .frame(width: 12)
                    .opacity(entry.isDir ? 1 : 0)
                Image(systemName: entry.isDir ? "folder" : "doc.text")
                    .font(.system(size: 18))
                    .foregroundStyle(Color(.secondaryLabel))
                    .frame(width: 22)
                Text(entry.name)
                    .font(.system(size: 16))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.leading, CGFloat(level) * 20)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16))

        if entry.isDir && isExpanded {
            ForEach(visibleChildren) { child in
                FileTreeRow(
                    entry: child,
                    level: level + 1,
                    expandedDirs: $expandedDirs,
                    children: children,
                    query: query,
                    onToggleDir: onToggleDir,
                    onOpen: onOpen
                )
            }
        }
    }
}

// MARK: - File preview

// Read-only file viewer with line numbers and syntax highlighting (desktop FileManager
// preview); long lines wrap like the diff rows.
private struct FilePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let client: DesktopClient
    let file: OpenedFile

    @State private var lines: [String]?
    @State private var errorMessage: String?

    private var palette: CodeHighlighter.Palette {
        colorScheme == .dark ? .dark : .light
    }

    var body: some View {
        NavigationStack {
            Group {
                if let errorMessage {
                    ContentUnavailableView("无法读取文件", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                } else if let lines {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                HStack(alignment: .top, spacing: 0) {
                                    Text("\(index + 1)")
                                        .frame(width: 44, alignment: .trailing)
                                        .foregroundStyle(.secondary.opacity(0.6))
                                        .padding(.trailing, 12)
                                        .padding(.top, 1)
                                        .frame(maxHeight: .infinity, alignment: .top)
                                    Text(CodeHighlighter.highlight(line, fileName: file.name, palette: palette))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.top, 1)
                                }
                                .font(.system(size: 13, design: .monospaced))
                                .padding(.horizontal, 12)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(file.relativePath)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = file.absolutePath
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("复制文件路径")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task {
            do {
                let content = try await client.readFile(at: file.absolutePath)
                // Truncation keeps huge files (minified bundles, lock files) responsive.
                let capped = content.count > 200_000 ? String(content.prefix(200_000)) : content
                lines = capped.components(separatedBy: "\n").map {
                    $0.hasSuffix("\r") ? String($0.dropLast()) : $0
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
