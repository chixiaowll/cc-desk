import SwiftUI
import CCDeskCore

/// 设置 › 语音 › 通用助手（设计 §24）：开关、模型（通用 API 时可另填）、允许上网、人设（名字 / 性格 / 人设描述 /
/// 怎么称呼我）、清空记忆。人设与上网开关停下 0.6 秒后通知 CompanionWork（Claude 进程用新提示词重启，记忆不丢），
/// 下一问起生效。
struct SettingsCompanionSection: View {
    let companion: CompanionWork
    @AppStorage(CompanionPreferences.enabledKey) private var enabled = true
    @AppStorage(CompanionPreferences.webKey) private var web = true
    @AppStorage(AssistantAPISettings.companionModelKey) private var apiModel = ""
    @State private var persona = CompanionPersona.load()
    @State private var engine: CompanionEngine = .unavailable(.resolving)
    @State private var confirmClear = false
    @State private var cleared = false
    /// 上次保存 / 读出时的 configID（打开设置页本身不算改动）。
    @State private var savedID: String?

    private var language: String { Localization.currentLanguage }
    /// 人设或上网开关变了都通知（去抖）。
    private var configID: String {
        [persona.name, persona.preset.rawValue, persona.customText, persona.address, String(web)].joined(separator: "\u{1}")
    }

    var body: some View {
        Section {
            Toggle(L("settings.companion.enabled"), isOn: $enabled)
            LabeledContent(L("settings.companion.model")) {
                SettingsStatus(text: engineLabel, tone: engine.model == nil ? .secondary : .success)
            }
            if case .api = engine {
                LabeledContent(L("settings.companion.apiModel")) {
                    TextField("", text: $apiModel, prompt: Text(L("settings.companion.apiModel.placeholder")))
                        .textFieldStyle(.roundedBorder).frame(width: 240)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle(L("settings.companion.web"), isOn: $web)
                SettingsNote(text: L("settings.companion.web.note"))
            }
            personaFields
            HStack {
                Button(L("settings.companion.clear")) { confirmClear = true }
                if cleared { SettingsStatus(text: L("settings.companion.cleared"), tone: .success) }
                Spacer()
            }
        } header: {
            Text(L("settings.companion.title"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                SettingsNote(text: L("settings.companion.note"))
                SettingsNote(text: L("settings.companion.privacy"))
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: enabled) { _, _ in engine = companion.engine }
        .onChange(of: apiModel) { _, _ in engine = companion.engine }
        .task(id: configID) {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, configID != savedID else { return }
            savedID = configID
            persona.save()
            companion.settingsChanged()
        }
        .confirmationDialog(L("settings.companion.clear.confirm", companion.name), isPresented: $confirmClear) {
            Button(L("settings.companion.clear"), role: .destructive) {
                companion.clearMemory()
                cleared = true
            }
        } message: {
            Text(L("settings.companion.clear.message"))
        }
    }

    @ViewBuilder private var personaFields: some View {
        LabeledContent(L("settings.companion.name")) {
            TextField("", text: $persona.name, prompt: Text(CompanionPersona.defaultName(language: language)))
                .textFieldStyle(.roundedBorder).frame(width: 160)
        }
        Picker(L("settings.companion.preset"), selection: presetBinding) {
            Text(L("settings.companion.preset.warm")).tag(CompanionPersonaPreset.warm)
            Text(L("settings.companion.preset.witty")).tag(CompanionPersonaPreset.witty)
            Text(L("settings.companion.preset.crisp")).tag(CompanionPersonaPreset.crisp)
            Text(L("settings.companion.preset.custom")).tag(CompanionPersonaPreset.custom)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(L("settings.companion.description"))
            TextEditor(text: descriptionBinding)
                .uiFont(size: 12)
                .frame(minHeight: 84, maxHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            SettingsNote(text: L("settings.companion.description.note"))
        }
        LabeledContent(L("settings.companion.address")) {
            TextField("", text: $persona.address, prompt: Text(L("settings.companion.address.placeholder")))
                .textFieldStyle(.roundedBorder).frame(width: 160)
        }
    }

    private var presetBinding: Binding<CompanionPersonaPreset> {
        Binding(get: { persona.preset }, set: { persona = persona.choosing($0, language: language) })
    }

    /// 描述框：显示当前人设的描述；改了文字就变成自定义（与某个预设一模一样时回到那个预设）。
    private var descriptionBinding: Binding<String> {
        Binding(get: { persona.preset == .custom ? persona.customText : persona.description(language: language) },
                set: { text in
                    guard text != persona.description(language: language) || persona.preset == .custom else { return }
                    persona = persona.editing(text: text, language: language)
                })
    }

    private var engineLabel: String {
        switch engine {
        case .claude: return "Claude Code · Sonnet"
        case .api(let model): return L("settings.companion.model.api", model)
        case .unavailable(.disabled): return L("settings.companion.model.off")
        case .unavailable(.localOnly): return L("settings.companion.model.local")
        case .unavailable(.resolving): return L("assistant.backend.resolving")
        }
    }

    private func refresh() {
        engine = companion.engine
        persona = CompanionPersona.load()
        savedID = configID
    }
}
