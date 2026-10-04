import SwiftUI
import CCDeskCore

/// 设置 › 通知 › 推送到手机：服务（Bark / ntfy / Webhook）、密钥（存 Keychain）、推送哪些事件、什么时候推送、测试推送。
/// 普通设置走 UserDefaults（键在 `PushSettings`），由 PhonePushCenter 每次推送时读取。
struct SettingsPushSection: View {
    let push: PhonePushCenter
    @AppStorage(PushSettings.providerKey) private var provider = PushProvider.none.rawValue
    @AppStorage(PushSettings.barkServerKey) private var barkServer = PushSettings.defaultBarkServer
    @AppStorage(PushSettings.ntfyServerKey) private var ntfyServer = PushSettings.defaultNtfyServer
    @AppStorage(PushSettings.onWaitingKey) private var onWaiting = true
    @AppStorage(PushSettings.onFinishedKey) private var onFinished = false
    @AppStorage(PushSettings.conditionKey) private var condition = PushCondition.whenAway.rawValue
    @AppStorage(PushSettings.includeReasonKey) private var includeReason = true
    /// 输入框里的密钥；停止输入 0.5 秒后（以及离开设置页、发送测试时）只把变了的项写回 Keychain。
    @State private var draft = PushSecrets()
    @State private var saveError: String?
    @State private var testing = false
    @State private var result: PhonePushCenter.Outcome?

    private var selected: PushProvider { PushProvider(rawValue: provider) ?? .none }

    var body: some View {
        Section {
            Picker(L("settings.push.provider"), selection: $provider) {
                ForEach(PushProvider.allCases) { Text(Self.label($0)).tag($0.rawValue) }
            }
            switch selected {
            case .none:
                EmptyView()
            case .bark:
                serverField($barkServer, placeholder: PushSettings.defaultBarkServer)
                LabeledContent(L("settings.push.bark.key")) {
                    SecureField("", text: $draft.barkDeviceKey).textFieldStyle(.roundedBorder).frame(width: 260)
                }
                SettingsNote(text: L("settings.push.bark.note"))
            case .ntfy:
                serverField($ntfyServer, placeholder: PushSettings.defaultNtfyServer)
                LabeledContent(L("settings.push.ntfy.topic")) {
                    TextField("", text: $draft.ntfyTopic).textFieldStyle(.roundedBorder).frame(width: 260)
                }
                LabeledContent(L("settings.push.ntfy.token")) {
                    SecureField("", text: $draft.ntfyToken, prompt: Text(L("settings.push.optional")))
                        .textFieldStyle(.roundedBorder).frame(width: 260)
                }
                SettingsNote(text: L("settings.push.ntfy.note"))
            case .webhook:
                LabeledContent(L("settings.push.webhook.url")) {
                    TextField("", text: $draft.webhookURL, prompt: Text(verbatim: "https://"))
                        .textFieldStyle(.roundedBorder).frame(width: 300)
                }
                SettingsNote(text: L("settings.push.webhook.note"))
            }
            if selected != .none {
                Toggle(L("settings.push.onWaiting"), isOn: $onWaiting)
                Toggle(L("settings.push.onFinished"), isOn: $onFinished)
                Toggle(L("settings.push.includeReason"), isOn: $includeReason)
                Picker(L("settings.push.when"), selection: $condition) {
                    Text(L("settings.push.when.away")).tag(PushCondition.whenAway.rawValue)
                    Text(L("settings.push.when.always")).tag(PushCondition.always.rawValue)
                }
                SettingsNote(text: L("settings.push.limitNote"))
                HStack(spacing: 8) {
                    Button(L("settings.push.test"), action: sendTest).disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    resultView
                    Spacer()
                }
            }
            if currentSettings.sendsSecretInPlaintext(draft) {
                SettingsNote(text: L("settings.push.insecureWarning"), tone: .warning)
            }
            if let saveError { SettingsNote(text: L("settings.push.saveFailed", saveError), tone: .warning) }
        } header: {
            Text(L("settings.push.title"))
        } footer: {
            SettingsNote(text: L("settings.push.privacy"))
        }
        .onAppear(perform: load)
        .onDisappear(perform: store)
        .task(id: draft) {
            // 每次按键都写 Keychain 太频繁：停下来 0.5 秒再写。
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !Task.isCancelled { store() }
        }
    }

    /// 当前界面上的推送设置（判断是否要提醒明文发送密钥）。
    private var currentSettings: PushSettings {
        PushSettings(provider: selected, barkServer: barkServer, ntfyServer: ntfyServer)
    }

    private func serverField(_ text: Binding<String>, placeholder: String) -> some View {
        LabeledContent(L("settings.push.server")) {
            TextField("", text: text, prompt: Text(verbatim: placeholder)).textFieldStyle(.roundedBorder).frame(width: 260)
        }
    }

    @ViewBuilder private var resultView: some View {
        switch result {
        case .sent(let code)?: SettingsStatus(text: L("settings.push.sent", code), tone: .success)
        case .failed(let reason)?: SettingsStatus(text: reason, tone: .warning)
        case nil: EmptyView()
        }
    }

    private static func label(_ provider: PushProvider) -> String {
        switch provider {
        case .none: return L("settings.push.provider.none")
        case .bark: return "Bark (iOS)"
        case .ntfy: return "ntfy"
        case .webhook: return L("settings.push.provider.webhook")
        }
    }

    private func load() {
        draft = push.reloadSecrets()
    }

    /// 把改动的那几项写进 Keychain（空白 = 删除）；没有改动时什么都不做。
    private func store() {
        guard draft != push.secrets else { return }
        do {
            try push.saveSecrets(draft)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
        result = nil
    }

    private func sendTest() {
        store()
        testing = true
        result = nil
        push.sendTest { outcome in
            testing = false
            result = outcome
        }
    }
}
