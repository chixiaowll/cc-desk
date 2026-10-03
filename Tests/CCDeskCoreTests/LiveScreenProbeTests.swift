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
