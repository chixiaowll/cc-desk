import XCTest
@testable import CCDeskCore

final class SidebarTests: XCTestCase {
    func s(_ id: String, cwd: String, status: AgentStatus = .idle, at: TimeInterval = 0,
           name: String = "n", derived: Bool = false, host: SessionHost = .vscode) -> AgentSession {
        AgentSession(id: id, kind: .claude, sessionID: id, pid: 1, tty: nil, cwd: cwd, name: name,
                     nameIsDerived: derived, host: host, status: status,
                     statusChangedAt: Date(timeIntervalSince1970: at))
    }

    let projects: [String: ProjectRef] = [
        "/r/herdr": ProjectRef(root: "/r/herdr", branch: nil),
        "/r/herdr/src": ProjectRef(root: "/r/herdr", branch: nil),
        "/wt/fix": ProjectRef(root: "/r/herdr", branch: "issue/1-fix"),
        "/r/poems": ProjectRef(root: "/r/poems", branch: nil),
    ]

    func build(_ sessions: [AgentSession]) -> [SessionGroup] {
        SidebarBuilder.build(sessions: sessions, project: { self.projects[$0] ?? ProjectRef(root: $0, branch: nil) })
    }

    func testGroupsByProjectRootAndOrdersGroupsByTopStatus() {
        let groups = build([
            s("a", cwd: "/r/poems", status: .idle, at: 50),
            s("b", cwd: "/r/herdr", status: .working, at: 10),
            s("c", cwd: "/wt/fix", status: .idle, at: 20),
        ])
        XCTAssertEqual(groups.map(\.title), ["herdr", "poems"])
        XCTAssertEqual(groups[0].id, "/r/herdr")
        XCTAssertEqual(groups[0].rows.map(\.id), ["b", "c"])
        XCTAssertEqual(groups[0].topStatus, .working)
    }

    func testRowsSortedByStatusThenRecency() {
        let g = build([
            s("idleOld", cwd: "/r/poems", status: .idle, at: 1),
            s("idleNew", cwd: "/r/poems", status: .idle, at: 9),
            s("wait", cwd: "/r/poems", status: .waiting("x"), at: 0),
        ])[0]
        XCTAssertEqual(g.rows.map(\.id), ["wait", "idleNew", "idleOld"])
    }

    func testDisplayNameShortensDerivedNames() {
        let g = build([
            s("a", cwd: "/r/poems", name: "poems-06", derived: true),
            s("b", cwd: "/r/poems", name: "travel-guide-pipeline", derived: false),
            s("c", cwd: "/r/poems", name: "", derived: false),
        ])[0]
        let names = Dictionary(uniqueKeysWithValues: g.rows.map { ($0.id, $0.displayName) })
        XCTAssertEqual(names["a"], "#06")
        XCTAssertEqual(names["b"], "travel-guide-pipeline")
        XCTAssertEqual(names["c"], "poems")
    }

    func testSubtitleShowsWaitingReasonOrRelativePathOrBranch() {
        let g = build([
            s("w", cwd: "/r/herdr", status: .waiting("Bash(ls)"), at: 3),
            s("sub", cwd: "/r/herdr/src", at: 2),
            s("wt", cwd: "/wt/fix", at: 1),
            s("root", cwd: "/r/herdr", at: 0),
        ])[0]
        let subs = Dictionary(uniqueKeysWithValues: g.rows.map { ($0.id, $0.subtitle) })
        XCTAssertEqual(subs["w"], "Bash(ls)")
        XCTAssertEqual(subs["sub"], "src")
        XCTAssertEqual(subs["wt"], "issue/1-fix")
        XCTAssertEqual(subs["root"], .some(nil))
    }

    func testSourceLabels() {
        let tid = UUID()
        let g = build([
            s("e", cwd: "/r/poems", host: .embedded(terminalID: tid)),
            s("t", cwd: "/r/poems", host: .terminalApp(tty: "ttys001")),
            s("v", cwd: "/r/poems", host: .vscode),
            s("o", cwd: "/r/poems", host: .other(tty: nil)),
            s("m", cwd: "/r/poems", host: .missing(terminalID: tid)),
        ])[0]
        let labels = Dictionary(uniqueKeysWithValues: g.rows.map { ($0.id, $0.sourceLabel) })
        XCTAssertEqual(labels["e"], .some(nil))
        XCTAssertEqual(labels["t"], "Terminal")
        XCTAssertEqual(labels["v"], "VS Code")
        XCTAssertEqual(labels["o"], "外部")
        XCTAssertEqual(labels["m"], "目录缺失")
    }

    func testRelativeTime() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-30), now: now), "now")
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-300), now: now), "5m")
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-7200), now: now), "2h")
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-3 * 86400), now: now), "3d")
        XCTAssertEqual(RelativeTime.short(from: .distantPast, now: now), "")
    }

    func testStale() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertTrue(RelativeTime.isStale(now.addingTimeInterval(-90_000), now: now))
        XCTAssertFalse(RelativeTime.isStale(now.addingTimeInterval(-60), now: now))
    }
}
