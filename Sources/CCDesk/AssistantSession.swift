import Foundation
import CCDeskCore

/// 常驻的助手会话（设计 §12）：一个长期运行的 `claude -p --input-format stream-json` 进程，
/// 会话 id 存在 ~/.cc-desk/assistant/session.json，下次启动用 `--resume` 接回，助手因此记得之前的对话。
///
/// - 请求串行：一次只有一条消息在等回复，其余排队。
/// - 进程退出 / 超时：当前请求失败，下一条请求时重新启动（接回同一会话）；接回失败则换新会话。
/// - 上下文（最后一次模型调用的输入）超过 `rotateInputTokens` 时，在这条回复之后换新会话。
/// - 朗读的回复取最后一次工具调用之后的文字（AssistantTurnText）。
/// - `generation` 每启动一次新进程加一，调用方据此判断要不要重发完整的侧栏上下文。
/// - 存下的会话带系统提示词版本；版本不同（提示词改了）就换新会话。
final class AssistantSession: @unchecked Sendable {
    static let rotateInputTokens = 60_000

    struct Stored: Codable {
        var id: String
        var createdAt: Date
        /// 创建时的系统提示词版本（旧版本没有这个字段）。
        var promptVersion: Int?
    }

    private let queue = DispatchQueue(label: "cc-desk.assistant.session")
    private let executable: () -> (path: String, searchPath: String?)?
    private let system: String
    private let promptVersion: Int
    private let toolArguments: () -> [String]
    private let model: String
    private let directory: URL
    private var storeURL: URL { directory.appendingPathComponent("session.json") }

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var buffer = Data()
    /// 请求队列（恰好一次的 completion、超时、退出 / 重置后继续往下走）；只在 queue 上使用。
    private lazy var requests = AssistantRequestQueue<AssistantReply>(driver: AssistantRequestQueue.Driver(
        ensureRunning: { [unowned self] in process != nil || start() },
        send: { [unowned self] message in write(message) },
        stopProcess: { [unowned self] in stopProcess() },
        schedule: { [unowned self] seconds, work in queue.asyncAfter(deadline: .now() + seconds, execute: work) }))
    /// 当前请求里模型最后说的话（最后一次工具调用之后）。
    private var turnText = AssistantTurnText()
    private var resumedID: String?
    private var answeredSinceStart = false
    private var _generation = 0

    init(directory: URL, model: String, system: String, promptVersion: Int, toolArguments: @escaping () -> [String],
         executable: @escaping () -> (path: String, searchPath: String?)?) {
        self.directory = directory
        self.model = model
        self.system = system
        self.promptVersion = promptVersion
        self.toolArguments = toolArguments
        self.executable = executable
    }

    /// 每启动一个新进程加一（接回 / 新会话都算）。
    var generation: Int { queue.sync { _generation } }

    /// 发一条用户消息；completion 在主线程，恰好调用一次。turn：这条消息的种类（决定这一轮能调用哪些工具）。
    func ask(_ message: String, turn: AssistantTurn, timeout: TimeInterval,
             completion: @escaping (Result<AssistantReply, AssistantError>) -> Void) {
        queue.async { [self] in
            requests.enqueue(Self.userLine(message), turn: turn, timeout: timeout) { result in
                let mapped = result.mapError(Self.map)
                DispatchQueue.main.async { completion(mapped) }
            }
        }
    }

    /// 正在等回复的那条消息的种类（工具调用权限据此判断，见 `AssistantToolPolicy`）；没有时 nil。
    /// 工具调用只会在一条消息等回复期间到达（进程一次只处理一条），所以这就是发起调用的那一轮。
    var currentTurn: AssistantTurn? { queue.sync { requests.currentTurn } }

    /// 预先启动进程（打开对话模式时调用，省掉第一句的启动时间）。
    func warmUp() {
        queue.async { [self] in if process == nil { _ = start() } }
    }

    /// 丢弃当前会话，下一条消息开始新会话（菜单「重置助手对话」/ 上下文过大）。排队的消息继续用新会话处理。
    func reset() {
        queue.async { [self] in
            try? FileManager.default.removeItem(at: storeURL)
            requests.abort("reset")
        }
    }

    func shutdown() {
        queue.sync { requests.shutdown() }
    }

    private static func map(_ failure: AssistantRequestQueue<AssistantReply>.Failure) -> AssistantError {
        switch failure {
        case .notStarted: return .notInstalled
        case .timeout:
            AssistantDiag.log("assistant session timeout")
            return .timeout
        case .writeFailed: return .failed("write")
        case .exited: return .failed("exited")
        case .aborted(let reason): return .failed(reason)
        case .failed(let message): return .failed(message)
        }
    }

    // MARK: 只在 queue 上调用

    private func write(_ line: String) -> Bool {
        turnText = AssistantTurnText()
        // 用会抛错的 write(contentsOf:)：进程已退出时 write(_:) 会抛 ObjC 异常、让整个 App 崩溃。
        do {
            try stdin?.write(contentsOf: Data((line + "\n").utf8))
            return stdin != nil
        } catch {
            AssistantDiag.log("assistant session write failed: \(error.localizedDescription)")
            return false
        }
    }

