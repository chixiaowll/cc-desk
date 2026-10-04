import Foundation
import CCDeskCore

/// 控制接口的本次启动口令（设计 §13）：只在内存里，经环境变量交给助手会话；每次启动不同。
enum ControlAuth {
    static let token = ControlToken.generate()
}

/// 语音助手的模型客户端（设计 §12/§13/§22）：解析 `claude` 路径，持有各个后端，按设置选出当前用哪个
/// （选择逻辑见 AssistantBackends.swift）。
///
/// - `claude` 的路径用登录交互 shell 解析一次并缓存（GUI App 的 PATH 不含用户目录），之后直接 exec，省掉每次约 1.5 秒的 shell 启动。
/// - 常驻会话只能用 CC Desk 的 MCP 工具（`--mcp-config` 指向本程序的 `--mcp` 模式），内置工具全部关闭。
/// - OpenAI 兼容接口后端在进程内执行同一套工具（`toolExecutor`，由 AppModel 接到 AssistantToolbox）。
final class AssistantClient: @unchecked Sendable {
    static let shared = AssistantClient()
    /// 摘要等不调用工具的请求。
    static let timeout: TimeInterval = 20
    /// 一句话的完整处理（可能多次调用工具、等待语音确认）。
    static let turnTimeout: TimeInterval = 60
    static let model = "haiku"

