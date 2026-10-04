import SwiftUI
import CCDeskCore

/// 设置 › 语音 › 助手模型（设计 §22）：自动 / Claude Code / 通用 API / 仅本地规则；通用 API 的服务、地址、模型（可从
/// /models 选）、顾问模型、密钥（钥匙串，停止输入 0.5 秒后保存）与「测试连接」。改动停下 0.5 秒后通知助手换后端，
/// 下一句话起生效。
struct SettingsAssistantSection: View {
    @ObservedObject var conversation: ConversationMode
    @AppStorage(AssistantBackendChoice.defaultsKey) private var choice = AssistantBackendChoice.auto.rawValue
    @AppStorage(AssistantAPISettings.presetKey) private var preset = AssistantAPIPreset.deepseek.rawValue
    @AppStorage(AssistantAPISettings.baseURLKey) private var baseURL = AssistantAPIPreset.deepseek.baseURL
    @AppStorage(AssistantAPISettings.modelKey) private var apiModel = ""
    @AppStorage(AssistantAPISettings.consultModelKey) private var consultModel = ""
    @State private var keyDraft = ""
    /// keyDraft 属于哪个服务（换服务时先读出那个服务的密钥，不能把输入框里的旧密钥存到新服务下）。
    @State private var keyPreset: AssistantAPIPreset?
    @State private var keyError: String?
    @State private var models: [String] = []
    @State private var fetching = false
    @State private var fetchNote: String?
    @State private var testing = false
    @State private var testResult: (AssistantAPIProbe.Result, TimeInterval)?
    @State private var activeLabel = ""
    @State private var claudeMissing = false

