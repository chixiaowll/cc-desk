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
}
