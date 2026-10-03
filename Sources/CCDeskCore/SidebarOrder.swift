import Foundation

/// 侧栏的固定顺序：项目组和会话按第一次出现的先后排列，重启后保持，状态变化不再改变位置。
/// 会话用多个键识别：行 id（内嵌终端 id 重启后不变）与 agent 会话 id（接管 / 恢复后不变），任一键已知就沿用它的位置。
/// 持久化在 ~/.cc-desk/sidebar-order.json。
public struct SidebarOrder: Codable, Equatable, Sendable {
    public static let maxEntries = 2000
    public static let defaultURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cc-desk/sidebar-order.json")

    public var next: Int
    public var groups: [String: Int]
    public var rows: [String: Int]

    public init(next: Int = 0, groups: [String: Int] = [:], rows: [String: Int] = [:]) {
        self.next = next
        self.groups = groups
        self.rows = rows
    }

    static func keys(of row: SidebarRow) -> [String] {
        var keys = [row.id]
        if let sid = row.session.sessionID, !sid.isEmpty { keys.append("sid:\(sid)") }
        return keys
    }

    /// 按固定顺序重排；新出现的组 / 会话排在末尾（同一批新出现的保持传入的相对顺序）。返回是否记录了新的键。
    @discardableResult
    public mutating func apply(_ input: [SessionGroup]) -> (groups: [SessionGroup], changed: Bool) {
        var changed = false
        for group in input where groups[group.id] == nil {
            groups[group.id] = next
            next += 1
            changed = true
        }
        var result: [SessionGroup] = []
        for group in input {
            var position: [String: Int] = [:]
            for row in group.rows {
                let keys = Self.keys(of: row)
                let known = keys.compactMap { rows[$0] }.min()
                let ordinal: Int
                if let known {
                    ordinal = known
                } else {
                    ordinal = next
                    next += 1
                }
                for key in keys where rows[key] != ordinal {
                    rows[key] = ordinal
                    changed = true
                }
                position[row.id] = ordinal
            }
            let sorted = group.rows.enumerated().sorted { a, b in
                let pa = position[a.element.id] ?? Int.max, pb = position[b.element.id] ?? Int.max
                return pa != pb ? pa < pb : a.offset < b.offset
            }.map(\.element)
            result.append(SessionGroup(id: group.id, title: group.title, rows: sorted, branch: group.branch))
        }
        result = result.enumerated().sorted { a, b in
            let pa = groups[a.element.id] ?? Int.max, pb = groups[b.element.id] ?? Int.max
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map(\.element)
        if changed { prune(keeping: Set(input.map(\.id)), rowKeys: Set(input.flatMap(\.rows).flatMap(Self.keys(of:)))) }
        return (result, changed)
    }

    /// 超过上限时丢掉当前不在侧栏里、且最早出现的记录。
    mutating func prune(keeping liveGroups: Set<String>, rowKeys liveRows: Set<String>) {
        if rows.count > Self.maxEntries {
            let removable = rows.filter { !liveRows.contains($0.key) }.sorted { $0.value < $1.value }
            for (key, _) in removable.prefix(rows.count - Self.maxEntries) { rows[key] = nil }
        }
        if groups.count > Self.maxEntries {
            let removable = groups.filter { !liveGroups.contains($0.key) }.sorted { $0.value < $1.value }
            for (key, _) in removable.prefix(groups.count - Self.maxEntries) { groups[key] = nil }
        }
    }

    // MARK: 手动调整顺序

    public enum Move: Sendable { case top, up, down, bottom }

    /// 把 id 移到 index（按当前顺序 ids 计算）。
    static func reordered(_ ids: [String], moving id: String, to index: Int) -> [String] {
        guard let from = ids.firstIndex(of: id) else { return ids }
        var out = ids
        out.remove(at: from)
        out.insert(id, at: max(0, min(index, out.count)))
        return out
    }

    static func target(of move: Move, from index: Int, count: Int) -> Int {
        switch move {
        case .top: return 0
        case .up: return index - 1
        case .down: return index + 1
        case .bottom: return count - 1
        }
    }

    /// 项目组：current 为侧栏当前顺序。按方向移动。
    public mutating func moveGroup(_ id: String, _ move: Move, in current: [String]) {
        guard let index = current.firstIndex(of: id) else { return }
        moveGroup(id, to: Self.target(of: move, from: index, count: current.count), in: current)
    }

    /// 项目组：移到 index（拖拽放到某组上 = 占据它的位置）。
    public mutating func moveGroup(_ id: String, to index: Int, in current: [String]) {
        let order = Self.reordered(current, moving: id, to: index)
        // 复用这些组原有的序号重新分配，侧栏外（暂时不在）的组位置不受影响。
        let ordinals = order.compactMap { groups[$0] }.sorted()
        guard ordinals.count == order.count else { return }
        for (id, ordinal) in zip(order, ordinals) { groups[id] = ordinal }
    }

    /// 组内会话：rows 为该组当前顺序。
    public mutating func moveRow(_ id: String, _ move: Move, in rows: [SidebarRow]) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        moveRow(id, to: Self.target(of: move, from: index, count: rows.count), in: rows)
    }

    public mutating func moveRow(_ id: String, to index: Int, in rows: [SidebarRow]) {
        let order = Self.reordered(rows.map(\.id), moving: id, to: index)
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = order.compactMap { byID[$0] }
        let ordinals = ordered.compactMap { Self.keys(of: $0).compactMap { self.rows[$0] }.min() }.sorted()
        guard ordinals.count == ordered.count else { return }
        for (row, ordinal) in zip(ordered, ordinals) {
            for key in Self.keys(of: row) { self.rows[key] = ordinal }
        }
    }

    public static func load(from url: URL = defaultURL) -> SidebarOrder? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SidebarOrder.self, from: data)
    }

    public func save(to url: URL = defaultURL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
