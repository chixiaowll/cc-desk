import Foundation

public struct SidebarRow: Identifiable, Equatable, Sendable {
    public let session: AgentSession
    public let displayName: String
    /// 所属分组的标题（可能带去重用的父目录前缀），用于通知文案。
    public let groupTitle: String
    public let subtitle: String?
    public let sourceLabel: String?
    /// 悬停提示：完整标题 + 运行位置 + （若有）最近一条 prompt。
    public let tooltip: String
    public var id: String { session.id }

    public init(session: AgentSession, displayName: String, groupTitle: String, subtitle: String?,
                sourceLabel: String?, tooltip: String = "") {
        self.session = session
        self.displayName = displayName
        self.groupTitle = groupTitle
        self.subtitle = subtitle
        self.sourceLabel = sourceLabel
        self.tooltip = tooltip
    }

    /// 状态文字：内嵌终端里从未运行 claude 的普通 shell 显示「终端」，其余取状态本身的文字。
    public var statusLabel: String {
        if session.status == .unknown, session.host.isEmbedded { return "终端" }
        return session.status.label
    }

    /// 通知标题用的名字。标题已取自 transcript（不再有 "#xx" 缩写），直接使用 displayName。
    public var notificationName: String { displayName }
}

public struct SessionGroup: Identifiable, Equatable, Sendable {
    /// 项目根路径。
    public let id: String
    public let title: String
    public let rows: [SidebarRow]
    public let waitingCount: Int
    public let workingCount: Int
    public let idleCount: Int
    public var topStatus: AgentStatus { rows.first?.session.status ?? .unknown }

    public init(id: String, title: String, rows: [SidebarRow]) {
        self.id = id
        self.title = title
        self.rows = rows
        self.waitingCount = rows.filter { $0.session.status.isWaiting }.count
        self.workingCount = rows.filter { $0.session.status == .working }.count
        self.idleCount = rows.filter { $0.session.status == .idle }.count
    }
}

public enum SidebarBuilder {
    public static func build(sessions: [AgentSession], project: (String) -> ProjectRef,
                             titles: (AgentSession) -> TranscriptMeta? = { _ in nil }) -> [SessionGroup] {
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
                .sorted(by: rowOrder)
                .map { row(for: $0, ref: refs[$0.cwd] ?? ProjectRef(root: root, branch: nil, cwd: root),
                          groupTitle: title, meta: titles($0)) }
            return SessionGroup(id: root, title: title, rows: rows)
        }

        return groups.sorted { a, b in
            let ra = a.topStatus.rank, rb = b.topStatus.rank
            if ra != rb { return ra < rb }
            let ta = a.rows.map(\.session.statusChangedAt).max() ?? .distantPast
            let tb = b.rows.map(\.session.statusChangedAt).max() ?? .distantPast
            if ta != tb { return ta > tb }
            return a.id < b.id
        }
    }

    static func rowOrder(_ a: AgentSession, _ b: AgentSession) -> Bool {
        if a.status.rank != b.status.rank { return a.status.rank < b.status.rank }
        if a.statusChangedAt != b.statusChangedAt { return a.statusChangedAt > b.statusChangedAt }
        return a.id < b.id
    }

    static func groupTitle(_ root: String) -> String {
        if root == NSHomeDirectory() { return "~" }
        let name = URL(fileURLWithPath: root).lastPathComponent
        return name.isEmpty ? root : name
    }

    static func row(for s: AgentSession, ref: ProjectRef, groupTitle: String, meta: TranscriptMeta?) -> SidebarRow {
        let name = displayName(s, meta: meta)
        return SidebarRow(session: s,
                          displayName: name,
                          groupTitle: groupTitle,
                          subtitle: subtitle(s, ref: ref),
                          sourceLabel: sourceLabel(s.host),
                          tooltip: tooltip(s, displayName: name, meta: meta))
    }

    /// 标题规则：customTitle → aiTitle → lastPrompt 前 20 字 → 非派生的会话名 → "新会话"。不再有 "#NN" 缩写。
    static func displayName(_ s: AgentSession, meta: TranscriptMeta?) -> String {
        (meta ?? TranscriptMeta()).displayTitle(fallbackName: s.name.isEmpty ? nil : s.name, fallbackIsDerived: s.nameIsDerived)
    }

    /// "<完整标题>\n<运行位置>"，若有 lastPrompt 再加一行 "最近：…"（单行化，最长 80 字）。
    static func tooltip(_ s: AgentSession, displayName: String, meta: TranscriptMeta?) -> String {
        var text = "\(displayName)\n\(whereText(s))"
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
