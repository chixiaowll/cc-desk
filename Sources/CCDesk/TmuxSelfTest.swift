import Foundation
import SwiftTerm
import CCDeskCore

/// `CCDesk --tmux-selftest`：不启动界面，在隔离的 tmux 服务器（socket `ccdesk-selftest-<pid>`、临时目录里的配置与
/// workspace）上验证 tmux 托管层，打印各步骤结果与耗时后退出；不碰 ~/.cc-desk 与正式的 `ccdesk` 服务器。
/// SwiftTerm 的无界面 `Terminal` 扮演 App 里的终端视图，经 pty 运行真正的 `tmux attach` 客户端。
enum TmuxSelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.dropFirst().contains("--tmux-selftest") else { return }
        exit(run() ? 0 : 1)
    }

    private static var failures = 0

    private static func check(_ ok: Bool, _ message: String) {
        print("\(ok ? "PASS" : "FAIL") \(message)")
        if !ok { failures += 1 }
    }

    private static func ms(_ since: Date) -> String { String(format: "%.1f ms", Date().timeIntervalSince(since) * 1000) }

    static func run() -> Bool {
        setvbuf(stdout, nil, _IOLBF, 0)
        TmuxHost.log = { print("  log: \($0)") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ccdesk-tmux-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = ProcessInfo.processInfo.environment
        let socket = "ccdesk-selftest-\(getpid())"
        var t0 = Date()
        guard let host = TmuxHost.resolve(environment: env, socket: socket,
                                          configPath: dir.appendingPathComponent("tmux.conf").path,
                                          bundledPath: env["CCDESK_SELFTEST_BUNDLED_TMUX"]) else {
            print("FAIL no usable tmux")
            return false
        }
        print("tmux \(host.executable) \(host.version), socket \(socket), resolve \(ms(t0))")
        defer { _ = host.run(host.command.base + ["kill-server"]) }

        // 1. 配置无错误。
        check((host.livePanes() ?? [TmuxPane(sessionName: "x", panePID: 1, paneTTY: "")]).isEmpty, "no server before start")

        // 2. 新建会话（首次会启动服务器）。
        let a = UUID()
        let script = "for i in $(seq 1 300); do echo hist-$i; done; printf '\\033]2;SELFTEST-TITLE\\007'; "
            + "printf 'WIDE:中文宽度|END\\n'; printf '\\033[38;2;255;0;128mRGB-TEXT\\033[0m\\n'; echo READY; sleep 600"
        t0 = Date()
        guard let paneA = host.createSession(terminalID: a, cwd: dir.path, cols: 100, rows: 30,
                                             shell: "/bin/zsh", command: script) else {
            print("FAIL create session")
            return false
        }
        print("create session (cold server) \(ms(t0)) pane pid \(paneA.panePID) tty \(paneA.paneTTY)")
        check(host.reloadConfigSucceeds(), "generated config sources without errors")
        let b = UUID()
        t0 = Date()
        let paneB = host.createSession(terminalID: b, cwd: dir.path, cols: 100, rows: 30, shell: "/bin/zsh", command: nil)
        print("create session (warm server) \(ms(t0))")
        check(paneB != nil, "second session")

        // 3. tty 映射：ps 里窗格 shell 的 tty == tmux 报告的窗格 tty（侧栏按它把 agent 匹配到内嵌终端）。
        usleep(300_000)
        let processes = SystemProbe.processTable()
        check(processes.tty(of: paneA.panePID) == paneA.paneTTY,
              "ProcessTable tty of pane pid = \(processes.tty(of: paneA.panePID) ?? "nil") (tmux says \(paneA.paneTTY))")
        t0 = Date()
        let listed = host.livePanes() ?? []
        print("list-panes \(ms(t0)) -> \(listed.count) pane(s)")
        check(TmuxListing.panesByTerminal(listed)[a] == paneA, "list-panes finds session a")

        // 3b. 窗格里的环境：TERM / COLORTERM / LANG 正确，看不到 TMUX，没有会话级 Claude 变量，终端 id 只属于本会话。
        let envFile = dir.appendingPathComponent("env.txt").path
        let e = UUID()
        _ = host.createSession(terminalID: e, cwd: dir.path, cols: 80, rows: 24, shell: "/bin/zsh",
                               command: "env > \(ShellQuote.quote(envFile)); sleep 60")
        var paneEnv: [String: String] = [:]
        for _ in 0..<50 where paneEnv["CC_DESK_TERMINAL_ID"] == nil {
            usleep(100_000)
            let text = (try? String(contentsOfFile: envFile, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") {
                if let eq = line.firstIndex(of: "=") { paneEnv[String(line[..<eq])] = String(line[line.index(after: eq)...]) }
            }
        }
        check(paneEnv["TERM"] == "tmux-256color", "pane TERM=\(paneEnv["TERM"] ?? "nil")")
        check(paneEnv["COLORTERM"] == "truecolor", "pane COLORTERM=\(paneEnv["COLORTERM"] ?? "nil")")
        check(paneEnv["TERM_PROGRAM"] == "CCDesk", "pane TERM_PROGRAM=\(paneEnv["TERM_PROGRAM"] ?? "nil")")
        check((paneEnv["LANG"] ?? paneEnv["LC_ALL"] ?? paneEnv["LC_CTYPE"] ?? "").uppercased().contains("UTF-8"),
              "pane locale is UTF-8 (LANG=\(paneEnv["LANG"] ?? "nil"))")
        check(paneEnv["TMUX"] == nil && paneEnv["TMUX_PANE"] == nil, "pane does not see TMUX / TMUX_PANE")
        check(paneEnv["CC_DESK_TERMINAL_ID"] == e.uuidString && paneEnv["CC_DESK"] == "1", "pane has its own CC_DESK_TERMINAL_ID")
        check(!paneEnv.keys.contains { $0 == "CLAUDECODE" || $0.hasPrefix("CLAUDE_CODE_") || $0 == "CODEX_THREAD_ID" },
              "no session-scoped Claude/Codex variables leak into the pane")
        host.killSession(terminalID: e)

        // 4. 用 SwiftTerm 附着：标题、中文宽度、真彩色。
        t0 = Date()
        let client = HeadlessClient(cols: 100, rows: 30)
        client.start(host: host, terminalID: a)
        let ready = client.wait(timeout: 5) { $0.screen.contains("READY") }
        print("attach to first frame \(ms(t0))")
        check(ready, "attached client shows pane output")
        check(client.titles.contains("SELFTEST-TITLE"), "OSC title reaches the outer terminal: \(client.titles)")
        if let (row, col) = client.find("中") {
            let first = client.terminal.getCharData(col: col, row: row)
            let next = client.terminal.getCharData(col: col + 1, row: row)
            check(first?.width == 2 && next?.width == 0, "CJK char is double width (\(String(describing: first?.width)), \(String(describing: next?.width)))")
            let text = client.line(row).replacingOccurrences(of: "\u{0}", with: "")
            check(text.contains("WIDE:中文宽度|END"), "CJK line intact: \(text)")
        } else {
            check(false, "CJK text visible")
        }
        if let (row, col) = client.find("RGB-TEXT"), let cell = client.terminal.getCharData(col: col, row: row) {
            let fg = String(describing: cell.attribute.fg)
            check(fg.contains("255") && fg.contains("128"), "true color preserved: \(fg)")
        } else {
            check(false, "RGB text visible")
        }

        // 5. 断开客户端（模拟 App 退出 / 崩溃）：会话与窗格进程仍在。
        client.stop()
        usleep(300_000)
        check(host.hasSession(terminalID: a), "session survives client exit")
        check(kill(paneA.panePID, 0) == 0, "pane shell survives client exit")

        // 6. 重新附着：不重新运行命令，内容还在。
        t0 = Date()
        let client2 = HeadlessClient(cols: 120, rows: 40)
        client2.start(host: host, terminalID: a)
        let again = client2.wait(timeout: 5) { $0.screen.contains("READY") }
        print("reattach to first frame \(ms(t0))")
        check(again, "reattached client shows the same output")
        check(host.pane(terminalID: a)?.panePID == paneA.panePID, "same pane process after reattach")

        // 7. 历史：tmux 保留了滚出屏幕的行（read_screen 取多行时用）。
        let captured = (host.capture(terminalID: a, lines: 400) ?? "").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        check(captured.contains("hist-1") && captured.contains("hist-300"), "capture-pane returns scrollback history (\(captured.count) lines)")

        // 8. 滚轮：SwiftTerm 收到 tmux 的鼠标模式请求，滚轮事件交给 tmux（进入复制模式翻历史）。
        check(client2.terminal.mouseMode != .off, "tmux enabled mouse reporting on the outer terminal (\(client2.terminal.mouseMode))")
        client2.send("\u{1b}[<64;10;10M")  // SGR 滚轮向上
        usleep(300_000)
        check(host.isInCopyMode(terminalID: a), "wheel up enters copy mode")
        t0 = Date()
        host.cancelCopyMode(terminalID: a)
        print("cancel copy mode \(ms(t0))")
        check(!host.isInCopyMode(terminalID: a), "cancel leaves copy mode")
        host.cancelCopyMode(terminalID: a)
        check(!client2.screen.contains("not in a mode"), "cancel outside copy mode is silent")
        client2.stop()

        // 9. Shift+Enter / Shift+Tab：程序请求扩展按键（如 Claude Code 的 modifyOtherKeys 2）时收到 CSI u。
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") || env["PATH"]?.contains("python") == true {
            let keysFile = dir.appendingPathComponent("keys.bin").path
            let py = "import os,sys,tty,select,time\ntty.setraw(0)\nos.write(1,b'\\x1b[>4;2mKEYS-READY\\r\\n')\n"
                + "g=b''\nt=time.time()\nwhile time.time()-t<3:\n r,_,_=select.select([0],[],[],0.1)\n if r: g+=os.read(0,64)\n"
                + "open(sys.argv[1],'wb').write(g)\ntime.sleep(30)\n"
            let pyFile = dir.appendingPathComponent("keys.py").path
            try? py.write(toFile: pyFile, atomically: true, encoding: .utf8)
            let k = UUID()
            _ = host.createSession(terminalID: k, cwd: dir.path, cols: 80, rows: 24, shell: "/bin/zsh",
                                   command: "python3 \(ShellQuote.quote(pyFile)) \(ShellQuote.quote(keysFile))")
            let kc = HeadlessClient(cols: 80, rows: 24)
            kc.start(host: host, terminalID: k)
            _ = kc.wait(timeout: 5) { $0.screen.contains("KEYS-READY") }
            kc.send("\u{1b}[13;2u")  // CC Desk 为 Shift+Enter 发出的序列
            kc.send("\u{1b}[Z")      // SwiftTerm 的 Shift+Tab
            usleep(3_500_000)
            let got = (try? Data(contentsOf: URL(fileURLWithPath: keysFile))) ?? Data()
            let text = String(decoding: got, as: UTF8.self)
            check(text.contains("\u{1b}[13;2u"), "Shift+Enter reaches the pane as CSI 13;2u")
            check(text.contains("\u{1b}[Z") || text.contains("\u{1b}[9;2u"), "Shift+Tab reaches the pane (\(got.map { String(format: "%02x", $0) }.joined()))")
            kc.stop()
            host.killSession(terminalID: k)
        } else {
            print("SKIP key passthrough (no python3)")
        }

        // 10. 启动恢复：有记录的会话附着、没有记录的残留会话被结束。
        let workspace = dir.appendingPathComponent("workspace.json")
        try? WorkspaceStore.save(WorkspaceFile(entries: [
            WorkspaceEntry(terminalID: a, cwd: dir.path, sessionID: "sid-a", name: "a", kind: .claude),
            WorkspaceEntry(terminalID: UUID(), cwd: dir.path, sessionID: "sid-dead", name: "dead", kind: .codex),
        ]), to: workspace)
        t0 = Date()
        let restore = TerminalRestore.prepare(tmux: host, workspaceURL: workspace)
        print("restore planning (list + reload + orphan kill) \(ms(t0))")
        check(restore.plan.items.map(\.decision) == [.attach, .create(command: "codex resume 'sid-dead'")],
              "restore: attach live, resume dead (\(restore.plan.items.map(\.decision)))")
        check(restore.plan.orphanSessions == [TmuxNaming.sessionName(for: b)], "restore: session b is an orphan")
        check(!host.hasSession(terminalID: b), "orphan session killed")

        // 11. 关闭会话：结束 tmux 会话及其中的进程。
        t0 = Date()
        host.killSession(terminalID: a)
        print("kill session \(ms(t0))")
        usleep(500_000)
        check(!host.hasSession(terminalID: a), "session gone after kill")
        check(kill(paneA.panePID, 0) != 0, "pane shell gone after kill")

        // 12. 轮询代价：8 个终端时，侧栏轮询只用 ps（不起 tmux 子进程）。
        let ids = (0..<8).map { _ in UUID() }
        let panes = ids.compactMap { host.createSession(terminalID: $0, cwd: dir.path, cols: 80, rows: 24, shell: "/bin/zsh", command: nil) }
        check(panes.count == 8, "8 sessions created")
        usleep(500_000)
        var total = 0.0
        for _ in 0..<5 {
            let start = Date()
            let table = SystemProbe.processTable()
            _ = panes.map { table.tty(of: $0.panePID) }
            total += Date().timeIntervalSince(start)
        }
        print(String(format: "poll tty mapping for 8 tmux terminals: %.1f ms per tick (ps only, 0 tmux spawns)", total / 5 * 1000))
        for id in ids { host.killSession(terminalID: id) }

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILURE(S)")
        return failures == 0
    }
}

