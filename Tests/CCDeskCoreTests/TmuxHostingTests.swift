import XCTest
@testable import CCDeskCore

final class TmuxHostingTests: XCTestCase {
    private let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    // MARK: 命名

    func testSessionNameRoundTrip() {
        let name = TmuxNaming.sessionName(for: id)
        XCTAssertEqual(name, "ccdesk-11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(TmuxNaming.terminalID(fromSessionName: name), id)
        XCTAssertEqual(TmuxNaming.target(for: id), "=" + name)
    }

    func testForeignSessionNamesAreRejected() {
        XCTAssertNil(TmuxNaming.terminalID(fromSessionName: "work"))
        XCTAssertNil(TmuxNaming.terminalID(fromSessionName: "ccdesk-notauuid"))
        XCTAssertNil(TmuxNaming.terminalID(fromSessionName: "x-ccdesk-" + id.uuidString))
    }

    func testSocketOverrideIsValidated() {
        XCTAssertEqual(TmuxNaming.socket(environment: [:]), "ccdesk")
        XCTAssertEqual(TmuxNaming.socket(environment: ["CCDESK_TMUX_SOCKET": "ccdesk-test"]), "ccdesk-test")
        XCTAssertEqual(TmuxNaming.socket(environment: ["CCDESK_TMUX_SOCKET": "../evil"]), "ccdesk")
        XCTAssertEqual(TmuxNaming.socket(environment: ["CCDESK_TMUX_SOCKET": ""]), "ccdesk")
    }

    // MARK: 版本

    func testVersionParsing() {
        XCTAssertEqual(TmuxVersion.parse("tmux 3.7c\n"), TmuxVersion(major: 3, minor: 7))
        XCTAssertEqual(TmuxVersion.parse("tmux 3.3"), TmuxVersion(major: 3, minor: 3))
        XCTAssertEqual(TmuxVersion.parse("tmux next-3.8"), TmuxVersion(major: 3, minor: 8))
        XCTAssertNil(TmuxVersion.parse("tmux master"))
        XCTAssertNil(TmuxVersion.parse(""))
        XCTAssertTrue(TmuxVersion(major: 3, minor: 2) < TmuxVersion.minimumSupported)
        XCTAssertFalse(TmuxVersion(major: 3, minor: 6) < TmuxVersion.minimumSupported)
        XCTAssertFalse(TmuxVersion(major: 4, minor: 0) < TmuxVersion.minimumSupported)
    }

    // MARK: 配置

    func testConfigMakesTmuxInvisible() {
        let conf = TmuxConfig.text()
        for line in [
            "set -g status off", "set -g prefix None", "set -g prefix2 None", "unbind -q -a -T prefix",
            "set -s escape-time 0", "set -g history-limit 20000", "set -g mouse on",
            "set -g set-titles on", "set -g set-titles-string '#{pane_title}'",
            "set -s extended-keys on", "set -s extended-keys-format csi-u",
            "set -g default-terminal tmux-256color", "set -s exit-empty on", "set -wg remain-on-exit off",
            "set -g destroy-unattached off", "set -wg window-size latest", "set -s set-clipboard on",
        ] {
            XCTAssertTrue(conf.contains(line + "\n"), "missing: \(line)")
        }
        // 真彩色：外层 SwiftTerm 声明 RGB；用固定下标，重复 source-file 不会越积越多。
        XCTAssertTrue(conf.contains("terminal-features[90] 'xterm*:RGB:"))
        // 不应出现任何键盘绑定（只允许鼠标 / 复制模式内的鼠标绑定）。
        for line in conf.split(separator: "\n") where line.hasPrefix("bind") {
            XCTAssertTrue(line.contains("Wheel") || line.contains("Mouse"), "unexpected binding: \(line)")
        }
    }

    // MARK: 列表解析

    func testParsePanes() {
        let output = """
        ccdesk-\(id.uuidString)\t4242\t/dev/ttys012
        work\t100\t/dev/ttys001
        broken line
        ccdesk-x\tnotapid\t/dev/ttys002

        """
        let panes = TmuxListing.parsePanes(output)
        XCTAssertEqual(panes, [
            TmuxPane(sessionName: "ccdesk-\(id.uuidString)", panePID: 4242, paneTTY: "ttys012"),
            TmuxPane(sessionName: "work", panePID: 100, paneTTY: "ttys001"),
        ])
        XCTAssertEqual(TmuxListing.panesByTerminal(panes), [id: panes[0]])
    }

    func testNoServerErrorsAreRecognized() {
        XCTAssertTrue(TmuxListing.isNoServer("no server running on /private/tmp/tmux-501/ccdesk\n"))
        XCTAssertTrue(TmuxListing.isNoServer("error connecting to /private/tmp/tmux-501/ccdesk (No such file or directory)"))
        XCTAssertFalse(TmuxListing.isNoServer("protocol version mismatch (client 8, server 7)"))
    }

    // MARK: 命令

    func testCommandArguments() {
        let cmd = TmuxCommand(socket: "ccdesk", configPath: "/h/.cc-desk/tmux.conf")
        XCTAssertEqual(cmd.base, ["-L", "ccdesk", "-f", "/h/.cc-desk/tmux.conf", "-u"])
        XCTAssertEqual(cmd.attach(terminalID: id), cmd.base + ["attach-session", "-t", "=ccdesk-\(id.uuidString)"])
        XCTAssertEqual(cmd.listPanes(), cmd.base + ["list-panes", "-a", "-F", "#{session_name}\t#{pane_pid}\t#{pane_tty}"])
        XCTAssertEqual(cmd.killSession(terminalID: id), cmd.base + ["kill-session", "-t", "=ccdesk-\(id.uuidString)"])
        XCTAssertEqual(cmd.capture(terminalID: id, lines: 200).suffix(2), ["-S", "-200"])
        let cancel = cmd.cancelCopyMode(terminalID: id)
        XCTAssertEqual(Array(cancel.suffix(5)), ["-F", "-t", "=ccdesk-\(id.uuidString):", "#{pane_in_mode}",
                                                 "send-keys -X -t '=ccdesk-\(id.uuidString):' cancel"])
        XCTAssertEqual(cmd.capture(terminalID: id, lines: 5)[cmd.base.count + 4], "=ccdesk-\(id.uuidString):")
        XCTAssertEqual(cmd.paneInMode(terminalID: id), cmd.base + ["display-message", "-p", "-t", "=ccdesk-\(id.uuidString):", "#{pane_in_mode}"])
    }

    func testNewSessionPassesEnvironmentPerSessionAndCommandVerbatim() {
        let cmd = TmuxCommand(socket: "s", configPath: "/c")
        let args = cmd.newSession(terminalID: id, cwd: "/tmp/a b", cols: 120, rows: 0,
                                  environment: ["CC_DESK_TERMINAL_ID": id.uuidString, "CC_DESK": "1"],
                                  command: ["/bin/zsh", "-l", "-i", "-c", "claude --resume 'x'\nexec \"$SHELL\" -l -i"])
        XCTAssertEqual(args, cmd.base + [
            "new-session", "-d", "-P", "-F", TmuxListing.paneFormat,
            "-s", "ccdesk-\(id.uuidString)", "-c", "/tmp/a b", "-x", "120", "-y", "2",
            "-e", "CC_DESK=1", "-e", "CC_DESK_TERMINAL_ID=\(id.uuidString)",
            "--", "/bin/zsh", "-l", "-i", "-c", "claude --resume 'x'\nexec \"$SHELL\" -l -i",
        ])
    }

    func testPaneCommandHidesTmuxFromThePane() {
        let args = TmuxCommand.paneCommand(shell: "/bin/zsh", command: "claude")
        XCTAssertEqual(args, ["/usr/bin/env", "-u", "TMUX", "-u", "TMUX_PANE", "-u", "TERM_PROGRAM_VERSION",
                              "TERM_PROGRAM=CCDesk", "COLORTERM=truecolor",
                              "/bin/zsh", "-l", "-i", "-c", "claude\nexec \"$SHELL\" -l -i"])
        XCTAssertEqual(Array(TmuxCommand.paneCommand(shell: "/bin/bash", command: nil).suffix(3)),
                       ["/bin/bash", "-l", "-i"])
    }

    func testClientEnvironmentOmitsTerminalID() {
        let env = LaunchSpec.environment(base: ["PATH": "/bin", "CLAUDECODE": "1"], shell: "/bin/zsh", terminalID: nil)
        XCTAssertFalse(env.contains { $0.hasPrefix("CC_DESK_TERMINAL_ID=") })
        XCTAssertFalse(env.contains { $0.hasPrefix("CLAUDECODE=") })
        XCTAssertTrue(env.contains("CC_DESK=1"))
    }

    // MARK: 可执行文件

    func testBinaryCandidatesOrder() {
        XCTAssertEqual(TmuxBinary.candidates(environment: [:], bundledPath: "/App/Contents/Helpers/tmux"),
                       ["/App/Contents/Helpers/tmux", "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"])
        XCTAssertEqual(TmuxBinary.candidates(environment: ["CCDESK_TMUX": "/x/tmux"], bundledPath: nil),
                       ["/x/tmux", "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"])
    }

    func testProbeParsing() {
        XCTAssertEqual(TmuxBinary.parseProbe("/opt/local/bin/tmux\n"), "/opt/local/bin/tmux")
        XCTAssertEqual(TmuxBinary.parseProbe("tmux: aliased to tmux -2\n/usr/bin/tmux"), "/usr/bin/tmux")
        XCTAssertNil(TmuxBinary.parseProbe("\n"))
    }

    // MARK: 恢复计划

    func testRestorePlanAttachesLiveSessionsAndResumesTheRest() {
        let live = UUID(), dead = UUID(), shell = UUID(), gone = UUID(), liveGone = UUID(), orphan = UUID()
        let entries = [
            WorkspaceEntry(terminalID: live, cwd: "/p", sessionID: "s1", name: "p", kind: .claude),
            WorkspaceEntry(terminalID: dead, cwd: "/p", sessionID: "s2", name: "p", kind: .codex),
            WorkspaceEntry(terminalID: shell, cwd: "/p", sessionID: nil, name: "p"),
            WorkspaceEntry(terminalID: gone, cwd: "/gone", sessionID: "s3", name: "g"),
            WorkspaceEntry(terminalID: liveGone, cwd: "/gone", sessionID: "s4", name: "g"),
        ]
        let sessions = [TmuxNaming.sessionName(for: live), TmuxNaming.sessionName(for: liveGone),
                        TmuxNaming.sessionName(for: orphan), "ccdesk-garbage", "user-made"]
        let plan = TerminalRestorePlanner.plan(entries: entries, liveSessions: sessions,
                                               directoryExists: { $0 == "/p" })
        XCTAssertEqual(plan.items.map(\.decision), [
            .attach,
            .create(command: "codex resume 's2'"),
            .create(command: nil),
            .missing,
            .attach,
        ])
        XCTAssertEqual(plan.orphanSessions, [TmuxNaming.sessionName(for: orphan), "ccdesk-garbage"])
    }

    func testRestorePlanWithoutTmuxIsTodaysBehavior() {
        // 迁移：升级前的会话没有 tmux 会话，全部按原来的方式新建并恢复。
        let a = UUID(), b = UUID()
        let entries = [
            WorkspaceEntry(terminalID: a, cwd: "/p", sessionID: "abc", name: "p"),
            WorkspaceEntry(terminalID: b, cwd: "/p", sessionID: nil, name: "p", kind: .pi),
        ]
        let plan = TerminalRestorePlanner.plan(entries: entries, liveSessions: [], directoryExists: { _ in true })
        XCTAssertEqual(plan.items.map(\.decision), [.create(command: "claude --resume 'abc'"), .create(command: "pi")])
        XCTAssertEqual(plan.orphanSessions, [])
        XCTAssertEqual(TerminalRestorePlanner.kind(for: entries[0]), .claude)
        XCTAssertEqual(TerminalRestorePlanner.kind(for: entries[1]), .pi)
    }
}
