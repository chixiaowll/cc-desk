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

    /// 按设置与当前情况选出的后端（claude 还没解析过时按「不可用」算，`prepare` 解析后再选一次）。只在主线程调用。
    var activeKind: AssistantBackendKind {
        AssistantBackendSelector.resolve(choice, claudeAvailable: isAvailable == true, apiConfigured: apiConfigured)
    }

    /// 当前后端。换了后端时停掉不再用的那个（Claude 进程不白白常驻）。只在主线程调用。
    var backend: AssistantBackend {
        let kind = activeKind
        if let last = lastKind, last != kind {
            AssistantDiag.log("assistant backend \(last.rawValue) -> \(kind.rawValue)")
            switch last {
            case .claude: session.shutdown()
            case .api: apiBackend.shutdown()
            case .local: break
            }
        }
        lastKind = kind
        switch kind {
        case .claude: return session
        case .api: return apiBackend
        case .local: return localBackend
        }
    }

    /// 有没有可用的模型：true / false；nil = 还要先解析 claude 才知道。只在主线程调用。
    var assistantAvailable: Bool? {
        if choice == .local { return false }
        if activeKind != .local { return true }
        if AssistantBackendSelector.needsClaude(choice), isAvailable == nil { return nil }
        return false
    }

    /// 顾问用哪个引擎：跟着当前后端走（仅本地规则时没有顾问）。只在主线程调用。
    var consultEngine: AssistantWork.ConsultEngine? {
        switch activeKind {
        case .claude: return .claude
        case .api: return .api
        case .local: return nil
        }
    }

    /// 设置页 / 结果面板里显示的当前后端。只在主线程调用。
    var activeLabel: String {
        switch activeKind {
        case .claude: return "Claude Code (\(Self.model))"
        case .api: return AssistantAPISettings.load().label
        case .local: return L("assistant.backend.local")
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
