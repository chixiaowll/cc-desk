import SwiftUI

/// 终端底部的语音浮层：录音中（脉动麦克风 + 「松开结束」 + 电平条）/ 模型下载或加载 / 识别中 / 简短提示。
struct VoiceOverlay: View {
    @ObservedObject var voice: VoiceInput
    let theme: Theme

    var body: some View {
        Group {
            if let content {
                capsule(content)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: voice.phase)
        .animation(.easeOut(duration: 0.15), value: voice.preparing)
        .allowsHitTesting(false)
    }

    private enum Content: Equatable {
        case recording
        case transcribing
        case downloading(Double)
        case loading
        case hint(String)
    }

    private var content: Content? {
        switch voice.phase {
        case .recording: return .recording
        case .hint(let text): return .hint(text)
        case .transcribing, .idle:
            switch voice.preparing {
            case .downloading(let fraction): return .downloading(fraction)
            case .loading: return .loading
            case nil: return voice.phase == .transcribing ? .transcribing : nil
            }
        }
    }

    @ViewBuilder
    private func capsule(_ content: Content) -> some View {
        HStack(spacing: 9) {
            switch content {
            case .recording:
                PulsingMic(color: theme.accent)
                Text("松开结束").foregroundStyle(theme.fg1)
                LevelMeter(level: voice.level, color: theme.accent, idle: theme.line)
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("识别中…").foregroundStyle(theme.fg1)
            case .downloading(let fraction):
                ProgressView().controlSize(.small)
                Text("首次使用正在下载语音模型… \(Int(fraction * 100))%").foregroundStyle(theme.fg1)
                    .monospacedDigit()
            case .loading:
                ProgressView().controlSize(.small)
                Text("正在加载语音模型…首次加载可能需要几分钟").foregroundStyle(theme.fg1)
            case .hint(let text):
                Image(systemName: "mic").foregroundStyle(theme.fg2)
                Text(text).foregroundStyle(theme.fg2)
            }
        }
        .font(.system(size: 12.5, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Capsule().fill(theme.sel))
        .overlay(Capsule().strokeBorder(content == .recording ? theme.accent.opacity(0.55) : theme.selLine,
                                        lineWidth: 1))
        .shadow(color: theme.popShadow, radius: 10, y: 3)
    }
}

/// 录音中的麦克风：缩放脉动；开启「减少动态效果」时静止。
private struct PulsingMic: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !reduceMotion {
                PhaseAnimator([0.0, 1.0]) { phase in
                    Circle().fill(color.opacity(0.28 * (1 - phase)))
                        .frame(width: 22, height: 22)
                        .scaleEffect(0.7 + 0.5 * phase)
                } animation: { _ in .easeOut(duration: 0.9) }
            }
            Image(systemName: "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: 22, height: 22)
    }
}

/// 5 格电平条。
private struct LevelMeter: View {
    let level: Float
    let color: Color
    let idle: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<5, id: \.self) { index in
                let threshold = Float(index) / 5
                let lit = level > threshold
                RoundedRectangle(cornerRadius: 1.25)
                    .fill(lit ? color : idle)
                    .frame(width: 3, height: 5 + CGFloat(index) * 2.5)
            }
        }
        .frame(height: 16)
        .animation(.linear(duration: 0.08), value: level)
    }
}

/// 终端下方的语音输入条：紧挨 agent 输入框，按住按钮说话，松开后插入识别结果。
struct VoiceBar: View {
    @ObservedObject var voice: VoiceInput
    let theme: Theme

    var body: some View {
        VStack(spacing: 0) {
            theme.line.frame(height: 1)
            HStack(spacing: 10) {
                MicButton(voice: voice, theme: theme)
                Text(voice.isRecording ? "松开结束，识别后插入输入框" : "按住说话 · 或按住右 ⌥")
                    .font(.system(size: 11.5))
                    .foregroundStyle(voice.isRecording ? theme.accent : theme.fg3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .frame(height: 36)
        }
        .background(Color(nsColor: theme.terminal.background))
    }
}

/// 语音输入条里的麦克风按钮：按住说话，松开结束。
struct MicButton: View {
    @ObservedObject var voice: VoiceInput
    let theme: Theme
    @State private var pressing = false

    var body: some View {
        let active = voice.isRecording
        HStack(spacing: 5) {
            Image(systemName: active ? "mic.fill" : "mic")
                .font(.system(size: 12, weight: .semibold))
            Text("按住说话")
                .font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(active ? theme.pillWaitFg : theme.fg2)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(active ? theme.accent : theme.pillIdleBg))
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressing else { return }
                    pressing = true
                    voice.mousePressed()
                }
                .onEnded { _ in
                    pressing = false
                    voice.mouseReleased()
                })
        .help("按住说话，松开后插入识别结果（也可按住右 ⌥）")
        .accessibilityLabel("语音输入")
    }
}
