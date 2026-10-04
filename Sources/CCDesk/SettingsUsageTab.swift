import SwiftUI
import CCDeskCore

/// 设置 › 用量：Claude 套餐与各项额度（复用侧栏的用量详情）、立即刷新、提醒阈值说明。
struct SettingsUsageTab: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var themes = ThemeStore.shared

    var body: some View {
        SettingsForm {
            Section(L("settings.usage.claude")) {
                if let usage = model.claudeUsage {
                    UsagePopover(usage: usage, now: model.now, theme: themes.theme(for: colorScheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    SettingsNote(text: L("settings.usage.none"))
                }
                HStack {
                    Button(L("settings.usage.refresh")) { model.refreshUsageNow() }
                    Spacer()
                }
                SettingsNote(text: L("settings.usage.alertNote", Int(UsageAlerts.threshold)))
            }
        }
        .onAppear { model.refreshUsageNow() }
    }
}
