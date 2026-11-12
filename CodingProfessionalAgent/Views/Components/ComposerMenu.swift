import SwiftUI

// Command of the composer's "/" menu; selecting it takes effect immediately.
struct SlashCommand: Identifiable {
    let id: String
    let systemImage: String
    let title: String
    let subtitle: String
    // Lowercased names matched by prefix against the typed query.
    let keywords: [String]
    var dismissesKeyboard = false
    let action: () -> Void

    static func fast(isOn: Bool, action: @escaping () -> Void) -> SlashCommand {
        SlashCommand(
            id: "fast",
            systemImage: "bolt.fill",
            title: "快速",
            subtitle: isOn ? "已开启，选择后恢复标准速度" : "提升响应速度，用量增加",
            keywords: ["fast", "speed", "快速", "kuaisu"],
            action: action
        )
    }

    // Compacts the conversation context on the desktop (desktop `/compact`).
    static func compact(action: @escaping () -> Void) -> SlashCommand {
        SlashCommand(
            id: "compact",
            systemImage: "arrow.down.right.and.arrow.up.left",
            title: "压缩",
            subtitle: "压缩对话上下文",
            keywords: ["compact", "compress", "压缩", "yasuo"],
            dismissesKeyboard: true,
            action: action
        )
    }

    static func model(current: String?, action: @escaping () -> Void) -> SlashCommand {
        SlashCommand(
            id: "model",
            systemImage: "cpu",
            title: "模型",
            subtitle: current.map { "当前：\($0)" } ?? "选择模型与推理强度",
            keywords: ["model", "models", "模型", "moxing"],
            dismissesKeyboard: true,
            action: action
        )
    }
}

// Row of the "/" (commands) or skill trigger menu.
struct ComposerMenuItem: Identifiable {
    enum Target {
        case command(SlashCommand)
        case skill(RemoteSkill)
    }

    let target: Target

    var id: String {
        switch target {
        case .command(let command): "command:\(command.id)"
        case .skill(let skill): "skill:\(skill.id)"
        }
    }
}

enum ComposerMenu {
    // Suggestions for the token being typed: "/" at the start of the draft or the skill trigger before
    // the caret. With the "/" trigger, skills join the command menu like the desktop composer.
    static func items(
        for draft: ComposerDraft,
        commands: [SlashCommand],
        skills: [RemoteSkill],
        trigger: SkillTrigger
    ) -> [ComposerMenuItem] {
        if let query = draft.slashQuery?.lowercased() {
            let matchedCommands = commands
                .filter { command in query.isEmpty || command.keywords.contains { $0.hasPrefix(query) } }
                .map { ComposerMenuItem(target: .command($0)) }
            guard trigger == .slash else { return matchedCommands }
            return matchedCommands + matchingSkills(skills, query: query, trigger: trigger)
        }
        if let query = draft.skillQuery(trigger: trigger)?.lowercased() {
            return matchingSkills(skills, query: query, trigger: trigger)
        }
        return []
    }

    // The desktop's "/" menu matches skill names by prefix, its "$" and "#" menus by substring.
    private static func matchingSkills(_ skills: [RemoteSkill], query: String, trigger: SkillTrigger) -> [ComposerMenuItem] {
        skills
            .filter { skill in
                let name = skill.name.lowercased()
                return query.isEmpty || (trigger == .slash ? name.hasPrefix(query) : name.contains(query))
            }
            .map { ComposerMenuItem(target: .skill($0)) }
    }

    // Commands clear the typed "/command" and run at once; skills become a chip at the caret.
    @MainActor
    static func select(
        _ item: ComposerMenuItem,
        draft: Binding<ComposerDraft>,
        isFocused: Binding<Bool>,
        trigger: SkillTrigger
    ) {
        switch item.target {
        case .command(let command):
            draft.wrappedValue = ComposerDraft()
            if command.dismissesKeyboard {
                isFocused.wrappedValue = false
            }
            command.action()
        case .skill(let skill):
            if let next = draft.wrappedValue.insertingSkill(skill.name, trigger: trigger) {
                draft.wrappedValue = next
            }
        }
    }
}

// Floating card shown above the composer; the first row is the one picked by the return key.
struct ComposerSuggestionMenu: View {
    let items: [ComposerMenuItem]
    let onSelect: (ComposerMenuItem) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        onSelect(item)
                    } label: {
                        ComposerMenuRow(item: item, isActive: index == 0)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(7)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 236)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

private struct ComposerMenuRow: View {
    let item: ComposerMenuItem
    let isActive: Bool

    private var systemImage: String {
        switch item.target {
        case .command(let command): command.systemImage
        case .skill: "sparkles"
        }
    }

    private var title: String {
        switch item.target {
        case .command(let command): command.title
        case .skill(let skill): skill.displayName
        }
    }

    private var subtitle: String {
        switch item.target {
        case .command(let command):
            command.subtitle
        case .skill(let skill):
            skill.description.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    private var kind: String {
        switch item.target {
        case .command: "命令"
        case .skill: "技能"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(Color.secondary)
                .frame(width: 26, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 8)
            Text(kind)
                .font(.system(size: 13))
                .foregroundStyle(Color.secondary)
                .padding(.top, 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isActive ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
    }
}

extension View {
    // Places the suggestion menu right above the modified composer without affecting its layout.
    func composerSuggestionMenu(_ items: [ComposerMenuItem], onSelect: @escaping (ComposerMenuItem) -> Void) -> some View {
        overlay(alignment: .top) {
            if !items.isEmpty {
                ComposerMenuOverlay(items: items, onSelect: onSelect)
            }
        }
    }

    // Short confirmation at the top of the screen, e.g. after toggling fast mode.
    func transientNotice(_ notice: Binding<String?>) -> some View {
        modifier(TransientNoticeModifier(notice: notice))
    }
}

// Lifts the menu by its own height so its bottom sits 10pt above the composer.
private struct ComposerMenuOverlay: View {
    let items: [ComposerMenuItem]
    let onSelect: (ComposerMenuItem) -> Void
    @State private var height: CGFloat = 0

    var body: some View {
        ComposerSuggestionMenu(items: items, onSelect: onSelect)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newValue in
                height = newValue
            }
            .offset(y: -(height + 10))
            // Hidden until measured so it never flashes over the composer.
            .opacity(height > 0 ? 1 : 0)
    }
}

private struct TransientNoticeModifier: ViewModifier {
    @Binding var notice: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let notice {
                    Text(notice)
                        .font(.system(size: 15, weight: .medium))
                        .padding(.horizontal, 16)
                        .frame(height: 38)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.snappy, value: notice)
            .task(id: notice) {
                guard notice != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled {
                    notice = nil
                }
            }
    }
}
