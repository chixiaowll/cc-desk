import AppKit
import SwiftTerm
import CCDeskCore

/// 在 SwiftTerm 收到输出后通知外部（用于节流触发屏幕检测）；⌘-点击文件路径交给 `pathClickHandler`（设计 §17）。
final class DetectingTerminalView: LocalProcessTerminalView {
    var onOutput: (() -> Void)?
    /// ⌘-点击：(终端视图, 点击行的文字, 列, 是否按着 ⇧) -> 是否已处理（识别出存在的文件）。
    /// 未处理时照常交给 SwiftTerm（URL / OSC 8 链接、选择、tmux 鼠标模式不受影响）。
    static var pathClickHandler: ((DetectingTerminalView, String, Int, Bool) -> Bool)?
    /// 按下时已处理的 ⌘-点击：吞掉对应的松开，不再交给 SwiftTerm / tmux。
    private var swallowMouseUp = false

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?()
    }

    override func mouseDown(with event: NSEvent) {
        swallowMouseUp = false
        if event.modifierFlags.contains(.command), event.clickCount == 1, handlePathClick(event) {
            swallowMouseUp = true
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if swallowMouseUp {
            swallowMouseUp = false
            return
        }
        super.mouseUp(with: event)
    }

    /// 取点击处那一行屏幕文字与列号；URL（非 file://）留给 SwiftTerm 自己的链接处理。
    private func handlePathClick(_ event: NSEvent) -> Bool {
        guard let handler = Self.pathClickHandler else { return false }
        let terminal = getTerminal()
        let cols = terminal.cols, rows = terminal.rows
        // characterIndex(for:) 按窗口坐标算出 row * cols + col（与 SwiftTerm 内部的点击定位一致）。
        let index = characterIndex(for: event.locationInWindow)
        guard cols > 0, rows > 0, index >= 0 else { return false }
        let row = min(index / cols, rows - 1)
        let col = min(index % cols, cols - 1)
        if let link = terminal.link(at: .screen(Position(col: col, row: row)), mode: .explicitAndImplicit),
           link.contains("://"), !link.hasPrefix("file://") {
            return false
        }
        guard let line = terminal.getLine(row: row) else { return false }
        // 每个单元格一个字符，列号与字符下标一一对应：宽字符后面的占位格换成不分隔路径的替身，空格子换成空格
        // （TerminalPaths.lineText）。
        let cells = (0..<line.count).map { i -> (character: Character, width: Int) in
            let cell = line[i]
            return (cell.getCharacter(), Int(cell.width))
        }
        let text = TerminalPaths.lineText(cells)
        return handler(self, text, col, event.modifierFlags.contains(.shift))
    }
}

/// 新建内嵌终端的方式。
enum TerminalLaunch {
    /// 运行命令（nil 为普通 shell）；tmux 可用时放进新的 tmux 会话，否则直连 SwiftTerm 的 PTY。
    case run(command: String?)
    /// 附着到已在运行的 tmux 会话（App 重启后恢复，不再发命令）。
    case attach(TmuxPane)
}

/// 终端里的进程挂在哪里。
enum TerminalBackend {
    /// shell / agent 直接运行在 SwiftTerm 的 PTY 上（没有 tmux 时；App 退出即结束）。
    case direct
    /// shell / agent 运行在 tmux 会话里，SwiftTerm 只运行 `tmux attach` 客户端；panePID 为窗格 shell 的 pid。
    case tmux(TmuxHost, panePID: Int32)
}

