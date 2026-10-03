import Foundation

// MARK: - 端点检测（VAD）

/// 对话模式的语音端点检测：按 30ms 帧计算能量（dBFS），与滚动噪声底比较判定语音帧。
///
/// - 连续 `startFrames` 帧语音才算开始（单个咔哒声不触发），片段带 `preRoll` 的前置音频，避免吞掉开头。
/// - 连续 `endSilence` 静音后结束；语音不足 `minSpeech` 的丢弃（`discarded`），超过 `maxUtterance` 强制切段。
/// - 噪声底取最近 `noiseWindow` 内的最小帧能量（说话有停顿，最小值≈环境噪声），稳态噪声（风扇、空调）会被
///   逐渐当作背景；开头 `calibration` 时长只用来估计噪声底，不做判定。
/// 纯逻辑、与音频设备无关；调用方保证在单一线程 / 队列上使用。
public struct VoiceActivityDetector {
    public struct Config: Equatable {
        public var sampleRate = 16_000
        public var frameLength = 480
        public var startFrames = 3
        public var endSilence: TimeInterval = 1.0
        public var minSpeech: TimeInterval = 0.4
        public var maxUtterance: TimeInterval = 30
        public var preRoll: TimeInterval = 0.3
        public var trailing: TimeInterval = 0.3
        public var minThresholdDB: Float = -45
        public var noiseMarginDB: Float = 12
        public var noiseWindow: TimeInterval = 3
        public var calibration: TimeInterval = 0.3

        public init() {}
    }

    public enum Event: Equatable {
        case speechStarted
        /// 一段完整语音（16 kHz 单声道），含前置与少量尾部静音。
        case utterance([Float])
        /// 已开始但语音太短，丢弃。
        case discarded
    }

    public let config: Config
    private var pending: [Float] = []
    private var history: [Float] = []
    private var utterance: [Float] = []
    private var active = false
    private var candidateFrames = 0
    private var silenceFrames = 0
    private var speechStart = 0
    private var lastSpeechEnd = 0
    private var noise: [Float] = []
    private var noiseIndex = 0
    private var framesSeen = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    public var isSpeaking: Bool { active }

    private var frameDuration: TimeInterval { Double(config.frameLength) / Double(config.sampleRate) }
    private func samples(_ seconds: TimeInterval) -> Int { Int(seconds * Double(config.sampleRate)) }

    /// 放弃进行中的片段（保留噪声估计），如播报语音时暂停采集。
    public mutating func reset() {
        pending = []
        history = []
        utterance = []
        active = false
        candidateFrames = 0
        silenceFrames = 0
    }

    public mutating func process(_ chunk: [Float]) -> [Event] {
        pending += chunk
        var events: [Event] = []
        var offset = 0
        while pending.count - offset >= config.frameLength {
            let frame = Array(pending[offset..<offset + config.frameLength])
            offset += config.frameLength
            if let event = processFrame(frame) { events.append(event) }
        }
        pending.removeFirst(offset)
        return events
    }

    public static func decibels(_ frame: ArraySlice<Float>) -> Float {
        guard !frame.isEmpty else { return -100 }
        var sum: Float = 0
        for v in frame { sum += v * v }
        let rms = (sum / Float(frame.count)).squareRoot()
        return 20 * log10(max(rms, 1e-5))
    }

    private mutating func processFrame(_ frame: [Float]) -> Event? {
        let db = Self.decibels(frame[...])
        let calibrated = Double(framesSeen) * frameDuration >= config.calibration
        let floor = noise.min() ?? -100
        let loud = calibrated && db > max(config.minThresholdDB, floor + config.noiseMarginDB)
        recordNoise(db)
        framesSeen += 1

        guard active else {
            history += frame
            let keep = samples(config.preRoll) + config.startFrames * config.frameLength
            if history.count > keep { history.removeFirst(history.count - keep) }
            candidateFrames = loud ? candidateFrames + 1 : 0
            guard candidateFrames >= config.startFrames else { return nil }
            active = true
            utterance = history
            history = []
            speechStart = utterance.count - candidateFrames * config.frameLength
            lastSpeechEnd = utterance.count
            silenceFrames = 0
            return .speechStarted
        }

        utterance += frame
        if loud {
            lastSpeechEnd = utterance.count
            silenceFrames = 0
        } else {
            silenceFrames += 1
        }
        if Double(silenceFrames) * frameDuration >= config.endSilence - 1e-9 {
            return finish()
        }
        if utterance.count - speechStart >= samples(config.maxUtterance) {
            return finish()
        }
        return nil
    }

