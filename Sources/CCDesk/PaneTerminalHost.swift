import AppKit
import SwiftUI
import CCDeskCore

/// 主窗口里所有内嵌终端视图常驻同一个容器（设计 §4.6 / §20）：切换 / 分屏只改每个视图的 frame 与 isHidden，
/// 不重建、不清屏，也不在容器之间搬来搬去。不在布局里的终端隐藏且保持原来的大小（不触发 tmux 改尺寸）。
/// 容器同时是侧栏会话行的拖放目标：拖到窗格的四边分屏，拖到中间替换。
struct PaneTerminalHost: NSViewRepresentable {
    let pool: TerminalPool
    /// 由主窗口托管的终端（分离到独立窗口的不在内）。
    let owned: [UUID]
    /// 显示中的终端视图的位置（左上角为原点）。
    let terminalFrames: [UUID: CGRect]
    /// 显示中的窗格的整个区域（含标题条），用于点击与拖放定位。
    let paneFrames: [UUID: CGRect]
    /// 焦点窗格：变化时把键盘焦点交给它的终端。
    let focused: UUID?
    let background: NSColor
    let accent: NSColor
    let canDrop: (UUID, UUID?, PaneDropZone) -> Bool
    let onDrop: (UUID, UUID?, PaneDropZone) -> Bool
    let onClickPane: (UUID) -> Void

    final class Coordinator {
        var lastFocused: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.wantsLayer = true
        view.registerForDraggedTypes([.string])
        return view
    }

    func updateNSView(_ host: HostView, context: Context) {
        host.layer?.backgroundColor = background.cgColor
        host.paneFrames = paneFrames
        host.terminalFrames = terminalFrames
        host.canDrop = canDrop
        host.onDrop = onDrop
        host.onClickPane = onClickPane
        host.highlight.tint = accent
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

    final class HostView: NSView {
        override var isFlipped: Bool { true }

        var terminalFrames: [UUID: CGRect] = [:] {
            didSet { if terminalFrames != oldValue { applyFrames() } }
        }
        var paneFrames: [UUID: CGRect] = [:]
        var canDrop: ((UUID, UUID?, PaneDropZone) -> Bool)?
        var onDrop: ((UUID, UUID?, PaneDropZone) -> Bool)?
        var onClickPane: ((UUID) -> Void)?
        let highlight = DropHighlightView()
        /// 当前托管的终端视图。
        private var views: [UUID: NSView] = [:]

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
            for (id, view) in views {
                if let frame = terminalFrames[id] {
                    if view.frame != frame { view.frame = frame }
                    if view.isHidden { view.isHidden = false }
                } else if !view.isHidden {
                    view.isHidden = true
                }
            }
        }

        private func pane(at point: CGPoint) -> UUID? {
            paneFrames.first { $0.value.contains(point) }?.key
        }

        /// 点在终端之外的留白（窗格内边距）：选中那个窗格。点在终端里由终端视图自己通知（`onMouseDown`）。
        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if let id = pane(at: point) { onClickPane?(id) }
            super.mouseDown(with: event)
        }

        // MARK: 拖放（侧栏会话行的拖动内容为 "row:term:<uuid>"）

        /// 拖动中读不到内容时（SwiftUI 的拖动内容可能延迟提供）先按可放下处理，松手时再核对。
        private func payload(_ info: NSDraggingInfo) -> (id: UUID?, known: Bool)? {
            let pasteboard = info.draggingPasteboard
            guard pasteboard.types?.contains(.string) == true else { return nil }
            guard let text = pasteboard.string(forType: .string) else { return (nil, false) }
            guard let id = AppModel.draggedTerminalID(text) else { return nil }
            return (id, true)
        }

        private func target(_ info: NSDraggingInfo) -> (pane: UUID?, zone: PaneDropZone, area: CGRect) {
            let point = convert(info.draggingLocation, from: nil)
            guard let id = pane(at: point), let frame = paneFrames[id] else { return (nil, .center, bounds) }
            let zone = PaneDropZone.at(point, in: frame)
            return (id, zone, zone.highlight(in: frame))
        }

        private func operation(_ info: NSDraggingInfo) -> NSDragOperation {
            let mask = info.draggingSourceOperationMask
            for candidate: NSDragOperation in [.move, .generic, .copy] where mask.contains(candidate) { return candidate }
            return []
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let payload = payload(sender) else { return hideHighlight() }
            let target = target(sender)
            if let id = payload.id, canDrop?(id, target.pane, target.zone) != true { return hideHighlight() }
            highlight.frame = target.area.insetBy(dx: 3, dy: 3)
            highlight.isHidden = false
            return operation(sender)
        }

        override func draggingExited(_ sender: NSDraggingInfo?) { hideHighlight() }
        override func draggingEnded(_ sender: NSDraggingInfo) { hideHighlight() }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            hideHighlight()
            guard let text = sender.draggingPasteboard.string(forType: .string),
                  let id = AppModel.draggedTerminalID(text) else { return false }
            let target = target(sender)
            return onDrop?(id, target.pane, target.zone) ?? false
        }

        @discardableResult
        private func hideHighlight() -> NSDragOperation {
            highlight.isHidden = true
            return []
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
