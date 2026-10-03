import Foundation
import CCDeskCore

/// 一次顾问调用（设计 §14）：后台运行一次性的 `claude -p`（只读参数见 `ConsultCommand`），问题经 stdin 传入，
/// 逐行读 stream-json：工具调用数作为进度，最后的 result 行作为结果。超时 / 取消时先 SIGTERM，3 秒后 SIGKILL。
/// 回调都在主线程，completion 恰好一次。
final class ConsultProcess: @unchecked Sendable {
    enum Ending {
        case finished(ConsultOutcome)
        case failed(String)
        case timedOut
        case cancelled
    }

    private let queue = DispatchQueue(label: "cc-desk.consult")
    private let executable: String
    private let searchPath: String?
    private let arguments: [String]
    private let cwd: URL
    private let input: String
    private let timeout: TimeInterval
    private let onProgress: (Int) -> Void
    private let completion: (Ending) -> Void

    // 以下只在 queue 上使用。
    private var process: Process?
    private var buffer = Data()
    private var stderrTail = Data()
    private var toolCalls = 0
    private var outcome: ConsultOutcome?
    private var ending: Ending?
    private var done = false

    init(executable: String, searchPath: String?, arguments: [String], cwd: URL, input: String,
         timeout: TimeInterval = ConsultCommand.timeout,
         onProgress: @escaping (Int) -> Void, completion: @escaping (Ending) -> Void) {
        self.executable = executable
        self.searchPath = searchPath
        self.arguments = arguments
        self.cwd = cwd
        self.input = input
        self.timeout = timeout
        self.onProgress = onProgress
        self.completion = completion
    }

    /// 子进程环境：去掉会话级 Claude Code 变量与控制接口口令（顾问不能用 CC Desk 的工具），
    /// 不限制扩展思考（让更强的模型自己决定想多久）。
    static func environment(searchPath: String?) -> [String: String] {
        var env = LaunchSpec.sanitizedEnvironment(base: ProcessInfo.processInfo.environment)
        if let searchPath { env["PATH"] = searchPath }
        env["MAX_THINKING_TOKENS"] = nil
        env["CC_DESK"] = "1"
        return env
    }

    @discardableResult
    func start() -> Bool {
        queue.sync {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
            p.environment = Self.environment(searchPath: searchPath)
            p.currentDirectoryURL = cwd
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = outPipe
            p.standardError = errPipe
            outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                self?.queue.async { self?.receive(data) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                self?.queue.async {
                    guard let self else { return }
                    self.stderrTail.append(data)
                    if self.stderrTail.count > 4096 { self.stderrTail = self.stderrTail.suffix(4096) }
                }
            }
            p.terminationHandler = { [weak self] proc in
                // 稍等让管道里剩下的输出读完（result 行可能和退出几乎同时到达）。
                self?.queue.asyncAfter(deadline: .now() + 0.2) { self?.exited(proc.terminationStatus) }
            }
            do { try p.run() } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                AssistantDiag.log("consult start failed: \(error.localizedDescription)")
                return false
            }
            process = p
            // 问题经 stdin 传入后关闭（claude -p 读到 EOF 才开始）。
            do {
                try inPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            } catch {
                AssistantDiag.log("consult stdin write failed: \(error.localizedDescription)")
            }
            try? inPipe.fileHandleForWriting.close()
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.stop(.timedOut) }
            return true
        }
    }

    func cancel() {
        queue.async { [weak self] in self?.stop(.cancelled) }
    }

    // MARK: 只在 queue 上调用

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            let calls = ConsultOutcome.toolCalls(line: line)
            if calls > 0 {
                toolCalls += calls
                let count = toolCalls
                DispatchQueue.main.async { [onProgress] in onProgress(count) }
            }
            if line.contains("\"type\":\"result\""), let parsed = ConsultOutcome.parse(line: line) { outcome = parsed }
        }
    }

    /// 超时 / 取消：记下原因并结束进程；进程退出后在 exited 里报告。
    private func stop(_ reason: Ending) {
        guard !done, ending == nil, let p = process else { return }
        ending = reason
        guard p.isRunning else { return }
        p.terminate()
        let pid = p.processIdentifier
        queue.asyncAfter(deadline: .now() + 3) { [weak p] in
            if p?.isRunning == true { kill(pid, SIGKILL) }
        }
    }

    private func exited(_ status: Int32) {
        guard !done else { return }
        done = true
        process = nil
        let result: Ending
        if let ending {
            result = ending
        } else if let outcome, !outcome.isError, !outcome.answer.isEmpty {
            result = .finished(outcome)
        } else if let outcome {
            result = .failed(outcome.answer.isEmpty ? "the advisor returned an error" : String(outcome.answer.prefix(300)))
        } else {
            let err = String(data: stderrTail, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            result = .failed("exit \(status)" + (err.isEmpty ? "" : ": " + String(err.suffix(300))))
        }
        DispatchQueue.main.async { [completion] in completion(result) }
    }
}
