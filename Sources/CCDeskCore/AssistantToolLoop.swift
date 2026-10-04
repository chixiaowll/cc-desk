import Foundation

/// OpenAI 兼容接口的一轮（设计 §22）：发请求 → 模型要调用工具就逐个执行、把结果接回去再请求 → 直到得到文字回复。
///
/// - 工具先过 `gate`（助手：`AssistantToolPolicy.check`，与 MCP 路径同一个函数），被拒绝的不执行，拒绝说明作为结果交给模型；
///   未知工具、参数不是 JSON 对象时同样回一个错误结果，让模型自己改正。
/// - 最多 `maxIterations` 次带工具的请求；用完时再发一次 `tool_choice: none` 逼出文字回复，仍要调用工具就失败。
/// - 总时长 `timeout`：每次请求只给剩余的时间，超出即失败。
/// - 回复取最后一次请求（没有工具调用的那次）的文字，去掉 `<think>` 段；调用工具时夹带的文字不朗读也不存。
/// - completion 恰好调用一次；`cancel()` 之后不再调用。不碰线程：调用方保证 transport / executor 的回调与 cancel 在同一个
///   串行上下文里（App 里是主线程）。
public final class AssistantToolLoop {
    public typealias Transport = (_ body: JSONValue, _ timeout: TimeInterval,
                                  _ completion: @escaping (Result<ChatCompletion, ChatAPIError>) -> Void) -> (() -> Void)
    public typealias Executor = (_ name: String, _ arguments: [String: JSONValue],
                                 _ completion: @escaping (MCPServerCore.ToolOutcome) -> Void) -> Void
    /// nil = 放行；否则是拒绝说明。
    public typealias Gate = (_ name: String) -> String?

    public static let defaultMaxIterations = 8
    /// 单个工具结果交给模型（并存进历史）的上限。
    public static let toolResultLimit = 12_000

    public struct Outcome: Equatable, Sendable {
        /// 要朗读 / 显示的回复。
        public var text: String
        /// 这一轮新增的消息：用户消息、带工具调用的 assistant 消息、工具结果、最后的回复（存进历史）。
        public var turnMessages: [ChatMessage]
        public var promptTokens: Int
        public var completionTokens: Int
        /// 最后一次请求的输入 token（= 当前上下文大小）。
        public var lastPromptTokens: Int
        /// 发了几次请求。
        public var requests: Int
        public var toolCalls: Int
        /// 被拒绝 / 出错的工具调用数。
        public var rejected: Int
        public var finishReason: String?
    }

    public enum Failure: Error, Equatable, Sendable {
        case api(ChatAPIError)
        case timeout
        case tooManyIterations
        case cancelled
    }

    private let model: String
    private let prefix: [ChatMessage]
    private let tools: [AssistantToolSpec]
    private let maxIterations: Int
    private let timeout: TimeInterval
    private let gate: Gate
    private let transport: Transport
    private let executor: Executor
    private let now: () -> Date
    private let onToolCall: ((String) -> Void)?

    private var turn: [ChatMessage]
    private var deadline = Date.distantFuture
    private var promptTokens = 0
    private var completionTokens = 0
    private var lastPromptTokens = 0
    private var requests = 0
    private var toolCalls = 0
    private var rejected = 0
    private var cancelRequest: (() -> Void)?
    private var completion: ((Result<Outcome, Failure>) -> Void)?
    private var finished = false

    /// prefix：系统提示词与历史；user：这一轮的用户消息。onToolCall：每次要执行一个工具时（进度显示）。
    public init(model: String, prefix: [ChatMessage], user: ChatMessage, tools: [AssistantToolSpec],
                maxIterations: Int = AssistantToolLoop.defaultMaxIterations, timeout: TimeInterval,
                gate: @escaping Gate, transport: @escaping Transport, executor: @escaping Executor,
                now: @escaping () -> Date = Date.init, onToolCall: ((String) -> Void)? = nil) {
        self.model = model
        self.prefix = prefix
        self.turn = [user]
        self.tools = tools
        self.maxIterations = max(1, maxIterations)
        self.timeout = timeout
        self.gate = gate
        self.transport = transport
        self.executor = executor
        self.now = now
        self.onToolCall = onToolCall
    }

