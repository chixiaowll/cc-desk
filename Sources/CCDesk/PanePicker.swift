import SwiftUI
import AppKit
import CCDeskCore

/// ⌘D / ⇧⌘D 打开的面板（设计 §20）：在焦点窗格旁边分屏显示哪个会话。样式与历史会话面板一致：
/// 顶部搜索框，列出还没显示在窗格里的内嵌会话，最后一项「新建会话…」；↑↓ 选择、↩ 打开、esc / 点背景关闭。
struct PanePickerSlot: View {
    @ObservedObject var model: AppModel
    @ObservedObject var panes: PaneLayoutModel

    var body: some View {
        if let request = panes.picker {
            PanePicker(model: model, request: request)
        }
    }
}

struct PanePicker: View {
    @Environment(\.uiScale) private var uiScale
    @ObservedObject var model: AppModel
    let request: PaneSplitRequest
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var themes = ThemeStore.shared
    @State private var query = ""
    @State private var selection = 0

    /// 列表项：已有会话，或最后的「新建会话…」。
    private enum Item: Identifiable {
        case session(SidebarRow, UUID)
        case newSession
        var id: String {
            switch self {
            case .session(let row, _): return row.id
            case .newSession: return "new"
            }
        }
    }

    private var items: [Item] {
        let rows = model.splitCandidates.filter { row in
            query.isEmpty || (row.displayName + " " + row.groupTitle).localizedCaseInsensitiveContains(query)
        }
        return rows.compactMap { row in row.session.host.terminalID.map { Item.session(row, $0) } } + [.newSession]
    }

    var body: some View {
        let theme = themes.theme(for: colorScheme)
        let items = self.items
        ZStack(alignment: .top) {
            theme.backdrop
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { model.cancelSplitPicker() }
            panel(theme: theme, items: items)
                .padding(.top, 44)
                .padding(.horizontal, 16)
        }
        .onExitCommand { model.cancelSplitPicker() }
    }

    private func panel(theme: Theme, items: [Item]) -> some View {
        let active = items.indices.contains(selection) ? items[selection].id : nil
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: request.edge == .bottom ? "rectangle.split.1x2" : "rectangle.split.2x1")
                    .uiFont(size: 14)
                    .foregroundStyle(theme.fg3)
                PaletteSearchField(
                    text: $query,
                    placeholder: request.edge == .bottom ? L("pane.picker.searchDown") : L("pane.picker.searchRight"),
                    textColor: NSColor(theme.fg1),
                    placeholderColor: NSColor(theme.fg3),
                    onMove: { delta in selection = min(max(0, selection + delta), items.count - 1) },
                    onSubmit: { if items.indices.contains(selection) { choose(items[selection]) } },
                    onCancel: { model.cancelSplitPicker() })
                KeyCap(text: "esc", theme: theme)
                CloseButton { model.cancelSplitPicker() }
            }
            .padding(.horizontal, 16)
            .frame(height: uiScale.metric(50))
            .overlay(alignment: .bottom) { theme.line.frame(height: 1) }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item, active: item.id == active, theme: theme)
                            .onHover { if $0 { selection = index } }
                            .onTapGesture { choose(item) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(height: min(CGFloat(items.count) * uiScale.metric(36) + 12, uiScale.metric(420)))

            HStack(spacing: 14) {
                HStack(spacing: 3) { KeyCap(text: "↑", theme: theme); KeyCap(text: "↓", theme: theme); Text(L("history.hint.select")) }
                HStack(spacing: 3) { KeyCap(text: "↩", theme: theme); Text(L("pane.picker.hint.open")) }
                HStack(spacing: 3) { KeyCap(text: "esc", theme: theme); Text(L("history.hint.close")) }
                Spacer()
            }
            .uiFont(size: 11)
            .foregroundStyle(theme.fg3)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .overlay(alignment: .top) { theme.line.frame(height: 1) }
        }
        .frame(maxWidth: uiScale.metric(520))
        .background(theme.main)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.line, lineWidth: 1))
        .shadow(color: theme.popShadow, radius: 30, y: 24)
        .onChange(of: query) { _, _ in selection = 0 }
    }

    @ViewBuilder
    private func row(_ item: Item, active: Bool, theme: Theme) -> some View {
        HStack(spacing: 10) {
            switch item {
            case .session(let row, _):
                PaneStatusDot(row: row, theme: theme)
                Text(row.displayName)
                    .uiFont(size: 13)
                    .foregroundStyle(theme.fg1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(PaletteRow.tagText(row.groupTitle, scale: uiScale))
                    .uiFont(size: 11)
                    .foregroundStyle(theme.fg2)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 5).fill(theme.chip))
                Text(row.agentLabel.map { "\($0) · \(row.statusLabel)" } ?? row.statusLabel)
                    .uiFont(size: 11)
                    .foregroundStyle(theme.fg3)
                    .lineLimit(1)
                    .fixedSize()
            case .newSession:
                Image(systemName: "plus").uiFont(size: 11, weight: .semibold).foregroundStyle(theme.action)
                    .frame(width: 7)
                Text(L("pane.picker.newSession"))
                    .uiFont(size: 13)
                    .foregroundStyle(theme.action)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: uiScale.metric(36))
        .background(RoundedRectangle(cornerRadius: 8).fill(active ? theme.hover : Color.clear))
        .contentShape(Rectangle())
    }

    private func choose(_ item: Item) {
        switch item {
        case .session(_, let tid): model.completeSplit(request, with: tid)
        case .newSession: model.completeSplitWithNewSession(request)
        }
    }
}
