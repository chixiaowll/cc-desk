import AppKit
import CCDeskCore

/// 通用助手（设计 §24）：语音助手经 ask_companion 交来的非编程问题（生活、常识、新闻天气、情绪、闲聊）。只在主线程使用。
///
/// - 引擎跟着语音助手的后端走（`CompanionEngine`）：Claude Code 时是 Sonnet 常驻会话（AssistantSession，工作目录
///   ~/.cc-desk/companion，只有 WebSearch / WebFetch），通用 API 时是同一个服务的「通用助手模型」（APIAssistantBackend，
///   历史在 companion/api-history.json，没有工具），仅本地规则时不可用。
/// - 一次只回答一个，其余排队（最多 3 个）；每个回答 90 秒超时；「算了」/ 关闭对话模式取消。
/// - 答完：对话模式开着时等用户不在说话、助手不在忙时直接朗读（不经语音助手转述），长回答只念开头两三句，
///   「继续说」念下一段；关着时发通知。完整内容进「助手结果」面板（jobs.json，最近 30 条）。语音助手从上下文里的
///   companion 字段知道最近一次问答，追问因此会交回通用助手。
/// - 换了新会话（轮换 / 重置）后的第一问带上最近两次问答作前情提要。
final class CompanionWork: ObservableObject {
    static let notificationKey = "ccdesk:companion"
    /// 等可以朗读最多等多久（之后只留在结果面板里）。
    static let speechMaxWait: TimeInterval = 120

    @Published private(set) var book = CompanionBook()
    weak var model: AppModel?
    let directory: URL
    private var jobsURL: URL { directory.appendingPathComponent("jobs.json") }
    /// 正在回答的问题与处理它的后端。
    private var active: (id: String, engine: String)?
    /// 上一个回答还没念的部分（「继续说」）。
    private(set) var remaining: String?
    /// 等着朗读的回答。
    private var pendingSpeech: (text: String, at: TimeInterval)?
    private var speechTimer: Timer?
    /// 人设 / 上网开关改了，但当时正在回答：答完再重启进程。
    private var restartPending = false