    private var client: AssistantClient { .shared }
    private var selectedChoice: AssistantBackendChoice { AssistantBackendChoice(stored: choice) }
    private var selectedPreset: AssistantAPIPreset { AssistantAPIPreset(rawValue: preset) ?? .deepseek }
    private var draftSettings: AssistantAPISettings {
        AssistantAPISettings(preset: selectedPreset, baseURL: baseURL, model: apiModel, consultModel: consultModel)
    }
    private var hasKey: Bool { !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// 任何一项变了都重新保存 / 通知（去抖）。
    private var configID: String { [choice, preset, baseURL, apiModel, consultModel, keyDraft].joined(separator: "\u{1}") }

    var body: some View {
        Group {
            choiceSection
            if selectedChoice == .auto || selectedChoice == .api { apiSection }
        }
        .onAppear(perform: load)
        .onDisappear(perform: store)
        .onChange(of: preset) { _, new in presetChanged(new) }
        .task(id: configID) {
            // 每次按键都写钥匙串 / 换后端太频繁：停下来 0.5 秒再做。
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !Task.isCancelled { store() }
        }
    }

    private var choiceSection: some View {
        Section {
            Picker(L("settings.assistant.choice"), selection: $choice) {
                Text(L("settings.assistant.choice.auto")).tag(AssistantBackendChoice.auto.rawValue)
                Text(verbatim: "Claude Code").tag(AssistantBackendChoice.claude.rawValue)
                Text(L("settings.assistant.choice.api")).tag(AssistantBackendChoice.api.rawValue)
                Text(L("settings.assistant.choice.local")).tag(AssistantBackendChoice.local.rawValue)
            }
            LabeledContent(L("settings.assistant.active")) {
                SettingsStatus(text: activeLabel, tone: activeLabel == L("assistant.backend.local") ? .secondary : .success)
            }
            SettingsNote(text: choiceNote)
            if claudeMissing, selectedChoice == .claude {
                SettingsNote(text: L("settings.assistant.claudeMissing"), tone: .warning)
            }
            if selectedChoice == .api, !draftSettings.isConfigured(hasKey: hasKey) {
                SettingsNote(text: L("settings.assistant.apiMissing"), tone: .warning)
            }
        } header: {
            Text(L("settings.assistant.title"))
        }
    }

    private var choiceNote: String {
        switch selectedChoice {
        case .auto: return L("settings.assistant.note.auto")
        case .claude: return L("settings.assistant.note.claude")
        case .api: return L("settings.assistant.note.api")
        case .local: return L("settings.assistant.note.local")
        }
    }

    // MARK: 通用 API

    private var apiSection: some View {
        Section {
            Picker(L("settings.assistant.preset"), selection: $preset) {
                ForEach(AssistantAPIPreset.allCases, id: \.rawValue) { item in
                    Text(item == .custom ? L("settings.assistant.preset.custom") : item.displayName).tag(item.rawValue)
                }
            }
            LabeledContent(L("settings.assistant.baseURL")) {
                TextField("", text: $baseURL, prompt: Text(verbatim: "https://…/v1"))
                    .textFieldStyle(.roundedBorder).frame(width: 300)
            }
            LabeledContent(L("settings.assistant.model")) {
                HStack(spacing: 6) {
                    TextField("", text: $apiModel, prompt: Text(verbatim: selectedPreset.modelPlaceholder))
                        .textFieldStyle(.roundedBorder).frame(width: 190)
                    modelMenu
                }
            }
            if let fetchNote { SettingsNote(text: fetchNote) }
            LabeledContent(L("settings.assistant.consultModel")) {
                TextField("", text: $consultModel, prompt: Text(L("settings.assistant.consultModel.placeholder")))
                    .textFieldStyle(.roundedBorder).frame(width: 300)
            }
            if selectedPreset.isLocal {
                SettingsNote(text: L("settings.assistant.localNote"))
            } else {
                LabeledContent(L("settings.assistant.key")) {
                    SecureField("", text: $keyDraft,
                                prompt: selectedPreset.requiresKey ? nil : Text(L("settings.push.optional")))
                        .textFieldStyle(.roundedBorder).frame(width: 300)
                }
                SettingsNote(text: L("settings.assistant.key.note"))
            }
            if draftSettings.sendsKeyInPlaintext(hasKey: hasKey && !selectedPreset.isLocal) {
                SettingsNote(text: L("settings.assistant.plaintext"), tone: .warning)
            }
            if let keyError { SettingsNote(text: L("settings.assistant.key.saveFailed", keyError), tone: .warning) }
            HStack(spacing: 8) {
                Button(L("settings.assistant.test"), action: test)
                    .disabled(testing || draftSettings.endpoint == nil || draftSettings.trimmedModel.isEmpty)
                if testing { ProgressView().controlSize(.small) }
                testView
                Spacer()
            }
            SettingsNote(text: L("settings.assistant.recommend"))
        } header: {
            Text(L("settings.assistant.api"))
        } footer: {
            SettingsNote(text: L("settings.assistant.privacy"))
        }
    }

    /// 「选择」菜单：/models 的结果；第一项是重新获取。
    private var modelMenu: some View {
        Menu {
            Button(L("settings.assistant.fetchModels"), action: fetchModels)
            if !models.isEmpty { Divider() }
            ForEach(models, id: \.self) { name in
                Button(name) { apiModel = name }
            }
        } label: {
            if fetching { ProgressView().controlSize(.small) } else { Text(L("settings.assistant.models")) }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(draftSettings.endpoint == nil)
    }

    @ViewBuilder private var testView: some View {
        if let testResult {
            let seconds = String(format: "%.1f", testResult.1)
            switch testResult.0 {
            case .ok(true, _): SettingsStatus(text: L("settings.assistant.test.toolsOK", seconds), tone: .success)
            case .ok(false, _): SettingsStatus(text: L("settings.assistant.test.noTools", seconds), tone: .warning)
            case .failed(let error): SettingsStatus(text: L("settings.assistant.test.failed", Self.describe(error)), tone: .warning)
            }
        }
    }

    // MARK: 动作

    private func load() {
        client.apiKeys.reload()
        keyPreset = selectedPreset
        keyDraft = client.apiKeys.key(for: selectedPreset)
        refreshActive()
        // 选了自动 / Claude Code 时确认一下 claude 在不在（第一次会走一次登录 shell，后台进行）。
        if AssistantBackendSelector.needsClaude(selectedChoice) {
            client.prepare { _ in refreshActive() }
        }
    }

    /// 换服务：地址换成预设地址（自定义保留），密钥换成那个服务的，清掉旧的模型列表与测试结果。
    private func presetChanged(_ raw: String) {
        let new = AssistantAPIPreset(rawValue: raw) ?? .deepseek
        store()
        if new != .custom { baseURL = new.baseURL }
        keyPreset = new
        keyDraft = client.apiKeys.key(for: new)
        models = []
        fetchNote = nil
        testResult = nil
    }

    /// 保存密钥（只存到它所属的服务下），通知助手重新选后端。
    private func store() {
        if let owner = keyPreset, !owner.isLocal {
            do {
                try client.apiKeys.save(keyDraft, for: owner)
                keyError = nil
            } catch {
                keyError = error.localizedDescription
            }
        }
        conversation.assistantBackendChanged()
        refreshActive()
    }

    private func refreshActive() {
        activeLabel = client.activeLabel
        claudeMissing = client.isAvailable == false
    }

    private func fetchModels() {
        guard let base = draftSettings.endpoint else { return }
        fetching = true
        fetchNote = nil
        ChatHTTPClient.shared.fetchModels(base: base, apiKey: hasKey ? keyDraft : nil) { result in
            fetching = false
            switch result {
            case .success(let list):
                models = list
                fetchNote = L("settings.assistant.models.count", list.count)
            case .failure(let error):
                models = []
                fetchNote = L("settings.assistant.models.failed", Self.describe(error))
            }
        }
    }

    private func test() {
        guard let base = draftSettings.endpoint else { return }
        store()
        testing = true
        testResult = nil
        let key = selectedPreset.isLocal || !hasKey ? nil : keyDraft
        ChatHTTPClient.shared.probe(base: base, apiKey: key, model: draftSettings.trimmedModel) { result, latency in
            testing = false
            testResult = (result, latency)
        }
    }

    /// 错误说明：状态码 / 网络错误，加上服务端给的一句原因（如「Invalid API key」）。
    static func describe(_ error: ChatAPIError) -> String {
        switch error {
        case .http(let code, let detail?): return "HTTP \(code) · \(detail)"
        case .provider(let detail): return detail
        default: return error.short
        }
    }
}
