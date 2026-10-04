import AppKit
import AVFoundation
import CCDeskCore

/// 播报：选中会话的状态播报、主动提醒（设计 §14）与对播报过的等批准的回应。
extension ConversationMode {
    /// 对刚播报过的后台会话执行批准 / 拒绝：仍在等同一个请求才发键（ApprovalNotification.decide 复核），否则说明原因。
    func respondAnnounced(_ announced: AnnouncedApproval, approve: Bool) {
        announcedApproval = nil
        guard let host else { return }
        let decision = host.assistantRespondApproval(rowID: announced.rowID, expectedReason: announced.reason,
                                                     expectedEpisode: announced.episode, approve: approve)
        AssistantDiag.log("announced \(approve ? "approve" : "deny") \(announced.rowID) -> \(decision)")
        switch decision {
        case .apply:
            let message = approve ? L("work.toast.approved", announced.name) : L("work.toast.denied", announced.name)
            showToast(message)
            assistant.note("\(approve ? "approved" : "denied") the permission prompt in \(announced.name) (the one you announced)")
        case .reasonChanged:
            speak(L("work.approval.changed", announced.name))
        case .notWaiting:
            speak(L("work.approval.notWaiting", announced.name))
        case .gone, .notEmbedded:
            speak(L("work.approval.gone", announced.name))
        }
    }

    /// 用户正在说话 / 等识别 / 等助手 / 听播报 / 回答确认问题：主动播报先排队，不打断。
    var isBusyForProactive: Bool {
        !isOn || preparing || capturing || transcribing || thinking || speaking || pendingConfirmation != nil || !queue.isEmpty
    }

    /// 播报一条主动提醒；approval 非 nil 时记下，之后的「批准 / 拒绝」作用于那个会话（待命时也接受，同播报等批准）。
    func announce(_ text: String, approval: AnnouncedApproval?) {
        guard isOn else { return }
        if let approval {
            announcedApproval = approval
            session.noteWaitingAnnounced(now: ProcessInfo.processInfo.systemUptime)
        }
        showToast(text, duration: 4)
        speak(text)
    }

    /// 后台会话的状态变化交给常驻助手；completion 在主线程：要播报的话（可能是 SILENT），失败时 nil。
    func relayEvent(_ description: String, completion: @escaping (String?) -> Void) {
        guard isOn, let host else { return completion(nil) }
        let current = generation
        let context = host.assistantContext(pendingText: "", lastSummary: nil)
        assistant.event(description, context: context) { [weak self] reply in
            guard let self, self.isOn, self.generation == current else { return }
            completion(reply)
        }
    }

    /// 顾问的结果交给常驻助手说一两句结论；completion 在主线程，失败时 nil。
    func relayConsultResult(job: ConsultJob, answer: String, completion: @escaping (String?) -> Void) {
        guard isOn else { return completion(nil) }
        let current = generation
        assistant.consultResult(job: job, answer: answer, language: Localization.currentLanguage) { [weak self] reply in
            guard let self, self.isOn, self.generation == current else { return }
            completion(reply)
        }
    }

    /// 每次轮询后由 AppModel 调用：选中的内嵌终端及其当前状态。
    func observe(terminalID: UUID?, status: AgentStatus?) {
        guard isOn else { return }
        guard let terminalID, let status else {
            observed = nil
            return
        }
        defer { observed = (terminalID, status) }
        guard let previous = observed, previous.id == terminalID,
              let text = SpokenStatus.announcement(previous: previous.status, current: status) else { return }
        if status.isWaiting {
            session.noteWaitingAnnounced(now: ProcessInfo.processInfo.systemUptime)
        } else if Self.summariesEnabled, host != nil {
            // 一轮完成：播报回复摘要，失败 / 超时时退回「已完成」。
            return summarize(terminalID: terminalID, fallback: text)
        }
        speak(text)
    }
}
