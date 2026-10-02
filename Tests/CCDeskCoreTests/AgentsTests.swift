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
                       ["-l", "-i", "-c", "claude\nexec \"$SHELL\" -l -i"])
    }

    func testEnvironmentStripsSessionScopedVarsAndAddsOurs() {
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
        XCTAssertTrue(env.contains("TERM_PROGRAM=CCDesk"))
        XCTAssertFalse(env.contains { $0.hasPrefix("CLAUDECODE=") || $0.hasPrefix("CLAUDE_CODE_") })
        XCTAssertFalse(env.contains("TERM=dumb"))
    }

    func testEnvironmentStripsHostTerminalIdentityVars() {
        let id = UUID()
        let env = LaunchSpec.environment(
            base: [
                "PATH": "/bin",
                "CLAUDECODE": "1",
                "CLAUDE_CODE_ENTRYPOINT": "cli",
                "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/s",
                "CLAUDE_CODE_MESSAGING_TOKEN": "t",
                "CLAUDE_CODE_EXECPATH": "/x",
                "CLAUDE_CODE_SESSION_ID": "sid",
                "CLAUDE_CODE_CHILD_SESSION": "1",
                "CLAUDE_CODE_SESSION_ATTENDED": "1",
                "CLAUDE_CODE_SSE_PORT": "1234",
                "CLAUDE_PID": "1",
                "CLAUDE_EFFORT": "high",
                "TERM_PROGRAM": "iTerm.app",
                "TERM_PROGRAM_VERSION": "3.5",
                "TERM_SESSION_ID": "abc",
                "__CFBundleIdentifier": "com.googlecode.iterm2",
                "TMUX": "/tmp/tmux-0/default,1,0",
                "TMUX_PANE": "%0",
                "STY": "123.pts-0",
                "ITERM_PROFILE": "Default",
                "ITERM_SESSION_ID": "w0t0p0",
                "VSCODE_PID": "42",
                "VSCODE_GIT_ASKPASS_NODE": "/x",
            ],
            shell: "/bin/zsh", terminalID: id)
        let strippedKeys = [
            "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
            "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION",
            "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_SSE_PORT", "CLAUDE_PID", "CLAUDE_EFFORT",
            "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "__CFBundleIdentifier", "TMUX", "TMUX_PANE", "STY",
            "ITERM_PROFILE", "ITERM_SESSION_ID", "VSCODE_PID", "VSCODE_GIT_ASKPASS_NODE",
        ]
        for key in strippedKeys {
            XCTAssertFalse(env.contains { $0.hasPrefix("\(key)=") }, "\(key) should have been stripped")
        }
        // We always set our own TERM_PROGRAM afterwards.
        XCTAssertTrue(env.contains("TERM_PROGRAM=CCDesk"))
    }

    func testEnvironmentKeepsUserSettingsVars() {
        let id = UUID()
        let env = LaunchSpec.environment(
            base: ["CLAUDE_CODE_USE_BEDROCK": "1", "SOME_USER_VAR": "x"],
            shell: "/bin/zsh", terminalID: id)
        XCTAssertTrue(env.contains("CLAUDE_CODE_USE_BEDROCK=1"))
        XCTAssertTrue(env.contains("SOME_USER_VAR=x"))
    }

    func testEnvironmentSetsDefaultLocaleWhenMissing() {
        let id = UUID()
        let env = LaunchSpec.environment(
            base: ["PATH": "/bin"], shell: "/bin/zsh", terminalID: id, defaultLocale: "zh_CN.UTF-8")
        XCTAssertTrue(env.contains("LANG=zh_CN.UTF-8"))
    }

    func testEnvironmentKeepsExistingLANG() {
        let id = UUID()
        let env = LaunchSpec.environment(
            base: ["PATH": "/bin", "LANG": "ja_JP.UTF-8"], shell: "/bin/zsh", terminalID: id,
            defaultLocale: "zh_CN.UTF-8")
        XCTAssertTrue(env.contains("LANG=ja_JP.UTF-8"))
        XCTAssertFalse(env.contains("LANG=zh_CN.UTF-8"))
    }

    func testEnvironmentKeepsExistingLC_ALLAndDoesNotAddLANG() {
        let id = UUID()
        let env = LaunchSpec.environment(
            base: ["PATH": "/bin", "LC_ALL": "C"], shell: "/bin/zsh", terminalID: id,
            defaultLocale: "zh_CN.UTF-8")
        XCTAssertTrue(env.contains("LC_ALL=C"))
        XCTAssertFalse(env.contains { $0.hasPrefix("LANG=") })
    }

    func testEnvironmentKeepsExistingLC_CTYPEAndDoesNotAddLANG() {
        let id = UUID()
        let env = LaunchSpec.environment(
            base: ["PATH": "/bin", "LC_CTYPE": "C"], shell: "/bin/zsh", terminalID: id,
            defaultLocale: "zh_CN.UTF-8")
        XCTAssertTrue(env.contains("LC_CTYPE=C"))
        XCTAssertFalse(env.contains { $0.hasPrefix("LANG=") })
    }

    func testBracketedPayload() {
        XCTAssertEqual(LaunchSpec.inputPayload(text: "hi", bracketed: false), "hi")
        XCTAssertEqual(LaunchSpec.inputPayload(text: "hi", bracketed: true), "\u{1b}[200~hi\u{1b}[201~")
    }

    func testBracketedPayloadStripsEndMarkerFromText() {
        let malicious = "hi\u{1b}[201~; rm -rf /"
        let payload = LaunchSpec.inputPayload(text: malicious, bracketed: true)
        XCTAssertEqual(payload, "\u{1b}[200~hi; rm -rf /\u{1b}[201~")
        XCTAssertEqual(payload.components(separatedBy: "\u{1b}[201~").count, 2, "end marker must appear exactly once")
    }
}
