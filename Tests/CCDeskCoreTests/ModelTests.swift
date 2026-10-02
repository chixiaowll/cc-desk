import XCTest
@testable import CCDeskCore

final class ModelTests: XCTestCase {
    func testStatusRankOrdersWaitingFirst() {
        let ordered: [AgentStatus] = [.unknown, .ended, .idle, .working, .waiting(nil)].sorted { $0.rank < $1.rank }
        XCTAssertEqual(ordered, [.waiting(nil), .working, .idle, .ended, .unknown])
    }

    func testStatusLabels() {
        XCTAssertEqual(AgentStatus.waiting("x").label, "等批准")
        XCTAssertEqual(AgentStatus.working.label, "处理中")
        XCTAssertEqual(AgentStatus.idle.label, "空闲")
        XCTAssertEqual(AgentStatus.ended.label, "已结束")
        XCTAssertEqual(AgentStatus.unknown.label, "未知")
    }

    func testIsActive() {
        XCTAssertTrue(AgentStatus.working.isActive)
        XCTAssertTrue(AgentStatus.waiting(nil).isActive)
        XCTAssertFalse(AgentStatus.idle.isActive)
        XCTAssertFalse(AgentStatus.ended.isActive)
        XCTAssertFalse(AgentStatus.unknown.isActive)
    }

    func testEmbeddedHost() {
        let id = UUID()
        XCTAssertTrue(SessionHost.embedded(terminalID: id).isEmbedded)
        XCTAssertEqual(SessionHost.embedded(terminalID: id).terminalID, id)
        XCTAssertFalse(SessionHost.vscode.isEmbedded)
        XCTAssertNil(SessionHost.vscode.terminalID)
    }

    func testAgentKindDisplayNames() {
        XCTAssertEqual(AgentKind.claude.displayName, "Claude")
        XCTAssertEqual(AgentKind.codex.displayName, "Codex")
        XCTAssertEqual(AgentKind.pi.displayName, "pi")
        XCTAssertEqual(AgentKind.other.displayName, "终端")
        XCTAssertTrue(AgentKind.claude.isAgent)
        XCTAssertFalse(AgentKind.other.isAgent)
    }

    func testHistoryItemDefaultsToClaude() {
        let item = HistoryItem(sessionID: "s", cwd: "/a", title: "t", lastPrompt: nil, modifiedAt: Date())
        XCTAssertEqual(item.kind, .claude)
    }
}
