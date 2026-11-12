import Foundation

// Composer content in the desktop's canonical form: plain text where every skill chip is a `$name`
// token, plus the chip positions. All offsets are UTF-16 based to match the desktop (JavaScript).
struct ComposerDraft: Equatable {
    enum Part: Equatable {
        case text(String)
        case skill(String)
    }

    var text = ""
    var references: [SkillReference] = []
    // Caret offset in `text`; nil means the end.
    var cursor: Int?

    init(text: String = "", references: [SkillReference] = [], cursor: Int? = nil) {
        self.text = text
        self.references = references
        self.cursor = cursor
    }

    // Draft holding the given text runs and chips, with the caret at the end.
    init(parts: [Part]) {
        var units: [UInt16] = []
        var references: [SkillReference] = []
        for part in parts {
            switch part {
            case .text(let text):
                units += Array(text.utf16)
            case .skill(let name):
                references.append(SkillReference(start: units.count, name: name))
                units += Array("$\(name)".utf16)
            }
        }
        self.init(text: Self.string(units), references: references)
    }

    var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var caret: Int {
        let length = text.utf16.count
        return min(max(cursor ?? length, 0), length)
    }

    // References that really point at a `$name` token, in order and without overlaps.
    var validReferences: [SkillReference] {
        let units = Array(text.utf16)
        var result: [SkillReference] = []
        var previousEnd = 0
        for reference in references.sorted(by: { $0.start < $1.start }) {
            // Bounds are checked before `end` so remote offsets cannot overflow.
            guard reference.start >= previousEnd,
                  reference.start <= units.count - reference.length,
                  Array(units[reference.start..<reference.end]) == Array("$\(reference.name)".utf16)
            else {
                continue
            }
            result.append(reference)
            previousEnd = reference.end
        }
        return result
    }

    // Text runs and chips in display order.
    var parts: [Part] {
        let units = Array(text.utf16)
        var parts: [Part] = []
        var offset = 0
        for reference in validReferences {
            if reference.start > offset {
                parts.append(.text(Self.string(units[offset..<reference.start])))
            }
            parts.append(.skill(reference.name))
            offset = reference.end
        }
        if offset < units.count {
            parts.append(.text(Self.string(units[offset...])))
        }
        return parts
    }

    // Query of a slash command when the whole draft is a single `/command` token (desktop `getSlashQuery`).
    var slashQuery: String? {
        guard validReferences.isEmpty else { return nil }
        let command = text.drop(while: \.isWhitespace)
        guard command.first == "/", !command.contains(where: \.isWhitespace) else { return nil }
        return String(command.dropFirst())
    }

    // Query typed after the skill trigger right before the caret (desktop `getSkillQuery`); chips never match.
    func skillQuery(trigger: SkillTrigger) -> String? {
        let units = Array(text.utf16)
        let caret = self.caret
        var index = caret - 1
        while index >= 0, Self.isNameUnit(units[index]) {
            index -= 1
        }
        guard index >= 0, units[index] == trigger.unit, Self.isBoundary(units, at: index) else { return nil }
        guard !validReferences.contains(where: { index >= $0.start && index < $0.end }) else { return nil }
        return Self.string(units[(index + 1)..<caret])
    }

    // Replaces the active trigger query with a `$name` chip followed by a space (desktop `insertSkillInParts`).
    func insertingSkill(_ name: String, trigger: SkillTrigger) -> ComposerDraft? {
        guard let query = skillQuery(trigger: trigger) else { return nil }
        let caret = self.caret
        let start = caret - query.utf16.count - 1
        let replacement = "$\(name) "
        let units = Array(text.utf16)
        let newText = Self.string(units[..<start]) + replacement + Self.string(units[caret...])
        let delta = replacement.utf16.count - (caret - start)
        let existing = validReferences
        let references = existing.filter { $0.end <= start }
            + [SkillReference(start: start, name: name)]
            + existing.filter { $0.start >= caret }.map { SkillReference(start: $0.start + delta, name: $0.name) }
        return ComposerDraft(text: newText, references: references, cursor: start + replacement.utf16.count)
    }

    // Plain text where chips are written like the desktop clipboard (`formatSkillDraftForClipboard`):
    // `#name`, `$name` or the explicit `/skill:name`, which `payload` folds back into chips.
    func plainText(trigger: SkillTrigger) -> String {
        Self.plainText(of: parts, trigger: trigger)
    }

    static func plainText(of parts: [Part], trigger: SkillTrigger) -> String {
        parts.map { part in
            switch part {
            case .text(let text): text
            case .skill(let name): (trigger == .slash ? "/skill:" : trigger.rawValue) + name
            }
        }.joined()
    }