    private mutating func finish() -> Event {
        let speech = Double(lastSpeechEnd - speechStart) / Double(config.sampleRate)
        let end = min(utterance.count, lastSpeechEnd + samples(config.trailing))
        let event: Event = speech < config.minSpeech ? .discarded : .utterance(Array(utterance[..<end]))
        history = Array(utterance.suffix(samples(config.preRoll)))
        utterance = []
        active = false
        candidateFrames = 0
        silenceFrames = 0
        return event
    }

    private mutating func recordNoise(_ db: Float) {
        let capacity = max(1, Int(config.noiseWindow / frameDuration))
        if noise.count < capacity {
            noise.append(db)
        } else {
            noise[noiseIndex] = db
            noiseIndex = (noiseIndex + 1) % capacity
        }
    }
}

// MARK: - 语音指令

public enum ConversationCommand: Equatable, Sendable {
    case send
    case cancel
    case stop
    case approve
    case deny
    /// 回到待命（常驻模式下结束这一轮对话，需要再次唤醒）。
    case rest
    /// 撤销上一个可撤销的动作（设计 §13）。
    case undo
}

/// 把整句识别结果解析成指令（整句匹配，容忍标点、首尾语气词）。批准 / 拒绝只在 agent 等批准时生效。
public enum ConversationCommands {
    static let send: Set<String> = ["发送", "发出去", "发出", "提交", "发送出去", "送出", "发送给他", "发送给它", "发给他", "发给它",
                                         "发过去", "发吧", "发出去给他", "send", "sendit", "submit", "sendittoit"]
    static let cancel: Set<String> = ["取消", "清空", "算了", "清除", "cancel", "clear", "clearit", "nevermind"]
    static let stop: Set<String> = [
        "退出对话模式", "停止对话", "退出对话", "结束对话", "关闭对话模式", "停止对话模式", "停止聆听", "停止监听",
        "stoplistening", "exitconversationmode", "stopconversation", "endconversation", "stopconversationmode",
    ]
    static let rest: Set<String> = [
        "休息一下", "休息", "你先休息", "先休息", "待命", "先这样", "没事了", "去休息", "你休息",
        "rest", "standby", "thatsall", "gotosleep",
    ]
    static let undo: Set<String> = [
        "撤销", "撤回", "撤销上一步", "撤销刚才的", "撤销刚才的操作", "撤回刚才的", "撤回上一步", "撤销一下", "撤回一下",
        "undo", "undothat", "undoit", "undolast",
    ]
    static let approve: Set<String> = [
        "同意", "可以", "好的", "是", "确认", "是的", "允许", "批准", "可以的", "好",
        "yes", "yeah", "yep", "approve", "approved", "allow", "ok", "okay",
    ]
    static let deny: Set<String> = ["拒绝", "不行", "不要", "否", "不可以", "不同意", "不允许", "no", "nope", "deny", "reject"]

    static let leading = ["嗯", "呃", "额", "那就", "那么", "那", "就", "请", "好", "ok", "okay", "please"]
    static let trailing = ["吧", "了", "啊", "呀", "吗", "嘛", "啦", "哦", "喔", "呢", "哈", "please", "now"]

    public static func parse(_ transcript: String, waiting: Bool) -> ConversationCommand? {
        for candidate in candidates(normalize(transcript)) {
            if send.contains(candidate) { return .send }
            if cancel.contains(candidate) { return .cancel }
            if stop.contains(candidate) { return .stop }
            if rest.contains(candidate) { return .rest }
            if undo.contains(candidate) { return .undo }
            if waiting, approve.contains(candidate) { return .approve }
            if waiting, deny.contains(candidate) { return .deny }
        }
        return nil
    }

    /// 繁转简、小写，只保留字母数字（含汉字）。
    public static func normalize(_ s: String) -> String {
        let simplified = s.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? s
        return TranscriptCleaner.normalized(simplified)
    }

    /// 原句，以及逐步去掉首尾语气词后的各个版本（去掉后不能为空）。
    static func candidates(_ normalized: String) -> [String] {
        guard !normalized.isEmpty else { return [] }
        var out = [normalized]
        var queue = [normalized]
        while let s = queue.popLast() {
            for prefix in leading where s.hasPrefix(prefix) && s.count > prefix.count {
                let next = String(s.dropFirst(prefix.count))
                if !out.contains(next) { out.append(next); queue.append(next) }
            }
            for suffix in trailing where s.hasSuffix(suffix) && s.count > suffix.count {
                let next = String(s.dropLast(suffix.count))
                if !out.contains(next) { out.append(next); queue.append(next) }
            }
        }
        return out
    }
}

// MARK: - 插入文本

