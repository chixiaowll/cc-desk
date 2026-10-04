import SwiftUI
import AppKit
import CCDeskCore

/// 技能库窗口（设计 §21）：左侧按来源分组的列表（可折叠，带数量），顶部搜索 / agent 过滤 / 「只看当前会话可用」；
/// 右侧详情。只读，没有启用 / 停用 / 新建 / 删除。
struct SkillsLibraryView: View {
    @ObservedObject var library: SkillLibrary
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var themes = ThemeStore.shared
    @State private var query = ""
    @State private var agentFilter: AgentKind?
    @State private var onlyCurrent = false
    @State private var selectedID: String?
    @State private var collapsed: Set<String> = []
    /// 窗口变成 key 时加一：重新读取「当前会话」（主窗口的焦点窗格在别的窗口里切换过）。
    @State private var keyTick = 0

    struct Section: Identifiable {
        let id: String
        let source: SkillSource
        let entries: [SkillEntry]
    }

    var body: some View {
        let theme = themes.theme(for: colorScheme)
        let session = keyTick >= 0 ? library.currentSession : nil
        let visible = filtered(session: session)
        let sections = Self.sections(visible)
        VStack(spacing: 0) {
            header(theme: theme, session: session)
            HStack(spacing: 0) {
                list(sections: sections, visibleCount: visible.count, theme: theme)
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 440)
                theme.line.frame(width: 1)
                detail(theme: theme)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.main.ignoresSafeArea())
        .onChange(of: visible.map(\.id)) { _, ids in
            if selectedID.map(ids.contains) != true { selectedID = ids.first }
        }
        .onAppear { if selectedID == nil { selectedID = visible.first?.id } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in keyTick += 1 }
    }

    private func filtered(session: SkillLibrary.SessionContext?) -> [SkillEntry] {
        var entries = library.entries
        if onlyCurrent, let session {
            entries = SkillCatalog.effective(entries, for: session.kind, cwd: session.cwd, projectRoot: session.projectRoot)
        }
        return SkillCatalog.filter(entries, query: query, agent: agentFilter)
    }

    /// 按主来源分区，保持扫描结果的顺序。
    static func sections(_ entries: [SkillEntry]) -> [Section] {
        var result: [Section] = []
        for entry in entries {
            let id = entry.source.groupID
            if let last = result.last, last.id == id {
                result[result.count - 1] = Section(id: id, source: last.source, entries: last.entries + [entry])
            } else {
                result.append(Section(id: id, source: entry.source, entries: [entry]))
            }
        }
        return result
    }

    // MARK: 顶部

