import AVFoundation
import CCDeskCore

/// 自然语音引擎：管理常驻的 tts_server.py 进程，按句请求合成，流式播放回传的 24 kHz PCM。
///
/// - 懒启动（对话模式打开 / 第一次朗读时），加载 + 预热约 2 秒（冷盘更久），就绪前 `state == .starting`；
/// - 进程意外退出时：对话模式开着（keepWarm）则 1 秒后重启，一分钟内最多 3 次；
/// - 对话模式关着且空闲 10 分钟后卸载（模型常驻约 2 GB 内存）；
/// - 一次只读一段话（utterance）：所有句子一次发给服务端排队合成，音频按到达顺序排进 AVAudioPlayerNode；
///   新的一段或 stop() 会取消旧的（服务端 `{"cancel":"*"}`，本地清空播放队列）。
/// 状态只在主线程读写；管道读取与解码在 readQueue 上。
final class NaturalSpeechEngine: @unchecked Sendable {
    static let shared = NaturalSpeechEngine()

    enum State: Equatable { case stopped, starting, ready }
    enum Outcome: Equatable {
        case finished
        case cancelled
        /// 一点声音都没出就失败了（调用方改用系统声音）。
        case failed
    }

    static let idleUnload: TimeInterval = 600
    static let startupTimeout: TimeInterval = 90

    private(set) var state: State = .stopped
    /// 服务端 ready 帧里的信息（load_s / ready_s）。
    private(set) var readyInfo: String?
    /// 对话模式开着：保持加载，崩溃后自动重启。
    var keepWarm = false {
        didSet {
            if keepWarm { crashTimes = [] }
            scheduleIdleCheck()
        }
    }
    /// 测试用：静音播放。
    var muted = false { didSet { audioEngine.mainMixerNode.outputVolume = muted ? 0 : 1 } }
    /// 测试用：服务端每个 end 帧（id, 统计 JSON）。
    var onServerEnd: ((String, String) -> Void)?

    var processID: Int32? { process?.processIdentifier }

    private var process: Process?
    private var input: FileHandle?
    private var stopping = false
    private var readyWaiters: [(Bool) -> Void] = []
    private var crashTimes: [Date] = []
    private var lastActivity = Date()
    private var idleWork: DispatchWorkItem?
    private var startupWork: DispatchWorkItem?
    private let readQueue = DispatchQueue(label: "cc-desk.tts.read")

