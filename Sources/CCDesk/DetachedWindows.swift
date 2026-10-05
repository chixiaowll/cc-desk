import AppKit
import SwiftUI
import CCDeskCore

/// 分离到独立窗口的终端（设计 §20.3）。每个终端一个 AppKit `NSWindow`，内容是 SwiftUI（标题条 + 终端）。
/// 终端视图归谁托管只看一处：在 `windows` 里的由独立窗口托管，其余由主窗口的窗格容器托管——
/// 两边都只认这一份记录，所以同一个视图不会被两个容器来回抢。只在主线程使用。
final class DetachedWindows: NSObject {
    weak var model: AppModel?
    private var windows: [UUID: DetachedWindow] = [:]
    /// 启动时恢复、但还没打开的独立窗口（登录启动时等用户打开主窗口再一起显示）。
    private(set) var pending: [DetachedWindowEntry] = []
    /// App 正在退出：窗口关闭时不再放回主窗口（保留下次恢复用的记录）。
    var isTerminating = false
    private var keyObserver: NSObjectProtocol?

    override init() {
        super.init()
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            self?.windowBecameKey(window)
        }
    }

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }

    func contains(_ tid: UUID) -> Bool { windows[tid] != nil }

    /// 已打开或等待打开的独立窗口里的终端（不放进主窗口的布局）。
    func owns(_ tid: UUID) -> Bool { windows[tid] != nil || pending.contains { $0.terminalID == tid } }

    var isEmpty: Bool { windows.isEmpty }

    /// 保存用：打开的窗口（当前位置）+ 还没打开的记录。
    var entries: [DetachedWindowEntry] {
        windows.map { DetachedWindowEntry(terminalID: $0.key, frame: $0.value.window.frame) }
            .sorted { $0.terminalID.uuidString < $1.terminalID.uuidString } + pending
    }

    func setPending(_ entries: [DetachedWindowEntry]) {
        pending = entries
    }

    /// 打开等待中的独立窗口（不抢焦点）。
    func openPending() {
        let entries = pending
        pending = []
        for entry in entries { open(entry.terminalID, frame: entry.frame, activate: false) }
    }

    /// 为终端打开独立窗口；已打开时拿到最前。
    func open(_ tid: UUID, frame: CGRect? = nil, activate: Bool = true) {
        guard let model else { return }
        if windows[tid] != nil { return bringToFront(tid) }
        pending.removeAll { $0.terminalID == tid }
        let detached = DetachedWindow(terminalID: tid, model: model, frame: Self.placement(frame, index: windows.count))
        detached.onClose = { [weak self] id in self?.windowClosed(id) }
        detached.onFrameChange = { [weak model] in model?.saveWorkspace() }
        windows[tid] = detached
        model.objectWillChange.send()
        // 登记完成后才搭建内容，保证第一次排版就能托管终端视图。
        detached.installContent(model: model)
        if activate {
            detached.window.makeKeyAndOrderFront(nil)
        } else {
            detached.window.orderFront(nil)
        }
    }

    func bringToFront(_ tid: UUID) {
        guard let window = windows[tid]?.window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
    }

    /// 关闭窗口；reattach = false 时不放回主窗口（会话已结束，或调用方自己安排位置）。
    func close(_ tid: UUID, reattach: Bool) {
        guard let detached = windows[tid] else { return }
        if !reattach {
            windows[tid] = nil
            model?.objectWillChange.send()
        }
        detached.window.close()
    }

    func windowFor(_ tid: UUID) -> NSWindow? { windows[tid]?.window }

    private func windowClosed(_ tid: UUID) {
        // 已被 close(reattach: false) 移除的：只做清理。
        guard windows.removeValue(forKey: tid) != nil else { return }
        model?.objectWillChange.send()
        guard !isTerminating else { return }
        model?.detachedWindowClosed(tid)
    }

    /// 主窗口成为 key 时，选中回到主窗口的焦点窗格；独立窗口成为 key 时选中它的终端
    /// （语音输入、对话模式、助手的默认目标都跟着选中走）。
    private func windowBecameKey(_ window: NSWindow) {
        guard let model else { return }
        if let tid = windows.first(where: { $0.value.window === window })?.key {
            model.selectDetached(tid)
        } else if CCDeskApp.isMainWindow(window), let selected = model.selectedTerminalID, windows[selected] != nil {
            model.selectFocusedPane()
        }
    }

    /// 拖出窗格分离时新窗口的位置：标题栏中部偏左落在松手处，大小与窗格相近（限制在合理范围内），
    /// 并整个放进松手处所在屏幕的可见区域。
    static func tearOffFrame(at point: CGPoint, paneSize: CGSize) -> CGRect {
        let width = min(max(paneSize.width, 480), 1400)
        let height = min(max(paneSize.height + 36, 320), 1000)
        var frame = CGRect(x: point.x - min(160, width / 2), y: point.y + 14 - height, width: width, height: height)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        return frame
    }

    /// 新窗口的位置：保存的位置仍在某个屏幕上就用它；否则在主窗口旁边错开摆放，没有主窗口时居中。
    private static func placement(_ saved: CGRect?, index: Int) -> CGRect {
        if let saved, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) { return saved }
        let size = CGSize(width: 820, height: 560)
        let offset = CGFloat(index + 1) * 32
        if let main = NSApp.windows.first(where: CCDeskApp.isMainWindow), main.isVisible {
            return CGRect(x: main.frame.minX + offset + 40, y: main.frame.maxY - size.height - offset - 40,
                          width: size.width, height: size.height)
        }
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGRect(x: screen.midX - size.width / 2 + offset, y: screen.midY - size.height / 2 - offset,
                      width: size.width, height: size.height)
    }
}

