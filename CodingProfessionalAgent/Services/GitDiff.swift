import Foundation

// Models and parsing for `git diff` output, mirroring the desktop review plugin's
// `utils/gitDiff.ts` (working-tree mode: `git diff HEAD` plus untracked files).

enum GitFileStatus: String, Sendable {
    case added
    case deleted
    case modified
    case renamed
    case copied
    case untracked
}

enum GitDiffLineType: Sendable {
    case add
    case delete
    case normal
}

struct GitDiffLine: Sendable, Hashable {
    let type: GitDiffLineType
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let content: String
}

struct GitDiffHunk: Sendable, Hashable {
    let oldStart: Int
    let oldLines: Int
    let newStart: Int
    let newLines: Int
    let heading: String
    let lines: [GitDiffLine]
}

struct GitDiffFile: Sendable, Hashable, Identifiable {
    var id: String { displayPath }
    let oldPath: String
    let newPath: String
    let displayPath: String
    let status: GitFileStatus
    let additions: Int
    let deletions: Int
    let isBinary: Bool
    let hunks: [GitDiffHunk]
}

struct GitDiffSummary: Sendable {
    var files: [GitDiffFile] = []
    var totalAdditions = 0
    var totalDeletions = 0
    var totalFilesChanged = 0
    var rawDiff = ""
}

struct GitRepoDetails: Sendable {
    let repoRoot: String
    let currentBranch: String?
    let defaultBranch: String?
    let branches: [String]
    let remoteUrl: String?
    let isClean: Bool
}

enum GitDiffParser {
    // Regex literals are value types but not Sendable-marked; parse() is only used
    // from the main actor, so the shared instance is safe.
    nonisolated(unsafe) private static let hunkHeaderRegex = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$/

