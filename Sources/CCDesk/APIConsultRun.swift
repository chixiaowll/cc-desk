import Foundation
import CCDeskCore

/// 接口版顾问（设计 §22）：一次性的 OpenAI 兼容对话，只有项目目录内的只读工具（`ConsultSandbox`：list_dir / read_file /
/// search / git_status / git_diff / git_log）。与 `ConsultProcess` 同样的任务记录、进度、超时（5 分钟，真正的计时器：
/// 请求或工具卡住也按时以超时结束）与取消；
/// 回调在主线程，completion 恰好一次。文件读取与 grep / git 在后台队列执行。
final class APIConsultRun: ConsultRunning {
    static let maxIterations = 20
    /// grep / git 单次最长。
    static let commandTimeout: TimeInterval = 15

    private let loop: AssistantToolLoop
    private let completion: (ConsultEnding) -> Void
    private var done = false
    private let started = Date()

    init(endpoint: APIEndpoint, sandbox: ConsultSandbox, question: String, profile: AgentProfile?, language: String,
         http: ChatHTTPClient = .consult, timeout: TimeInterval = ConsultCommand.timeout,
         onProgress: @escaping (Int) -> Void, completion: @escaping (ConsultEnding) -> Void) {
        self.completion = completion
        var calls = 0
        let system = APIConsultPrompt.system(language: language, profile: profile, project: sandbox.root)
        loop = AssistantToolLoop(
            model: endpoint.model, prefix: [.system(system)],
            user: .user(ConsultPrompt.question(question, project: sandbox.root)),
            tools: APIConsultTools.all, maxIterations: Self.maxIterations, timeout: timeout,
            gate: APIConsultTools.check,
            transport: http.transport(endpoint: endpoint, purpose: "consult"),
            executor: { name, arguments, done in
                DispatchQueue.global(qos: .userInitiated).async {
                    let outcome = Self.execute(name, ToolArgs(arguments), sandbox: sandbox)
                    DispatchQueue.main.async { done(outcome) }
                }
            },
            onToolCall: { _ in
                calls += 1
                onProgress(calls)
            })
    }

    func start() {
        loop.start { [weak self] result in
            guard let self, !self.done else { return }
            self.done = true
            switch result {
            case .success(let outcome):
                let answer = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !answer.isEmpty else { return self.completion(.failed("the advisor returned an empty answer")) }
                self.completion(.finished(ConsultOutcome(
                    answer: answer, inputTokens: outcome.promptTokens, outputTokens: outcome.completionTokens,
                    durationMS: Int(Date().timeIntervalSince(self.started) * 1000), turns: outcome.requests,
                    denials: outcome.rejected)))
            case .failure(.timeout): self.completion(.timedOut)
            case .failure(.cancelled): self.completion(.cancelled)
            case .failure(.api(let error)): self.completion(.failed("API error: \(error.short)"))
            case .failure(.tooManyIterations): self.completion(.failed("the advisor used too many tool calls"))
            }
        }
    }

    func cancel() {
        guard !done else { return }
        done = true
        loop.cancel()
        let completion = self.completion
        DispatchQueue.main.async { completion(.cancelled) }
    }

    func terminateNow() {
        done = true
        loop.cancel()
    }

    // MARK: 工具（后台线程）

    static func execute(_ name: String, _ args: ToolArgs, sandbox: ConsultSandbox) -> MCPServerCore.ToolOutcome {
        func outcome(_ result: Result<String, ConsultSandbox.Failure>) -> MCPServerCore.ToolOutcome {
            switch result {
            case .success(let text): return MCPServerCore.ToolOutcome(text: text)
            case .failure(let failure): return MCPServerCore.ToolOutcome(text: failure.message, isError: true)
            }
        }
        switch name {
        case "list_dir":
            return outcome(sandbox.listDir(args.string("path")))
        case "read_file":
            return outcome(sandbox.readFile(args.string("path"), startLine: args.int("start_line"),
                                            maxLines: args.int("max_lines")))
        case "search":
            return outcome(sandbox.searchArguments(pattern: args.text("pattern"), regex: args.bool("regex") ?? false,
                                                   ignoreCase: args.bool("ignore_case") ?? false, path: args.string("path"))
                .flatMap { run("/usr/bin/grep", $0, cwd: sandbox.root, search: true) })
        case "git_status", "git_diff", "git_log":
            guard let tool = ConsultSandbox.GitTool(rawValue: name) else { break }
            return outcome(sandbox.gitArguments(tool, staged: args.bool("staged") ?? false, ref: args.string("ref"),
                                                path: args.string("path"), count: args.int("count"))
                .flatMap { run("/usr/bin/git", $0, cwd: sandbox.root, search: false) })
        default: break
        }
        return MCPServerCore.ToolOutcome(text: "unknown tool \(name)", isError: true)
    }

    /// 运行 grep / git：环境去掉会话级变量，git 用安全设置（不执行仓库配置里的外部程序）。
    private static func run(_ exe: String, _ args: [String], cwd: String, search: Bool) -> Result<String, ConsultSandbox.Failure> {
        let env = GitSafety.environment(LaunchSpec.sanitizedEnvironment(base: ProcessInfo.processInfo.environment))
        switch ProcessRunner.capture(exe, args, environment: env, cwd: URL(fileURLWithPath: cwd), timeout: commandTimeout) {
        case .failed(let message): return .failure(.invalid("could not run: \(message)"))
        case .timedOut: return .failure(.invalid("timed out after \(Int(commandTimeout)) seconds"))
        case .exited(let out):
            if search {
                // grep：0 = 有结果，1 = 没有，其他 = 出错。
                guard out.status <= 1 else { return .failure(.invalid(String(out.stderr.prefix(300)))) }
                return .success(ConsultSandbox.searchOutput(out.stdout, status: out.status))
            }
            guard out.status == 0 else { return .failure(.invalid(String(out.stderr.prefix(300)))) }
            return .success(out.stdout.isEmpty ? "(no output)" : ConsultSandbox.clip(out.stdout))
        }
    }
}
