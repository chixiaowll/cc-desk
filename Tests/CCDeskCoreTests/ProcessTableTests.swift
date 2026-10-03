import XCTest
@testable import CCDeskCore

final class ProcessTableTests: XCTestCase {
    let sample = """
        1     0 ??       /sbin/launchd
      500     1 ??       /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
      600   500 ttys007  /usr/bin/login
      601   600 ttys007  -zsh
      700   601 ttys007  claude
      800     1 ??       /Applications/Visual Studio Code.app/Contents/MacOS/Electron
      801   800 ??       /Users/x/.vscode/extensions/claude
    garbage line
    """

    func testParsesRowsIncludingPathsWithSpaces() {
        let t = ProcessTable.parse(sample)
        XCTAssertEqual(t.byPID.count, 7)
        XCTAssertEqual(t.byPID[800]?.command, "/Applications/Visual Studio Code.app/Contents/MacOS/Electron")
        XCTAssertEqual(t.byPID[700]?.ppid, 601)
    }

    func testTTYNormalizesQuestionMarks() {
        let t = ProcessTable.parse(sample)
        XCTAssertEqual(t.tty(of: 700), "ttys007")
        XCTAssertNil(t.tty(of: 801))
        XCTAssertNil(t.tty(of: 99999))
    }

    func testAliveAndAncestors() {
        let t = ProcessTable.parse(sample)
        XCTAssertTrue(t.isAlive(700))
        XCTAssertFalse(t.isAlive(12345))
        XCTAssertEqual(t.ancestors(of: 700).map(\.pid), [601, 600, 500, 1])
    }

    func testAncestorsStopOnCycle() {
        let t = ProcessTable.parse("10 11 ?? a\n11 10 ?? b\n")
        XCTAssertEqual(t.ancestors(of: 10).map(\.pid), [11])
    }

    func testHasAncestorMatching() {
        let t = ProcessTable.parse(sample)
        XCTAssertTrue(t.hasAncestor(of: 700) { $0.command.contains("/Terminal.app/") })
        XCTAssertFalse(t.hasAncestor(of: 801) { $0.command.contains("/Terminal.app/") })
    }

    func testMergesArgsByPID() {
        let comm = """
            100     1 ttys021  node
            101   100 ttys021  /opt/homebrew/lib/node_modules/@openai/codex/vendor/bin/codex
            102     1 ??       /Applications/Visual Studio Code.app/Contents/MacOS/Electron
            103     1 ttys019  pi
        """
        let args = """
          100 node /opt/homebrew/bin/codex
          101 /opt/homebrew/lib/node_modules/@openai/codex/vendor/bin/codex resume  abc-123
          102 /Applications/Visual Studio Code.app/Contents/MacOS/Electron --type=renderer
          103 pi\u{20}
          999 ghost
        """
        let t = ProcessTable.parse(comm, args: args)
        XCTAssertEqual(t.byPID.count, 4)
        XCTAssertEqual(t.byPID[100]?.args, "node /opt/homebrew/bin/codex")
        XCTAssertEqual(t.byPID[101]?.executableName, "codex")
        XCTAssertEqual(t.byPID[101]?.argv, ["/opt/homebrew/lib/node_modules/@openai/codex/vendor/bin/codex", "resume", "abc-123"])
        XCTAssertEqual(t.byPID[102]?.command, "/Applications/Visual Studio Code.app/Contents/MacOS/Electron")
        XCTAssertEqual(t.byPID[103]?.args, "pi")
        XCTAssertNil(t.byPID[999])
    }

    func testArgsMissingWhenNotProvided() {
        let t = ProcessTable.parse(sample)
        XCTAssertNil(t.byPID[700]?.args)
        XCTAssertEqual(t.byPID[700]?.argv, [])
        XCTAssertEqual(t.byPID[500]?.executableName, "Terminal")
    }
}
