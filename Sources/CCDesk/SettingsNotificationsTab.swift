import SwiftUI
import AppKit
import CCDeskCore

/// 设置 › 通知：系统通知权限、按事件开关、测试通知与角标，以及推送到手机。
struct SettingsNotificationsTab: View {
    let model: AppModel
    @AppStorage(NotificationPreferences.waitingKey) private var notifyWaiting = true
    @AppStorage(NotificationPreferences.finishedKey) private var notifyFinished = true
    @State private var authorization: Notifier.Authorization?

    var body: some View {
        SettingsForm {
            Section(L("settings.notify.system")) {
                LabeledContent(L("settings.notify.permission")) {
                    HStack(spacing: 8) {
                        permissionStatus
                        Button(L("action.openSystemSettings")) {
                            if let url = Notifier.systemSettingsURL { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                Toggle(L("settings.notify.onWaiting"), isOn: $notifyWaiting)
                Toggle(L("settings.notify.onFinished"), isOn: $notifyFinished)
                HStack {
                    Button(L("settings.notify.test")) { model.testNotificationAndBadge() }
                    Spacer()
                }
                SettingsNote(text: L("settings.notify.note"))
            }
            SettingsPushSection(push: model.push)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    @ViewBuilder private var permissionStatus: some View {
        switch authorization {
        case .allowed?: SettingsStatus(text: L("settings.notify.allowed"), tone: .success)
        case .denied?: SettingsStatus(text: L("settings.notify.denied"), tone: .warning)
        case .notDetermined?: SettingsStatus(text: L("settings.notify.notDetermined"), tone: .secondary)
        case .unavailable?: SettingsStatus(text: L("settings.notify.unavailable"), tone: .secondary)
        case nil: ProgressView().controlSize(.small)
        }
    }

    private func refresh() {
        model.notifier.authorization { authorization = $0 }
    }
}
