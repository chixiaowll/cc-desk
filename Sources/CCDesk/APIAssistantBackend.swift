import Foundation
import CCDeskCore

/// OpenAI 兼容接口的助手后端（设计 §22）：每条消息跑一轮 `AssistantToolLoop`（函数调用 → 进程内执行 CC Desk 的工具 →
/// 再请求），对话历史在内存里并存到 api-history.json（0600），重启后接着用；过长时从最早的整轮裁掉。
///
/// - 请求串行、恰好一次的 completion、超时、重置：与 Claude 会话共用 `AssistantRequestQueue`（「进程」= 正在跑的那一轮）。
/// - 工具权限：每个调用先过 `AssistantToolPolicy.check`（与 MCP 路径同一个函数），再交给工具执行器（它也会检查一次）。
/// - 日志只记状态码、耗时、token 数与工具个数，不记密钥、地址路径和消息内容。
/// - 只在主线程使用；网络回调切回主线程。
final class APIAssistantBackend: AssistantBackend {
    /// 摘要 / 事件等请求至少给这么久（比 claude 慢的接口与本机模型）。
    static let minimumTimeout: TimeInterval = 45
    /// 一轮的兜底时长（真正的超时由请求队列控制，超时后会取消这一轮）。
    static let loopTimeout: TimeInterval = 120

    let kind = AssistantBackendKind.api
    private(set) var generation = 0

