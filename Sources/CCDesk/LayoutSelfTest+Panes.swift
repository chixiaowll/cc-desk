import AppKit
import SwiftUI
import CCDeskCore

/// `--layout-selftest` 的鼠标整理部分（设计 §20.2）：挪动 / 互换 / 拖分隔线的布局结果，
/// 以及窗格容器的命中区域（分隔线之间的空隙归容器、窗格里归终端；叠上 SwiftUI 之后仍如此）。
extension LayoutSelfTest {
    private static let size = CGSize(width: 1200, height: 800)
    private static let minPane = PaneLayoutModel.minPane

    /// a | (b / c)，再在 a 下面分出 d：四个窗格。
    private static func fourPanes(_ ids: [UUID]) -> PaneLayout {
        var layout = PaneLayout()
        layout.show(ids[0])
        layout.split(ids[0], edge: .right, with: ids[1])
        layout.split(ids[1], edge: .bottom, with: ids[2])
        layout.split(ids[0], edge: .bottom, with: ids[3])
        return layout
    }

    /// 把每个窗格挪到其它每个窗格的每一边、两两互换：窗格集合不变、铺满、焦点跟着走；
    /// 拖分隔线：比例跟着位移走，拖得再远两侧也不小于最小窗格。
    static func checkRearrange() {
        let ids = (0..<4).map { _ in UUID() }
        let area = CGRect(origin: .zero, size: size)
        var broken: String?
        for moving in ids {
            for target in ids where target != moving {
                for edge in PaneEdge.allCases where broken == nil {
                    var layout = fourPanes(ids)
                    guard layout.move(moving, beside: target, edge: edge) else {
                        broken = "move \(edge) refused"
                        continue
                    }
                    let frames = layout.frames(in: area)
                    let covered = frames.values.reduce(0) { $0 + $1.width * $1.height }
                    guard let moved = frames[moving], let anchor = frames[target] else {
                        broken = "pane missing after move"
                        continue
                    }
                    let beside: Bool
                    switch edge {
                    case .left: beside = abs(moved.maxX - anchor.minX) < 0.5
                    case .right: beside = abs(moved.minX - anchor.maxX) < 0.5
                    case .top: beside = abs(moved.maxY - anchor.minY) < 0.5
                    case .bottom: beside = abs(moved.minY - anchor.maxY) < 0.5
                    }
                    if Set(layout.leaves) != Set(ids) || layout.count != 4 { broken = "panes changed by move" }
                    else if abs(covered - area.width * area.height) > 1 { broken = "panes do not tile after move" }
                    else if layout.focused != moving { broken = "focus did not follow the moved pane" }
                    else if !beside { broken = "moved pane not on the \(edge) side of its target" }
                }
            }
        }
        check(broken == nil, "moving every pane beside every other pane keeps the layout valid\(broken.map { ": \($0)" } ?? "")")

        var swapped = fourPanes(ids)
        let before = swapped.frames(in: area)
        swapped.swap(ids[0], ids[2])
        let after = swapped.frames(in: area)
        check(after[ids[0]] == before[ids[2]] && after[ids[2]] == before[ids[0]] && after[ids[1]] == before[ids[1]],
              "swapping two panes exchanges their frames")

        var layout = fourPanes(ids)
        var ratiosOK = true
        for divider in layout.dividers(in: area) {
            for delta: CGFloat in [-2000, -120, -1, 0, 1, 120, 2000] {
                var copy = layout
                copy.setRatio(copy.ratio(dragging: divider, by: delta, in: size, minPane: minPane), at: divider.path)
                let tooSmall = copy.frames(in: area).values.contains {
                    $0.width < minPane.width - 0.5 || $0.height < minPane.height - 0.5
                }
                if tooSmall { ratiosOK = false }
            }
        }
        check(ratiosOK, "dragging any divider any distance keeps every pane at least \(Int(minPane.width))x\(Int(minPane.height))")
        if let root = layout.dividers(in: area).first(where: { $0.path == [] }) {
            layout.setRatio(layout.ratio(dragging: root, by: 120, in: size, minPane: minPane), at: root.path)
            let moved = layout.dividers(in: area).first { $0.path == [] }?.position ?? 0
            check(abs(moved - (root.position + 120)) < 0.5, "dragging the root divider by 120pt moves it by 120pt")
        }
    }

