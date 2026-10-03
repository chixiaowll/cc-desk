import Foundation

/// 给模型用的稳定短 id（s1、s2… / h1、h2…）：同一个真实 id 在 App 运行期间始终对应同一个短 id，
/// 侧栏按状态重排也不变；新出现的按顺序编号，不复用（避免模型拿旧 id 指到新会话）。
public struct ShortIDRegistry: Equatable, Sendable {
    public let prefix: String
    private var byKey: [String: String] = [:]
    private var byShort: [String: String] = [:]
    private var next = 1

    public init(prefix: String) {
        self.prefix = prefix
    }

    public mutating func id(for key: String) -> String {
        if let id = byKey[key] { return id }
        let id = "\(prefix)\(next)"
        next += 1
        byKey[key] = id
        byShort[id] = key
        return id
    }

    /// 短 id → 真实 id（大小写不敏感）；从未分配过时 nil。
    public func key(for shortID: String) -> String? {
        byShort[shortID.trimmingCharacters(in: .whitespaces).lowercased()]
    }
}

/// 按引用找会话 / 历史 / 项目的结果。
public enum ReferenceMatch<Item: Equatable>: Equatable {
    case found(Item)
    /// 多个候选，让模型追问。
    case ambiguous([Item])
    case notFound
}

/// 工具参数里的会话 / 历史 / 项目引用解析（设计 §13）：短 id、真实 id、或标题 / 目录 / agent 的模糊匹配。
public enum AssistantReferences {
    /// 指「当前选中的会话」的说法。
    static let currentWords: Set<String> = ["", "current", "selected", "this", "it", "thisone", "当前", "这个", "它", "他",
                                            "当前会话", "这个会话", "选中的", "现在这个"]
    /// 模糊匹配时忽略的词。
    static let fillers: Set<String> = ["那个", "这个", "会话", "的", "session", "the", "one", "in", "里", "里面", "项目", "project"]

