import SwiftUI
import AppKit
import CCDeskCore

/// App 内外观偏好：跟随系统 / 浅色 / 深色。设置 NSApp.appearance，SwiftUI 的 colorScheme 与终端配色随之更新。
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    static let defaultsKey = "appearance"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return L("appearance.system")
        case .light: return L("appearance.light")
        case .dark: return L("appearance.dark")
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
        pool?.apply(ThemeStore.shared.terminalTheme(for: NSApp.effectiveAppearance))
        CATransaction.commit()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    /// 正在为切换语言而重启。
    var relaunching = false
    /// 这次是登录时自动启动（不显示 / 不激活主窗口，见设计 §15）。
    private(set) var launchedAtLogin = false
    /// applicationWillFinishLaunching 时启动 Apple 事件是否带「作为登录项启动」标记。
    private var loginItemEvent = false
    private var desktop: DesktopPresence?

    func applicationWillFinishLaunching(_ notification: Notification) {
        LocalizationProbe.runIfRequested()
        loginItemEvent = LoginLaunchDetector.appleEventSaysLoginItem()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        launchedAtLogin = LoginLaunchDetector.detect(
            appleEventSaysLoginItem: loginItemEvent || LoginLaunchDetector.appleEventSaysLoginItem())
        let desktop = DesktopPresence(delegate: self)
        self.desktop = desktop
        if launchedAtLogin {
            // 登录启动：不抢焦点，主窗口出现后立即收起；点 Dock 图标 / 菜单栏菜单再显示。
            desktop.suppressMainWindowAtLaunch()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        // 点通知等用户主动打开主窗口的路径都走 showMainWindow（会结束登录启动时的收起）。
        model.revealMainWindow = { [weak self] in self?.showMainWindow() }
        ThemeStore.shared.pool = model.pool
        TerminalFontPreferences.shared.onFontChange = { [weak pool = model.pool] in pool?.applyFont() }
        TerminalFontShortcuts.install()
        AppearancePreference.stored.apply(pool: model.pool)
        model.start()
        // 上次分离的独立窗口：登录启动时等用户打开主窗口再显示（showMainWindow）。
        if !launchedAtLogin { model.openPendingDetachedWindows() }
        desktop.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.confirmQuit() else {
            relaunching = false
            return .terminateCancel
        }
        guard relaunching else { return .terminateNow }
        launchNewInstanceThenTerminate()
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 顾问的 claude（连同它启动的 git 等）不随 App 退出：结束整个进程组。
        model.work.cancelAll()
        model.conversation.turnOff()
        model.companion.shutdown()
        NaturalSpeechEngine.shared.unload()
        model.stopControlServer()
    }

    /// 关闭窗口不退出，内嵌 session 继续运行；点 Dock 图标重新打开窗口。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 点 Dock 图标 / 再次打开 App 时显示主窗口。不依赖 hasVisibleWindows：语音浮层等辅助窗口也会被算作「可见」，
    /// 导致主窗口关掉后再也打不开。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMainWindow()
        return true
    }

    /// 主窗口（`Window` scene 的 NSWindow）；被关闭 / 销毁后为 nil。
    var mainWindow: NSWindow? {
        NSApp.windows.first { window in
            guard let id = window.identifier?.rawValue else { return false }
            return id == "main" || id.hasPrefix("main-")
        }
    }

    /// 主窗口还在（被关闭 / 最小化 / 登录启动时收起）就拿到最前；已经销毁则重新打开。
    func showMainWindow() {
        desktop?.endLaunchSuppression()
        model.openPendingDetachedWindows()
        if NSApp.isHidden { NSApp.unhide(nil) }
        if let main = mainWindow {
            if main.isMiniaturized { main.deminiaturize(nil) }
            main.makeKeyAndOrderFront(nil)
        } else {
            model.openMainWindow?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 全局快捷键「显示 / 隐藏 CC Desk」：已在最前且主窗口可见时隐藏 App，否则显示主窗口。
    func toggleMainWindow() {
        if NSApp.isActive, let main = mainWindow, main.isVisible, !main.isMiniaturized {
            NSApp.hide(nil)
        } else {
            showMainWindow()
        }
    }

    /// 菜单「新建会话」：显示主窗口并打开新建表单。
    func showNewSession() {
        showMainWindow()
        model.openMainWindow?()
        model.showNewSession = true
    }
}

/// 入口：`--mcp` 时作为助手的 stdio MCP 工具服务器运行（不启动界面，设计 §13）；`--tts-test` 时验证自然语音引擎后退出；
/// `--tmux-selftest` 时在隔离的 tmux 服务器上自检会话托管层后退出（设计 §4.9）；`--layout-selftest` 时在屏幕外自检分屏（设计 §20）；
/// `--ui-scale-selftest` 时在屏幕外按各档界面文字渲染关键组件（设计 §25）；
/// `--skills-selftest` 时只读扫描本机技能并打印各来源的数量与名字（设计 §21）；`--files-selftest` 时在临时目录里
/// 自检项目监视与提到的文件（设计 §17）；`--proc-selftest` 时对照原生进程表与 ps、`--perf-selftest` 时量空闲开销（设计 §26）；`--consult-test` 时用真实的
/// claude 验证顾问的只读参数后退出（设计 §14）；`--companion-test` 时用真实的 claude 验证通用助手（设计 §24）；`--assistant-api-selftest` 时用本机假服务验证 OpenAI 兼容接口后端（设计 §22）；
/// 否则拿单实例锁（已有实例时激活它并退出）后启动 App。
@main
enum CCDeskMain {
    static func main() {
        // 子进程（助手会话 / 语音服务 / MCP）退出后再写它的管道会触发 SIGPIPE，默认会终止整个 App；
        // 忽略后写入只会返回错误，由调用方处理。
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.dropFirst().contains("--mcp") { MCPMode.run() }
        NaturalSpeechTest.runIfRequested()
        TmuxSelfTest.runIfRequested()
        LayoutSelfTest.runIfRequested()
        UIScaleSelfTest.runIfRequested()
        SkillsSelfTest.runIfRequested()
        FilesSelfTest.runIfRequested()
        ProcSelfTest.runIfRequested()
        PerfSelfTest.runIfRequested()
        ConsultTest.runIfRequested()
        CompanionTest.runIfRequested()
        AssistantAPISelfTest.runIfRequested()
        PushSecretImport.runIfRequested()
        SingleInstance.acquireOrHandOff()
        CCDeskApp.main()
    }
}

/// 菜单「切换到」：⌘1–9 对应侧栏从上到下的会话，菜单里直接写出会话名。
private struct SwitchSessionMenuItems: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let rows = model.numberedRows
        ForEach(1...9, id: \.self) { index in
            let row = rows.indices.contains(index - 1) ? rows[index - 1] : nil
            Button(row.map { L("menu.switchTo", $0.displayName) } ?? L("menu.switchTo.empty", index)) {
                model.selectNumbered(index: index - 1)
            }
            .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
            .disabled(row == nil)
        }
    }
}

