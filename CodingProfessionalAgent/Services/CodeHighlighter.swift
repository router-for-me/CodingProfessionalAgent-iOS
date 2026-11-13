import Foundation
import SwiftUI

// Lightweight regex-based syntax highlighting, approximating the desktop panels'
// highlight.js output for the common languages in this project (Go, Swift, TS/JS,
// Python, JSON/YAML/TOML, shell, markdown…). Colors follow the diff screenshot:
// keywords purple, strings red, comments green, numbers blue, types teal.

enum CodeHighlighter {
    struct Palette {
        var keyword: Color
        var string: Color
        var comment: Color
        var number: Color
        var type: Color
        var base: Color

        static let light = Palette(
            keyword: Color(red: 0.61, green: 0.16, blue: 0.70),
            string: Color(red: 0.77, green: 0.10, blue: 0.09),
            comment: Color(red: 0.16, green: 0.51, blue: 0.24),
            number: Color(red: 0.11, green: 0.29, blue: 0.85),
            type: Color(red: 0.16, green: 0.45, blue: 0.55),
            base: Color(.label)
        )

        static let dark = Palette(
            keyword: Color(red: 0.85, green: 0.47, blue: 0.92),
            string: Color(red: 0.98, green: 0.55, blue: 0.52),
            comment: Color(red: 0.47, green: 0.75, blue: 0.47),
            number: Color(red: 0.55, green: 0.67, blue: 0.98),
            type: Color(red: 0.45, green: 0.78, blue: 0.78),
            base: Color(.label)
        )
    }

    private enum CommentStyle {
        case slash
        case hash
        case none
    }

    // File extension -> language id (subset of the desktop EXT_TO_LANGUAGE map).
    private static let slashCommentExts: Set<String> = [
        "ts", "tsx", "js", "jsx", "mjs", "cjs", "go", "rs", "java", "c", "h", "cpp",
        "hpp", "cc", "cxx", "cs", "swift", "kt", "kts", "scala", "php", "json", "jsonc",
        "css", "scss", "sass", "less",
    ]
    private static let hashCommentExts: Set<String> = [
        "py", "pyw", "rb", "sh", "bash", "zsh", "fish", "ps1", "psm1", "yaml", "yml",
        "toml", "pl", "pm", "r", "make", "mk", "dockerfile", "conf", "ini", "env",
    ]

    private static let commonKeywords: Set<String> = [
        "func", "function", "return", "if", "else", "for", "while", "switch", "case",
        "default", "break", "continue", "struct", "class", "enum", "interface", "type",
        "import", "package", "from", "export", "let", "var", "const", "static", "final",
        "public", "private", "protected", "internal", "open", "override", "async", "await",
        "try", "catch", "throw", "throws", "raise", "except", "finally", "defer", "go",
        "chan", "select", "map", "range", "nil", "null", "None", "true", "false", "True",
        "False", "this", "self", "super", "new", "delete", "in", "is", "not", "and", "or",
        "def", "elif", "lambda", "with", "as", "pass", "yield", "impl", "trait", "pub",
        "use", "mod", "fn", "mut", "match", "where", "guard", "protocol", "extension",
        "some", "any", "do", "then", "end", "begin", "local", "readonly", "declare",
    ]

    static func languageExtension(of fileName: String) -> String {
        let name = fileName.lowercased()
        if name == "dockerfile" || name.hasPrefix("dockerfile.") { return "dockerfile" }
        if name == "makefile" || name.hasSuffix(".mk") { return "make" }
        return (name as NSString).pathExtension
    }

    private static func commentStyle(for fileName: String) -> CommentStyle {
        let ext = languageExtension(of: fileName)
        if hashCommentExts.contains(ext) { return .hash }
        if slashCommentExts.contains(ext) { return .slash }
        return .none
    }

    // Highlights one line as an AttributedString; multi-line block comments are not
    // tracked (each line is scored independently), which is accurate enough for
    // diff and file previews.
    static func highlight(_ line: String, fileName: String, palette: Palette) -> AttributedString {
        var result = AttributedString(line)
        result.foregroundColor = palette.base
        guard !line.isEmpty else { return result }

        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        let style = commentStyle(for: fileName)

        // 1. Comments — scored first so strings inside comments are not colored.
        var commentRange: NSRange?
        switch style {
        case .slash:
            if let range = matchRange(in: nsLine, pattern: #"//.*$"#) {
                // `://` inside a string (e.g. URLs) is still rare enough to accept;
                // a quote before the marker means the marker is inside a string.
                commentRange = range
            }
        case .hash:
            if let range = matchRange(in: nsLine, pattern: #"(?<![\w$])#.*$"#) {
                commentRange = range
            }
        case .none:
            break
        }
        if let commentRange {
            apply(&result, color: palette.comment, range: commentRange, in: line)
        }

        // 2. Strings (single, double, back quotes) outside of comments.
        let stringPattern = #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#
        for range in matchRanges(in: nsLine, pattern: stringPattern) {
            guard !overlaps(range, commentRange) else { continue }
            apply(&result, color: palette.string, range: range, in: line)
        }

        // 3. Keywords (whole word).
        for range in matchRanges(in: nsLine, pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#) {
            guard !overlaps(range, commentRange) else { continue }
            let word = nsLine.substring(with: range)
            if commonKeywords.contains(word) {
                apply(&result, color: palette.keyword, range: range, in: line)
            }
        }

        // 4. Numbers.
        for range in matchRanges(in: nsLine, pattern: #"\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#) {
            guard !overlaps(range, commentRange) else { continue }
            apply(&result, color: palette.number, range: range, in: line)
        }

        // 5. Capitalized identifiers (types) — only when clearly a type-like token.
        for range in matchRanges(in: nsLine, pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#) {
            guard !overlaps(range, commentRange) else { continue }
            apply(&result, color: palette.type, range: range, in: line)
        }

        _ = fullRange
        return result
    }

    private static func matchRange(in nsLine: NSString, pattern: String) -> NSRange? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(in: nsLine as String, range: NSRange(location: 0, length: nsLine.length))?.range
    }

    private static func matchRanges(in nsLine: NSString, pattern: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex
            .matches(in: nsLine as String, range: NSRange(location: 0, length: nsLine.length))
            .map(\.range)
    }

    private static func overlaps(_ range: NSRange, _ other: NSRange?) -> Bool {
        guard let other else { return false }
        return NSIntersectionRange(range, other).length > 0
    }

    private static func apply(_ text: inout AttributedString, color: Color, range: NSRange, in line: String) {
        guard let swiftRange = Range(range, in: line),
              let attributedRange = Range(swiftRange, in: text)
        else {
            return
        }
        text[attributedRange].foregroundColor = color
    }
}