    static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cc-desk/companion", isDirectory: true)
    }

    init(model: AppModel?, directory: URL = CompanionWork.defaultDirectory) {
        self.model = model
        self.directory = directory
    }

    /// 系统提示词：当前人设 + 能不能上网（每次启动进程 / 每轮接口请求时生成）。
    static func systemPrompt(web: Bool) -> String {
        CompanionPrompt.system(persona: .load(), language: Localization.currentLanguage, web: web)
    }

    private(set) lazy var claude = AssistantSession(
        directory: directory, model: CompanionCommand.model,
        system: { Self.systemPrompt(web: CompanionPreferences.load().web) }, promptVersion: CompanionPrompt.version,
        toolArguments: { CompanionCommand.toolArguments(web: CompanionPreferences.load().web) }, label: "companion",
        rotateInputTokens: CompanionCommand.rotateInputTokens, passControlToken: false,
        executable: { AssistantClient.shared.resolvedClaude() })

    private(set) lazy var api = APIAssistantBackend(
        store: AssistantChatHistoryStore(url: directory.appendingPathComponent("api-history.json")),
        endpoint: {
            let settings = AssistantAPISettings.load()
            return AssistantClient.shared.apiEndpoint(settings: settings,
                                                      model: settings.companionModel(AssistantAPISettings.companionModel()))
        },
        executor: { _, _, _, done in done(MCPServerCore.ToolOutcome(text: "no tools are available", isError: true)) },
        promptVersion: CompanionPrompt.version, system: { Self.systemPrompt(web: false) }, tools: [],
        label: "api companion")

    func start() {
        AssistantClient.prepareWorkingDirectory(directory)
        book = Self.load(jobsURL)
        book.recoverAfterRestart(now: Date())
    }

    /// 现在用哪个引擎。只在主线程调用（会读钥匙串）。
    var engine: CompanionEngine {
        CompanionEngine.resolve(.load(), backend: AssistantClient.shared.activeKind, api: .load(),
                                companionModel: AssistantAPISettings.companionModel())
    }

    /// 名字（语音助手的上下文、通知标题）。
    var name: String { CompanionPersona.load().effectiveName(language: Localization.currentLanguage) }

    /// 给语音助手的上下文：名字与十分钟内最近一次问答；关掉时 nil。
    func assistantContext() -> CompanionContext? {
        guard CompanionPreferences.load().enabled else { return nil }
        return CompanionContext(name: name, last: book.latestExchange(now: Date(), within: CompanionContext.window))
    }

    // MARK: 提问

    enum AskError: Error {
        case disabled
        case unavailable(String)
        case queueFull
    }

    func ask(question: String, note: String?) -> Result<CompanionJob, AskError> {
        let model: String
        let engine: String
        switch self.engine {
        case .claude(let m, _): (model, engine) = (m, "claude")
        case .api(let m): (model, engine) = (m, "api")
        case .unavailable(.disabled): return .failure(.disabled)
        case .unavailable(.localOnly): return .failure(.unavailable("no assistant model is configured (local rules only)"))
        case .unavailable(.resolving): return .failure(.unavailable("the assistant model is still being detected"))
        }
        if engine == "api", AssistantClient.shared.apiEndpoint(model: model) == nil {
            return .failure(.unavailable("the assistant API is not configured"))
        }
        switch book.enqueue(question: question, note: note, model: model, engine: engine, now: Date()) {
        case .failure: return .failure(.queueFull)
        case .success(let job):
            AssistantDiag.log("companion \(job.id) queued engine=\(engine) model=\(model) " +
                              "q=\"\(AssistantContext.clip(question, 120))\"")
            pump()
            save()
            return .success(book.job(job.id) ?? job)
        }
    }

    /// 没有在回答的时候开始下一个。
    private func pump() {
        guard active == nil, let job = book.startNext(now: Date()) else { return }
        active = (job.id, job.engine)
        let backend: AssistantBackend = job.engine == "claude" ? claude : api
        // 换了新会话（轮换 / 重置 / 提示词版本变了）：带上最近两次问答，接得上话。
        let fresh = job.engine == "claude" ? !claude.hasStoredConversation : api.turnCount == 0
        let message = CompanionPrompt.message(question: job.question, note: job.note, language: Localization.currentLanguage,
                                              now: Date(), timeZone: .current, recap: fresh ? book.recap() : [])
        let id = job.id
        AssistantDiag.log("companion \(id) asking (\(fresh ? "fresh" : "resumed") conversation)")
        backend.ask(message, turn: AssistantTurn(kind: .utterance), timeout: CompanionCommand.timeout) { [weak self] result in
            self?.answered(id, result)
        }
    }

    private func answered(_ id: String, _ result: Result<AssistantReply, AssistantError>) {
        if active?.id == id { active = nil }
        let now = Date()
        var finished: CompanionJob?
        switch result {
        case .success(let reply):
            let parsed = CompanionAnswer.parse(reply.text)
            if parsed.text.isEmpty {
                finished = book.finish(id, state: .failed, error: "empty answer", now: now)
            } else {
                let outcome = CompanionJob.Outcome(answer: parsed.text, sources: parsed.sources,
                                                   webLookups: CompanionAnswer.webLookups(reply.toolUses),
                                                   inputTokens: reply.inputTokens, outputTokens: reply.outputTokens)
                finished = book.finish(id, state: .done, outcome: outcome, now: now)
            }
        case .failure(.timeout):
            finished = book.finish(id, state: .timedOut, error: "timed out after \(Int(CompanionCommand.timeout)) seconds",
                                   now: now)
        case .failure(let error):
            finished = book.finish(id, state: .failed, error: Self.describe(error), now: now)
        }
        save()
        if let job = finished {
            AssistantDiag.log(String(format: "companion %@ %@ %.1fs in=%d out=%d web=%d sources=%d", id, job.state.rawValue,
                                     job.duration ?? 0, job.inputTokens, job.outputTokens, job.webLookups.count,
                                     job.sources.count))
            deliver(job)
        }
        if restartPending, active == nil, claude.restartIfIdle() { restartPending = false }
        pump()
    }

    static func describe(_ error: AssistantError) -> String {
        switch error {
        case .notInstalled: return "no model available"
        case .timeout: return "timed out"
        case .failed(let message): return message
        case .api(let detail): return "API error: \(detail)"
        }
    }

    // MARK: 播报

    private func deliver(_ job: CompanionJob) {
        guard let model else { return }
        let conversation = model.conversation
        guard job.state == .done, let answer = job.answer else {
            guard job.state != .cancelled else { return }
            let text = job.state == .timedOut ? L("companion.speech.timeout") : L("companion.speech.failed")
            if conversation.isOn { return speakWhenFree(text) }
            return model.notifier.postNotice(title: name, body: text, sessionKey: Self.notificationKey)
        }
        conversation.assistant.note("the companion answered \"\(AssistantContext.clip(job.question, 60))\"; " +
                                    "its answer was spoken to the user")
        let split = CompanionSpeech.split(answer)
        guard conversation.isOn else {
            remaining = nil
            let body = split.head.isEmpty ? AssistantContext.clip(answer, 200) : split.head
            return model.notifier.postNotice(title: name, body: body, sessionKey: Self.notificationKey)
        }
        remaining = split.rest
        speakWhenFree(split.head + (split.rest == nil ? "" : " " + L("companion.speech.more")))
    }

    /// 「继续说」：上一个回答剩下的下一段；没有时 nil。
    func continuation() -> String? {
        guard let rest = remaining else { return nil }
        let split = CompanionSpeech.split(rest)
        remaining = split.rest
        guard !split.head.isEmpty else { return nil }
        return split.head + (split.rest == nil ? "" : " " + L("companion.speech.more"))
    }

    /// 用户没在说话、语音助手不忙、没在播报时再念（最多等 `speechMaxWait` 秒）。
    private func speakWhenFree(_ text: String) {
        pendingSpeech = (text, ProcessInfo.processInfo.systemUptime)
        drainSpeech()
        guard pendingSpeech != nil, speechTimer == nil else { return }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in self?.drainSpeech() }
        RunLoop.main.add(timer, forMode: .common)
        speechTimer = timer
    }

    private func drainSpeech() {
        defer {
            if pendingSpeech == nil {
                speechTimer?.invalidate()
                speechTimer = nil
            }
        }
        guard let pending = pendingSpeech, let conversation = model?.conversation, conversation.isOn else {
            pendingSpeech = nil
            return
        }
        if ProcessInfo.processInfo.systemUptime - pending.at > Self.speechMaxWait {
            AssistantDiag.log("companion answer not spoken (user stayed busy)")
            pendingSpeech = nil
            return
        }
        guard !conversation.isBusyForProactive else { return }
        pendingSpeech = nil
        conversation.speakCompanion(pending.text)
    }

    // MARK: 取消与设置

    /// 有排队 / 回答中的问题，或有等着朗读的回答。
    var isBusy: Bool { book.hasActive || pendingSpeech != nil }

    /// 取消排队 / 回答中的问题与等着朗读的回答（「算了」/ 关闭对话模式）；返回是否取消了什么。
    @discardableResult
    func cancel(reason: String) -> Bool {
        let hadSpeech = pendingSpeech != nil
        pendingSpeech = nil
        let ids = book.cancelAll(now: Date())
        if let running = active, ids.contains(running.id) {
            running.engine == "claude" ? claude.interrupt("cancelled") : api.cancelCurrent()
            active = nil
        }
        guard !ids.isEmpty || hadSpeech else { return false }
        AssistantDiag.log("companion cancelled (\(reason)): \(ids)")
        save()
        return true
    }

    /// 人设 / 上网开关改了：Claude 进程用新的系统提示词与工具重启（接回同一会话，记忆不丢）；正在回答时答完再重启。
    /// 接口版每轮都重新生成系统提示词，不需要做什么。
    func settingsChanged() {
        restartPending = !claude.restartIfIdle()
        AssistantDiag.log("companion settings changed (restart \(restartPending ? "after this answer" : "now"))")
    }

    /// 「清空通用助手记忆」：取消进行中的，丢掉 Claude 会话与接口历史、结果记录，删掉它工作目录对应的 Claude 会话记录。
    func clearMemory() {
        cancel(reason: "clear memory")
        claude.reset()
        api.reset()
        remaining = nil
        book.clear()
        save()
        let projects = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(ClaudeProjectDirectory.name(for: Self.realPath(directory.path)), isDirectory: true)
        // 稍等：被停掉的进程可能还在写最后几行。
        Self.ioQueue.asyncAfter(deadline: .now() + 1) {
            let files = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jsonl" { try? FileManager.default.removeItem(at: file) }
            AssistantDiag.log("companion memory cleared (\(files.count) transcript file(s))")
        }
    }

    func shutdown() {
        claude.shutdown()
    }

    /// claude 用工作目录的真实路径（/var → /private/var）编码记录目录；`resolvingSymlinksInPath` 会去掉 /private，不能用。
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: 持久化

    private static let ioQueue = DispatchQueue(label: "cc-desk.companion.io")

    static func load(_ url: URL) -> CompanionBook {
        guard let data = try? Data(contentsOf: url) else { return CompanionBook() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(CompanionBook.self, from: data)) ?? CompanionBook()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(book) else { return }
        let url = jobsURL
        let directory = self.directory
        Self.ioQueue.async {
            AssistantClient.prepareWorkingDirectory(directory)
            try? data.write(to: url, options: .atomic)
            chmod(url.path, 0o600)
        }
    }
}
