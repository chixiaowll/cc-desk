import SwiftUI
import AppKit
import CCDeskCore

/// 设置窗口的标签页；当前标签存在 UserDefaults，其他地方（菜单栏菜单等）可以直接打开某一页。
enum SettingsTab: String, CaseIterable {
    case general, voice, notifications, integrations, usage
    static let defaultsKey = "settingsTab"
}

/// 打开设置窗口（SwiftUI `Settings` scene，⌘,）。
enum SettingsOpener {
    static func open(_ tab: SettingsTab? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.defaultsKey) }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

/// 设置窗口（⌘,，设计 §16）：系统风格的工具栏标签页；每个控件都绑定原有的 UserDefaults 键 / 偏好对象，
/// 不另存一份。用纸色背景与陶土色强调，与主窗口一致。
struct SettingsView: View {
    let model: AppModel
    let selectLanguage: (LanguagePreference) -> Void
    @AppStorage(SettingsTab.defaultsKey) private var tab = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $tab) {
            SettingsGeneralTab(model: model, selectLanguage: selectLanguage)
                .tabItem { Label(L("settings.tab.general"), systemImage: "gearshape") }
                .tag(SettingsTab.general.rawValue)
            SettingsVoiceTab(model: model, voice: model.voice, conversation: model.conversation)
                .tabItem { Label(L("settings.tab.voice"), systemImage: "waveform") }
                .tag(SettingsTab.voice.rawValue)
            SettingsNotificationsTab(model: model)
                .tabItem { Label(L("settings.tab.notifications"), systemImage: "bell.badge") }
                .tag(SettingsTab.notifications.rawValue)
            SettingsIntegrationsTab(model: model)
                .tabItem { Label(L("settings.tab.integrations"), systemImage: "puzzlepiece.extension") }
                .tag(SettingsTab.integrations.rawValue)
            SettingsUsageTab(model: model)
                .tabItem { Label(L("settings.tab.usage"), systemImage: "chart.bar") }
                .tag(SettingsTab.usage.rawValue)
        }
        .frame(width: 600, height: 560)
    }
}

/// 设置 › 集成：直接复用 `IntegrationsList`。
private struct SettingsIntegrationsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsForm {
            Section {
                IntegrationsList(model: model)
                    .padding(.vertical, 4)
            }
        }
    }
}

// MARK: 共用样式

/// 设置页的表单：系统分组样式，纸色背景、陶土色强调。
struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var themes = ThemeStore.shared

    var body: some View {
        let theme = themes.theme(for: colorScheme)
        Form { content }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(theme.main)
            .tint(theme.accent)
    }
}

/// 控件下方的小字说明。
struct SettingsNote: View {
    let text: String
    var tone: Tone = .secondary

    enum Tone { case secondary, warning, success }

    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject private var themes = ThemeStore.shared

    var body: some View {
        let theme = themes.theme(for: colorScheme)
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color(theme))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func color(_ theme: Theme) -> Color {
        switch tone {
        case .secondary: return theme.fg3
        case .warning: return theme.accent
        case .success: return theme.unread
        }
    }
}

/// 状态文字（如「已下载」「未授权」），与集成页的状态色一致。
struct SettingsStatus: View {
    let text: String
    let tone: SettingsNote.Tone

    var body: some View {
        SettingsNote(text: text, tone: tone)
            .font(.system(size: 12))
    }
}
