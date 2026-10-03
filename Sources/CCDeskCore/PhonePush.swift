import Foundation

// 推送到手机（设置 › 通知 › 推送到手机）的纯逻辑：设置、是否推送、限流去重、各服务的请求格式。
// App 层（PhonePushCenter）负责读 Keychain、判断是否离开、发 HTTP 请求。

/// 推送服务。
public enum PushProvider: String, CaseIterable, Identifiable, Sendable {
    case none, bark, ntfy, webhook
    public var id: String { rawValue }
}

/// 什么时候推送。
public enum PushCondition: String, CaseIterable, Identifiable, Sendable {
    /// 每次都推送（仍受事件开关与限流约束）。
    case always
    /// 只在离开 Mac 时：空闲 ≥ 3 分钟或屏幕已锁定。
    case whenAway
    public var id: String { rawValue }
}

/// 推送设置（UserDefaults）。密钥类的值（Bark 设备 key、ntfy 主题与令牌、Webhook 地址）不在这里，见 `PushSecretKey`。
public struct PushSettings: Equatable, Sendable {
    public static let providerKey = "pushProvider"
    public static let barkServerKey = "pushBarkServer"
    public static let ntfyServerKey = "pushNtfyServer"
    public static let onWaitingKey = "pushOnWaiting"
    public static let onFinishedKey = "pushOnFinished"
    public static let conditionKey = "pushCondition"

    public static let defaultBarkServer = "https://api.day.app"
    public static let defaultNtfyServer = "https://ntfy.sh"

    public var provider: PushProvider
    public var barkServer: String
    public var ntfyServer: String
    public var onWaiting: Bool
    public var onFinished: Bool
    public var condition: PushCondition

    public init(provider: PushProvider = .none, barkServer: String = PushSettings.defaultBarkServer,
                ntfyServer: String = PushSettings.defaultNtfyServer, onWaiting: Bool = true, onFinished: Bool = false,
                condition: PushCondition = .whenAway) {
        self.provider = provider
        self.barkServer = barkServer
        self.ntfyServer = ntfyServer
        self.onWaiting = onWaiting
        self.onFinished = onFinished
        self.condition = condition
    }

    public static func load(_ defaults: UserDefaults = .standard) -> PushSettings {
        func text(_ key: String, _ fallback: String) -> String {
            let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? fallback : value
        }
        return PushSettings(
            provider: PushProvider(rawValue: defaults.string(forKey: providerKey) ?? "") ?? .none,
            barkServer: text(barkServerKey, defaultBarkServer),
            ntfyServer: text(ntfyServerKey, defaultNtfyServer),
            onWaiting: defaults.object(forKey: onWaitingKey) as? Bool ?? true,
            onFinished: defaults.object(forKey: onFinishedKey) as? Bool ?? false,
            condition: PushCondition(rawValue: defaults.string(forKey: conditionKey) ?? "") ?? .whenAway)
    }

    public func allows(_ kind: StatusEvent.Kind) -> Bool {
        switch kind {
        case .needsInput: return onWaiting
        case .finished: return onFinished
        }
    }
}

/// Keychain 里的推送密钥（generic password，service 见 `PushSecrets.service`，account 为 rawValue）。
public enum PushSecretKey: String, CaseIterable, Sendable {
    case barkDeviceKey = "bark.deviceKey"
    /// ntfy.sh 上的主题名就是事实上的密码（知道主题就能订阅），所以也放 Keychain。
    case ntfyTopic = "ntfy.topic"
    case ntfyToken = "ntfy.token"
    case webhookURL = "webhook.url"
}

/// 存取密钥的抽象：App 用 Keychain，测试用内存实现（测试不碰真实 Keychain）。
public protocol SecretStore: AnyObject {
    func read(_ account: String) -> String?
    /// value 为 nil 或空白时删除。
    func write(_ value: String?, account: String) throws
}

public final class InMemorySecretStore: SecretStore {
    private var values: [String: String]
    private let lock = NSLock()

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public func read(_ account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    public func write(_ value: String?, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        values[account] = trimmed.isEmpty ? nil : trimmed
    }
}

public struct PushSecrets: Equatable, Sendable {
    public static let service = "dev.local.ccdesk.push"

    public var barkDeviceKey: String
    public var ntfyTopic: String
    public var ntfyToken: String
    public var webhookURL: String

