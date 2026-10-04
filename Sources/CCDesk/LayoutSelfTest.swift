import AppKit
import SwiftTerm
import CCDeskCore

/// `CCDesk --layout-selftest`：不启动界面，在屏幕外的容器里验证分屏（设计 §20）：按布局摆放真正的 SwiftTerm 视图、
/// 隐藏不在布局里的终端、在两个容器之间搬动视图（同一视图任何时候只有一个父视图），以及随机操作序列下布局的不变量。
/// 不启动任何进程、不碰 ~/.cc-desk 与 tmux。
enum LayoutSelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.dropFirst().contains("--layout-selftest") else { return }
        exit(run() ? 0 : 1)
    }

    private static var failures = 0

    static func check(_ ok: Bool, _ message: String) {
        print("\(ok ? "PASS" : "FAIL") \(message)")
        if !ok { failures += 1 }
    }

    static func run() -> Bool {
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared
        checkInvariantsUnderRandomOperations()
        checkHostPlacement()
        checkRearrange()
        checkHostMouseAreas()
        print(failures == 0 ? "layout selftest: all passed" : "layout selftest: \(failures) failure(s)")
        return failures == 0
    }

    /// 随机分屏 / 移除 / 替换 / 交换 / 移动焦点 / 放大，每一步后检查：叶子不重复、不超过 4 个、焦点在布局里、
    /// 放大的窗格在布局里且至少两个窗格、各窗格铺满且不重叠、编码解码后不变。
    private static func checkInvariantsUnderRandomOperations() {
        var generator = SplitMix(seed: 20261004)
        let ids = (0..<7).map { _ in UUID() }
        var layout = PaneLayout()
        var broken: String?
        let area = CGRect(x: 0, y: 0, width: 1200, height: 800)
        for step in 0..<5000 where broken == nil {
            let a = ids[Int(generator.next() % 7)], b = ids[Int(generator.next() % 7)]
            let edge = PaneEdge.allCases[Int(generator.next() % 4)]
            switch generator.next() % 8 {
            case 0, 1: layout.split(a, edge: edge, with: b)
            case 2: layout.remove(a)
            case 3: layout.replace(a, with: b)
            case 4: layout.swap(a, b)
            case 5: layout.moveFocus(edge)
            case 6: layout.toggleZoom(a)
            default: layout.show(a)
            }
            if Bool.random(using: &generator) {
                layout.setRatio(Double(generator.next() % 1000) / 1000, at: [Int(generator.next() % 2)])
            }
            let leaves = layout.leaves
            let frames = layout.frames(in: area)
            let covered = frames.values.reduce(0) { $0 + $1.width * $1.height }
            if Set(leaves).count != leaves.count { broken = "duplicate leaf at step \(step)" }
            else if leaves.count > PaneLayout.maxPanes { broken = "more than 4 panes at step \(step)" }
            else if layout.isEmpty != (layout.focused == nil) { broken = "focus/emptiness mismatch at step \(step)" }
            else if let focused = layout.focused, !leaves.contains(focused) { broken = "focus outside layout at step \(step)" }
            else if let zoomed = layout.zoomed, !leaves.contains(zoomed) || leaves.count < 2 { broken = "bad zoom at step \(step)" }
            else if !leaves.isEmpty, abs(covered - area.width * area.height) > 1 { broken = "panes do not tile at step \(step)" }
            else if let data = try? JSONEncoder().encode(layout),
                    (try? JSONDecoder().decode(PaneLayout.self, from: data)) != layout { broken = "codable mismatch at step \(step)" }
        }
        check(broken == nil, "5000 random layout operations keep invariants\(broken.map { ": \($0)" } ?? "")")
    }

    /// 真正的 SwiftTerm 视图放进屏幕外的容器：按布局摆放、隐藏其余、搬到另一个容器再搬回来。
    private static func checkHostPlacement() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        let main = PaneTerminalHost.HostView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        let other = PaneTerminalHost.HostView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = main
        let ids = (0..<5).map { _ in UUID() }
        var views: [UUID: NSView] = [:]
        for id in ids { views[id] = DetectingTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)) }

        var layout = PaneLayout()
        layout.show(ids[0])
        layout.split(ids[0], edge: .right, with: ids[1])
        layout.split(ids[1], edge: .bottom, with: ids[2])
        let size = CGSize(width: 1200, height: 800)
        var geometry = PaneGeometry(layout: layout, size: size)
        main.adopt(views)
        main.terminalFrames = geometry.terminalFrames
        check(views.values.allSatisfy { $0.superview === main }, "all terminal views hosted by the main container")
        check(ids[0...2].allSatisfy { views[$0]?.isHidden == false } && ids[3...].allSatisfy { views[$0]?.isHidden == true },
              "visible panes shown, other terminals hidden")
        check(ids[0...2].allSatisfy { views[$0]?.frame == geometry.terminalFrames[$0] }, "terminal frames follow the layout")
        let hiddenFrame = views[ids[3]]?.frame
        if let view = views[ids[2]] as? DetectingTerminalView {
            let terminal = view.getTerminal()
            check(terminal.cols > 0 && terminal.rows > 0 && terminal.cols < 200,
                  "pane-sized terminal resized to \(terminal.cols)x\(terminal.rows)")
        }

        layout.toggleZoom(ids[1])
        geometry = PaneGeometry(layout: layout, size: size)
        main.terminalFrames = geometry.terminalFrames
        check(views[ids[1]]?.isHidden == false && views[ids[0]]?.isHidden == true && views[ids[2]]?.isHidden == true,
              "zoom shows only the zoomed pane")
        check(views[ids[3]]?.frame == hiddenFrame, "hidden terminals keep their size")

        // 搬到另一个容器（如分离窗口），主容器不再托管它；再搬回来。
        var moved = views
        let detached = moved.removeValue(forKey: ids[1])
        main.adopt(moved)
        other.adopt(detached.map { [ids[1]: $0] } ?? [:])
        check(detached?.superview === other && !main.subviews.contains { $0 === detached }, "view moved to the other container")
        check(main.subviews.filter { $0 is DetectingTerminalView }.count == 4, "main container keeps the remaining 4 views")
        other.adopt([:])
        main.adopt(views)
        check(detached?.superview === main && other.subviews.filter { $0 is DetectingTerminalView }.isEmpty,
              "view returned to the main container")
        let allViews = Set((main.subviews + other.subviews).filter { $0 is DetectingTerminalView }.map(ObjectIdentifier.init))
        check(allViews.count == ids.count, "every terminal view has exactly one host")

        // 独立窗口：放进屏幕外窗口里的单终端容器，主容器交出；独立窗口先交出、主容器后接回（以及反过来的顺序）。
        let detachedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        let single = SingleTerminalHostView(frame: NSRect(x: 0, y: 0, width: 820, height: 560))
        detachedWindow.contentView = single
        if let view = views[ids[2]] {
            var remaining = views
            remaining[ids[2]] = nil
            single.host(view)
            main.adopt(remaining)
            single.layout()
            check(view.superview === single && view.window === detachedWindow && !view.isHidden,
                  "detached window hosts the terminal")
            check(view.frame.width > 700 && view.frame.height > 450, "detached terminal fills its window")
            single.host(nil)
            main.adopt(views)
            check(view.superview === main && single.subviews.isEmpty, "closing the window returns the view (window first)")
            main.adopt(remaining)
            single.host(view)
            main.adopt(remaining)
            single.host(nil)
            single.host(nil)
            main.adopt(views)
            check(view.superview === main, "returning works when the window releases twice")
            single.host(view)
            main.adopt(views)       // 主容器先接回
            single.host(nil)        // 独立窗口后交出：不能把已经回到主容器的视图拿走
            check(view.superview === main, "returning works when the main container takes the view first")
        }
        detachedWindow.contentView = nil

        if let view = views[ids[0]] {
            layout.toggleZoom(ids[0])
            main.terminalFrames = PaneGeometry(layout: layout, size: size).terminalFrames
            check(window.makeFirstResponder(view) && window.firstResponder === view, "focused pane's terminal can take keyboard focus")
        }
    }
}

/// 可复现的伪随机数（自检用固定种子）。
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