    // Text and skill references to send: typed trigger tokens of known skills (e.g. `#name`) become
    // `$name` references (desktop `normalizeSkillDraft`) and surrounding whitespace is trimmed
    // (`trimTextWithSkillReferences`). With the "/" trigger, a leading built-in command stays text
    // and the explicit `/skill:name` form is accepted as well.
    func payload(knownSkills: [RemoteSkill], trigger: SkillTrigger) -> (text: String, references: [SkillReference]) {
        var canonicalNames: [String: String] = [:]
        for skill in knownSkills where canonicalNames[skill.name.lowercased()] == nil {
            canonicalNames[skill.name.lowercased()] = skill.name
        }

        var output: [UInt16] = []
        var references: [SkillReference] = []
        for part in parts {
            switch part {
            case .skill(let name):
                references.append(SkillReference(start: output.count, name: name))
                output += Array("$\(name)".utf16)
            case .text(let segment):
                let units = Array(segment.utf16)
                var index = 0
                while index < units.count {
                    if units[index] == trigger.unit, Self.isBoundary(units, at: index) {
                        let isExplicit = trigger == .slash && units[(index + 1)...].starts(with: Self.explicitSkillPrefix)
                        let nameStart = index + 1 + (isExplicit ? Self.explicitSkillPrefix.count : 0)
                        var end = nameStart
                        while end < units.count, Self.isNameUnit(units[end]) {
                            end += 1
                        }
                        let followedBySpace = end == units.count || Self.isWhitespace(units[end])
                        let token = Self.string(units[nameStart..<end]).lowercased()
                        let isLeadingCommand = trigger == .slash
                            && !isExplicit
                            && Self.reservedSlashNames.contains(token)
                            && output.allSatisfy(Self.isWhitespace)
                        if end > nameStart, followedBySpace, !isLeadingCommand, let name = canonicalNames[token] {
                            references.append(SkillReference(start: output.count, name: name))
                            output += Array("$\(name)".utf16)
                            index = end
                            continue
                        }
                    }
                    output.append(units[index])
                    index += 1
                }
            }
        }

        var lower = 0
        var upper = output.count
        while lower < upper, Self.isWhitespace(output[lower]) {
            lower += 1
        }
        while upper > lower, Self.isWhitespace(output[upper - 1]) {
            upper -= 1
        }
        let trimmed = references
            .filter { $0.start >= lower && $0.end <= upper }
            .map { SkillReference(start: $0.start - lower, name: $0.name) }
        return (Self.string(output[lower..<upper]), trimmed)
    }

    // Chips of a stored prompt without references (older records), like the desktop message bubble:
    // `$name` and `/skill:name` tokens of known skills (`parseSkillDraft`), else a whole prompt written
    // as a skill command (`matchSkillPresentation`). Unlike `payload`, the text is kept as is.
    static func legacyParts(of text: String, knownSkills: [RemoteSkill]) -> [Part] {
        var canonicalNames: [String: String] = [:]
        for skill in knownSkills where canonicalNames[skill.name.lowercased()] == nil {
            canonicalNames[skill.name.lowercased()] = skill.name
        }
        let units = Array(text.utf16)
        var parts: [Part] = []
        var offset = 0
        var index = 0
        while index < units.count {
            let prefix = units[index] == SkillTrigger.dollar.unit ? 1
                : units[index...].starts(with: slashSkillPrefix) ? slashSkillPrefix.count : 0
            if prefix > 0, isBoundary(units, at: index) {
                var end = index + prefix
                while end < units.count, isNameUnit(units[end]) {
                    end += 1
                }
                if end > index + prefix, end == units.count || isWhitespace(units[end]),
                   let name = canonicalNames[string(units[(index + prefix)..<end]).lowercased()] {
                    if index > offset {
                        parts.append(.text(string(units[offset..<index])))
                    }
                    parts.append(.skill(name))
                    offset = end
                    index = end
                    continue
                }
            }
            index += 1
        }
        if parts.isEmpty, let command = skillCommandParts(text) {
            return command
        }
        if offset < units.count {
            parts.append(.text(string(units[offset...])))
        }
        return parts
    }

    // A prompt such as `$name args` or `/skill:name args`, shown as a chip and its arguments
    // even for skills that are not installed (desktop `parseSkillCommand`).
    private static func skillCommandParts(_ text: String) -> [Part]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rest: Substring
        if trimmed.hasPrefix("/skill:") {
            rest = trimmed.dropFirst("/skill:".count)
        } else if trimmed.hasPrefix("$") {
            rest = trimmed.dropFirst()
        } else {
            return nil
        }
        let name = rest.prefix { $0 != " " }
        guard !name.isEmpty else { return nil }
        let args = rest.dropFirst(name.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
        return args.isEmpty ? [.skill(String(name))] : [.skill(String(name)), .text(" " + args)]
    }

    // MARK: - Character classes

    // Desktop built-in slash commands (`COMPACT_COMMAND_ALIASES`, `MODEL_COMMAND_ALIASES`) that can be skill names.
    private static let reservedSlashNames: Set<String> = ["compact", "compress", "model", "models"]
    private static let explicitSkillPrefix = Array("skill:".utf16)
    private static let slashSkillPrefix = Array("/skill:".utf16)

    private static func string<S: Sequence>(_ units: S) -> String where S.Element == UInt16 {
        String(decoding: Array(units), as: UTF16.self)
    }

    private static func scalar(_ unit: UInt16) -> Unicode.Scalar? {
        UTF16.isLeadSurrogate(unit) || UTF16.isTrailSurrogate(unit) ? nil : Unicode.Scalar(unit)
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        scalar(unit)?.properties.isWhitespace ?? false
    }

    // `[a-z0-9-]`, case-insensitive.
    private static func isNameUnit(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D: true
        default: false
        }
    }

    // A trigger starts a token at the beginning or after whitespace/punctuation other than `#$/\`.
    private static func isBoundary(_ units: [UInt16], at index: Int) -> Bool {
        guard index > 0 else { return true }
        guard let previous = scalar(units[index - 1]) else { return false }
        if "#$/\\".unicodeScalars.contains(previous) {
            return false
        }
        if previous.properties.isWhitespace {
            return true
        }
        switch previous.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }
}
