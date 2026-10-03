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
        pool?.apply(TerminalTheme.of(NSApp.effectiveAppearance))
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
        AppearancePreference.stored.apply(pool: model.pool)
        model.start()
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
        model.conversation.turnOff()
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
/// `--tmux-selftest` 时在隔离的 tmux 服务器上自检会话托管层后退出（设计 §4.9）；
/// 否则启动 App。
@main
enum CCDeskMain {
    static func main() {
        // 子进程（助手会话 / 语音服务 / MCP）退出后再写它的管道会触发 SIGPIPE，默认会终止整个 App；
        // 忽略后写入只会返回错误，由调用方处理。
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.dropFirst().contains("--mcp") { MCPMode.run() }
        NaturalSpeechTest.runIfRequested()
        TmuxSelfTest.runIfRequested()
        CCDeskApp.main()
    }
}

struct CCDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(AppearancePreference.defaultsKey) private var appearance: String = AppearancePreference.system.rawValue
    @State private var language = LanguagePreference.stored

    var body: some Scene {
        Window("CC Desk", id: "main") {
            ContentView(model: delegate.model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("menu.newSession")) {
                    delegate.model.openMainWindow?()
                    delegate.model.showNewSession = true
                }
                .keyboardShortcut("n")
            }
            // `Window` scene 不像 WindowGroup 那样自带系统 "Close"（⌘W）菜单项，所以这里用
            // `after:` 新增而非 `replacing:` 某个占位组，确保有且只有一个 ⌘W 绑定。
            // 选中内嵌 session 时关闭该 session（沿用原有确认逻辑）；否则按标准行为关闭窗口本身。
            CommandGroup(after: .newItem) {
                Button(L("menu.closeSession")) {
                    if let row = delegate.model.selectedRow, row.session.host.isEmbedded {
                        delegate.model.closeSelected()
                    } else {
                        NSApp.keyWindow?.performClose(nil)
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
                    delegate.model.openMainWindow?()
                    delegate.model.showHistoryPalette = true
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
                Section(L("menu.appearance")) {
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
                Section(L("menu.language")) {
                    ForEach(LanguagePreference.allCases) { pref in
                        Toggle(pref.label, isOn: Binding(
                            get: { language == pref },
                            set: { on in
                                guard on else { return }
                                language = pref
                                delegate.selectLanguage(pref)
                            }))
                    }
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button(L("menu.integrations")) {
                    delegate.model.openMainWindow?()
                    delegate.model.showIntegrations = true
                }
                .keyboardShortcut(",")
                Divider()
                DesktopMenuItems()
            }
            CommandMenu(L("menu.session")) {
                Button(L("menu.installIntegrations")) {
                    delegate.model.openMainWindow?()
                    delegate.model.showIntegrations = true
                }
                Divider()
                Button(L("menu.testNotification")) { delegate.model.testNotificationAndBadge() }
                Button(L("menu.downloadVoiceModel")) {
                    delegate.model.openMainWindow?()
                    delegate.model.voice.predownload()
                }
                ConversationMenuItem(model: delegate.model, conversation: delegate.model.conversation)
                TurnSummaryMenuItem()
                PersistentConversationMenuItem()
                AutoStartConversationMenuItem()
                Button(L("menu.resetAssistant")) { delegate.model.conversation.resetAssistant() }
                SpeechVoiceMenu(model: delegate.model, conversation: delegate.model.conversation)
                Divider()
                ForEach(1...9, id: \.self) { index in
                    Button(L("menu.switchTo", index)) { delegate.model.selectEmbedded(index: index - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                }
            }
        }
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

/// 菜单「Session → 回复摘要」：对话模式下一轮完成时播报摘要而不是「已完成」（占用 Claude 订阅额度）。
private struct TurnSummaryMenuItem: View {
    @AppStorage(ConversationMode.summariesDefaultsKey) private var on = true

    var body: some View {
        Toggle(L("menu.turnSummaries"), isOn: $on)
    }
}

/// 菜单「Session → 启动时开启助手」。
private struct AutoStartConversationMenuItem: View {
    @AppStorage(ConversationMode.autoStartDefaultsKey) private var on = false

    var body: some View {
        Toggle(L("menu.autoStartConversation"), isOn: $on)
    }
}

/// 菜单「Session → 常驻对话」：唤醒后一直在线，不因沉默或发送而回到待命。
private struct PersistentConversationMenuItem: View {
    @AppStorage(ConversationMode.persistentDefaultsKey) private var on = true

    var body: some View {
        Toggle(L("menu.persistentConversation"), isOn: $on)
    }
}

/// 菜单「Session → 朗读声音」：自然语音（本机 Qwen3-TTS，没装时先询问安装）、自动（音质最好的系统声音）
/// 或指定一个已安装的系统声音；可跳到系统设置下载更多声音。
private struct SpeechVoiceMenu: View {
    let model: AppModel
    @ObservedObject var conversation: ConversationMode
    @ObservedObject private var installer = NaturalVoiceInstaller.shared
    @AppStorage(SpeechVoiceRanking.defaultsKey) private var chosen = ""

    var body: some View {
        Menu(L("menu.speechVoice")) {
            Toggle(installer.installing ? L("menu.speechVoice.naturalInstalling") : L("menu.speechVoice.natural"),
                   isOn: naturalBinding)
                .disabled(installer.installing)
            Toggle(L("menu.speechVoice.auto"), isOn: binding(""))
            Divider()
            ForEach(SpeechVoices.candidates(), id: \.identifier) { voice in
                Toggle(SpeechVoices.label(voice), isOn: binding(voice.identifier))
            }
            Divider()
            Button(L("menu.speechVoice.download")) {
                if let url = SpeechVoices.spokenContentSettingsURL { NSWorkspace.shared.open(url) }
            }
        }
    }

    /// `chosen` 只用来让菜单随偏好刷新；是否选中自然语音以 NaturalVoice.isSelected 为准（装好且没选过 = 默认）。
    private var naturalBinding: Binding<Bool> {
        Binding(get: { _ = chosen; return NaturalVoice.isSelected }, set: { on in
            guard on else { return }
            guard NaturalVoice.isInstalled else {
                NaturalVoiceInstaller.shared.confirmAndInstall(hint: { model.voice.showHint($0) }) { ok in
                    guard ok else { return }
                    chosen = NaturalVoiceProtocol.preferenceID
                    if !conversation.isOn { SpeechVoices.preview() }
                }
                return
            }
            chosen = NaturalVoiceProtocol.preferenceID
            if !conversation.isOn { SpeechVoices.preview() }
        })
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { chosen == id && !NaturalVoice.isSelected }, set: { on in
            guard on else { return }
            chosen = id
            if !conversation.isOn { SpeechVoices.preview() }
        })
    }
}