    // Splits on LF only; a trailing CR of a CRLF line is stripped per line so line
    // numbers and content match the desktop parser (which splits on /\r?\n/).
    private static func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    // Decodes a quoted git path ("\\303\\244…") into UTF-8; unquoted paths pass through.
    // Only \\ooo octal escapes and the standard \\t/\\\\/\\" escapes are decoded;
    // any other backslash sequence is kept verbatim.
    static func unquoteGitPath(_ path: String) -> String {
        guard path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") else { return path }
        var bytes: [UInt8] = []
        let inner = path.dropFirst().dropLast()
        var scalars = inner.makeIterator()
        while let ch = scalars.next() {
            guard ch == "\\" else {
                bytes.append(contentsOf: String(ch).utf8)
                continue
            }
            guard let next = scalars.next() else {
                bytes.append(UInt8(ascii: "\\"))
                break
            }
            switch next {
            case "t": bytes.append(UInt8(ascii: "\t"))
            case "n": bytes.append(UInt8(ascii: "\n"))
            case "\\", "\"", "'": bytes.append(UInt8(ascii: next == "'" ? "'" : next == "\\" ? "\\" : "\""))
            case "0"..."7":
                guard let o2 = scalars.next(), let o3 = scalars.next(),
                      let value = Int("\(next)\(o2)\(o3)", radix: 8), value <= 255
                else {
                    bytes.append(contentsOf: String("\\\(next)").utf8)
                    continue
                }
                bytes.append(UInt8(value))
            default:
                bytes.append(UInt8(ascii: "\\"))
                bytes.append(contentsOf: String(next).utf8)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // Extracts one path token starting at `start`: either a quoted "..." sequence or a
    // run of non-space characters; returns the decoded path and the index after it.
    static func extractGitPath(_ line: String, from start: String.Index) -> (path: String, end: String.Index)? {
        guard start < line.endIndex else { return nil }
        if line[start] == "\"" {
            var index = line.index(after: start)
            var raw = "\""
            while index < line.endIndex {
                let ch = line[index]
                raw.append(ch)
                index = line.index(after: index)
                if ch == "\\", index < line.endIndex {
                    raw.append(line[index])
                    index = line.index(after: index)
                    continue
                }
                if ch == "\"" {
                    return (unquoteGitPath(raw), index)
                }
            }
            return nil
        }
        var index = start
        while index < line.endIndex, line[index] != " ", line[index] != "\t" {
            index = line.index(after: index)
        }
        return (String(line[start..<index]), index)
    }

    // Path of a `--- `/`+++ ` marker line: quoted or running to the end of the line
    // (an unquoted name keeps its spaces; a trailing tab is trimmed), with the a//b/
    // prefix removed like the desktop parser.
    private static func markerPath(_ line: String, prefix: String) -> String {
        let start = line.index(line.startIndex, offsetBy: 4)
        if line[start] == "\"", let (path, _) = extractGitPath(line, from: start) {
            return path.hasPrefix(prefix) ? String(path.dropFirst(2)) : path
        }
        var tail = String(line[start...])
        if let tab = tail.firstIndex(of: "\t") {
            tail = String(tail[..<tab])
        }
        return tail.hasPrefix(prefix) ? String(tail.dropFirst(2)) : tail
    }

    // Splits the `diff --git` header into its two path tokens; each may be quoted and is
    // prefixed with `a/` or `b/` which is stripped. Unquoted paths keep their spaces, so
    // after a quoted-or-atomic first token the separator before the `b/` token is found
    // by checking which split yields equal paths (the common case); unequal pairs fall
    // back to the `---`/`+++` marker lines, which always carry the exact names.
    static func parseDiffGitPaths(_ line: String) -> (old: String, new: String)? {
        let start = line.index(line.startIndex, offsetBy: "diff --git ".count)
        guard let (oldRaw, afterOld) = extractGitPath(line, from: start) else { return nil }
        // A quoted first token ends unambiguously; the rest is the second token.
        if line[start] == "\"" {
            var index = afterOld
            while index < line.endIndex, line[index] == " " || line[index] == "\t" {
                index = line.index(after: index)
            }
            guard let (newRaw, _) = extractGitPath(line, from: index) else { return nil }
            return (stripGitPrefix(oldRaw), stripGitPrefix(newRaw))
        }
        // Unquoted: find " b/" such that the stripped paths are equal; otherwise the
        // pair is ambiguous and the marker lines decide.
        let body = line[start...]
        let marker = " b/"
        var search = body.startIndex
        while let range = body.range(of: marker, range: search..<body.endIndex) {
            // `range.upperBound` already sits after the ` b/` separator, so the new
            // path needs no prefix stripping; only the old side keeps its `a/` prefix.
            let oldCandidate = stripGitPrefix(String(body[..<range.lowerBound]))
            let newCandidate = String(body[range.upperBound...])
            if oldCandidate == newCandidate {
                return (oldCandidate, newCandidate)
            }
            search = range.upperBound
        }
        return nil
    }

    private static func stripGitPrefix(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            return String(path.dropFirst(2))
        }
        return path
    }

    // Same output shape as the desktop `parseGitDiff`.
    static func parse(_ rawDiff: String) -> GitDiffSummary {
        guard !rawDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return GitDiffSummary()
        }
        var summary = GitDiffSummary(rawDiff: rawDiff)
        let lines = splitLines(rawDiff)
        var index = 0

        while index < lines.count {
            let line = lines[index]
            guard line.hasPrefix("diff --git ") else {
                index += 1
                continue
            }

            var oldPath = ""
            var newPath = ""
            if let pair = parseDiffGitPaths(line) {
                oldPath = pair.old
                newPath = pair.new
            }
            var displayPath = newPath.isEmpty ? oldPath : newPath
            var status = GitFileStatus.modified
            var isBinary = false
            var fileAdditions = 0
            var fileDeletions = 0
            var hunks: [GitDiffHunk] = []

            index += 1
            while index < lines.count && !lines[index].hasPrefix("diff --git ") {
                let subLine = lines[index]

                if subLine.hasPrefix("new file mode") {
                    status = .added
                } else if subLine.hasPrefix("deleted file mode") {
                    status = .deleted
                } else if subLine.hasPrefix("similarity index") || subLine.hasPrefix("rename from") {
                    status = .renamed
                } else if subLine.hasPrefix("copy from") {
                    status = .copied
                }
                if subLine.hasPrefix("rename from ") {
                    oldPath = unquoteGitPath(String(subLine.dropFirst("rename from ".count)))
                } else if subLine.hasPrefix("rename to ") {
                    newPath = unquoteGitPath(String(subLine.dropFirst("rename to ".count)))
                    displayPath = newPath
                } else if subLine.hasPrefix("Binary files ") || subLine.hasPrefix("GIT binary patch") {
                    isBinary = true
                } else if subLine.hasPrefix("--- ") {
                    oldPath = markerPath(subLine, prefix: "a/")
                } else if subLine.hasPrefix("+++ ") {
                    newPath = markerPath(subLine, prefix: "b/")
                    displayPath = newPath
                } else if subLine.hasPrefix("@@ "),
                          let hunkMatch = subLine.firstMatch(of: hunkHeaderRegex) {
                    let oldStart = Int(hunkMatch.1) ?? 0
                    let oldLines = hunkMatch.2.flatMap { Int($0) } ?? 1
                    let newStart = Int(hunkMatch.3) ?? 0
                    let newLines = hunkMatch.4.flatMap { Int($0) } ?? 1
                    let heading = hunkMatch.5.trimmingCharacters(in: .whitespaces)

                    var hunkLines: [GitDiffLine] = []
                    var curOld = oldStart
                    var curNew = newStart

                    // The hunk body ends after oldLines context+delete and newLines
                    // context+add lines; a trailing empty line outside it is not content.
                    var remainingOld = oldLines
                    var remainingNew = newLines

                    index += 1
                    while index < lines.count {
                        let hLine = lines[index]
                        if hLine.hasPrefix("diff --git ") || hLine.hasPrefix("@@ ") {
                            break
                        }
                        if hLine.hasPrefix("+") {
                            guard remainingNew > 0 else { break }
                            remainingNew -= 1
                        } else if hLine.hasPrefix("-") {
                            guard remainingOld > 0 else { break }
                            remainingOld -= 1
                        } else if hLine.hasPrefix("\\ No newline at end of file") {
                            // Diff artifact, ignored like the desktop parser.
                        } else {
                            guard remainingOld > 0, remainingNew > 0 else { break }
                            remainingOld -= 1
                            remainingNew -= 1
                        }
                        if hLine.hasPrefix("+") {
                            fileAdditions += 1
                            hunkLines.append(GitDiffLine(
                                type: .add,
                                oldLineNumber: nil,
                                newLineNumber: curNew,
                                content: String(hLine.dropFirst())
                            ))
                            curNew += 1
                        } else if hLine.hasPrefix("-") {
                            fileDeletions += 1
                            hunkLines.append(GitDiffLine(
                                type: .delete,
                                oldLineNumber: curOld,
                                newLineNumber: nil,
                                content: String(hLine.dropFirst())
                            ))
                            curOld += 1
                        } else if !hLine.hasPrefix("\\ No newline at end of file") {
                            hunkLines.append(GitDiffLine(
                                type: .normal,
                                oldLineNumber: curOld,
                                newLineNumber: curNew,
                                content: hLine.hasPrefix(" ") ? String(hLine.dropFirst()) : hLine
                            ))
                            curOld += 1
                            curNew += 1
                        }
                        index += 1
                    }

                    hunks.append(GitDiffHunk(
                        oldStart: oldStart,
                        oldLines: oldLines,
                        newStart: newStart,
                        newLines: newLines,
                        heading: heading,
                        lines: hunkLines
                    ))
                    continue
                }
                index += 1
            }

            if displayPath == "/dev/null" || displayPath == "dev/null" || displayPath.isEmpty {
                displayPath = oldPath.isEmpty || oldPath == "/dev/null" ? newPath : oldPath
            }

            summary.totalAdditions += fileAdditions
            summary.totalDeletions += fileDeletions
            summary.files.append(GitDiffFile(
                oldPath: oldPath,
                newPath: newPath,
                displayPath: displayPath,
                status: status,
                additions: fileAdditions,
                deletions: fileDeletions,
                isBinary: isBinary,
                hunks: hunks
            ))
        }

        summary.totalFilesChanged = summary.files.count
        return summary
    }
}

// Loads the working-tree diff of a desktop project folder through `DesktopClient.runGit`,
// mirroring the desktop `loadGitDiff` (workingTree mode) and `loadGitRepoDetails`.
struct GitDiffLoader {
    let client: DesktopClient
    let cwd: String