/// 一个独立窗口：标准标题栏（不改标题栏 / 窗口底色），内容为 `DetachedWindowView`。
final class DetachedWindow: NSObject, NSWindowDelegate {
    let terminalID: UUID
    let window: NSWindow
    var onClose: ((UUID) -> Void)?
    var onFrameChange: (() -> Void)?
    private var contentInstalled = false

    init(terminalID: UUID, model: AppModel, frame: CGRect) {
        self.terminalID = terminalID
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.identifier = NSUserInterfaceItemIdentifier("detached-\(terminalID.uuidString)")
        window.minSize = NSSize(width: 380, height: 240)
        window.title = model.row(forTerminal: terminalID)?.displayName ?? model.pool.terminal(terminalID)?.title ?? ""
        window.setFrame(frame, display: false)
        window.delegate = self
    }

    /// 搭建窗口内容。必须在 `DetachedWindows` 登记好这个终端之后调用：内容第一次排版时就要确认
    /// 「终端归这个窗口显示」，登记前搭建会拿不到终端视图（窗口一片空白）。
    func installContent(model: AppModel) {
        guard !contentInstalled else { return }
        contentInstalled = true
        let window = self.window
        let frame = window.frame
        let content = NSHostingView(rootView: DetachedWindowView(
            model: model, terminalID: terminalID, onTitle: { [weak window] title in
                if let window, window.title != title { window.title = title }
            }).uiScaleRoot())
        // 不让 SwiftUI 内容的理想尺寸反过来改窗口大小。
        content.sizingOptions = []
        window.contentView = content
        window.setFrame(frame, display: false)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(terminalID)
        let window = self.window
        // 等这一轮事件结束再拆掉 SwiftUI 内容（不再观察 AppModel、不再托管终端视图）。
        DispatchQueue.main.async {
            window.delegate = nil
            window.contentView = nil
        }
    }

    func windowDidMove(_ notification: Notification) { onFrameChange?() }
    func windowDidEndLiveResize(_ notification: Notification) { onFrameChange?() }
}