private extension TmuxHost {
    func reloadConfigSucceeds() -> Bool { run(command.sourceConfig())?.ok ?? false }
}

/// 无界面的 SwiftTerm 终端 + pty 上的 `tmux attach` 客户端。
private final class HeadlessClient: TerminalDelegate, LocalProcessDelegate {
    private(set) var terminal: Terminal!
    private var process: LocalProcess!
    private let queue = DispatchQueue(label: "selftest.client")
    private let cols: Int
    private let rows: Int
    private(set) var titles: [String] = []

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows))
        process = LocalProcess(delegate: self, dispatchQueue: queue)
    }

    func start(host: TmuxHost, terminalID: UUID) {
        let env = host.clientEnvironment
        process.startProcess(executable: host.executable, args: host.command.attach(terminalID: terminalID),
                             environment: env, currentDirectory: NSTemporaryDirectory())
    }

    func stop() {
        process.terminate()
    }

    func send(_ text: String) {
        process.send(data: ArraySlice(Array(text.utf8)))
    }

    /// 在客户端队列上读终端状态。
    var screen: String {
        queue.sync { (0..<terminal.rows).map { lineUnsafe($0) }.joined(separator: "\n") }
    }

    func line(_ row: Int) -> String { queue.sync { lineUnsafe(row) } }

    private func lineUnsafe(_ row: Int) -> String {
        terminal.getLine(row: row)?.translateToString(trimRight: true) ?? ""
    }

    func find(_ text: String) -> (Int, Int)? {
        queue.sync {
            for row in 0..<terminal.rows {
                for col in 0..<terminal.cols {
                    guard let cell = terminal.getCharData(col: col, row: row) else { continue }
                    if String(cell.getCharacter()) == String(text.first ?? " ") {
                        let rest = lineUnsafe(row)
                        if rest.contains(text) { return (row, col) }
                    }
                }
            }
            return nil
        }
    }

    func wait(timeout: TimeInterval, until predicate: (HeadlessClient) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(self) { return true }
            usleep(10_000)
        }
        return false
    }

    // MARK: LocalProcessDelegate（在 queue 上）
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {}
    func dataReceived(slice: ArraySlice<UInt8>) { terminal.feed(buffer: slice) }
    func getWindowSize() -> winsize {
        winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
    }

    // MARK: TerminalDelegate
    func send(source: Terminal, data: ArraySlice<UInt8>) { process.send(data: data) }
    func setTerminalTitle(source: Terminal, title: String) { titles.append(title) }
    func showCursor(source: Terminal) {}
    func hideCursor(source: Terminal) {}
    func setTerminalIconTitle(source: Terminal, title: String) {}
    func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { nil }
    func sizeChanged(source: Terminal) {}
    func scrolled(source: Terminal, yDisp: Int) {}
    func linefeed(source: Terminal) {}
    func bufferActivated(source: Terminal) {}
    func bell(source: Terminal) {}
    func selectionChanged(source: Terminal) {}
    func isProcessTrusted(source: Terminal) -> Bool { true }
    func mouseModeChanged(source: Terminal) {}
    func hostCurrentDirectoryUpdated(source: Terminal) {}
    func hostCurrentDocumentUpdated(source: Terminal) {}
    func colorChanged(source: Terminal, idx: Int?) {}
    func setForegroundColor(source: Terminal, color: Color) {}
    func setBackgroundColor(source: Terminal, color: Color) {}
    func setCursorColor(source: Terminal, color: Color?) {}
    func getColors(source: Terminal) -> (foreground: Color, background: Color) {
        (Color(red: 0xffff, green: 0xffff, blue: 0xffff), Color(red: 0, green: 0, blue: 0))
    }
    func iTermContent(source: Terminal, content: ArraySlice<UInt8>) {}
    func clipboardCopy(source: Terminal, content: Data) {}
    func clipboardRead(source: Terminal) -> Data? { nil }
}