public enum ConversationText {
    static let fillerScalars: Set<Character> = ["嗯", "啊", "呃", "额", "哦", "唔", "噢", "哎", "诶", "欸"]
    static let englishFillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "hm", "hmm", "mm", "mhm", "ah", "oh", "er", "erm"]

    /// 去掉标点空白后非空，且不只是语气词（嗯 / 啊 / um / uh…）。
    public static func isMeaningful(_ text: String) -> Bool {
        let n = TranscriptCleaner.normalized(text)
        guard !n.isEmpty else { return false }
        if n.allSatisfy(fillerScalars.contains) { return false }
        return !englishFillers.contains(n)
    }

    /// 追加到已插入文本 `previous` 之后时的实际内容：两侧不都是中日韩字符且前面没有空白时加一个空格。
    public static func insertion(_ text: String, after previous: String) -> String {
        guard let last = previous.unicodeScalars.last, let first = text.unicodeScalars.first else { return text }
        if CharacterSet.whitespacesAndNewlines.contains(last) { return text }
        if TranscriptCleaner.isCJK(last) && TranscriptCleaner.isCJK(first) { return text }
        return " " + text
    }
}

// MARK: - 唤醒词

/// 唤醒词模糊匹配：按拼音比较（Whisper 常把人名听成同音字），允许小的编辑距离和开头的语气词。
public struct WakeWordMatcher: Equatable {
    public let wakeWord: String
    let target: String
    let maxDistance: Int

