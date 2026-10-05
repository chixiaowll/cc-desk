import SwiftUI
import AppKit
import CCDeskCore

/// 「助手结果」面板里的通用助手问答（设计 §24）：问题、回答全文（可选中、可复制）、模型、用时、token，
/// 上网搜索过什么、来源链接；排队 / 回答中的可以取消。
struct CompanionResultsList: View {
    @ObservedObject var companion: CompanionWork
    let theme: Theme

    var body: some View {
        if companion.book.jobs.isEmpty {
            Text(L("results.companion.empty", companion.name))
                .font(.system(size: 12))
                .foregroundStyle(theme.fg3)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(companion.book.jobs) { job in
                        CompanionJobRow(job: job, theme: theme, cancel: { companion.cancel(reason: "results panel") })
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 260, maxHeight: 520)
        }
    }
}

private struct CompanionJobRow: View {
    let job: CompanionJob
    let theme: Theme
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                stateIcon.frame(width: 16, height: 16).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.question)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.fg1)
                        .textSelection(.enabled)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(meta(now: context.date))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.fg3)
                    }
                }
                Spacer(minLength: 8)
                if job.isActive {
                    Button(L("results.cancel"), action: cancel).controlSize(.small)
                } else if let answer = job.answer, job.state == .done {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answer, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help(L("results.copy"))
                }
            }
            if job.state == .done, let answer = job.answer {
                Text(ConsultJobRow.markdown(answer))
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.fg1)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 24)
                if !job.webLookups.isEmpty {
                    Text(L("results.companion.searched", job.webLookups.prefix(4).joined(separator: " · ")))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.fg3)
                        .textSelection(.enabled)
                        .padding(.leading, 24)
                }
                if !job.sources.isEmpty { sources }
            } else if let error = job.error, !job.isActive {
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

    /// 来源链接（只显示 http(s)）。
    private var sources: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("results.companion.sources")).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.fg2)
            ForEach(job.sources.prefix(6), id: \.url) { source in
                if let url = URL(string: source.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    Link(source.title, destination: url)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(source.url)
                }
            }
        }
        .padding(.leading, 24)
    }

    @ViewBuilder private var stateIcon: some View {
        switch job.state {
        case .queued: Image(systemName: "clock").foregroundStyle(theme.fg3)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "bubble.left.and.text.bubble.right.fill").foregroundStyle(theme.unread)
        case .failed, .timedOut: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.accent)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(theme.fg3)
        }
    }

    /// 「Sonnet · 8 秒 · 输入 12.3k / 输出 210 token · 上网搜索」。
    private func meta(now: Date) -> String {
        var parts = [job.model.capitalized]
        switch job.state {
        case .queued:
            parts.append(L("results.companion.queued"))
        case .running:
            let started = job.startedAt ?? job.askedAt
            parts.append(L("results.seconds", Int(now.timeIntervalSince(started).rounded())))
            parts.append(L("results.thinking"))
        case .done:
            parts.append(L("results.seconds", Int((job.duration ?? 0).rounded())))
            parts.append(L("results.tokens", ConsultJobRow.k(job.inputTokens), ConsultJobRow.k(job.outputTokens)))
            if !job.webLookups.isEmpty { parts.append(L("results.companion.web")) }
        case .failed: parts.append(L("results.failed"))
        case .timedOut: parts.append(L("results.timedOut"))
        case .cancelled: parts.append(L("results.cancelled"))
        }
        return parts.joined(separator: " · ")
    }
}