    private let store: AssistantChatHistoryStore
    private let endpoint: () -> APIEndpoint?
    private let executor: AssistantToolExecutor
    private let http: ChatHTTPClient
    private let promptVersion: Int
    private var history: AssistantChatHistory
    private var loaded = false
    private var loop: AssistantToolLoop?
    private var loopID = 0
    private lazy var requests = AssistantRequestQueue<AssistantReply>(driver: AssistantRequestQueue.Driver(
        ensureRunning: { [unowned self] in endpoint() != nil },
        send: { [unowned self] message in startTurn(message) },
        stopProcess: { [unowned self] in cancelTurn() },
        schedule: { seconds, work in DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work) }))

    /// 历史写盘（串行，后写的最后落盘）。
    private static let ioQueue = DispatchQueue(label: "cc-desk.assistant.api.io")

    init(store: AssistantChatHistoryStore, endpoint: @escaping () -> APIEndpoint?, executor: @escaping AssistantToolExecutor,
         http: ChatHTTPClient = .shared, promptVersion: Int = AssistantPrompt.apiVersion) {
        self.store = store
        self.endpoint = endpoint
        self.executor = executor
        self.http = http
        self.promptVersion = promptVersion
        history = AssistantChatHistory(promptVersion: promptVersion)
    }

    var currentTurn: AssistantTurn? { requests.currentTurn }

    /// 历史里有几轮（自检用）。
    var turnCount: Int {
        loadIfNeeded()
        return history.turnCount
    }

    func ask(_ message: String, turn: AssistantTurn, timeout: TimeInterval,
             completion: @escaping (Result<AssistantReply, AssistantError>) -> Void) {
        loadIfNeeded()
        let limit = turn.kind == .utterance ? timeout : max(timeout, Self.minimumTimeout)
        requests.enqueue(message, turn: turn, timeout: limit) { result in
            let mapped = result.mapError(Self.map)
            // 统一异步回调：调用方可能在 ask 返回之前还没准备好处理结果。
            DispatchQueue.main.async { completion(mapped) }
        }
    }

    func warmUp() {
        loadIfNeeded()
    }

    func reset() {
        loadIfNeeded()
        history.clear()
        generation += 1
        let store = self.store
        Self.ioQueue.async { store.remove() }
        requests.abort("reset")
        AssistantDiag.log("api assistant history reset")
    }

    func shutdown() {
        requests.shutdown()
    }

    private static func map(_ failure: AssistantRequestQueue<AssistantReply>.Failure) -> AssistantError {
        switch failure {
        case .notStarted: return .notInstalled
        case .timeout:
            AssistantDiag.log("api assistant timeout")
            return .timeout
        case .writeFailed: return .failed("send")
        case .exited: return .failed("stopped")
        case .aborted(let reason): return .failed(reason)
        case .failed(let message): return message.hasPrefix("api:") ? .api(String(message.dropFirst(4))) : .failed(message)
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        history = store.load(promptVersion: promptVersion)
        generation += 1
        if history.turnCount > 0 { AssistantDiag.log("api assistant history loaded: \(history.turnCount) turns") }
    }

    // MARK: 一轮

    private func startTurn(_ message: String) -> Bool {
        guard let endpoint = endpoint() else { return false }
        let turn = requests.currentTurn
        let started = Date()
        loopID += 1
        let id = loopID
        let prefix = [ChatMessage.system(AssistantPrompt.apiSystem)] + history.messages
        let loop = AssistantToolLoop(
            model: endpoint.model, prefix: prefix, user: .user(message), tools: AssistantTools.all,
            timeout: Self.loopTimeout,
            gate: { AssistantToolPolicy.check($0, turn: turn?.kind) },
            transport: http.transport(endpoint: endpoint, purpose: "assistant"),
            executor: { [executor] name, arguments, done in executor(name, arguments, turn, done) })
        self.loop = loop
        loop.start { [weak self] result in
            guard let self, self.loopID == id else { return }
            self.loop = nil
            self.finishTurn(result, kind: turn?.kind, started: started)
        }
        return true
    }

    private func cancelTurn() {
        loopID += 1
        loop?.cancel()
        loop = nil
    }

    private func finishTurn(_ result: Result<AssistantToolLoop.Outcome, AssistantToolLoop.Failure>,
                            kind: AssistantTurnKind?, started: Date) {
        let latency = Date().timeIntervalSince(started)
        switch result {
        case .success(let outcome):
            if history.append(outcome.turnMessages) {
                // 裁掉了带完整上下文的早期消息：下一句重发侧栏上下文。
                generation += 1
                AssistantDiag.log("api assistant history trimmed to \(history.turnCount) turns")
            }
            save()
            AssistantDiag.log(String(format: "api turn %@ %.2fs requests=%d tools=%d rejected=%d in=%d out=%d finish=%@",
                                     kind?.rawValue ?? "-", latency, outcome.requests, outcome.toolCalls, outcome.rejected,
                                     outcome.promptTokens, outcome.completionTokens, outcome.finishReason ?? "-"))
            requests.complete(.success(AssistantReply(text: outcome.text, inputTokens: outcome.promptTokens,
                                                      outputTokens: outcome.completionTokens, latency: latency)))
        case .failure(let failure):
            AssistantDiag.log(String(format: "api turn %@ failed after %.2fs: %@", kind?.rawValue ?? "-", latency,
                                     Self.describe(failure)))
            switch failure {
            case .timeout: requests.complete(.failure(.timeout))
            case .api(let error): requests.complete(.failure(.failed("api:" + error.short)))
            case .tooManyIterations: requests.complete(.failure(.failed("too many tool calls")))
            case .cancelled: requests.complete(.failure(.aborted("cancelled")))
            }
        }
    }

    static func describe(_ failure: AssistantToolLoop.Failure) -> String {
        switch failure {
        case .timeout: return "timeout"
        case .api(let error): return error.short
        case .tooManyIterations: return "too many tool calls"
        case .cancelled: return "cancelled"
        }
    }

    private func save() {
        let snapshot = history
        let store = self.store
        Self.ioQueue.async {
            do { try store.save(snapshot) } catch {
                AssistantDiag.log("api assistant history save failed: \(error.localizedDescription)")
            }
        }
    }
}

