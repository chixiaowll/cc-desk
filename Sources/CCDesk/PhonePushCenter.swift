import AppKit
import CoreGraphics
import CCDeskCore

/// 推送到手机（设置 › 通知 › 推送到手机）：在发系统通知的同一处（AppModel 处理状态变化事件时）调用。
/// 是否推送、限流、请求格式在 CCDeskCore（`PushPolicy` / `PushRateLimiter` / `PushRequestBuilder`）；
/// 这里只采集「是否离开」、读写 Keychain、用 URLSession 在后台发送并把结果记到 AssistantDiag（不记密钥和地址）。
/// 密钥只在主线程读写 Keychain（第一次推送 / 设置页打开或修改时），缓存在内存里给发送队列用：
/// 重新签名后 Keychain 可能弹出访问授权框，在后台队列上读会一直卡住推送。
/// `handle` / `sendTest` / 密钥读写只在主线程调用；网络请求不在主线程，不会阻塞轮询。
final class PhonePushCenter {
    enum Outcome: Equatable {
        case sent(Int)
        case failed(String)
    }

    /// 推送密钥的存储（Keychain）。
    private let store: SecretStore
    private let queue = DispatchQueue(label: "cc-desk.push")
    private let session: URLSession
    private var limiter = PushRateLimiter()
    /// 内存里的密钥；nil = 还没从 Keychain 读过。只在主线程读写。
    private var cachedSecrets: PushSecrets?

    init(secrets: SecretStore = KeychainSecretStore.push) {
        self.store = secrets
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// 当前密钥（第一次在主线程从 Keychain 读取，之后用内存里的）。
    var secrets: PushSecrets {
        if let cachedSecrets { return cachedSecrets }
        let loaded = PushSecrets.load(store)
        cachedSecrets = loaded
        return loaded
    }

    /// 设置页打开时：重新从 Keychain 读一次（可能在别处改过）。
    @discardableResult
    func reloadSecrets() -> PushSecrets {
        cachedSecrets = nil
        return secrets
    }

    /// 设置页修改密钥：只写变了的项（空白 = 删除），成功后更新内存里的值。
    func saveSecrets(_ new: PushSecrets) throws {
        let old = secrets
        let pairs: [(PushSecretKey, String, String)] = [
            (.barkDeviceKey, new.barkDeviceKey, old.barkDeviceKey),
            (.ntfyTopic, new.ntfyTopic, old.ntfyTopic),
            (.ntfyToken, new.ntfyToken, old.ntfyToken),
            (.webhookURL, new.webhookURL, old.webhookURL),
        ]
        var saved = old
        defer { cachedSecrets = saved }
        for (key, value, previous) in pairs where value != previous {
            try store.write(value, account: key.rawValue)
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case .barkDeviceKey: saved.barkDeviceKey = trimmed
            case .ntfyTopic: saved.ntfyTopic = trimmed
            case .ntfyToken: saved.ntfyToken = trimmed
            case .webhookURL: saved.webhookURL = trimmed
            }
        }
    }

    /// 本轮交给推送的事件（EventRouting 已决定：别的会话照常；正看着的会话只在离开时）；rows 用来取项目名与会话标题。
    /// presence：调用方已采集过时传入，否则这里采集。
    func handle(_ events: [StatusEvent], rows: [SidebarRow], presence known: PushPresence? = nil) {
        guard !events.isEmpty else { return }
        let settings = PushSettings.load()
        guard settings.provider != .none else { return }
        let presence = known ?? PresenceProbe.current()
        let now = Date()
        for event in events where PushPolicy.shouldPush(event.kind, settings: settings, presence: presence) {
            guard let row = rows.first(where: { $0.id == event.sessionKey }) else { continue }
            let key = PushPolicy.dedupeKey(sessionKey: event.sessionKey, kind: event.kind)
            guard limiter.admit(key: key, now: now) else {
                AssistantDiag.log("push skipped rate-limited provider=\(settings.provider.rawValue)")
                continue
            }
            send(PushMessage.make(event: event, row: row, includeReason: settings.includeReason), settings: settings) { _ in }
        }
    }

    /// 设置里的「发送测试推送」：不看推送时机与限流，结果在主线程回调。
    func sendTest(completion: @escaping (Outcome) -> Void) {
        send(.test(), settings: PushSettings.load(), completion: completion)
    }

    private func send(_ message: PushMessage, settings: PushSettings, completion: @escaping (Outcome) -> Void) {
        let provider = settings.provider.rawValue
        let status = message.status.rawValue
        let secrets = self.secrets
        queue.async { [session] in
            /// detail：写进诊断日志的说明（不含密钥、地址和推送内容）。
            let finish: (Outcome, String) -> Void = { outcome, detail in
                AssistantDiag.log("push provider=\(provider) status=\(status) \(detail)")
                DispatchQueue.main.async { completion(outcome) }
            }
            let built = PushRequestBuilder.request(message, settings: settings, secrets: secrets)
            let request: PushRequest
            switch built {
            case .success(let value): request = value
            case .failure(let error): return finish(.failed(error.message), "not sent: \(error)")
            }
            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = request.method
            urlRequest.httpBody = request.body
            for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
            session.dataTask(with: urlRequest) { _, response, error in
                if let error {
                    // 日志只记错误域和错误码（userInfo 里带完整 URL，可能含 Webhook 地址）。
                    let ns = error as NSError
                    return finish(.failed(L("push.result.network", ns.localizedDescription)),
                                  "failed: \(ns.domain) \(ns.code)")
                }
                let http = (response as? HTTPURLResponse)?.statusCode ?? 0
                let ok = (200..<300).contains(http)
                finish(ok ? .sent(http) : .failed(L("push.result.http", http)), ok ? "sent http=\(http)" : "failed http=\(http)")
            }.resume()
        }
    }
}

/// 「是否离开 Mac」：距上次键盘 / 鼠标输入的秒数（不需要辅助功能权限）与屏幕是否锁定。
enum PresenceProbe {
    static func current() -> PushPresence {
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        return PushPresence(idleSeconds: idle, screenLocked: locked)
    }
}