    private func git(_ args: [String]) async -> (exitCode: Int, stdout: String)? {
        await client.runGit(args, cwd: cwd)
    }

    // Repo root, current/default branch, branch list, remote URL and cleanliness.
    func loadRepoDetails() async -> GitRepoDetails? {
        guard let rootResult = await git(["rev-parse", "--show-toplevel"]),
              rootResult.exitCode == 0
        else {
            return nil
        }
        let repoRoot = rootResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repoRoot.isEmpty else { return nil }

        let currentBranch: String? = await {
            guard let result = await git(["branch", "--show-current"]), result.exitCode == 0 else {
                return nil
            }
            let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }()

        var defaultBranch: String?
        if let refResult = await git(["symbolic-ref", "refs/remotes/origin/HEAD"]),
           refResult.exitCode == 0,
           let match = refResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
               .firstMatch(of: /refs\/remotes\/origin\/(.+)$/) {
            defaultBranch = String(match.1)
        }
        if defaultBranch == nil, let allResult = await git(["branch", "-a"]), allResult.exitCode == 0 {
            if allResult.stdout.contains("main") {
                defaultBranch = "main"
            } else if allResult.stdout.contains("master") {
                defaultBranch = "master"
            }
        }

        let branches: [String] = await {
            guard let result = await git(["for-each-ref", "--format=%(refname:short)", "refs/heads/"]),
                  result.exitCode == 0
            else {
                return []
            }
            return result.stdout
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }()

        let remoteUrl: String? = await {
            guard let result = await git(["config", "--get", "remote.origin.url"]),
                  result.exitCode == 0
            else {
                return nil
            }
            let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return url.isEmpty ? nil : url
        }()

        let isClean = await {
            guard let result = await git(["status", "--porcelain"]), result.exitCode == 0 else {
                return false
            }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }()

        return GitRepoDetails(
            repoRoot: repoRoot,
            currentBranch: currentBranch,
            defaultBranch: defaultBranch ?? "main",
            branches: branches,
            remoteUrl: remoteUrl,
            isClean: isClean
        )
    }

