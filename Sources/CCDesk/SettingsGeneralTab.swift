import SwiftUI
import CCDeskCore

/// 设置 › 通用：外观、语言（沿用重启流程）、登录时启动、菜单栏图标、全局快捷键。
struct SettingsGeneralTab: View {
    let model: AppModel
    let selectLanguage: (LanguagePreference) -> Void
    @AppStorage(AppearancePreference.defaultsKey) private var appearance = AppearancePreference.system.rawValue
    @State private var language = LanguagePreference.stored
    @ObservedObject private var preferences = DesktopPreferences.shared
    @ObservedObject private var loginItem = LoginItemController.shared
    @ObservedObject private var hotkeys = GlobalHotkeyCenter.shared

    var body: some View {
        SettingsForm {
            Section {
                Picker(L("settings.general.appearance"), selection: appearanceBinding) {
                    ForEach(AppearancePreference.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 4) {
                    Picker(L("settings.general.language"), selection: languageBinding) {
                        ForEach(LanguagePreference.allCases) { Text($0.label).tag($0) }
                    }
                    SettingsNote(text: L("settings.general.languageNote"))
                }
            }
            Section(L("settings.general.desktop")) {
                Toggle(isOn: Binding(get: { loginItem.state.isOn }, set: { _ in loginItem.toggle() })) {
                    Text(loginItem.state.needsApprovalHint ? L("menu.launchAtLogin.needsApproval") : L("menu.launchAtLogin"))
                }
                Toggle(L("menu.showMenuBarIcon"), isOn: $preferences.menuBarIconShown)
            }
            Section(L("settings.general.hotkeys")) {
                Toggle(L("menu.globalHotkeys"), isOn: $preferences.globalHotkeysEnabled)
                hotkeyRow(.toggleMainWindow, L("settings.general.hotkey.main"))
                hotkeyRow(.toggleConversation, L("settings.general.hotkey.conversation"))
                ForEach(hotkeys.unavailable) { hotkey in
                    SettingsNote(text: L("hotkey.unavailable", hotkey.displayString), tone: .warning)
                }
                SettingsNote(text: L("settings.general.hotkeysNote"))
            }
        }
        .onAppear {
            loginItem.refresh()
            language = LanguagePreference.stored
        }
    }

    private func hotkeyRow(_ action: GlobalHotkey.Action, _ title: String) -> some View {
        LabeledContent(title) {
            Text(GlobalHotkey.default(for: action)?.displayString ?? "")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(preferences.globalHotkeysEnabled ? .primary : .tertiary)
        }
    }

    private var appearanceBinding: Binding<AppearancePreference> {
        Binding(get: { AppearancePreference(rawValue: appearance) ?? .system }, set: { pref in
            appearance = pref.rawValue
            pref.apply(pool: model.pool)
        })
    }

    /// 选择后走原来的「保存 → 询问是否立即重启」流程；选「稍后」时保持新选择（重启后生效）。
    private var languageBinding: Binding<LanguagePreference> {
        Binding(get: { language }, set: { pref in
            language = pref
            selectLanguage(pref)
            language = LanguagePreference.stored
        })
    }
}
