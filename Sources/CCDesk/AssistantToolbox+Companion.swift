import Foundation
import CCDeskCore

/// 通用助手工具（设计 §24）：把非编程问题交给 CompanionWork；它的回答由 CC Desk 直接朗读，不经语音助手转述。
extension AssistantToolbox {
    func askCompanion(_ args: ToolArgs, _ done: @escaping Completion) {
        guard let model else { return done(Self.shuttingDown) }
        guard let question = args.text("question"), ConversationText.isMeaningful(question) else {
            return done(.failure(ControlError(.invalidParams, "question is empty")))
        }
        let companion = model.companion
        let name = companion.name
        switch companion.ask(question: question, note: args.string("context")) {
        case .success(let job):
            show(L("assistant.activity.companion", name))
            let waiting = job.state == .queued ? " It waits behind the question being answered now." : ""
            done(Self.text("Asked the companion (\(name), job \(job.id), \(job.model)).\(waiting) CC Desk will speak " +
                           "\(name)'s answer to the user directly when it is ready — do not answer the question " +
                           "yourself and do not repeat it. Reply exactly SILENT, or only a filler of a few words when " +
                           "the answer needs a web lookup (e.g. \"我问问\(name)\")."))
        case .failure(.disabled):
            done(Self.failure("The companion is turned off in Settings › Voice. Tell the user in a few words that " +
                              "\(name) is off (it can be turned on in Settings); do not answer the question yourself."))
        case .failure(.unavailable(let why)):
            done(Self.failure("The companion is not available: \(why). Tell the user briefly; do not answer it yourself."))
        case .failure(.queueFull):
            done(Self.failure("\(name) already has \(CompanionCommand.maxQueued) questions waiting; tell the user to " +
                              "wait a moment"))
        }
    }
}
