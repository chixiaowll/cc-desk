import AppKit
import CCDeskCore

/// App 界面语言：跟随系统 / 简体中文 / English。写入本 App 域的 `AppleLanguages`，重启后生效。
enum LanguagePreference: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case en

    static let defaultsKey = "AppleLanguages"
    var id: String { rawValue }

    /// 语言名用各自的本地写法，不随界面语言变化。
    var label: String {
        switch self {
        case .system: return L("language.system")
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }

    /// 本 App 域里保存的选择（不读全局域，否则「跟随系统」无法区分）。
    static var stored: LanguagePreference {
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        guard let languages = UserDefaults.standard.persistentDomain(forName: domain)?[defaultsKey] as? [String],
              let first = languages.first else { return .system }
        return LanguagePreference(rawValue: Localization.resolveLanguage(preferences: [first])) ?? .system
    }

    func save() {
        switch self {
        case .system: UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        case .zhHans, .en: UserDefaults.standard.set([rawValue], forKey: Self.defaultsKey)
        }
        UserDefaults.standard.synchronize()
    }
}

extension AppDelegate {
    /// 菜单里选择语言：保存后询问是否立即重启。
    func selectLanguage(_ preference: LanguagePreference) {
        guard preference != LanguagePreference.stored else { return }
        preference.save()
        let alert = NSAlert()
        alert.messageText = L("alert.restart.title")
        alert.informativeText = L("alert.restart.message")
        alert.addButton(withTitle: L("action.restartNow"))
        alert.addButton(withTitle: L("action.later"))
        if alert.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    /// 重启：走正常退出流程（含运行中 session 的确认），确认后先启动新实例再退出。
    func relaunch() {
        relaunching = true
        NSApp.terminate(nil)
    }

    /// 在 applicationShouldTerminate 确认可以退出后调用：启动新实例，完成后再真正退出。
    func launchNewInstanceThenTerminate() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    self.relaunching = false
                    NSApp.reply(toApplicationShouldTerminate: false)
                    let alert = NSAlert()
                    alert.messageText = L("alert.restartFailed.title")
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                } else {
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
        }
    }
}
