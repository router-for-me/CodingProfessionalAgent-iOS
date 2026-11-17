import SwiftUI

// Edits a project's name and source folders, or removes it from the app (desktop `ProjectEditDialog`).
struct ProjectEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let client: DesktopClient
    let project: RemoteProject
    @State private var name: String
    @State private var paths: [String]
    @State private var showsBrowser = false
    @State private var confirmsRemoval = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(client: DesktopClient, project: RemoteProject) {
        self.client = client
        self.project = project
        _name = State(initialValue: project.name)
        _paths = State(initialValue: project.allPaths)
    }

    var body: some View {
        let _ = locale
        NavigationStack {
            Form {
                Section(L10n.Project.name) {
                    TextField(L10n.Project.name, text: $name)
                }

                Section(L10n.Project.sourceFolders) {
                    ForEach(paths, id: \.self) { path in
                        HStack(spacing: 12) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(RemotePath.lastComponent(of: path))
                                    .lineLimit(1)
                                Text(path)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            Button {
                                paths.removeAll { $0 == path }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(Color(.systemGray3))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.Project.removeSourceFolder(path))
                        }
                    }

                    Button {
                        showsBrowser = true
                    } label: {
                        Label(L10n.Project.addFolder, systemImage: "folder.badge.plus")
                    }
                }

                Section {
                    Button(L10n.Project.remove, role: .destructive) {
                        confirmsRemoval = true
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .font(.system(size: 17))
            .disabled(isSaving)
            .navigationTitle(L10n.Project.edit)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) {
                        dismiss()
                    }
                    .tint(Color.primary)
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.save) {
                        save()
                    }
                    .disabled(trimmedName.isEmpty || isSaving)
                }
            }
            .navigationDestination(isPresented: $showsBrowser) {
                DirectoryBrowserView(client: client) { path in
                    if !paths.contains(path) {
                        paths.append(path)
                    }
                    showsBrowser = false
                }
            }
            .alert(L10n.Project.removeConfirmNamed(project.name), isPresented: $confirmsRemoval) {
                Button(L10n.Common.cancel, role: .cancel) {}
                Button(L10n.Project.remove, role: .destructive) {
                    remove()
                }
            } message: {
                Text(L10n.Project.removeConfirmMessage)
            }
            .alert(L10n.Common.actionFailed, isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button(L10n.Common.ok, role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isSaving)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        run(failure: nil) {
            try await client.updateProject(id: project.id, name: name, paths: paths)
        }
    }

    private func remove() {
        run(failure: L10n.Project.removeFailed) {
            try await client.removeProject(id: project.id)
        }
    }

    // Closes the sheet once the desktop has applied the change.
    private func run(failure: String?, _ action: @escaping @MainActor () async throws -> Void) {
        isSaving = true
        Task {
            do {
                try await action()
                dismiss()
            } catch {
                let message = error.localizedDescription
                errorMessage = failure.map { L10n.Common.errorWithDetail($0, message) } ?? message
                isSaving = false
            }
        }
    }
}
