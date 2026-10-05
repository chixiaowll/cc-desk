import AppKit
import AVFoundation
import CCDeskCore

/// 语音助手（设计 §12/§13）：交给常驻助手的话、等待与看门狗、工具反馈与语音确认、回复摘要。
extension ConversationMode {
    /// 本地规则没命中的话：「哪些在等我」「有哪些会话」本地回答，转述直接填入，其余交给常驻助手（期间提示音 +「思考中…」）。
    func assist(_ text: String, target: UUID?) {
        guard let host else { return perform(.insert(text), target: target) }
        let context = host.assistantContext(pendingText: target.map(inputs.pending) ?? "",
                                            lastSummary: target.flatMap { lastSummaries[$0] })
        if AssistantLocal.isWaitingQuestion(text) {
            return speak(AssistantLocal.waitingAnswer(sessions: context.sessions))
        }
        if let number = AssistantLocal.numberedSwitch(text) {
            // 「切到第 N 个」：本地直接按侧栏编号切换（与 ⌘N 一致），不经过模型。
            if let title = host.assistantSelectNumbered(number) {
                showToast(L("assistant.switch.numbered", number, title))
                assistant.note("user said \"\(text)\"; CC Desk switched to sidebar session #\(number) \(title)")
            } else {
                speak(L("assistant.switch.numberedNone", number))
            }
            return
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
        let turn = beginThinking(heard: text)
        assistant.handle(utterance: text, spokenAt: utteranceStartedAt, context: context) { [weak self] result in
            // 看门狗已经结束了这一轮时忽略迟到的回复。
            guard let self, self.isOn, self.generation == current, self.thinkingTurn == turn, self.thinking else { return }
            let quiet = self.turnQuiet == true
            self.endThinking()
            switch result {
            case .success(let reply):
                // 只是往输入框打字（逐句口述）时不朗读，免得太吵；回复显示在提示条上。
                if let spoken = AssistantSpeech.clean(reply.text) { quiet ? self.showToast(spoken) : self.speak(spoken) }
            case .failure(.notInstalled):
                self.perform(.insert(text), target: target)
            case .failure(.api(let detail)):
                self.speak(L("assistant.unavailable"))
                self.showToast(L("assistant.toast.apiError", detail))
            case .failure:
                self.speak(L("assistant.unavailable"))
            }
            self.state = self.session.state
            self.transcribeNext()
        }
    }

    /// 设置里换了助手模型 / 改了接口配置（设计 §22）：重新选后端；对话模式开着时更新「交给助手还是直接填入」。
    func assistantBackendChanged() {
        assistant.backendChanged()
        guard isOn else { return }
        let current = generation
        assistant.prepare { [weak self] ok in
            guard let self, self.isOn, self.generation == current else { return }
            self.session.routesToAssistant = ok
            AssistantDiag.log("assistant backend changed, model available=\(ok)")
        }
    }

    /// 开始等助手；返回这一轮的编号。看门狗保证 `thinking` 最多持续「一轮超时 + 余量」，
    /// 否则助手那边万一没有回调，后面所有的话都会排在 transcribeNext 里出不来。
    @discardableResult
    private func beginThinking(heard text: String) -> Int {
        thinkingTurn += 1
        let turn = thinkingTurn
        thinking = true
        heard = text
        activity = nil
        turnQuiet = nil
        session.noteSpeech(now: ProcessInfo.processInfo.systemUptime)
        NSSound(named: "Tink")?.play()
        thinkingWatchdog?.cancel()
        let current = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isOn, self.generation == current, self.thinking, self.thinkingTurn == turn else { return }
            AssistantDiag.log("assistant watchdog: no reply after \(Int(Self.thinkingWatchdogDelay))s, giving up")
            self.endThinking()
            self.speak(L("assistant.unavailable"))
            self.state = self.session.state
            self.transcribeNext()
        }
        thinkingWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.thinkingWatchdogDelay, execute: work)
        return turn
    }

    private func endThinking() {
        thinkingWatchdog?.cancel()
        thinkingWatchdog = nil
        thinking = false
        heard = nil
        activity = nil
        turnQuiet = nil
        session.noteSpeech(now: ProcessInfo.processInfo.systemUptime)
    }

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
        let now = ProcessInfo.processInfo.systemUptime
        pendingConfirmation = (now + window, completion)
        // 问题之前说的话不能当作回答：丢掉排队的，正在识别的那句由 apply 按开始时间丢弃；播报完再更新这个时刻。
        confirmationListenAfter = now
        queue = []
        AssistantDiag.log("confirm? \"\(question)\"")
        showToast(toast, duration: window)
        speak(question)
    }

    func resolveConfirmation(_ ok: Bool) {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        AssistantDiag.log("confirm -> \(ok)")
        pending.completion(ok)
    }

    /// 等待确认时听到的话：「确认」类 → 执行；其他话 → 取消（这句话不再另作处理）。
    func answerConfirmation(_ text: String) {
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
    func summarize(terminalID: UUID, fallback: String) {
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
}
