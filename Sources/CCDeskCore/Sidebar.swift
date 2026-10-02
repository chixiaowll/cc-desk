import Foundation

public struct SidebarRow: Identifiable, Equatable, Sendable {
    public let session: AgentSession
    public let displayName: String
    /// 所属分组的标题（可能带去重用的父目录前缀），用于通知文案。
    public let groupTitle: String
    public let subtitle: String?
    public let sourceLabel: String?
    public var id: String { session.id }

    public init(session: AgentSession, displayName: String, groupTitle: String, subtitle: String?, sourceLabel: String?) {
        self.session = session
        self.displayName = displayName
        self.groupTitle = groupTitle
        self.subtitle = subtitle
        self.sourceLabel = sourceLabel
    }

    /// 通知标题用的名字；仅当 displayName 被缩短为 "#xx" 形式时补上分组前缀，避免通知歧义。
    public var notificationName: String {
        displayName.hasPrefix("#") ? "\(groupTitle) \(displayName)" : displayName
    }
}

public struct SessionGroup: Identifiable, Equatable, Sendable {
    /// 项目根路径。
    public let id: String
    public let title: String
    public let rows: [SidebarRow]
    public var topStatus: AgentStatus { rows.first?.session.status ?? .unknown }
}

public enum SidebarBuilder {
    public static func build(sessions: [AgentSession], project: (String) -> ProjectRef) -> [SessionGroup] {
        var buckets: [String: [AgentSession]] = [:]
        var refs: [String: ProjectRef] = [:]
        for session in sessions {
            let ref = project(session.cwd)
            refs[session.cwd] = ref
            buckets[ref.root, default: []].append(session)
        }

        var titles: [String: String] = [:]
        for root in buckets.keys { titles[root] = groupTitle(root) }
        var titleCounts: [String: Int] = [:]
        for title in titles.values { titleCounts[title, default: 0] += 1 }
        for root in titles.keys where (titleCounts[titles[root]!] ?? 0) > 1 {
            let parent = URL(fileURLWithPath: root).deletingLastPathComponent().lastPathComponent
            if !parent.isEmpty { titles[root] = "\(parent)/\(titles[root]!)" }
        }

        let groups = buckets.map { root, members -> SessionGroup in
            let title = titles[root] ?? groupTitle(root)
            let rows = members
                .sorted(by: rowOrder)
                .map { row(for: $0, ref: refs[$0.cwd] ?? ProjectRef(root: root, branch: nil), groupTitle: title) }
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

    static func row(for s: AgentSession, ref: ProjectRef, groupTitle: String) -> SidebarRow {
        SidebarRow(session: s,
                   displayName: displayName(s, groupTitle: groupTitle),
                   groupTitle: groupTitle,
                   subtitle: subtitle(s, ref: ref),
                   sourceLabel: sourceLabel(s.host))
    }

    static func displayName(_ s: AgentSession, groupTitle: String) -> String {
        if s.name.isEmpty { return groupTitle }
        if s.nameIsDerived, let dash = s.name.lastIndex(of: "-") {
            let suffix = s.name[s.name.index(after: dash)...]
            if isLowercaseHexSuffix(suffix) { return "#\(suffix)" }
        }
        return s.name
    }

    /// 真实的 Claude 派生名后缀形如 "4a"、"88"、"06"、"c7"：1-4 位小写十六进制字符。
    /// 其它后缀（如 "my-app" 的 "app"）不应被当成短 id 缩写。
    static func isLowercaseHexSuffix(_ s: Substring) -> Bool {
        guard !s.isEmpty, s.count <= 4 else { return false }
        return s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    static func subtitle(_ s: AgentSession, ref: ProjectRef) -> String? {
        if case .waiting(let reason) = s.status { return reason ?? "等待输入" }
        if case .missing = s.host { return s.cwd }
        if let branch = ref.branch { return branch }
        let canonicalCwd = ProjectResolver.canonical(s.cwd)
        if canonicalCwd != ref.root, canonicalCwd.hasPrefix(ref.root + "/") {
            return String(canonicalCwd.dropFirst(ref.root.count + 1))
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
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }

    /// 超过 24 小时没有状态变化。
    public static func isStale(_ date: Date, now: Date) -> Bool {
        date != .distantPast && now.timeIntervalSince(date) > 86400
    }
}