    /// 窗格容器的命中区域：分隔线可拖动范围里是容器自己（容器处理拖动），窗格里是终端；鼠标按下 / 拖动 / 松开
    /// 分隔线按位移调整比例；叠上 SwiftUI 的分隔线和标题条（按钮以外不接收点击）后，空隙与标题条仍交给容器。
    static func checkHostMouseAreas() {
        let ids = (0..<3).map { _ in UUID() }
        var layout = PaneLayout()
        layout.show(ids[0])
        layout.split(ids[0], edge: .right, with: ids[1])
        layout.split(ids[1], edge: .bottom, with: ids[2])
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        let host = PaneTerminalHost.HostView(frame: NSRect(origin: .zero, size: size))
        window.contentView = host
        var views: [UUID: NSView] = [:]
        for id in ids { views[id] = DetectingTerminalView(frame: NSRect(x: 0, y: 0, width: 300, height: 200)) }
        let geometry = PaneGeometry(layout: layout, size: size)
        host.adopt(views)
        host.paneFrames = geometry.paneFrames
        host.terminalFrames = geometry.terminalFrames
        host.headerFrames = geometry.headerFrames
        host.dividers = geometry.dividers
        host.focused = ids[0]

        func hit(_ point: CGPoint) -> NSView? {
            host.superview.flatMap { host.hitTest(host.convert(point, to: $0)) }
        }
        let gapPoints = geometry.dividers.flatMap { divider -> [CGPoint] in
            let line = divider.axis == .horizontal
                ? [CGPoint(x: divider.position, y: divider.rect.midY), CGPoint(x: divider.position + 5, y: divider.rect.midY + 40)]
                : [CGPoint(x: divider.rect.midX, y: divider.position), CGPoint(x: divider.rect.midX - 40, y: divider.position - 5)]
            return line
        }
        check(!gapPoints.isEmpty && gapPoints.allSatisfy { host.divider(at: $0) != nil && hit($0) === host },
              "points in the gaps between panes hit a divider on the host (\(gapPoints.count) points)")
        let paneCenters = ids.compactMap { geometry.terminalFrames[$0].map { CGPoint(x: $0.midX, y: $0.midY) } }
        check(paneCenters.count == 3 && paneCenters.allSatisfy { point in
            host.divider(at: point) == nil && ids.contains { id in
                guard let view = views[id], let hitView = hit(point) else { return false }
                return hitView === view || hitView.isDescendant(of: view)
            }
        }, "points inside panes hit the terminal, not a divider")
        let headerPoints = ids.compactMap { id in geometry.headerFrames[id].map { (id, CGPoint(x: $0.minX + 60, y: $0.midY)) } }
        check(headerPoints.count == 3 && headerPoints.allSatisfy { host.header(at: $0.1) == $0.0 && hit($0.1) === host },
              "pane headers belong to the host (drag source)")

        // 按下 / 拖动 / 松开分隔线：位移交给 resize 回调，松开时保存。
        var current = layout
        var saved = false
        host.actions.resize = { divider, delta, save in
            current.setRatio(current.ratio(dragging: divider, by: delta, in: size, minPane: minPane), at: divider.path)
            if save { saved = true }
        }
        if let root = geometry.dividers.first(where: { $0.path == [] }) {
            let start = CGPoint(x: root.position, y: 300)
            func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            if let down = event(.leftMouseDown, start), let drag = event(.leftMouseDragged, CGPoint(x: start.x - 90, y: 310)),
               let up = event(.leftMouseUp, CGPoint(x: start.x - 2000, y: 310)) {
                host.mouseDown(with: down)
                host.mouseDragged(with: drag)
                let midDrag = current.dividers(in: CGRect(origin: .zero, size: size)).first { $0.path == [] }?.position ?? 0
                check(abs(midDrag - (root.position - 90)) < 0.5 && !saved, "dragging the divider on the host resizes the panes live")
                host.mouseUp(with: up)
                let leftWidth = current.frames(in: CGRect(origin: .zero, size: size))[ids[0]]?.width ?? 0
                check(saved && abs(leftWidth - minPane.width) < 0.5,
                      "releasing far away clamps to the minimum pane width and saves (left pane \(Int(leftWidth))pt)")
            } else {
                check(false, "could not create mouse events")
            }
        }
        checkSwiftUIRouting(host: host, geometry: geometry, ids: ids, views: views)
        window.contentView = nil
    }