    // Working-tree diff vs HEAD plus untracked files (desktop `loadGitDiff` workingTree mode).
    // `repoRoot` resolves the root-relative paths git reports; it may differ from `cwd`
    // when the project folder is a subdirectory of the repository.
    func loadWorkingTreeDiff(repoRoot: String? = nil) async -> GitDiffSummary {
        var rawDiff = ""
        if let headResult = await git(["diff", "HEAD"]), headResult.exitCode == 0 {
            rawDiff = headResult.stdout
        } else {
            // No HEAD yet (unborn branch): `git diff` cannot express "everything is new",
            // so a synthetic diff of the whole worktree is built instead by diffing each
            // tracked/staged candidate against /dev/null below, like untracked files.
            rawDiff = ""
        }

        var summary = GitDiffParser.parse(rawDiff)

        // `-z` prints raw paths (no quoting) separated by NUL; quoted-path entries are
        // decoded by unquoteGitPath for display but used raw for git commands.
        guard let statusResult = await git(["status", "--porcelain", "-uall", "-z"]),
              statusResult.exitCode == 0,
              !statusResult.stdout.isEmpty
        else {
            return summary
        }

        // With no HEAD yet, staged and modified files are also "new" relative to the
        // empty tree, so they join untracked files in the /dev/null comparison below.
        let hasHead = await git(["rev-parse", "--verify", "HEAD"])?.exitCode == 0
        let diffCwd = repoRoot ?? cwd
        for statusEntry in statusResult.stdout.components(separatedBy: "\0") {
            guard statusEntry.count >= 4 else { continue }
            let code = statusEntry.prefix(2)
            let isUntracked = code == "??"
            guard isUntracked || !hasHead else { continue }
            let untrackedPath = String(statusEntry.dropFirst(3))
            guard !untrackedPath.isEmpty,
                  !summary.files.contains(where: { $0.displayPath == untrackedPath })
            else {
                continue
            }

            var parsedFile: GitDiffFile?
            if let diffResult = await client.runGit(
                ["diff", "--no-index", "--", "/dev/null", untrackedPath],
                cwd: diffCwd
            ),
               !diffResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parsedFile = GitDiffParser.parse(diffResult.stdout).files.first
            }

            if let parsedFile {
                summary.files.append(GitDiffFile(
                    oldPath: untrackedPath,
                    newPath: untrackedPath,
                    displayPath: untrackedPath,
                    status: isUntracked ? .untracked : .added,
                    additions: parsedFile.additions,
                    deletions: parsedFile.deletions,
                    isBinary: parsedFile.isBinary,
                    hunks: parsedFile.hunks
                ))
                summary.totalAdditions += parsedFile.additions
                summary.totalFilesChanged += 1
            } else if isUntracked {
                // An untracked file with no diff output is empty or unreadable; it is
                // listed without line counts, like the desktop's fallback entry.
                summary.files.append(GitDiffFile(
                    oldPath: untrackedPath,
                    newPath: untrackedPath,
                    displayPath: untrackedPath,
                    status: .untracked,
                    additions: 0,
                    deletions: 0,
                    isBinary: false,
                    hunks: []
                ))
                summary.totalFilesChanged += 1
            }
            // A staged-but-worktree-deleted file has no counterpart in the empty-tree
            // comparison, so a failed diff skips it entirely (desktop behavior).
        }

        return summary
    }

    // Branch comparison diff `origin/base...target` (desktop `loadGitDiff` branch mode).
    // The base is always the remote-tracking ref the panel labels; no local fallback,
    // so the shown `origin/base` always matches what was actually compared.
    func loadBranchDiff(base: String, target: String) async -> GitDiffSummary? {
        guard let result = await git(["diff", "origin/\(base)...\(target)"]),
              result.exitCode == 0
        else {
            return nil
        }
        return GitDiffParser.parse(result.stdout)
    }
}
