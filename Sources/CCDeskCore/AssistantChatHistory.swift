import Foundation

/// OpenAI 兼容接口后端的对话历史（设计 §22）：不含系统提示词（每次按当前版本生成），按「轮」保存——
/// 一轮从一条 user 消息开始，含之后的工具调用、工具结果与回复。超过上限时从最早的整轮丢弃，
/// 不会留下没有结果的工具调用。按字符估算大小（中文约 1 字 1 token，英文约 4 字符 1 token）。
public struct AssistantChatHistory: Equatable, Codable, Sendable {
    public static let maxChars = 60_000
    public static let maxTurns = 40

    /// 写下这些消息时的系统提示词版本；版本不同就从头开始（与 Claude 会话的 promptVersion 相同的规则）。
    public var promptVersion: Int
    public private(set) var messages: [ChatMessage]

    public init(promptVersion: Int, messages: [ChatMessage] = []) {
        self.promptVersion = promptVersion
        self.messages = Self.sanitized(messages)
    }

    public var size: Int { messages.reduce(0) { $0 + $1.size } }
    public var turnCount: Int { Self.turnStarts(messages).count }

    /// 追加一轮；超出上限时丢弃最早的整轮（至少保留最新的一轮）。返回是否丢弃了内容。
    @discardableResult
    public mutating func append(_ turn: [ChatMessage], maxChars: Int = maxChars, maxTurns: Int = maxTurns) -> Bool {
        messages += Self.sanitized(turn)
        return trim(maxChars: maxChars, maxTurns: maxTurns)
    }

    @discardableResult
    public mutating func trim(maxChars: Int = maxChars, maxTurns: Int = maxTurns) -> Bool {
        var dropped = false
        while true {
            let starts = Self.turnStarts(messages)
            guard starts.count > 1, size > maxChars || starts.count > maxTurns else { break }
            messages.removeSubrange(0..<starts[1])
            dropped = true
        }
        return dropped
    }

    public mutating func clear() {
        messages = []
    }

    static func turnStarts(_ messages: [ChatMessage]) -> [Int] {
        messages.indices.filter { messages[$0].role == "user" }
    }

    /// 只保留结构完整的轮：以 user 开头；每条带工具调用的 assistant 消息后面紧跟着全部调用的结果。
    static func sanitized(_ messages: [ChatMessage]) -> [ChatMessage] {
        let starts = turnStarts(messages)
        var out: [ChatMessage] = []
        for (n, start) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1] : messages.count
            let turn = Array(messages[start..<end])
            if isComplete(turn) { out += turn }
        }
        return out
    }

    private static func isComplete(_ turn: [ChatMessage]) -> Bool {
        var i = 1
        while i < turn.count {
            let message = turn[i]
            if message.role == "assistant", let calls = message.toolCalls, !calls.isEmpty {
                let results = turn.dropFirst(i + 1).prefix(calls.count)
                guard results.count == calls.count,
                      zip(calls, results).allSatisfy({ $1.role == "tool" && $1.toolCallID == $0.id }) else { return false }
                i += calls.count + 1
            } else if message.role == "assistant" {
                i += 1
            } else {
                return false
            }
        }
        return true
    }
}

/// 历史存在 ~/.cc-desk/assistant/api-history.json（文件 0600、目录 0700）。
public struct AssistantChatHistoryStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// 读回；没有文件、读不了或提示词版本不同时返回空历史。
    public func load(promptVersion: Int) -> AssistantChatHistory {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(AssistantChatHistory.self, from: data),
              stored.promptVersion == promptVersion else { return AssistantChatHistory(promptVersion: promptVersion) }
        return AssistantChatHistory(promptVersion: promptVersion, messages: stored.messages)
    }

    public func save(_ history: AssistantChatHistory) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)
        let data = try JSONEncoder().encode(history)
        // 先建好 0600 的文件再写，内容不会有一刻对其他用户可读。
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8))")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: tmp)
            try handle.write(contentsOf: data)
            try handle.close()
            if rename(tmp.path, url.path) != 0 { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
