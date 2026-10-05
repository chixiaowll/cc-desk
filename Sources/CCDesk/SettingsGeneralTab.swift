import SwiftUI
import CCDeskCore

/// 设置 › 通用：外观（明暗与浅色 / 深色主题、侧栏是否显示模型）、语言（沿用重启流程）、终端字体、登录时启动、菜单栏图标、全局快捷键。
struct SettingsGeneralTab: View {
    let model: AppModel
    let selectLanguage: (LanguagePreference) -> Void
    @AppStorage(AppearancePreference.defaultsKey) private var appearance = AppearancePreference.system.rawValue
    @AppStorage(SidebarModelPreference.defaultsKey) private var showModelInSidebar = true
    @State private var language = LanguagePreference.stored
    @ObservedObject private var preferences = DesktopPreferences.shared
    @ObservedObject private var loginItem = LoginItemController.shared
    @ObservedObject private var hotkeys = GlobalHotkeyCenter.shared
    @ObservedObject private var terminalFont = TerminalFontPreferences.shared
    /// 可选的等宽字体族与「自动」实际用的字体族（打开设置时扫描一次，装了新字体后重新打开即可看到）。
    @State private var fontFamilies: [String] = []
    @State private var autoFamily: String?

    var body: some View {
        SettingsForm {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Picker(L("settings.general.appearance"), selection: appearanceBinding) {
                        ForEach(AppearancePreference.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    SettingsNote(text: L("settings.general.claudeThemeNote"))
                }
                ThemePickerRow(title: L("settings.general.lightTheme"), kind: .light)
                ThemePickerRow(title: L("settings.general.darkTheme"), kind: .dark)
                Toggle(L("settings.general.showModelInSidebar"), isOn: $showModelInSidebar)
                VStack(alignment: .leading, spacing: 4) {
                    Picker(L("settings.general.language"), selection: languageBinding) {
                        ForEach(LanguagePreference.allCases) { Text($0.label).tag($0) }
                    }
                    SettingsNote(text: L("settings.general.languageNote"))
                }
            }
            Section(L("settings.general.terminal")) {
                Picker(L("settings.general.terminalFont"), selection: $terminalFont.family) {
                    Text(L("settings.general.terminalFont.auto", autoFamily ?? "SF Mono")).tag("")
                    Divider()
                    ForEach(fontFamilies, id: \.self) { Text($0).tag($0) }
                    // 选过的字体已卸载：仍显示在列表里，实际按「自动」处理。
                    if !terminalFont.family.isEmpty, !fontFamilies.contains(terminalFont.family) {
                        Text(terminalFont.family).tag(terminalFont.family)
                    }
                }
                Picker(L("settings.general.terminalFontSize"), selection: $terminalFont.size) {
                    ForEach(Array(stride(from: TerminalFontChoice.sizeRange.lowerBound,
                                         through: TerminalFontChoice.sizeRange.upperBound, by: 1)), id: \.self) { size in
                        Text("\(Int(size)) pt").tag(size)
                    }
                }
                if autoFamily == nil {
                    SettingsNote(text: L("settings.general.terminalFont.installHint", TerminalFontChoice.installHint))
                        .textSelection(.enabled)
                } else {
                    SettingsNote(text: L("settings.general.terminalFontNote"))
                }
            }
            Section(L("settings.general.desktop")) {
                // toggle 可能弹出说明框：不在绑定的 setter 里直接运行模态框。
                Toggle(isOn: Binding(get: { loginItem.state.isOn },
                                     set: { _ in DispatchQueue.main.async { loginItem.toggle() } })) {
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
            fontFamilies = TerminalFont.pickableFamilies()
            autoFamily = TerminalFontChoice.autoFamily(installed: TerminalFont.installedFamilies())
        }
        .onChange(of: terminalFont.family) { _, _ in model.pool.applyFont() }
        .onChange(of: terminalFont.size) { _, _ in model.pool.applyFont() }
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
            // 「是否立即重启」的模态框放到下一轮主循环，不在绑定的 setter 里运行。
            DispatchQueue.main.async {
                selectLanguage(pref)
                language = LanguagePreference.stored
            }
        })
    }
}
