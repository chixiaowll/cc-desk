import Foundation

public struct SidebarRow: Identifiable, Equatable, Sendable {
    public let session: AgentSession
    public let displayName: String
    /// 所属分组的标题（可能带去重用的父目录前缀），用于通知文案。
    public let groupTitle: String
    public let subtitle: String?
    public let sourceLabel: String?
    /// agent 名（如 "Claude"）；普通 shell 为 nil。
    public let agentLabel: String?
    /// 悬停提示：完整标题 + 运行位置 + （若有）最近一条 prompt。
    public let tooltip: String
    /// Claude 完成一轮（working → idle）时用户没在看它：「已完成·未读」。仅内存中保存，由 App 层维护。
    public var unread: Bool
    public var id: String { session.id }

    public init(session: AgentSession, displayName: String, groupTitle: String, subtitle: String?,
                sourceLabel: String?, agentLabel: String? = nil, tooltip: String = "", unread: Bool = false) {
        self.session = session
        self.displayName = displayName
        self.groupTitle = groupTitle
        self.subtitle = subtitle
        self.sourceLabel = sourceLabel
        self.agentLabel = agentLabel
        self.tooltip = tooltip
        self.unread = unread
    }

    /// 是否按「已完成·未读」显示：等批准始终优先于未读。
    public var showsUnread: Bool { unread && !session.status.isWaiting }

    /// 排序用：等批准 > 已完成·未读 > 处理中 > 空闲 > 已结束 > 未知；数值越小越靠前。
    public var rank: Int {
        if showsUnread { return 1 }
        switch session.status {
        case .waiting: return 0
        case .working: return 2
        case .idle: return 3
        case .ended: return 4
        case .unknown: return 5
        }
    }

    /// 状态文字：内嵌终端里从未运行 claude 的普通 shell 显示「终端」，其余取状态本身的文字。
    public var statusLabel: String {
        if showsUnread { return "已完成" }
        if session.status == .unknown, session.host.isEmbedded { return "终端" }
        return session.status.label
    }

    /// 通知标题用的名字。标题已取自 transcript（不再有 "#xx" 缩写），直接使用 displayName。
    public var notificationName: String { displayName }
}

/// 会话行 / 历史行上是否显示 agent 名（「处理中 · Claude」）的唯一开关。
/// 目前始终显示；接入 Codex / pi 后可改为「本机同时出现两种及以上 agent 时才显示」（见设计 §11）。
public enum AgentLabelPolicy {
    public static let showAgentLabel = true

    /// `kinds` 为当前出现的 agent 种类；目前忽略，始终返回 `showAgentLabel`。
    public static func shows(presentKinds kinds: Set<AgentKind>) -> Bool {
        showAgentLabel
    }
}

public struct SessionGroup: Identifiable, Equatable, Sendable {
    /// 项目根路径。
    public let id: String
    public let title: String
    public let rows: [SidebarRow]
    public let waitingCount: Int
    public let workingCount: Int
    public let idleCount: Int
    /// 已完成·未读且不在等批准的行数。
    public let unreadCount: Int
    public var topStatus: AgentStatus { rows.first?.session.status ?? .unknown }
    /// 组内最靠前一行的排序值（见 `SidebarRow.rank`），用于组间排序。
    public var topRank: Int { rows.first?.rank ?? 5 }

    public init(id: String, title: String, rows: [SidebarRow]) {
        self.id = id
        self.title = title
        self.rows = rows
        self.waitingCount = rows.filter { $0.session.status.isWaiting }.count
        self.workingCount = rows.filter { $0.session.status == .working }.count
        self.idleCount = rows.filter { $0.session.status == .idle }.count
        self.unreadCount = rows.filter(\.showsUnread).count
    }
}

public enum SidebarBuilder {
    public static func build(sessions: [AgentSession], project: (String) -> ProjectRef,
                             titles: (AgentSession) -> TranscriptMeta? = { _ in nil },
                             unread: (AgentSession) -> Bool = { _ in false }) -> [SessionGroup] {
        var buckets: [String: [AgentSession]] = [:]
        var refs: [String: ProjectRef] = [:]
        for session in sessions {
            let ref = project(session.cwd)
            refs[session.cwd] = ref
            buckets[ref.root, default: []].append(session)
        }

        var titleByRoot: [String: String] = [:]
        for root in buckets.keys { titleByRoot[root] = groupTitle(root) }
        var titleCounts: [String: Int] = [:]
        for title in titleByRoot.values { titleCounts[title, default: 0] += 1 }
        for root in titleByRoot.keys where (titleCounts[titleByRoot[root]!] ?? 0) > 1 {
            let parent = URL(fileURLWithPath: root).deletingLastPathComponent().lastPathComponent
            if !parent.isEmpty { titleByRoot[root] = "\(parent)/\(titleByRoot[root]!)" }
        }

        let groups = buckets.map { root, members -> SessionGroup in
            let title = titleByRoot[root] ?? groupTitle(root)
            let rows = members
                .map { row(for: $0, ref: refs[$0.cwd] ?? ProjectRef(root: root, branch: nil, cwd: root),
                          groupTitle: title, meta: titles($0), unread: unread($0)) }
                .sorted(by: rowOrder)
            return SessionGroup(id: root, title: title, rows: rows)
        }

        return groups.sorted { a, b in
            let ra = a.topRank, rb = b.topRank
            if ra != rb { return ra < rb }
            let ta = a.rows.map(\.session.statusChangedAt).max() ?? .distantPast
            let tb = b.rows.map(\.session.statusChangedAt).max() ?? .distantPast
            if ta != tb { return ta > tb }
            return a.id < b.id
        }
    }

