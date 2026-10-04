import SwiftUI
import AppKit
import CCDeskCore

/// 「助手结果」面板（设计 §14）：顾问任务列表——问题、模型、用时、token、状态；运行中可取消，完成的显示结论与完整回答（可选中、可复制）。
/// 与「集成」面板一样以表单形式出现在主窗口上。
struct AssistantResultsSheet: View {
    @ObservedObject var work: AssistantWork
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var themes = ThemeStore.shared
    @State private var expanded: Set<String> = []

    var body: some View {
        let theme = themes.theme(for: colorScheme)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("results.title")).font(.headline)
                Spacer()
                CloseButton { work.showResults = false }
            }
            Text(L("results.intro"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if work.consults.jobs.isEmpty {
                Text(L("results.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.fg3)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(work.consults.jobs) { job in
                            ConsultJobRow(job: job, theme: theme, expanded: expandedBinding(job.id),
                                          cancel: { work.cancelConsult(job.id) })
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 260, maxHeight: 520)
            }

            HStack {
                Text(L("results.quotaNote"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(L("action.done")) { work.showResults = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onExitCommand { work.showResults = false }
        .onAppear {
            // 打开时展开最新一条已完成的结果。
            if let latest = work.consults.jobs.first(where: { $0.state == .done }) { expanded.insert(latest.id) }
        }
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { on in
            if on { expanded.insert(id) } else { expanded.remove(id) }
        })
    }
}

private struct ConsultJobRow: View {
    let job: ConsultJob
    let theme: Theme
    @Binding var expanded: Bool
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                stateIcon.frame(width: 16, height: 16).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.question)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.fg1)
                        .lineLimit(expanded ? nil : 2)
                        .textSelection(.enabled)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(meta(now: context.date))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.fg3)
                    }
                }
                Spacer(minLength: 8)
                if job.state == .running {
                    Button(L("results.cancel"), action: cancel).controlSize(.small)
                } else if let answer = job.outcome?.answer, job.state == .done {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answer, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help(L("results.copy"))
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if job.state == .done, let answer = job.outcome?.answer {
                Text(ConsultAnswer.conclusion(answer, limit: 400))
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.fg1)
                    .textSelection(.enabled)
                    .padding(.leading, 24)
                if expanded {
                    Text(Self.markdown(ConsultAnswer.details(answer)))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.fg2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.side))
                        .padding(.leading, 24)
                }
            } else if let error = job.error, job.state != .running {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.fg2)
                    .textSelection(.enabled)
                    .padding(.leading, 24)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    @ViewBuilder private var stateIcon: some View {
        switch job.state {
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.unread)
        case .failed, .timedOut: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.accent)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(theme.fg3)
        }
    }

    /// 「Sonnet · 审查员 · poems · 42 秒 · 输入 18.3k / 输出 1.2k token」。
    private func meta(now: Date) -> String {
        var parts = [job.model.capitalized]
        if let profile = job.profile { parts.append(profile) }
        parts.append(URL(fileURLWithPath: job.project).lastPathComponent)
        let seconds = Int((job.duration ?? now.timeIntervalSince(job.startedAt)).rounded())
        parts.append(L("results.seconds", seconds))
        switch job.state {
        case .running:
            parts.append(job.toolCalls > 0 ? L("results.reading", job.toolCalls) : L("results.thinking"))
        case .done:
            if let o = job.outcome { parts.append(L("results.tokens", Self.k(o.inputTokens), Self.k(o.outputTokens))) }
        case .failed: parts.append(L("results.failed"))
        case .timedOut: parts.append(L("results.timedOut"))
        case .cancelled: parts.append(L("results.cancelled"))
        }
        return parts.joined(separator: " · ")
    }

    static func k(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    /// 完整回答：行内 markdown（粗体 / 代码 / 链接），保留换行。
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// 工具栏按钮：打开「助手结果」；有顾问在运行时高亮。
struct AssistantResultsButton: View {
    @ObservedObject var work: AssistantWork

    var body: some View {
        Button { work.showResults = true } label: {
            Image(systemName: "sparkles")
                .foregroundStyle(work.consults.running.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
        }
        .help(L("toolbar.results.help"))
    }
}

/// 在主窗口上挂「助手结果」表单。
struct AssistantResultsPresenter: ViewModifier {
    @ObservedObject var work: AssistantWork

    func body(content: Content) -> some View {
        content.sheet(isPresented: $work.showResults) { AssistantResultsSheet(work: work) }
    }
}
