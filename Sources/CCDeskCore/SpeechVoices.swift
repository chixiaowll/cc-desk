import Foundation

/// 系统朗读声音的描述（与 AVSpeechSynthesisVoice 对应，便于在 Core 里测试排序）。
public struct SpeechVoiceInfo: Equatable, Sendable {
    public enum Quality: Int, Comparable, Sendable {
        case standard = 1
        case enhanced = 2
        case premium = 3

        public static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
    }

    public let identifier: String
    public let name: String
    /// BCP 47，如 "zh-CN"。
    public let language: String
    public let quality: Quality
    /// 趣味声音（Bells、Zarvox…）与个人声音不参与自动选择。
    public let isNovelty: Bool

    public init(identifier: String, name: String, language: String, quality: Quality, isNovelty: Bool = false) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.quality = quality
        self.isNovelty = isNovelty
    }
}

public enum SpeechVoiceRanking {
    public static let defaultsKey = "voiceSpeechVoice"

    /// 界面语言对应的首选朗读语言。
    public static func locale(forUILanguage language: String) -> String {
        language == "zh-Hans" ? "zh-CN" : "en-US"
    }

    /// 界面语言下可选的声音：首选地区（zh-CN / en-US）的声音；没有时退到同语种（zh-* / en-*）。
    /// 按音质（Premium > Enhanced > 默认）、名称排序。
    public static func candidates(_ voices: [SpeechVoiceInfo], uiLanguage: String) -> [SpeechVoiceInfo] {
        let preferred = locale(forUILanguage: uiLanguage)
        let base = String(preferred.prefix(while: { $0 != "-" }))
        let usable = voices.filter { !$0.isNovelty }
        var list = usable.filter { $0.language == preferred }
        if list.isEmpty { list = usable.filter { $0.language.hasPrefix(base + "-") || $0.language == base } }
        return list.sorted { a, b in
            if a.quality != b.quality { return a.quality > b.quality }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// 选择朗读声音：用户选过且仍已安装的优先，否则音质最好的。
    public static func best(_ voices: [SpeechVoiceInfo], uiLanguage: String, preferredID: String? = nil) -> SpeechVoiceInfo? {
        let list = candidates(voices, uiLanguage: uiLanguage)
        if let preferredID, let chosen = list.first(where: { $0.identifier == preferredID }) { return chosen }
        return list.first
    }

    /// 没有 Enhanced / Premium 声音时提示用户去下载。
    public static func needsQualityHint(_ voices: [SpeechVoiceInfo], uiLanguage: String) -> Bool {
        (candidates(voices, uiLanguage: uiLanguage).first?.quality ?? .standard) < .enhanced
    }
}