final class EmbeddedTerminal: NSObject, LocalProcessTerminalViewDelegate {
    let id: UUID
    let cwd: String
    let title: String
    let createdAt = Date()
    let view: DetectingTerminalView
    var onTerminated: ((UUID) -> Void)?
    private(set) var backend: TerminalBackend = .direct
    /// 正在由 App 关闭（不再自动重新附着）。
    var closing = false
    /// tmux 客户端退出后是否 / 何时重新附着（反复失败时停下，稳定附着一段时间后清零）。
    var reattachPolicy = TmuxReattachPolicy()
    /// tmux 服务器崩溃 / 被结束，会话里的进程都没了（终端保留会话信息，由 AppModel 转为「已结束」）。
    var onServerLost: ((UUID) -> Void)?
    /// 可能处于 tmux 复制模式（用户向上滚过）：输入前先退出复制模式，屏幕检测先确认。
    var mayBeInCopyMode = false

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

    /// 当前的明暗（换色时据此决定是否给 tmux 发主题变化报告）。
    private(set) var colorScheme: TerminalColorScheme
    /// 当前主题（换主题时同样发主题变化报告）。
    private var themeID: ThemeID

    init(id: UUID, cwd: String, title: String, launch: TerminalLaunch, host: TmuxHost?, theme: TerminalTheme, font: NSFont) {
        self.id = id
        self.cwd = cwd
        self.title = title
        self.view = DetectingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.colorScheme = theme.scheme
        self.themeID = theme.id
        super.init()
        view.onOutput = { [weak self] in self?.scheduleDetection() }
        view.font = font
        apply(theme)
        view.processDelegate = self
        let shell = Self.userShell()
        // 会话启动时的明暗写进 COLORFGBG（Claude Code 的 Auto 主题据此选浅色 / 深色，设计 §18）。
        let directEnvironment = LaunchSpec.environment(base: ProcessInfo.processInfo.environment, shell: shell,
                                                       terminalID: id, colorScheme: theme.scheme)
        switch launch {
        case .attach(let pane) where host != nil:
            if let host { backend = .tmux(host, panePID: pane.panePID) }
        case .attach:
            view.startProcess(executable: shell, args: LaunchSpec.shellArgs(command: nil),
                              environment: directEnvironment, currentDirectory: cwd)
            return
        case .run(let command):
            let terminal = view.getTerminal()
            if let host, let pane = host.createSession(terminalID: id, cwd: cwd, cols: terminal.cols, rows: terminal.rows,
                                                       shell: shell, command: command, colorScheme: theme.scheme) {
                backend = .tmux(host, panePID: pane.panePID)
            } else {
                view.startProcess(executable: shell, args: LaunchSpec.shellArgs(command: command),
                                  environment: directEnvironment, currentDirectory: cwd)
                return
            }
        }
        attachTmuxClient()
        hideScrollerIfPersistent()
    }

    /// 用来查 tty 的 pid：tmux 托管时为窗格 shell（agent 的 tty 是窗格的 tty），否则为 SwiftTerm 直接启动的 shell。
    var ttyPID: Int32 {
        if case .tmux(_, let panePID) = backend { return panePID }
        return view.process.shellPid
    }

    /// tmux 托管时滚动历史由 tmux（复制模式）负责，SwiftTerm 自带的滚动条用不上；系统设为「始终显示滚动条」时
    /// 它会显示成一条不跟随主题的系统色竖条，所以隐藏掉。直连 PTY 的终端保留（历史在 SwiftTerm 里）。
    func hideScrollerIfPersistent() {
        guard isPersistent else { return }
        for case let scroller as NSScroller in view.subviews where !scroller.isHidden {
            scroller.isHidden = true
        }
    }

    /// App 退出 / 崩溃后会话仍在运行（tmux 托管）。
    var isPersistent: Bool {
        if case .tmux = backend { return true }
        return false
    }

