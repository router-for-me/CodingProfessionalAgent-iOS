import SwiftUI

// Chat search of the home screen (desktop `ChatSearchModal`): recent chats and quick actions while
// the query is empty, otherwise title and content matches from every listed desktop.
struct ChatSearchView: View {
    let clients: [DesktopClient]
    // Called with the destination to open once the search has been dismissed.
    let onOpen: (Route) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var query = ""
    @State private var matches: [ChatSearchHit] = []
    @State private var isSearching = false
    @FocusState private var isFocused: Bool
    @State private var notice: String?

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsDevice: Bool {
        clients.count > 1
    }

    // Recent chats update with the desktops' lists while the query is empty.
    private var hits: [ChatSearchHit] {
        guard !trimmedQuery.isEmpty else {
            let recent = clients.flatMap { client in
                ChatSearch.recent(client.sessions).map { ChatSearchHit(client: client, result: $0) }
            }
            return Array(recent.sorted { $0.result.updatedAt > $1.result.updatedAt }.prefix(ChatSearch.limit))
        }
        return matches
    }

    var body: some View {
        let _ = locale
        NavigationStack {
            List {
                Section {
                    if hits.isEmpty && !isSearching {
                        Text(L10n.Search.noResults)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    ForEach(hits) { hit in
                        Button {
                            open(.thread(connectionId: hit.client.id, sessionId: hit.result.sessionId))
                        } label: {
                            row(hit)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(L10n.Search.chats)
                        if isSearching {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                }

                if trimmedQuery.isEmpty {
                    Section(L10n.Search.quickActions) {
                        quickAction(L10n.Search.newChat, systemImage: "square.and.pencil") {
                            open(.newThread(NewThreadContext(connectionId: (clients.first { $0.isConnected } ?? clients.first)?.id)))
                        }
                        quickAction(L10n.Search.openFolder, systemImage: "folder") {
                            notice = L10n.Common.comingSoon
                        }
                        quickAction(L10n.Search.searchFiles, systemImage: "magnifyingglass") {
                            notice = L10n.Common.comingSoon
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.Search.placeholder)
            .searchFocused($isFocused)
            .navigationTitle(L10n.Search.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.Common.close, systemImage: "xmark") {
                        dismiss()
                    }
                }
            }
            .task(id: trimmedQuery) {
                await search(trimmedQuery)
            }
            .onAppear {
                isFocused = true
            }
            .transientNotice($notice)
        }
    }

    private func row(_ hit: ChatSearchHit) -> some View {
        // With several desktops the device comes first so a long project name cannot truncate it away.
        let detail = [showsDevice ? hit.client.connection.displayName : nil, hit.client.project(id: hit.result.projectId)?.name]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if !(hit.result.branch ?? "").isEmpty {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 13))
                        .foregroundStyle(.purple)
                        .accessibilityLabel(L10n.Search.branch)
                }
                highlighted(hit.result.title.isEmpty ? L10n.Home.newChat : hit.result.title)
                    .font(.system(size: 16))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .trailing)
                }
            }
            if let snippet = hit.result.snippet, !trimmedQuery.isEmpty {
                highlighted(snippet)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    // Matched parts are emphasized and underlined, like the desktop.
    private func highlighted(_ text: String) -> Text {
        ChatSearch.highlightSegments(text, query: trimmedQuery).reduce(Text(verbatim: "")) { result, segment in
            if segment.isMatch {
                Text("\(result)\(Text(verbatim: segment.text).fontWeight(.semibold).underline())")
            } else {
                Text("\(result)\(Text(verbatim: segment.text))")
            }
        }
    }

    private func quickAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 16))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func open(_ route: Route) {
        onOpen(route)
        dismiss()
    }

    private func search(_ text: String) async {
        guard !text.isEmpty else {
            matches = []
            isSearching = false
            return
        }
        isSearching = true
        // Typing restarts this task, which debounces the request like the desktop.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        var found: [ChatSearchHit] = []
        await withTaskGroup(of: [ChatSearchHit].self) { group in
            for client in clients {
                group.addTask {
                    await Self.search(text, on: client)
                }
            }
            for await hits in group {
                found += hits
            }
        }
        guard !Task.isCancelled else { return }
        matches = ChatSearch.ordered(found, result: \.result)
        isSearching = false
    }

    // Older desktops without the search request fall back to matching the listed titles.
    @MainActor
    private static func search(_ text: String, on client: DesktopClient) async -> [ChatSearchHit] {
        let results: [SessionSearchResult]
        do {
            results = try await client.searchSessions(query: text, limit: ChatSearch.limit)
        } catch {
            results = ChatSearch.titleMatches(client.sessions, query: text)
        }
        return results.map { ChatSearchHit(client: client, result: $0) }
    }
}

struct ChatSearchHit: Identifiable {
    let client: DesktopClient
    let result: SessionSearchResult

    var id: String {
        "\(client.id.uuidString)/\(result.sessionId)"
    }
}
