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
    /// 读会话记录尾部（后台），completion 在主线程。rowID 为 nil 时取选中的会话。
    func assistantDigest(rowID: String?, completion: @escaping (AssistantDigest?) -> Void)
}

/// 意图解析 / 问答 / 摘要的模型调用与兜底（结果都在主线程回调）。不持有界面状态，执行由 ConversationMode 负责。
final class VoiceAssistant {
    private let client: AssistantClient

    init(client: AssistantClient = .shared) {
        self.client = client
    }

    var isAvailable: Bool? { client.isAvailable }

    func prepare(completion: ((Bool) -> Void)? = nil) {
        client.prepare(completion: completion)
    }

    /// 意图解析。模型不可用 / 超时 / 输出无效时退回为插入原话。
    func decide(utterance: String, context: AssistantContext, completion: @escaping (AssistantDecision) -> Void) {
        client.complete(system: AssistantPrompt.intentSystem,
                        message: AssistantPrompt.intentMessage(utterance: utterance, context: context)) { result in
            switch result {
            case .success(let reply):
                completion(AssistantResponse.decide(modelText: reply.text, utterance: utterance, context: context))
            case .failure:
                completion(AssistantDecision(command: .insert(utterance), speak: L("assistant.unavailable"), isFallback: true))
            }
        }
    }

    /// 状态问答：1–2 句口语回答；失败时给出简短的说明。
    func answer(question: String, digest: AssistantDigest?, language: String, completion: @escaping (String) -> Void) {
        guard let digest, !digest.digest.isEmpty else { return completion(L("assistant.query.noTranscript")) }
        client.complete(system: AssistantPrompt.querySystem(language: language),
                        message: AssistantPrompt.queryMessage(question: question, title: digest.title,
                                                              status: digest.status, digest: digest.digest)) { result in
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
        client.complete(system: AssistantPrompt.summarySystem(language: language),
                        message: AssistantPrompt.summaryMessage(title: digest.title, digest: digest.digest)) { result in
            if case .success(let reply) = result { completion(AssistantResponse.cleanSpokenAnswer(reply.text)) } else { completion(nil) }
        }
    }
}
