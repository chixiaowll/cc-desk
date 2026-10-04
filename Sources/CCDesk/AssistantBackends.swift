import Foundation
import CCDeskCore

/// 接口后端执行一个助手工具：名字、参数、发起调用的那一轮（权限据此判断），结果在主线程回调。
typealias AssistantToolExecutor = (_ name: String, _ arguments: [String: JSONValue], _ turn: AssistantTurn?,
                                   _ completion: @escaping (MCPServerCore.ToolOutcome) -> Void) -> Void

/// 常驻 Claude 会话就是一个后端（行为不变，设计 §12/§13）。
extension AssistantSession: AssistantBackend {
    var kind: AssistantBackendKind { .claude }
}

/// 仅本地规则：没有模型。每个请求都回 `.notInstalled`（调用方把原话当作口述内容填入，与找不到 claude 时相同）。
final class LocalAssistantBackend: AssistantBackend {
    let kind = AssistantBackendKind.local
    let generation = 0
    var currentTurn: AssistantTurn? { nil }

    func ask(_ message: String, turn: AssistantTurn, timeout: TimeInterval,
             completion: @escaping (Result<AssistantReply, AssistantError>) -> Void) {
        DispatchQueue.main.async { completion(.failure(.notInstalled)) }
    }

    func warmUp() {}
    func reset() {}
    func shutdown() {}
}

/// 接口密钥：钥匙串里按地址分账户（`AssistantAPISettings.keyAccount`：服务预设地址用服务的账户，其他地址按来源），
/// 第一次用到时在主线程读出并缓存在内存（与推送密钥相同的做法：重新签名后钥匙串可能弹授权，不能在后台队列上读）。
/// 只在主线程使用。
final class AssistantAPIKeys {
    private let store: SecretStore
    private var cache: [String: String] = [:]

    init(store: SecretStore) {
        self.store = store
    }

    func key(account: String) -> String {
        if let cached = cache[account] { return cached }
        let value = store.read(account) ?? ""
        cache[account] = value
        return value
    }

    /// 这套设置要发的密钥（本机服务、地址无效时为空）。
    func key(for settings: AssistantAPISettings) -> String {
        guard !settings.preset.isLocal, let account = settings.keyAccount else { return "" }
        return key(account: account)
    }

    /// 设置页打开时重新读一次（可能在别处改过）。
    func reload() {
        cache = [:]
    }

    /// 空白 = 删除。值没变时不写钥匙串。
    func save(_ value: String, account: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != key(account: account) else { return }
        try store.write(trimmed, account: account)
        cache[account] = trimmed
    }
}

/// 发请求要用的东西（设置 + 密钥的快照）。
struct APIEndpoint {
    let base: URL
    let model: String
    let apiKey: String?
    let label: String
}

extension AssistantClient {
    var choice: AssistantBackendChoice {
        AssistantBackendChoice(stored: UserDefaults.standard.string(forKey: AssistantBackendChoice.defaultsKey))
    }

    /// 当前的接口设置与密钥；没配置好时 nil。只在主线程调用（会读钥匙串）。
    func apiEndpoint(settings: AssistantAPISettings = .load(), model override: String? = nil) -> APIEndpoint? {
        let key = apiKeys.key(for: settings)
        guard settings.isConfigured(hasKey: !key.isEmpty), let base = settings.endpoint else { return nil }
        let model = override ?? settings.trimmedModel
        return APIEndpoint(base: base, model: model, apiKey: key.isEmpty ? nil : key, label: settings.label)
    }

    var apiConfigured: Bool { apiEndpoint() != nil }

    /// 按设置与当前情况选出的后端；nil = 需要 claude 而它还在解析（`prepare` 解析后再选）。只在主线程调用。
    var activeKind: AssistantBackendKind? {
        AssistantBackendSelector.resolve(choice, claudeAvailable: isAvailable, apiConfigured: apiConfigured)
    }

    /// 当前后端；claude 还在解析时是 `pendingBackend`（请求攒着，解析完再交给选出的后端）。只在主线程调用。
    var backend: AssistantBackend {
        guard let kind = activeKind else { return pendingBackend }
        return activate(kind)
    }

    /// 等待解析结束（或等够了）之后选后端：仍不知道 claude 在不在时按不可用算。只在主线程调用。
    func decidedBackend() -> AssistantBackend {
        let kind = activeKind ?? AssistantBackendSelector.resolve(choice, claudeAvailable: false,
                                                                    apiConfigured: apiConfigured) ?? .local
        return activate(kind)
    }

    /// 选用 kind 的后端。换了后端时不再用的那个等它空闲了再停（不打断正在进行的一轮，见 `AssistantBackendSwitch`）。
    private func activate(_ kind: AssistantBackendKind) -> AssistantBackend {
        if let previous = backendSwitch.active, previous != kind {
            AssistantDiag.log("assistant backend \(previous.rawValue) -> \(kind.rawValue)")
        }
        let idle = backendSwitch.activate(kind, busy: isBusy)
        idle.forEach(shutdownBackend)
        scheduleRetireCheck()
        return object(for: kind)
    }

    private func object(for kind: AssistantBackendKind) -> AssistantBackend {
        switch kind {
        case .claude: return session
        case .api: return apiBackend
        case .local: return localBackend
        }
    }

