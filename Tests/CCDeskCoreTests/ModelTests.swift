import XCTest
@testable import CCDeskCore

final class ModelTests: XCTestCase {
    func testStatusRankOrdersWaitingFirst() {
        let ordered: [AgentStatus] = [.unknown, .idle, .working, .waiting(nil)].sorted { $0.rank < $1.rank }
        XCTAssertEqual(ordered, [.waiting(nil), .working, .idle, .unknown])
    }

    func testStatusLabels() {
        XCTAssertEqual(AgentStatus.waiting("x").label, "等批准")
        XCTAssertEqual(AgentStatus.working.label, "处理中")
        XCTAssertEqual(AgentStatus.idle.label, "空闲")
        XCTAssertEqual(AgentStatus.unknown.label, "未知")
    }

    func testIsActive() {
        XCTAssertTrue(AgentStatus.working.isActive)
        XCTAssertTrue(AgentStatus.waiting(nil).isActive)
        XCTAssertFalse(AgentStatus.idle.isActive)
    }

    func testEmbeddedHost() {
        let id = UUID()
        XCTAssertTrue(SessionHost.embedded(terminalID: id).isEmbedded)
        XCTAssertEqual(SessionHost.embedded(terminalID: id).terminalID, id)
        XCTAssertFalse(SessionHost.vscode.isEmbedded)
        XCTAssertNil(SessionHost.vscode.terminalID)
    }
}
