import AppKit
import AVFoundation
import CCDeskCore

/// 语音输入：按住右 ⌥（窗口为 key 时）或按住详情区的麦克风按钮说话，松开后本机 Whisper 识别，
/// 把文字插入当前选中的内嵌终端（不回车）。只在主线程使用（因此标为 @unchecked Sendable，
/// 后台回调一律先切回主线程）；录音在独立队列，识别在 Transcriber actor 里。
final class VoiceInput: ObservableObject, @unchecked Sendable {
    enum Source { case key, mouse }

    enum Phase: Equatable {
        case idle
        /// 正在录音（浮层显示「松开结束」）。
        case recording
        /// 已松开，等待模型准备 / 识别。
        case transcribing
        /// 简短提示，几秒后自动消失。
        case hint(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// 录音电平 0...1（浮层电平条）。
    @Published private(set) var level: Float = 0
    /// 模型下载 / 加载进度；nil 表示没有在准备。
    @Published private(set) var preparing: TranscriberProgress?

    private let pool: TerminalPool
    private let selectedTerminalID: () -> UUID?
    private let canListen: () -> Bool
    private let transcriber: Transcriber
    private let recorder = AudioRecorder()
    private var hotkey = VoiceHotkey(minHold: 0.3, maxDuration: 60)
    private var source: Source?
    /// 按下时选中的终端；识别结果插入到这里（即使期间切换了选中项）。
    private var targetID: UUID?
    private var capturing = false
    private var timer: Timer?
    private var hintWork: DispatchWorkItem?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var transcribing = false
    /// 模型已加载；之后迟到的进度回调一律忽略，避免浮层卡在「加载中」。
    private var modelReady = false

    init(pool: TerminalPool, transcriber: Transcriber = WhisperTranscriber.shared,
         selectedTerminalID: @escaping () -> UUID?, canListen: @escaping () -> Bool) {
        self.pool = pool
        self.transcriber = transcriber
        self.selectedTerminalID = selectedTerminalID
        self.canListen = canListen
    }

    var isRecording: Bool { phase == .recording }

    // MARK: 键盘监听

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.apply(self?.hotkey.escape() ?? .none)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            switch VoiceKey.classify(keyCode: event.keyCode, flags: event.modifierFlags.rawValue) {
            case .rightOptionDown:
                if !hotkey.isHolding, canListen() { press(.key) }
            case .rightOptionUp:
                if source == .key { release() }
            case .otherModifier:
                if hotkey.isHolding, source == .key { apply(hotkey.interrupt()) }
            }
        case .keyDown:
            guard hotkey.isHolding else { return event }
            if event.keyCode == 53 { // Esc：取消录音，且不把 Esc 发给终端
                apply(hotkey.escape())
                return nil
            }
            // 按住右 ⌥ 时按了别的键：是在用 ⌥ 组合键（Meta），放行并放弃录音。
            if source == .key { apply(hotkey.interrupt()) }
        default:
            if hotkey.isHolding, source == .key { apply(hotkey.interrupt()) }
        }
        return event
    }

    // MARK: 麦克风按钮

    func mousePressed() {
        guard !hotkey.isHolding else { return }
        press(.mouse)
        if capturing { // 鼠标按住立即显示，不必等 0.3s
            phase = .recording
            warmUp()
        }
    }

    func mouseReleased() {
        guard source == .mouse else { return }
        release()
    }

    // MARK: 预先下载

