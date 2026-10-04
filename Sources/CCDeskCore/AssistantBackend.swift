import Foundation

// MARK: - 助手的「大脑」（设计 §22）：Claude Code 常驻会话 / OpenAI 兼容接口 / 仅本地规则

/// 一次助手请求的结果。
public struct AssistantReply: Equatable, Sendable {
    /// 要朗读的文字（最后一次工具调用之后的回复）。
    public let text: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let latency: TimeInterval

    public init(text: String, inputTokens: Int, outputTokens: Int, latency: TimeInterval) {
        self.text = text
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.latency = latency
    }
}

public enum AssistantError: Error, Equatable, Sendable {
    /// 没有可用的模型（找不到 claude / 没配置接口）：调用方把原话当作口述内容处理。
    case notInstalled
    case timeout
    case failed(String)
    /// 接口返回错误（简短说明，如 "HTTP 401"；不含密钥与消息内容）。
    case api(String)
}

/// 助手后端：VoiceAssistant 只通过它发消息。实现都保证 completion 在主线程、恰好调用一次；
/// 请求串行（一次只有一条在等回复），`currentTurn` 是正在等回复的那条的种类（工具权限据此判断）。
public protocol AssistantBackend: AnyObject {
    var kind: AssistantBackendKind { get }
    /// 每次换了一段新的对话（新进程 / 新会话 / 历史被裁剪）加一：调用方据此重发完整的侧栏上下文。
    var generation: Int { get }
    var currentTurn: AssistantTurn? { get }
    func ask(_ message: String, turn: AssistantTurn, timeout: TimeInterval,
             completion: @escaping (Result<AssistantReply, AssistantError>) -> Void)
    /// 预热（Claude：先启动进程；接口：什么都不做）。
    func warmUp()
    /// 丢弃对话记忆，下一条消息从头开始。
    func reset()
    func shutdown()
}

/// 设置里选的助手模型。
public enum AssistantBackendChoice: String, CaseIterable, Sendable {
    /// Claude Code 可用就用它，否则配置好的接口，否则仅本地规则。
    case auto
    case claude
    case api
    case local

    public static let defaultsKey = "assistantBackend"

    public init(stored: String?) {
        self = stored.flatMap(AssistantBackendChoice.init(rawValue:)) ?? .auto
    }
}

/// 实际使用的后端。
public enum AssistantBackendKind: String, Equatable, Sendable {
    case claude, api, local
}

public enum AssistantBackendSelector {
    /// 选哪个后端。claudeAvailable：解析到了 claude 可执行文件；apiConfigured：接口地址、模型（与需要的密钥）都填好了。
    /// 明确选了某个后端但它不可用时退回仅本地规则（不偷偷换成另一家：用户的话会发到哪里应当是用户选的）。
    public static func resolve(_ choice: AssistantBackendChoice, claudeAvailable: Bool,
                               apiConfigured: Bool) -> AssistantBackendKind {
        switch choice {
        case .auto: return claudeAvailable ? .claude : apiConfigured ? .api : .local
        case .claude: return claudeAvailable ? .claude : .local
        case .api: return apiConfigured ? .api : .local
        case .local: return .local
        }
    }

    /// 这个选择是否需要先解析 claude 路径（走一次登录 shell）。
    public static func needsClaude(_ choice: AssistantBackendChoice) -> Bool {
        choice == .auto || choice == .claude
    }
}

// MARK: - OpenAI 兼容接口的配置

/// 常见的 OpenAI 兼容服务（只是预填地址；都可以改）。
public enum AssistantAPIPreset: String, CaseIterable, Sendable {
    case openrouter, deepseek, dashscope, moonshot, ollama, lmstudio, custom

    public var baseURL: String {
        switch self {
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .dashscope: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .moonshot: return "https://api.moonshot.cn/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .lmstudio: return "http://localhost:1234/v1"
        case .custom: return ""
        }
    }

