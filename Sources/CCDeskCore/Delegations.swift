import Foundation

/// 助手派出的任务（设计 §14 delegate）：在侧栏里可见的内嵌会话。记在 `~/.cc-desk/assistant/delegations.json`，
/// 主动提醒据此判断「这是派出的任务」（非选中会话的「一轮完成」只对派出的任务播报）。
public struct Delegation: Equatable, Codable, Sendable {
    public enum State: String, Codable, Sendable {
        /// 刚启动 / 正在处理。
        case working
        case waiting
        /// 一轮完成，等用户看结果。
        case idle
        /// agent 已退出（终端还在）。
        case ended
        /// 会话已关闭。
        case closed
    }

    /// 侧栏行 id（`term:<uuid>`）。
    public let rowID: String
    public let terminalID: String
    /// agent 会话 id（claude 用 `--session-id` 预先指定；codex / pi 出现后补上）。
    public var sessionID: String?
    public let project: String
    public let task: String
    public let agent: String
    public let profile: String?
    public let startedAt: Date
    public var state: State
    public var updatedAt: Date

    public init(rowID: String, terminalID: String, sessionID: String?, project: String, task: String, agent: String,
                profile: String?, startedAt: Date) {
        self.rowID = rowID
        self.terminalID = terminalID
        self.sessionID = sessionID
        self.project = project
        self.task = task
        self.agent = agent
        self.profile = profile
        self.startedAt = startedAt
        self.state = .working
        self.updatedAt = startedAt
    }
}

/// 派出任务的记录簿。纯数据；持久化见 `DelegationStore`。
public struct DelegationBook: Equatable, Codable, Sendable {
    public static let keep = 30
    /// 已关闭的记录保留多久。
    public static let closedRetention: TimeInterval = 3 * 24 * 3600

    public private(set) var items: [Delegation] = []

    public init(items: [Delegation] = []) {
        self.items = items
    }

    public mutating func add(_ delegation: Delegation) {
        items.removeAll { $0.rowID == delegation.rowID }
        items.insert(delegation, at: 0)
        if items.count > Self.keep { items = Array(items.prefix(Self.keep)) }
    }

    /// 仍在侧栏上的派出任务（未关闭）。
    public func active(rowID: String) -> Delegation? {
        items.first { $0.rowID == rowID && $0.state != .closed }
    }

    public func isDelegated(_ rowID: String) -> Bool { active(rowID: rowID) != nil }

    /// 一行的当前情况（每次轮询）。
    public struct Observation: Equatable, Sendable {
        public let rowID: String
        public let status: AgentStatus
        public let sessionID: String?

        public init(rowID: String, status: AgentStatus, sessionID: String?) {
            self.rowID = rowID
            self.status = status
            self.sessionID = sessionID
        }
    }

    /// 按本轮侧栏更新状态；`liveRowIDs` 里没有的（终端已关闭）标为 closed，过期的已关闭记录删掉。返回是否有变化。
    @discardableResult
    public mutating func update(observations: [Observation], liveRowIDs: Set<String>, now: Date) -> Bool {
        let byRow = Dictionary(observations.map { ($0.rowID, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = false
        for i in items.indices where items[i].state != .closed {
            guard liveRowIDs.contains(items[i].rowID) else {
                items[i].state = .closed
                items[i].updatedAt = now
                changed = true
                continue
            }
            guard let obs = byRow[items[i].rowID] else { continue }
            let state = Self.state(for: obs.status, previous: items[i].state)
            if state != items[i].state {
                items[i].state = state
                items[i].updatedAt = now
                changed = true
            }
            if let sid = obs.sessionID, sid != items[i].sessionID {
                items[i].sessionID = sid
                changed = true
            }
        }
        let before = items.count
        items.removeAll { $0.state == .closed && now.timeIntervalSince($0.updatedAt) > Self.closedRetention }
        return changed || items.count != before
    }

    static func state(for status: AgentStatus, previous: Delegation.State) -> Delegation.State {
        switch status {
        case .working: return .working
        case .waiting: return .waiting
        case .idle: return .idle
        case .ended: return .ended
        // 刚启动时 agent 还没注册（unknown）：保持原状态。
        case .unknown: return previous
        }
    }
}

/// delegations.json 的读写（目录 0700 由调用方保证）。
public struct DelegationStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> DelegationBook {
        guard let data = try? Data(contentsOf: url) else { return DelegationBook() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(DelegationBook.self, from: data)) ?? DelegationBook()
    }

    public func save(_ book: DelegationBook) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(book) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
