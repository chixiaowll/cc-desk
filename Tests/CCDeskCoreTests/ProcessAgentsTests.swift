import XCTest
@testable import CCDeskCore

final class ProcessAgentsTests: XCTestCase {
    func proc(_ pid: Int32, tty: String? = "ttys001", _ comm: String, _ args: String? = nil) -> ProcInfo {
        ProcInfo(pid: pid, ppid: 1, tty: tty, command: comm, args: args ?? comm)
    }

    let codexBin = "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"

    func testIdentifiesNativeCodexButNotNodeWrapper() {
        XCTAssertEqual(AgentProcessMatcher.kind(of: proc(2, codexBin)), .codex)
        XCTAssertNil(AgentProcessMatcher.kind(of: proc(1, "node", "node /opt/homebrew/bin/codex")))
        XCTAssertEqual(AgentProcessMatcher.kind(of: proc(3, codexBin, "\(codexBin) resume 01a1")), .codex)
        XCTAssertEqual(AgentProcessMatcher.kind(of: proc(4, codexBin, "\(codexBin) -m gpt-5 fix it")), .codex)
    }

    func testRejectsNonInteractiveCodex() {
        XCTAssertNil(AgentProcessMatcher.kind(of: proc(2, codexBin, "\(codexBin) exec say hi")))
        XCTAssertNil(AgentProcessMatcher.kind(of: proc(2, tty: nil, "/Users/x/.codex/packages/bin/codex",
                                                       "/Users/x/.codex/packages/bin/codex app-server --listen unix://")))
        XCTAssertNil(AgentProcessMatcher.kind(of: proc(2, "/x/codex", "/x/codex app-server daemon")))
        XCTAssertNil(AgentProcessMatcher.kind(of: proc(2, "/x/codex", "/x/codex --version")))
    }

    func testIdentifiesPi() {
        XCTAssertEqual(AgentProcessMatcher.kind(of: proc(5, "pi", "pi")), .pi)
        XCTAssertEqual(AgentProcessMatcher.kind(of: proc(6, "node", "node /opt/homebrew/bin/pi --session abc")), .pi)
        XCTAssertEqual(AgentProcessMatcher.kind(of: proc(7, "node",
            "node /opt/homebrew/lib/node_modules/@mariozechner/pi-coding-agent/dist/cli.js")), .pi)
        XCTAssertNil(AgentProcessMatcher.kind(of: proc(8, "node", "node /opt/homebrew/bin/pi -p hello")))
        XCTAssertNil(AgentProcessMatcher.kind(of: proc(9, "node", "node /usr/local/bin/pip")))
        XCTAssertNil(AgentProcessMatcher.kind(of: proc(10, tty: nil, "pi", "pi")))
    }

    func testDoesNotMatchUnrelated() {
        XCTAssertNil(AgentProcessMatcher.kind(of: proc(1, "claude")))
        XCTAssertNil(AgentProcessMatcher.kind(of: proc(1, "-zsh")))
        XCTAssertNil(AgentProcessMatcher.kind(of: proc(1, "/usr/bin/python3", "python3 codex.py")))
    }

    func testAgentProcessesSkipsNestedSameKind() {
        let table = ProcessTable(byPID: [
            10: ProcInfo(pid: 10, ppid: 1, tty: "ttys001", command: "-zsh"),
            11: ProcInfo(pid: 11, ppid: 10, tty: "ttys001", command: "node", args: "node /opt/homebrew/bin/codex"),
            12: ProcInfo(pid: 12, ppid: 11, tty: "ttys001", command: codexBin, args: codexBin),
            13: ProcInfo(pid: 13, ppid: 12, tty: "ttys001", command: "/x/codex", args: "/x/codex"),
            20: ProcInfo(pid: 20, ppid: 1, tty: "ttys002", command: "pi", args: "pi"),
        ])
        let found = AgentProcessMatcher.agentProcesses(in: table)
        XCTAssertEqual(found.map { $0.proc.pid }, [12, 20])
        XCTAssertEqual(found.map { $0.kind }, [.codex, .pi])
    }

    func testSessionHints() {
        XCTAssertEqual(AgentProcessMatcher.sessionHint(kind: .codex, argv: ["codex", "resume", "abc"]), "abc")
        XCTAssertNil(AgentProcessMatcher.sessionHint(kind: .codex, argv: ["codex", "resume", "--last"]))
        XCTAssertNil(AgentProcessMatcher.sessionHint(kind: .codex, argv: ["codex"]))
        XCTAssertEqual(AgentProcessMatcher.sessionHint(kind: .pi, argv: ["node", "pi", "--session", "01a1"]), "01a1")
    }
}

final class ProcessDetailsTests: XCTestCase {
    func testReadsOwnProcess() throws {
        let d = try XCTUnwrap(ProcessDetails.of(pid: getpid(), includeCwd: true))
        XCTAssertEqual(d.cwd.map(ProjectResolver.canonical), ProjectResolver.canonical(FileManager.default.currentDirectoryPath))
        XCTAssertLessThan(d.startedAt, Date())
        XCTAssertNil(ProcessDetails.of(pid: getpid(), includeCwd: false)?.cwd)
        XCTAssertNil(ProcessDetails.of(pid: 999_999, includeCwd: true))
    }
}
