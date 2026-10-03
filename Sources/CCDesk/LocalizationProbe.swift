import Foundation
import CCDeskCore

/// 隐藏的调试开关：`CCDESK_L10N_PROBE=1` 启动时打印当前语言与几条已知文案后立即退出，
/// 用来验证打包后的 .app 能找到资源包并按 `AppleLanguages` 选中语言。
enum LocalizationProbe {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["CCDESK_L10N_PROBE"] == "1" else { return }
        let lines = [
            "language=\(Localization.currentLanguage)",
            "mainBundleLocalizations=\(Bundle.main.preferredLocalizations.joined(separator: ","))",
            "appBundle=\(Localization.resourceBundle(named: "CCDesk_CCDesk")?.bundlePath ?? "missing")",
            "coreBundle=\(Localization.resourceBundle(named: "CCDesk_CCDeskCore")?.bundlePath ?? "missing")",
            "menu.newSession=\(L("menu.newSession"))",
            "status.waiting=\(AgentStatus.waiting(nil).label)",
            "time.minutes=\(RelativeTime.short(from: Date(timeIntervalSinceNow: -300), now: Date()))",
        ]
        print(lines.joined(separator: "\n"))
        fflush(stdout)
        exit(0)
    }
}
