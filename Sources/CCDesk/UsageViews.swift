import SwiftUI
import CCDeskCore

extension Theme {
    /// 用量进度条颜色：正常雾蓝、警告浅陶土、严重实心陶土。
    func usageFill(_ level: UsageLevel) -> Color {
        switch level {
        case .normal: return dot
        case .warning: return accent.opacity(0.55)
        case .critical: return pillWaitBg
        }
    }
}

/// 胶囊进度条；缓存已过期（重置时间已过）时只显示轨道。
struct UsageBar: View {
    let limit: UsageLimit
    let now: Date
    let width: CGFloat?
    let height: CGFloat
    let theme: Theme

    var body: some View {
        let fraction = limit.isExpired(now: now) ? 0 : min(max(limit.percent / 100, 0), 1)
        Capsule()
            .fill(theme.chip)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(theme.usageFill(limit.level))
                        .frame(width: fraction > 0 ? max(proxy.size.width * fraction, height) : 0)
                }
            }
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
    }
}

/// 侧栏底部的用量行：「Claude  5h ▓░ 20%   7d ▓▓▓ 89%」；窄时省略「Claude」。点击弹出详情。
struct UsageFooterLine: View {
    let usage: ClaudeUsage
    let now: Date
    let theme: Theme
    @State private var showDetail = false

    var body: some View {
        Button { showDetail.toggle() } label: {
            ViewThatFits(in: .horizontal) {
                line(showName: true)
                line(showName: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(usage.summary(now: now, calendar: .current))
        .popover(isPresented: $showDetail, arrowEdge: .top) {
            UsagePopover(usage: usage, now: now, theme: theme)
        }
    }

    private func line(showName: Bool) -> some View {
        HStack(spacing: 10) {
            if showName {
                Text("Claude").fontWeight(.medium)
            }
            ForEach(Array(usage.footerLimits.enumerated()), id: \.offset) { _, limit in
                HStack(spacing: 5) {
                    Text(limit.shortLabel).foregroundStyle(theme.fg3)
                    UsageBar(limit: limit, now: now, width: 40, height: 5, theme: theme)
                    Text(limit.percentText(now: now))
                        .monospacedDigit()
                        .frame(minWidth: 28, alignment: .leading)
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.fg2)
        .lineLimit(1)
        .fixedSize()
    }
}

/// 用量详情：套餐、全部额度（标出当前限制）、额外用量、数据时间。
struct UsagePopover: View {
    let usage: ClaudeUsage
    let now: Date
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Claude").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.fg1)
                if !usage.planLabel.isEmpty {
                    Text(usage.planLabel).font(.system(size: 12)).foregroundStyle(theme.fg2)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(usage.limits.enumerated()), id: \.offset) { _, limit in
                    row(limit)
                }
            }
            theme.line.frame(height: 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("额外用量：\(usage.extraUsageText)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.fg2)
                Text(usage.ageText(now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(usage.isStale(now: now) ? theme.fg3 : theme.fg2)
                if usage.isStale(now: now) {
                    Text("Claude Code 运行时会刷新这份缓存，数据可能已过时")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.fg3)
                }
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background(theme.main)
    }

    private func row(_ limit: UsageLimit) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(limit.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.fg1)
                    .lineLimit(1)
                if limit.isActive {
                    Text("当前限制")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background(Capsule().fill(theme.waitRow))
                }
                Spacer(minLength: 4)
                Text(limit.percentText(now: now))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.fg1)
            }
            UsageBar(limit: limit, now: now, width: nil, height: 6, theme: theme)
            if let reset = limit.resetText(now: now, calendar: .current) {
                Text(reset).font(.system(size: 11)).foregroundStyle(theme.fg3)
            }
        }
    }
}
