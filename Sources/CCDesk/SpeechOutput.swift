import AVFoundation
import CCDeskCore

/// 朗读出口：选了自然语音且服务已就绪时用它；没装 / 还在加载 / 出错 / 2.5 秒内没出声时用系统声音
/// （AVSpeechSynthesizer），保证不会沉默。新的一句会打断正在读的。只在主线程使用。
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
    enum Route: Equatable { case natural, system }

    /// 自然语音多久没出声就改用系统声音。
    static let fallbackDelay: TimeInterval = 2.5

    /// 开始出声（自然语音：第一块音频排进播放队列；系统声音：开始朗读）。
    var onStart: ((Route) -> Void)?
    /// 一段朗读结束（读完或被打断）；调用方用 `isSpeaking` 判断是否还有别的在读。
    var onFinish: (() -> Void)?
    /// 测试用：静音（系统声音音量 0）。
    var muted = false

    private(set) var lastRoute: Route?
    var isSpeaking: Bool { naturalActive || synthesizer.isSpeaking }

    private let synthesizer = AVSpeechSynthesizer()
    private let engine: NaturalSpeechEngine
    private var token = 0
    private var naturalActive = false
    private var fallbackWork: DispatchWorkItem?

    init(engine: NaturalSpeechEngine = .shared) {
        self.engine = engine
        super.init()
        synthesizer.delegate = self
    }

    /// waitForNatural：自然语音还没就绪时最多等多久（试听用）；0 = 不等，直接用系统声音并在后台加载。
    func speak(_ text: String, waitForNatural: TimeInterval = 0) {
        stop(notify: false)
        token += 1
        let current = token
        let spoken = SpeechText.normalize(text, language: SpeechText.language(of: text))
        guard !spoken.isEmpty else { return finished() }
        guard NaturalVoice.isSelected else { return speakSystem(spoken) }
        if engine.state == .ready { return speakNatural(spoken, token: current) }
        guard waitForNatural > 0 else {
            engine.start()
            return speakSystem(spoken)
        }
        naturalActive = true
        engine.whenReady(timeout: waitForNatural) { [weak self] ok in
            guard let self, self.token == current else { return }
            self.naturalActive = false
            ok ? self.speakNatural(spoken, token: current) : self.speakSystem(spoken)
        }
    }

    func stop() {
        stop(notify: true)
    }

    private func stop(notify: Bool) {
        token += 1
        fallbackWork?.cancel()
        let wasNatural = naturalActive
        naturalActive = false
        if wasNatural { engine.stop() }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        if wasNatural, notify { DispatchQueue.main.async { [weak self] in self?.onFinish?() } }
    }

    private func speakNatural(_ text: String, token current: Int) {
        let sentences = SpeechText.sentences(text)
        let lang = NaturalVoiceProtocol.langCode(forUILanguage: SpeechText.language(of: text))
        naturalActive = true
        lastRoute = .natural
        let ok = engine.speak(sentences: sentences, lang: lang, onAudio: { [weak self] in
            guard let self, self.token == current else { return }
            self.fallbackWork?.cancel()
            self.onStart?(.natural)
        }, onDone: { [weak self] outcome in
            guard let self, self.token == current else { return }
            self.fallbackWork?.cancel()
            self.naturalActive = false
            switch outcome {
            case .failed:
                AssistantDiag.log("natural voice failed, falling back to the system voice")
                self.speakSystem(text)
            case .finished, .cancelled:
                self.finished()
            }
        })
        guard ok else {
            naturalActive = false
            return speakSystem(text)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.token == current, self.naturalActive else { return }
            AssistantDiag.log("natural voice: no audio after \(Self.fallbackDelay)s, falling back")
            // 先换 token，engine.stop() 回调的 .cancelled 就不会当成读完。
            self.token += 1
            self.naturalActive = false
            self.engine.stop()
            self.speakSystem(text)
        }
        fallbackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fallbackDelay, execute: work)
    }

    private func speakSystem(_ text: String) {
        lastRoute = .system
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = SpeechVoices.current()
        if muted { utterance.volume = 0 }
        synthesizer.speak(utterance)
    }

    private func finished() {
        DispatchQueue.main.async { [weak self] in self?.onFinish?() }
    }

    // MARK: AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.onStart?(.system) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.onFinish?() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.onFinish?() }
    }
}
