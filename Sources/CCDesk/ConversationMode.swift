import AppKit
import AVFoundation
import CCDeskCore

/// 对话模式（免按键语音）：持续监听，VAD 切出一句话后本机 Whisper 识别。
///
/// - 待命：只听唤醒词（默认「嬴政同学」，UserDefaults `voiceWakeWord`）；刚播报过「需要批准」时也接受批准 / 拒绝。
/// - 对话中：每句话追加到选中内嵌终端的输入框（不发送），「发送」回车、「取消」删掉本轮插入的文字、
///   「退出对话模式」关闭；发送 / 取消 / 30 秒没说话后回到待命。
/// - 选中 session 转为等批准 / 一轮完成时简短播报；播报期间暂停采集，避免识别到自己的声音。
///   播报用 SpeechOutput：选了自然语音（本机 Qwen3-TTS）时用它，未就绪 / 失败时退回系统声音。
/// - 语音助手（设计 §12/§13）：对话中没命中本地指令的话交给常驻助手会话，它用 CC Desk 的工具做事（打字、切换、
///   新建、读屏…），最后的文字回复被朗读；等待期间提示音 +「听到：… · 思考中…」，执行工具时显示「→ …」。
///   需确认的工具在这里语音确认（15 秒内说「确认」）。「撤销」撤回上一个可撤销动作。
///   选中会话一轮完成时播报一两句回复摘要（可在菜单关闭）。
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
    /// 正在等语音助手。
    @Published private(set) var thinking = false
    /// 助手正在处理的那句话（「听到：…」）。
    @Published private(set) var heard: String?
    /// 助手正在执行的工具（「→ 往 poems 输入：…」）。
    @Published private(set) var activity: String?
    @Published private(set) var level: Float = 0
    /// 指令执行后的简短提示（已发送 / 已清空…）。
    @Published private(set) var toast: String?

    private let pool: TerminalPool
    private let voice: VoiceInput
    private let transcriber: Transcriber
    private let selectedTerminalID: () -> UUID?
    private let statusOf: (UUID) -> AgentStatus?
    private let recorder = ContinuousRecorder()
    private let output = SpeechOutput()
    private let assistant: VoiceAssistant
    /// 未发送的输入与撤销记录（与助手工具共用）。
    private let inputs: AssistantInputs
    /// 提供侧栏上下文、切换 / 关闭会话、读记录的对象（AppModel）。
    weak var host: AssistantHost?
    /// 选中会话最近一轮的回复摘要（作为助手的上下文）。
    private var lastSummaries: [UUID: String] = [:]
    /// 等待语音确认的工具调用（关闭 / 接管 / 中断）：截止时间与回调。
    private var pendingConfirmation: (deadline: TimeInterval, completion: (Bool) -> Void)?
    /// 本轮助手调用过的工具是否都只是往输入框打字（是则不朗读回复，只显示提示条）；nil = 本轮没调用工具。
    private var turnQuiet: Bool?

    private var session = ConversationSession()
    /// 等待识别的片段（与说话时选中的终端）。
    private var queue: [(samples: [Float], target: UUID?)] = []
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

    init(pool: TerminalPool, voice: VoiceInput, inputs: AssistantInputs, transcriber: Transcriber = WhisperTranscriber.shared,
         assistant: VoiceAssistant = VoiceAssistant(),
         selectedTerminalID: @escaping () -> UUID?, statusOf: @escaping (UUID) -> AgentStatus?) {
        self.pool = pool
        self.inputs = inputs
        self.assistant = assistant
        self.voice = voice
        self.transcriber = transcriber
        self.selectedTerminalID = selectedTerminalID
        self.statusOf = statusOf
        super.init()
        output.onFinish = { [weak self] in self?.speechEnded() }
    }

    var wakeWord: String { session.wakeWord }

    static var storedWakeWord: String {
        let stored = UserDefaults.standard.string(forKey: ConversationSession.wakeWordDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? ConversationSession.defaultWakeWord : stored
    }

    static let summariesDefaultsKey = "voiceTurnSummaries"
    static let persistentDefaultsKey = "conversationPersistent"
    static let autoStartDefaultsKey = "conversationAutoStart"

    /// 「启动时开启助手」：App 启动后自动进入对话模式待命（默认关；需已有麦克风权限和语音模型）。
    static var autoStartEnabled: Bool {
        UserDefaults.standard.object(forKey: autoStartDefaultsKey) as? Bool ?? false
    }

    /// 启动时自动开启：不触发模型下载；麦克风未授权过时会弹系统授权框，被拒绝过就保持关闭。
    func autoStartIfEnabled() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let downloaded = WhisperTranscriber.shared.isDownloaded
        AssistantDiag.log("auto start enabled=\(Self.autoStartEnabled) mic=\(mic.rawValue) model=\(downloaded)")
        guard Self.autoStartEnabled, !isOn, mic == .authorized || mic == .notDetermined, downloaded else { return }
        turnOn()
    }

    /// 「常驻对话」：唤醒一次后一直在线，说「休息一下」才回到待命（默认开）。
    static var persistentEnabled: Bool {
        UserDefaults.standard.object(forKey: persistentDefaultsKey) as? Bool ?? true
    }

    /// 「回复摘要」：一轮完成时播报摘要而不是「已完成」（默认开）。
    static var summariesEnabled: Bool {
        get { UserDefaults.standard.object(forKey: summariesDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: summariesDefaultsKey) }
    }

    /// Whisper 提示词里追加的唤醒词提示。不要以唤醒词结尾：实测那样 Whisper 会把开头的唤醒词当作提示的延续而漏掉。
    private var transcriptionHint: String { "用户会先说\(wakeWord)再下指令。" }

    // MARK: 开关

    func toggle() {
        isOn ? turnOff() : turnOn()
    }

    func turnOn() {
        guard !isOn else { return }
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
        session.persistent = Self.persistentEnabled
        session.routesToAssistant = assistant.isAvailable != false
        state = session.state
        thinking = false
        heard = nil
        activity = nil
        assistant.prepare { [weak self] ok in
            guard let self, self.isOn, self.generation == current else { return }
            self.session.routesToAssistant = ok
            AssistantDiag.log("assistant prepare ok=\(ok)")
        }
        if !NaturalVoice.isSelected, SpeechVoices.takeQualityHint() { voice.showHint(L("voice.hint.betterVoice")) }
        // 自然语音在对话模式期间常驻；现在就开始加载（约 2 秒），加载完之前的播报用系统声音。
        NaturalSpeechEngine.shared.keepWarm = true
        if NaturalVoice.isSelected { NaturalSpeechEngine.shared.start() }
        isOn = true
        preparing = true
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
        thinking = false
        heard = nil
        activity = nil
        resolveConfirmation(false)
        level = 0
        queue = []
        observed = nil
        session.reset()
        state = session.state
        timer?.invalidate()
        timer = nil
        resumeWork?.cancel()
        output.stop()
        // 关闭后空闲 10 分钟卸载自然语音模型。
        NaturalSpeechEngine.shared.keepWarm = false
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
        session.persistent = Self.persistentEnabled
        let now = ProcessInfo.processInfo.systemUptime
        if let pending = pendingConfirmation, now > pending.deadline {
            resolveConfirmation(false)
            showToast(L("assistant.toast.cancelled"))
        }
        for action in session.tick(now: now) { perform(action, target: nil) }
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
            // 助手常驻：没选中内嵌会话时也照常识别（列会话 / 切换 / 新建不需要目标终端）。
            queue.append((samples, selectedTerminalID()))
            transcribeNext()
        }
    }

    private func transcribeNext() {
        // 等助手时先不处理后面的话，保证插入顺序；助手在等语音确认时例外。
        guard !transcribing, !thinking || pendingConfirmation != nil, !queue.isEmpty else { return }
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

    private func apply(_ text: String, target: UUID?) {
        if pendingConfirmation != nil { return answerConfirmation(text) }
        let waiting = target.flatMap(statusOf)?.isWaiting ?? false
        session.persistent = Self.persistentEnabled
        let before = session.state
        let actions = session.handle(transcript: text, waiting: waiting, now: ProcessInfo.processInfo.systemUptime)
        AssistantDiag.log("heard \"\(text)\" state=\(before) assistant=\(session.routesToAssistant) -> \(actions)")
        for action in actions { perform(action, target: target) }
        state = session.state
    }

    // MARK: 动作

    private func perform(_ action: ConversationAction, target: UUID?) {
        let terminal = target.flatMap(pool.terminal)
        switch action {
        case .wake:
            // 唤醒后用语音应答（「我在」），播报期间暂停采集，结束后自动恢复聆听。
            speak(L("conversation.wake.reply"))
        case .standby:
            NSSound(named: "Pop")?.play()
        case .assist(let text):
            assist(text, target: target)
        case .insert(let text):
            guard let terminal else { return noTarget() }
            inputs.type(text, into: terminal, title: targetTitle, submit: false)
            assistant.note("typed \"\(text)\" into \(targetTitle) (not sent)")
        case .send:
            guard let terminal else { return noTarget() }
            terminal.sendKeys("\r")
            inputs.submitted(terminal.id)
            showToast(L("conversation.toast.sent"))
            assistant.note("pressed Enter (sent) in \(targetTitle)")
        case .cancel:
            if let terminal { inputs.clear(terminal) }
            showToast(L("conversation.toast.cleared"))
            assistant.note("cleared the pending text in \(targetTitle)")
        case .undo:
            undo()
        case .approve:
            // Claude Code / Codex 的权限对话框默认高亮第一项「Yes」，回车即批准。
            terminal?.sendKeys("\r")
            showToast(L("conversation.toast.approved"))
            assistant.note("approved the permission prompt in \(targetTitle)")
        case .deny:
            terminal?.sendKeys("\u{1b}")
            showToast(L("conversation.toast.denied"))
            assistant.note("denied the permission prompt in \(targetTitle)")
        case .stop:
            turnOff()
            showToast(L("conversation.toast.stopped"))
        }
    }

    /// 「撤销」：撤回上一个可撤销动作（新建 → 关闭；未发送的输入 → 删除；切换 → 切回）。
    private func undo() {
        guard let action = inputs.popUndo() else { return speak(L("assistant.undo.none")) }
        let message: String
        switch action {
        case .created(let rowID, let title):
            host?.assistantClose(rowID)
            message = L("assistant.undo.created", title)
        case .typed(let tid, let text, _):
            guard let terminal = pool.terminal(tid), inputs.undoTyping(text, in: terminal) else { return undo() }
            message = L("assistant.undo.typed")
        case .switched(let rowID, let title):
            guard host?.assistantRow(rowID) != nil else { return undo() }
            host?.assistantSwitch(to: rowID)
            message = L("assistant.undo.switched", title)
        }
        AssistantDiag.log("undo \(action)")
        assistant.note("undid: \(action)")
        showToast(message)
        speak(message)
    }

    /// 选中会话的标题（给助手的事件记录用）。
    private var targetTitle: String {
        host?.assistantContext(pendingText: "", lastSummary: nil).selected.map { "\($0.title) (\($0.dir))" } ?? "no session"
    }

    /// 菜单「重置助手对话」：丢弃助手的对话记忆。
    func resetAssistant() {
        assistant.reset()
        showToast(L("assistant.toast.reset"))
    }

    /// 要往终端里输入，但当前没选中 CC Desk 里的会话。
    private func noTarget() {
        showToast(L("assistant.noTarget"))
        speak(L("assistant.noTarget"))
    }

    private func showToast(_ text: String, duration: TimeInterval = 1.8) {
        toastWork?.cancel()
        toast = text
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    // MARK: 语音助手

    /// 本地规则没命中的话：「哪些在等我」「有哪些会话」本地回答，转述直接填入，其余交给常驻助手（期间提示音 +「思考中…」）。
    private func assist(_ text: String, target: UUID?) {
        guard let host else { return perform(.insert(text), target: target) }
        let context = host.assistantContext(pendingText: target.map(inputs.pending) ?? "",
                                            lastSummary: target.flatMap { lastSummaries[$0] })
        if AssistantLocal.isWaitingQuestion(text) {
            return speak(AssistantLocal.waitingAnswer(sessions: context.sessions))
        }
        if let content = AssistantLocal.relayContent(text) {
            AssistantDiag.log("relay -> insert \"\(content)\"")
            // 「让它继续」：正在等批准时就是批准。
            if ConversationCommands.normalize(content) == "继续", target.flatMap(statusOf)?.isWaiting == true {
                return perform(.approve, target: target)
            }
            return perform(.insert(content), target: target)
        }
        if AssistantLocal.isListQuestion(text) {
            let answer = AssistantLocal.listAnswer(sessions: context.sessions)
            assistant.note("user asked \"\(text)\"; CC Desk answered \"\(answer)\"")
            return speak(answer)
        }
        let current = generation
        beginThinking(heard: text)
        assistant.handle(utterance: text, context: context) { [weak self] result in
            guard let self, self.isOn, self.generation == current else { return }
            let quiet = self.turnQuiet == true
            self.endThinking()
            switch result {
            case .success(let reply):
                // 只是往输入框打字（逐句口述）时不朗读，免得太吵；回复显示在提示条上。
                if let spoken = AssistantSpeech.clean(reply.text) { quiet ? self.showToast(spoken) : self.speak(spoken) }
            case .failure(.notInstalled):
                self.perform(.insert(text), target: target)
            case .failure:
                self.speak(L("assistant.unavailable"))
            }
            self.state = self.session.state
            self.transcribeNext()
        }
    }

    private func beginThinking(heard text: String) {
        thinking = true
        heard = text
        activity = nil
        turnQuiet = nil
        session.noteSpeech(now: ProcessInfo.processInfo.systemUptime)
        NSSound(named: "Tink")?.play()
    }

    private func endThinking() {
        thinking = false
        heard = nil
        activity = nil
        turnQuiet = nil
        session.noteSpeech(now: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: 助手工具的反馈与确认（由 AssistantToolbox 调用）

    /// 工具开始执行：VoiceBar 显示「→ …」。quiet：只是往输入框打字。
    func toolStarted(_ text: String, quiet: Bool) {
        session.noteSpeech(now: ProcessInfo.processInfo.systemUptime)
        guard isOn else { return }
        // 不在助手的一轮里（别的客户端调用控制接口）：只闪一下提示条。
        guard thinking else { return showToast(text) }
        activity = text
        turnQuiet = (turnQuiet ?? true) && quiet
    }

    func toolFinished() {
        session.noteSpeech(now: ProcessInfo.processInfo.systemUptime)
    }

    /// 播报确认问题并显示提示条，等最多 `window` 秒的「确认」；其他话 / 超时 / 关闭对话模式都算取消。
    func requestConfirmation(question: String, toast: String, window: TimeInterval, completion: @escaping (Bool) -> Void) {
        resolveConfirmation(false)
        pendingConfirmation = (ProcessInfo.processInfo.systemUptime + window, completion)
        // 问题之前说的话不能当作回答。
        queue = []
        AssistantDiag.log("confirm? \"\(question)\"")
        showToast(toast, duration: window)
        speak(question)
    }

    private func resolveConfirmation(_ ok: Bool) {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        AssistantDiag.log("confirm -> \(ok)")
        pending.completion(ok)
    }

    /// 等待确认时听到的话：「确认」类 → 执行；其他话 → 取消（这句话不再另作处理）。
    private func answerConfirmation(_ text: String) {
        let spoken = session.matcher.match(text) ?? text
        guard ConversationText.isMeaningful(spoken) else { return }
        let ok = ConversationCommands.parse(spoken, waiting: true) == .approve || Self.isConfirmation(spoken)
        AssistantDiag.log("heard \"\(text)\" while confirming")
        if !ok { showToast(L("assistant.toast.cancelled")) } else { toast = nil }
        resolveConfirmation(ok)
    }

    static func isConfirmation(_ text: String) -> Bool {
        let n = ConversationCommands.normalize(text)
        return ["确认关闭", "关闭", "关吧", "关掉", "关了吧", "确定", "确定关闭", "接管", "移过来", "要", "行", "对", "中断",
                "确认中断", "确认接管", "closeit", "confirm", "takeover", "sure", "doit"].contains(n)
    }

    /// 选中会话一轮完成：读记录尾部生成摘要；仍选中且没开始新一轮时播报，失败时播报 `fallback`。
    private func summarize(terminalID: UUID, fallback: String) {
        guard let host else { return speak(fallback) }
        let current = generation
        // 稍等让 agent 把最后一条消息写进记录。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.isOn, self.generation == current else { return }
            host.assistantDigest(rowID: "term:\(terminalID.uuidString)", turns: 0) { [weak self] digest in
                guard let self, self.isOn, self.generation == current else { return }
                self.assistant.summarize(digest: digest, language: Localization.currentLanguage) { [weak self] summary in
                    guard let self, self.isOn, self.generation == current,
                          self.selectedTerminalID() == terminalID else { return }
                    let status = self.statusOf(terminalID)
                    guard status != .working, status?.isWaiting != true else { return }
                    if let summary { self.lastSummaries[terminalID] = summary }
                    self.speak(summary ?? fallback)
                }
            }
        }
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
        if status.isWaiting {
            session.noteWaitingAnnounced(now: ProcessInfo.processInfo.systemUptime)
        } else if Self.summariesEnabled, host != nil {
            // 一轮完成：播报回复摘要，失败 / 超时时退回「已完成」。
            return summarize(terminalID: terminalID, fallback: text)
        }
        speak(text)
    }

    private func speak(_ text: String) {
        resumeWork?.cancel()
        setPaused(true)
        speaking = true
        capturing = false
        output.speak(text)
    }

    /// 播报结束后稍等再恢复采集（扬声器余音）。
    private func speechEnded() {
        guard !output.isSpeaking else { return }
        resumeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.output.isSpeaking else { return }
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
