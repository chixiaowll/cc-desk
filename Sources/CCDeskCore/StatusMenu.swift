import Foundation

/// 菜单栏状态项（设计 §15）的纯逻辑：计数文字、悬停提示与菜单分组排序。
/// 侧栏保持固定顺序；只有菜单栏菜单按紧急程度排序，方便一眼找到在等你的会话。
public enum StatusMenu {
    /// 菜单里每一行的状态色调，App 层映射为 Theme 里的状态色。
    public enum Tone: Equatable, Sendable {
        case waiting, working, unread, idle, inactive
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        public let row: SidebarRow
        /// 显示名（单行化并截断）。
        public let title: String
        /// 「等批准 · Claude · Fable 5.1」：状态文字 + agent 名 + 模型短名（普通 shell 没有 agent 名，没有模型信息时不带模型）。
        public let detail: String
        public let tone: Tone
        public var id: String { row.id }
    }

    public struct Section: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let branch: String?
        public let entries: [Entry]
    }

    /// 菜单项标题的最大字数。
    public static let maxTitleLength = 40

    /// 按紧急程度排序的分组：组按组内最紧急的一行排序（等批准 > 已完成·未读 > 处理中 > 空闲 > 其他），
    /// 组内的行也按紧急程度排序；同级保持侧栏里的相对顺序（稳定排序）。空组被省略。
    public static func sections(_ groups: [SessionGroup]) -> [Section] {
        let built = groups.enumerated().compactMap { index, group -> (Int, Int, Section)? in
            guard !group.rows.isEmpty else { return nil }
            let rows = group.rows.enumerated()
                .sorted { a, b in a.element.rank != b.element.rank ? a.element.rank < b.element.rank : a.offset < b.offset }
                .map { entry(for: $0.element) }
            return (group.topRank, index, Section(id: group.id, title: group.title, branch: group.branch, entries: rows))
        }
        return built.sorted { a, b in a.0 != b.0 ? a.0 < b.0 : a.1 < b.1 }.map(\.2)
    }

    static func entry(for row: SidebarRow) -> Entry {
        let title = SidebarBuilder.singleLine(row.displayName, maxLength: maxTitleLength)
        var detail = row.statusLabel
        if let agent = row.agentModelLabel { detail += " · " + agent }
        return Entry(row: row, title: title.isEmpty ? row.displayName : title, detail: detail, tone: tone(of: row))
    }

    static func tone(of row: SidebarRow) -> Tone {
        if row.showsUnread { return .unread }
        switch row.session.status {
        case .waiting: return .waiting
        case .working: return .working
        case .idle: return .idle
        case .ended, .unknown: return .inactive
        }
    }

    /// 菜单栏图标旁的计数：与 Dock 角标一致（等批准 + 已完成·未读），等批准数单独突出显示。
    public struct Badge: Equatable, Sendable {
        public let waiting: Int
        public let unread: Int

        public init(waiting: Int, unread: Int) {
            self.waiting = max(0, waiting)
            self.unread = max(0, unread)
        }

        public init(groups: [SessionGroup]) {
            self.init(waiting: groups.reduce(0) { $0 + $1.waitingCount },
                      unread: groups.reduce(0) { $0 + $1.unreadCount })
        }

        /// 与 Dock 角标相同的总数。
        public var total: Int { waiting + unread }
        public var isEmpty: Bool { total == 0 }

        /// 突出显示的部分（等批准数）；没有等批准时为 nil。
        public var emphasizedText: String? { waiting > 0 ? "\(waiting)" : nil }

        /// 次要部分（已完成·未读数）：有等批准时带分隔符（「 · 2」），否则就是数字本身；没有未读时为 nil。
        public var secondaryText: String? {
            guard unread > 0 else { return nil }
            return waiting > 0 ? " · \(unread)" : "\(unread)"
        }

        /// 菜单栏按钮上的完整文字；没有需要处理的会话时为空串（只显示图标）。
        public var text: String { (emphasizedText ?? "") + (secondaryText ?? "") }

        /// 悬停提示：「CC Desk — 2 个等批准 · 1 个已完成未读」或「CC Desk — 没有需要处理的会话」。
        public var tooltip: String {
            var parts: [String] = []
            if waiting > 0 { parts.append(L("statusItem.waiting", waiting)) }
            if unread > 0 { parts.append(L("statusItem.unread", unread)) }
            let summary = parts.isEmpty ? L("statusItem.nothing") : parts.joined(separator: " · ")
            return "CC Desk — " + summary
        }
    }
}