    private func loadStored() -> Stored? {
        guard let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        guard stored.promptVersion == promptVersion else {
            AssistantDiag.log("assistant session \(stored.id) has prompt version \(stored.promptVersion ?? 1), " +
                              "want \(promptVersion): starting a new session")
            try? FileManager.default.removeItem(at: storeURL)
            return nil
        }
        return stored
    }

    private func start() -> Bool {
        guard let exe = executable() else { return false }
        AssistantClient.prepareWorkingDirectory(directory)
        var args = ["-p", "--model", model, "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
            + toolArguments() + ["--system-prompt", system]
        if let stored = loadStored() {
            args += ["--resume", stored.id]
            resumedID = stored.id
        } else {
            let id = UUID().uuidString.lowercased()
            let stored = Stored(id: id, createdAt: Date(), promptVersion: promptVersion)
            if let data = try? JSONEncoder().encode(stored) { try? data.write(to: storeURL) }
            args += ["--session-id", id]
            resumedID = nil
        }
        var env = LaunchSpec.sanitizedEnvironment(base: ProcessInfo.processInfo.environment)
        if let path = exe.searchPath { env["PATH"] = path }
        env["CC_DESK"] = "1"
        // 控制接口的本次启动口令：claude 把自己的环境传给 MCP 子进程（2.1.280 实测），`--mcp` 据此通过鉴权。
        // 不写进任何文件；内嵌终端的环境里会去掉它（LaunchSpec.sanitizedEnvironment）。
        env[ControlProtocol.tokenEnvironmentKey] = ControlAuth.token
        // 关掉扩展思考：haiku 默认会先想几百上千个 token，延迟明显变长，而这里的任务很简单。
        env["MAX_THINKING_TOKENS"] = "0"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe.path)
        p.arguments = args
        p.environment = env
        p.currentDirectoryURL = directory
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        // 不强引用 p：handler 挂在管道上，强引用会形成 Process ↔ 管道的循环，进程退出后泄漏 fd。
        outPipe.fileHandleForReading.readabilityHandler = { [weak self, weak p] handle in
            let data = handle.availableData
            // EOF：清掉 handler，否则空数据会让它不停被调用。
            if data.isEmpty { handle.readabilityHandler = nil }
            guard let self, let p else { return }
            self.queue.async { self.receive(data, from: p) }
        }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.queue.async { self.exited(proc) }
        }
        do { try p.run() } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            AssistantDiag.log("assistant session start failed: \(error.localizedDescription)")
            return false
        }
        process = p
        stdin = inPipe.fileHandleForWriting
        stdout = outPipe.fileHandleForReading
        buffer = Data()
        answeredSinceStart = false
        _generation += 1
        AssistantDiag.log("assistant session started \(resumedID.map { "resume \($0)" } ?? "new \(loadStored()?.id ?? "?")")")
        return true
    }

    private func receive(_ data: Data, from p: Process) {
        guard p === process else { return }
        if data.isEmpty { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            if line.contains("\"type\":\"assistant\""), let message = JSONValue.parse(line) { turnText.consume(message) }
            if line.contains("\"result\"") { handleResult(line) }
        }
    }

    private func handleResult(_ line: String) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              obj["type"] as? String == "result", let started = requests.currentStartedAt else { return }
        guard let envelope = AssistantEnvelope.parse(line) else {
            return requests.complete(.failure(.failed(String(line.prefix(200)))))
        }
        answeredSinceStart = true
        let rotate = envelope.contextTokens > Self.rotateInputTokens
        if rotate {
            AssistantDiag.log("assistant session rotating (context too large)")
            try? FileManager.default.removeItem(at: storeURL)
        }
        requests.complete(.success(AssistantReply(text: turnText.spoken(result: envelope.result),
                                                  inputTokens: envelope.inputTokens,
                                                  outputTokens: envelope.outputTokens,
                                                  latency: Date().timeIntervalSince(started))),
                          restart: rotate)
    }

    private func exited(_ p: Process) {
        guard p === process else { return }
        AssistantDiag.log("assistant session exited status=\(p.terminationStatus)")
        // 接回旧会话还没答过一句就退出：多半是会话已不存在，换新会话。
        if resumedID != nil, !answeredSinceStart { try? FileManager.default.removeItem(at: storeURL) }
        releaseProcess()
        requests.processExited()
    }

    /// 停掉当前进程（之后它的退出不再报告给队列）。
    private func stopProcess() {
        guard let p = process else { return }
        releaseProcess()
        if p.isRunning { p.terminate() }
    }

    /// 清掉 handler、关闭父进程这边的管道端，忘掉进程。
    private func releaseProcess() {
        process?.terminationHandler = nil
        process = nil
        try? stdin?.close()
        stdin = nil
        stdout?.readabilityHandler = nil
        try? stdout?.close()
        stdout = nil
        buffer = Data()
    }

    static func userLine(_ text: String) -> String {
        let obj: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: data, encoding: .utf8) else { return "" }
        return line
    }
}
