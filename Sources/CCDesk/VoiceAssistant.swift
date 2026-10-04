import Foundation
import CCDeskCore

/// 某个会话的记录摘录（供问答 / 回复摘要）。
struct AssistantDigest {
    let title: String
    let status: AgentStatus
    let digest: String
}

/// 对话模式需要 App 提供的东西（由 AppModel 实现）。会话操作走助手工具（AssistantToolbox）。只在主线程调用。
protocol AssistantHost: AnyObject {
    /// 当前侧栏（带稳定短 id）与项目；pendingText、lastSummary 由对话模式提供。
    func assistantContext(pendingText: String, lastSummary: String?) -> AssistantContext
    /// 会话标题与状态；不存在时 nil。
    func assistantRow(_ rowID: String) -> (title: String, status: AgentStatus, isEmbedded: Bool)?
    func assistantSwitch(to rowID: String)
    /// 关闭内嵌会话（不再弹确认框）。
    func assistantClose(_ rowID: String)
    /// 回应某个会话的等批准：仍是内嵌终端、仍在等批准、等待原因与 expectedReason 相同且仍是同一次等待
    /// （expectedEpisode，nil 时不比较）时才发键（设计 §14）。
    func assistantRespondApproval(rowID: String, expectedReason: String?, expectedEpisode: Int?,
                                  approve: Bool) -> ApprovalNotification.Decision
    /// 读会话记录尾部（后台），completion 在主线程。rowID 为 nil 时取选中的会话；turns > 0 时只取最近几轮。
    func assistantDigest(rowID: String?, turns: Int, completion: @escaping (AssistantDigest?) -> Void)
}

/// 每句话 / 摘要都发给同一个常驻助手会话（有上下文），结果在主线程回调。
/// 不持有界面状态，执行由 ConversationMode 负责。只在主线程调用。
final class VoiceAssistant {
    static let maxEvents = 12
    private let client: AssistantClient
    private var session: AssistantSession { client.session }
    /// 上次发给会话的侧栏上下文与当时的进程代数（新进程 / 新会话要重发完整上下文）。
    private var lastContextJSON: String?
    private var lastGeneration = -1
    /// 本地已执行、模型还不知道的事（下一句话时一并告诉它）。
    private var events: [String] = []

    init(client: AssistantClient = .shared) {
        self.client = client
    }

    var isAvailable: Bool? { client.isAvailable }

    /// 解析 claude 路径并预先启动常驻会话。
    func prepare(completion: ((Bool) -> Void)? = nil) {
        client.prepare { [weak self] ok in
            if ok { self?.session.warmUp() }
            completion?(ok)
        }
    }

    /// 记一件本地发生的事（如「把『继续』填入了 poems」），下一句话时告诉助手。
    func note(_ event: String) {
        events.append(AssistantContext.clip(event, 120))
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
    }

    /// 丢弃助手的对话记忆，下一句开始新会话。
    func reset() {
        events = []
        lastContextJSON = nil
        session.reset()
    }

    /// 正在等回复的那条消息的种类（助手工具据此决定放不放行，见 `AssistantToolPolicy`）。
    var currentTurn: AssistantTurn? { session.currentTurn }

    /// 一句话交给常驻会话：模型用工具做事，返回最后的文字回复（要朗读的内容）。spokenAt：用户开始说这句话的时刻（systemUptime）。
    func handle(utterance: String, spokenAt: TimeInterval?, context: AssistantContext,
                completion: @escaping (Result<AssistantReply, AssistantError>) -> Void) {
        let json = context.json()
        let generation = session.generation
        let unchanged = json == lastContextJSON && generation == lastGeneration
        let message = AssistantPrompt.residentUtterance(utterance: utterance, events: events, contextJSON: unchanged ? nil : json)
        let sentEvents = events
        events = []
        AssistantDiag.log("ask \"\(utterance)\" context=\(unchanged ? "unchanged" : "full") events=\(sentEvents.count) sessions=" +
                          context.sessions.map { "\($0.shortID):\($0.dir)\($0.isSelected ? "*" : "")" }.joined(separator: " "))
        session.ask(message, turn: AssistantTurn(kind: .utterance, spokenAt: spokenAt),
                    timeout: AssistantClient.turnTimeout) { [weak self] result in
            switch result {
            case .success(let reply):
                self?.lastContextJSON = json
                self?.lastGeneration = self?.session.generation ?? -1
                AssistantDiag.log(String(format: "reply %.2fs in=%d out=%d: %@", reply.latency, reply.inputTokens,
                                         reply.outputTokens, reply.text))
            case .failure(let error):
                self?.lastContextJSON = nil
                AssistantDiag.log("reply failed: \(error)")
            }
            completion(result)
        }
    }

    /// 主动提醒（设计 §14）：后台会话的状态变化，助手回复要播报的一句话或 SILENT；失败 / 超时返回 nil。
    func event(_ description: String, context: AssistantContext, completion: @escaping (String?) -> Void) {
        let json = context.json()
        let unchanged = json == lastContextJSON && session.generation == lastGeneration
        let message = AssistantPrompt.residentEvent(description, language: context.language,
                                                    contextJSON: unchanged ? nil : json)
        AssistantDiag.log("event \(AssistantContext.clip(description, 200)) context=\(unchanged ? "unchanged" : "full")")
        session.ask(message, turn: AssistantTurn(kind: .event), timeout: AssistantClient.timeout) { [weak self] result in
            switch result {
            case .success(let reply):
                self?.lastContextJSON = json
                self?.lastGeneration = self?.session.generation ?? -1
                AssistantDiag.log(String(format: "event reply %.2fs in=%d out=%d: %@", reply.latency, reply.inputTokens,
                                         reply.outputTokens, reply.text))
                completion(reply.text)
            case .failure(let error):
                self?.lastContextJSON = nil
                AssistantDiag.log("event reply failed: \(error)")
                completion(nil)
            }
        }
    }

    /// 顾问的回答交给助手（它记住全文，便于追问），回复一两句结论；失败 / 超时返回 nil。
    func consultResult(job: ConsultJob, answer: String, language: String, completion: @escaping (String?) -> Void) {
        let message = AssistantPrompt.residentConsultResult(job: job.id, question: job.question, model: job.model,
                                                            answer: answer, language: language)
        session.ask(message, turn: AssistantTurn(kind: .consultResult), timeout: AssistantClient.timeout) { result in
            switch result {
            case .success(let reply):
                AssistantDiag.log(String(format: "consult result reply %.2fs: %@", reply.latency, reply.text))
                completion(reply.text)
            case .failure(let error):
                AssistantDiag.log("consult result reply failed: \(error)")
                completion(nil)
            }
        }
    }

    /// 回复摘要；失败 / 超时返回 nil（调用方退回「已完成」）。
    func summarize(digest: AssistantDigest?, language: String, completion: @escaping (String?) -> Void) {
        guard let digest, !digest.digest.isEmpty else { return completion(nil) }
        let message = AssistantPrompt.residentSummary(title: digest.title, digest: digest.digest, language: language)
        session.ask(message, turn: AssistantTurn(kind: .summarize), timeout: AssistantClient.timeout) { result in
            if case .success(let reply) = result { completion(AssistantSpeech.clean(reply.text)) } else { completion(nil) }
        }
    }
}
