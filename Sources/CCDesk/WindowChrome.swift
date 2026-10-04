import SwiftUI
import AppKit

/// 让窗口自身的底色（工具栏 / 标题栏区域露出的颜色）跟随主题：放在视图的 background 里，主题变化时随视图更新。
/// 只改 backgroundColor，不动标题栏样式：设置 titlebarAppearsTransparent 会让 SwiftUI 的工具栏
/// （红绿灯、侧栏 / 新建 / 历史按钮、会话标题）整个消失。
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
            guard let window, window.backgroundColor != color else { return }
            window.backgroundColor = color
        }
    }
}