    /// 本机服务：不需要密钥。
    public var isLocal: Bool { self == .ollama || self == .lmstudio }

    /// 没有密钥就一定用不了（自定义的不确定，不要求）。
    public var requiresKey: Bool { !isLocal && self != .custom }

    /// 填写模型名时的示例（不代表推荐）。
    public var modelPlaceholder: String {
        switch self {
        case .openrouter: return "deepseek/deepseek-chat"
        case .deepseek: return "deepseek-chat"
        case .dashscope: return "qwen-plus"
        case .moonshot: return "kimi-k2-0905-preview"
        case .ollama: return "qwen3:14b"
        case .lmstudio: return "qwen3-14b"
        case .custom: return "model"
        }
    }

    public var displayName: String {
        switch self {
        case .openrouter: return "OpenRouter"
        case .deepseek: return "DeepSeek"
        case .dashscope: return "DashScope"
        case .moonshot: return "Kimi (Moonshot)"
        case .ollama: return "Ollama"
        case .lmstudio: return "LM Studio"
        case .custom: return "Custom"
        }
    }

    /// 钥匙串账户：每个服务一个，换服务时不会把一家的密钥发给另一家。
    public var keyAccount: String { "assistant.api.key.\(rawValue)" }
}

/// 接口设置（UserDefaults；密钥在钥匙串，见 `keyAccount`）。
public struct AssistantAPISettings: Equatable, Sendable {
    public static let presetKey = "assistantAPIPreset"
    public static let baseURLKey = "assistantAPIBaseURL"
    public static let modelKey = "assistantAPIModel"
    public static let consultModelKey = "assistantAPIConsultModel"
    /// 钥匙串的 service（条目由 CC Desk 自己创建，读取时不弹授权）。
    public static let keychainService = "dev.local.ccdesk.assistant"

    public var preset: AssistantAPIPreset
    public var baseURL: String
    public var model: String
    /// 顾问用的模型；空 = 与助手相同。
    public var consultModel: String

    public init(preset: AssistantAPIPreset = .deepseek, baseURL: String = "", model: String = "", consultModel: String = "") {
        self.preset = preset
        self.baseURL = baseURL
        self.model = model
        self.consultModel = consultModel
    }

    public static func load(_ defaults: UserDefaults = .standard) -> AssistantAPISettings {
        let preset = AssistantAPIPreset(rawValue: defaults.string(forKey: presetKey) ?? "") ?? .deepseek
        return AssistantAPISettings(preset: preset, baseURL: defaults.string(forKey: baseURLKey) ?? preset.baseURL,
                                    model: defaults.string(forKey: modelKey) ?? "",
                                    consultModel: defaults.string(forKey: consultModelKey) ?? "")
    }

    /// 规范化的地址：去掉首尾空白与末尾的 `/`；不是 http(s) 地址时 nil。
    public var endpoint: URL? {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    public var trimmedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 顾问实际用的模型。
    public var effectiveConsultModel: String {
        let consult = consultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return consult.isEmpty ? trimmedModel : consult
    }

    /// 能发请求：地址有效、填了模型、需要密钥的服务有密钥。
    public func isConfigured(hasKey: Bool) -> Bool {
        endpoint != nil && !trimmedModel.isEmpty && (hasKey || !preset.requiresKey)
    }

    /// 密钥会以明文发到别的机器上（http 且不是本机）。
    public func sendsKeyInPlaintext(hasKey: Bool) -> Bool {
        guard hasKey, let url = endpoint, url.scheme?.lowercased() == "http" else { return false }
        let host = url.host?.lowercased() ?? ""
        return !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    /// 显示用的名字：「DeepSeek · deepseek-chat」。
    public var label: String {
        let host = endpoint?.host ?? ""
        let service = preset == .custom ? host : preset.displayName
        return trimmedModel.isEmpty ? service : "\(service) · \(trimmedModel)"
    }
}
