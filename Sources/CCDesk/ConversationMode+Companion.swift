import AppKit
import CCDeskCore

/// 通用助手（设计 §24）在对话模式里的部分：朗读它的回答、「继续说」、「算了」取消 / 打断。
extension ConversationMode {
    /// 朗读通用助手的回答（CompanionWork 在用户不忙时调用）；提示条同时显示开头。
    func speakCompanion(_ text: String) {
        guard isOn else { return }
        showToast(AssistantContext.clip(text, 80), duration: 4)
        speak(text)
        speakingCompanion = true
    }

    /// 「继续说」：接着念通用助手上一个回答剩下的部分；没有剩下的时返回 false（这句话照常交给语音助手）。
    func continueCompanion(_ text: String) -> Bool {
        guard CompanionSpeech.isContinue(text), let more = host?.companionContinuation() else { return false }
        AssistantDiag.log("companion continue -> \(more.count) chars")
        speakCompanion(more)
        return true
    }

    /// 「算了」：通用助手有排队 / 回答中的问题、等着念的回答或正在念时，取消 / 打断它（不清空输入框）。
    /// 返回是否处理了。
    func cancelCompanion() -> Bool {
        let wasSpeaking = speakingCompanion && speaking
        let cancelled = host?.companionCancel() ?? false
        guard cancelled || wasSpeaking else { return false }
        if wasSpeaking { stopSpeaking() }
        speakingCompanion = false
        showToast(L("companion.toast.cancelled"))
        assistant.note("the user cancelled the companion's answer")
        return true
    }
}
