import AppKit
import AVFoundation
import CCDeskCore

/// 对话模式（免按键语音）：持续监听，VAD 切出一句话后本机 Whisper 识别。
///
/// - 待命：只听唤醒词（默认「嬴政同学」，UserDefaults `voiceWakeWord`）；刚播报过「需要批准」时也接受批准 / 拒绝。
/// - 对话中：每句话追加到选中内嵌终端的输入框（不发送），「发送」回车、「取消」删掉本轮插入的文字、
///   「退出对话模式」关闭；发送 / 取消 / 30 秒没说话后回到待命。
/// - 选中 session 转为等批准 / 一轮完成时简短播报；播报期间暂停采集，避免识别到自己的声音。
/// 状态机在 CCDeskCore 的 `ConversationSession`；这里负责麦克风、识别、终端按键、播报与界面状态。
/// 只在主线程使用；音频回调切到 `audioQueue`，识别在 Transcriber actor 里串行进行。
final class ConversationMode: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var isOn = false
    /// 待命 / 对话中。
    @Published private(set) var state: ConversationSession.State = .standby
    /// 正在准备模型（下载 / 加载进度由 VoiceInput 的浮层显示）。
    @Published private(set) var preparing = false
    /// VAD 判定正在说话。
    @Published private(set) var capturing = false
    @Published private(set) var transcribing = false
    @Published private(set) var speaking = false
    @Published private(set) var level: Float = 0
    /// 指令执行后的简短提示（已发送 / 已清空…）。
    @Published private(set) var toast: String?

    private let pool: TerminalPool
    private let voice: VoiceInput
    private let transcriber: Transcriber
    private let selectedTerminalID: () -> UUID?
    private let statusOf: (UUID) -> AgentStatus?
    private let recorder = ContinuousRecorder()
    private let synthesizer = AVSpeechSynthesizer()

    private var session = ConversationSession()
    /// 本轮（上次发送 / 清空以来）插入到 `insertedTarget` 的文字，「取消」时按字符数退格删除。
    private var inserted = ""
    private var insertedTarget: UUID?
    /// 等待识别的片段（与说话时选中的终端）。
    private var queue: [(samples: [Float], target: UUID)] = []
    private var timer: Timer?
    private var toastWork: DispatchWorkItem?
    private var resumeWork: DispatchWorkItem?
    /// 上一次观察到的选中终端及其状态，用于判断播报。
    private var observed: (id: UUID, status: AgentStatus)?
    /// 每次开关递增；迟到的回调据此丢弃。
    private var generation = 0

    // 以下只在 audioQueue 上使用。
    private let audioQueue = DispatchQueue(label: "cc-desk.conversation.vad")
    private var vad = VoiceActivityDetector()
    private var paused = false
    private let levelLock = NSLock()
    private var currentLevel: Float = 0

    init(pool: TerminalPool, voice: VoiceInput, transcriber: Transcriber = WhisperTranscriber.shared,
         selectedTerminalID: @escaping () -> UUID?, statusOf: @escaping (UUID) -> AgentStatus?) {
        self.pool = pool
        self.voice = voice
        self.transcriber = transcriber
        self.selectedTerminalID = selectedTerminalID
        self.statusOf = statusOf
        super.init()
        synthesizer.delegate = self
    }

    var wakeWord: String { session.wakeWord }

    static var storedWakeWord: String {
        let stored = UserDefaults.standard.string(forKey: ConversationSession.wakeWordDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? ConversationSession.defaultWakeWord : stored
    }

    /// Whisper 提示词里追加的唤醒词提示。不要以唤醒词结尾：实测那样 Whisper 会把开头的唤醒词当作提示的延续而漏掉。
    private var transcriptionHint: String { "用户会先说\(wakeWord)再下指令。" }

    // MARK: 开关

    func toggle() {
        isOn ? turnOff() : turnOn()
    }

    func turnOn() {
        guard !isOn else { return }
        guard selectedTerminalID() != nil else { return voice.showHint(L("voice.hint.selectSession")) }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { [weak self] in
                    if granted { self?.turnOn() } else { self?.voice.showHint(L("voice.hint.micDenied")) }
                }
            }
            return
        default:
            voice.alertMicrophoneDenied()
            return
        }
        generation += 1
        let current = generation
        session = ConversationSession(wakeWord: Self.storedWakeWord)
        state = session.state
        isOn = true
        preparing = true
        inserted = ""
        insertedTarget = nil
        observed = nil
        voice.ensureModel { [weak self] ready in
            guard let self, self.isOn, self.generation == current else { return }
            self.preparing = false
            ready ? self.startListening() : self.turnOff()
        }
    }

    func turnOff() {
        guard isOn else { return }
        generation += 1
        isOn = false
        preparing = false
        capturing = false
        transcribing = false
        speaking = false
        level = 0
        queue = []
        inserted = ""
        insertedTarget = nil
        observed = nil
        session.reset()
        state = session.state
        timer?.invalidate()
        timer = nil
        resumeWork?.cancel()
        synthesizer.stopSpeaking(at: .immediate)
        recorder.stop()
        audioQueue.async { [self] in
            vad = VoiceActivityDetector()
            paused = false
        }
    }

    private func startListening() {
        audioQueue.async { [self] in
            vad = VoiceActivityDetector()
            paused = false
        }
        let current = generation
        recorder.start(onSamples: { [weak self] chunk in
            self?.audioQueue.async { self?.feed(chunk, generation: current) }
        }, completion: { [weak self] ok in
            DispatchQueue.main.async {
                guard let self, self.generation == current, !ok else { return }
                self.voice.showHint(L("voice.hint.micUnavailable"))
                self.turnOff()
            }
        })
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        levelLock.lock()
        let value = currentLevel
        levelLock.unlock()
        level = speaking ? 0 : value
        for action in session.tick(now: ProcessInfo.processInfo.systemUptime) { perform(action, target: nil) }
        state = session.state
    }

    // MARK: 音频（audioQueue）

    private func feed(_ chunk: [Float], generation current: Int) {
        guard !paused else { return }
        let level = chunk.withUnsafeBufferPointer(MicrophoneTap.level(of:))
        levelLock.lock()
        currentLevel = currentLevel * 0.4 + level * 0.6
        levelLock.unlock()
        for event in vad.process(chunk) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isOn, self.generation == current else { return }
                self.handle(event)
            }
        }
    }

    // MARK: 识别

    private func handle(_ event: VoiceActivityDetector.Event) {
        switch event {
        case .speechStarted:
            capturing = true
            session.noteSpeech(now: ProcessInfo.processInfo.systemUptime)
        case .discarded:
            capturing = false
        case .utterance(let samples):
            capturing = false
            session.noteSpeech(now: ProcessInfo.processInfo.systemUptime)
            guard let target = selectedTerminalID() else { return }
            queue.append((samples, target))
            transcribeNext()
        }
    }

    private func transcribeNext() {
        guard !transcribing, !queue.isEmpty else { return }
        let (samples, target) = queue.removeFirst()
        let duration = Double(samples.count) / Double(MicrophoneTap.sampleRate)
        let policy = session.transcriptionPolicy(duration: duration)
        let matcher = session.matcher
        let hint = transcriptionHint
        let current = generation
        transcribing = true
        Task { @MainActor [weak self, transcriber] in
            var text: String?
            do {
                if case .prefixThenFull(let seconds) = policy {
                    // 待命时的长片段：先只识别开头检查唤醒词，没有就不必识别整段。
                    let prefix = Array(samples.prefix(Int(seconds * Double(MicrophoneTap.sampleRate))))
                    let head = try await transcriber.transcribe(prefix, hint: hint)
                    if matcher.match(head) != nil { text = try await transcriber.transcribe(samples, hint: hint) }
                } else {
                    text = try await transcriber.transcribe(samples, hint: hint)
                }
            } catch {
                text = nil
            }
            guard let self, self.isOn, self.generation == current else { return }
            self.transcribing = false
            if let text, !text.isEmpty { self.apply(text, target: target) }
            self.transcribeNext()
        }
    }

    private func apply(_ text: String, target: UUID) {
        let waiting = statusOf(target)?.isWaiting ?? false
        let actions = session.handle(transcript: text, waiting: waiting, now: ProcessInfo.processInfo.systemUptime)
        for action in actions { perform(action, target: target) }
        state = session.state
    }

    // MARK: 动作

    private func perform(_ action: ConversationAction, target: UUID?) {
        let terminal = target.flatMap(pool.terminal)
        if let target, insertedTarget != target {
            inserted = ""
            insertedTarget = target
        }
        switch action {
        case .wake:
            // 唤醒后用语音应答（「我在」），播报期间暂停采集，结束后自动恢复聆听。
            speak(L("conversation.wake.reply"))
        case .standby:
            NSSound(named: "Pop")?.play()
        case .insert(let text):
            guard let terminal else { return voice.showHint(L("voice.hint.targetClosed")) }
            let payload = ConversationText.insertion(text, after: inserted)
            terminal.send(text: payload, submit: false)
            inserted += payload
        case .send:
            terminal?.sendKeys("\r")
            inserted = ""
            showToast(L("conversation.toast.sent"))
        case .cancel:
            // Claude Code 的 Ctrl+U 只删到当前可视行的行首（长文本自动换行后删不干净），
            // 按插入的字符数退格才能准确删掉本轮插入的内容（实测 Claude Code 中可靠）。
            if !inserted.isEmpty { terminal?.sendKeys(String(repeating: "\u{7f}", count: inserted.count)) }
            inserted = ""
            showToast(L("conversation.toast.cleared"))
        case .approve:
            // Claude Code / Codex 的权限对话框默认高亮第一项「Yes」，回车即批准。
            terminal?.sendKeys("\r")
            showToast(L("conversation.toast.approved"))
        case .deny:
            terminal?.sendKeys("\u{1b}")
            showToast(L("conversation.toast.denied"))
        case .stop:
            turnOff()
            showToast(L("conversation.toast.stopped"))
        }
    }

    private func showToast(_ text: String) {
        toastWork?.cancel()
        toast = text
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    // MARK: 状态播报

    /// 每次轮询后由 AppModel 调用：选中的内嵌终端及其当前状态。
    func observe(terminalID: UUID?, status: AgentStatus?) {
        guard isOn else { return }
        guard let terminalID, let status else {
            observed = nil
            return
        }
        defer { observed = (terminalID, status) }
        guard let previous = observed, previous.id == terminalID,
              let text = SpokenStatus.announcement(previous: previous.status, current: status) else { return }
        if status.isWaiting { session.noteWaitingAnnounced(now: ProcessInfo.processInfo.systemUptime) }
        speak(text)
    }

    private func speak(_ text: String) {
        resumeWork?.cancel()
        setPaused(true)
        speaking = true
        capturing = false
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Localization.currentLanguage == "zh-Hans" ? "zh-CN" : "en-US")
        synthesizer.speak(utterance)
    }

    /// 播报结束后稍等再恢复采集（扬声器余音）。
    private func speechEnded() {
        guard !synthesizer.isSpeaking else { return }
        resumeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.synthesizer.isSpeaking else { return }
            self.speaking = false
            if self.isOn { self.setPaused(false) }
        }
        resumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func setPaused(_ value: Bool) {
        audioQueue.async { [self] in
            paused = value
            vad.reset()
        }
    }
}

extension ConversationMode: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.speechEnded() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.speechEnded() }
    }
}

/// 持续录音：AVAudioEngine 输入 -> 16 kHz 单声道块，交给回调（音频线程），不在内存里累积。
/// start / stop 在专用串行队列上执行，不阻塞主线程。
final class ContinuousRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cc-desk.conversation.audio")
    private var engine: AVAudioEngine?

    /// completion(false)：没有可用的输入设备或无法启动。
    func start(onSamples: @escaping ([Float]) -> Void, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            stopEngine()
            let engine = AVAudioEngine()
            guard MicrophoneTap.install(on: engine, handler: { chunk in onSamples(Array(chunk)) }) else {
                return completion(false)
            }
            do {
                engine.prepare()
                try engine.start()
                self.engine = engine
                completion(true)
            } catch {
                engine.inputNode.removeTap(onBus: 0)
                completion(false)
            }
        }
    }

    func stop() {
        queue.async { [self] in stopEngine() }
    }

    private func stopEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }
}
