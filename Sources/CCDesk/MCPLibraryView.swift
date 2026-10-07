import SwiftUI
import AppKit
import CCDeskCore

/// 技能库窗口的「MCP」页（设计 §31）：左侧按来源分组的 MCP 列表，顶部搜索 / agent 过滤 / 检查连接；右侧详情。
/// 只读：不增删改配置，密钥一律不显示。
struct MCPLibraryView: View {
    @Environment(\.uiScale) private var uiScale
    @ObservedObject var library: MCPLibrary
    let theme: Theme
    @State private var query = ""
    @State private var agentFilter: AgentKind?
    @State private var selectedID: String?
    @State private var collapsed: Set<String> = []

    struct Section: Identifiable {
        let id: String
        let source: MCPSource
        let entries: [MCPServerEntry]
    }

    static let agents: [AgentKind] = [.claude, .codex, .opencode]

    var body: some View {
        let visible = MCPCatalog.filter(library.entries, query: query, agent: agentFilter)
        let sections = Self.sections(visible)
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                list(sections: sections, visibleCount: visible.count)
                    .frame(minWidth: uiScale.metric(300), idealWidth: 360, maxWidth: uiScale.metric(440))
                theme.line.frame(width: 1)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: visible.map(\.id)) { _, ids in
            if selectedID.map(ids.contains) != true { selectedID = ids.first }
        }
        .onAppear {
            library.refresh()
            if selectedID == nil { selectedID = visible.first?.id }
        }
    }

    static func sections(_ entries: [MCPServerEntry]) -> [Section] {
        var result: [Section] = []
        for entry in entries {
            let id = entry.source.groupID
            if let i = result.firstIndex(where: { $0.id == id }) {
                result[i] = Section(id: id, source: result[i].source, entries: result[i].entries + [entry])
            } else {
                result.append(Section(id: id, source: entry.source, entries: [entry]))
            }
        }
        return result
    }

    // MARK: 顶部

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").uiFont(size: 13).foregroundStyle(theme.fg3)
                TextField("", text: $query, prompt: Text(L("mcp.search")).foregroundColor(theme.fg3))
                    .textFieldStyle(.plain)
                    .uiFont(size: 13)
                    .foregroundStyle(theme.fg1)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(theme.fg3) }
                        .buttonStyle(.plain)
                        .help(L("skills.clearSearch"))
                }
                if library.isLoading { ProgressView().controlSize(.small) }
                Button { library.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(library.isLoading)
                    .help(L("skills.refresh"))
            }
            .padding(.horizontal, 16)
            .frame(height: uiScale.metric(44))
            .overlay(alignment: .bottom) { theme.line.frame(height: 1) }

            HStack(spacing: 6) {
                AgentFilterChip(title: L("skills.filter.all"), selected: agentFilter == nil, theme: theme) { agentFilter = nil }
                ForEach(Self.agents, id: \.self) { kind in
                    AgentFilterChip(title: kind.displayName, selected: agentFilter == kind, theme: theme) {
                        agentFilter = agentFilter == kind ? nil : kind
                    }
                }
                Spacer(minLength: 12)
                if library.isChecking {
                    ProgressView().controlSize(.small)
                    Text(L("mcp.check.running")).uiFont(size: 11).foregroundStyle(theme.fg3)
                } else if let error = library.checkError {
                    Text(error).uiFont(size: 11).foregroundStyle(theme.accent).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: uiScale.metric(260), alignment: .trailing)
                }
                Button(L("mcp.check")) { library.checkConnections() }
                    .controlSize(.small)
                    .disabled(library.isChecking)
                    .help(L("mcp.check.help"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
        }
        .background(theme.side)
    }

    // MARK: 列表

    @ViewBuilder
    private func list(sections: [Section], visibleCount: Int) -> some View {
        if library.entries.isEmpty {
            VStack(spacing: 10) {
                if library.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "puzzlepiece.extension").uiFont(size: 26).foregroundStyle(theme.fg3)
                    Text(L("mcp.empty")).uiFont(size: 13, weight: .medium).foregroundStyle(theme.fg2)
                    Text(L("mcp.empty.hint")).uiFont(size: 11.5).foregroundStyle(theme.fg3).multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.side)
        } else if visibleCount == 0 {
            Text(L("skills.noMatches"))
                .uiFont(size: 12)
                .foregroundStyle(theme.fg3)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(theme.side)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(sections) { section in
                        sectionHeader(section)
                        if !collapsed.contains(section.id) {
                            ForEach(section.entries) { entry in
                                MCPRow(entry: entry, selected: entry.id == selectedID, theme: theme)
                                    .onTapGesture { selectedID = entry.id }
                            }
                        }
                    }
                    if library.checkedAt == nil {
                        Text(L("mcp.connectorsHint"))
                            .uiFont(size: 10.5)
                            .foregroundStyle(theme.fg3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)
                            .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .background(theme.side)
        }
    }

    private func sectionHeader(_ section: Section) -> some View {
        Button {
            if collapsed.contains(section.id) { collapsed.remove(section.id) } else { collapsed.insert(section.id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .uiFont(size: 9, weight: .semibold)
                    .rotationEffect(.degrees(collapsed.contains(section.id) ? -90 : 0))
                    .foregroundStyle(theme.fg3)
                    .frame(width: 10)
                Text(section.source.title)
                    .uiFont(size: 11.5, weight: .semibold)
                    .foregroundStyle(theme.fg2)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(section.entries.count)")
                    .uiFont(size: 10.5, weight: .medium)
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

    // MARK: 详情

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID, let entry = library.entries.first(where: { $0.id == id }) {
            MCPDetailView(entry: entry, library: library, theme: theme).id(entry.id)
        } else {
            Text(library.entries.isEmpty ? "" : L("mcp.selectHint")).uiFont(size: 12).foregroundStyle(theme.fg3)
        }
    }
}

/// 连接状态徽章。
struct MCPHealthBadge: View {
    let health: MCPHealth
    let theme: Theme

    var body: some View {
        let (text, warning): (String, Bool) = {
            switch health {
            case .connected: return (L("mcp.health.connected"), false)
            case .needsAuth: return (L("mcp.health.needsAuth"), true)
            case .failed: return (L("mcp.health.failed"), true)
            case .unknown(let s): return (s, true)
            }
        }()
        return HStack(spacing: 3) {
            if case .connected = health { Circle().fill(theme.unread).frame(width: 5, height: 5) }
            SkillBadge(text: text, theme: theme, warning: warning)
        }
    }
}

struct MCPRow: View {
    let entry: MCPServerEntry
    let selected: Bool
    let theme: Theme
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.name)
                    .uiFont(size: 12.5, weight: .semibold)
                    .foregroundStyle(theme.fg1)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let health = entry.health { MCPHealthBadge(health: health, theme: theme) }
            }
            if !entry.summary.isEmpty {
                Text(entry.summary)
                    .uiFont(size: 11, design: .monospaced)
                    .foregroundStyle(theme.fg2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 4) {
                SkillBadge(text: entry.transport.label, theme: theme)
                if case .claudePlugin(let plugin, _) = entry.source { SkillBadge(text: plugin, theme: theme) }
                if !entry.enabled { SkillBadge(text: L("skills.badge.disabled"), theme: theme, warning: true) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? theme.sel : hovering ? theme.hover : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? theme.selLine : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .opacity(entry.enabled ? 1 : 0.65)
    }
}

/// 右侧详情：名字、agent、来源、传输、命令 / 地址、环境变量 / 请求头（只有名字）、配置文件、连接状态。
struct MCPDetailView: View {
    let entry: MCPServerEntry
    @ObservedObject var library: MCPLibrary
    let theme: Theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.name).uiFont(size: 18, weight: .semibold).foregroundStyle(theme.fg1).textSelection(.enabled)
                    HStack(spacing: 4) {
                        SkillBadge(text: entry.source.agent.displayName, theme: theme)
                        SkillBadge(text: entry.source.title, theme: theme)
                        SkillBadge(text: entry.transport.label, theme: theme)
                        if !entry.enabled { SkillBadge(text: L("skills.badge.disabled"), theme: theme, warning: true) }
                        if let health = entry.health { MCPHealthBadge(health: health, theme: theme) }
                    }
                }
                if MCPPromotion.canPromote(entry) {
                    HStack(spacing: 8) {
                        Button(L("mcp.promote.button")) { library.confirmPromote(entry) }
                            .disabled(library.promoting != nil)
                        if library.promoting == entry.id { ProgressView().controlSize(.small) }
                    }
                    Text(L("mcp.promote.hint")).uiFont(size: 11).foregroundStyle(theme.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .failed(let why) = entry.health, !why.isEmpty {
                    field(L("mcp.field.error"), why)
                }
                if let url = entry.url { field(L("mcp.field.url"), url, mono: true) }
                if let command = entry.command { field(L("mcp.field.command"), command, mono: true) }
                if !entry.args.isEmpty { field(L("mcp.field.args"), entry.args.joined(separator: " "), mono: true) }
                if !entry.envKeys.isEmpty { field(L("mcp.field.env"), entry.envKeys.joined(separator: "\n"), mono: true) }
                if !entry.headerKeys.isEmpty { field(L("mcp.field.headers"), entry.headerKeys.joined(separator: "\n"), mono: true) }
                if let path = entry.configPath {
                    VStack(alignment: .leading, spacing: 6) {
                        field(L("mcp.field.config"), path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), mono: true)
                        Button(L("files.menu.reveal")) { FileActions.reveal(path) }.controlSize(.small)
                    }
                }
                Text(entry.source == .claudeConnector ? L("mcp.note.connector") : L("mcp.note.secrets"))
                    .uiFont(size: 11)
                    .foregroundStyle(theme.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func field(_ title: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).uiFont(size: 11, weight: .medium).foregroundStyle(theme.fg3)
            Text(value)
                .uiFont(size: 12, design: mono ? .monospaced : .default)
                .foregroundStyle(theme.fg1)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 技能库窗口的根视图：顶部「技能 / MCP」页签（记住上次的选择），下面是对应的页面。
struct LibraryRootView: View {
    @ObservedObject var skills: SkillLibrary
    @ObservedObject var mcp: MCPLibrary
    @AppStorage("libraryTab") private var tab = "skills"
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var themes = ThemeStore.shared
    @Environment(\.uiScale) private var uiScale

    var body: some View {
        let theme = themes.theme(for: colorScheme)
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    Text(L("library.tab.skills")).tag("skills")
                    Text(L("library.tab.mcp")).tag("mcp")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .frame(maxWidth: .infinity)
            .frame(height: uiScale.metric(38))
            .background(theme.side)
            .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
            if tab == "mcp" {
                MCPLibraryView(library: mcp, theme: theme)
            } else {
                SkillsLibraryView(library: skills)
            }
        }
        .background(theme.main.ignoresSafeArea())
    }
}
