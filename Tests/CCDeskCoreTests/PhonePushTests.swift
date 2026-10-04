import XCTest
@testable import CCDeskCore

final class PhonePushTests: ZhHansTestCase {
    private let present = PushPresence(idleSeconds: 5, screenLocked: false)
    private let idle = PushPresence(idleSeconds: 200, screenLocked: false)
    private let locked = PushPresence(idleSeconds: 0, screenLocked: true)

    private func defaults() -> UserDefaults {
        let name = "PhonePushTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name) ?? .standard
        suite.removePersistentDomain(forName: name)
        return suite
    }

    private func json(_ request: PushRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    // MARK: 设置

    func testDefaultSettings() {
        let settings = PushSettings.load(defaults())
        XCTAssertEqual(settings, PushSettings())
        XCTAssertEqual(settings.provider, .none)
        XCTAssertEqual(settings.barkServer, "https://api.day.app")
        XCTAssertEqual(settings.ntfyServer, "https://ntfy.sh")
        XCTAssertTrue(settings.onWaiting)
        XCTAssertFalse(settings.onFinished)
        XCTAssertEqual(settings.condition, .whenAway)
    }

    func testLoadStoredSettingsAndBlankServerFallsBack() {
        let d = defaults()
        d.set("ntfy", forKey: PushSettings.providerKey)
        d.set("  ", forKey: PushSettings.ntfyServerKey)
        d.set(" https://bark.example.com ", forKey: PushSettings.barkServerKey)
        d.set(false, forKey: PushSettings.onWaitingKey)
        d.set(true, forKey: PushSettings.onFinishedKey)
        d.set("always", forKey: PushSettings.conditionKey)
        let settings = PushSettings.load(d)
        XCTAssertEqual(settings, PushSettings(provider: .ntfy, barkServer: "https://bark.example.com",
                                              ntfyServer: "https://ntfy.sh", onWaiting: false, onFinished: true,
                                              condition: .always))
    }

    func testUnknownProviderIsNone() {
        let d = defaults()
        d.set("pushover", forKey: PushSettings.providerKey)
        XCTAssertEqual(PushSettings.load(d).provider, .none)
    }

    func testSystemNotificationPreferencesDefaultOn() {
        let d = defaults()
        XCTAssertTrue(NotificationPreferences.allows(.needsInput, defaults: d))
        XCTAssertTrue(NotificationPreferences.allows(.finished, defaults: d))
        d.set(false, forKey: NotificationPreferences.finishedKey)
        XCTAssertFalse(NotificationPreferences.allows(.finished, defaults: d))
        XCTAssertTrue(NotificationPreferences.allows(.needsInput, defaults: d))
    }

    // MARK: 是否推送

    func testNoProviderNeverPushes() {
        let settings = PushSettings(provider: .none, condition: .always)
        XCTAssertFalse(PushPolicy.shouldPush(.needsInput, settings: settings, presence: locked))
    }

    func testEventToggles() {
        let settings = PushSettings(provider: .bark, onWaiting: true, onFinished: false, condition: .always)
        XCTAssertTrue(PushPolicy.shouldPush(.needsInput, settings: settings, presence: present))
        XCTAssertFalse(PushPolicy.shouldPush(.finished, settings: settings, presence: present))
        let both = PushSettings(provider: .bark, onWaiting: false, onFinished: true, condition: .always)
        XCTAssertFalse(PushPolicy.shouldPush(.needsInput, settings: both, presence: present))
        XCTAssertTrue(PushPolicy.shouldPush(.finished, settings: both, presence: present))
    }

    func testWhenAwayRequiresIdleOrLocked() {
        let settings = PushSettings(provider: .ntfy, condition: .whenAway)
        XCTAssertFalse(PushPolicy.shouldPush(.needsInput, settings: settings, presence: present))
        XCTAssertTrue(PushPolicy.shouldPush(.needsInput, settings: settings, presence: idle))
        XCTAssertTrue(PushPolicy.shouldPush(.needsInput, settings: settings, presence: locked))
        XCTAssertFalse(PushPolicy.isAway(PushPresence(idleSeconds: 179, screenLocked: false)))
        XCTAssertTrue(PushPolicy.isAway(PushPresence(idleSeconds: 180, screenLocked: false)))
    }

    // MARK: 限流

    func testSameKeyLimitedForTwoMinutes() {
        var limiter = PushRateLimiter()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let key = PushPolicy.dedupeKey(sessionKey: "a", kind: .needsInput)
        XCTAssertTrue(limiter.admit(key: key, now: t0))
        XCTAssertFalse(limiter.admit(key: key, now: t0.addingTimeInterval(60)))
        XCTAssertTrue(limiter.admit(key: PushPolicy.dedupeKey(sessionKey: "a", kind: .finished), now: t0.addingTimeInterval(60)))
        XCTAssertTrue(limiter.admit(key: PushPolicy.dedupeKey(sessionKey: "b", kind: .needsInput), now: t0.addingTimeInterval(61)))
        XCTAssertTrue(limiter.admit(key: key, now: t0.addingTimeInterval(120)))
    }

    func testGlobalLimitPerHour() {
        var limiter = PushRateLimiter(perKeyInterval: 120, globalLimit: 20, globalWindow: 3600)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<20 {
            XCTAssertTrue(limiter.admit(key: "s\(i)", now: t0.addingTimeInterval(Double(i))))
        }
        XCTAssertFalse(limiter.admit(key: "s20", now: t0.addingTimeInterval(30)))
        // 第一条滑出一小时窗口后又有一个名额。
        XCTAssertTrue(limiter.admit(key: "s21", now: t0.addingTimeInterval(3600)))
        XCTAssertFalse(limiter.admit(key: "s22", now: t0.addingTimeInterval(3600)))
    }

    func testRejectedPushDoesNotConsumeQuota() {
        var limiter = PushRateLimiter(perKeyInterval: 120, globalLimit: 2, globalWindow: 3600)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(limiter.admit(key: "a", now: t0))
        XCTAssertFalse(limiter.admit(key: "a", now: t0.addingTimeInterval(1)))
        XCTAssertTrue(limiter.admit(key: "b", now: t0.addingTimeInterval(2)))
    }

    // MARK: 内容

    func testMessageForWaiting() {
        let message = PushMessage.make(kind: .needsInput, project: "poems", sessionTitle: "旅行攻略",
                                       reason: "Bash(rm -rf\n  build)")
        XCTAssertEqual(message.title, "poems · 旅行攻略")
        XCTAssertEqual(message.body, "等批准：Bash(rm -rf build)")
        XCTAssertEqual(message.status, .waiting)
        XCTAssertEqual(message.project, "poems")
        XCTAssertEqual(message.session, "旅行攻略")
        XCTAssertNil(message.url)
    }

    func testMessageForFinishedAndSameProjectName() {
        let message = PushMessage.make(kind: .finished, project: "poems", sessionTitle: "poems", reason: nil)
        XCTAssertEqual(message.title, "poems")
        XCTAssertEqual(message.body, "已完成")
        XCTAssertEqual(message.status, .finished)
    }

    func testLongReasonAndTitleAreTruncated() {
        let reason = String(repeating: "a", count: 300)
        let title = String(repeating: "标", count: 100)
        let message = PushMessage.make(kind: .needsInput, project: "", sessionTitle: title, reason: reason)
        XCTAssertEqual(message.title.count, PushMessage.titleLimit + 1)
        XCTAssertTrue(message.title.hasSuffix("…"))
        XCTAssertEqual(message.body, "等批准：" + String(repeating: "a", count: 99) + "…")
    }

    func testMessageFromEventAndRow() {
        let row = SidebarRow(session: AgentSession(id: "k", kind: .claude, sessionID: "k", pid: 1, tty: nil, cwd: "/a",
                                                   name: "修复", nameIsDerived: false, host: .vscode,
                                                   status: .waiting("Bash(ls)"), statusChangedAt: Date()),
                             displayName: "修复", groupTitle: "cc-desk", subtitle: nil, sourceLabel: nil)
        let event = StatusEvent(kind: .needsInput, sessionKey: "k", title: "", body: "", reason: "Bash(ls)")
        XCTAssertEqual(PushMessage.make(event: event, row: row).title, "cc-desk · 修复")
    }

    // MARK: 请求

    private let waiting = PushMessage(title: "poems · 旅行攻略", body: "等批准：Bash(ls)", session: "旅行攻略",
                                      project: "poems", status: .waiting)

    func testBarkRequest() throws {
        let settings = PushSettings(provider: .bark, barkServer: "https://api.day.app/")
        let request = try PushRequestBuilder.request(waiting, settings: settings,
                                                     secrets: PushSecrets(barkDeviceKey: "KEY")).get()
        XCTAssertEqual(request.url.absoluteString, "https://api.day.app/push")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Content-Type"], "application/json; charset=utf-8")
        let body = try json(request)
        XCTAssertEqual(body["device_key"] as? String, "KEY")
        XCTAssertEqual(body["title"] as? String, "poems · 旅行攻略")
        XCTAssertEqual(body["body"] as? String, "等批准：Bash(ls)")
        XCTAssertEqual(body["group"] as? String, "CC Desk")
        XCTAssertEqual(body["level"] as? String, "timeSensitive")
    }

    func testBarkRequiresKeyAndValidServer() {
        let settings = PushSettings(provider: .bark)
        XCTAssertEqual(PushRequestBuilder.request(waiting, settings: settings, secrets: PushSecrets()), .failure(.missingDeviceKey))
        let bad = PushSettings(provider: .bark, barkServer: "ftp://example.com")
        XCTAssertEqual(PushRequestBuilder.request(waiting, settings: bad, secrets: PushSecrets(barkDeviceKey: "k")),
                       .failure(.invalidURL))
    }

    func testNtfyRequestWithToken() throws {
        let settings = PushSettings(provider: .ntfy, ntfyServer: "https://ntfy.example.com")
        let request = try PushRequestBuilder.request(
            waiting, settings: settings, secrets: PushSecrets(ntfyTopic: "cc-desk-xyz", ntfyToken: "tk_1")).get()
        XCTAssertEqual(request.url.absoluteString, "https://ntfy.example.com")
        XCTAssertEqual(request.headers["Authorization"], "Bearer tk_1")
        let body = try json(request)
        XCTAssertEqual(body["topic"] as? String, "cc-desk-xyz")
        XCTAssertEqual(body["title"] as? String, "poems · 旅行攻略")
        XCTAssertEqual(body["message"] as? String, "等批准：Bash(ls)")
        XCTAssertEqual(body["priority"] as? Int, 4)
    }

    func testNtfyWithoutTokenHasNoAuthorization() throws {
        let settings = PushSettings(provider: .ntfy)
        let request = try PushRequestBuilder.request(waiting, settings: settings, secrets: PushSecrets(ntfyTopic: "t")).get()
        XCTAssertNil(request.headers["Authorization"])
        XCTAssertEqual(request.url.absoluteString, "https://ntfy.sh")
        XCTAssertEqual(PushRequestBuilder.request(waiting, settings: settings, secrets: PushSecrets()), .failure(.missingTopic))
    }

    func testWebhookPayload() throws {
        let settings = PushSettings(provider: .webhook)
        let request = try PushRequestBuilder.request(
            waiting, settings: settings, secrets: PushSecrets(webhookURL: "https://hooks.example.com/x?y=1")).get()
        XCTAssertEqual(request.url.absoluteString, "https://hooks.example.com/x?y=1")
        let body = try json(request)
        XCTAssertEqual(Set(body.keys), ["title", "body", "session", "project", "status"])
        XCTAssertEqual(body["status"] as? String, "waiting")
        XCTAssertEqual(body["session"] as? String, "旅行攻略")
        XCTAssertEqual(body["project"] as? String, "poems")

        let linked = PushMessage(title: "t", body: "b", session: "s", project: "p", status: .finished, url: "https://x")
        let withURL = try json(PushRequestBuilder.request(linked, settings: settings,
                                                          secrets: PushSecrets(webhookURL: "http://localhost:8080/h")).get())
        XCTAssertEqual(withURL["url"] as? String, "https://x")
        XCTAssertEqual(withURL["status"] as? String, "finished")
    }

    func testWebhookRequiresValidURL() {
        let settings = PushSettings(provider: .webhook)
        XCTAssertEqual(PushRequestBuilder.request(waiting, settings: settings, secrets: PushSecrets()), .failure(.missingWebhookURL))
        XCTAssertEqual(PushRequestBuilder.request(waiting, settings: settings, secrets: PushSecrets(webhookURL: "not a url")),
                       .failure(.invalidURL))
    }

    func testNoneProviderIsNotConfigured() {
        XCTAssertEqual(PushRequestBuilder.request(waiting, settings: PushSettings(), secrets: PushSecrets()),
                       .failure(.notConfigured))
    }

    // MARK: 密钥

    func testSecretsLoadFromStoreAndBlankDeletes() throws {
        let store = InMemorySecretStore()
        try store.write(" KEY ", account: PushSecretKey.barkDeviceKey.rawValue)
        try store.write("topic", account: PushSecretKey.ntfyTopic.rawValue)
        XCTAssertEqual(PushSecrets.load(store), PushSecrets(barkDeviceKey: "KEY", ntfyTopic: "topic"))
        try store.write("  ", account: PushSecretKey.ntfyTopic.rawValue)
        XCTAssertNil(store.read(PushSecretKey.ntfyTopic.rawValue))
        XCTAssertEqual(PushSecrets.service, "dev.local.ccdesk.push")
    }

    // MARK: 唤醒词

    func testWakeWordValidation() {
        XCTAssertEqual(WakeWordRule.validate("  嬴政同学 "), .success("嬴政同学"))
        XCTAssertEqual(WakeWordRule.validate("小智"), .success("小智"))
        XCTAssertEqual(WakeWordRule.validate("   "), .failure(.empty))
        XCTAssertEqual(WakeWordRule.validate("嗨"), .failure(.tooShort))
        XCTAssertEqual(WakeWordRule.validate("一二三四五六七八"), .success("一二三四五六七八"))
        XCTAssertEqual(WakeWordRule.validate("一二三四五六七八九"), .failure(.tooLong))
        XCTAssertEqual(WakeWordRule.Problem.tooShort.message, "唤醒词至少 2 个字")
        XCTAssertEqual(WakeWordRule.Problem.empty.message, "唤醒词不能为空")
    }

    /// 完成 30 秒内只推一次；等批准按次（episode）去重，新的一次请求立即推送。
    func testPerKindIntervalsAndEpisodes() {
        var limiter = PushRateLimiter()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let done = PushPolicy.dedupeKey(sessionKey: "a", kind: .finished)
        XCTAssertTrue(limiter.admit(key: done, now: t0, interval: PushPolicy.interval(for: .finished)))
        XCTAssertFalse(limiter.admit(key: done, now: t0.addingTimeInterval(20), interval: PushPolicy.interval(for: .finished)))
        XCTAssertTrue(limiter.admit(key: done, now: t0.addingTimeInterval(31), interval: PushPolicy.interval(for: .finished)))
        let wait1 = PushPolicy.dedupeKey(sessionKey: "a", kind: .needsInput, episode: 1)
        let wait2 = PushPolicy.dedupeKey(sessionKey: "a", kind: .needsInput, episode: 2)
        XCTAssertTrue(limiter.admit(key: wait1, now: t0, interval: PushPolicy.interval(for: .needsInput)))
        XCTAssertFalse(limiter.admit(key: wait1, now: t0.addingTimeInterval(5), interval: PushPolicy.interval(for: .needsInput)))
        XCTAssertTrue(limiter.admit(key: wait2, now: t0.addingTimeInterval(6), interval: PushPolicy.interval(for: .needsInput)))
    }
}
