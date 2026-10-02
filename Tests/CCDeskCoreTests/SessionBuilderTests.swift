import XCTest
@testable import CCDeskCore

final class SessionBuilderTests: XCTestCase {
    let ps = ProcessTable.parse("""
        500     1 ??       /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
        601   500 ttys007  -zsh
        700   601 ttys007  claude
        900     1 ttys020  /bin/zsh
        901   900 ttys020  claude
        902   900 ttys020  claude
        950     1 ??       /Applications/Visual Studio Code.app/Contents/MacOS/Electron
        951   950 ??       claude
        960     1 ttys030  /Applications/iTerm.app/Contents/MacOS/iTerm2
        961   960 ttys030  claude
    """)

    func reg(_ pid: Int32, _ sid: String, status: AgentStatus = .idle, at: TimeInterval = 100,
             entrypoint: String = "cli", name: String = "n") -> RegistryEntry {
        RegistryEntry(pid: pid, sessionID: sid, cwd: "/p/\(sid)", name: name, nameIsDerived: false,
                      status: status, statusUpdatedAt: Date(timeIntervalSince1970: at), entrypoint: entrypoint)
    }

    func testDropsDeadProcesses() {
        let out = SessionBuilder.build(registry: [reg(4242, "dead")], processes: ps, embedded: [], missing: [])
        XCTAssertTrue(out.isEmpty)
    }

    func testClassifiesExternalHosts() {
        let out = SessionBuilder.build(
            registry: [reg(700, "term"), reg(951, "code", entrypoint: "claude-vscode"), reg(961, "iterm")],
            processes: ps, embedded: [], missing: [])
        let hosts = Dictionary(uniqueKeysWithValues: out.map { ($0.id, $0.host) })
        XCTAssertEqual(hosts["claude:term"], .terminalApp(tty: "ttys007"))
        XCTAssertEqual(hosts["claude:code"], .vscode)
        XCTAssertEqual(hosts["claude:iterm"], .other(tty: "ttys030"))
    }

    func testEmbeddedTerminalMatchedByTTYUsesNewestEntry() {
        let tid = UUID()
        let info = EmbeddedTerminalInfo(id: tid, cwd: "/p/e", tty: "ttys020", title: "e",
                                        createdAt: Date(timeIntervalSince1970: 1))
        let out = SessionBuilder.build(
            registry: [reg(901, "old", status: .idle, at: 100), reg(902, "new", status: .working, at: 200)],
            processes: ps, embedded: [info], missing: [])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].id, "term:\(tid.uuidString)")
        XCTAssertEqual(out[0].sessionID, "new")
        XCTAssertEqual(out[0].status, .working)
        XCTAssertEqual(out[0].host, .embedded(terminalID: tid))
        XCTAssertEqual(out[0].kind, .claude)
    }

    func testEmbeddedTerminalWithoutClaudeIsShellRow() {
        let tid = UUID()
        let info = EmbeddedTerminalInfo(id: tid, cwd: "/p/x", tty: "ttys099", title: "x",
                                        createdAt: Date(timeIntervalSince1970: 5))
        let out = SessionBuilder.build(registry: [], processes: ps, embedded: [info], missing: [])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].kind, .other)
        XCTAssertEqual(out[0].status, .unknown)
        XCTAssertEqual(out[0].name, "x")
        XCTAssertEqual(out[0].cwd, "/p/x")
    }

    func testMissingEntriesBecomePlaceholders() {
        let tid = UUID()
        let out = SessionBuilder.build(
            registry: [], processes: ps, embedded: [],
            missing: [WorkspaceEntry(terminalID: tid, cwd: "/gone", sessionID: "s", name: "gone")])
        XCTAssertEqual(out.map(\.id), ["missing:\(tid.uuidString)"])
        XCTAssertEqual(out[0].host, .missing(terminalID: tid))
        XCTAssertEqual(out[0].sessionID, "s")
    }
}
