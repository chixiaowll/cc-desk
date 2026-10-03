import SwiftUI
import AppKit
import CCDeskCore

/// 目录行时钟按钮弹出的历史会话列表（界面稿 `.pop`）。
struct HistoryPopover: View {
    @ObservedObject var model: AppModel
    let root: String
    let title: String
    let onSearchAll: () -> Void
    let onResume: (HistoryItem) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""

    var body: some View {
        let theme = Theme.of(colorScheme)
        let entries = model.history(forRoot: root)
        let filtered = entries.filter { query.isEmpty || $0.item.title.localizedCaseInsensitiveContains(query) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(L("history.popover.title", title)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Text(L("history.popover.count", entries.count)).fontWeight(.medium).foregroundStyle(theme.fg3)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.fg2)
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .padding(.bottom, 8)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(theme.fg3)
                TextField("", text: $query, prompt: Text(L("history.popover.search")).foregroundColor(theme.fg3))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.fg1)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.side))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line, lineWidth: 1))
            .padding(.bottom, 4)

            if filtered.isEmpty {
                Text(L("history.noMatches"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.fg3)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { entry in
                            HistoryPopoverRow(item: entry.item, now: model.now, theme: theme,
                                              showAgent: model.showAgentLabel)
                                .onTapGesture { onResume(entry.item) }
                        }
                    }
                }
                .frame(height: min(CGFloat(filtered.count) * 32, 260))
            }

            Button(action: onSearchAll) {
                HStack {
                    Text(L("history.searchAll"))
                    Spacer()
                    KeyCap(text: "⌘⇧H", theme: theme)
                }
                .font(.system(size: 11.5))
                .padding(.horizontal, 8)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverTextButtonStyle(normal: theme.fg2, hover: theme.fg1))
            .overlay(alignment: .top) { theme.line.frame(height: 1) }
            .padding(.top, 4)
        }
        .padding(8)
        .frame(width: 300)
        .background(theme.main)
    }
}

struct HistoryPopoverRow: View {
    let item: HistoryItem
    let now: Date
    let theme: Theme
    var showAgent: Bool = AgentLabelPolicy.showAgentLabel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(item.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(hovering ? theme.fg1 : theme.fg2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showAgent { AgentTag(kind: item.kind, theme: theme) }
            if hovering {
                ResumeLabel(theme: theme)
            } else {
                Text(RelativeTime.short(from: item.modifiedAt, now: now))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(theme.fg3)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? theme.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(historyHelp(item))
    }
}

/// 全局历史搜索面板（⌘⇧H / 工具栏时钟）：按「今天 / 昨天 / 更早」分组；↑↓ 选择、↩ 恢复、esc 关闭。
struct HistoryPalette: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""
    @State private var selection = 0
    /// 按 agent 过滤；nil 为全部。
    @State private var agentFilter: AgentKind?

    private struct Section: Identifiable {
        let label: String
        let entries: [HistoryEntry]
        var id: String { label }
    }

    var body: some View {
        let theme = Theme.of(colorScheme)
        let sections = makeSections()
        let flat = sections.flatMap(\.entries)
        ZStack(alignment: .top) {
            theme.backdrop
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }
            panel(theme: theme, sections: sections, flat: flat)
                .padding(.top, 44)
                .padding(.horizontal, 16)
        }
        .onExitCommand { close() }
    }

    private func panel(theme: Theme, sections: [Section], flat: [HistoryEntry]) -> some View {
        let active = flat.indices.contains(selection) ? flat[selection].id : nil
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(theme.fg3)
                PaletteSearchField(
                    text: $query,
                    placeholder: L("history.palette.search"),
                    textColor: NSColor(theme.fg1),
                    placeholderColor: NSColor(theme.fg3),
                    onMove: { delta in
                        guard !flat.isEmpty else { return }
                        selection = min(max(0, selection + delta), flat.count - 1)
                    },
                    onSubmit: {
                        if flat.indices.contains(selection) { resume(flat[selection].item) }
                    },
                    onCancel: { close() })
                KeyCap(text: "esc", theme: theme)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .overlay(alignment: .bottom) { theme.line.frame(height: 1) }

            let kinds = AgentKind.launchable.filter { kind in model.history.contains { $0.item.kind == kind } }
            if kinds.count >= 2 {
                HStack(spacing: 6) {
                    AgentFilterChip(title: L("history.filter.all"), selected: agentFilter == nil, theme: theme) { agentFilter = nil; selection = 0 }
                    ForEach(kinds, id: \.self) { kind in
                        AgentFilterChip(title: kind.displayName, selected: agentFilter == kind, theme: theme) {
                            agentFilter = agentFilter == kind ? nil : kind
                            selection = 0
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
            }

            if flat.isEmpty {
                Text(L("history.noMatches"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.fg3)
                    .padding(.vertical, 24)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(sections) { section in
                                Text(section.label)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(theme.fg3)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                                ForEach(section.entries) { entry in
                                    PaletteRow(entry: entry, active: entry.id == active, now: model.now, theme: theme,
                                               showAgent: model.showAgentLabel)
                                        .id(entry.id)
                                        .onHover { inside in
                                            if inside, let index = flat.firstIndex(where: { $0.id == entry.id }) {
                                                selection = index
                                            }
                                        }
                                        .onTapGesture { resume(entry.item) }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                        .padding(.bottom, 8)
                    }
                    .frame(height: min(contentHeight(sections: sections), 560 - 50 - 34))
                    .onChange(of: selection) { _, newValue in
                        if flat.indices.contains(newValue) { proxy.scrollTo(flat[newValue].id) }
                    }
                }
            }

            HStack(spacing: 14) {
                HStack(spacing: 3) { KeyCap(text: "↑", theme: theme); KeyCap(text: "↓", theme: theme); Text(L("history.hint.select")) }
                HStack(spacing: 3) { KeyCap(text: "↩", theme: theme); Text(L("history.hint.resume")) }
                HStack(spacing: 3) { KeyCap(text: "esc", theme: theme); Text(L("history.hint.close")) }
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.fg3)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .overlay(alignment: .top) { theme.line.frame(height: 1) }
        }
        .frame(maxWidth: 560)
        .background(theme.main)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.line, lineWidth: 1))
        .shadow(color: theme.popShadow, radius: 30, y: 24)
        .onChange(of: query) { _, _ in selection = 0 }
    }

    /// 估算列表内容高度，使面板随内容收缩（最大 560）。
    private func contentHeight(sections: [Section]) -> CGFloat {
        14 + CGFloat(sections.count) * 28 + CGFloat(sections.reduce(0) { $0 + $1.entries.count }) * 36
    }

    private func makeSections() -> [Section] {
        let entries = model.history.filter { entry in
            (agentFilter == nil || entry.item.kind == agentFilter)
                && (query.isEmpty || (entry.item.title + entry.projectTitle).localizedCaseInsensitiveContains(query))
        }
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return HistoryGrouping.byDay(entries.map(\.item), now: model.now).map { group in
            Section(label: group.label, entries: group.items.compactMap { byID[$0.id] })
        }
    }

    private func resume(_ item: HistoryItem) {
        model.showHistoryPalette = false
        model.resumeHistory(item)
    }

    private func close() {
        model.showHistoryPalette = false
        model.focusSelectedTerminal()
    }
}

struct PaletteRow: View {
    let entry: HistoryEntry
    let active: Bool
    let now: Date
    let theme: Theme
    var showAgent: Bool = AgentLabelPolicy.showAgentLabel