    private func header(theme: Theme, session: SkillLibrary.SessionContext?) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(theme.fg3)
                TextField("", text: $query, prompt: Text(L("skills.search")).foregroundColor(theme.fg3))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.fg1)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(theme.fg3) }
                        .buttonStyle(.plain)
                        .help(L("skills.clearSearch"))
                }
                if library.isLoading {
                    ProgressView().controlSize(.small)
                }
                Button { library.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(library.isLoading)
                    .help(L("skills.refresh"))
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .overlay(alignment: .bottom) { theme.line.frame(height: 1) }

            HStack(spacing: 6) {
                AgentFilterChip(title: L("skills.filter.all"), selected: agentFilter == nil, theme: theme) { agentFilter = nil }
                ForEach(AgentKind.launchable, id: \.self) { kind in
                    AgentFilterChip(title: kind.displayName, selected: agentFilter == kind, theme: theme) {
                        agentFilter = agentFilter == kind ? nil : kind
                    }
                }
                Spacer(minLength: 12)
                Toggle(isOn: Binding(get: { onlyCurrent && session != nil }, set: { onlyCurrent = $0 })) {
                    Text(L("skills.onlyCurrent")).font(.system(size: 11.5))
                }
                .toggleStyle(.checkbox)
                .disabled(session == nil)
                .help(session.map { L("skills.onlyCurrent.help", $0.name, $0.kind.displayName) }
                      ?? L("skills.onlyCurrent.none"))
                if let session, onlyCurrent {
                    Text("\(session.name) · \(session.kind.displayName)")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.fg3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
        }
        .background(theme.side)
    }

    // MARK: 列表

    @ViewBuilder
    private func list(sections: [Section], visibleCount: Int, theme: Theme) -> some View {
        if library.entries.isEmpty {
            VStack(spacing: 10) {
                if library.isLoading || library.loadedAt == nil {
                    ProgressView().controlSize(.small)
                    Text(L("skills.loading")).font(.system(size: 12)).foregroundStyle(theme.fg3)
                } else {
                    Image(systemName: "books.vertical").font(.system(size: 26)).foregroundStyle(theme.fg3)
                    Text(L("skills.empty")).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.fg2)
                    Text(L("skills.empty.hint")).font(.system(size: 11.5)).foregroundStyle(theme.fg3)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.side)
        } else if visibleCount == 0 {
            Text(L("skills.noMatches"))
                .font(.system(size: 12))
                .foregroundStyle(theme.fg3)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(theme.side)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(sections) { section in
                        SkillSectionHeader(source: section.source, count: section.entries.count,
                                           collapsed: collapsed.contains(section.id), theme: theme) {
                            if collapsed.contains(section.id) { collapsed.remove(section.id) } else { collapsed.insert(section.id) }
                        }
                        if !collapsed.contains(section.id) {
                            ForEach(section.entries) { entry in
                                SkillRow(entry: entry, selected: entry.id == selectedID, theme: theme)
                                    .onTapGesture { selectedID = entry.id }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .background(theme.side)
        }
    }

    @ViewBuilder
    private func detail(theme: Theme) -> some View {
        if let id = selectedID, let entry = library.entries.first(where: { $0.id == id }) {
            SkillDetailView(entry: entry, library: library, theme: theme)
                .id(entry.id)
        } else {
            Text(library.entries.isEmpty ? "" : L("skills.selectHint"))
                .font(.system(size: 12))
                .foregroundStyle(theme.fg3)
        }
    }
}

/// 分区标题：来源名 + 灰色说明 + 数量；整行点击折叠 / 展开。
struct SkillSectionHeader: View {
    let source: SkillSource
    let count: Int
    let collapsed: Bool
    let theme: Theme
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .foregroundStyle(theme.fg3)
                    .frame(width: 10)
                Text(source.sectionTitle)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.fg2)
                    .lineLimit(1)
                if source.isDisabled {
                    SkillBadge(text: L("skills.badge.disabled"), theme: theme, warning: true)
                }
                Text(source.sectionDetail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.fg3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.fg3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.chip))
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 列表行：名字、一行描述、徽章（来源 / 种类 / 已停用 / 适用的 agent）。
struct SkillRow: View {
    let entry: SkillEntry
    let selected: Bool
    let theme: Theme
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.displayName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.fg1)
                .lineLimit(1)
            if !entry.description.isEmpty {
                Text(entry.description)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.fg2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            SkillBadges(entry: entry, theme: theme)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? theme.sel : hovering ? theme.hover : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? theme.selLine : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .opacity(entry.isDisabled ? 0.65 : 1)
        .help(entry.description)
    }
}

/// 一行徽章：来源、种类（命令 / 子 agent）、已停用、适用的 agent。
struct SkillBadges: View {
    let entry: SkillEntry
    let theme: Theme

    var body: some View {
        HStack(spacing: 4) {
            SkillBadge(text: entry.source.badge, theme: theme)
            if let kind = entry.kind.badge { SkillBadge(text: kind, theme: theme) }
            if entry.isDisabled { SkillBadge(text: L("skills.badge.disabled"), theme: theme, warning: true) }
            ForEach(entry.agents, id: \.self) { agent in
                Text(agent.displayName)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(theme.accent.opacity(0.45), lineWidth: 1))
            }
        }
        .lineLimit(1)
    }
}

struct SkillBadge: View {
    let text: String
    let theme: Theme
    var warning = false

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(warning ? theme.pillWaitFg : theme.fg2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(warning ? theme.pillWaitBg : theme.chip))
            .fixedSize()
    }
}
