import SwiftUI
import CCDeskCore

/// 设置 › 语音 › 模型下载与环境（设计 §29）：选下载源（自动 / 官方 / 国内镜像），一键检查芯片、uv 与两个下载源的连通性。
struct SettingsModelSection: View {
    @AppStorage(ModelHubSource.defaultsKey) private var source = ModelHubSource.auto.rawValue
    @State private var checking = false
    @State private var results: [(text: String, ok: Bool)] = []
    @State private var uvMissing = false

    var body: some View {
        Section(L("settings.voice.check")) {
            VStack(alignment: .leading, spacing: 4) {
                Picker(L("settings.voice.hub"), selection: $source) {
                    Text(L("settings.voice.hub.auto")).tag(ModelHubSource.auto.rawValue)
                    Text(L("settings.voice.hub.official")).tag(ModelHubSource.official.rawValue)
                    Text(L("settings.voice.hub.mirror")).tag(ModelHubSource.mirror.rawValue)
                }
                SettingsNote(text: L("settings.voice.hub.note"))
            }
            HStack(spacing: 8) {
                Button(L("settings.voice.check.run"), action: runCheck).disabled(checking)
                if checking {
                    ProgressView().controlSize(.small)
                    SettingsStatus(text: L("settings.voice.check.running"), tone: .secondary)
                }
                Spacer()
                if uvMissing {
                    Button(L("settings.voice.check.copyUV")) { FileActions.copy(VoiceSupport.uvInstallCommand) }
                }
            }
            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                        SettingsStatus(text: (item.ok ? "✓ " : "⚠︎ ") + item.text, tone: item.ok ? .success : .warning)
                    }
                }
            }
        }
    }

    private func runCheck() {
        checking = true
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [(String, Bool)] = []
            let apple = ModelHubProbe.isAppleSilicon
            lines.append((apple ? L("settings.voice.check.chip.apple") : L("settings.voice.check.chip.intel"), apple))
            let uv = NaturalVoiceInstaller.locateUV()
            if apple {
                lines.append((uv.map { L("settings.voice.check.uv.ok", $0) } ?? L("settings.voice.check.uv.missing"), uv != nil))
            }
            let official = ModelHubProbe.reachable(ModelHub.official, useCache: false)
            lines.append((official ? L("settings.voice.check.official.ok") : L("settings.voice.check.official.fail"), official))
            let mirror = ModelHubProbe.reachable(ModelHub.mirror, useCache: false)
            lines.append((mirror ? L("settings.voice.check.mirror.ok") : L("settings.voice.check.mirror.fail"), mirror))
            DispatchQueue.main.async {
                results = lines.map { (text: $0.0, ok: $0.1) }
                uvMissing = apple && uv == nil
                checking = false
            }
        }
    }
}
