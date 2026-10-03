import AVFoundation
import CCDeskCore

/// 朗读声音：自然语音（本机 Qwen3-TTS serena，装好后默认）或系统声音（按界面语言选音质最好的
/// Premium > Enhanced > 默认），可在菜单里改选。
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

    /// 用户在菜单里选的系统声音（空 = 自动；选了自然语音时系统声音也按自动，作为后备）。
    static var preferredID: String? {
        let id = UserDefaults.standard.string(forKey: SpeechVoiceRanking.defaultsKey) ?? ""
        return id.isEmpty || id == NaturalVoiceProtocol.preferenceID ? nil : id
    }

    private static let previewOutput = SpeechOutput()

    /// 在菜单里选了声音后试听一句（对话模式开启时不试听，免得被麦克风收进去）。
    /// 自然语音还在加载时最多等 30 秒再读。
    static func preview() {
        previewOutput.speak(L("voice.speech.sample"), waitForNatural: 30)
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
        guard !NaturalVoice.isSelected, !UserDefaults.standard.bool(forKey: qualityHintShownKey),
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
