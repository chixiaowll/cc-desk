import SwiftUI
import AppKit

/// 让窗口自身的底色（工具栏 / 标题栏区域露出的颜色）跟随主题：放在视图的 background 里，主题变化时随视图更新。
/// 标题栏设为透明，这样工具栏区域显示的就是这里设置的底色，而不是系统灰。
struct WindowChrome: NSViewRepresentable {
    let color: NSColor
    /// 标题栏透明（工具栏区域露出窗口底色）。设置窗口不要开：它的标签栏和关闭按钮会被内容盖住。
    var transparentTitlebar = true

    func makeNSView(context: Context) -> NSView { ChromeView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ChromeView else { return }
        view.transparentTitlebar = transparentTitlebar
        view.color = color
    }

    final class ChromeView: NSView {
        var transparentTitlebar = true
        var color: NSColor = .windowBackgroundColor { didSet { apply() } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            guard let window else { return }
            if transparentTitlebar { window.titlebarAppearsTransparent = true }
            if window.backgroundColor != color { window.backgroundColor = color }
        }
    }
}