    static var workingDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cc-desk/assistant", isDirectory: true)
    }

    private struct Executable {
        let path: String
        /// 登录 shell 的 PATH（claude 可能再调用 node / git 等）。
        let searchPath: String?
    }

    private let resolveQueue = DispatchQueue(label: "cc-desk.assistant.resolve")
    private let lock = NSLock()
    private var executable: Executable?
    private var resolveFailedAt: Date?

    /// 接口后端执行工具（AppModel 启动时接到 AssistantToolbox.call；只在主线程调用）。
    var toolExecutor: AssistantToolExecutor?
    /// 接口密钥（钥匙串，内存缓存；只在主线程读写）。
    let apiKeys = AssistantAPIKeys(store: KeychainSecretStore.assistant)
    /// 选出的后端与退役中的后端（只在主线程读写）：换了后端时等不再用的那个空闲了再停掉。
    var backendSwitch = AssistantBackendSwitch()
    /// 已经安排了一次退役检查（只在主线程读写）。
    var retireCheckScheduled = false
    let localBackend = LocalAssistantBackend()
    /// claude 还在解析时先攒着请求（只在主线程使用）。
    lazy var pendingBackend = PendingAssistantBackend(
        prepare: { [weak self] done in self?.prepare { _ in done() } },
        decide: { [weak self] in self?.decidedBackend() ?? LocalAssistantBackend() })

    /// OpenAI 兼容接口后端（历史存在 api-history.json）。只在主线程使用。
    lazy var apiBackend = APIAssistantBackend(
        store: AssistantChatHistoryStore(url: Self.workingDirectory.appendingPathComponent("api-history.json")),
        endpoint: { [weak self] in self?.apiEndpoint() },
        executor: { [weak self] name, arguments, turn, done in
            guard let executor = self?.toolExecutor else {
                return done(MCPServerCore.ToolOutcome(text: "CC Desk is not ready", isError: true))
            }
            executor(name, arguments, turn, done)
        })

    /// Claude 会话正在等回复的那条消息的种类（MCP 来的工具调用按它判断权限）。
    var claudeTurn: AssistantTurn? { session.currentTurn }

    /// 常驻助手会话（工具调用 / 摘要共用，有上下文）。
    lazy var session = AssistantSession(directory: Self.workingDirectory, model: Self.model,
                                        system: AssistantPrompt.residentSystem, promptVersion: AssistantPrompt.residentVersion,
                                        toolArguments: Self.toolArguments) { [weak self] in
        guard let self else { return nil }
        return self.resolveQueue.sync { self.resolve() }.map { ($0.path, $0.searchPath) }
    }

    /// 解析到的 claude 路径（后台线程调用；首次会走登录 shell 解析）。
    func resolvedClaude() -> (path: String, searchPath: String?)? {
        resolveQueue.sync { resolve() }.map { ($0.path, $0.searchPath) }
    }

    /// 写 `mcp.json`（`ccdesk` 服务器 = 本程序 `--mcp`）并返回工具相关参数。
    /// 实测（claude 2.1.280）：`--tools ""` 关闭全部内置工具；`--allowedTools "mcp__ccdesk__*"` 让 -p 模式下的
    /// MCP 工具调用不需要权限（不加时调用被拒绝，permission_denials 里能看到）。
    static func toolArguments() -> [String] {
        let base = ["--strict-mcp-config", "--tools", ""]
        guard let exe = Bundle.main.executableURL?.path else { return base }
        let url = workingDirectory.appendingPathComponent("mcp.json")
        // 不含控制接口口令（口令经 claude 进程的环境传给 MCP 子进程）；目录 0700、文件 0600。
        let json = MCPServerCore.configJSON(executable: exe, socketPath: ControlProtocol.socketPath())
        do {
            prepareWorkingDirectory(workingDirectory)
            try json.write(to: url, atomically: true, encoding: .utf8)
            chmod(url.path, 0o600)
        } catch {
            AssistantDiag.log("assistant mcp config write failed: \(error.localizedDescription)")
            return base
        }
        return ["--mcp-config", url.path] + base + ["--allowedTools", "mcp__\(AssistantTools.mcpServerName)__*"]
    }

    /// 建好助手的工作目录并收紧为 0700（里面有 mcp.json、session.json）。
    static func prepareWorkingDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        chmod(url.path, 0o700)
    }

    /// 已解析过的 claude 路径；还没解析时 nil（不阻塞，不走登录 shell）。
    func resolvedClaudeIfKnown() -> (path: String, searchPath: String?)? {
        lock.lock(); defer { lock.unlock() }
        return executable.map { ($0.path, $0.searchPath) }
    }

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

    /// 进程跑完的结果（任意退出码）。truncated：输出超过了上限，进程被提前终止，stdout / stderr 只是开头。
    struct Captured {
        let status: Int32
        let stdout: String
        let stderr: String
        var truncated = false
    }

    enum Capture {
        case exited(Captured)
        case failed(String)
        case timedOut
    }

    static func run(_ executable: String, _ args: [String], environment: [String: String]?, cwd: URL?,
                    timeout: TimeInterval) -> Outcome {
        switch capture(executable, args, environment: environment, cwd: cwd, timeout: timeout) {
        case .failed(let message): return .failed(message)
        case .timedOut: return .timedOut
        case .exited(let out):
            guard out.status == 0 else { return .failed("exit \(out.status): \(out.stderr.prefix(200))") }
            return .finished(out.stdout)
        }
    }

    /// maxOutputBytes：stdout / stderr 各自最多保存这么多字节；超出时终止进程（边读边丢，不会整个读进内存）。
    static func capture(_ executable: String, _ args: [String], environment: [String: String]?, cwd: URL?,
                        timeout: TimeInterval, maxOutputBytes: Int = .max) -> Capture {
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

        let stop = {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        let group = DispatchGroup()
        var stdout = CappedOutput(limit: maxOutputBytes)
        var stderr = CappedOutput(limit: maxOutputBytes)
        group.enter()
        DispatchQueue.global().async {
            stdout = drain(out.fileHandleForReading, limit: maxOutputBytes, onExceeded: stop)
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            stderr = drain(err.fileHandleForReading, limit: maxOutputBytes, onExceeded: stop)
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            stop()
            _ = group.wait(timeout: .now() + 3)
            return .timedOut
        }
        process.waitUntilExit()
        return .exited(Captured(status: process.terminationStatus, stdout: String(decoding: stdout.data, as: UTF8.self),
                                stderr: String(decoding: stderr.data, as: UTF8.self),
                                truncated: stdout.exceeded || stderr.exceeded))
    }

    /// 读到 EOF；超过上限后其余的读出来丢掉（进程已被终止，很快就到 EOF）。
    private static func drain(_ handle: FileHandle, limit: Int, onExceeded: () -> Void) -> CappedOutput {
        var buffer = CappedOutput(limit: limit)
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if buffer.append(chunk) { onExceeded() }
        }
        return buffer
    }
}
