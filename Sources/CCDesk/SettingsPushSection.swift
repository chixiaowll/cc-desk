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
    /// 输入框里的密钥；`saved` 是 Keychain 里的值，只有不同时才写回。
    @State private var draft = PushSecrets()
    @State private var saved = PushSecrets()
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
            if let saveError { SettingsNote(text: L("settings.push.saveFailed", saveError), tone: .warning) }
        } header: {
            Text(L("settings.push.title"))
        } footer: {
            SettingsNote(text: L("settings.push.privacy"))
        }
        .onAppear(perform: load)
        .onChange(of: draft) { _, _ in store() }
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
        let current = PushSecrets.load(push.secrets)
        saved = current
        draft = current
    }

    /// 输入框变化时把改动的那几项写进 Keychain（空白 = 删除）。
    private func store() {
        let pairs: [(PushSecretKey, String, String)] = [
            (.barkDeviceKey, draft.barkDeviceKey, saved.barkDeviceKey),
            (.ntfyTopic, draft.ntfyTopic, saved.ntfyTopic),
            (.ntfyToken, draft.ntfyToken, saved.ntfyToken),
            (.webhookURL, draft.webhookURL, saved.webhookURL),
        ]
        do {
            for (key, value, old) in pairs where value != old {
                try push.secrets.write(value, account: key.rawValue)
            }
            saved = draft
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