    func predownload() {
        guard preparing == nil else { return }
        Task { @MainActor [weak self, transcriber] in
            do {
                try await transcriber.prepare(progress: self?.progressSink ?? { @Sendable _ in })
                self?.modelReady = true
                self?.preparing = nil
                self?.showHint("语音模型已就绪")
            } catch {
                self?.preparing = nil
                self?.showHint("语音模型下载失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: 状态机

    private func press(_ from: Source) {
        guard !transcribing else {
            if from == .mouse { showHint("正在识别上一段…") }
            return
        }
        source = from
        apply(hotkey.press(at: ProcessInfo.processInfo.systemUptime))
    }

    private func release() {
        apply(hotkey.release(at: ProcessInfo.processInfo.systemUptime))
    }

    private func apply(_ action: VoiceHotkey.Action) {
        switch action {
        case .none:
            break
        case .beginCapture:
            beginCapture()
        case .reveal:
            guard capturing, phase != .recording else { break }
            phase = .recording
            // 确认是在说话（而不是把 ⌥ 当 Meta 用）后，边说边准备模型（首次下载 / 加载较慢）。
            warmUp()
        case .finish:
            finish()
        case .discard:
            let wasMouse = source == .mouse
            stopCapture(keep: false)
            phase = .idle
            if wasMouse { showHint("按住说话，松开结束") }
        case .cancel:
            stopCapture(keep: false)
            phase = .idle
        }
    }

    private func beginCapture() {
        hintWork?.cancel()
        if case .hint = phase { phase = .idle }
        targetID = selectedTerminalID()
        capturing = targetID != nil && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if capturing {
            level = 0
            recorder.start()
        }
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        if capturing { level = recorder.level }
        apply(hotkey.tick(at: ProcessInfo.processInfo.systemUptime))
    }

    private func stopCapture(keep: Bool, completion: (([Float]) -> Void)? = nil) {
        timer?.invalidate()
        timer = nil
        source = nil
        level = 0
        if capturing {
            capturing = false
            recorder.stop { samples in completion?(keep ? samples : []) }
        } else {
            completion?([])
        }
    }

    private func finish() {
        let wasCapturing = capturing
        let target = targetID
        if wasCapturing {
            phase = .transcribing
            transcribing = true
        }
        stopCapture(keep: true) { [weak self] samples in
            self?.transcribe(samples, into: target)
        }
        guard !wasCapturing else { return }
        phase = .idle
        guard target != nil else {
            showHint("请先选择一个内嵌 session")
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { [weak self] in
                    self?.showHint(granted ? "已允许麦克风，请再次按住说话" : "未获得麦克风权限")
                }
            }
        case .denied, .restricted:
            alertMicrophoneDenied()
        default:
            break
        }
    }

    private func transcribe(_ samples: [Float], into target: UUID?) {
        guard let target, samples.count >= AudioRecorder.sampleRate * 3 / 10 else {
            if transcribing {
                transcribing = false
                phase = .idle
            }
            return
        }
        phase = .transcribing
        transcribing = true
        Task { @MainActor [weak self, transcriber] in
            let result: Result<String, Error>
            do {
                try await transcriber.prepare(progress: self?.progressSink ?? { @Sendable _ in })
                self?.modelReady = true
                self?.preparing = nil
                result = .success(try await transcriber.transcribe(samples))
            } catch {
                result = .failure(error)
            }
            self?.deliver(result, to: target)
        }
    }

    private func deliver(_ result: Result<String, Error>, to target: UUID) {
        transcribing = false
        preparing = nil
        phase = .idle
        switch result {
        case .success(let text):
            guard !text.isEmpty else { return showHint("没有识别到内容") }
            guard let terminal = pool.terminal(target) else { return showHint("目标 session 已关闭") }
            terminal.send(text: text, submit: false)
        case .failure(let error):
            showHint("语音识别失败：\(error.localizedDescription)")
        }
    }

    private func warmUp() {
        Task { @MainActor [weak self, transcriber] in
            do {
                try await transcriber.prepare(progress: self?.progressSink ?? { @Sendable _ in })
                self?.modelReady = true
            } catch {
                // 失败时由松开后的识别流程重试并提示。
            }
            if self?.transcribing == false { self?.preparing = nil }
        }
    }

    /// 模型准备进度回调（可能来自后台），切回主线程更新 `preparing`。
    private var progressSink: @Sendable (TranscriberProgress) -> Void {
        { [weak self] p in self?.setPreparing(p) }
    }

    private func setPreparing(_ progress: TranscriberProgress) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.modelReady else { return }
            self.preparing = progress
        }
    }

    private func showHint(_ text: String) {
        hintWork?.cancel()
        phase = .hint(text)
        let work = DispatchWorkItem { [weak self] in
            if case .hint = self?.phase { self?.phase = .idle }
        }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    private func alertMicrophoneDenied() {
        let alert = NSAlert()
        alert.messageText = "无法使用麦克风"
        alert.informativeText = "请在「系统设置 → 隐私与安全性 → 麦克风」中允许 CC Desk。语音识别完全在本机完成。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "好")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// AVAudioEngine 输入 -> 16 kHz 单声道 Float32，存在内存里（不落盘），最长 60 秒。
/// start / stop 在专用串行队列上执行，不阻塞主线程。
final class AudioRecorder {
    static let sampleRate = 16_000
    static let maxSamples = sampleRate * 60

    private let queue = DispatchQueue(label: "cc-desk.voice.audio")
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private var currentLevel: Float = 0

    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return currentLevel
    }

    func start() {
        queue.async { [self] in
            lock.lock()
            samples = []
            samples.reserveCapacity(Self.sampleRate * 10)
            currentLevel = 0
            lock.unlock()

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let inFormat = input.outputFormat(forBus: 0)
            guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
                  let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.sampleRate),
                                                channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return }
            let ratio = outFormat.sampleRate / inFormat.sampleRate
            input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
                guard let self, let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
                var fed = false
                var error: NSError?
                converter.convert(to: out, error: &error) { _, status in
                    if fed {
                        status.pointee = .noDataNow
                        return nil
                    }
                    fed = true
                    status.pointee = .haveData
                    return buffer
                }
                guard error == nil, let data = out.floatChannelData?[0] else { return }
                self.append(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
            }
            do {
                engine.prepare()
                try engine.start()
                self.engine = engine
            } catch {
                input.removeTap(onBus: 0)
            }
        }
    }

    /// 停止录音，在主线程回调采样。
    func stop(completion: @escaping ([Float]) -> Void) {
        queue.async { [self] in
            if let engine {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            engine = nil
            lock.lock()
            let result = samples
            samples = []
            currentLevel = 0
            lock.unlock()
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func append(_ chunk: UnsafeBufferPointer<Float>) {
        guard !chunk.isEmpty else { return }
        var sum: Float = 0
        for value in chunk { sum += value * value }
        let rms = (sum / Float(chunk.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-6))
        let level = min(1, max(0, (db + 50) / 45))
        lock.lock()
        let room = Self.maxSamples - samples.count
        if room > 0 { samples.append(contentsOf: chunk.prefix(room)) }
        currentLevel = currentLevel * 0.4 + level * 0.6
        lock.unlock()
    }
}