    /// 跟随外观切换终端底色 / 前景色 / 光标色与 ANSI 16 色，并重绘已有内容。
    /// 明暗变了且由 tmux（≥ 3.6）托管时，像真实终端一样给 tmux 发主题变化报告：tmux 重新查询底色
    /// （SwiftTerm 按新的底色回答 OSC 11），并通知订阅了 mode 2031 的窗格程序。
    func apply(_ theme: TerminalTheme) {
        hideScrollerIfPersistent()
        view.nativeBackgroundColor = theme.background
        view.nativeForegroundColor = theme.foreground
        view.caretColor = theme.cursor
        // installColors 按当前底色 / 前景色推算 256 色里的灰阶，所以放在设置底色之后。
        view.installColors(theme.palette.ansi.map(Self.terminalColor))
        view.getTerminal().updateFullScreen()
        view.needsDisplay = true
        // 明暗或主题变了都报告一次：同为浅色 / 深色时底色也可能变了，tmux 据此重新查询 OSC 10/11。
        if theme.scheme != colorScheme || theme.id != themeID {
            colorScheme = theme.scheme
            themeID = theme.id
            sendThemeReport()
        }
    }

    /// 改终端字体（会按新的格子大小重算行列，tmux 客户端随之调整窗口大小）。
    func apply(font: NSFont) {
        guard view.font != font else { return }
        view.font = font
    }

    /// 0xRRGGBB -> SwiftTerm 的 16 位颜色。
    static func terminalColor(_ hex: UInt32) -> SwiftTerm.Color {
        let c = TerminalPalette.components(hex)
        return SwiftTerm.Color(red: UInt16(c.red) * 257, green: UInt16(c.green) * 257, blue: UInt16(c.blue) * 257)
    }

    /// 写入文本（遵循 bracketed paste 模式），submit 时稍后补回车。为语音输入等后续功能预留。
    func send(text: String, submit: Bool) {
        leaveCopyModeIfNeeded()
        let bracketed = view.getTerminal().bracketedPasteMode
        view.send(txt: LaunchSpec.inputPayload(text: text, bracketed: bracketed))
        if submit {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.view.send(txt: "\r") }
        }
    }

    /// 直接发送按键字节（回车 "\r"、Esc "\u{1b}"、退格 "\u{7f}"…），不走 bracketed paste。
    func sendKeys(_ keys: String) {
        leaveCopyModeIfNeeded()
        view.send(txt: keys)
    }

    /// 应答 Claude Code / Codex 的权限对话框（对话模式、助手工具、通知按钮共用）；调用方负责先确认正在等批准。
    func respondToPermission(approve: Bool) {
        sendKeys(PermissionPrompt.keys(approve: approve))
    }

    /// 挂断整个终端：交互式 shell 会忽略 SIGTERM，且前台作业（如 claude，独立进程组）不会收到
    /// SwiftTerm `view.terminate()` 发出的信号，导致 pty 主端关闭后子进程仍孤儿存活。
    /// 改为先向前台进程组、shell 自身进程组发送 SIGHUP，2 秒后若 shell 仍存活再升级为 SIGKILL。
    func terminate() {
        closing = true
        if case .tmux(let host, let panePID) = backend {
            terminateTmuxSession(host: host, panePID: panePID)
            return
        }
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
        // 复制模式里屏幕上是历史内容，不能用来判断当前状态：先确认已回到底部。
        if mayBeInCopyMode, case .tmux(let host, _) = backend {
            let id = self.id
            lastDetectionAt = Date()
            Self.detectionQueue.async { [weak self] in
                let inMode = host.isInCopyMode(terminalID: id)
                DispatchQueue.main.async {
                    guard let self, !inMode else { return }
                    self.mayBeInCopyMode = false
                    self.scheduleDetection()
                }
            }
            return
        }
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

    /// 助手的 read_screen：底部 `lines` 行纯文本（可超过一屏，含回滚区）。在主线程调用，completion 也在主线程。
    func screenText(lines: Int, completion: @escaping (String) -> Void) {
        let local = Self.bottomText(of: view.getTerminal(), lines: lines)
        // tmux 托管时 SwiftTerm 里只有一屏（tmux 客户端用备用屏幕），更多行在后台从 tmux 的历史里取。
        guard lines > view.getTerminal().rows, case .tmux(let host, _) = backend else { return completion(local) }
        let id = self.id
        Self.tmuxQueue.async {
            let text = Self.tmuxScreenText(host: host, terminalID: id, lines: lines)
            DispatchQueue.main.async { completion(text ?? local) }
        }
    }

    /// 应用光标模式（方向键发 ESC O A 而不是 ESC [ A）。
    var applicationCursor: Bool { view.getTerminal().applicationCursor }

    /// 当前活动缓冲区底部一屏（或 `lines` 行；不受用户滚动位置影响），每行去掉行尾空白，去掉末尾空行。
    static func bottomText(of terminal: Terminal, lines count: Int? = nil) -> String {
        let rows = count ?? terminal.rows
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
            // tmux 客户端退出：先在后台确认会话 / 服务器的状态，不当场把终端当作已关闭。
            if case .tmux(let host, _) = self.backend, !self.closing {
                return self.tmuxClientExited(host: host, rawStatus: exitCode)
            }
            self.onTerminated?(self.id)
        }
    }
}

