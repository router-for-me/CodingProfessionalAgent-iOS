import SwiftUI

// "Continue in new worktree": forks the conversation into one that works in a new git worktree with an
// optional environment (desktop `ContinueInWorktreeModal`). The desktop creates the worktree and runs
// the environment setup before the copy's next turn.
struct WorktreeForkSheet: View {
    @Environment(\.dismiss) private var dismiss
    let client: DesktopClient
    let session: RemoteSession
    let onForked: (String) -> Void
    @State private var environmentId: String?
    @State private var environmentProjects: [RemoteProject] = []
    @State private var isDetecting = true
    @State private var branches: [String] = []
    @State private var branch: String
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(client: DesktopClient, session: RemoteSession, onForked: @escaping (String) -> Void) {
        self.client = client
        self.session = session
        self.onForked = onForked
        _environmentId = State(initialValue: session.environmentId)
        _branch = State(initialValue: session.branch ?? "main")
    }

    private var project: RemoteProject? {
        client.project(id: session.projectId)
    }

    private var sourcePath: String? {
        project?.primaryPath
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if branches.count > 1 {
                        Picker("分支", selection: $branch) {
                            ForEach(branches, id: \.self) { name in
                                Text(name)
                                    .tag(name)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(Color.secondary)
                    } else {
                        LabeledContent("分支", value: branch)
                    }
                    if let project {
                        LabeledContent("当前项目", value: project.name)
                    }
                } footer: {
                    if sourcePath == nil {
                        Text("未设置项目路径，无法创建工作树。")
                            .foregroundStyle(.red)
                    } else {
                        Text("基于所选分支创建独立的工作树，并分叉当前对话。")
                    }
                }

                Section {
                    environmentRow(
                        id: nil,
                        title: "不使用环境工作",
                        detail: "仅创建独立的 Git 工作树，不运行设置脚本"
                    )
                    ForEach(environmentProjects) { candidate in
                        environmentRow(
                            id: candidate.id,
                            title: candidate.name,
                            detail: candidate.primaryPath ?? "environment.toml"
                        )
                    }
                } header: {
                    HStack(spacing: 8) {
                        Text("环境")
                        if isDetecting {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                } footer: {
                    Text("工作树会在桌面端运行新对话的下一条消息之前创建。")
                }
            }
            .font(.system(size: 17))
            .disabled(isSubmitting)
            .navigationTitle("在新工作树中继续")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .tint(Color.primary)
                    .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("继续") {
                            submit()
                        }
                        .disabled(sourcePath == nil)
                    }
                }
            }
            .alert("分叉会话失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isSubmitting)
        .task {
            await detectBranches()
        }
        .task {
            environmentProjects = await client.environmentProjects()
            isDetecting = false
        }
    }

    private func environmentRow(id: String?, title: String, detail: String) -> some View {
        Button {
            environmentId = id
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(Color.primary)
                    // Concrete colors: hierarchical styles would take the button tint.
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if environmentId == id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(environmentId == id ? .isSelected : [])
    }

    // Uses the repository of the conversation's worktree, else of the project (desktop `readGitRepo`).
    private func detectBranches() async {
        for path in [session.worktreePath, sourcePath].compactMap({ $0 }) {
            let result = await client.gitBranches(at: path)
            guard !result.branches.isEmpty else { continue }
            branches = result.branches
            if let current = result.current {
                branch = current
            }
            if !branches.contains(branch) {
                branches.insert(branch, at: 0)
            }
            return
        }
    }

    private func submit() {
        isSubmitting = true
        let target = WorktreeFork(environmentId: environmentId, branch: branch)
        Task {
            do {
                let newId = try await client.forkSession(id: session.id, worktree: target)
                onForked(newId)
            } catch {
                errorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}
