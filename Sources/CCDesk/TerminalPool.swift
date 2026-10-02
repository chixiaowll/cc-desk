import AppKit
import SwiftTerm
import CCDeskCore

final class EmbeddedTerminal: NSObject, LocalProcessTerminalViewDelegate {
    let id: UUID
    let cwd: String
    let title: String
    let createdAt = Date()
    let view: LocalProcessTerminalView
    var onTerminated: ((UUID) -> Void)?

    init(id: UUID, cwd: String, title: String, command: String?, theme: TerminalTheme) {
        self.id = id
        self.cwd = cwd
        self.title = title
        self.view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        apply(theme)
        view.processDelegate = self
        let shell = Self.userShell()
        view.startProcess(
            executable: shell,
            args: LaunchSpec.shellArgs(command: command),
            environment: LaunchSpec.environment(base: ProcessInfo.processInfo.environment, shell: shell, terminalID: id),
            currentDirectory: cwd)
    }

    var shellPID: Int32 { view.process.shellPid }

    /// 跟随系统外观切换终端底色 / 前景色 / 光标色，并重绘已有内容。
    func apply(_ theme: TerminalTheme) {
        view.nativeBackgroundColor = theme.background
        view.nativeForegroundColor = theme.foreground
        view.caretColor = theme.cursor
        view.getTerminal().updateFullScreen()
        view.needsDisplay = true
    }

    /// 写入文本（遵循 bracketed paste 模式），submit 时稍后补回车。为语音输入等后续功能预留。
    func send(text: String, submit: Bool) {
        let bracketed = view.getTerminal().bracketedPasteMode
        view.send(txt: LaunchSpec.inputPayload(text: text, bracketed: bracketed))
        if submit {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.view.send(txt: "\r") }
        }
    }

    /// 挂断整个终端：交互式 shell 会忽略 SIGTERM，且前台作业（如 claude，独立进程组）不会收到
    /// SwiftTerm `view.terminate()` 发出的信号，导致 pty 主端关闭后子进程仍孤儿存活。
    /// 改为先向前台进程组、shell 自身进程组发送 SIGHUP，2 秒后若 shell 仍存活再升级为 SIGKILL。
    func terminate() {
        let pid = view.process.shellPid
        if pid > 0 {
            let fg = tcgetpgrp(view.process.childfd)
            if fg > 0 { kill(-fg, SIGHUP) }
            kill(pid, SIGHUP)
            kill(-pid, SIGHUP)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                    kill(-pid, SIGKILL)
                }
            }
        }
        view.terminate()
    }

    static func userShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }

    // MARK: LocalProcessTerminalViewDelegate
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onTerminated?(self.id)
        }
    }
}

/// 只在主线程使用。
final class TerminalPool {
    private(set) var terminals: [EmbeddedTerminal] = []
    /// 当前终端配色；nil 时按 App 当前外观取。
    private var theme: TerminalTheme?

    /// 外观变化时由视图层调用，更新所有终端。
    func apply(_ theme: TerminalTheme) {
        self.theme = theme
        for terminal in terminals { terminal.apply(theme) }
    }

    @discardableResult
    func create(id: UUID = UUID(), cwd: String, title: String, command: String?) -> EmbeddedTerminal {
        let theme = self.theme ?? TerminalTheme.of(NSApp.effectiveAppearance)
        let terminal = EmbeddedTerminal(id: id, cwd: cwd, title: title, command: command, theme: theme)
        terminals.append(terminal)
        return terminal
    }

    func terminal(_ id: UUID) -> EmbeddedTerminal? {
        terminals.first { $0.id == id }
    }

    func remove(_ id: UUID) {
        terminals.removeAll { $0.id == id }
    }

    func infos(processes: ProcessTable) -> [EmbeddedTerminalInfo] {
        terminals.map {
            EmbeddedTerminalInfo(id: $0.id, cwd: $0.cwd, tty: processes.tty(of: $0.shellPID),
                                 title: $0.title, createdAt: $0.createdAt)
        }
    }
}
