import Foundation

// Chat search helpers mirroring the desktop `searchChats`.
enum ChatSearch {
    static let limit = 30

    // Recent conversations shown before anything is typed.
    static func recent(_ sessions: [RemoteSession]) -> [SessionSearchResult] {
        sessions
            .filter(\.isVisibleInList)
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { result(for: $0) }
    }

    // Title matches only, for desktops whose search request fails.
    static func titleMatches(_ sessions: [RemoteSession], query: String) -> [SessionSearchResult] {
        sessions
            .filter { $0.isVisibleInList && $0.title.range(of: query, options: .caseInsensitive) != nil }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { result(for: $0) }
    }

    // Results of several desktops: title matches first, each group newest first, like one desktop.
    static func ordered<Item>(_ items: [Item], result: (Item) -> SessionSearchResult) -> [Item] {
        let titles = items.filter { result($0).isTitleMatch }.sorted { result($0).updatedAt > result($1).updatedAt }
        let contents = items.filter { !result($0).isTitleMatch }.sorted { result($0).updatedAt > result($1).updatedAt }
        return Array((titles + contents).prefix(limit))
    }

    // Splits text into matched and unmatched parts for highlighting (desktop `splitHighlightSegments`).
    static func highlightSegments(_ text: String, query: String) -> [(text: String, isMatch: Bool)] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !needle.isEmpty else { return [(text, false)] }
        var segments: [(text: String, isMatch: Bool)] = []
        var start = text.startIndex
        while start < text.endIndex, let match = text.range(of: needle, options: .caseInsensitive, range: start..<text.endIndex) {
            if match.lowerBound > start {
                segments.append((String(text[start..<match.lowerBound]), false))
            }
            segments.append((String(text[match]), true))
            start = match.upperBound
        }
        if start < text.endIndex {
            segments.append((String(text[start...]), false))
        }
        return segments
    }

    private static func result(for session: RemoteSession) -> SessionSearchResult {
        SessionSearchResult(
            sessionId: session.id,
            title: session.title,
            projectId: session.projectId,
            branch: session.branch,
            updatedAt: session.updatedAt
        )
    }
}
