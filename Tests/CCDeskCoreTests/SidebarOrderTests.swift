import XCTest
@testable import CCDeskCore

final class SidebarOrderTests: XCTestCase {
    func row(_ id: String, sid: String?, status: AgentStatus = .idle, at: TimeInterval = 0) -> SidebarRow {
        let s = AgentSession(id: id, kind: .claude, sessionID: sid, pid: 1, tty: nil, cwd: "/r", name: id,
                             nameIsDerived: false, host: .vscode, status: status,
                             statusChangedAt: Date(timeIntervalSince1970: at))
        return SidebarBuilder.row(for: s, ref: ProjectRef(root: "/r", branch: nil, cwd: "/r"), groupTitle: "r", meta: nil)
    }

    func group(_ id: String, _ rows: [SidebarRow]) -> SessionGroup { SessionGroup(id: id, title: id, rows: rows) }

    func ids(_ groups: [SessionGroup]) -> [String] { groups.flatMap { [$0.id] + $0.rows.map(\.id) } }

    func testFirstSeenOrderSurvivesStatusChangesAndRestart() {
        var order = SidebarOrder()
        let first = order.apply([group("A", [row("a1", sid: "x"), row("a2", sid: "y")]), group("B", [row("b1", sid: "z")])])
        XCTAssertTrue(first.changed)
        XCTAssertEqual(ids(first.groups), ["A", "a1", "a2", "B", "b1"])

        // 状态变化后上游动态排序把 B / a2 排到前面：固定顺序不变，也不再记录新键。
        let again = order.apply([group("B", [row("b1", sid: "z", status: .waiting(nil))]),
                                 group("A", [row("a2", sid: "y", status: .working), row("a1", sid: "x")])])
        XCTAssertFalse(again.changed)
        XCTAssertEqual(ids(again.groups), ["A", "a1", "a2", "B", "b1"])
        XCTAssertEqual(again.groups[1].topStatus, .waiting(nil))

        // 存盘再读回（重启）后仍然一样。
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("order-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        order.save(to: url)
        var loaded = SidebarOrder.load(from: url) ?? SidebarOrder()
        XCTAssertEqual(ids(loaded.apply([group("B", [row("b1", sid: "z")]), group("A", [row("a2", sid: "y"), row("a1", sid: "x")])]).groups),
                       ["A", "a1", "a2", "B", "b1"])
    }

    func testNewItemsGoLastAndTakeOverKeepsPosition() {
        var order = SidebarOrder()
        order.apply([group("A", [row("claude-pid:1", sid: "x"), row("term:2", sid: "y")])])
        // 外部会话 x 被接管成内嵌终端 term:9：会话 id 相同，沿用原位置；新会话排在最后。
        let result = order.apply([group("A", [row("term:new", sid: "n"), row("term:2", sid: "y"), row("term:9", sid: "x")])])
        XCTAssertEqual(result.groups[0].rows.map(\.id), ["term:9", "term:2", "term:new"])
    }

    func testPruneDropsOldestAbsentEntries() {
        var order = SidebarOrder()
        for i in 0..<5 { order.rows["old\(i)"] = i }
        order.next = 5
        order.rows["live"] = 4
        order.prune(keeping: [], rowKeys: ["live"])
        XCTAssertEqual(order.rows.count, 6)  // 未超上限不清理
    }

    func testManualMovesPersistAgainstUpstreamOrder() {
        var order = SidebarOrder()
        let groups = [group("A", [row("a1", sid: "x"), row("a2", sid: "y"), row("a3", sid: "w")]),
                      group("B", [row("b1", sid: "z")]), group("C", [row("c1", sid: nil)])]
        order.apply(groups)
        order.moveGroup("C", .top, in: ["A", "B", "C"])
        order.moveGroup("A", .down, in: ["C", "A", "B"])
        order.moveRow("a3", to: 0, in: groups[0].rows)
        order.moveRow("a1", .bottom, in: [groups[0].rows[2], groups[0].rows[0], groups[0].rows[1]])
        let result = order.apply(groups.reversed())
        XCTAssertFalse(result.changed)
        XCTAssertEqual(ids(result.groups), ["C", "c1", "B", "b1", "A", "a3", "a2", "a1"])
        // 越界的移动不出错。
        order.moveGroup("C", .up, in: ["C", "B", "A"])
        XCTAssertEqual(order.apply(groups).groups.map(\.id), ["C", "B", "A"])
    }
}