struct CCDeskApp: App {
    /// 主窗口（`Window("CC Desk", id: "main")` 的 NSWindow 标识以 "main" 开头）。
    static func isMainWindow(_ window: NSWindow) -> Bool {
        guard let id = window.identifier?.rawValue else { return false }
        return id == "main" || id.hasPrefix("main-")
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("CC Desk", id: "main") {
            ContentView(model: delegate.model)
                .uiScaleRoot()
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("menu.newSession")) { delegate.showNewSession() }
                .keyboardShortcut("n")
            }
            // `Window` scene 不像 WindowGroup 那样自带系统 "Close"（⌘W）菜单项，所以这里用
            // `after:` 新增而非 `replacing:` 某个占位组，确保有且只有一个 ⌘W 绑定。
            // 选中内嵌 session 时关闭该 session（沿用原有确认逻辑）；否则按标准行为关闭窗口本身。
            CommandGroup(after: .newItem) {
                Button(L("menu.closeSession")) {
                    // 只有主窗口是 key 时才关选中的会话；设置等其他窗口在前时关那个窗口；
                    // 没有 key 窗口（主窗口已关 / 收起）时什么都不做，不能误关侧栏里选中的会话。
                    guard let key = NSApp.keyWindow else { return }
                    if Self.isMainWindow(key), let row = delegate.model.selectedRow, row.session.host.isEmbedded {
                        delegate.model.closeSelected()
                    } else {
                        key.performClose(nil)
                    }
                }
                .keyboardShortcut("w")
            }
            // 菜单「窗口 → 显示主窗口」（⌘0）：主窗口被关掉时也能从菜单栏找回来。
            CommandGroup(after: .windowArrangement) {
                Button(L("menu.showMainWindow")) { delegate.showMainWindow() }
                    .keyboardShortcut("0")
            }
            CommandGroup(after: .sidebar) {
                Button(L("menu.history")) {
                    delegate.showMainWindow()
                    delegate.model.showHistoryPalette = true
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                TouchedFilesMenuItem(files: delegate.model.touchedFiles)
                Button(L("menu.skills")) { delegate.model.skills.showWindow() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                ThemeMenu()
                Divider()
                TerminalFontMenuItems()
            }
            // 偏好开关都在设置窗口（⌘,）里；这里只留常用动作。
            CommandMenu(L("menu.session")) {
                ConversationMenuItem(model: delegate.model, conversation: delegate.model.conversation)
                Button(L("menu.resetAssistant")) { delegate.model.conversation.resetAssistant() }
                Button(L("menu.assistantResults")) {
                    delegate.showMainWindow()
                    delegate.model.work.showResults = true
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                PaneCommands(model: delegate.model, panes: delegate.model.panes)
                Divider()
                SwitchSessionMenuItems(model: delegate.model)
            }
        }
        // 设置窗口（应用菜单「设置…」，⌘,，设计 §16）。
        Settings {
            SettingsView(model: delegate.model, selectLanguage: { delegate.selectLanguage($0) })
                .uiScaleRoot()
        }
    }
}

/// 菜单「显示 → 改动的文件」（⇧⌘F）：开关详情区右侧的面板（设计 §17）。
private struct TouchedFilesMenuItem: View {
    @ObservedObject var files: TouchedFilesModel

    var body: some View {
        Toggle(L("menu.touchedFiles"), isOn: $files.isShown)
            .keyboardShortcut("f", modifiers: [.command, .shift])
    }
}

/// 菜单「Session → 对话模式」（⌥⌘V）；没有选中内嵌 session 时不可用。
private struct ConversationMenuItem: View {
    @ObservedObject var model: AppModel
    @ObservedObject var conversation: ConversationMode

    var body: some View {
        Toggle(L("menu.conversationMode"), isOn: Binding(
            get: { conversation.isOn },
            set: { _ in conversation.toggle() }))
            .keyboardShortcut("v", modifiers: [.command, .option])
    }
}
