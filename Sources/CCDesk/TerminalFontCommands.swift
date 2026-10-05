import SwiftUI
import AppKit
import CCDeskCore

/// 菜单「显示」里的终端字号命令（设计 §18）：⌘= 放大、⌘- 缩小、⌥⌘0 恢复默认（⌘0 是「显示主窗口」）。
/// 改的是设置 › 通用 › 终端里的同一个字号，所有终端（含独立窗口）一起变，并短暂显示新字号。
/// 菜单项始终可用：到边界时只提示，不能置灰——置灰的菜单项不拦按键，⌘= / ⌘- 会落到终端里。
struct TerminalFontMenuItems: View {
    var body: some View {
        Button(L("menu.terminalFont.bigger")) { TerminalFontShortcuts.step(by: 1) }
            .keyboardShortcut("=", modifiers: .command)
        Button(L("menu.terminalFont.smaller")) { TerminalFontShortcuts.step(by: -1) }
            .keyboardShortcut("-", modifiers: .command)
        Button(L("menu.terminalFont.reset")) { TerminalFontShortcuts.reset() }
            .keyboardShortcut("0", modifiers: [.command, .option])
    }
}

/// 字号快捷键的动作，以及菜单项之外的等价按键：⌘+（美式键盘上是 ⇧⌘=）和小键盘的 ⌘+ / ⌘-。
/// 菜单只能绑一个组合，这些在 App 内的按键监视里处理并吞掉，不会发给终端。只在主线程使用。
enum TerminalFontShortcuts {
    private static var monitor: Any?

    static func step(by steps: Int) {
        let preferences = TerminalFontPreferences.shared
        let before = preferences.size
        let after = preferences.step(by: steps)
        let size = Int(after)
        let text: String
        if after != before {
            text = L("hud.terminalFont.size", size)
        } else {
            text = steps > 0 ? L("hud.terminalFont.max", size) : L("hud.terminalFont.min", size)
        }
        FontSizeHUD.shared.show(text)
    }

    static func reset() {
        TerminalFontPreferences.shared.resetSize()
        FontSizeHUD.shared.show(L("hud.terminalFont.size", Int(TerminalFontChoice.defaultSize)))
    }

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let steps = alternateSteps(for: event) else { return event }
            step(by: steps)
            return nil
        }
    }

    /// 菜单项没覆盖到的放大 / 缩小按键；其他按键返回 nil（照常处理）。
    static func alternateSteps(for event: NSEvent) -> Int? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command || flags == [.command, .shift] else { return nil }
        let keypadPlus: UInt16 = 69, keypadMinus: UInt16 = 78
        if event.keyCode == keypadPlus { return 1 }
        if event.keyCode == keypadMinus, flags == .command { return -1 }
        // ⌘= 由菜单处理；这里只接 ⇧⌘= 与直接打出「+」的键位（如德语键盘）。
        if flags == [.command, .shift], event.charactersIgnoringModifiers == "=" { return 1 }
        if event.characters == "+" || event.charactersIgnoringModifiers == "+" { return 1 }
        return nil
    }
}

/// 屏幕中央（当前窗口上方）短暂显示的一行提示，约 1 秒后淡出；不接收鼠标、不抢焦点。只在主线程使用。
final class FontSizeHUD {
    static let shared = FontSizeHUD()

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    func show(_ text: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        label.stringValue = text
        label.sizeToFit()
        let size = NSSize(width: max(140, label.frame.width + 40), height: 44)
        let anchor = NSApp.keyWindow?.frame ?? NSApp.mainWindow?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: anchor.midX - size.width / 2, y: anchor.midY - size.height / 2,
                              width: size.width, height: size.height), display: false)
        label.frame = NSRect(x: 20, y: (size.height - label.frame.height) / 2,
                             width: size.width - 40, height: label.frame.height)
        hideWork?.cancel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, let panel = self.panel, panel.alphaValue == 0 else { return }
            panel.orderOut(nil)
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        let background = NSVisualEffectView(frame: panel.contentLayoutRect)
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.alignment = .center
        label.textColor = .labelColor
        background.addSubview(label)
        panel.contentView = background
        return panel
    }
}
