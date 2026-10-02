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
        "/r/herdr": ProjectRef(root: "/r/herdr", branch: nil, cwd: "/r/herdr"),
        "/r/herdr/src": ProjectRef(root: "/r/herdr", branch: nil, cwd: "/r/herdr/src"),
        "/wt/fix": ProjectRef(root: "/r/herdr", branch: "issue/1-fix", cwd: "/wt/fix"),
        "/r/poems": ProjectRef(root: "/r/poems", branch: nil, cwd: "/r/poems"),
    ]

    func build(_ sessions: [AgentSession], titles: @escaping (AgentSession) -> TranscriptMeta? = { _ in nil }) -> [SessionGroup] {
        SidebarBuilder.build(sessions: sessions, project: { self.projects[$0] ?? ProjectRef(root: $0, branch: nil, cwd: $0) }, titles: titles)
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

    func testDisplayNameUsesTranscriptTitleWhenAvailable() {
        let g = build([
            s("a", cwd: "/r/poems", name: "poems-06", derived: true),
            s("b", cwd: "/r/poems", name: "travel-guide-pipeline", derived: false),
        ], titles: { session in
            session.id == "a" ? TranscriptMeta(customTitle: "自定义标题") : nil
        })[0]
        let names = Dictionary(uniqueKeysWithValues: g.rows.map { ($0.id, $0.displayName) })
        XCTAssertEqual(names["a"], "自定义标题")
        XCTAssertEqual(names["b"], "travel-guide-pipeline", "no meta available, falls back to non-derived name")
    }

    func testDisplayNameFallsBackToNameWhenNotDerivedAndNoMeta() {
        let g = build([
            s("a", cwd: "/r/poems", name: "travel-guide-pipeline", derived: false),
            s("b", cwd: "/r/poems", name: "poems-06", derived: true),
            s("c", cwd: "/r/poems", name: "", derived: false),
        ])[0]
        let names = Dictionary(uniqueKeysWithValues: g.rows.map { ($0.id, $0.displayName) })
        XCTAssertEqual(names["a"], "travel-guide-pipeline")
        XCTAssertEqual(names["b"], "新会话", "derived name must not be used as a fallback title")
        XCTAssertEqual(names["c"], "新会话", "empty name must not be used as a fallback title")
    }

    func testDisplayNameNeverShortensToHashPrefix() {
        let g = build([s("a", cwd: "/r/poems", name: "claude-4a", derived: true)])[0]
        XCTAssertEqual(g.rows[0].displayName, "新会话")
    }

    func testDuplicateGroupTitlesGetParentDirPrefix() {
        let projectsWithDup: [String: ProjectRef] = [
            "/work/a/widgets": ProjectRef(root: "/work/a/widgets", branch: nil, cwd: "/work/a/widgets"),
            "/work/b/widgets": ProjectRef(root: "/work/b/widgets", branch: nil, cwd: "/work/b/widgets"),
            "/work/unique": ProjectRef(root: "/work/unique", branch: nil, cwd: "/work/unique"),
        ]
        let groups = SidebarBuilder.build(
            sessions: [
                s("x", cwd: "/work/a/widgets"),
                s("y", cwd: "/work/b/widgets"),
                s("z", cwd: "/work/unique"),
            ],
            project: { projectsWithDup[$0] ?? ProjectRef(root: $0, branch: nil, cwd: $0) })
        let titles = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.title) })
        XCTAssertEqual(titles["/work/a/widgets"], "a/widgets")
        XCTAssertEqual(titles["/work/b/widgets"], "b/widgets")
        XCTAssertEqual(titles["/work/unique"], "unique")
    }

    func testHomeDirectoryRootIsTitledTilde() {
        let home = NSHomeDirectory()
        let projectsWithHome: [String: ProjectRef] = ["/x": ProjectRef(root: home, branch: nil, cwd: "/x")]
        let groups = SidebarBuilder.build(sessions: [s("a", cwd: "/x")],
                                          project: { projectsWithHome[$0] ?? ProjectRef(root: $0, branch: nil, cwd: $0) })
        XCTAssertEqual(groups.first?.title, "~")
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

    func testSubtitleUsesCanonicalPathForRelativePrefixCheck() {
        // SidebarBuilder must not touch the filesystem: it trusts ProjectRef.cwd, which
        // ProjectResolver already canonicalized (e.g. /tmp -> /private/tmp on macOS).
        let uncanonicalCwd = "/tmp/fake/inner"
        let canonicalRoot = "/private/tmp/fake"
        let canonicalCwd = "/private/tmp/fake/inner"

        let projectsCanonical: [String: ProjectRef] = [
            uncanonicalCwd: ProjectRef(root: canonicalRoot, branch: nil, cwd: canonicalCwd),
        ]
        let g = SidebarBuilder.build(sessions: [s("x", cwd: uncanonicalCwd)],
                                     project: { projectsCanonical[$0] ?? ProjectRef(root: $0, branch: nil, cwd: $0) })[0]
        XCTAssertEqual(g.rows.first?.subtitle, "inner")
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

    func testTooltipIncludesFullTitleAndWhereForEachHost() {
        let tid = UUID()
        let g = build([
            s("e", cwd: "/r/poems", name: "n", host: .embedded(terminalID: tid)),
            s("t", cwd: "/r/poems", name: "n", host: .terminalApp(tty: "ttys001")),
            s("v", cwd: "/r/poems", name: "n", host: .vscode),
            s("o", cwd: "/r/poems", name: "n", host: .other(tty: nil)),
            s("m", cwd: "/r/poems", name: "n", host: .missing(terminalID: tid)),
        ])[0]
        let tooltips = Dictionary(uniqueKeysWithValues: g.rows.map { ($0.id, $0.tooltip) })
        XCTAssertEqual(tooltips["e"], "n\n在 CC Desk 内运行")
        XCTAssertEqual(tooltips["t"], "n\n在 Terminal 中运行，点击跳转")
        XCTAssertEqual(tooltips["v"], "n\n在 VS Code 中运行，点击跳转")
        XCTAssertEqual(tooltips["o"], "n\n在外部终端中运行")
        XCTAssertEqual(tooltips["m"], "n\n目录缺失：/r/poems")
    }

    func testTooltipAppendsLastPromptWhenAvailable() {
        let g = build([s("a", cwd: "/r/poems", name: "n")], titles: { _ in
            TranscriptMeta(customTitle: "n", lastPrompt: "帮我\n写一个函数")
        })[0]
        XCTAssertEqual(g.rows[0].tooltip, "n\n在 VS Code 中运行，点击跳转\n最近：帮我 写一个函数")
    }

    func testTooltipTruncatesLastPromptTo80Characters() {
        let longPrompt = String(repeating: "字", count: 100)
        let g = build([s("a", cwd: "/r/poems", name: "n")], titles: { _ in
            TranscriptMeta(customTitle: "n", lastPrompt: longPrompt)
        })[0]
        let expected = "n\n在 VS Code 中运行，点击跳转\n最近：" + String(repeating: "字", count: 80) + "…"
        XCTAssertEqual(g.rows[0].tooltip, expected)
    }

    func testSessionGroupCounts() {
        let g = build([
            s("a", cwd: "/r/poems", status: .waiting("x")),
            s("b", cwd: "/r/poems", status: .waiting("y")),
            s("c", cwd: "/r/poems", status: .working),
            s("d", cwd: "/r/poems", status: .idle),
            s("e", cwd: "/r/poems", status: .idle),
            s("f", cwd: "/r/poems", status: .idle),
            s("g", cwd: "/r/poems", status: .unknown),
        ])[0]
        XCTAssertEqual(g.waitingCount, 2)
        XCTAssertEqual(g.workingCount, 1)
        XCTAssertEqual(g.idleCount, 3)
    }

    func testRelativeTime() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-30), now: now), "刚刚")
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-300), now: now), "5分钟")
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-7200), now: now), "2小时")
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-3 * 86400), now: now), "3天")
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-10 * 86400), now: now), "1周")
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-20 * 86400), now: now), "2周")
        XCTAssertEqual(RelativeTime.short(from: .distantPast, now: now), "")
    }

    func testStale() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertTrue(RelativeTime.isStale(now.addingTimeInterval(-90_000), now: now))
        XCTAssertFalse(RelativeTime.isStale(now.addingTimeInterval(-60), now: now))
    }
}
