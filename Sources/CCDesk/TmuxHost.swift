import Foundation
import CCDeskCore

/// CC Desk 专用 tmux 服务器的执行层（设计 §4.9）：解析 tmux、写配置、同步执行短命令（每次几毫秒）。
/// 每个内嵌终端一个 `ccdesk-<终端 id>` 会话；SwiftTerm 里运行的只是 `tmux attach` 客户端，
/// App 退出 / 崩溃时客户端断开，会话与其中的 agent 继续运行，下次启动时重新附着。
final class TmuxHost: @unchecked Sendable {
    let executable: String
    let version: TmuxVersion
    let command: TmuxCommand
    /// tmux 客户端（attach / 短命令）的环境；第一次启动服务器的客户端的环境会成为服务器的全局环境，
    /// 所以这里已去掉会话级 Claude / Codex 变量与宿主终端身份变量，且不含 CC_DESK_TERMINAL_ID。
    let clientEnvironment: [String]

    /// 诊断日志（写入 ~/.cc-desk/assistant-diag.txt）；自检时改为打印到 stdout，不碰用户的状态目录。
    nonisolated(unsafe) static var log: (String) -> Void = { AssistantDiag.log($0) }

    init(executable: String, version: TmuxVersion, command: TmuxCommand, clientEnvironment: [String]) {
        self.executable = executable
        self.version = version
        self.command = command
        self.clientEnvironment = clientEnvironment
    }

