import SwiftUI

// "Continue in new worktree": forks the conversation into one that works in a new git worktree with an
// optional environment (desktop `ContinueInWorktreeModal`). The desktop creates the worktree and runs
// the environment setup before the copy's next turn.
struct WorktreeForkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
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
        let _ = locale
        NavigationStack {
            Form {
                Section {
                    if branches.count > 1 {
                        Picker(L10n.Worktree.branch, selection: $branch) {
                            ForEach(branches, id: \.self) { name in
                                Text(name)
                                    .tag(name)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(Color.secondary)
                    } else {
                        LabeledContent(L10n.Worktree.branch, value: branch)
                    }
                    if let project {
                        LabeledContent(L10n.Worktree.currentProject, value: project.name)
                    }
                } footer: {
                    if sourcePath == nil {
                        Text(L10n.Worktree.noProjectPath)
                            .foregroundStyle(.red)
                    } else {
                        Text(L10n.Worktree.createHint)
                    }
                }

                Section {
                    environmentRow(
                        id: nil,
                        title: L10n.Worktree.withoutEnvTitle,
                        detail: L10n.Worktree.withoutEnvDetail
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
                        Text(L10n.Worktree.environmentSection)
                        if isDetecting {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                } footer: {
                    Text(L10n.Worktree.environmentFooter)
                }
            }
            .font(.system(size: 17))
            .disabled(isSubmitting)
            .navigationTitle(L10n.Worktree.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) {
                        dismiss()
                    }
                    .tint(Color.primary)
                    .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button(L10n.Worktree.continue) {
                            submit()
                        }
                        .disabled(sourcePath == nil)
                    }
                }
            }
            .alert(L10n.Worktree.forkFailedTitle, isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button(L10n.Common.ok, role: .cancel) {}
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
