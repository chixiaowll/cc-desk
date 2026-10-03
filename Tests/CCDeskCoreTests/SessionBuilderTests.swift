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
        XCTAssertEqual(hosts["claude-pid:700"], .terminalApp(tty: "ttys007"))
        XCTAssertEqual(hosts["claude-pid:951"], .vscode)
        XCTAssertEqual(hosts["claude-pid:961"], .other(tty: "ttys030"))
    }

    func testExternalSessionIDsAreKeyedByPIDNotSessionID() {
        // Same sessionId resumed on two different pids/terminals must not collide.
        let out = SessionBuilder.build(
            registry: [reg(700, "shared"), reg(961, "shared")],
            processes: ps, embedded: [], missing: [])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(Set(out.map(\.id)), ["claude-pid:700", "claude-pid:961"])
        XCTAssertEqual(Set(out.map { $0.sessionID ?? "" }), ["shared"])
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

    func testDropsEntriesWhosePIDWasReusedByNonClaudeProcess() {
        let psReused = ProcessTable.parse("""
            700   601 ttys007  vim
        """)
        let out = SessionBuilder.build(registry: [reg(700, "stale")], processes: psReused, embedded: [], missing: [])
        XCTAssertTrue(out.isEmpty)
    }

    func testAcceptsVSCodeNativeBinaryNamedClaude() {
        let psVSCode = ProcessTable.parse("""
            700   601 ttys007  /some/native-binary/claude
        """)
        let out = SessionBuilder.build(registry: [reg(700, "ok")], processes: psVSCode, embedded: [], missing: [])
        XCTAssertEqual(out.count, 1)
    }

    func testMissingEntriesBecomePlaceholders() {
        let tid = UUID()
        let out = SessionBuilder.build(
            registry: [], processes: ps, embedded: [],
            missing: [WorkspaceEntry(terminalID: tid, cwd: "/gone", sessionID: "s", name: "gone")])
        XCTAssertEqual(out.map(\.id), ["missing:\(tid.uuidString)"])
        XCTAssertEqual(out[0].host, .missing(terminalID: tid))
        XCTAssertEqual(out[0].sessionID, "s")
        XCTAssertEqual(out[0].kind, .claude)
    }

    func testMissingEntryWithoutSessionIDBecomesOtherKindPlaceholder() {
        let tid = UUID()
        let out = SessionBuilder.build(
            registry: [], processes: ps, embedded: [],
            missing: [WorkspaceEntry(terminalID: tid, cwd: "/gone", sessionID: nil, name: "gone")])
        XCTAssertEqual(out.map(\.kind), [.other])
    }

    func testClassifiesVSCodeByAncestryWhenEntrypointMissing() {
        let psVSCodeNoEntrypoint = ProcessTable.parse("""
            950     1 ??       /Applications/Visual Studio Code.app/Contents/MacOS/Electron
            951   950 ttys040  /Applications/Visual Studio Code.app/Contents/Resources/app/out/vs/platform/files/node/watcher/watcherMain
            952   951 ttys040  Code Helper (Plugin)
            953   952 ttys040  claude
        """)
        let out = SessionBuilder.build(
            registry: [reg(953, "vsc", entrypoint: "cli")], processes: psVSCodeNoEntrypoint, embedded: [], missing: [])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].host, .vscode)
    }

    func testTerminalAppTakesPriorityOverVSCodeAncestryCheck() {
        // Even if a VS Code ancestor also happened to exist, Terminal.app ancestry wins when present.
        let psBothAncestors = ProcessTable.parse("""
            500     1 ??       /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
            600   500 ??       /Applications/Visual Studio Code.app/Contents/MacOS/Electron
            700   600 ttys007  claude
        """)
        let out = SessionBuilder.build(registry: [reg(700, "term")], processes: psBothAncestors, embedded: [], missing: [])
        XCTAssertEqual(out.first(where: { $0.id == "claude-pid:700" })?.host, .terminalApp(tty: "ttys007"))
    }

    func testClassifiesVSCodeByCodeHelperAncestryWithoutAppPath() {
        // Only "/Code Helper" (not a "/Visual Studio Code.app/" path) appears in the ancestry,
        // so this exercises the second half of the ancestry OR-check on its own.
        let psCodeHelperOnly = ProcessTable.parse("""
            800     1 ??       /opt/x/Code Helper (Plugin)
            801   800 ttys050  claude
        """)
        let out = SessionBuilder.build(
            registry: [reg(801, "ch", entrypoint: "cli")], processes: psCodeHelperOnly, embedded: [], missing: [])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].host, .vscode)
    }

    func testSortTieBreaksOnHigherPIDWhenStatusUpdatedAtEqual() {
        let out = SessionBuilder.build(
            registry: [reg(901, "a", status: .idle, at: 100), reg(902, "b", status: .idle, at: 100)],
            processes: ps, embedded: [], missing: [])
        // Both pids are on the same tty; the first (sorted) live entry wins the embedded/claim race,
        // but here there's no embedded terminal so both rows should appear, with the higher pid
        // ordered first by the live-sort tie-break.
        XCTAssertEqual(out.map(\.pid), [902, 901])
    }

    func testEmbeddedTerminalWithEndedClaudeBecomesEndedRow() {
        let tid = UUID()
        let ended = Date(timeIntervalSince1970: 50)
        let info = EmbeddedTerminalInfo(id: tid, cwd: "/p/x", tty: "ttys099", title: "x",
                                        createdAt: Date(timeIntervalSince1970: 5),
                                        lastSessionID: "gone", endedAt: ended)
        let out = SessionBuilder.build(registry: [], processes: ps, embedded: [info], missing: [])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].id, "term:\(tid.uuidString)")
        XCTAssertEqual(out[0].kind, .claude)
        XCTAssertEqual(out[0].sessionID, "gone")
        XCTAssertEqual(out[0].status, .ended)
        XCTAssertEqual(out[0].name, "x")
        XCTAssertNil(out[0].pid)
        XCTAssertEqual(out[0].host, .embedded(terminalID: tid))
        XCTAssertEqual(out[0].statusChangedAt, ended)
    }

    func testEndedRowFallsBackToCreatedAtWhenEndTimeUnknown() {
        let info = EmbeddedTerminalInfo(id: UUID(), cwd: "/p/x", tty: nil, title: "x",
                                        createdAt: Date(timeIntervalSince1970: 5), lastSessionID: "gone")
        let out = SessionBuilder.build(registry: [], processes: ps, embedded: [info], missing: [])
        XCTAssertEqual(out.first?.status, .ended)
        XCTAssertEqual(out.first?.statusChangedAt, Date(timeIntervalSince1970: 5))
    }

    func testLiveClaudeWinsOverEndedSessionInSameTerminal() {
        let tid = UUID()
        let info = EmbeddedTerminalInfo(id: tid, cwd: "/p/e", tty: "ttys020", title: "e",
                                        createdAt: Date(timeIntervalSince1970: 1),
                                        lastSessionID: "old", endedAt: Date(timeIntervalSince1970: 2))
        let out = SessionBuilder.build(registry: [reg(902, "new", status: .working, at: 200)],
                                       processes: ps, embedded: [info], missing: [])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].sessionID, "new")
        XCTAssertEqual(out[0].status, .working)
    }

    // MARK: Codex / pi

    func agent(_ pid: Int32, _ kind: AgentKind, tty: String?, sid: String? = "s", status: AgentStatus = .idle) -> AgentProcessInfo {
        AgentProcessInfo(pid: pid, kind: kind, tty: tty, cwd: "/p/\(kind.rawValue)", sessionID: sid,
                         status: status, statusChangedAt: Date(timeIntervalSince1970: 300))
    }

    func testCodexAndPiExternalSessionsUseKindPrefixedIDs() {
        let out = SessionBuilder.build(registry: [], processes: ps, embedded: [], missing: [],
                                       agents: [agent(700, .codex, tty: "ttys007", status: .working),
                                                agent(961, .pi, tty: "ttys030", sid: nil)])
        let byID = Dictionary(uniqueKeysWithValues: out.map { ($0.id, $0) })
        XCTAssertEqual(byID["codex-pid:700"]?.host, .terminalApp(tty: "ttys007"))
        XCTAssertEqual(byID["codex-pid:700"]?.kind, .codex)
        XCTAssertEqual(byID["codex-pid:700"]?.status, .working)
        XCTAssertEqual(byID["codex-pid:700"]?.cwd, "/p/codex")
        XCTAssertEqual(byID["pi-pid:961"]?.host, .other(tty: "ttys030"))
        XCTAssertNil(byID["pi-pid:961"]?.sessionID)
        XCTAssertEqual(byID["pi-pid:961"]?.statusChangedAt, Date(timeIntervalSince1970: 300))
    }

    func testEmbeddedCodexClaimsTerminalByTTY() {
        let tid = UUID()
        let info = EmbeddedTerminalInfo(id: tid, cwd: "/p/e", tty: "ttys020", title: "e", createdAt: Date(timeIntervalSince1970: 1))
        let out = SessionBuilder.build(registry: [], processes: ps, embedded: [info], missing: [],
                                       agents: [agent(901, .codex, tty: "ttys020", status: .waiting("Bash"))])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].id, "term:\(tid.uuidString)")
        XCTAssertEqual(out[0].kind, .codex)
        XCTAssertEqual(out[0].status, .waiting("Bash"))
        XCTAssertEqual(out[0].host, .embedded(terminalID: tid))
    }

    func testEndedRowKeepsAgentKind() {
        let info = EmbeddedTerminalInfo(id: UUID(), cwd: "/p/x", tty: nil, title: "x",
                                        createdAt: Date(timeIntervalSince1970: 5), lastSessionID: "pi-sid", lastKind: .pi)
        let out = SessionBuilder.build(registry: [], processes: ps, embedded: [info], missing: [])
        XCTAssertEqual(out.first?.kind, .pi)
        XCTAssertEqual(out.first?.status, .ended)
    }

    func testMissingEntryUsesStoredKind() {
        let tid = UUID()
        let out = SessionBuilder.build(registry: [], processes: ps, embedded: [], missing: [
            WorkspaceEntry(terminalID: tid, cwd: "/gone", sessionID: "c1", name: "n", kind: .codex),
            WorkspaceEntry(terminalID: UUID(), cwd: "/gone", sessionID: "c2", name: "n", kind: nil),
            WorkspaceEntry(terminalID: UUID(), cwd: "/gone", sessionID: nil, name: "n", kind: .codex),
        ])
        XCTAssertEqual(out.map(\.kind), [.codex, .claude, .other])
    }
}