    /// App 使用的实例；nil 表示没有可用的 tmux（回退为直连 PTY，没有会话保持）。第一次访问时解析（主线程）。
    static let shared: TmuxHost? = {
        let env = ProcessInfo.processInfo.environment
        let configPath = (SessionBuilder.internalDirectory as NSString).appendingPathComponent("tmux.conf")
        let host = resolve(environment: env, socket: TmuxNaming.socket(environment: env), configPath: configPath,
                           bundledPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tmux").path)
        TmuxHost.log(host.map { "tmux: \($0.executable) \($0.version) socket=\($0.command.socket)" }
                          ?? "tmux: unavailable, embedded terminals use a direct PTY")
        return host
    }()

    /// 按优先级找到第一个可运行、版本足够新的 tmux，并写入 CC Desk 的配置；都不行时返回 nil。
    static func resolve(environment: [String: String], socket: String, configPath: String,
                        bundledPath: String?) -> TmuxHost? {
        let shell = EmbeddedTerminal.userShell()
        let clientEnv = LaunchSpec.environment(base: environment, shell: shell, terminalID: nil)
        var candidates = TmuxBinary.candidates(environment: environment, bundledPath: bundledPath)
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
        if candidates.isEmpty, let found = TmuxBinary.parseProbe(
            SystemProbe.run(shell, ["-l", "-i", "-c", TmuxBinary.probeScript], timeout: 3) ?? "") {
            candidates = [found]
        }
        for path in candidates {
            guard let output = SystemProbe.run(path, ["-V"], timeout: 2), let version = TmuxVersion.parse(output),
                  version >= TmuxVersion.minimumSupported else { continue }
            do {
                try FileManager.default.createDirectory(atPath: (configPath as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true)
                try TmuxConfig.text().write(toFile: configPath, atomically: true, encoding: .utf8)
            } catch {
                TmuxHost.log("tmux: cannot write \(configPath): \(error)")
                return nil
            }
            return TmuxHost(executable: path, version: version,
                            command: TmuxCommand(socket: socket, configPath: configPath), clientEnvironment: clientEnv)
        }
        return nil
    }

    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { status == 0 }
    }

    /// 同步执行 tmux 子命令；超时或无法启动时返回 nil。
    func run(_ args: [String], timeout: TimeInterval = 3) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = Dictionary(clientEnvironment.compactMap { pair -> (String, String)? in
            guard let eq = pair.firstIndex(of: "=") else { return nil }
            return (String(pair[..<eq]), String(pair[pair.index(after: eq)...]))
        }, uniquingKeysWith: { a, _ in a })
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        // 后台读完两个管道（capture-pane 的输出可能超过管道缓冲区），再等进程退出。
        let buffers = PipeBuffers()
        let reads = DispatchGroup()
        for (index, pipe) in [out, err].enumerated() {
            reads.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                buffers.set(index, pipe.fileHandleForReading.readDataToEndOfFile())
                reads.leave()
            }
        }
        let deadline = DispatchTime.now() + timeout
        if reads.wait(timeout: deadline) == .timedOut || exited.wait(timeout: deadline) == .timedOut {
            process.terminate()
            TmuxHost.log("tmux: timed out: \(args.dropFirst(command.base.count).joined(separator: " "))")
            return nil
        }
        let stdout = String(data: buffers.get(0), encoding: .utf8) ?? ""
        let stderr = String(data: buffers.get(1), encoding: .utf8) ?? ""
        return Output(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// 服务器里全部窗格；服务器没在运行时为空数组，其他错误（如版本不兼容）为 nil。
    func livePanes() -> [TmuxPane]? {
        guard let output = run(command.listPanes()) else { return nil }
        if output.ok { return TmuxListing.parsePanes(output.stdout) }
        if TmuxListing.isNoServer(output.stderr) { return [] }
        TmuxHost.log("tmux: list-panes failed: \(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        return nil
    }

    /// 服务器已在运行（上一版 App 启动的）时重新加载配置，让配置改动立即生效。
    func reloadConfig() {
        if let output = run(command.sourceConfig()), !output.ok {
            TmuxHost.log("tmux: source-file failed: \(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// 在后台新建会话并返回窗格；会话已存在（同一终端 id）时返回已有窗格。失败返回 nil（调用方回退直连 PTY）。
    func createSession(terminalID: UUID, cwd: String, cols: Int, rows: Int, shell: String, command shellCommand: String?) -> TmuxPane? {
        let args = command.newSession(
            terminalID: terminalID, cwd: cwd, cols: cols, rows: rows,
            environment: ["CC_DESK": "1", "CC_DESK_TERMINAL_ID": terminalID.uuidString],
            command: TmuxCommand.paneCommand(shell: shell, command: shellCommand))
        if let output = run(args), output.ok, let pane = TmuxListing.parsePanes(output.stdout).first {
            return pane
        }
        if let existing = pane(terminalID: terminalID) { return existing }
        TmuxHost.log("tmux: cannot create session for \(terminalID.uuidString)")
        return nil
    }

    func pane(terminalID: UUID) -> TmuxPane? {
        guard let output = run(command.pane(terminalID: terminalID)), output.ok else { return nil }
        return TmuxListing.parsePanes(output.stdout).first
    }

    func hasSession(terminalID: UUID) -> Bool {
        run(command.hasSession(terminalID: terminalID))?.ok ?? false
    }

    func killSession(name: String) {
        _ = run(command.killSession(name: name))
    }

    func killSession(terminalID: UUID) {
        killSession(name: TmuxNaming.sessionName(for: terminalID))
    }

    /// 窗格底部 `lines` 行（含历史）。
    func capture(terminalID: UUID, lines: Int) -> String? {
        guard let output = run(command.capture(terminalID: terminalID, lines: lines)), output.ok else { return nil }
        return output.stdout
    }

    func cancelCopyMode(terminalID: UUID) {
        _ = run(command.cancelCopyMode(terminalID: terminalID))
    }

    /// 窗格是否在复制模式（滚轮翻看历史中）。
    func isInCopyMode(terminalID: UUID) -> Bool {
        return run(command.paneInMode(terminalID: terminalID))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }
}

/// 两个管道读取线程的结果。
private final class PipeBuffers: @unchecked Sendable {
    private var data = [Data(), Data()]
    private let lock = NSLock()

    func set(_ index: Int, _ value: Data) {
        lock.lock()
        defer { lock.unlock() }
        data[index] = value
    }

    func get(_ index: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data[index]
    }
}
