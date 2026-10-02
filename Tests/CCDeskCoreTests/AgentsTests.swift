import XCTest
@testable import CCDeskCore

final class AgentsTests: XCTestCase {
    func testShellQuote() {
        XCTAssertEqual(ShellQuote.quote("abc"), "'abc'")
        XCTAssertEqual(ShellQuote.quote("it's"), "'it'\\''s'")
    }

    func testClaudeCommands() {
        let a = ClaudeAdapter()
        XCTAssertEqual(a.kind, .claude)
        XCTAssertEqual(a.launchCommand(), "claude")
        XCTAssertEqual(a.resumeCommand(sessionID: "69e1-a8bc"), "claude --resume '69e1-a8bc'")
    }

    func testShellArgs() {
        XCTAssertEqual(LaunchSpec.shellArgs(command: nil), ["-l", "-i"])
        XCTAssertEqual(LaunchSpec.shellArgs(command: "claude"),
                       ["-l", "-i", "-c", "claude; exec \"$SHELL\" -l -i"])
    }

    func testEnvironmentStripsClaudeVarsAndAddsOurs() {
        let id = UUID()
        let env = LaunchSpec.environment(
            base: ["PATH": "/bin", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "TERM": "dumb"],
            shell: "/bin/zsh", terminalID: id)
        XCTAssertTrue(env.contains("PATH=/bin"))
        XCTAssertTrue(env.contains("TERM=xterm-256color"))
        XCTAssertTrue(env.contains("COLORTERM=truecolor"))
        XCTAssertTrue(env.contains("SHELL=/bin/zsh"))
        XCTAssertTrue(env.contains("CC_DESK=1"))
        XCTAssertTrue(env.contains("CC_DESK_TERMINAL_ID=\(id.uuidString)"))
        XCTAssertFalse(env.contains { $0.hasPrefix("CLAUDECODE=") || $0.hasPrefix("CLAUDE_CODE_") })
        XCTAssertFalse(env.contains("TERM=dumb"))
    }

    func testBracketedPayload() {
        XCTAssertEqual(LaunchSpec.inputPayload(text: "hi", bracketed: false), "hi")
        XCTAssertEqual(LaunchSpec.inputPayload(text: "hi", bracketed: true), "\u{1b}[200~hi\u{1b}[201~")
    }
}