    var body: some View {
        HStack(spacing: 10) {
            Text(entry.item.title)
                .font(.system(size: 13))
                .foregroundStyle(theme.fg1)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.tagText(entry.projectTitle))
                .font(.system(size: 11))
                .foregroundStyle(theme.fg2)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.chip))
            if showAgent { AgentTag(kind: entry.item.kind, theme: theme) }
            Group {
                if active {
                    Text(L("history.row.resumeHint")).fontWeight(.semibold).foregroundStyle(theme.action)
                } else {
                    Text(RelativeTime.short(from: entry.item.modifiedAt, now: now)).foregroundStyle(theme.fg3)
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .frame(minWidth: 40, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 8).fill(active ? theme.hover : Color.clear))
        .contentShape(Rectangle())
        .help(historyHelp(entry.item))
    }

    /// 目录标签最宽 160pt（含 12pt 内边距）：按 11pt 字号估算宽度，超出时截断并加省略号。
    static func tagText(_ text: String) -> String {
        let font = NSFont.systemFont(ofSize: 11)
        let limit: CGFloat = 148
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        guard width(text) > limit else { return text }
        var prefix = ""
        for ch in text {
            if width(prefix + String(ch) + "…") > limit { break }
            prefix.append(ch)
        }
        return prefix + "…"
    }
}

/// 历史搜索面板的 agent 过滤胶囊。
struct AgentFilterChip: View {
    let title: String
    let selected: Bool
    let theme: Theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? theme.fg1 : theme.fg3)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 历史行上的小号灰色 agent 名（如「Claude」）。
struct AgentTag: View {
    let kind: AgentKind
    let theme: Theme

    var body: some View {
        Text(kind.displayName)
            .font(.system(size: 10.5))
            .foregroundStyle(theme.fg3)
            .lineLimit(1)
            .fixedSize()
    }
}

/// 「↩ 恢复」悬停标签。
struct ResumeLabel: View {
    let theme: Theme

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.uturn.backward").font(.system(size: 9, weight: .semibold))
            Text(L("action.resume"))
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(theme.action)
    }
}

/// 键帽样式（如 ⌘⇧H、esc）。
struct KeyCap: View {
    let text: String
    let theme: Theme

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(theme.fg3)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(theme.side))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.line, lineWidth: 1))
    }
}

struct HoverTextButtonStyle: ButtonStyle {
    let normal: Color
    let hover: Color

    func makeBody(configuration: Configuration) -> some View {
        HoverTextButton(configuration: configuration, normal: normal, hover: hover)
    }

    private struct HoverTextButton: View {
        let configuration: Configuration
        let normal: Color
        let hover: Color
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? hover : normal)
                .onHover { hovering = $0 }
        }
    }
}

private func historyHelp(_ item: HistoryItem) -> String {
    var text = "\(item.title)\n\(item.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
    if let prompt = item.lastPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
        let line = prompt.components(separatedBy: .newlines).joined(separator: " ")
        text += "\n" + L("history.tooltip.recent", line.count > 80 ? String(line.prefix(80)) + "…" : line)
    }
    return text
}

/// 面板的搜索框：AppKit NSTextField，以便可靠地拦截 ↑↓ / ↩ / esc，并在出现时自动聚焦。
struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let textColor: NSColor
    let placeholderColor: NSColor
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    final class Field: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteSearchField

        init(_ parent: PaletteSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1); return true
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1); return true
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            default: return false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.textColor = textColor
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: placeholderColor, .font: NSFont.systemFont(ofSize: 15)])
    }
}
