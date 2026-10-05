import SwiftUI
import CCDeskCore

/// 设置 › 语音：按住说话、Whisper 模型、对话模式默认值、唤醒词、回复摘要、朗读声音、重置助手。
/// 对话模式的偏好在开启 / 唤醒时读取（ConversationMode），所以这里改动后从下次开启对话模式起生效。
struct SettingsVoiceTab: View {
    let model: AppModel
    @ObservedObject var voice: VoiceInput
    @ObservedObject var conversation: ConversationMode
    @ObservedObject private var installer = NaturalVoiceInstaller.shared
    @AppStorage(ConversationMode.autoStartDefaultsKey) private var autoStart = false
    @AppStorage(ConversationMode.persistentDefaultsKey) private var persistent = true
    @AppStorage(ConversationMode.summariesDefaultsKey) private var summaries = true
    @AppStorage(SpeechVoiceRanking.defaultsKey) private var chosen = ""
    @AppStorage(ConversationSession.wakeWordDefaultsKey) private var storedWakeWord = ""
    @State private var wakeWordDraft = ConversationMode.storedWakeWord
    /// 可选的系统声音；打开页面时读一次（枚举系统声音较慢，不在每次重绘时做）。
    @State private var candidates: [SpeechVoiceInfo] = []

    var body: some View {
        SettingsForm {
            Section(L("settings.voice.input")) {
                LabeledContent(L("settings.voice.pushToTalk")) {
                    Text(L("settings.voice.pushToTalk.key")).font(.system(size: 12, design: .monospaced))
                }
                SettingsNote(text: L("settings.voice.pushToTalk.note"))
                LabeledContent(L("settings.voice.model")) { modelStatus }
            }
            Section(L("settings.voice.conversation")) {
                Toggle(L("settings.voice.autoStart"), isOn: $autoStart)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(L("settings.voice.persistent"), isOn: $persistent)
                    SettingsNote(text: L("settings.voice.persistent.note"))
                }
                wakeWordRow
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(L("settings.voice.summaries"), isOn: $summaries)
                    SettingsNote(text: L("settings.voice.summaries.note"))
                }
            }
            Section(L("settings.voice.speech")) {
                Picker(L("settings.voice.speechVoice"), selection: voiceSelection) {
                    Text(L("settings.voice.speech.natural")).tag(NaturalVoiceProtocol.preferenceID)
                    Text(L("settings.voice.speech.auto")).tag("")
                    Divider()
                    ForEach(candidates, id: \.identifier) { Text(SpeechVoices.label($0)).tag($0.identifier) }
                }
                LabeledContent(L("settings.voice.speech.naturalStatus")) { naturalStatus }
                HStack {
                    Button(L("settings.voice.speech.preview")) { SpeechVoices.preview() }
                        .disabled(conversation.isOn)
                        .help(conversation.isOn ? L("settings.voice.speech.previewDisabled") : "")
                    Button(L("settings.voice.speech.download")) {
                        if let url = SpeechVoices.spokenContentSettingsURL { NSWorkspace.shared.open(url) }
                    }
                }
            }
            SettingsAssistantSection(conversation: conversation)
            SettingsCompanionSection(companion: model.companion)
            Section(L("settings.voice.assistant")) {
                HStack {
                    Button(L("settings.voice.resetAssistant")) { conversation.resetAssistant() }
                    Spacer()
                }
                SettingsNote(text: L("settings.voice.resetAssistant.note"))
            }
        }
        .onAppear { candidates = SpeechVoices.candidates() }
    }

    // MARK: Whisper 模型

    @ViewBuilder private var modelStatus: some View {
        HStack(spacing: 8) {
            switch voice.preparing {
            case .downloading(let fraction)?:
                ProgressView(value: fraction).frame(width: 90)
                SettingsStatus(text: L("settings.voice.model.downloading", Int(fraction * 100)), tone: .secondary)
            case .loading?:
                ProgressView().controlSize(.small)
                SettingsStatus(text: L("settings.voice.model.loading"), tone: .secondary)
            case nil:
                if WhisperTranscriber.shared.isDownloaded {
                    SettingsStatus(text: L("settings.voice.model.ready"), tone: .success)
                } else {
                    SettingsStatus(text: L("settings.voice.model.missing"), tone: .secondary)
                    Button(L("settings.voice.model.download")) { voice.predownload() }
                }
            }
        }
    }

    // MARK: 唤醒词

    private var wakeWordProblem: WakeWordRule.Problem? {
        if case .failure(let problem) = WakeWordRule.validate(wakeWordDraft) { return problem }
        return nil
    }

    private var wakeWordDirty: Bool {
        guard case .success(let value) = WakeWordRule.validate(wakeWordDraft) else { return false }
        return value != ConversationMode.storedWakeWord
    }

    private var wakeWordRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(L("settings.voice.wakeWord")) {
                HStack(spacing: 6) {
                    TextField("", text: $wakeWordDraft, prompt: Text(ConversationSession.defaultWakeWord))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .onSubmit(saveWakeWord)
                    Button(L("settings.voice.wakeWord.save"), action: saveWakeWord)
                        .disabled(!wakeWordDirty)
                }
            }
            if let problem = wakeWordProblem {
                SettingsNote(text: problem.message, tone: .warning)
            } else {
                SettingsNote(text: conversation.isOn ? L("settings.voice.wakeWord.noteOn") : L("settings.voice.wakeWord.note"))
            }
        }
        .onDisappear(perform: saveWakeWord)
    }

    /// 只保存通过校验的值；与默认值相同时删掉自定义（回到默认）。下次开启对话模式时生效。
    private func saveWakeWord() {
        guard case .success(let value) = WakeWordRule.validate(wakeWordDraft) else { return }
        wakeWordDraft = value
        guard value != ConversationMode.storedWakeWord else { return }
        if value == ConversationSession.defaultWakeWord {
            UserDefaults.standard.removeObject(forKey: ConversationSession.wakeWordDefaultsKey)
        } else {
            storedWakeWord = value
        }
    }

    // MARK: 朗读声音


    @ViewBuilder private var naturalStatus: some View {
        if installer.installing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                SettingsStatus(text: L("settings.voice.speech.installing"), tone: .secondary)
            }
        } else if NaturalVoice.isInstalled {
            SettingsStatus(text: L("settings.voice.speech.installed"), tone: .success)
        } else {
            HStack(spacing: 8) {
                SettingsStatus(text: L("settings.voice.speech.notInstalled"), tone: .secondary)
                Button(L("settings.voice.speech.install")) { install(select: false) }
            }
        }
    }

    /// 选中项：自然语音以 NaturalVoice.isSelected 为准（装好且没选过 = 默认）；选过的系统声音已不在时显示为自动。
    /// 选自然语音但没装时先询问安装，装好后才切换。
    private var voiceSelection: Binding<String> {
        Binding(get: {
            _ = chosen
            if NaturalVoice.isSelected { return NaturalVoiceProtocol.preferenceID }
            return candidates.contains { $0.identifier == chosen } ? chosen : ""
        }, set: { id in
            if id == NaturalVoiceProtocol.preferenceID, !NaturalVoice.isInstalled { return install(select: true) }
            chosen = id
            if !conversation.isOn { SpeechVoices.preview() }
        })
    }

    private func install(select: Bool) {
        installer.confirmAndInstall(hint: { model.voice.showHint($0) }) { ok in
            guard ok else { return }
            if select { chosen = NaturalVoiceProtocol.preferenceID }
            if !conversation.isOn { SpeechVoices.preview() }
        }
    }
}