    /// 把同一个容器放进 SwiftUI（与 PaneArea 同样的叠放：容器在下，分隔线和标题条在上），看命中交给谁。
    private static func checkSwiftUIRouting(host: PaneTerminalHost.HostView, geometry: PaneGeometry,
                                            ids: [UUID], views: [UUID: NSView]) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        let theme = ThemeStore.shared.theme(for: .dark)
        let hosting = NSHostingView(rootView: RoutingProbe(host: host, geometry: geometry, ids: ids, theme: theme))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        func hit(_ point: CGPoint) -> NSView? {
            hosting.superview.flatMap { hosting.hitTest(host.convert(point, to: $0)) }
        }
        let dividerPoints = geometry.dividers.map { divider in
            divider.axis == .horizontal ? CGPoint(x: divider.position + 3, y: divider.rect.midY)
                : CGPoint(x: divider.rect.midX, y: divider.position - 3)
        }
        check(host.window === window && dividerPoints.allSatisfy { hit($0) === host },
              "under SwiftUI, divider gaps still reach the host")
        let headerPoints = ids.compactMap { geometry.headerFrames[$0].map { CGPoint(x: $0.minX + 60, y: $0.midY) } }
        check(headerPoints.allSatisfy { hit($0) === host }, "under SwiftUI, pane headers (outside buttons) reach the host")
        let buttonPoints = ids.compactMap { geometry.headerFrames[$0].map { CGPoint(x: $0.maxX - 17, y: $0.midY) } }
        check(buttonPoints.allSatisfy { point in hit(point).map { $0 !== host && !$0.isDescendant(of: host) } ?? false },
              "under SwiftUI, header buttons stay with SwiftUI")
        let inside = ids.compactMap { id in geometry.terminalFrames[id].map { (id, CGPoint(x: $0.midX, y: $0.midY)) } }
        check(inside.allSatisfy { pair in
            guard let view = views[pair.0], let hitView = hit(pair.1) else { return false }
            return hitView === view || hitView.isDescendant(of: view)
        }, "under SwiftUI, terminal content still reaches the terminal")
        window.contentView = nil
    }
}

/// 自检用：与 PaneArea 同样的叠放，标题条换成同样结构（内容不接收点击 + 按钮）的替身（不需要 AppModel）。
private struct RoutingProbe: View {
    let host: PaneTerminalHost.HostView
    let geometry: PaneGeometry
    let ids: [UUID]
    let theme: Theme

    var body: some View {
        ZStack(alignment: .topLeading) {
            ExistingView(view: host)
            ForEach(geometry.dividers, id: \.path) { PaneDividerLine(divider: $0, theme: theme) }
            ForEach(ids, id: \.self) { id in
                if let frame = geometry.paneFrames[id] {
                    VStack(spacing: 0) {
                        HStack(spacing: 7) {
                            HStack { Text("session"); Spacer(minLength: 4) }.allowsHitTesting(false)
                            SidebarIconButton(systemName: "xmark", help: "", theme: theme) {}
                        }
                        .padding(.leading, 12)
                        .padding(.trailing, 6)
                        .frame(height: PaneGeometry.headerHeight)
                        Color.clear.allowsHitTesting(false)
                    }
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .frame(width: geometry.paneFrames.values.map(\.maxX).max() ?? 0,
               height: geometry.paneFrames.values.map(\.maxY).max() ?? 0, alignment: .topLeading)
    }
}

private struct ExistingView: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
