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
                Text(L("voice.overlay.release")).foregroundStyle(theme.fg1)
                LevelMeter(level: voice.level, color: theme.accent, idle: theme.line)
            case .transcribing:
                ProgressView().controlSize(.small)
                Text(L("voice.overlay.transcribing")).foregroundStyle(theme.fg1)
            case .downloading(let fraction):
                ProgressView().controlSize(.small)
                Text(L("voice.overlay.downloading", Int(fraction * 100))).foregroundStyle(theme.fg1)
                    .monospacedDigit()
            case .loading:
                ProgressView().controlSize(.small)
                Text(L("voice.overlay.loading")).foregroundStyle(theme.fg1)
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

/// 终端下方的语音输入条：紧挨 agent 输入框。平时按住按钮说话；打开「对话模式」后显示聆听状态。
struct VoiceBar: View {
    @ObservedObject var voice: VoiceInput
    @ObservedObject var conversation: ConversationMode
    let theme: Theme

    var body: some View {
        VStack(spacing: 0) {
            theme.line.frame(height: 1)
            HStack(spacing: 10) {
                if conversation.isOn {
                    ConversationToggle(conversation: conversation, theme: theme)
                    ConversationStatus(conversation: conversation, theme: theme)
                } else {
                    MicButton(voice: voice, theme: theme)
                    ConversationToggle(conversation: conversation, theme: theme)
                    Text(voice.isRecording ? L("voice.bar.recording") : L("voice.bar.idle"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(voice.isRecording ? theme.accent : theme.fg3)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .frame(height: 36)
        }
        .background(Color(nsColor: theme.terminal.background))
    }
}

/// 「对话模式」开关（⌥⌘V）。
struct ConversationToggle: View {
    @ObservedObject var conversation: ConversationMode
    let theme: Theme

    var body: some View {
        let on = conversation.isOn
        Button {
            conversation.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "waveform.circle.fill" : "waveform.circle")
                    .font(.system(size: 12, weight: .semibold))
                Text(L("conversation.toggle"))
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(on ? theme.chipWorkFg : theme.fg2)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(on ? theme.chipWorkBg : theme.pillIdleBg))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L("conversation.toggle.help", conversation.wakeWord))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 对话模式的状态：脉动圆点 + 电平 + 文字（待命 / 聆听 / 识别中 / 播报中 / 指令提示）。
/// 聆听时雾蓝，正在录下一句话时陶土色；待命时圆点变淡、不脉动。
struct ConversationStatus: View {
    @ObservedObject var conversation: ConversationMode
    let theme: Theme

    var body: some View {
        let active = conversation.state == .active
        let color = conversation.capturing ? theme.accent : theme.dot
        HStack(spacing: 8) {
            PulsingDot(color: color, pulsing: active || conversation.capturing)
                .opacity(active || conversation.capturing ? 1 : 0.55)
            LevelMeter(level: conversation.level, color: color, idle: theme.line)
            Text(text)
                .font(.system(size: 11.5, weight: conversation.toast == nil ? .regular : .semibold))
                .foregroundStyle(conversation.toast == nil ? (active ? theme.fg2 : theme.fg3) : theme.fg1)
                .lineLimit(1)
        }
        .animation(.easeOut(duration: 0.15), value: conversation.toast)
    }

    private var text: String {
        if let toast = conversation.toast { return toast }
        if conversation.preparing { return L("conversation.status.preparing") }
        if conversation.thinking { return L("conversation.status.thinking") }
        if conversation.speaking { return L("conversation.status.speaking") }
        if conversation.transcribing { return L("conversation.status.transcribing") }
        switch conversation.state {
        case .standby: return L("conversation.status.standby", conversation.wakeWord)
        case .active: return L("conversation.status.listening")
        }
    }
}

/// 对话模式聆听中的圆点：缩放脉动；开启「减少动态效果」或待命时静止。
private struct PulsingDot: View {
    let color: Color
    let pulsing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if pulsing && !reduceMotion {
                PhaseAnimator([0.0, 1.0]) { phase in
                    Circle().fill(color.opacity(0.3 * (1 - phase)))
                        .frame(width: 16, height: 16)
                        .scaleEffect(0.5 + 0.6 * phase)
                } animation: { _ in .easeOut(duration: 1.0) }
            }
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: 16, height: 16)
    }
}

/// 工具栏里的「对话模式」标识：麦克风正在持续监听。
struct ConversationBadge: View {
    @ObservedObject var conversation: ConversationMode
    let theme: Theme

    var body: some View {
        if conversation.isOn {
            HStack(spacing: 4) {
                Image(systemName: "mic.fill").font(.system(size: 10, weight: .semibold))
                Text(L("conversation.indicator")).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(theme.pillWorkFg)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(theme.pillWorkBg))
            .opacity(conversation.state == .active ? 1 : 0.75)
            .help(L("conversation.indicator.help"))
        }
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
            Text(L("voice.button.holdToTalk"))
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
        .help(L("voice.button.help"))
        .accessibilityLabel(L("voice.button.accessibility"))
    }
}
