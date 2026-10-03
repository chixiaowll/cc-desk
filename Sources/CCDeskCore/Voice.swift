import Foundation

/// 「按住说话」状态机（键盘右 ⌥ 与麦克风按钮共用）。纯逻辑，时间由调用方传入。
///
/// - 按下即开始采音（`beginCapture`），避免丢掉开头的字；按住满 `minHold` 后才显示录音浮层（`reveal`）。
/// - 不足 `minHold` 就松开，或按住期间按了其他键 / 改变了其他修饰键（说明是把 ⌥ 当 Meta 用），丢弃（`discard`）。
/// - 按住期间按 Esc 取消（`cancel`）；超过 `maxDuration` 自动结束（`finish`），随后的松开不再触发。
public struct VoiceHotkey: Equatable {
    public enum Action: Equatable {
        case none
        case beginCapture
        case reveal
        case finish
        case discard
        case cancel
    }

    public let minHold: TimeInterval
    public let maxDuration: TimeInterval
    private var pressedAt: TimeInterval?
    private var revealed = false

    public init(minHold: TimeInterval = 0.3, maxDuration: TimeInterval = 60) {
        self.minHold = minHold
        self.maxDuration = maxDuration
    }

    public var isHolding: Bool { pressedAt != nil }

    public mutating func press(at time: TimeInterval) -> Action {
        guard pressedAt == nil else { return .none }
        pressedAt = time
        revealed = false
        return .beginCapture
    }

    public mutating func tick(at time: TimeInterval) -> Action {
        guard let start = pressedAt else { return .none }
        let elapsed = time - start
        if elapsed >= maxDuration {
            reset()
            return .finish
        }
        if !revealed && elapsed >= minHold {
            revealed = true
            return .reveal
        }
        return .none
    }

    public mutating func release(at time: TimeInterval) -> Action {
        guard let start = pressedAt else { return .none }
        reset()
        return time - start >= minHold ? .finish : .discard
    }

    /// 按住期间出现了其他按键 / 修饰键 / 鼠标点击。
    public mutating func interrupt() -> Action {
        guard pressedAt != nil else { return .none }
        reset()
        return .discard
    }

    public mutating func escape() -> Action {
        guard pressedAt != nil else { return .none }
        reset()
        return .cancel
    }

    private mutating func reset() {
        pressedAt = nil
        revealed = false
    }
}

/// 把 `flagsChanged` 事件（keyCode + 原始 modifierFlags）归类：右 ⌥ 单独按下 / 右 ⌥ 松开 / 其他修饰键变化。
public enum VoiceKey: Equatable {
    case rightOptionDown
    case rightOptionUp
    case otherModifier

    public static let rightOptionKeyCode: UInt16 = 61
    /// NX_DEVICELALTKEYMASK / NX_DEVICERALTKEYMASK
    static let leftOptionBit: UInt = 0x20
    static let rightOptionBit: UInt = 0x40
    /// shift / control / command / function（不含 capsLock、numericPad、option 本身）。
    static let blockingModifiers: UInt = (1 << 17) | (1 << 18) | (1 << 20) | (1 << 23)

    public static func classify(keyCode: UInt16, flags: UInt) -> VoiceKey {
        guard keyCode == rightOptionKeyCode else { return .otherModifier }
        guard flags & rightOptionBit != 0 else { return .rightOptionUp }
        if flags & leftOptionBit != 0 || flags & blockingModifiers != 0 { return .otherModifier }
        return .rightOptionDown
    }
}

/// Whisper 识别结果后处理：去掉特殊 token / 非语音标注 / 常见幻觉字幕，繁转简，整理空白，合并重复。
public enum TranscriptCleaner {
    /// 归一化（去标点空白、小写）后整句相等即丢弃。
    static let hallucinations: Set<String> = [
        "谢谢观看", "感谢观看", "谢谢大家观看", "谢谢收看", "感谢收看",
        "请订阅", "请订阅我的频道", "点赞订阅",
        "thankyouforwatching", "thanksforwatching", "pleasesubscribe", "thankyou",
    ]
    /// 归一化后包含即丢弃（足够独特、不会出现在正常口述里的片段）。
    static let hallucinationFragments = [
        "明镜与点点", "请不吝点赞", "amaraorg", "字幕志愿者", "字幕由", "字幕制作", "中文字幕",
    ]
    /// 括号里出现这些词时视为非语音标注，整段删除；其他括号保留（如 `foo(bar)`）。
    static let annotationKeywords = ["字幕", "音乐", "掌声", "笑声", "鼓掌", "music", "applause", "laughter", "silence"]

    public static func clean(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        // 截断的多字节 token 会解码成替换字符 U+FFFD。
        text = text.replacingOccurrences(of: "\u{FFFD}", with: "")
        text = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text

        var lines: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = stripAnnotations(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !isHallucination(line) else { continue }
            if lines.last != line { lines.append(line) }
        }

        var joined = ""
        for line in lines {
            if let last = joined.unicodeScalars.last, let first = line.unicodeScalars.first,
               !(isCJK(last) && isCJK(first)) {
                joined += " "
            }
            joined += line
        }
        joined = collapseWhitespace(joined)
        return dedupeSentences(joined).trimmingCharacters(in: .whitespaces)
    }

    static func stripAnnotations(_ line: String) -> String {
        var s = line.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"【[^】]*】"#, with: " ", options: .regularExpression)
        for pattern in [#"\([^)]*\)"#, #"（[^）]*）"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = s as NSString
            var result = ""
            var cursor = 0
            for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                let inner = ns.substring(with: match.range).lowercased()
                guard annotationKeywords.contains(where: inner.contains) else { continue }
                result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)) + " "
                cursor = match.range.location + match.range.length
            }
            result += ns.substring(from: cursor)
            s = result
        }
        return s
    }

    static func normalized(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func isHallucination(_ s: String) -> Bool {
        let n = normalized(s)
        guard !n.isEmpty else { return true }
        return hallucinations.contains(n) || hallucinationFragments.contains(where: n.contains)
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF: return true
        default: return false
        }
    }

    /// 连续空白合并为一个空格；两侧都是中日韩字符 / 全角标点时删除空白。
    static func collapseWhitespace(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if CharacterSet.whitespacesAndNewlines.contains(c) {
                var j = i
                while j < scalars.count, CharacterSet.whitespacesAndNewlines.contains(scalars[j]) { j += 1 }
                if let prev = out.last, j < scalars.count, !(isCJK(prev) && isCJK(scalars[j])) {
                    out.append(" ")
                }
                i = j
            } else {
                out.append(c)
                i += 1
            }
        }
        return String(out)
    }

    /// 按句末标点切句，丢弃幻觉句并合并连续重复的句子（Whisper 常见的循环输出）。
    static func dedupeSentences(_ s: String) -> String {
        let terminators: Set<Character> = ["。", "！", "？", "!", "?"]
        var sentences: [String] = []
        var current = ""
        for ch in s {
            current.append(ch)
            if terminators.contains(ch) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty { sentences.append(current) }

        var kept: [String] = []
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !isHallucination(trimmed) else { continue }
            if let last = kept.last, last.trimmingCharacters(in: .whitespaces) == trimmed { continue }
            kept.append(sentence)
        }
        return kept.joined()
    }
}