    private func isBusy(_ kind: AssistantBackendKind) -> Bool {
        object(for: kind).currentTurn != nil
    }

    private func shutdownBackend(_ kind: AssistantBackendKind) {
        AssistantDiag.log("assistant backend \(kind.rawValue) stopped (no longer selected)")
        object(for: kind).shutdown()
    }

    /// 还有退役中（正忙）的后端时每秒看一次，空闲了就停掉。
    private func scheduleRetireCheck() {
        guard !backendSwitch.retiring.isEmpty, !retireCheckScheduled else { return }
        retireCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.retireCheckScheduled = false
            self.backendSwitch.sweep(busy: self.isBusy).forEach(self.shutdownBackend)
            self.scheduleRetireCheck()
        }
    }

    /// 有没有可用的模型：true / false；nil = 还要先解析 claude 才知道。只在主线程调用。
    var assistantAvailable: Bool? {
        if choice == .local { return false }
        guard let kind = activeKind else { return nil }
        return kind != .local
    }

    /// 顾问用哪个引擎：跟着当前后端走（仅本地规则、还在解析 claude 时没有顾问）。只在主线程调用。
    var consultEngine: AssistantWork.ConsultEngine? {
        switch activeKind {
        case .claude?: return .claude
        case .api?: return .api
        case .local?, nil: return nil
        }
    }

    /// 设置页 / 结果面板里显示的当前后端。只在主线程调用。
    var activeLabel: String {
        switch activeKind {
        case .claude?: return "Claude Code (\(Self.model))"
        case .api?: return AssistantAPISettings.load().label
        case .local?: return L("assistant.backend.local")
        case nil: return L("assistant.backend.resolving")
        }
    }

    /// 打开对话模式 / 改了设置时：需要时先解析 claude，再选后端并预热；completion(有没有模型) 在主线程。
    func prepareBackend(completion: ((Bool) -> Void)? = nil) {
        let finish = { [weak self] in
            guard let self else { return }
            let backend = self.backend
            backend.warmUp()
            AssistantDiag.log("assistant backend \(backend.kind.rawValue) (choice \(self.choice.rawValue))")
            let ok = backend.kind != .local
            // 总是异步回调（不需要解析 claude 时这里是同步走到的，调用方可能还没准备好）。
            DispatchQueue.main.async { completion?(ok) }
        }
        guard AssistantBackendSelector.needsClaude(choice) else { return finish() }
        prepare { _ in finish() }
    }
}

/// 需要 claude 而它还在解析时（登录 shell 最多约 6 秒）的后端（设计 §22）：请求先攒着，解析完再交给选出的后端；
/// 最多等 `maxHold` 秒，仍不知道就按 claude 不可用来选。这样自动模式不会先把话发给第三方接口、等 claude 解析出来
/// 再中止那一轮。等待的时间从请求的超时里扣掉。只在主线程使用；completion 恰好一次（由接手的后端保证）。
final class PendingAssistantBackend: AssistantBackend {
    static let maxHold: TimeInterval = 8

    /// 不会真正处理请求；按「没有模型」报告种类（调用方据此重发完整上下文）。
    let kind = AssistantBackendKind.local
    let generation = 0
    var currentTurn: AssistantTurn? { nil }

    private struct Held {
        let message: String
        let turn: AssistantTurn
        let timeout: TimeInterval
        let heldAt: Date
        let completion: (Result<AssistantReply, AssistantError>) -> Void
    }

    private let prepare: (@escaping () -> Void) -> Void
    private let decide: () -> AssistantBackend
    private var held: [Held] = []
    private var waitID = 0
    private var waiting = false

    init(prepare: @escaping (@escaping () -> Void) -> Void, decide: @escaping () -> AssistantBackend) {
        self.prepare = prepare
        self.decide = decide
    }

    /// 攒着的请求数（自检用）。
    var heldCount: Int { held.count }

    func ask(_ message: String, turn: AssistantTurn, timeout: TimeInterval,
             completion: @escaping (Result<AssistantReply, AssistantError>) -> Void) {
        held.append(Held(message: message, turn: turn, timeout: timeout, heldAt: Date(), completion: completion))
        guard !waiting else { return }
        waiting = true
        waitID += 1
        let id = waitID
        AssistantDiag.log("assistant backend undecided: holding requests until claude is resolved")
        prepare { [weak self] in self?.release(id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxHold) { [weak self] in self?.release(id) }
    }

    private func release(_ id: Int) {
        guard waiting, id == waitID else { return }
        waiting = false
        let items = held
        held = []
        let target = decide()
        AssistantDiag.log("assistant backend decided: \(target.kind.rawValue), releasing \(items.count) held request(s)")
        for item in items {
            let left = item.timeout - Date().timeIntervalSince(item.heldAt)
            target.ask(item.message, turn: item.turn, timeout: max(5, left), completion: item.completion)
        }
    }

    func warmUp() {}
    func reset() {}

    func shutdown() {
        waiting = false
        waitID += 1
        let items = held
        held = []
        items.forEach { item in DispatchQueue.main.async { item.completion(.failure(.failed("stopped"))) } }
    }
}
