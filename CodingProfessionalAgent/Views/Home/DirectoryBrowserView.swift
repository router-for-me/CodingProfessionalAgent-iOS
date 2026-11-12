import SwiftUI

// Browses the desktop computer's folders to pick a project source folder (desktop `DirectoryBrowserModal`).
struct DirectoryBrowserView: View {
    let client: DesktopClient
    let onSelect: (String) -> Void
    @State private var currentPath = ""
    @State private var homePath = ""
    @State private var folders: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var showsHidden = false
    @State private var showsPathInput = false
    @State private var pathInput = ""
    // Only the latest navigation may update the list.
    @State private var loadGeneration = 0

    var body: some View {
        List {
            Section {
                Text(currentPath.isEmpty ? " " : currentPath)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 15))
                        .foregroundStyle(.red)
                }

                if let parent = RemotePath.parent(of: currentPath) {
                    Button {
                        load(parent)
                    } label: {
                        Label("上一级", systemImage: "arrow.turn.left.up")
                    }
                }
            }

            Section {
                ForEach(visibleFolders, id: \.self) { name in
                    Button {
                        load(RemotePath.join(currentPath, name))
                    } label: {
                        HStack {
                            Label(name, systemImage: "folder")
                                .foregroundStyle(Color.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(.tertiaryLabel))
                        }
                        .contentShape(Rectangle())
                    }
                }
            }
        }
        .overlay {
            if isLoading && folders.isEmpty {
                ProgressView()
            } else if !isLoading && visibleFolders.isEmpty && !currentPath.isEmpty {
                ContentUnavailableView("没有子文件夹", systemImage: "folder")
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "筛选文件夹")
        .navigationTitle("选择项目目录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("用户主目录", systemImage: "house") {
                        load(homePath)
                    }
                    .disabled(homePath.isEmpty)
                    Button("根目录", systemImage: "externaldrive") {
                        load(RemotePath.root(of: currentPath.isEmpty ? homePath : currentPath))
                    }
                    // Typed paths reach other drives and network shares (desktop editable path).
                    Button("前往路径…", systemImage: "arrow.right.circle") {
                        pathInput = currentPath
                        showsPathInput = true
                    }
                    Button("刷新", systemImage: "arrow.clockwise") {
                        load(currentPath)
                    }
                    .disabled(currentPath.isEmpty)
                    Toggle("显示隐藏文件夹", systemImage: "eye", isOn: $showsHidden)
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("选择此目录") {
                    onSelect(currentPath)
                }
                .buttonStyle(.glassProminent)
                .disabled(currentPath.isEmpty || isLoading)
            }
        }
        .alert("前往路径", isPresented: $showsPathInput) {
            TextField("/Users/name/Projects", text: $pathInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("前往") {
                load(pathInput.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        .task {
            guard homePath.isEmpty else { return }
            do {
                homePath = try await client.homeDirectory()
            } catch {
                homePath = "/"
            }
            load(homePath)
        }
    }

    private var visibleFolders: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return folders.filter { name in
            (showsHidden || !name.hasPrefix(".")) && (trimmed.isEmpty || name.localizedCaseInsensitiveContains(trimmed))
        }
    }

    // Shows a folder once its contents are read; on failure the previous folder stays listed.
    private func load(_ path: String) {
        guard !path.isEmpty else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        Task {
            do {
                let names = try await client.subdirectories(of: path)
                guard generation == loadGeneration else { return }
                folders = names
                currentPath = path
                query = ""
                errorMessage = nil
            } catch {
                guard generation == loadGeneration else { return }
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// Path helpers for the desktop's file system (POSIX or Windows), mirroring the desktop's `pathUtils`.
enum RemotePath {
    // Drive paths (`C:\...`) and UNC shares (`\\server\share\...`) use backslashes.
    static func isWindows(_ path: String) -> Bool {
        path.range(of: "^[A-Za-z]:", options: .regularExpression) != nil || path.hasPrefix("\\\\")
    }

    static func root(of path: String) -> String {
        if path.hasPrefix("\\\\") {
            let parts = path.dropFirst(2).split(separator: "\\", omittingEmptySubsequences: true)
            return parts.count >= 2 ? "\\\\\(parts[0])\\\(parts[1])\\" : path
        }
        return isWindows(path) ? String(path.prefix(2)) + "\\" : "/"
    }

    static func join(_ base: String, _ name: String) -> String {
        if base.hasSuffix("/") || base.hasSuffix("\\") {
            return base + name
        }
        return base + (isWindows(base) ? "\\" : "/") + name
    }

    // Nil at the root of the file system.
    static func parent(of path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let root = root(of: path)
        var trimmed = path
        while trimmed.count > root.count, trimmed.hasSuffix("/") || trimmed.hasSuffix("\\") {
            trimmed.removeLast()
        }
        guard trimmed.count > root.count,
              let separator = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" })
        else {
            return nil
        }
        let parent = String(trimmed[..<separator])
        return parent.count < root.count ? root : parent
    }

    static func lastComponent(of path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        return trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }
}