    static func rowOrder(_ a: SidebarRow, _ b: SidebarRow) -> Bool {
        if a.rank != b.rank { return a.rank < b.rank }
        if a.session.statusChangedAt != b.session.statusChangedAt { return a.session.statusChangedAt > b.session.statusChangedAt }
        return a.id < b.id
    }

    static func groupTitle(_ root: String) -> String {
        if root == NSHomeDirectory() { return "~" }
        let name = URL(fileURLWithPath: root).lastPathComponent
        return name.isEmpty ? root : name
    }

    static func row(for s: AgentSession, ref: ProjectRef, groupTitle: String, meta: TranscriptMeta?,
                    unread: Bool = false) -> SidebarRow {
        let name = displayName(s, meta: meta)
        return SidebarRow(session: s,
                          displayName: name,
                          groupTitle: groupTitle,
                          subtitle: subtitle(s, ref: ref),
                          sourceLabel: sourceLabel(s.host),
                          agentLabel: agentLabel(s),
                          tooltip: tooltip(s, displayName: name, meta: meta),
                          unread: unread)
    }

    /// 标题规则：customTitle → aiTitle → lastPrompt 前 20 字 → 非派生的会话名 → "新会话"。不再有 "#NN" 缩写。
    static func displayName(_ s: AgentSession, meta: TranscriptMeta?) -> String {
        (meta ?? TranscriptMeta()).displayTitle(fallbackName: s.name.isEmpty ? nil : s.name, fallbackIsDerived: s.nameIsDerived)
    }

    /// agent 会话取 kind 的显示名；普通 shell 与目录缺失的占位为 nil。
    static func agentLabel(_ s: AgentSession) -> String? {
        if case .missing = s.host { return nil }
        return s.kind.isAgent ? s.kind.displayName : nil
    }

    /// "<完整标题>\n[Agent：<名>\n]<运行位置>"，若有 lastPrompt 再加一行 "最近：…"（单行化，最长 80 字）。
    static func tooltip(_ s: AgentSession, displayName: String, meta: TranscriptMeta?) -> String {
        var text = displayName
        if let agent = agentLabel(s) { text += "\nAgent：\(agent)" }
        text += "\n\(whereText(s))"
        if let prompt = meta?.lastPrompt {
            let collapsed = singleLine(prompt, maxLength: 80)
            if !collapsed.isEmpty { text += "\n最近：\(collapsed)" }
        }
        return text
    }

    static func whereText(_ s: AgentSession) -> String {
        switch s.host {
        case .embedded: return "在 CC Desk 内运行"
        case .terminalApp: return "在 Terminal 中运行，点击跳转"
        case .vscode: return "在 VS Code 中运行，点击跳转"
        case .other: return "在外部终端中运行"
        case .missing: return "目录缺失：\(s.cwd)"
        }
    }

    static func singleLine(_ text: String, maxLength: Int) -> String {
        let collapsed = text
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength)) + "…"
    }

    static func subtitle(_ s: AgentSession, ref: ProjectRef) -> String? {
        if case .waiting(let reason) = s.status { return reason ?? "等待输入" }
        if case .missing = s.host { return s.cwd }
        if let branch = ref.branch { return branch }
        if ref.cwd != ref.root, ref.cwd.hasPrefix(ref.root + "/") {
            return String(ref.cwd.dropFirst(ref.root.count + 1))
        }
        return nil
    }

    static func sourceLabel(_ host: SessionHost) -> String? {
        switch host {
        case .embedded: return nil
        case .terminalApp: return "Terminal"
        case .vscode: return "VS Code"
        case .other: return "外部"
        case .missing: return "目录缺失"
        }
    }
}

public enum RelativeTime {
    public static func short(from date: Date, now: Date) -> String {
        if date == .distantPast { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60))分钟" }
        if seconds < 86400 { return "\(Int(seconds / 3600))小时" }
        if seconds < 7 * 86400 { return "\(Int(seconds / 86400))天" }
        return "\(Int(seconds / (7 * 86400)))周"
    }

    /// 超过 24 小时没有状态变化。
    public static func isStale(_ date: Date, now: Date) -> Bool {
        date != .distantPast && now.timeIntervalSince(date) > 86400
    }
}

public enum HistoryGrouping {
    /// 按「今天 / 昨天 / 更早」分组，组内按时间倒序；空分组被省略。
    public static func byDay(_ items: [HistoryItem], now: Date, calendar: Calendar = .current) -> [(label: String, items: [HistoryItem])] {
        var today: [HistoryItem] = []
        var yesterday: [HistoryItem] = []
        var earlier: [HistoryItem] = []
        let yesterdayDate = calendar.date(byAdding: .day, value: -1, to: now)

        for item in items {
            if calendar.isDate(item.modifiedAt, inSameDayAs: now) {
                today.append(item)
            } else if let yesterdayDate, calendar.isDate(item.modifiedAt, inSameDayAs: yesterdayDate) {
                yesterday.append(item)
            } else {
                earlier.append(item)
            }
        }

        func sorted(_ items: [HistoryItem]) -> [HistoryItem] { items.sorted { $0.modifiedAt > $1.modifiedAt } }

        var groups: [(label: String, items: [HistoryItem])] = []
        if !today.isEmpty { groups.append((label: "今天", items: sorted(today))) }
        if !yesterday.isEmpty { groups.append((label: "昨天", items: sorted(yesterday))) }
        if !earlier.isEmpty { groups.append((label: "更早", items: sorted(earlier))) }
        return groups
    }

    /// 某个项目根目录下的历史会话，按时间倒序。
    public static func forProject(root: String, items: [HistoryItem], project: (String) -> ProjectRef) -> [HistoryItem] {
        items
            .filter { project($0.cwd).root == root }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }
}
