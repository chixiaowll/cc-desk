import AppKit
import AVFoundation
import CCDeskCore

/// 本地指令的执行：插入 / 发送 / 清空 / 批准 / 拒绝 / 撤销 / 关闭。
extension ConversationMode {
    func perform(_ action: ConversationAction, target: UUID?) {
        let terminal = target.flatMap(pool.terminal)
        switch action {
        case .wake:
            // 唤醒后用语音应答（「我在」），播报期间暂停采集，结束后自动恢复聆听。
            speak(L("conversation.wake.reply"))
        case .standby:
            NSSound(named: "Pop")?.play()
        case .assist(let text):
            assist(text, target: target)
        case .insert(let text):
            guard let terminal else { return noTarget() }
            inputs.type(text, into: terminal, title: targetTitle, submit: false)
            assistant.note("typed \"\(text)\" into \(targetTitle) (not sent)")
        case .send:
            guard let terminal else { return noTarget() }
            terminal.sendKeys("\r")
            inputs.submitted(terminal.id)
            showToast(L("conversation.toast.sent"))
            assistant.note("pressed Enter (sent) in \(targetTitle)")
        case .cancel:
            // 通用助手在回答 / 朗读时，「算了」是对它说的。
            if cancelCompanion() { return }
            if let terminal { inputs.clear(terminal) }
            showToast(L("conversation.toast.cleared"))
            assistant.note("cleared the pending text in \(targetTitle)")
        case .undo:
            undo()
        case .approve:
            terminal?.respondToPermission(approve: true)
            showToast(L("conversation.toast.approved"))
            assistant.note("approved the permission prompt in \(targetTitle)")
        case .deny:
            terminal?.respondToPermission(approve: false)
            showToast(L("conversation.toast.denied"))
            assistant.note("denied the permission prompt in \(targetTitle)")
        case .stop:
            turnOff()
            showToast(L("conversation.toast.stopped"))
        }
    }

    /// 「撤销」：撤回上一个可撤销动作（新建 → 关闭；未发送的输入 → 删除；切换 → 切回）。
    private func undo() {
        guard let action = inputs.popUndo() else { return speak(L("assistant.undo.none")) }
        let message: String
        switch action {
        case .created(let rowID, let title):
            host?.assistantClose(rowID)
            message = L("assistant.undo.created", title)
        case .typed(let tid, let text, _):
            guard let terminal = pool.terminal(tid), inputs.undoTyping(text, in: terminal) else { return undo() }
            message = L("assistant.undo.typed")
        case .switched(let rowID, let title):
            guard host?.assistantRow(rowID) != nil else { return undo() }
            host?.assistantSwitch(to: rowID)
            message = L("assistant.undo.switched", title)
        }
        AssistantDiag.log("undo \(action)")
        assistant.note("undid: \(action)")
        showToast(message)
        speak(message)
    }

    /// 选中会话的标题（给助手的事件记录用）。
    private var targetTitle: String {
        host?.assistantContext(pendingText: "", lastSummary: nil).selected.map { "\($0.title) (\($0.dir))" } ?? "no session"
    }

    /// 菜单「重置助手对话」：丢弃助手的对话记忆。
    func resetAssistant() {
        assistant.reset()
        showToast(L("assistant.toast.reset"))
    }

    /// 要往终端里输入，但当前没选中 CC Desk 里的会话。
    private func noTarget() {
        showToast(L("assistant.noTarget"))
        speak(L("assistant.noTarget"))
    }
}