    public static func session(_ ref: String?, in sessions: [AssistantSessionInfo]) -> ReferenceMatch<AssistantSessionInfo> {
        let raw = (ref ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        if currentWords.contains(lower.replacingOccurrences(of: " ", with: "")) {
            return sessions.first(where: \.isSelected).map(ReferenceMatch.found) ?? .notFound
        }
        if let s = sessions.first(where: { $0.shortID.lowercased() == lower || $0.rowID == raw }) { return .found(s) }
        let candidates = fuzzy(lower, in: sessions) { [$0.title, $0.dir, $0.agent.rawValue] }
        guard candidates.count > 1 else { return candidates.first.map(ReferenceMatch.found) ?? .notFound }
        // 目录名完全相同的优先。
        let exactDir = candidates.filter { $0.dir.lowercased() == lower }
        if exactDir.count == 1 { return .found(exactDir[0]) }
        return .ambiguous(candidates)
    }

    public static func history(_ ref: String?, in history: [AssistantHistoryInfo]) -> ReferenceMatch<AssistantHistoryInfo> {
        let raw = (ref ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .notFound }
        let lower = raw.lowercased()
        if let h = history.first(where: { $0.shortID.lowercased() == lower || $0.sessionID == raw }) { return .found(h) }
        let candidates = fuzzy(lower, in: history) { [$0.title, $0.dir, $0.agent.rawValue] }
        // 历史按时间倒序：标题完全包含查询的只有一个时直接用它。
        guard candidates.count > 1 else { return candidates.first.map(ReferenceMatch.found) ?? .notFound }
        let titled = candidates.filter { $0.title.lowercased().contains(lower) }
        if titled.count == 1 { return .found(titled[0]) }
        return .ambiguous(Array(candidates.prefix(5)))
    }

    public static func project(_ ref: String?, in projects: [AssistantProject]) -> ReferenceMatch<AssistantProject> {
        let raw = (ref ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .notFound }
        let path = raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        if let p = projects.first(where: { $0.path == path }) { return .found(p) }
        let lower = path.lowercased()
        let named = projects.filter { $0.name.lowercased() == lower }
        if named.count == 1 { return .found(named[0]) }
        if named.count > 1 { return .ambiguous(named) }
        let candidates = fuzzy(lower, in: projects) { [$0.name] }
        guard candidates.count > 1 else { return candidates.first.map(ReferenceMatch.found) ?? .notFound }
        return .ambiguous(candidates)
    }

    /// 引用有歧义 / 找不到时给模型的说明（列出候选，让它追问用户）。
    public static func ambiguity(_ ref: String, _ candidates: [AssistantSessionInfo]) -> String {
        "\"\(ref)\" matches several sessions, ask the user which one: " + candidates.prefix(6).map(describe).joined(separator: "; ")
    }

    public static func describe(_ s: AssistantSessionInfo) -> String {
        "\(s.shortID) \(s.dir) / \(AssistantContext.clip(s.title, 30)) (\(s.agent.rawValue), \(AssistantContext.statusCode(s.status)))"
    }

    /// 整个引用被某个字段包含，或去掉虚词后的每个词都被某个字段包含。
    public static func fuzzy<T>(_ lower: String, in items: [T], fields: (T) -> [String]) -> [T] {
        guard !lower.isEmpty else { return [] }
        let whole = items.filter { fields($0).contains { $0.lowercased().contains(lower) } }
        if !whole.isEmpty { return whole }
        var words = lower.components(separatedBy: CharacterSet.whitespaces.union(.punctuationCharacters))
            .filter { !$0.isEmpty && !fillers.contains($0) }
        // 「poems那个」这类没有空格的中文说法：去掉虚词后整体再试一次。
        if words.count <= 1 {
            var stripped = lower
            for f in fillers.sorted(by: { $0.count > $1.count }) { stripped = stripped.replacingOccurrences(of: f, with: " ") }
            words = stripped.split(separator: " ").map(String.init)
        }
        guard !words.isEmpty else { return [] }
        return items.filter { item in
            let haystack = fields(item).map { $0.lowercased() }
            return words.allSatisfy { w in haystack.contains { $0.contains(w) } }
        }
    }
}

// MARK: - 撤销

/// 可撤销的动作（设计 §13「撤销」）。
public enum UndoableAction: Equatable, Sendable {
    /// 新建了会话（撤销 = 关闭它）。
    case created(rowID: String, title: String)
    /// 往某个终端输入了文字、还没发送（撤销 = 退格删掉这么多字符）。
    case typed(terminalID: UUID, text: String, title: String)
    /// 切换了会话（撤销 = 切回 `from`）。
    case switched(from: String, title: String)
}

/// 撤销记录：最近的在最后，最多 `limit` 条，超过 `ttl` 秒的不再撤销。纯逻辑，时间由调用方传入。
public struct UndoLedger: Equatable, Sendable {
    public static let limit = 10
    public static let ttl: TimeInterval = 600
    private var entries: [(action: UndoableAction, at: TimeInterval)] = []

    public init() {}

    public static func == (a: UndoLedger, b: UndoLedger) -> Bool {
        a.entries.map(\.action) == b.entries.map(\.action) && a.entries.map(\.at) == b.entries.map(\.at)
    }

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func record(_ action: UndoableAction, now: TimeInterval) {
        entries.append((action, now))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// 该终端的输入已发送 / 清空：之前的「输入」不能再撤销。
    public mutating func typingFinished(terminalID: UUID) {
        entries.removeAll {
            if case .typed(let id, _, _) = $0.action { return id == terminalID }
            return false
        }
    }

    /// 会话已关闭：与它相关的记录都作废。
    public mutating func sessionClosed(rowID: String, terminalID: UUID?) {
        entries.removeAll {
            switch $0.action {
            case .created(let id, _): return id == rowID
            case .typed(let id, _, _): return id == terminalID
            case .switched(let from, _): return from == rowID
            }
        }
    }

    /// 取出最近一条仍有效的动作。
    public mutating func pop(now: TimeInterval) -> UndoableAction? {
        while let last = entries.popLast() {
            if now - last.at <= Self.ttl { return last.action }
        }
        return nil
    }
}