    /// 每个进程一个解码器，只在 readQueue 上使用。
    private final class DecoderBox: @unchecked Sendable {
        var decoder = NaturalVoiceProtocol.Decoder()
    }

    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: NaturalVoiceProtocol.sampleRate, channels: 1)
    private var audioConfigured = false

    private struct Utterance {
        let token: Int
        var pending: Set<String>
        var scheduled = 0
        var gotAudio = false
        var failed = false
        let onAudio: () -> Void
        let onDone: (Outcome) -> Void
    }

    private var current: Utterance?
    private var nextToken = 0

    init() {
        // 服务进程意外退出后再写 stdin 会触发 SIGPIPE（默认终止整个 App）；忽略后 write 只会抛错。
        signal(SIGPIPE, SIG_IGN)
        // 输出设备变化（耳机插拔等）时引擎会停下，已排队的缓冲不会再回调：直接结束当前这段，免得一直卡在「朗读中」。
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audioEngine,
                                               queue: .main) { [weak self] _ in
            guard let self, var u = self.current else { return }
            AssistantDiag.log("natural voice: audio configuration changed")
            u.scheduled = 0
            self.current = u
            self.checkDone()
        }
    }

    // MARK: 进程

    /// 启动服务（已在运行 / 未安装时什么都不做）。
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        touch()
        guard state == .stopped else { return }
        guard NaturalVoice.isInstalled, let script = NaturalVoice.serverScript else {
            AssistantDiag.log("natural voice: not installed or server script missing")
            return
        }
        let p = Process()
        p.executableURL = NaturalVoice.python
        p.arguments = [script.path, NaturalVoice.modelDir.path]
        p.environment = NaturalVoice.serverEnvironment()
        p.currentDirectoryURL = NaturalVoice.root
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        FileManager.default.createFile(atPath: NaturalVoice.logURL.path, contents: nil)
        p.standardError = (try? FileHandle(forWritingTo: NaturalVoice.logURL)) ?? FileHandle.nullDevice
        let reader = stdoutPipe.fileHandleForReading
        let box = DecoderBox()
        reader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.readQueue.async { self?.decode(data, with: box, from: p) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.terminated(proc) }
        }
        do {
            try p.run()
        } catch {
            AssistantDiag.log("natural voice: launch failed \(error.localizedDescription)")
            reader.readabilityHandler = nil
            return
        }
        process = p
        input = stdinPipe.fileHandleForWriting
        stopping = false
        state = .starting
        AssistantDiag.log("natural voice: server starting pid=\(p.processIdentifier)")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.process === p, self.state == .starting else { return }
            AssistantDiag.log("natural voice: startup timed out")
            self.unload()
        }
        startupWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startupTimeout, execute: work)
    }

    /// 就绪后（或超时 / 失败时）回调；未运行时先启动。
    func whenReady(timeout: TimeInterval, _ completion: @escaping (Bool) -> Void) {
        if state == .ready { return completion(true) }
        start()
        guard state == .starting else { return completion(false) }
        var done = false
        let finish: (Bool) -> Void = { ok in
            guard !done else { return }
            done = true
            completion(ok)
        }
        readyWaiters.append(finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(false) }
    }

    /// 卸载：关 stdin 让服务自己退出，2 秒后还在就强杀。
    func unload() {
        guard let p = process else { return }
        stop()
        stopping = true
        try? input?.close()
        input = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if p.isRunning { p.terminate() }
        }
    }

    private func terminated(_ p: Process) {
        guard p === process else { return }
        let deliberate = stopping
        process = nil
        input = nil
        startupWork?.cancel()
        state = .stopped
        readyInfo = nil
        AssistantDiag.log("natural voice: server exited status=\(p.terminationStatus) deliberate=\(deliberate)")
        failWaiters()
        if var u = current {
            // 已排进播放队列的音频照常播完。
            u.pending = []
            u.failed = true
            current = u
            checkDone()
        }
        guard !deliberate, keepWarm else { return }
        let now = Date()
        crashTimes = crashTimes.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard crashTimes.count <= 3 else {
            AssistantDiag.log("natural voice: crashed too often, staying on the system voice")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.keepWarm, self.state == .stopped else { return }
            self.start()
        }
    }

    private func failWaiters() {
        let waiters = readyWaiters
        readyWaiters = []
        waiters.forEach { $0(false) }
    }

    private func send(_ data: Data) {
        guard let input else { return }
        do {
            try input.write(contentsOf: data)
        } catch {
            AssistantDiag.log("natural voice: write failed \(error.localizedDescription)")
        }
    }

    // MARK: 帧

    /// readQueue 上：解码后切回主线程处理。
    private func decode(_ data: Data, with box: DecoderBox, from p: Process) {
        do {
            let frames = try box.decoder.append(data)
            guard !frames.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.process === p else { return }
                frames.forEach(self.handle)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                AssistantDiag.log("natural voice: corrupt stream \(error), restarting")
                guard let self, self.process === p else { return }
                p.terminate()
            }
        }
    }

    private func handle(_ frame: NaturalVoiceProtocol.Frame) {
        switch frame.kind {
        case .ready:
            startupWork?.cancel()
            state = .ready
            readyInfo = frame.text
            AssistantDiag.log("natural voice: ready \(frame.text)")
            let waiters = readyWaiters
            readyWaiters = []
            waiters.forEach { $0(true) }
            scheduleIdleCheck()
        case .audio:
            guard var u = current, u.pending.contains(frame.id) else { return }
            guard schedule(frame.samples, token: u.token) else { return }
            u.scheduled += 1
            let first = !u.gotAudio
            u.gotAudio = true
            current = u
            if first { u.onAudio() }
        case .end:
            onServerEnd?(frame.id, frame.text)
            guard var u = current, u.pending.remove(frame.id) != nil else { return }
            current = u
            checkDone()
        case .error:
            AssistantDiag.log("natural voice: server error [\(frame.id)] \(frame.text)")
            guard var u = current, u.pending.remove(frame.id) != nil else { return }
            u.failed = true
            current = u
            checkDone()
        }
    }

    // MARK: 朗读

    /// 读一段话（已切好的句子）。未就绪时返回 false。
    @discardableResult
    func speak(sentences: [String], lang: String, onAudio: @escaping () -> Void,
               onDone: @escaping (Outcome) -> Void) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state == .ready, input != nil, !sentences.isEmpty else { return false }
        stop()
        touch()
        nextToken += 1
        let token = nextToken
        let ids = sentences.indices.map { "u\(token).\($0)" }
        current = Utterance(token: token, pending: Set(ids), onAudio: onAudio, onDone: onDone)
        for (id, text) in zip(ids, sentences) {
            send(NaturalVoiceProtocol.speakRequest(id: id, text: text, lang: lang))
        }
        return true
    }

    /// 打断当前这段（回调 .cancelled）。
    func stop() {
        guard let u = current else { return }
        current = nil
        send(NaturalVoiceProtocol.cancelRequest("*"))
        player.stop()
        touch()
        u.onDone(.cancelled)
    }

    private func checkDone() {
        guard let u = current, u.pending.isEmpty, u.scheduled == 0 else { return }
        current = nil
        touch()
        u.onDone(u.failed && !u.gotAudio ? .failed : .finished)
    }

    /// 把一块采样排进播放队列（必要时启动音频引擎）。
    private func schedule(_ samples: [Float], token: Int) -> Bool {
        guard !samples.isEmpty, let format, ensureAudio(),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { channel.update(from: base, count: samples.count) }
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.played(token: token) }
        }
        if !player.isPlaying { player.play() }
        return true
    }

    private func played(token: Int) {
        guard var u = current, u.token == token else { return }
        u.scheduled -= 1
        current = u
        checkDone()
    }

    private func ensureAudio() -> Bool {
        if !audioConfigured, let format {
            audioEngine.attach(player)
            audioEngine.connect(player, to: audioEngine.mainMixerNode, format: format)
            audioEngine.mainMixerNode.outputVolume = muted ? 0 : 1
            audioConfigured = true
        }
        guard audioConfigured else { return false }
        if audioEngine.isRunning { return true }
        do {
            audioEngine.prepare()
            try audioEngine.start()
            return true
        } catch {
            AssistantDiag.log("natural voice: audio engine failed \(error.localizedDescription)")
            return false
        }
    }

    // MARK: 空闲卸载

    private func touch() {
        lastActivity = Date()
    }

    private func scheduleIdleCheck() {
        idleWork?.cancel()
        guard !keepWarm, state != .stopped else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.keepWarm, self.state != .stopped else { return }
            if self.current == nil, Date().timeIntervalSince(self.lastActivity) >= Self.idleUnload {
                AssistantDiag.log("natural voice: idle, unloading")
                self.unload()
                // 音频设备也释放掉。
                if self.audioEngine.isRunning { self.audioEngine.stop() }
            } else {
                self.scheduleIdleCheck()
            }
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleUnload / 4, execute: work)
    }
}
