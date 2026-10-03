import AVFoundation
import CCDeskCore

/// 系统朗读声音：按界面语言选音质最好的（Premium > Enhanced > 默认），可在菜单里改选。
enum SpeechVoices {
    static let qualityHintShownKey = "voiceQualityHintShown"
    static let spokenContentSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")

    static func installed() -> [SpeechVoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices().map { v in
            let quality: SpeechVoiceInfo.Quality
            switch v.quality {
            case .premium: quality = .premium
            case .enhanced: quality = .enhanced
            default: quality = .standard
            }
            let novelty = v.voiceTraits.contains(.isNoveltyVoice) || v.voiceTraits.contains(.isPersonalVoice)
            return SpeechVoiceInfo(identifier: v.identifier, name: v.name, language: v.language, quality: quality,
                                   isNovelty: novelty)
        }
    }

    /// 界面语言下可选的声音（菜单用）。
    static func candidates() -> [SpeechVoiceInfo] {
        SpeechVoiceRanking.candidates(installed(), uiLanguage: Localization.currentLanguage)
    }

    /// 用户在菜单里选的声音（空 = 自动）。
    static var preferredID: String? {
        let id = UserDefaults.standard.string(forKey: SpeechVoiceRanking.defaultsKey) ?? ""
        return id.isEmpty ? nil : id
    }

    private static let previewSynthesizer = AVSpeechSynthesizer()

    /// 在菜单里选了声音后试听一句（对话模式开启时不试听，免得被麦克风收进去）。
    static func preview() {
        previewSynthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: L("voice.speech.sample"))
        utterance.voice = current()
        previewSynthesizer.speak(utterance)
    }

    /// 当前应使用的声音。
    static func current() -> AVSpeechSynthesisVoice? {
        let language = Localization.currentLanguage
        if let best = SpeechVoiceRanking.best(installed(), uiLanguage: language, preferredID: preferredID),
           let voice = AVSpeechSynthesisVoice(identifier: best.identifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: SpeechVoiceRanking.locale(forUILanguage: language))
    }

    /// 缺少高质量声音、且还没提示过时返回 true（并记下已提示）。
    static func takeQualityHint() -> Bool {
        guard !UserDefaults.standard.bool(forKey: qualityHintShownKey),
              SpeechVoiceRanking.needsQualityHint(installed(), uiLanguage: Localization.currentLanguage) else { return false }
        UserDefaults.standard.set(true, forKey: qualityHintShownKey)
        return true
    }

    static func label(_ voice: SpeechVoiceInfo) -> String {
        switch voice.quality {
        case .premium: return L("voice.speech.premium", voice.name)
        case .enhanced: return L("voice.speech.enhanced", voice.name)
        case .standard: return voice.name
        }
    }
}
