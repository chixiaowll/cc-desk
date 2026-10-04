import XCTest
@testable import CCDeskCore

/// 后端选择、密钥绑定地址、退役（设计 §22）。
final class AssistantBackendTests: XCTestCase {
    private func settings(_ preset: AssistantAPIPreset, _ url: String) -> AssistantAPISettings {
        AssistantAPISettings(preset: preset, baseURL: url, model: "m")
    }

    func testKeyIsBoundToTheEndpointOrigin() {
        // 预设地址：服务自己的账户（兼容原来按服务存的密钥）；写法上的差异不影响。
        XCTAssertEqual(settings(.deepseek, "https://api.deepseek.com/v1").keyAccount, "assistant.api.key.deepseek")
        XCTAssertEqual(settings(.deepseek, " HTTPS://API.DeepSeek.com:443/v1/ ").keyAccount, "assistant.api.key.deepseek")
        XCTAssertEqual(settings(.deepseek, "https://api.deepseek.com/beta").keyAccount, "assistant.api.key.deepseek",
                       "same host, different path: same key")
        // 服务还是 DeepSeek，地址改成了别的主机：不能用 DeepSeek 的密钥。
        let moved = settings(.deepseek, "https://evil.example.com/v1").keyAccount
        XCTAssertNotEqual(moved, "assistant.api.key.deepseek")
        XCTAssertEqual(moved, "assistant.api.key.origin.https://evil.example.com")
        // 端口、scheme 不同也算另一个地址。
        XCTAssertNotEqual(settings(.deepseek, "https://api.deepseek.com:8443/v1").keyAccount, "assistant.api.key.deepseek")
        XCTAssertNotEqual(settings(.deepseek, "http://api.deepseek.com/v1").keyAccount, "assistant.api.key.deepseek")
        // 另一个服务的预设地址也不行（OpenRouter 服务填了 DeepSeek 的地址）。
        XCTAssertNotEqual(settings(.openrouter, "https://api.deepseek.com/v1").keyAccount, "assistant.api.key.deepseek")
        XCTAssertNotEqual(settings(.openrouter, "https://api.deepseek.com/v1").keyAccount, "assistant.api.key.openrouter")
        // 自定义：永远按地址；两个自定义地址互不相通。
        let a = settings(.custom, "https://a.example.com/v1").keyAccount
        let b = settings(.custom, "https://b.example.com/v1").keyAccount
        XCTAssertNotNil(a)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(settings(.custom, "https://a.example.com/other").keyAccount, a)
        // 地址无效：没有账户（不发密钥）。
        XCTAssertNil(settings(.deepseek, "not a url").keyAccount)
        XCTAssertNil(settings(.custom, "").keyAccount)
    }

    func testOrigin() throws {
        let url = try XCTUnwrap(URL(string: "HTTP://LocalHost:11434/v1"))
        XCTAssertEqual(AssistantAPISettings.origin(url), "http://localhost:11434")
        XCTAssertEqual(AssistantAPISettings.origin(try XCTUnwrap(URL(string: "http://h:80/x"))), "http://h")
    }

    /// claude 还在解析时（nil）自动 / Claude Code 模式都待定，不能先选接口。
    func testUnknownClaudeAvailabilityIsUndecided() {
        typealias S = AssistantBackendSelector
        XCTAssertNil(S.resolve(.auto, claudeAvailable: nil, apiConfigured: true), "auto must not route to the API yet")
        XCTAssertNil(S.resolve(.auto, claudeAvailable: nil, apiConfigured: false))
        XCTAssertNil(S.resolve(.claude, claudeAvailable: nil, apiConfigured: true))
        XCTAssertEqual(S.resolve(.api, claudeAvailable: nil, apiConfigured: true), .api)
        XCTAssertEqual(S.resolve(.api, claudeAvailable: nil, apiConfigured: false), .local)
        XCTAssertEqual(S.resolve(.local, claudeAvailable: nil, apiConfigured: true), .local)
        // 解析完了就有确定的结果。
        XCTAssertEqual(S.resolve(.auto, claudeAvailable: true, apiConfigured: true), .claude)
        XCTAssertEqual(S.resolve(.auto, claudeAvailable: false, apiConfigured: true), .api)
    }

    func testSwitchingAwayFromAnIdleBackendStopsItAtOnce() {
        var sw = AssistantBackendSwitch()
        XCTAssertEqual(sw.activate(.claude, busy: { _ in false }), [])
        XCTAssertEqual(sw.activate(.api, busy: { _ in false }), [.claude])
        XCTAssertEqual(sw.active, .api)
        XCTAssertTrue(sw.retiring.isEmpty)
        // 换回同一个：不停任何东西。
        XCTAssertEqual(sw.activate(.api, busy: { _ in false }), [])
    }

    /// 正在等回复的后端不被中止：空闲后才停。设置里临时改出不完整的配置（api → local）也一样。
    func testBusyBackendIsRetiredOnlyWhenIdle() {
        var sw = AssistantBackendSwitch()
        _ = sw.activate(.api, busy: { _ in false })
        var apiBusy = true
        XCTAssertEqual(sw.activate(.local, busy: { $0 == .api && apiBusy }), [], "in-flight api turn is not aborted")
        XCTAssertEqual(sw.retiring, [.api])
        XCTAssertEqual(sw.sweep(busy: { $0 == .api && apiBusy }), [])
        apiBusy = false
        XCTAssertEqual(sw.sweep(busy: { _ in false }), [.api])
        XCTAssertTrue(sw.retiring.isEmpty)
    }

    func testReselectingARetiringBackendKeepsIt() {
        var sw = AssistantBackendSwitch()
        _ = sw.activate(.api, busy: { _ in false })
        XCTAssertEqual(sw.activate(.local, busy: { _ in true }), [])
        XCTAssertEqual(sw.activate(.api, busy: { _ in false }), [], "api selected again: not stopped")
        XCTAssertTrue(sw.retiring.isEmpty)
        // 仅本地规则没有东西要停。
        _ = sw.activate(.local, busy: { _ in false })
        XCTAssertEqual(sw.activate(.claude, busy: { _ in false }), [])
    }
}
