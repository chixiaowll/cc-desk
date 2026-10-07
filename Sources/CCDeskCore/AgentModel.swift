import Foundation

/// 会话当前使用的模型（取自会话记录里最近的一条模型信息）。
public struct AgentModelInfo: Equatable, Sendable {
    /// 完整模型 id，如 "claude-fable-5-1"、"qwen/qwen3.8-27b:free"。
    public let id: String
    /// 提供方（Codex 的 model_provider、pi 的 provider）；Claude 记录里没有。
    public let provider: String?
    /// 推理强度（Claude 的 effort、Codex 的 effort / reasoning_effort、pi 的 thinkingLevel）。
    public let effort: String?

    public init(id: String, provider: String? = nil, effort: String? = nil) {
        self.id = id
        self.provider = provider
        self.effort = effort
    }

    /// 侧栏 / 标题栏用的短名：Claude 为友好名（不带 effort），其他为 id 最后一段 + 「 · effort」。
    public var shortName: String { AgentModelFormat.short(self) }

    /// 悬停提示用的完整描述：完整 id，后跟 effort / provider（有的话）。
    public var detail: String { AgentModelFormat.detail(self) }
}

/// 逐行累积会话记录里的模型信息，后出现的覆盖先出现的（latest wins）。
/// 由 TranscriptReader / AgentTranscriptReader 在已有的头部 / 尾部解析循环里喂入已解析的 JSON 对象，不额外读文件。
///
/// - Claude：assistant 记录 `{"type":"assistant","effort":…,"message":{"model":…}}`；`<synthetic>` / 空值跳过。
/// - Codex：`turn_context` 的 `payload.model` / `payload.effort`，`event_msg` / `thread_settings_applied` 的
///   `payload.thread_settings.model` / `reasoning_effort`，`session_meta` 的 `payload.model_provider`。
/// - pi：`{"type":"model_change","provider","modelId"}`、`{"type":"thinking_level_change","thinkingLevel"}`，
///   以及 assistant 消息里的 `message.model` / `message.provider`。
public struct AgentModelScanner: Sendable {
    public let kind: AgentKind
    public private(set) var id: String?
    public private(set) var provider: String?
    public private(set) var effort: String?

    public init(kind: AgentKind) {
        self.kind = kind
    }

    /// 结果；还没见到模型 id 时为 nil。
    public var info: AgentModelInfo? {
        id.map { AgentModelInfo(id: $0, provider: provider, effort: effort) }
    }

    public mutating func consume(_ obj: [String: Any]) {
        switch kind {
        case .claude: consumeClaude(obj)
        case .codex: consumeCodex(obj)
        case .pi, .opencode: consumePi(obj)
        case .other: break
        }
    }

    /// 以 `base`（通常来自头部）为底，用本扫描器（通常来自尾部）已有的字段覆盖。
    public func merged(over base: AgentModelScanner) -> AgentModelInfo? {
        guard let id = id ?? base.id else { return nil }
        return AgentModelInfo(id: id, provider: provider ?? base.provider, effort: effort ?? base.effort)
    }

    private mutating func consumeClaude(_ obj: [String: Any]) {
        guard obj["type"] as? String == "assistant", let m = obj["message"] as? [String: Any],
              let model = Self.clean(m["model"]), model != "<synthetic>" else { return }
        id = model
        effort = Self.clean(obj["effort"])
    }

    private mutating func consumeCodex(_ obj: [String: Any]) {
        guard let p = obj["payload"] as? [String: Any] else { return }
        switch obj["type"] as? String {
        case "session_meta":
            if let v = Self.clean(p["model_provider"]) { provider = v }
        case "turn_context":
            take(model: p["model"], effort: p["effort"] ?? p["reasoning_effort"])
        case "event_msg":
            guard let s = p["thread_settings"] as? [String: Any] else { return }
            take(model: s["model"], effort: s["reasoning_effort"] ?? s["effort"])
        default:
            break
        }
    }

    private mutating func consumePi(_ obj: [String: Any]) {
        switch obj["type"] as? String {
        case "model_change":
            guard let model = Self.clean(obj["modelId"]) else { return }
            id = model
            if let v = Self.clean(obj["provider"]) { provider = v }
        case "thinking_level_change":
            if let v = Self.clean(obj["thinkingLevel"]) { effort = v == "off" ? nil : v }
        case "message":
            guard let m = obj["message"] as? [String: Any], m["role"] as? String == "assistant",
                  let model = Self.clean(m["model"]) else { return }
            id = model
            if let v = Self.clean(m["provider"]) { provider = v }
        default:
            break
        }
    }

    private mutating func take(model: Any?, effort rawEffort: Any?) {
        guard let model = Self.clean(model) else { return }
        id = model
        if let v = Self.clean(rawEffort) { effort = v }
    }

    private static func clean(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

/// 模型名的显示规则。
public enum AgentModelFormat {
    /// Claude 为友好名（"claude-opus-5-5" → "Opus 5.5"），不带 effort；
    /// 其他取 id 最后一段（"qwen/qwen3.8-27b:free" → "qwen3.8-27b:free"），有 effort 时追加「 · high」。
    public static func short(_ info: AgentModelInfo) -> String {
        if let friendly = claudeName(info.id) { return friendly }
        let name = lastComponent(info.id)
        guard let effort = info.effort else { return name }
        return "\(name) · \(effort)"
    }

    /// "<完整 id>[ · effort <e>][ · <provider>]"。
    public static func detail(_ info: AgentModelInfo) -> String {
        var text = info.id
        if let effort = info.effort { text += " · effort \(effort)" }
        if let provider = info.provider { text += " · \(provider)" }
        return text
    }

    /// Claude 模型 id 的友好名：家族名 + 版本数字（以点连接），去掉日期后缀与 `[1m]` 之类的方括号后缀；
    /// 支持新旧两种顺序（"claude-opus-4-1" / "claude-3-5-sonnet"）。不是 Claude id 或无法识别时为 nil。
    public static func claudeName(_ id: String) -> String? {
        var raw = lastComponent(id).lowercased()
        if let bracket = raw.firstIndex(of: "[") { raw = String(raw[..<bracket]) }
        guard raw.hasPrefix("claude-") else { return nil }
        var family: [String] = []
        var version: [String] = []
        for token in raw.dropFirst("claude-".count).split(separator: "-").map(String.init) {
            if token.allSatisfy(\.isLetter) {
                family.append(token.prefix(1).uppercased() + token.dropFirst())
            } else if token.allSatisfy({ $0.isNumber || $0 == "." }) {
                // 8 位纯数字是日期后缀（如 20251001）。
                if token.count >= 8 { continue }
                version.append(token)
            } else {
                return nil
            }
        }
        guard !family.isEmpty else { return nil }
        let name = family.joined(separator: " ")
        return version.isEmpty ? name : "\(name) \(version.joined(separator: "."))"
    }

    static func lastComponent(_ id: String) -> String {
        let last = id.split(separator: "/").last.map(String.init) ?? id
        return last.isEmpty ? id : last
    }
}
