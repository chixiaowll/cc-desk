import Foundation
import CCDeskCore

/// CC Desk 往内嵌终端输入、尚未发送的文字，以及撤销记录（设计 §13）。对话模式的本地规则（插入 / 发送 / 取消 / 撤销）
/// 与助手工具（type_text / clear_input / press_key）共用，「取消」「撤销」因此能删掉任一方输入的内容。只在主线程使用。
final class AssistantInputs {
    /// 终端 → 本轮已输入、未发送的文字（按字符数退格即可删除）。
    private var typed: [UUID: String] = [:]
    private(set) var ledger = UndoLedger()

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func pending(_ terminalID: UUID) -> String {
        typed[terminalID] ?? ""
    }

    /// 输入文字；submit 时补回车。未发送的输入可撤销。返回实际写入的内容（可能前面补了空格）。
    @discardableResult
    func type(_ text: String, into terminal: EmbeddedTerminal, title: String, submit: Bool) -> String {
        let payload = ConversationText.insertion(text, after: pending(terminal.id))
        terminal.send(text: payload, submit: submit)
        if submit {
            submitted(terminal.id)
        } else {
            typed[terminal.id, default: ""] += payload
            ledger.record(.typed(terminalID: terminal.id, text: payload, title: title), now: now)
        }
        return payload
    }

    /// 删掉本轮输入的全部文字。Claude Code 的 Ctrl+U 只删到当前可视行的行首（长文本换行后删不干净），
    /// 按字符数退格才可靠。返回删掉的字符数。
    @discardableResult
    func clear(_ terminal: EmbeddedTerminal) -> Int {
        let count = pending(terminal.id).count
        if count > 0 { terminal.sendKeys(String(repeating: "\u{7f}", count: count)) }
        typed[terminal.id] = nil
        ledger.typingFinished(terminalID: terminal.id)
        return count
    }

    /// 已回车发送：本轮输入清空，之前的输入不再可撤销。
    func submitted(_ terminalID: UUID) {
        typed[terminalID] = nil
        ledger.typingFinished(terminalID: terminalID)
    }

    /// 撤销一次输入：输入框末尾仍是这段文字时退格删掉。
    func undoTyping(_ text: String, in terminal: EmbeddedTerminal) -> Bool {
        guard let current = typed[terminal.id], current.hasSuffix(text) else { return false }
        terminal.sendKeys(String(repeating: "\u{7f}", count: text.count))
        typed[terminal.id] = String(current.dropLast(text.count))
        return true
    }

    func record(_ action: UndoableAction) {
        ledger.record(action, now: now)
    }

    func popUndo() -> UndoableAction? {
        ledger.pop(now: now)
    }

    func closed(terminalID: UUID) {
        typed[terminalID] = nil
        ledger.sessionClosed(rowID: "term:\(terminalID.uuidString)", terminalID: terminalID)
    }
}
