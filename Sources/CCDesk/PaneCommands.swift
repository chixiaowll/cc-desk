import SwiftUI
import AppKit
import CCDeskCore

/// 菜单「Session」里的分屏命令（设计 §20）：⌘D / ⇧⌘D 分屏，⌥⌘W 关闭分屏，⇧⌘↩ 放大 / 还原，⌥⌘方向键移动焦点。
/// 只在主窗口是 key 时生效；不能用时置灰，按键照常交给终端（如单窗格时的 ⌥⌘←）。
struct PaneCommands: View {
    let model: AppModel
    @ObservedObject var panes: PaneLayoutModel

    var body: some View {
        let layout = panes.layout
        let canSplit = layout.focused != nil && !layout.isFull
        Button(L("menu.splitRight")) { inMainWindow { model.requestSplit(.right) } }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(!canSplit)
        Button(L("menu.splitDown")) { inMainWindow { model.requestSplit(.bottom) } }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!canSplit)
        Button(layout.zoomed == nil ? L("menu.zoomPane") : L("menu.unzoomPane")) { inMainWindow { model.toggleZoom() } }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(!layout.isSplit)
        Button(L("menu.closePane")) { inMainWindow { model.closePane() } }
            .keyboardShortcut("w", modifiers: [.command, .option])
            .disabled(!layout.isSplit)
        Button(L("menu.detachPane")) { inMainWindow { model.detachFocused() } }
            .disabled(layout.focused == nil)
        Menu(L("menu.focusPane")) {
            focusButton(L("menu.focusLeft"), .left, key: .leftArrow)
            focusButton(L("menu.focusRight"), .right, key: .rightArrow)
            focusButton(L("menu.focusUp"), .top, key: .upArrow)
            focusButton(L("menu.focusDown"), .bottom, key: .downArrow)
        }
        .disabled(!layout.isSplit)
    }

    private func focusButton(_ title: String, _ edge: PaneEdge, key: KeyEquivalent) -> some View {
        Button(title) { inMainWindow { model.moveFocus(edge) } }
            .keyboardShortcut(key, modifiers: [.command, .option])
            .disabled(!panes.layout.isSplit)
    }

    /// 只在主窗口是 key 时执行（设置等其他窗口在前时什么都不做）。
    private func inMainWindow(_ action: () -> Void) {
        guard let key = NSApp.keyWindow, CCDeskApp.isMainWindow(key) else { return }
        action()
    }
}
