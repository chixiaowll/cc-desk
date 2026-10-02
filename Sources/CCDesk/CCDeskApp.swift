import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        model.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.confirmQuit() ? .terminateNow : .terminateCancel
    }

    /// 关闭窗口不退出，内嵌 session 继续运行；点 Dock 图标重新打开窗口。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 点 Dock 图标时，若没有可见窗口（已被关闭），重新打开主窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { model.openMainWindow?() }
        return true
    }
}

@main
struct CCDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("CC Desk", id: "main") {
            ContentView(model: delegate.model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建 Session") {
                    delegate.model.openMainWindow?()
                    delegate.model.showNewSession = true
                }
                .keyboardShortcut("n")
            }
            // `Window` scene 不像 WindowGroup 那样自带系统 "Close"（⌘W）菜单项，所以这里用
            // `after:` 新增而非 `replacing:` 某个占位组，确保有且只有一个 ⌘W 绑定。
            // 选中内嵌 session 时关闭该 session（沿用原有确认逻辑）；否则按标准行为关闭窗口本身。
            CommandGroup(after: .newItem) {
                Button("关闭当前 Session") {
                    if let row = delegate.model.selectedRow, row.session.host.isEmbedded {
                        delegate.model.closeSelected()
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w")
            }
            CommandMenu("Session") {
                ForEach(1...9, id: \.self) { index in
                    Button("切换到第 \(index) 个") { delegate.model.selectEmbedded(index: index - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                }
            }
        }
    }
}
