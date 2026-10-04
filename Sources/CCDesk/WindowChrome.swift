import SwiftUI
import AppKit

/// 让窗口自身的底色（工具栏 / 标题栏区域露出的颜色）跟随主题：放在视图的 background 里，主题变化时随视图更新。
/// 标题栏设为透明，这样工具栏区域显示的就是这里设置的底色，而不是系统灰。
struct WindowChrome: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> NSView { ChromeView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ChromeView)?.color = color
    }

    final class ChromeView: NSView {
        var color: NSColor = .windowBackgroundColor { didSet { apply() } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            if window.backgroundColor != color { window.backgroundColor = color }
        }
    }
}
