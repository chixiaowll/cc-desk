import Foundation
import CCDeskCore

/// 一次模型调用的结果。
struct AssistantReply {
    let text: String
    let inputTokens: Int
    let outputTokens: Int
    let latency: TimeInterval
}

enum AssistantError: Error, Equatable {
    /// 找不到 claude 可执行文件。
    case notInstalled
    case timeout
    case failed(String)
}

/// 语音助手的模型客户端（设计 §12）：`claude -p --model haiku` 无会话记录、无工具、无 MCP，工作目录 `~/.cc-desk/assistant`。
///
/// - `claude` 的路径用登录交互 shell 解析一次并缓存（GUI App 的 PATH 不含用户目录），之后直接 exec，省掉每次约 1.5 秒的 shell 启动。
/// - 去掉会话级 Claude Code 变量（同 LaunchSpec），避免它以为自己嵌套在另一个 Claude Code 里。
/// - 关闭扩展思考（`MAX_THINKING_TOKENS=0`）以降低延迟。
/// - 调用在后台队列进行，结果回到主线程；20 秒超时。
final class AssistantClient: @unchecked Sendable {
    static let shared = AssistantClient()
    static let timeout: TimeInterval = 20
    static let model = "haiku"

    static var workingDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cc-desk/assistant", isDirectory: true)
    }

    private struct Executable {
        let path: String
        /// 登录 shell 的 PATH（claude 可能再调用 node / git 等）。
        let searchPath: String?
    }

    private let queue = DispatchQueue(label: "cc-desk.assistant", qos: .userInitiated, attributes: .concurrent)
    private let resolveQueue = DispatchQueue(label: "cc-desk.assistant.resolve")
    private let lock = NSLock()
    private var executable: Executable?
    private var resolveFailedAt: Date?

    /// 已解析到 claude（nil = 尚未解析）。
    var isAvailable: Bool? {
        lock.lock(); defer { lock.unlock() }
        if executable != nil { return true }
        return resolveFailedAt != nil ? false : nil
    }

    /// 在后台预先解析 claude 路径（打开对话模式时调用）。
    func prepare(completion: ((Bool) -> Void)? = nil) {
        resolveQueue.async { [self] in
            let ok = resolve() != nil
            if let completion { DispatchQueue.main.async { completion(ok) } }
        }
    }

    /// 调用模型；completion 在主线程执行。
    func complete(system: String, message: String, timeout: TimeInterval = AssistantClient.timeout,
                  completion: @escaping (Result<AssistantReply, AssistantError>) -> Void) {
        queue.async { [self] in
            let result = run(system: system, message: message, timeout: timeout)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 同步调用（只在后台线程使用；调试工具也用它）。
    func run(system: String, message: String, timeout: TimeInterval = AssistantClient.timeout) -> Result<AssistantReply, AssistantError> {
        let started = Date()
        guard let exe = resolveQueue.sync(execute: { resolve() }) else { return .failure(.notInstalled) }
        let dir = Self.workingDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var env = LaunchSpec.sanitizedEnvironment(base: ProcessInfo.processInfo.environment)
        if let path = exe.searchPath { env["PATH"] = path }
        env["CC_DESK"] = "1"
        // 关掉扩展思考：haiku 默认会先想几百上千个 token，延迟从 1–2 秒涨到 6–14 秒，而这里的任务很简单。
        env["MAX_THINKING_TOKENS"] = "0"
        let args = ["-p", "--model", Self.model, "--no-session-persistence", "--tools", "", "--strict-mcp-config",
                    "--output-format", "json", "--system-prompt", system, message]
        let remaining = max(1, timeout - Date().timeIntervalSince(started))
        switch ProcessRunner.run(exe.path, args, environment: env, cwd: dir, timeout: remaining) {
        case .timedOut:
            return .failure(.timeout)
        case .failed(let message):
            return .failure(.failed(message))
        case .finished(let stdout):
            guard let envelope = AssistantEnvelope.parse(stdout) else {
                return .failure(.failed(String(stdout.prefix(200))))
            }
            return .success(AssistantReply(text: envelope.result, inputTokens: envelope.inputTokens,
                                           outputTokens: envelope.outputTokens,
                                           latency: Date().timeIntervalSince(started)))
        }
    }

    /// 只在 resolveQueue 上调用。成功结果永久缓存；失败 60 秒内不重试。
    private func resolve() -> Executable? {
        lock.lock()
        if let executable { lock.unlock(); return executable }
        if let at = resolveFailedAt, Date().timeIntervalSince(at) < 60 { lock.unlock(); return nil }
        lock.unlock()
        let found = Self.locate()
        lock.lock()
        executable = found
        resolveFailedAt = found == nil ? Date() : nil
        lock.unlock()
        return found
    }

    /// 在登录交互 shell 里 `command -v claude` 并取 PATH；输出里可能混有 rc 文件打印的内容，用标记行定位。
    private static func locate() -> Executable? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let script = "printf '__CCDESK_CLAUDE__%s\\n' \"$(command -v claude)\"; printf '__CCDESK_PATH__%s\\n' \"$PATH\""
        var path: String?
        var searchPath: String?
        if case .finished(let out) = ProcessRunner.run(shell, ["-l", "-i", "-c", script], environment: nil, cwd: nil,
                                                       timeout: 6) {
            for line in out.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("__CCDESK_CLAUDE__") { path = String(line.dropFirst("__CCDESK_CLAUDE__".count)) }
                if line.hasPrefix("__CCDESK_PATH__") { searchPath = String(line.dropFirst("__CCDESK_PATH__".count)) }
            }
        }
        // `command -v` 对 alias / 函数不返回路径；退到常见安装位置。
        let home = NSHomeDirectory()
        let candidates = [path ?? ""] + ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                                         "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        guard let exe = candidates.first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
        return Executable(path: exe, searchPath: searchPath.flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// 带超时、环境变量与工作目录的子进程执行；stdin 为空设备（claude -p 在非终端 stdin 上会等待输入）。
enum ProcessRunner {
    enum Outcome {
        case finished(String)
        case failed(String)
        case timedOut
    }

    static func run(_ executable: String, _ args: [String], environment: [String: String]?, cwd: URL?,
                    timeout: TimeInterval) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let environment { process.environment = environment }
        if let cwd { process.currentDirectoryURL = cwd }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return .failed(error.localizedDescription) }

        let group = DispatchGroup()
        var stdout = Data()
        var stderr = Data()
        group.enter()
        DispatchQueue.global().async {
            stdout = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            stderr = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            _ = group.wait(timeout: .now() + 3)
            return .timedOut
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr, encoding: .utf8) ?? ""
            return .failed("exit \(process.terminationStatus): \(message.prefix(200))")
        }
        return .finished(String(data: stdout, encoding: .utf8) ?? "")
    }
}
