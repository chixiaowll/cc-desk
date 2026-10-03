import XCTest
@testable import CCDeskCore

/// 实测辅助：设置 CCDESK_SCREEN_DIR（含 screen.txt / title.txt）与 CCDESK_SCREEN_AGENT（codex / pi）时，
/// 用打包的规则检测该屏幕并打印结果；未设置时跳过。不对具体屏幕做断言。
final class LiveScreenProbeTests: XCTestCase {
    func testProbeScreenFromEnvironment() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["CCDESK_SCREEN_DIR"], let agent = env["CCDESK_SCREEN_AGENT"].flatMap(AgentKind.init(rawValue:)) else {
            throw XCTSkip("CCDESK_SCREEN_DIR 未设置")
        }
        let manifest = try XCTUnwrap(BundledManifests.manifest(for: agent))
        let screen = (try? String(contentsOfFile: dir + "/screen.txt", encoding: .utf8)) ?? ""
        let title = (try? String(contentsOfFile: dir + "/title.txt", encoding: .utf8)) ?? ""
        let d = ScreenDetector.detect(manifest, screen: screen, oscTitle: title)
        print("LIVE-PROBE agent=\(agent.rawValue) state=\(d.state.rawValue) rule=\(d.ruleID ?? "-") skip=\(d.skipStateUpdate)")
    }
}

/// 实测辅助：CCDESK_LIVE_INTEGRATION=install|uninstall|status 时对真实 HOME 执行 Codex / pi 集成操作；未设置时跳过。
final class LiveIntegrationTests: XCTestCase {
    func testLiveIntegrationAction() throws {
        guard let action = ProcessInfo.processInfo.environment["CCDESK_LIVE_INTEGRATION"] else {
            throw XCTSkip("CCDESK_LIVE_INTEGRATION 未设置")
        }
        let codex = CodexIntegration()
        let pi = PiIntegration()
        switch action {
        case "install":
            try codex.install()
            try pi.install()
        case "uninstall":
            try codex.uninstall()
            try pi.uninstall()
        default:
            break
        }
        print("LIVE-INTEGRATION codex=\(codex.status().label) pi=\(pi.status().label)")
    }
}
