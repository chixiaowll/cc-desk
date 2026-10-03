import AppKit
import CCDeskCore

/// tmux 托管的内嵌终端（设计 §4.9）：附着 / 重新附着、关闭会话、复制模式与修饰键的处理。
extension EmbeddedTerminal {
    private static let returnKeyCodes: Set<UInt16> = [36, 76]
    /// 查询会话状态 / 抓取历史等可能等上几秒的 tmux 命令放在这里，不占主线程。
    static let tmuxQueue = DispatchQueue(label: "cc-desk.tmux", qos: .userInitiated)

    /// 在 SwiftTerm 里启动 `tmux attach` 客户端。
    func attachTmuxClient() {
        guard case .tmux(let host, _) = backend else { return }
        reattachPolicy.noteAttached(at: Date())
        var isDir: ObjCBool = false
        let dir = FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) && isDir.boolValue ? cwd : NSHomeDirectory()
        view.startProcess(executable: host.executable, args: host.command.attach(terminalID: id),
                          environment: host.clientEnvironment, currentDirectory: dir)
    }

    /// 向上滚会让 tmux 进入复制模式（滚回底部时自动退出）。
    func noteScroll(_ event: NSEvent) {
        if case .tmux = backend, event.scrollingDeltaY > 0 { mayBeInCopyMode = true }
    }

    /// tmux 不会请求外层终端的 kitty 键盘协议，SwiftTerm 于是把 Shift+Enter 发成普通回车。
    /// 这里改发 CSI u（`ESC [13;2u`）：tmux 能解析，并按 `extended-keys always` 以 CSI u 转给窗格里的程序
    /// （Claude Code / pi 请求了 mode 2，Codex 不请求但能解析）。返回 true 表示已处理。
    func handleTmuxKey(_ event: NSEvent) -> Bool {
        guard case .tmux = backend else { return false }
        // ⌘ 组合键是菜单快捷键（如 ⌘C 复制），不是输入。
        if !event.modifierFlags.contains(.command) { leaveCopyModeIfNeeded() }
        guard view.getTerminal().keyboardEnhancementFlags.isEmpty,
              Self.returnKeyCodes.contains(event.keyCode) else { return false }
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        switch flags {
        case [.shift]: view.send(txt: "\u{1b}[13;2u")
        case [.control]: view.send(txt: "\u{1b}[13;5u")
        case [.shift, .control]: view.send(txt: "\u{1b}[13;6u")
        default: return false
        }
        return true
    }

    /// 输入之前退出复制模式，否则按键会被复制模式吞掉。只在用户向上滚过之后执行一次（同步，几毫秒）。
    func leaveCopyModeIfNeeded() {
        guard mayBeInCopyMode, case .tmux(let host, _) = backend else { return }
        mayBeInCopyMode = false
        host.cancelCopyMode(terminalID: id)
    }

    /// 关闭会话：先向窗格 tty 上的所有进程组（含前台作业，如 claude）发 SIGHUP，再结束 tmux 会话
    /// （tmux 关闭 pty，内核向前台进程组发 SIGHUP）；2 秒后仍存活的进程组与窗格 shell 一律 SIGKILL。
    /// 与直连 PTY 的关闭方式一致：只杀窗格 shell 的进程组时，独立进程组的前台作业会成为孤儿继续运行。
    func terminateTmuxSession(host: TmuxHost, panePID: Int32) {
        let id = self.id
        Self.tmuxQueue.async {
            let groups = panePID > 0 ? Self.processGroups(onTTYOf: panePID) : []
            for group in groups { kill(-group, SIGHUP) }
            host.killSession(terminalID: id)
            guard panePID > 0 else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                for group in groups where kill(-group, 0) == 0 { kill(-group, SIGKILL) }
                if kill(panePID, 0) == 0 {
                    kill(-panePID, SIGKILL)
                    kill(panePID, SIGKILL)
                }
            }
        }
        view.terminate()
    }

    /// 窗格 shell 所在 tty 上的所有进程组（不含 CC Desk 自己的进程组）。
    private static func processGroups(onTTYOf pid: Int32) -> [Int32] {
        guard let tty = SystemProbe.run("/bin/ps", ["-o", "tty=", "-p", String(pid)])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !tty.isEmpty, tty != "??",
              let output = SystemProbe.run("/bin/ps", ["-o", "pgid=", "-t", tty]) else { return [] }
        let own = getpgrp()
        let groups = Set(output.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) })
        return groups.filter { $0 > 1 && $0 != own }.sorted()
    }

    /// 助手 read_screen 要的行数超过一屏时，从 tmux 历史里取（去掉行尾空白与末尾空行，与 bottomText 一致）。
    /// 会起 tmux 子进程，不要在主线程调用。
    func tmuxScreenText(lines: Int) -> String? {
        guard case .tmux(let host, _) = backend else { return nil }
        return Self.tmuxScreenText(host: host, terminalID: id, lines: lines)
    }

    static func tmuxScreenText(host: TmuxHost, terminalID: UUID, lines: Int) -> String? {
        guard let raw = host.capture(terminalID: terminalID, lines: lines) else { return nil }
        var rows = raw.components(separatedBy: "\n").map { line -> String in
            var line = line
            while let c = line.last, c == " " || c == "\t" || c == "\u{00A0}" { line.removeLast() }
            return line
        }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        return rows.suffix(lines).joined(separator: "\n")
    }

    /// tmux 客户端退出（主线程）：在后台查会话状态，再按 TmuxReattachPolicy 重新附着 / 保留 / 移除 / 转为已结束。
    /// rawStatus：SwiftTerm 给的 waitpid 状态，0 = 客户端正常退出（`[exited]` / `[detached]`）。
    func tmuxClientExited(host: TmuxHost, rawStatus: Int32?) {
        let id = self.id
        let clean = (rawStatus ?? 0) == 0
        Self.tmuxQueue.async {
            let state = host.sessionState(terminalID: id)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closing else { return }
                let action = self.reattachPolicy.onClientExit(state: state, clientExitedCleanly: clean, now: Date())
                TmuxHost.log("tmux: client for \(id.uuidString) exited (status \(rawStatus.map(String.init) ?? "-"), " +
                             "session \(state)) -> \(action)")
                switch action {
                case .reattach:
                    self.attachTmuxClient()
                case .keepDetached:
                    // 会话可能还在：不移除（workspace 记录保留，下次启动时附着），只在终端里说明。
                    self.view.feed(text: "\r\n" + L("terminal.tmuxDetached") + "\r\n")
                case .remove:
                    self.onTerminated?(id)
                case .serverLost:
                    if let lost = self.onServerLost { lost(id) } else { self.onTerminated?(id) }
                }
            }
        }
    }
}