/// 只在主线程使用。
final class TerminalPool {
    private(set) var terminals: [EmbeddedTerminal] = []
    /// 当前终端配色；nil 时按 App 当前外观取。
    private var theme: TerminalTheme?

    /// 外观 / 主题变化时调用，更新所有终端；与当前主题相同时什么都不做（外观切换与视图层的
    /// onChange 可能先后各调一次，避免重复 installColors / 全屏重绘）。
    func apply(_ theme: TerminalTheme) {
        if let current = self.theme, current.id == theme.id { return }
        self.theme = theme
        for terminal in terminals { terminal.apply(theme) }
    }

    /// 终端字体设置变化时调用，所有终端立即换字体。
    func applyFont() {
        let font = TerminalFont.current()
        for terminal in terminals { terminal.apply(font: font) }
    }

    /// tmux 托管层；nil 时所有终端直连 PTY。
    var tmux: TmuxHost? {
        didSet { if tmux != nil { installEventMonitor() } }
    }
    private var eventMonitor: Any?

    /// SwiftTerm 的 keyDown / scrollWheel 不可覆盖（非 open），改用 App 内事件监视：
    /// 按键交给拥有焦点的终端（Shift+Enter、退出复制模式），滚轮记下「可能进入了复制模式」。
    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            guard let self, let window = event.window else { return event }
            switch event.type {
            case .keyDown:
                guard let view = window.firstResponder as? DetectingTerminalView,
                      let terminal = self.terminals.first(where: { $0.view === view }) else { return event }
                return terminal.handleTmuxKey(event) ? nil : event
            case .scrollWheel:
                guard let hit = window.contentView?.hitTest(event.locationInWindow),
                      let terminal = self.terminals.first(where: { hit.isDescendant(of: $0.view) }) else { return event }
                terminal.noteScroll(event)
                return event
            default:
                return event
            }
        }
    }

    @discardableResult
    func create(id: UUID = UUID(), cwd: String, title: String, launch: TerminalLaunch) -> EmbeddedTerminal {
        let theme = self.theme ?? ThemeStore.shared.terminalTheme(for: NSApp.effectiveAppearance)
        let terminal = EmbeddedTerminal(id: id, cwd: cwd, title: title, launch: launch, host: tmux, theme: theme,
                                        font: TerminalFont.current())
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
            EmbeddedTerminalInfo(id: $0.id, cwd: $0.cwd, tty: processes.tty(of: $0.ttyPID),
                                 title: $0.title, createdAt: $0.createdAt,
                                 lastSessionID: ended[$0.id]?.id, lastKind: ended[$0.id]?.kind ?? .claude,
                                 endedAt: ended[$0.id]?.at)
        }
    }

    /// tty -> 终端。
    func terminal(tty: String, processes: ProcessTable) -> EmbeddedTerminal? {
        terminals.first { processes.tty(of: $0.ttyPID) == tty }
    }
}

/// 内嵌终端里已退出的 agent 会话（可原地恢复）。
struct EndedSession {
    let id: String
    let kind: AgentKind
    let at: Date
}
