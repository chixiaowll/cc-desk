import SwiftUI
import CCDeskCore

/// token 汇总（设计 §27）：今天 / 近 7 天切换，总量与构成，按项目 / 模型 / agent 的前几名。
struct TokenSection: View {
    let tokens: TokenOverview
    let theme: Theme
    @State private var showToday = false

    private var summary: TokenSummary { showToday ? tokens.today : tokens.week }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(L("tokens.title")).uiFont(size: 13, weight: .semibold).foregroundStyle(theme.fg1)
                Spacer(minLength: 4)
                Picker("", selection: $showToday) {
                    Text(L("tokens.today")).tag(true)
                    Text(L("tokens.week")).tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
            if summary.total.isZero {
                Text(L("tokens.none")).uiFont(size: 11.5).foregroundStyle(theme.fg3)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(TokenUsage.compact(summary.total.total))
                        .uiFont(size: 18, weight: .semibold, monospacedDigit: true)
                        .foregroundStyle(theme.fg1)
                    Text(summary.total.breakdownText)
                        .uiFont(size: 11)
                        .foregroundStyle(theme.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                breakdown(L("tokens.byProject"), summary.byProject, limit: 5)
                breakdown(L("tokens.byModel"), summary.byModel, limit: 4)
                if summary.byAgent.count > 1 { breakdown(L("tokens.byAgent"), summary.byAgent, limit: 3) }
            }
            Text(L("tokens.note"))
                .uiFont(size: 10.5)
                .foregroundStyle(theme.fg3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func breakdown(_ title: String, _ slices: [TokenSummary.Slice], limit: Int) -> some View {
        let top = Array(slices.prefix(limit))
        let maxTotal = max(top.first?.usage.total ?? 1, 1)
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).uiFont(size: 11, weight: .medium).foregroundStyle(theme.fg3)
            ForEach(top) { slice in
                HStack(spacing: 8) {
                    Text(slice.name)
                        .uiFont(size: 11.5)
                        .foregroundStyle(theme.fg1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Capsule()
                        .fill(theme.chip)
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule().fill(theme.dot)
                                    .frame(width: max(proxy.size.width * Double(slice.usage.total) / Double(maxTotal), 3))
                            }
                        }
                        .frame(width: 50, height: 4)
                    Text(TokenUsage.compact(slice.usage.total))
                        .uiFont(size: 11.5, monospacedDigit: true)
                        .foregroundStyle(theme.fg2)
                        .frame(minWidth: 42, alignment: .trailing)
                }
            }
        }
    }
}

/// 没有 Claude 订阅用量时底部的 token 行：「Token  今天 1.2M · 7 天 210M」，点击弹出汇总。
struct TokenFooterLine: View {
    @Environment(\.uiScale) private var uiScale
    let tokens: TokenOverview
    let theme: Theme
    var onOpen: () -> Void = {}
    @State private var showDetail = false

    var body: some View {
        Button {
            showDetail.toggle()
            if showDetail { onOpen() }
        } label: {
            HStack(spacing: 8) {
                Text(L("tokens.title")).fontWeight(.medium)
                Text(L("tokens.footer", TokenUsage.compact(tokens.today.total.total),
                       TokenUsage.compact(tokens.week.total.total)))
                    .monospacedDigit()
            }
            .uiFont(size: 11)
            .foregroundStyle(theme.fg2)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDetail, arrowEdge: .top) {
            TokenSection(tokens: tokens, theme: theme)
                .padding(14)
                .frame(width: uiScale.metric(280), alignment: .leading)
                .background(theme.main)
                .uiScaleRoot()
        }
    }
}