/// 发 HTTP 请求（URLSession，临时会话：不存 cookie / 缓存），回调在主线程。
final class ChatHTTPClient: @unchecked Sendable {
    /// 共用一个（URLSession 线程安全；每次新建会话会一直占着资源）。
    static let shared = ChatHTTPClient()
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration)
    }

    /// 发一个请求；返回取消函数。
    @discardableResult
    func send(_ request: URLRequest, completion: @escaping (Result<(status: Int, data: Data), ChatAPIError>) -> Void)
        -> () -> Void {
        let task = session.dataTask(with: request) { data, response, error in
            let result: Result<(status: Int, data: Data), ChatAPIError>
            if let error {
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorTimedOut {
                    result = .failure(.timeout)
                } else if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled {
                    result = .failure(.cancelled)
                } else {
                    // 只记域与错误码（userInfo 里有完整地址）。
                    result = .failure(.network("\(ns.domain) \(ns.code)"))
                }
            } else {
                result = .success(((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()))
            }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
        return { task.cancel() }
    }

    /// 给 `AssistantToolLoop` 用的 /chat/completions 传输；每次请求记一行诊断（不含内容）。
    func transport(endpoint: APIEndpoint, purpose: String) -> AssistantToolLoop.Transport {
        { [self] body, timeout, completion in
            let request = ChatAPI.request(url: ChatAPI.completionsURL(endpoint.base), body: body, apiKey: endpoint.apiKey,
                                          timeout: timeout)
            let started = Date()
            let host = endpoint.base.host ?? "?"
            return send(request) { result in
                let parsed = result.flatMap { ChatAPI.parse(status: $0.status, data: $0.data) }
                let latency = Date().timeIntervalSince(started)
                switch (result, parsed) {
                case (.success(let response), .success(let completion)):
                    AssistantDiag.log(String(format: "api %@ http %d %.2fs host=%@ prompt=%d completion=%d tools=%d finish=%@",
                                             purpose, response.status, latency, host, completion.promptTokens,
                                             completion.completionTokens, completion.toolCalls.count,
                                             completion.finishReason ?? "-"))
                case (_, .failure(let error)):
                    AssistantDiag.log(String(format: "api %@ failed %.2fs host=%@: %@", purpose, latency, host, error.short))
                default: break
                }
                completion(parsed)
            }
        }
    }
}

// MARK: - 设置页：模型列表与测试连接

extension ChatHTTPClient {
    /// `GET <base>/models`；回调在主线程。
    func fetchModels(base: URL, apiKey: String?, completion: @escaping (Result<[String], ChatAPIError>) -> Void) {
        let request = ChatAPI.request(url: ChatAPI.modelsURL(base), method: "GET", body: nil, apiKey: apiKey, timeout: 15)
        send(request) { result in
            let parsed = result.flatMap { ChatAPI.parseModels(status: $0.status, data: $0.data) }
            AssistantDiag.log("api models host=\(base.host ?? "?") -> " +
                              ((try? parsed.get()).map { "\($0.count) models" } ?? "failed"))
            completion(parsed)
        }
    }

    /// 「测试连接」：一次只给 ping 工具的请求，看能不能连上、会不会调用工具；回调在主线程（附耗时）。
    func probe(base: URL, apiKey: String?, model: String,
               completion: @escaping (AssistantAPIProbe.Result, TimeInterval) -> Void) {
        let request = ChatAPI.request(url: ChatAPI.completionsURL(base), body: AssistantAPIProbe.body(model: model),
                                      apiKey: apiKey, timeout: 60)
        let started = Date()
        send(request) { result in
            let latency = Date().timeIntervalSince(started)
            let outcome = AssistantAPIProbe.evaluate(result.flatMap { ChatAPI.parse(status: $0.status, data: $0.data) })
            let summary: String
            switch outcome {
            case .ok(let toolCalling, _): summary = toolCalling ? "ok, tool call" : "ok, no tool call"
            case .failed(let error): summary = error.short
            }
            AssistantDiag.log(String(format: "api probe host=%@ %.2fs -> %@", base.host ?? "?", latency, summary))
            completion(outcome, latency)
        }
    }
}