    static let fillers = ["那个", "这个", "嗯", "呃", "额", "啊", "喂", "嘿", "hey", "hi", "ok", "okay"]
    static let separators = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).union(.symbols)

    public init(wakeWord: String) {
        self.wakeWord = wakeWord
        target = Self.pinyin(wakeWord)
        maxDistance = min(2, target.count / 5)
    }

    /// 匹配时返回唤醒词之后的原文（去掉开头标点空白，可能为空）；不以唤醒词开头时返回 nil。
    public func match(_ transcript: String) -> String? {
        guard !target.isEmpty else { return nil }
        let simplified = transcript.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? transcript
        var text = Substring(simplified)
        while true {
            text = Self.trimSeparators(text)
            if let rest = matchPrefix(text) { return String(Self.trimSeparators(rest)) }
            guard let filler = Self.fillers.first(where: { text.lowercased().hasPrefix($0) }) else { return nil }
            text = text.dropFirst(filler.count)
        }
    }

    /// 逐个字符累积拼音，找与目标编辑距离最小（≤ maxDistance）的前缀；距离相同取更短的前缀。
    private func matchPrefix(_ text: Substring) -> Substring? {
        var accumulated = ""
        var best: (distance: Int, end: Substring.Index)?
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            index = text.index(after: index)
            let piece = Self.pinyin(String(ch))
            guard !piece.isEmpty else { continue }
            accumulated += piece
            if accumulated.count > target.count + maxDistance { break }
            guard accumulated.count >= target.count - maxDistance else { continue }
            let d = Self.editDistance(accumulated, target)
            if d <= maxDistance, best.map({ d < $0.distance }) ?? true { best = (d, index) }
        }
        return best.map { text[$0.end...] }
    }

    static func trimSeparators(_ s: Substring) -> Substring {
        var s = s
        while let first = s.unicodeScalars.first, separators.contains(first) { s = s.dropFirst() }
        return s
    }

    /// 汉字 -> 无声调拼音，小写，只保留 a-z0-9。
    static func pinyin(_ s: String) -> String {
        let latin = s.applyingTransform(.toLatin, reverse: false) ?? s
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return String(plain.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
            .map(Character.init))
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

// MARK: - 对话会话（待命 / 对话中）

public enum ConversationAction: Equatable, Sendable {
    /// 听到唤醒词，进入对话中。
    case wake
    /// 追加到输入框（不发送）。
    case insert(String)
    /// 本地规则没命中：交给语音助手（意图模型）判断。
    case assist(String)
    case send
    case cancel
    /// 关闭对话模式。
    case stop
    case approve
    case deny
    /// 回到待命。
    case standby
    /// 撤销上一个可撤销的动作。
    case undo
}

/// 对话模式的状态机：待命时只听唤醒词（以及刚播报过「需要批准」时的批准 / 拒绝），唤醒后逐句追加、执行指令；
/// 发送 / 取消 / 超过 `idleTimeout` 没说话后回到待命。纯逻辑，时间由调用方传入。
public struct ConversationSession: Equatable {
    public enum State: Equatable, Sendable {
        case standby
        case active
    }

    public enum TranscriptionPolicy: Equatable {
        /// 识别整段。
        case full
        /// 待命时的长片段：先只识别开头这么多秒检查唤醒词，命中再识别整段。
        case prefixThenFull(TimeInterval)
    }

    public static let defaultWakeWord = "嬴政同学"
    public static let wakeWordDefaultsKey = "voiceWakeWord"

    public private(set) var state: State = .standby
    public let matcher: WakeWordMatcher
    public let idleTimeout: TimeInterval
    public let approvalWindow: TimeInterval
    public let wakeSegmentMax: TimeInterval
    public let wakePrefix: TimeInterval
    /// 对话中没命中本地指令的话交给语音助手（`.assist`），否则直接插入（`.insert`）。
    public var routesToAssistant = false
    /// 常驻：唤醒后一直保持对话（不超时、发送 / 取消后不回待命），说「休息一下」才回到待命。
    public var persistent = false
    private var lastActivity: TimeInterval = 0
    private var waitingAnnouncedAt: TimeInterval?

    public init(wakeWord: String = ConversationSession.defaultWakeWord, idleTimeout: TimeInterval = 30,
                approvalWindow: TimeInterval = 120, wakeSegmentMax: TimeInterval = 4, wakePrefix: TimeInterval = 3) {
        matcher = WakeWordMatcher(wakeWord: wakeWord)
        self.idleTimeout = idleTimeout
        self.approvalWindow = approvalWindow
        self.wakeSegmentMax = wakeSegmentMax
        self.wakePrefix = wakePrefix
    }

    public var wakeWord: String { matcher.wakeWord }

    public mutating func reset() {
        state = .standby
        waitingAnnouncedAt = nil
    }

    /// 回到待命（如助手执行了发送 / 取消）。
    public mutating func standby() {
        state = .standby
    }

    /// 发送 / 取消之后：非常驻时回到待命。返回是否回到了待命。
    @discardableResult
    public mutating func finishTurn() -> Bool {
        guard !persistent else { return false }
        state = .standby
        return true
    }

    /// 检测到有人在说话（对话中时推迟超时）。
    public mutating func noteSpeech(now: TimeInterval) {
        if state == .active { lastActivity = now }
    }

    /// 刚用语音播报了「需要批准」。
    public mutating func noteWaitingAnnounced(now: TimeInterval) {
        waitingAnnouncedAt = now
    }

    public mutating func tick(now: TimeInterval) -> [ConversationAction] {
        guard state == .active, !persistent, now - lastActivity >= idleTimeout else { return [] }
        state = .standby
        return [.standby]
    }

    public func transcriptionPolicy(duration: TimeInterval) -> TranscriptionPolicy {
        state == .standby && duration > wakeSegmentMax ? .prefixThenFull(wakePrefix) : .full
    }

    /// waiting：选中 session 正在等批准。
    public mutating func handle(transcript: String, waiting: Bool, now: TimeInterval) -> [ConversationAction] {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = matcher.match(text)
        switch state {
        case .standby:
            if let rest {
                state = .active
                lastActivity = now
                return [.wake] + process(rest, waiting: waiting)
            }
            guard waiting, let at = waitingAnnouncedAt, now - at <= approvalWindow,
                  let command = ConversationCommands.parse(text, waiting: true),
                  command == .approve || command == .deny else { return [] }
            return [command == .approve ? .approve : .deny]
        case .active:
            lastActivity = now
            return process(rest ?? text, waiting: waiting)
        }
    }

    private mutating func process(_ text: String, waiting: Bool) -> [ConversationAction] {
        guard ConversationText.isMeaningful(text) else { return [] }
        switch ConversationCommands.parse(text, waiting: waiting) {
        case .send?:
            return finishTurn() ? [.send, .standby] : [.send]
        case .cancel?:
            return finishTurn() ? [.cancel, .standby] : [.cancel]
        case .rest?:
            state = .standby
            return [.standby]
        case .stop?:
            state = .standby
            return [.stop]
        case .approve?:
            return [.approve]
        case .deny?:
            return [.deny]
        case .undo?:
            return [.undo]
        case nil:
            return [routesToAssistant ? .assist(text) : .insert(text)]
        }
    }
}

// MARK: - 语音播报

/// 对话模式下的简短状态播报（只播报选中的 session）：转为等批准 / 一轮完成。
public enum SpokenStatus {
    public static let reasonLimit = 40

    public static func announcement(previous: AgentStatus?, current: AgentStatus) -> String? {
        guard let previous else { return nil }
        if case .waiting(let reason) = current, !previous.isWaiting {
            guard let short = shorten(reason) else { return L("speech.needsApproval") }
            return L("speech.needsApprovalReason", short)
        }
        if current == .idle, previous == .working { return L("speech.done") }
        return nil
    }

    public static func shorten(_ reason: String?) -> String? {
        guard let line = reason?.components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespaces), !line.isEmpty else { return nil }
        return line.count > reasonLimit ? String(line.prefix(reasonLimit - 1)) + "…" : line
    }
}
