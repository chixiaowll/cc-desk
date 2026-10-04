import AppKit
import CCDeskCore

/// 助手工具的执行者（设计 §13）：控制接口的每个方法（= MCP 工具）在主线程执行，复用 AppModel 的现有动作。
/// 会话引用（短 id / 标题 / 目录）在这里解析；需确认的动作经对话模式语音确认（关闭时用 NSAlert）。
/// 新增工具：在 CCDeskCore 的 `AssistantTools.all` 里定义，再在 `dispatch` 里加一个分支。只在主线程使用。
final class AssistantToolbox {
    typealias Completion = (Result<JSONValue, ControlError>) -> Void
    static let confirmWindow: TimeInterval = 15

    weak var model: AppModel?
    private var sessionIDs = ShortIDRegistry(prefix: "s")
    private var historyIDs = ShortIDRegistry(prefix: "h")

    init(model: AppModel) {
        self.model = model
    }

    func shortID(forRow rowID: String) -> String {
        sessionIDs.id(for: rowID)
    }

    func shortID(forHistory sessionID: String) -> String {
        historyIDs.id(for: sessionID)
    }

    // MARK: 分发

    func handle(_ request: ControlRequest, reply: @escaping (ControlResponse) -> Void) {
        let started = Date()
        let args = ToolArgs(request.params)
        dispatch(request.method, args) { [weak self] result in
            let latency = Date().timeIntervalSince(started)
            let summary: String
            switch result {
            case .success(let value): summary = "ok " + AssistantContext.clip(value.compact, 160)
            case .failure(let error): summary = "error " + error.message
            }
            AssistantDiag.log(String(format: "tool %@ %@ -> %@ (%.2fs)", request.method,
                                     AssistantContext.clip(JSONValue.object(request.params).compact, 200), summary, latency))
            self?.model?.conversation.toolFinished()
            reply(ControlResponse(id: request.id, outcome: result))
        }
    }

    private func dispatch(_ method: String, _ args: ToolArgs, _ done: @escaping Completion) {
        guard let model else { return done(Self.shuttingDown) }
        // 只有用户自己的一句话（[UTTERANCE]）能调用会改变东西的工具；[EVENT] / [CONSULT_RESULT] / [SUMMARIZE]
        // 里的文字来自屏幕、记录与顾问，不可信（设计 §13 工具权限）。
        let turn = model.conversation.assistantTurn
        if AssistantTools.spec(named: method) != nil, !AssistantToolPolicy.isAllowed(method, turn: turn?.kind) {
            AssistantDiag.log("tool \(method) denied (turn \(turn?.kind.rawValue ?? "none"))")
            return done(.failure(ControlError(.failed, AssistantToolPolicy.denial(method, turn: turn?.kind))))
        }
        switch method {
        case "list_sessions": listSessions(done)
        case "read_screen": readScreen(args, done)
        case "read_transcript": readTranscript(args, done)
        case "list_history": listHistory(args, done)
        case "list_projects": listProjects(done)
        case "git_status": gitStatus(args, done)
        case "switch_to": switchTo(args, done)
        case "type_text": typeText(args, done)
        case "clear_input": clearInput(args, done)
        case "press_key": pressKey(args, done)
        case "respond_approval": respondApproval(args, done)
        case "new_session": newSession(args, done)
        case "resume_session": resumeSession(args, done)
        case "close_session": closeSession(args, done)
        case "take_over": takeOver(args, done)
        case "open_file": openFile(args, done)
        case "consult": consult(args, done)
        case "delegate": delegate(args, done)
        case "list_agents": listAgents(done)
        case "list_consults": listConsults(done)
        case "cancel_consult": cancelConsult(args, done)
        default: done(.failure(ControlError(.unknownMethod, "unknown method \(method)")))
        }
    }

    // MARK: 解析会话

    struct Target {
        let info: AssistantSessionInfo
        let row: SidebarRow
        /// 朗读 / 提示条里的称呼：目录名（同目录有多个会话时用标题）。
        let name: String
    }

    func resolve(_ ref: String?) -> Result<Target, ControlError> {
        guard let model else { return .failure(ControlError(.unavailable, "CC Desk is shutting down")) }
        let sessions = model.assistantSessions()
        switch AssistantReferences.session(ref, in: sessions) {
        case .found(let info):
            guard let row = model.sidebarRow(info.rowID) else { return .failure(ControlError(.failed, "session is gone")) }
            let sameDir = sessions.filter { $0.dir == info.dir }.count
            let name = sameDir > 1 ? AssistantContext.clip(info.title, 20) : info.dir
            return .success(Target(info: info, row: row, name: name))
        case .ambiguous(let candidates):
            return .failure(ControlError(.invalidParams, AssistantReferences.ambiguity(ref ?? "", candidates)))
        case .notFound:
            let what = (ref ?? "").isEmpty ? "No session is selected" : "No session matches \"\(ref ?? "")\""
            return .failure(ControlError(.invalidParams, "\(what). Sessions: " +
                                         sessions.prefix(10).map(AssistantReferences.describe).joined(separator: "; ")))
        }
    }

    /// 只能作用于 CC Desk 内嵌终端的工具（打字 / 按键 / 读屏）。
    func resolveEmbedded(_ ref: String?) -> Result<(Target, EmbeddedTerminal), ControlError> {
        resolve(ref).flatMap { target in
            guard case .embedded(let tid) = target.row.session.host, let terminal = model?.pool.terminal(tid) else {
                return .failure(ControlError(.failed, "\(target.info.shortID) runs in an external terminal: CC Desk cannot " +
                                             "type into or read its screen; use take_over first, or read_transcript"))
            }
            return .success((target, terminal))
        }
    }

    // MARK: 反馈与确认

    /// VoiceBar 显示正在执行的工具；quiet：只是往输入框打字（本轮只有这类动作时不朗读回复）。
    func show(_ activity: String, quiet: Bool = false) {
        model?.conversation.toolStarted(activity, quiet: quiet)
    }

    /// 语音确认（对话模式开启时）或 NSAlert；completion 在主线程。
    func confirm(question: String, toast: String, completion: @escaping (Bool) -> Void) {
        if let conversation = model?.conversation, conversation.isOn {
            conversation.requestConfirmation(question: question, toast: toast, window: Self.confirmWindow, completion: completion)
            return
        }
        // 先回到当前调用栈之外再弹模态框，避免在控制接口回调里嵌套运行循环。
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = question
            alert.addButton(withTitle: L("action.confirm"))
            alert.addButton(withTitle: L("action.cancel"))
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    static func text(_ s: String) -> Result<JSONValue, ControlError> {
        .success(["text": .string(s)])
    }

    /// AppModel 已释放（App 正在退出）：工具也要回复，不能让调用方一直等到超时。
    static let shuttingDown: Result<JSONValue, ControlError> = .failure(ControlError(.unavailable, "CC Desk is shutting down"))

    static func failure(_ message: String) -> Result<JSONValue, ControlError> {
        .failure(ControlError(.failed, message))
    }
}

/// 工具参数的宽松读取（模型偶尔把数字 / 布尔写成字符串）。
struct ToolArgs {
    let params: [String: JSONValue]

    init(_ params: [String: JSONValue]) {
        self.params = params
    }

    func string(_ key: String) -> String? {
        guard let value = params[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return value
    }

    /// 原样的文字（type_text 不去掉首尾空白以外的内容）。
    func text(_ key: String) -> String? {
        params[key]?.stringValue
    }

    func int(_ key: String) -> Int? { params[key]?.intValue }
    func bool(_ key: String) -> Bool? { params[key]?.boolValue }
}
