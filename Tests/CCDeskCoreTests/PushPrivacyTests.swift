import XCTest
@testable import CCDeskCore

/// 推送：是否带原因、明文 http 发送密钥的提醒。
final class PushPrivacyTests: ZhHansTestCase {
    func testReasonCanBeLeftOut() {
        let row = SidebarRow(session: AgentSession(id: "a", kind: .claude, sessionID: "a", pid: 1, tty: nil, cwd: "/a",
                                                   name: "t", nameIsDerived: false, host: .vscode, status: .waiting("rm -rf /"),
                                                   statusChangedAt: Date()),
                             displayName: "t", groupTitle: "poems", subtitle: nil, sourceLabel: nil)
        let event = StatusEvent(kind: .needsInput, sessionKey: "a", title: "", body: "", reason: "rm -rf /")
        XCTAssertTrue(PushMessage.make(event: event, row: row).body.contains("rm -rf /"))
        XCTAssertFalse(PushMessage.make(event: event, row: row, includeReason: false).body.contains("rm -rf"))
    }

    func testIncludeReasonDefaultsOnAndLoads() {
        let defaults = UserDefaults(suiteName: "push-privacy-\(UUID().uuidString)")!
        XCTAssertTrue(PushSettings.load(defaults).includeReason)
        defaults.set(false, forKey: PushSettings.includeReasonKey)
        XCTAssertFalse(PushSettings.load(defaults).includeReason)
    }

    func testPlaintextSecretWarning() {
        let token = PushSecrets(barkDeviceKey: "k", ntfyTopic: "t", ntfyToken: "tok")
        XCTAssertTrue(PushSettings(provider: .ntfy, ntfyServer: "http://ntfy.example.com").sendsSecretInPlaintext(token))
        XCTAssertFalse(PushSettings(provider: .ntfy, ntfyServer: "https://ntfy.example.com").sendsSecretInPlaintext(token))
        XCTAssertFalse(PushSettings(provider: .ntfy, ntfyServer: "http://localhost:8080").sendsSecretInPlaintext(token))
        XCTAssertFalse(PushSettings(provider: .ntfy, ntfyServer: "http://127.0.0.1").sendsSecretInPlaintext(token))
        XCTAssertFalse(PushSettings(provider: .ntfy, ntfyServer: "http://ntfy.example.com")
            .sendsSecretInPlaintext(PushSecrets(ntfyTopic: "t")), "no token, nothing secret beyond the topic")
        XCTAssertTrue(PushSettings(provider: .bark, barkServer: "http://bark.example.com").sendsSecretInPlaintext(token))
        XCTAssertFalse(PushSettings(provider: .webhook).sendsSecretInPlaintext(token))
    }
}