    public init(barkDeviceKey: String = "", ntfyTopic: String = "", ntfyToken: String = "", webhookURL: String = "") {
        self.barkDeviceKey = barkDeviceKey
        self.ntfyTopic = ntfyTopic
        self.ntfyToken = ntfyToken
        self.webhookURL = webhookURL
    }

    public static func load(_ store: SecretStore) -> PushSecrets {
        func value(_ key: PushSecretKey) -> String {
            store.read(key.rawValue)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return PushSecrets(barkDeviceKey: value(.barkDeviceKey), ntfyTopic: value(.ntfyTopic),
                           ntfyToken: value(.ntfyToken), webhookURL: value(.webhookURL))
    }
}

/// 推送的事件状态（webhook 的 `status` 字段）。
public enum PushStatus: String, Sendable {
    case waiting, finished, test
}

/// 一条推送的内容：只有项目名、会话标题、状态和简短原因，不带对话内容。
public struct PushMessage: Equatable, Sendable {
    /// 原因（如等待批准的命令）最多保留的字数。
    public static let reasonLimit = 100
    /// 会话标题最多保留的字数。
    public static let titleLimit = 60

    public let title: String
    public let body: String
    public let session: String
    public let project: String
    public let status: PushStatus
    public let url: String?

    public init(title: String, body: String, session: String, project: String, status: PushStatus, url: String? = nil) {
        self.title = title
        self.body = body
        self.session = session
        self.project = project
        self.status = status
        self.url = url
    }

    /// 标题「<项目> · <会话标题>」（两者相同或项目为空时只写会话标题）；正文「等批准：<原因>」/「已完成」。
    public static func make(kind: StatusEvent.Kind, project: String, sessionTitle: String, reason: String?) -> PushMessage {
        let session = SidebarBuilder.singleLine(sessionTitle, maxLength: titleLimit)
        let projectName = SidebarBuilder.singleLine(project, maxLength: titleLimit)
        let title = projectName.isEmpty || projectName == session ? session : "\(projectName) · \(session)"
        let status: PushStatus = kind == .needsInput ? .waiting : .finished
        let statusText = kind == .needsInput ? L("status.waiting") : L("status.done")
        let short = reason.map { ApprovalNotification.body($0, limit: reasonLimit) } ?? ""
        let body = short.isEmpty ? statusText : L("push.body", statusText, short)
        return PushMessage(title: title, body: body, session: session, project: projectName, status: status)
    }

    public static func make(event: StatusEvent, row: SidebarRow) -> PushMessage {
        make(kind: event.kind, project: row.groupTitle, sessionTitle: row.notificationName, reason: event.reason)
    }

    /// 设置里「发送测试推送」的内容。
    public static func test() -> PushMessage {
        PushMessage(title: L("push.test.title"), body: L("push.test.body"), session: "CC Desk", project: "CC Desk",
                    status: .test)
    }
}

/// 当前是否离开 Mac 的观测值（App 层用 CGEventSource / CGSession 采集）。
public struct PushPresence: Equatable, Sendable {
    public let idleSeconds: TimeInterval
    public let screenLocked: Bool

    public init(idleSeconds: TimeInterval, screenLocked: Bool) {
        self.idleSeconds = idleSeconds
        self.screenLocked = screenLocked
    }
}

public enum PushPolicy {
    /// 「离开时」：空闲达到这个秒数或屏幕锁定。
    public static let awayIdleSeconds: TimeInterval = 180

    public static func isAway(_ presence: PushPresence) -> Bool {
        presence.screenLocked || presence.idleSeconds >= awayIdleSeconds
    }

    /// 是否要为这个事件推送（不含限流）：已选服务、事件已勾选、满足推送时机。
    public static func shouldPush(_ kind: StatusEvent.Kind, settings: PushSettings, presence: PushPresence) -> Bool {
        guard settings.provider != .none, settings.allows(kind) else { return false }
        switch settings.condition {
        case .always: return true
        case .whenAway: return isAway(presence)
        }
    }

    /// 限流去重的键：同一会话的同一种状态。
    public static func dedupeKey(sessionKey: String, kind: StatusEvent.Kind) -> String {
        "\(sessionKey)|\(kind == .needsInput ? PushStatus.waiting.rawValue : PushStatus.finished.rawValue)"
    }
}

/// 限流：同一键（会话 + 状态）至少间隔 `perKeyInterval`；所有推送在 `globalWindow` 内最多 `globalLimit` 条。
/// 只在一个线程上使用（App 在主线程）。
public struct PushRateLimiter: Sendable {
    public let perKeyInterval: TimeInterval
    public let globalLimit: Int
    public let globalWindow: TimeInterval
    private var lastByKey: [String: Date] = [:]
    private var recent: [Date] = []

