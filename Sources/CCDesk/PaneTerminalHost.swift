import AppKit
import SwiftUI
import CCDeskCore

/// 主窗口里所有内嵌终端视图常驻同一个容器（设计 §4.6 / §20）：切换 / 分屏只改每个视图的 frame 与 isHidden，
/// 不重建、不清屏，也不在容器之间搬来搬去。不在布局里的终端隐藏且保持原来的大小（不触发 tmux 改尺寸）。
/// 容器同时是侧栏会话行与窗格标题条的拖放目标：拖到窗格的四边分屏 / 挪过去，拖到中间替换 / 互换；
/// 分隔线的拖动、标题条的拖动（拖出窗格区域时分离到新窗口）也由它处理（`PaneTerminalHost+Drag`）。
/// 窗格容器上的鼠标操作交给 AppModel 的回调。
struct PaneHostActions {
    /// (终端, 目标窗格, 落点) -> 能否放下 / 放下。
    var canDrop: (UUID, UUID?, PaneDropZone) -> Bool = { _, _, _ in false }
    var drop: (UUID, UUID?, PaneDropZone) -> Bool = { _, _, _ in false }
    var focus: (UUID) -> Void = { _ in }
    var toggleZoom: (UUID) -> Void = { _ in }
    /// (拖动开始时的分隔线, 位移, 是否松手)。
    var resize: (PaneDivider, CGFloat, Bool) -> Void = { _, _, _ in }
    /// (终端, 松手处的屏幕坐标, 窗格大小)：标题条拖到窗格区域之外松手。
    var tearOff: (UUID, CGPoint, CGSize) -> Void = { _, _, _ in }
}

struct PaneTerminalHost: NSViewRepresentable {
    let pool: TerminalPool
    /// 由主窗口托管的终端（分离到独立窗口的不在内）。
    let owned: [UUID]
    /// 显示中的终端视图的位置（左上角为原点）。
    let terminalFrames: [UUID: CGRect]
    /// 显示中的窗格的整个区域（含标题条），用于点击与拖放定位。
    let paneFrames: [UUID: CGRect]
    /// 多窗格时各窗格的标题条区域（单窗格时为空）：按下可拖动窗格。
    let headerFrames: [UUID: CGRect]
    /// 可拖动的分隔线（单窗格或放大时为空）。
    let dividers: [PaneDivider]
    /// 窗格的会话名（拖动时的预览）与标题条的提示文字。
    let titles: [UUID: String]
    let tooltips: [UUID: String]
    /// 焦点窗格：变化时把键盘焦点交给它的终端。
    let focused: UUID?
    let background: NSColor
    let accent: NSColor
    let actions: PaneHostActions

    final class Coordinator {
        var lastFocused: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.wantsLayer = true
        view.registerForDraggedTypes([.string, HostView.paneType])
        return view
    }

    func updateNSView(_ host: HostView, context: Context) {
        host.layer?.backgroundColor = background.cgColor
        host.paneFrames = paneFrames
        host.terminalFrames = terminalFrames
        host.headerFrames = headerFrames
        host.dividers = dividers
        host.titles = titles
        host.tooltips = tooltips
        host.focused = focused
        host.actions = actions
        host.highlight.tint = accent
        host.background = background
        var views: [UUID: NSView] = [:]
        for id in owned {
            if let terminal = pool.terminal(id) { views[id] = terminal.view }
        }
        host.adopt(views)
        if context.coordinator.lastFocused != focused {
            context.coordinator.lastFocused = focused
            if let id = focused, let terminal = pool.terminal(id) {
                DispatchQueue.main.async {
                    guard terminal.view.superview === host else { return }
                    terminal.view.window?.makeFirstResponder(terminal.view)
                }
            }
        }
    }

    /// 托管所有主窗口终端视图的容器。分隔线与标题条的鼠标操作也在这里处理（AppKit 自己做命中测试、光标区域
    /// 与拖动），不依赖叠在上面的 SwiftUI 视图能不能收到事件；SwiftUI 只画线和标题条的内容（按钮除外都不接收点击）。
    final class HostView: NSView, NSViewToolTipOwner {
        /// 拖动窗格标题条时的私有拖放类型，内容为终端 id。
        static let paneType = NSPasteboard.PasteboardType("dev.local.ccdesk.pane")
        /// 分隔线两侧可拖动的宽度：几乎占满两个终端之间 20pt 的空隙（终端离窗格边缘左右 10pt、底部 8pt），不压到终端。
        static let dividerGrab: CGFloat = 8
        /// 标题条右侧按钮占的宽度（不显示抓手光标）。
        static let headerButtonsWidth: CGFloat = 92

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        var terminalFrames: [UUID: CGRect] = [:] {
            didSet { if terminalFrames != oldValue { applyFrames() } }
        }
        var paneFrames: [UUID: CGRect] = [:]
        var headerFrames: [UUID: CGRect] = [:] {
            didSet { if headerFrames != oldValue { chromeChanged(tooltips: true) } }
        }
        var dividers: [PaneDivider] = [] {
            didSet { if dividers != oldValue { chromeChanged(tooltips: false) } }
        }
        var titles: [UUID: String] = [:]
        var tooltips: [UUID: String] = [:]
        var focused: UUID?
        var background: NSColor = .textBackgroundColor
        var actions = PaneHostActions()
        let highlight = DropHighlightView()
        /// 当前托管的终端视图。
        private(set) var views: [UUID: NSView] = [:]
        /// 正在拖动的分隔线与按下的位置。
        private var resizing: (divider: PaneDivider, start: CGPoint)?
        /// 在标题条上按下、还没拖出拖动距离的窗格。
        private var pressedHeader: (id: UUID, start: CGPoint)?
        /// 正在拖出的窗格（拖动会话进行中）与它的大小。
        var draggingPane: (id: UUID, size: CGSize)?

