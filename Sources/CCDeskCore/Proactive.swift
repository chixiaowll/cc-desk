import Foundation

// MARK: - 主动提醒（设计 §14）

/// 一次状态变化是否要告诉常驻助手（由它决定播不播报）。
public enum ProactivePolicy {
    public enum Trigger: Equatable, Sendable {
        case needsApproval(reason: String?)
        case finished
    }

    /// - 对话模式关闭：一律不（只发普通通知）。
    /// - 选中的会话：不（已有的选中会话播报 / 回复摘要负责）。
    /// - 等批准：任意会话都告诉助手。
    /// - 一轮完成：只对派出的任务。
    public static func shouldNotify(_ trigger: Trigger, isSelected: Bool, isDelegated: Bool, conversationOn: Bool) -> Bool {
        guard conversationOn, !isSelected else { return false }
        switch trigger {
        case .needsApproval: return true
        case .finished: return isDelegated
        }
    }
}

/// 主动播报的排队与限流：用户正在说话 / 识别 / 等助手 / 播报时先排着；全局与同一会话各有最短间隔；
/// 排太久的过期丢弃。纯逻辑，时间由调用方传入。
public struct ProactiveSpeechGate: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// 会话等批准（reason 为当时的等待原因，播报前复核）。
            case approval(reason: String?)
            case finished
            /// 顾问结果：用户主动要的，不受同一会话间隔限制。
            case consult
        }

        public let key: String
        public let kind: Kind
        public let text: String
        public let enqueuedAt: TimeInterval

        public init(key: String, kind: Kind, text: String, enqueuedAt: TimeInterval) {
            self.key = key
            self.kind = kind
            self.text = text
            self.enqueuedAt = enqueuedAt
        }
    }

    public let globalInterval: TimeInterval
    public let perKeyInterval: TimeInterval
    public let maxAge: TimeInterval
    public let capacity: Int
    public private(set) var queue: [Item] = []
    private var lastSpokenAt: TimeInterval?
    private var lastSpokenByKey: [String: TimeInterval] = [:]

    public init(globalInterval: TimeInterval = 8, perKeyInterval: TimeInterval = 30, maxAge: TimeInterval = 120,
                capacity: Int = 6) {
        self.globalInterval = globalInterval
        self.perKeyInterval = perKeyInterval
        self.maxAge = maxAge
        self.capacity = capacity
    }

    /// 排队；同一会话、同类的旧条目被新的替换。超出容量时丢最旧的非顾问条目。
    public mutating func enqueue(_ item: Item) {
        queue.removeAll { $0.key == item.key && Self.sameKind($0.kind, item.kind) }
        queue.append(item)
        while queue.count > capacity {
            if let i = queue.firstIndex(where: { $0.kind != .consult }) { queue.remove(at: i) } else { queue.removeFirst() }
        }
    }

    /// 现在可以播的下一条（并记为已播）；busy 时或间隔未到时 nil。过期条目顺带丢掉。
    public mutating func next(now: TimeInterval, busy: Bool) -> Item? {
        queue.removeAll { now - $0.enqueuedAt > maxAge }
        guard !busy, !queue.isEmpty else { return nil }
        if let last = lastSpokenAt, now - last < globalInterval { return nil }
        guard let index = queue.firstIndex(where: { item in
            if case .consult = item.kind { return true }
            guard let last = lastSpokenByKey[item.key] else { return true }
            return now - last >= perKeyInterval
        }) else { return nil }
        let item = queue.remove(at: index)
        lastSpokenAt = now
        lastSpokenByKey[item.key] = now
        return item
    }

    /// 丢掉某个会话的排队条目（如用户已切过去 / 已处理）。
    public mutating func drop(key: String) {
        queue.removeAll { $0.key == key }
    }

    public var isEmpty: Bool { queue.isEmpty }

    static func sameKind(_ a: Item.Kind, _ b: Item.Kind) -> Bool {
        switch (a, b) {
        case (.approval, .approval), (.finished, .finished), (.consult, .consult): return true
        default: return false
        }
    }
}

/// 刚播报过的「某会话要批准」：用户随后说「批准 / 拒绝」时作用于这个会话（不是选中的会话），
/// 且只在它仍在等同一个请求时执行（ApprovalNotification.decide 复核）。
public struct AnnouncedApproval: Equatable, Sendable {
    public static let window: TimeInterval = 120

    public let rowID: String
    public let name: String
    public let reason: String?
    public let at: TimeInterval

    public init(rowID: String, name: String, reason: String?, at: TimeInterval) {
        self.rowID = rowID
        self.name = name
        self.reason = reason
        self.at = at
    }

    public func isFresh(now: TimeInterval) -> Bool { now - at <= Self.window }
}

// MARK: - 派活的启动命令

public enum DelegateCommand {
    /// 交互式 claude：`claude --session-id <id> [--agents "$(cat <file>)" --agent <name>] '<task>'`。
    /// 配置的 JSON 写在文件里、由 shell 读出，tmux 命令行不会因为提示词太长而超限。
    public static func claude(task: String, sessionID: String, profile: (name: String, jsonFile: String)?) -> String {
        var command = "claude --session-id \(ShellQuote.quote(sessionID))"
        if let profile {
            command += " --agents \"$(cat \(ShellQuote.quote(profile.jsonFile)))\" --agent \(ShellQuote.quote(profile.name))"
        }
        return command + promptArgument(task)
    }

    /// 第一句话作为位置参数：去掉换行；以 `-` 开头时补空格，避免被当成选项。
    static func promptArgument(_ task: String) -> String {
        let text = task.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return "" }
        return " " + ShellQuote.quote(text.hasPrefix("-") ? " " + text : text)
    }
}
