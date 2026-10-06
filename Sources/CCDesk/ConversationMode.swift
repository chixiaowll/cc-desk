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
    @Published var state: ConversationSession.State = .standby
    /// 正在准备模型（下载 / 加载进度由 VoiceInput 的浮层显示）。
    @Published private(set) var preparing = false
    /// VAD 判定正在说话。
    @Published var capturing = false
    @Published var transcribing = false
    @Published private(set) var speaking = false
    /// 正在等语音助手。
    @Published var thinking = false
    /// 助手正在处理的那句话（「听到：…」）。
    @Published var heard: String?
    /// 助手正在执行的工具（「→ 往 poems 输入：…」）。
    @Published var activity: String?
    @Published private(set) var level: Float = 0
    /// 指令执行后的简短提示（已发送 / 已清空…）。
    @Published var toast: String?

    let pool: TerminalPool
    private let voice: VoiceInput
    let transcriber: Transcriber
    let selectedTerminalID: () -> UUID?
    let statusOf: (UUID) -> AgentStatus?
    private let recorder = ContinuousRecorder()
    private let output = SpeechOutput()
    let assistant: VoiceAssistant
    /// 未发送的输入与撤销记录（与助手工具共用）。
    let inputs: AssistantInputs
    /// 提供侧栏上下文、切换 / 关闭会话、读记录的对象（AppModel）。
    weak var host: AssistantHost?
    /// 选中会话最近一轮的回复摘要（作为助手的上下文）。
    var lastSummaries: [UUID: String] = [:]
    /// 等待语音确认的工具调用（关闭 / 接管 / 中断）：截止时间与回调。
    var pendingConfirmation: (deadline: TimeInterval, completion: (Bool) -> Void)?
    /// 每次开始等助手加一；迟到的回复 / 看门狗据此判断是不是同一轮。
    var thinkingTurn = 0
    var thinkingWatchdog: DispatchWorkItem?
    /// 助手一轮的超时（含语音确认）之外再留 15 秒余量。
    static let thinkingWatchdogDelay = AssistantClient.turnTimeout + 15
    /// 本轮助手调用过的工具是否都只是往输入框打字（是则不朗读回复，只显示提示条）；nil = 本轮没调用工具。
    var turnQuiet: Bool?
    /// 刚主动播报过的「某个后台会话要批准」（设计 §14）：之后的「批准 / 拒绝」作用于它，而不是选中的会话。
    var announcedApproval: AnnouncedApproval?
    /// 正在处理的这句话开始说的时刻（systemUptime），随这一轮交给助手（respond_approval 据此判断用户是否在请求出现后才说）。
    var utteranceStartedAt: TimeInterval?
    /// 正在朗读通用助手的回答（设计 §24）：「算了」会打断它。
    var speakingCompanion = false

    var session = ConversationSession()
    /// 等待识别的片段（与说话时选中的终端、开始说话的时刻 systemUptime）。
    var queue: [(samples: [Float], target: UUID?, startedAt: TimeInterval)] = []
    /// 等待语音确认时，只接受这个时刻（确认问题播报完）之后才开始说的话。
    var confirmationListenAfter: TimeInterval = 0
    private var timer: Timer?
    private var toastWork: DispatchWorkItem?
    private var resumeWork: DispatchWorkItem?
    /// 上一次观察到的选中终端及其状态，用于判断播报。
    var observed: (id: UUID, status: AgentStatus)?
    /// 每次开关递增；迟到的回调据此丢弃。
    private(set) var generation = 0

    // 以下只在 audioQueue 上使用。
    private let audioQueue = DispatchQueue(label: "cc-desk.conversation.vad")
    var vad = VoiceActivityDetector()
    private(set) var paused = false
    let levelLock = NSLock()
    var currentLevel: Float = 0

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
    var transcriptionHint: String { "用户会先说\(wakeWord)再下指令。" }

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
        // 对话模式期间随时可能听到唤醒词：识别模型常驻，不做空闲卸载。
        syncModelResidency()
        observed = nil
        voice.ensureModel { [weak self] ready in
            guard let self, self.isOn, self.generation == current else { return }
            self.preparing = false
            ready ? self.startListening() : self.turnOff()
        }
    }

    /// 把「对话模式开着」告诉识别模型（开着时常驻）。快速开关时以执行那一刻的状态为准，先后乱序也不会留错。
    private func syncModelResidency() {
        Task { @MainActor [weak self, transcriber] in
            await transcriber.setKeepLoaded(self?.isOn ?? false)
        }
    }

    func turnOff() {
        guard isOn else { return }
        generation += 1
        isOn = false
        syncModelResidency()
        preparing = false
        capturing = false
        transcribing = false
        speaking = false
        thinking = false
        thinkingWatchdog?.cancel()
        thinkingWatchdog = nil
        heard = nil
        activity = nil
        resolveConfirmation(false)
        announcedApproval = nil
        speakingCompanion = false
        // 关闭对话模式：取消通用助手排队 / 回答中的问题。
        host?.companionConversationEnded()
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
        let micLost: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == current, self.isOn else { return }
                self.voice.showHint(L("voice.hint.micUnavailable"))
                self.turnOff()
            }
        }
        recorder.start(onSamples: { [weak self] chunk in
            self?.audioQueue.async { self?.feed(chunk, generation: current) }
        }, onLost: micLost, completion: { ok in
            if !ok { micLost() }
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

    // MARK: 提示条

    func showToast(_ text: String, duration: TimeInterval = 1.8) {
        toastWork?.cancel()
        toast = text
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    // MARK: 播报

    func speak(_ text: String) {
        speakingCompanion = false
        resumeWork?.cancel()
        setPaused(true)
        speaking = true
        capturing = false
        output.speak(text)
    }

    /// 播报结束后稍等再恢复采集（扬声器余音）。
    private func speechEnded() {
        guard !output.isSpeaking else { return }
        if pendingConfirmation != nil { confirmationListenAfter = ProcessInfo.processInfo.systemUptime }
        resumeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.output.isSpeaking else { return }
            self.speaking = false
            self.speakingCompanion = false
            if self.isOn { self.setPaused(false) }
        }
        resumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// 停止朗读（「算了」打断通用助手的回答）。
    func stopSpeaking() {
        output.stop()
    }

    private func setPaused(_ value: Bool) {
        audioQueue.async { [self] in
            paused = value
            vad.reset()
        }
    }
}
