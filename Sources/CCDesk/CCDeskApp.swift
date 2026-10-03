import SwiftUI
import AppKit

/// App 内外观偏好：跟随系统 / 浅色 / 深色。设置 NSApp.appearance，SwiftUI 的 colorScheme 与终端配色随之更新。
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    static let defaultsKey = "appearance"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    static var stored: AppearancePreference {
        AppearancePreference(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
    }
    /// 同步切换：在同一个 CATransaction 里设置 App 外观并给所有终端换色，避免「先侧栏、后终端」两步跳变。
    func apply(pool: TerminalPool?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSApp.appearance = nsAppearance
        pool?.apply(TerminalTheme.of(NSApp.effectiveAppearance))
        CATransaction.commit()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppearancePreference.stored.apply(pool: model.pool)
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
    @AppStorage(AppearancePreference.defaultsKey) private var appearance: String = AppearancePreference.system.rawValue

    var body: some Scene {
        Window("CC Desk", id: "main") {
            ContentView(model: delegate.model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
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
            CommandGroup(after: .sidebar) {
                Button("历史会话") {
                    delegate.model.openMainWindow?()
                    delegate.model.showHistoryPalette = true
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
                Section("外观") {
                    ForEach(AppearancePreference.allCases) { pref in
                        Toggle(pref.label, isOn: Binding(
                            get: { appearance == pref.rawValue },
                            set: { on in
                                guard on else { return }
                                appearance = pref.rawValue
                                pref.apply(pool: delegate.model.pool)
                            }))
                    }
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("集成…") {
                    delegate.model.openMainWindow?()
                    delegate.model.showIntegrations = true
                }
                .keyboardShortcut(",")
            }
            CommandMenu("Session") {
                Button("安装 Codex / pi 状态集成…") {
                    delegate.model.openMainWindow?()
                    delegate.model.showIntegrations = true
                }
                Divider()
                Button("测试通知与角标") { delegate.model.testNotificationAndBadge() }
                Button("预先下载语音模型") {
                    delegate.model.openMainWindow?()
                    delegate.model.voice.predownload()
                }
                Divider()
                ForEach(1...9, id: \.self) { index in
                    Button("切换到第 \(index) 个") { delegate.model.selectEmbedded(index: index - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                }
            }
        }
    }
}
