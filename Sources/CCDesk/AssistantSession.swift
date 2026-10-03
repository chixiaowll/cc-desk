import Foundation
import CCDeskCore

/// 常驻的助手会话（设计 §12）：一个长期运行的 `claude -p --input-format stream-json` 进程，
/// 会话 id 存在 ~/.cc-desk/assistant/session.json，下次启动用 `--resume` 接回，助手因此记得之前的对话。
///
/// - 请求串行：一次只有一条消息在等回复，其余排队。
/// - 进程退出 / 超时：当前请求失败，下一条请求时重新启动（接回同一会话）；接回失败则换新会话。
/// - 上下文超过 `rotateInputTokens` 时，在这条回复之后换新会话。
/// - `generation` 每启动一次新进程加一，调用方据此判断要不要重发完整的侧栏上下文。
final class AssistantSession: @unchecked Sendable {
    static let rotateInputTokens = 60_000

    struct Stored: Codable {
        var id: String
        var createdAt: Date
    }

    private let queue = DispatchQueue(label: "cc-desk.assistant.session")
    private let executable: () -> (path: String, searchPath: String?)?
    private let system: String
    private let model: String
    private let directory: URL
    private var storeURL: URL { directory.appendingPathComponent("session.json") }

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var pending: [(message: String, timeout: TimeInterval, completion: (Result<AssistantReply, AssistantError>) -> Void)] = []
    private var current: (completion: (Result<AssistantReply, AssistantError>) -> Void, started: Date, token: Int)?
    private var token = 0
    private var resumedID: String?
    private var answeredSinceStart = false
    private var rotateAfterReply = false
    private var _generation = 0

    init(directory: URL, model: String, system: String,
         executable: @escaping () -> (path: String, searchPath: String?)?) {
        self.directory = directory
        self.model = model
        self.system = system
        self.executable = executable
    }

    /// 每启动一个新进程加一（接回 / 新会话都算）。
    var generation: Int { queue.sync { _generation } }

    /// 发一条用户消息；completion 在主线程。
    func ask(_ message: String, timeout: TimeInterval, completion: @escaping (Result<AssistantReply, AssistantError>) -> Void) {
        queue.async { [self] in
            pending.append((message, timeout, { result in DispatchQueue.main.async { completion(result) } }))
            pump()
        }
    }

    /// 预先启动进程（打开对话模式时调用，省掉第一句的启动时间）。
    func warmUp() {
        queue.async { [self] in if process == nil { _ = start() } }
    }

    /// 丢弃当前会话，下一条消息开始新会话（菜单「重置助手对话」/ 上下文过大）。
    func reset() {
        queue.async { [self] in
            try? FileManager.default.removeItem(at: storeURL)
            stop(failing: .failed("reset"))
        }
    }

    func shutdown() {
        queue.sync { stop(failing: .failed("shutdown")) }
    }

    // MARK: 只在 queue 上调用

    private func pump() {
        guard current == nil, !pending.isEmpty else { return }
        if process == nil, !start() {
            let failed = pending
            pending = []
            failed.forEach { $0.completion(.failure(.notInstalled)) }
            return
        }
        let next = pending.removeFirst()
        token += 1
        let mine = token
        current = (next.completion, Date(), mine)
        let line = Self.userLine(next.message)
        stdin?.write(Data((line + "\n").utf8))
        queue.asyncAfter(deadline: .now() + next.timeout) { [self] in
            guard let current, current.token == mine else { return }
            AssistantDiag.log("assistant session timeout")
            stop(failing: .timeout)
        }
    }

    private func loadStored() -> Stored? {
        guard let data = try? Data(contentsOf: storeURL) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private func start() -> Bool {
        guard let exe = executable() else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var args = ["-p", "--model", model, "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--tools", "", "--strict-mcp-config", "--system-prompt", system]
        if let stored = loadStored() {
            args += ["--resume", stored.id]
            resumedID = stored.id
        } else {
            let id = UUID().uuidString.lowercased()
            if let data = try? JSONEncoder().encode(Stored(id: id, createdAt: Date())) { try? data.write(to: storeURL) }
            args += ["--session-id", id]
            resumedID = nil
        }
        var env = LaunchSpec.sanitizedEnvironment(base: ProcessInfo.processInfo.environment)
        if let path = exe.searchPath { env["PATH"] = path }
        env["CC_DESK"] = "1"
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
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.queue.async { self.receive(data, from: p) }
        }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.queue.async { self.exited(proc) }
        }
        do { try p.run() } catch {
            AssistantDiag.log("assistant session start failed: \(error.localizedDescription)")
            return false
        }
        process = p
        stdin = inPipe.fileHandleForWriting
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
            guard let line = String(data: lineData, encoding: .utf8), line.contains("\"result\"") else { continue }
            handleResult(line)
        }
    }

    private func handleResult(_ line: String) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              obj["type"] as? String == "result", let current else { return }
        self.current = nil
        if let envelope = AssistantEnvelope.parse(line) {
            answeredSinceStart = true
            current.completion(.success(AssistantReply(text: envelope.result, inputTokens: envelope.inputTokens,
                                                       outputTokens: envelope.outputTokens,
                                                       latency: Date().timeIntervalSince(current.started))))
            if envelope.inputTokens > Self.rotateInputTokens { rotateAfterReply = true }
        } else {
            current.completion(.failure(.failed(String(line.prefix(200)))))
        }
        if rotateAfterReply {
            rotateAfterReply = false
            AssistantDiag.log("assistant session rotating (context too large)")
            try? FileManager.default.removeItem(at: storeURL)
            stop(failing: .failed("rotate"))
        }
        pump()
    }

    private func exited(_ p: Process) {
        guard p === process else { return }
        AssistantDiag.log("assistant session exited status=\(p.terminationStatus)")
        // 接回旧会话还没答过一句就退出：多半是会话已不存在，换新会话。
        if resumedID != nil, !answeredSinceStart { try? FileManager.default.removeItem(at: storeURL) }
        let failing = current
        current = nil
        process = nil
        stdin = nil
        failing?.completion(.failure(.failed("exited")))
        pump()
    }

    private func stop(failing error: AssistantError) {
        if let current {
            self.current = nil
            current.completion(.failure(error))
        }
        guard let p = process else { return }
        process = nil
        try? stdin?.close()
        stdin = nil
        if p.isRunning { p.terminate() }
    }

    static func userLine(_ text: String) -> String {
        let obj: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: data, encoding: .utf8) else { return "" }
        return line
    }
}
