import AppKit
import CCDeskCore

/// tmux 托管的内嵌终端（设计 §14）：附着 / 重新附着、关闭会话、复制模式与修饰键的处理。
extension EmbeddedTerminal {
    private static let returnKeyCodes: Set<UInt16> = [36, 76]
    /// 客户端意外退出后最多自动重新附着几次（防止反复失败时死循环）。
    private static let maxReattach = 3

    /// 在 SwiftTerm 里启动 `tmux attach` 客户端。
    func attachTmuxClient() {
        guard case .tmux(let host, _) = backend else { return }
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
    /// 这里改发 CSI u（`ESC [13;2u`）：tmux 能解析，并按窗格里程序请求的模式转发（Claude Code 请求了扩展按键，
    /// 收到的就是 Shift+Enter；普通 shell 收到的是回车）。返回 true 表示已处理。
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

    /// 关闭会话：结束 tmux 会话（tmux 向窗格进程组发 SIGHUP 并关闭 pty）；2 秒后窗格 shell 仍在则 SIGKILL。
    func terminateTmuxSession(host: TmuxHost, panePID: Int32) {
        let id = self.id
        DispatchQueue.global(qos: .userInitiated).async {
            host.killSession(terminalID: id)
            guard panePID > 0 else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if kill(panePID, 0) == 0 {
                    kill(-panePID, SIGKILL)
                    kill(panePID, SIGKILL)
                }
            }
        }
        view.terminate()
    }

    /// 助手 read_screen 要的行数超过一屏时，从 tmux 历史里取（去掉行尾空白与末尾空行，与 bottomText 一致）。
    func tmuxScreenText(lines: Int) -> String? {
        guard case .tmux(let host, _) = backend, let raw = host.capture(terminalID: id, lines: lines) else { return nil }
        var rows = raw.components(separatedBy: "\n").map { line -> String in
            var line = line
            while let c = line.last, c == " " || c == "\t" || c == "\u{00A0}" { line.removeLast() }
            return line
        }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        return rows.suffix(lines).joined(separator: "\n")
    }

    /// 客户端退出时：若不是 App 主动关闭、且会话仍在（被外部 detach 等），重新附着并返回 true。
    func reattachIfSessionAlive() -> Bool {
        guard case .tmux(let host, _) = backend, !closing, reattachCount < Self.maxReattach,
              host.hasSession(terminalID: id) else { return false }
        reattachCount += 1
        TmuxHost.log("tmux: client for \(id.uuidString) exited while the session is alive; reattaching")
        attachTmuxClient()
        return true
    }
}