    public init(perKeyInterval: TimeInterval = 120, globalLimit: Int = 20, globalWindow: TimeInterval = 3600) {
        self.perKeyInterval = perKeyInterval
        self.globalLimit = globalLimit
        self.globalWindow = globalWindow
    }

    /// 允许时记下这次并返回 true。
    public mutating func admit(key: String, now: Date) -> Bool {
        recent.removeAll { now.timeIntervalSince($0) >= globalWindow }
        lastByKey = lastByKey.filter { now.timeIntervalSince($0.value) < perKeyInterval }
        guard lastByKey[key] == nil, recent.count < globalLimit else { return false }
        lastByKey[key] = now
        recent.append(now)
        return true
    }
}

/// 发给推送服务的 HTTP 请求。
public struct PushRequest: Equatable, Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data
}

public enum PushConfigError: Error, Equatable, Sendable {
    case notConfigured
    case missingDeviceKey
    case missingTopic
    case missingWebhookURL
    case invalidURL

    public var message: String {
        switch self {
        case .notConfigured: return L("push.error.notConfigured")
        case .missingDeviceKey: return L("push.error.missingDeviceKey")
        case .missingTopic: return L("push.error.missingTopic")
        case .missingWebhookURL: return L("push.error.missingWebhookURL")
        case .invalidURL: return L("push.error.invalidURL")
        }
    }
}

public enum PushRequestBuilder {
    public static let group = "CC Desk"

    public static func request(_ message: PushMessage, settings: PushSettings,
                               secrets: PushSecrets) -> Result<PushRequest, PushConfigError> {
        switch settings.provider {
        case .none:
            return .failure(.notConfigured)
        case .bark:
            guard !secrets.barkDeviceKey.isEmpty else { return .failure(.missingDeviceKey) }
            guard let base = httpURL(settings.barkServer) else { return .failure(.invalidURL) }
            var json: [String: Any] = ["device_key": secrets.barkDeviceKey, "title": message.title, "body": message.body,
                                       "group": group]
            if message.status == .waiting { json["level"] = "timeSensitive" }
            if let url = message.url { json["url"] = url }
            return jsonRequest(base.appendingPathComponent("push"), json, headers: [:])
        case .ntfy:
            guard !secrets.ntfyTopic.isEmpty else { return .failure(.missingTopic) }
            guard let base = httpURL(settings.ntfyServer) else { return .failure(.invalidURL) }
            // JSON 发布（POST 到服务根地址）：标题放 JSON 里，避免 HTTP 头不能放中文。
            var json: [String: Any] = ["topic": secrets.ntfyTopic, "title": message.title, "message": message.body,
                                       "priority": message.status == .waiting ? 4 : 3,
                                       "tags": [message.status == .waiting ? "warning" : "white_check_mark"]]
            if let url = message.url { json["click"] = url }
            var headers: [String: String] = [:]
            if !secrets.ntfyToken.isEmpty { headers["Authorization"] = "Bearer \(secrets.ntfyToken)" }
            return jsonRequest(base, json, headers: headers)
        case .webhook:
            guard !secrets.webhookURL.isEmpty else { return .failure(.missingWebhookURL) }
            guard let url = httpURL(secrets.webhookURL) else { return .failure(.invalidURL) }
            var json: [String: Any] = ["title": message.title, "body": message.body, "session": message.session,
                                       "project": message.project, "status": message.status.rawValue]
            if let link = message.url { json["url"] = link }
            return jsonRequest(url, json, headers: [:])
        }
    }

    /// 只接受 http / https 且有主机名的地址；去掉末尾的斜杠。
    static func httpURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private static func jsonRequest(_ url: URL, _ json: [String: Any],
                                    headers: [String: String]) -> Result<PushRequest, PushConfigError> {
        guard let body = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            return .failure(.invalidURL)
        }
        var all = headers
        all["Content-Type"] = "application/json; charset=utf-8"
        return .success(PushRequest(url: url, method: "POST", headers: all, body: body))
    }
}
