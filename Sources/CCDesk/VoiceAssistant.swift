import Foundation
import CCDeskCore

/// 某个会话的记录摘录（供问答 / 回复摘要）。
struct AssistantDigest {
    let title: String
    let status: AgentStatus
    let digest: String
}

/// 语音助手能对 App 做的事（由 AppModel 实现）。只在主线程调用。
protocol AssistantHost: AnyObject {
    /// 当前侧栏 / 项目 / 历史；pendingText、lastSummary 由对话模式提供。
    func assistantContext(pendingText: String, lastSummary: String?) -> AssistantContext
    /// 会话标题与状态；不存在时 nil。
    func assistantRow(_ rowID: String) -> (title: String, status: AgentStatus, isEmbedded: Bool)?
    func assistantSwitch(to rowID: String)
    func assistantNew(dir: String, agent: AgentKind)
    /// 返回历史会话的标题；找不到时 nil。
    func assistantResume(sessionID: String) -> String?
    /// 关闭内嵌会话（不再弹确认框：语音已确认过）。
    func assistantClose(_ rowID: String)
    /// 外部终端里的会话能否接管到 CC Desk（有会话 id、agent 支持恢复）。
    func assistantCanTakeOver(_ rowID: String) -> Bool
    /// 接管外部会话（语音已确认过，不再弹确认框）并选中它。
    func assistantTakeOver(_ rowID: String)
    /// 读会话记录尾部（后台），completion 在主线程。rowID 为 nil 时取选中的会话。
    func assistantDigest(rowID: String?, completion: @escaping (AssistantDigest?) -> Void)
}

/// 意图解析 / 问答 / 摘要都发给同一个常驻助手会话（有上下文），结果在主线程回调。
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

    /// 意图解析。模型不可用 / 超时 / 输出无效时退回为插入原话。
    func decide(utterance: String, context: AssistantContext, completion: @escaping (AssistantDecision) -> Void) {
        let json = context.json()
        let generation = session.generation
        let unchanged = json == lastContextJSON && generation == lastGeneration
        let message = AssistantPrompt.residentUtterance(utterance: utterance, events: events, contextJSON: unchanged ? nil : json)
        events = []
        AssistantDiag.log("decide \"\(utterance)\" context=\(unchanged ? "unchanged" : "full") sessions=" + context.sessions.map {
            "\($0.title)@\($0.dir)\($0.isSelected ? "*" : "")"
        }.joined(separator: " | "))
        session.ask(message, timeout: AssistantClient.timeout) { [weak self] result in
            switch result {
            case .success(let reply):
                self?.lastContextJSON = json
                self?.lastGeneration = self?.session.generation ?? -1
                let decision = AssistantResponse.decide(modelText: reply.text, utterance: utterance, context: context)
                AssistantDiag.log(String(format: "model %.2fs in=%d out=%d raw=%@ -> %@", reply.latency, reply.inputTokens,
                                         reply.outputTokens, reply.text, String(describing: decision.command)))
                completion(decision)
            case .failure(let error):
                self?.lastContextJSON = nil
                AssistantDiag.log("model failed: \(error)")
                completion(AssistantDecision(command: .insert(utterance), speak: L("assistant.unavailable"), isFallback: true))
            }
        }
    }

    /// 状态问答：1–2 句口语回答；失败时给出简短的说明。
    func answer(question: String, digest: AssistantDigest?, language: String, completion: @escaping (String) -> Void) {
        guard let digest, !digest.digest.isEmpty else { return completion(L("assistant.query.noTranscript")) }
        let message = AssistantPrompt.residentQuestion(question: question, title: digest.title, status: digest.status,
                                                       digest: digest.digest, language: language)
        session.ask(message, timeout: AssistantClient.timeout) { result in
            if case .success(let reply) = result, let text = AssistantResponse.cleanSpokenAnswer(reply.text) {
                completion(text)
            } else {
                completion(L("assistant.query.failed"))
            }
        }
    }

    /// 回复摘要；失败 / 超时返回 nil（调用方退回「已完成」）。
    func summarize(digest: AssistantDigest?, language: String, completion: @escaping (String?) -> Void) {
        guard let digest, !digest.digest.isEmpty else { return completion(nil) }
        let message = AssistantPrompt.residentSummary(title: digest.title, digest: digest.digest, language: language)
        session.ask(message, timeout: AssistantClient.timeout) { result in
            if case .success(let reply) = result { completion(AssistantResponse.cleanSpokenAnswer(reply.text)) } else { completion(nil) }
        }
    }
}
