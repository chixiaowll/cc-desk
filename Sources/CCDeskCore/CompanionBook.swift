import Foundation

// MARK: - 通用助手的问答记录（设计 §24）

/// 一次问答：语音助手经 ask_companion 交来的问题、排队 / 回答状态、回答与用量。
public struct CompanionJob: Equatable, Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case queued, running, done, failed, cancelled, timedOut
    }

    /// 短 id（q1、q2…）。
    public let id: String
    public let question: String
    /// 语音助手附带的备注（可选）。
    public let note: String?
    /// 模型名（sonnet / 接口的模型名）。
    public let model: String
    /// "claude" / "api"。
    public let engine: String
    /// 交来的时刻。
    public let askedAt: Date
    public var state: State
    /// 开始回答的时刻（排队结束）。
    public var startedAt: Date?
    public var finishedAt: Date?
    /// 回答正文（不含来源列表）。
    public var answer: String?
    public var sources: [CompanionSource]
    /// 上网用过的搜索词 / 网址。
    public var webLookups: [String]
    public var inputTokens: Int
    public var outputTokens: Int
    public var error: String?

    public init(id: String, question: String, note: String?, model: String, engine: String, askedAt: Date) {
        self.id = id
        self.question = question
        self.note = note
        self.model = model
        self.engine = engine
        self.askedAt = askedAt
        state = .queued
        sources = []
        webLookups = []
        inputTokens = 0
        outputTokens = 0
    }

    /// 回答用时（不含排队）。
    public var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt ?? askedAt)
    }

    public var isActive: Bool { state == .queued || state == .running }

    /// 回答的结果。
    public struct Outcome: Equatable, Sendable {
        public var answer: String
        public var sources: [CompanionSource]
        public var webLookups: [String]
        public var inputTokens: Int
        public var outputTokens: Int

        public init(answer: String, sources: [CompanionSource] = [], webLookups: [String] = [], inputTokens: Int = 0,
                    outputTokens: Int = 0) {
            self.answer = answer
            self.sources = sources
            self.webLookups = webLookups
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
        }
    }
}

/// 最近一次问答（给语音助手的上下文，便于把追问交回通用助手；也用于换新会话后的前情提要）。
public struct CompanionExchange: Equatable, Sendable {
    public let question: String
    public let answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

/// 问答簿：短 id、一次只回答一个、其余排队（最多 `CompanionCommand.maxQueued` 个）、保留最近若干条（持久化供结果面板）。
/// 纯数据，调用方负责线程与真正的模型调用。
public struct CompanionBook: Equatable, Codable, Sendable {
    public static let keep = 30
    public private(set) var jobs: [CompanionJob] = []
    private var nextNumber = 1

    public init() {}

    public enum StartError: Error, Equatable {
        case queueFull
    }

    public var running: CompanionJob? { jobs.first { $0.state == .running } }
    /// 排队中的，先来的在前。
    public var queued: [CompanionJob] { jobs.filter { $0.state == .queued }.reversed() }
    public var hasActive: Bool { jobs.contains(where: \.isActive) }

    /// 登记一个问题（排队）；排队已满时拒绝。之后调用 `startNext` 取出要回答的那个。
    public mutating func enqueue(question: String, note: String?, model: String, engine: String, now: Date,
                                 maxQueued: Int = CompanionCommand.maxQueued) -> Result<CompanionJob, StartError> {
        guard queued.count < maxQueued else { return .failure(.queueFull) }
        let job = CompanionJob(id: "q\(nextNumber)", question: question, note: note, model: model, engine: engine,
                               askedAt: now)
        nextNumber += 1
        jobs.insert(job, at: 0)
        prune()
        return .success(job)
    }

    /// 没有正在回答的时：把最早排队的那个标为回答中并返回。
    public mutating func startNext(now: Date) -> CompanionJob? {
        guard running == nil, let next = queued.first, let i = jobs.firstIndex(where: { $0.id == next.id }) else { return nil }
        jobs[i].state = .running
        jobs[i].startedAt = now
        return jobs[i]
    }

    /// 结束一个仍在排队 / 回答中的问题；已结束的忽略，返回 nil。
    @discardableResult
    public mutating func finish(_ id: String, state: CompanionJob.State, outcome: CompanionJob.Outcome? = nil,
                                error: String? = nil, now: Date) -> CompanionJob? {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].isActive, state != .running, state != .queued
        else { return nil }
        jobs[i].state = state
        jobs[i].finishedAt = now
        jobs[i].error = error
        if let outcome {
            jobs[i].answer = outcome.answer
            jobs[i].sources = outcome.sources
            jobs[i].webLookups = outcome.webLookups
            jobs[i].inputTokens = outcome.inputTokens
            jobs[i].outputTokens = outcome.outputTokens
        }
        return jobs[i]
    }

    /// 取消所有排队 / 回答中的（「算了」/ 关闭对话模式）；返回被取消的 id（回答中的在前）。
    @discardableResult
    public mutating func cancelAll(now: Date) -> [String] {
        let ids = (running.map { [$0.id] } ?? []) + queued.map(\.id)
        for id in ids { finish(id, state: .cancelled, now: now) }
        return ids
    }

    public func job(_ id: String) -> CompanionJob? {
        let key = id.trimmingCharacters(in: .whitespaces).lowercased()
        return jobs.first { $0.id == key }
    }

    /// 最近一次答完的问答（`within` 秒内）；用于语音助手的上下文。
    public func latestExchange(now: Date, within: TimeInterval) -> CompanionExchange? {
        guard let job = jobs.first(where: { $0.state == .done }), let answer = job.answer,
              let finished = job.finishedAt, now.timeIntervalSince(finished) <= within else { return nil }
        return CompanionExchange(question: job.question, answer: answer)
    }

    /// 最近几次答完的问答（旧的在前），换新会话时作前情提要。
    public func recap(limit: Int = 2) -> [CompanionExchange] {
        jobs.filter { $0.state == .done }.prefix(limit).reversed().compactMap { job in
            job.answer.map { CompanionExchange(question: job.question, answer: $0) }
        }
    }

    /// 读回持久化的记录：上次退出时还在排队 / 回答的标为失败。
    public mutating func recoverAfterRestart(now: Date) {
        for i in jobs.indices where jobs[i].isActive {
            jobs[i].state = .failed
            jobs[i].finishedAt = now
            jobs[i].error = "CC Desk quit before it finished"
        }
    }

    /// 清空记录（「清空通用助手记忆」）；短 id 继续往上数。
    public mutating func clear() {
        jobs = []
    }

    private mutating func prune() {
        guard jobs.count > Self.keep else { return }
        var kept: [CompanionJob] = []
        var others = 0
        let active = jobs.filter(\.isActive).count
        for job in jobs {
            if job.isActive { kept.append(job); continue }
            if others < Self.keep - active { kept.append(job); others += 1 }
        }
        jobs = kept
    }
}
