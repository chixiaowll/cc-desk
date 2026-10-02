import Foundation

public struct SidebarRow: Identifiable, Equatable, Sendable {
    public let session: AgentSession
    public let displayName: String
    public let subtitle: String?
    public let sourceLabel: String?
    public var id: String { session.id }
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

        let groups = buckets.map { root, members -> SessionGroup in
            let title = groupTitle(root)
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
                   subtitle: subtitle(s, ref: ref),
                   sourceLabel: sourceLabel(s.host))
    }

    static func displayName(_ s: AgentSession, groupTitle: String) -> String {
        if s.name.isEmpty { return groupTitle }
        if s.nameIsDerived, let dash = s.name.lastIndex(of: "-") {
            let suffix = s.name[s.name.index(after: dash)...]
            if !suffix.isEmpty, suffix.count <= 4 { return "#\(suffix)" }
        }
        return s.name
    }

    static func subtitle(_ s: AgentSession, ref: ProjectRef) -> String? {
        if case .waiting(let reason) = s.status { return reason ?? "等待输入" }
        if case .missing = s.host { return s.cwd }
        if let branch = ref.branch { return branch }
        if s.cwd != ref.root, s.cwd.hasPrefix(ref.root + "/") {
            return String(s.cwd.dropFirst(ref.root.count + 1))
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
