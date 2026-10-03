import AppKit
import SwiftTerm
import CCDeskCore

/// 在 SwiftTerm 收到输出后通知外部（用于节流触发屏幕检测）。
final class DetectingTerminalView: LocalProcessTerminalView {
    var onOutput: (() -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?()
    }
}

final class EmbeddedTerminal: NSObject, LocalProcessTerminalViewDelegate {
    let id: UUID
    let cwd: String
    let title: String
    let createdAt = Date()
    let view: DetectingTerminalView
    var onTerminated: ((UUID) -> Void)?

    /// 终端里当前运行的、需要屏幕检测的 agent（Codex / pi）；由 AppModel 每次轮询后设置，nil 时不检测。
    var detectionKind: AgentKind? {
        didSet {
            guard detectionKind != oldValue else { return }
            screenStatus = nil
            scheduleDetection()
        }
    }
    /// 最近一次屏幕规则得出的状态及其开始时间（设计 §4.5）；只在主线程读写。
    private(set) var screenStatus: StatusObservation?
    /// 终端标题（OSC 0/2），供 `osc_title` 区域使用。
    private(set) var oscTitle = ""
    private var detectionScheduled = false
    private var lastDetectionAt = Date.distantPast
    /// 同一终端最多每 0.5 秒检测一次（设计 §4.2）。
    private static let detectionInterval: TimeInterval = 0.5
    private static let detectionQueue = DispatchQueue(label: "cc-desk.screen-detect", qos: .utility)

    init(id: UUID, cwd: String, title: String, command: String?, theme: TerminalTheme) {
        self.id = id
        self.cwd = cwd
        self.title = title
        self.view = DetectingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        view.onOutput = { [weak self] in self?.scheduleDetection() }
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

    /// 直接发送按键字节（回车 "\r"、Esc "\u{1b}"、退格 "\u{7f}"…），不走 bracketed paste。
    func sendKeys(_ keys: String) {
        view.send(txt: keys)
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

    // MARK: 屏幕检测

    /// 有输出时调用：合并 0.5 秒内的多次输出，到点后在主线程截取底部可见区域，在后台队列匹配规则。
    func scheduleDetection() {
        guard detectionKind != nil, !detectionScheduled else { return }
        detectionScheduled = true
        let delay = max(0, Self.detectionInterval - Date().timeIntervalSince(lastDetectionAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.runDetection() }
    }

    private func runDetection() {
        detectionScheduled = false
        guard let kind = detectionKind, let manifest = BundledManifests.manifest(for: kind) else { return }
        lastDetectionAt = Date()
        let screen = bottomScreenText()
        let title = oscTitle
        Self.detectionQueue.async { [weak self] in
            let detection = ScreenDetector.detect(manifest, screen: screen, oscTitle: title)
            DispatchQueue.main.async { self?.apply(detection, kind: kind) }
        }
    }

    private func apply(_ detection: ScreenDetection, kind: AgentKind) {
        guard detectionKind == kind, !detection.skipStateUpdate,
              let status = detection.state.agentStatus() else { return }
        if screenStatus?.status != status { screenStatus = StatusObservation(status: status, at: Date()) }
    }

    /// 必须在主线程调用（SwiftTerm 在主线程写缓冲区）。
    private func bottomScreenText() -> String {
        Self.bottomText(of: view.getTerminal())
    }

    /// 当前活动缓冲区底部一屏（不受用户滚动位置影响），每行去掉行尾空白，去掉末尾空行。
    static func bottomText(of terminal: Terminal) -> String {
        let rows = terminal.rows
        let top = terminal.buffer.totalLinesTrimmed
        guard terminal.getScrollInvariantLine(row: top) != nil else { return "" }
        // 二分找到缓冲区最后一行（SwiftTerm 未公开行数）。
        var lo = top, hi = top + (1 << 24)
        while lo < hi {
            let mid = lo + (hi - lo + 1) / 2
            if terminal.getScrollInvariantLine(row: mid) != nil { lo = mid } else { hi = mid - 1 }
        }
        let first = max(top, lo - rows + 1)
        var lines: [String] = []
        lines.reserveCapacity(rows)
        for row in first...lo {
            // translateToString(trimRight:) 只去掉空单元格；程序显式写入的空格也要去掉，规则里的 `$` / `\z` 依赖这一点。
            var line = terminal.getScrollInvariantLine(row: row)?.translateToString(trimRight: true) ?? ""
            while let c = line.last, c == " " || c == "\t" || c == "\u{00A0}" { line.removeLast() }
            lines.append(line)
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: LocalProcessTerminalViewDelegate
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        oscTitle = title
        scheduleDetection()
    }
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

    /// ended：agent 已退出的终端 -> 最近的 sessionId、agent 种类与退出时间。
    func infos(processes: ProcessTable, ended: [UUID: EndedSession] = [:]) -> [EmbeddedTerminalInfo] {
        terminals.map {
            EmbeddedTerminalInfo(id: $0.id, cwd: $0.cwd, tty: processes.tty(of: $0.shellPID),
                                 title: $0.title, createdAt: $0.createdAt,
                                 lastSessionID: ended[$0.id]?.id, lastKind: ended[$0.id]?.kind ?? .claude,
                                 endedAt: ended[$0.id]?.at)
        }
    }

    /// tty -> 终端。
    func terminal(tty: String, processes: ProcessTable) -> EmbeddedTerminal? {
        terminals.first { processes.tty(of: $0.shellPID) == tty }
    }
}

/// 内嵌终端里已退出的 agent 会话（可原地恢复）。
struct EndedSession {
    let id: String
    let kind: AgentKind
    let at: Date
}
