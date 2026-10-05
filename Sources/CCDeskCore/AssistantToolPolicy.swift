import Foundation

// MARK: - 助手工具的调用权限（设计 §13）

/// 常驻助手会话里一条请求的种类（= 消息开头的标签）。
public enum AssistantTurnKind: String, Equatable, Sendable {
    /// 用户说的话（[UTTERANCE]）。
    case utterance
    /// 后台会话的状态变化（[EVENT]）：内容含屏幕抓取的等待原因 / 记录尾部，不可信。
    case event
    /// 顾问的回答（[CONSULT_RESULT]）：不可信。
    case consultResult
    /// 选中会话一轮完成的摘要（[SUMMARIZE]）：内容是记录尾部，不可信。
    case summarize
}

/// 正在等回复的那条请求：种类，以及（用户的话）开始说的时刻（systemUptime）。
public struct AssistantTurn: Equatable, Sendable {
    public let kind: AssistantTurnKind
    public let spokenAt: TimeInterval?

    public init(kind: AssistantTurnKind, spokenAt: TimeInterval? = nil) {
        self.kind = kind
        self.spokenAt = spokenAt
    }
}

/// 工具调用的权限：提示词里的「不要调用工具」只是请求，真正的限制在这里（防止记录 / 屏幕 / 顾问回答里的文字
/// 借助 [EVENT] / [CONSULT_RESULT] / [SUMMARIZE] 让助手替用户批准、打字、开会话）。
public enum AssistantToolPolicy {
    /// 只读工具（`AssistantToolSpec.readOnly`）任何时候都可以；会改变东西的工具（打字、按键、批准 / 拒绝、
    /// 切换 / 新建 / 恢复 / 关闭 / 接管会话、派活、顾问、取消顾问、打开文件）与标了 `utteranceOnly` 的只读工具
    /// （ask_companion）只在用户的一句话（[UTTERANCE]）里可以。没有请求在等回复（turn 为 nil）或未知的工具一律不行。
    public static func isAllowed(_ tool: String, turn: AssistantTurnKind?) -> Bool {
        guard let spec = AssistantTools.spec(named: tool) else { return false }
        return (spec.readOnly && !spec.utteranceOnly) || turn == .utterance
    }

    /// 工具调用的统一检查（控制接口 / MCP 与 OpenAI 兼容接口两条路径都经过这里，见设计 §22）：
    /// nil = 放行；否则是给模型看的拒绝说明。未知的方法不在这里拒绝（由分发处回复「unknown method」）。
    public static func check(_ tool: String, turn: AssistantTurnKind?) -> String? {
        guard AssistantTools.spec(named: tool) != nil, !isAllowed(tool, turn: turn) else { return nil }
        return denial(tool, turn: turn)
    }

    /// 被拒绝时给模型看的说明。
    public static func denial(_ tool: String, turn: AssistantTurnKind?) -> String {
        let where_ = turn.map { "a [\(tag($0))] message" } ?? "no active request"
        return "\(tool) is not allowed while handling \(where_): tools that change anything only run for the user's " +
            "own [UTTERANCE]. Reply in words instead; the user can ask for it."
    }

    static func tag(_ kind: AssistantTurnKind) -> String {
        switch kind {
        case .utterance: return "UTTERANCE"
        case .event: return "EVENT"
        case .consultResult: return "CONSULT_RESULT"
        case .summarize: return "SUMMARIZE"
        }
    }

    /// respond_approval 是否要先语音确认：用户这句话必须在这次等批准开始之后、（播报过的话）在播报之后才开始说，
    /// 否则用户说「批准」时还没听到 / 看到这个请求。时间都是 systemUptime；不知道的时刻按「需要确认」处理。
    public static func approvalNeedsConfirmation(spokenAt: TimeInterval?, waitingSince: TimeInterval?,
                                                 announcedAt: TimeInterval?) -> Bool {
        guard let spokenAt, let waitingSince, spokenAt > waitingSince else { return true }
        if let announcedAt, spokenAt <= announcedAt { return true }
        return false
    }
}