        /// 托管这些终端视图：新来的加进来（先从原来的父视图移走），不再托管的移走。
        func adopt(_ newViews: [UUID: NSView]) {
            for (id, view) in views where newViews[id] !== view && view.superview === self {
                view.removeFromSuperview()
            }
            for (_, view) in newViews where view.superview !== self {
                view.removeFromSuperview()
                view.isHidden = true
                addSubview(view)
            }
            views = newViews
            if highlight.superview !== self || subviews.last !== highlight {
                highlight.removeFromSuperview()
                addSubview(highlight)
            }
            applyFrames()
        }

        override func layout() {
            super.layout()
            applyFrames()
        }

        private func applyFrames() {
            // 只动确实还在这里的视图：刚被独立窗口接走的终端还留在旧名单里（下一次 adopt 前），
            // 不能按「布局里没有它」把它隐藏，否则独立窗口一片空白。
            for (id, view) in views where view.superview === self {
                if let frame = terminalFrames[id] {
                    if view.frame != frame { view.frame = frame }
                    if view.isHidden { view.isHidden = false }
                } else if !view.isHidden {
                    view.isHidden = true
                }
            }
        }

        func pane(at point: CGPoint) -> UUID? {
            paneFrames.first { $0.value.contains(point) }?.key
        }

        /// `point` 所在的分隔线可拖动范围（有多条时取最近的）。
        func divider(at point: CGPoint) -> PaneDivider? {
            PaneDivider.hit(point, among: dividers, grab: Self.dividerGrab)
        }

        func header(at point: CGPoint) -> UUID? {
            headerFrames.first { $0.value.contains(point) }?.key
        }

        // MARK: 光标与提示

        private func chromeChanged(tooltips: Bool) {
            window?.invalidateCursorRects(for: self)
            if tooltips { rebuildToolTips() }
        }

        /// 标题条（按钮以外）显示抓手，分隔线显示左右 / 上下调整光标。cursor rect 由窗口管理，不用 push / pop。
        override func resetCursorRects() {
            for frame in headerFrames.values {
                var grab = frame
                grab.size.width = max(0, frame.width - Self.headerButtonsWidth)
                addCursorRect(grab, cursor: .openHand)
            }
            for divider in dividers {
                addCursorRect(divider.hitRect(grab: Self.dividerGrab),
                              cursor: divider.axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
            }
        }

        private func rebuildToolTips() {
            removeAllToolTips()
            for frame in headerFrames.values { addToolTip(frame, owner: self, userData: nil) }
        }

        func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                  userData data: UnsafeMutableRawPointer?) -> String {
            header(at: point).flatMap { tooltips[$0] } ?? ""
        }

        // MARK: 鼠标

        /// 按在分隔线上：开始调整比例。按在窗格里（终端之外的留白、标题条）：选中那个窗格；标题条上拖动超过
        /// 几个点时开始拖动窗格，双击放大 / 还原。点在终端里由终端视图自己通知（`onMouseDown`）。
        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if let divider = divider(at: point) {
                resizing = (divider, point)
                return
            }
            if let id = pane(at: point) { actions.focus(id) }
            if let id = header(at: point) {
                if event.clickCount == 2 {
                    actions.toggleZoom(id)
                } else {
                    pressedHeader = (id, point)
                }
                return
            }
            super.mouseDown(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if let resizing {
                actions.resize(resizing.divider, Self.delta(resizing.divider, from: resizing.start, to: point), false)
                return
            }
            if let pressed = pressedHeader {
                if hypot(point.x - pressed.start.x, point.y - pressed.start.y) >= 4 {
                    pressedHeader = nil
                    beginPaneDrag(pressed.id, event: event)
                }
                return
            }
            super.mouseDragged(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if let resizing {
                self.resizing = nil
                actions.resize(resizing.divider, Self.delta(resizing.divider, from: resizing.start, to: point), true)
                restoreKeyboardFocus()
                return
            }
            if pressedHeader != nil {
                pressedHeader = nil
                restoreKeyboardFocus()
                return
            }
            super.mouseUp(with: event)
        }

        /// 分隔线方向上的位移（横向分割取 x，纵向取 y）。
        static func delta(_ divider: PaneDivider, from start: CGPoint, to point: CGPoint) -> CGFloat {
            divider.axis == .horizontal ? point.x - start.x : point.y - start.y
        }

        /// 拖完分隔线 / 点完标题条：键盘焦点回到焦点窗格的终端。
        func restoreKeyboardFocus() {
            guard let id = focused, let view = views[id], view.superview === self, let window,
                  window.firstResponder !== view else { return }
            window.makeFirstResponder(view)
        }
    }

    /// 拖放落点的高亮：半透明强调色 + 描边；不接收鼠标事件。
    final class DropHighlightView: NSView {
        var tint: NSColor = .controlAccentColor {
            didSet { updateColors() }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            isHidden = true
            layer?.cornerRadius = 8
            layer?.borderWidth = 2
            updateColors()
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func updateColors() {
            layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
            layer?.borderColor = tint.withAlphaComponent(0.75).cgColor
        }
    }
}