    public func start(completion: @escaping (Result<Outcome, Failure>) -> Void) {
        guard self.completion == nil, !finished else { return }
        self.completion = completion
        deadline = now().addingTimeInterval(timeout)
        request()
    }

    public func cancel() {
        guard !finished else { return }
        finished = true
        completion = nil
        cancelRequest?()
        cancelRequest = nil
    }

    // MARK: 内部

    private func finish(_ result: Result<Outcome, Failure>) {
        guard !finished else { return }
        finished = true
        cancelRequest = nil
        let done = completion
        completion = nil
        done?(result)
    }

    private func request() {
        guard !finished else { return }
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0 else { return finish(.failure(.timeout)) }
        // 前 maxIterations 次可以调用工具；之后一次只许回文字。
        let forceText = requests >= maxIterations
        let body = ChatAPI.body(model: model, messages: prefix + turn, tools: tools, toolChoice: forceText ? "none" : nil)
        requests += 1
        cancelRequest = transport(body, remaining) { [weak self] result in
            self?.received(result, forcedText: forceText)
        }
    }

    private func received(_ result: Result<ChatCompletion, ChatAPIError>, forcedText: Bool) {
        guard !finished else { return }
        cancelRequest = nil
        let completion: ChatCompletion
        switch result {
        case .failure(.timeout): return finish(.failure(.timeout))
        case .failure(.cancelled): return finish(.failure(.cancelled))
        case .failure(let error): return finish(.failure(.api(error)))
        case .success(let value): completion = value
        }
        promptTokens += completion.promptTokens
        completionTokens += completion.completionTokens
        lastPromptTokens = completion.promptTokens
        guard completion.toolCalls.isEmpty else {
            if forcedText { return finish(.failure(.tooManyIterations)) }
            // 调用工具时夹带的文字（「我来看看」）不保留：只朗读最后的回复。
            turn.append(ChatMessage(role: "assistant", content: "", toolCalls: completion.toolCalls))
            return runTools(completion.toolCalls[...])
        }
        let text = ChatAPI.stripThinking(completion.content ?? "")
        turn.append(ChatMessage(role: "assistant", content: text))
        finish(.success(Outcome(text: text, turnMessages: turn, promptTokens: promptTokens,
                                completionTokens: completionTokens, lastPromptTokens: lastPromptTokens,
                                requests: requests, toolCalls: toolCalls, rejected: rejected,
                                finishReason: completion.finishReason)))
    }

    /// 依次执行（需确认的工具会等用户回答，顺序要和模型给的一致），全部有结果后再请求。
    private func runTools(_ pending: ArraySlice<ChatToolCall>) {
        guard !finished else { return }
        guard let call = pending.first else { return request() }
        let rest = pending.dropFirst()
        toolCalls += 1
        let reply: (String) -> Void = { [weak self] text in
            guard let self, !self.finished else { return }
            self.turn.append(.tool(id: call.id, Self.clip(text)))
            self.runTools(rest)
        }
        guard tools.contains(where: { $0.name == call.name }) else {
            rejected += 1
            return reply("Error: unknown tool \(call.name). Available tools: " + tools.map(\.name).joined(separator: ", "))
        }
        let arguments: [String: JSONValue]
        switch call.parsedArguments() {
        case .failure(let error):
            rejected += 1
            return reply("Error: " + error.message)
        case .success(let value): arguments = value
        }
        if let denial = gate(call.name) {
            rejected += 1
            return reply("Error: " + denial)
        }
        onToolCall?(call.name)
        var answered = false
        executor(call.name, arguments) { [weak self] outcome in
            guard !answered else { return }
            answered = true
            if outcome.isError { self?.rejected += 1 }
            reply(outcome.isError ? "Error: " + outcome.text : outcome.text)
        }
    }

    static func clip(_ text: String) -> String {
        text.count > toolResultLimit ? String(text.prefix(toolResultLimit)) + "\n…(truncated)" : text
    }
}
