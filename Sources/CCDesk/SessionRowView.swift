import SwiftUI
import AppKit
import CCDeskCore

/// 侧栏中的一条会话（舒适密度：两行）。布局取自界面稿 `.rows .row`。
struct SessionRowView: View {
    let row: SidebarRow
    let selected: Bool
    let now: Date
    let appIcon: NSImage?
    let theme: Theme
    @State private var hovering = false

    private var isWaiting: Bool { row.session.status.isWaiting }
    private var isMissing: Bool {
        if case .missing = row.session.host { return true }
        return false
    }

    /// 行背景：选中 > 等批准 > 悬停 > 透明（与界面稿 CSS 的覆盖顺序一致）。
    private var background: Color {
        if selected { return theme.sel }
        if isWaiting { return theme.waitRow }
        if hovering { return theme.hover }
        return .clear
    }

    /// 图标角标外圈的颜色，需与行背景一致，才能把角标和图标分开。
    private var ringColor: Color {
        if selected { return theme.sel }
        if isWaiting { return theme.waitRow }
        if hovering { return theme.hover }
        return theme.side
    }

    var body: some View {
        HStack(spacing: 9) {
            SessionTile(host: row.session.host, status: row.session.status, appIcon: appIcon,
                        ring: ringColor, extRing: selected || isWaiting || theme.isDark ? ringColor : theme.extRing,
                        theme: theme)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 9) {
                    Text(row.displayName)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.fg1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(RelativeTime.short(from: row.session.statusChangedAt, now: now))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(theme.fg3)
                }
                .frame(height: 17)
                statusLine
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: 14)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(background))
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.selLine, lineWidth: 1) }
        }
        .shadow(color: selected ? theme.selShadow : .clear, radius: 1, y: 1)
        .opacity(RelativeTime.isStale(row.session.statusChangedAt, now: now) ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(row.tooltip)
    }

    @ViewBuilder private var statusLine: some View {
        if isMissing {
            (Text("目录缺失").fontWeight(.medium).foregroundColor(theme.pillMissFg)
                + Text(" · \(row.session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))").foregroundColor(theme.fg2))
        } else {
            switch row.session.status {
            case .waiting(let reason):
                Text(reason.map { "等批准 · \($0)" } ?? "等批准")
                    .fontWeight(.bold)
                    .foregroundStyle(theme.pillWaitBg)
            case .working:
                Text("处理中").fontWeight(.medium).foregroundStyle(theme.pillWorkFg)
            case .idle, .ended, .unknown:
                Text(row.statusLabel).fontWeight(.medium).foregroundStyle(theme.fg3)
            }
        }
    }
}

/// 26pt 图标块：内嵌 = 暖灰底终端符号；外部 = 宿主 App 真实图标 + 右上角「↗」；右下角状态点。
struct SessionTile: View {
    let host: SessionHost
    let status: AgentStatus
    let appIcon: NSImage?
    /// 状态点外圈颜色（= 行背景）。
    let ring: Color
    /// 「↗」角标外圈颜色。
    let extRing: Color
    let theme: Theme

    private var isExternal: Bool {
        switch host {
        case .terminalApp, .vscode, .other: return true
        case .embedded, .missing: return false
        }
    }

    var body: some View {
        tile
            .frame(width: 26, height: 26)
            .overlay(alignment: .topTrailing) {
                if isExternal { ExternalBadge(ring: extRing, theme: theme).offset(x: 3 + 1.5, y: -3 - 1.5) }
            }
            .overlay(alignment: .bottomTrailing) {
                if let color = dotColor {
                    ZStack {
                        Circle().fill(ring).frame(width: 9, height: 9)
                        if status == .working {
                            BreathingDot(color: color, size: 6)
                        } else {
                            Circle().fill(color).frame(width: 6, height: 6)
                        }
                    }
                    .offset(x: 2, y: 2)
                }
            }
    }

    private var dotColor: Color? {
        if case .missing = host { return nil }
        switch status {
        case .waiting: return theme.pillWaitBg
        case .working: return theme.dot
        case .idle, .ended, .unknown: return nil
        }
    }

    @ViewBuilder private var tile: some View {
        switch host {
        case .missing:
            symbolTile("questionmark.folder", bg: theme.tileMissBg, fg: theme.tileMissFg)
        case .embedded:
            symbolTile("apple.terminal", bg: theme.tileEmbBg, fg: theme.tileEmbFg)
        case .terminalApp, .vscode, .other:
            if let appIcon {
                AppIconImage(image: appIcon, theme: theme)
            } else {
                symbolTile("apple.terminal", bg: theme.tileTermBg, fg: theme.tileTermFg)
            }
        }
    }

    private func symbolTile(_ name: String, bg: Color, fg: Color) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(bg)
            .overlay(Image(systemName: name).font(.system(size: 13)).foregroundStyle(fg))
    }
}

/// 外部 App 图标。深色外观下加一圈 0.6pt 的半透明白色描边（沿图标形状）+ 投影，避免黑色图标融进深色侧栏。
struct AppIconImage: View {
    let image: NSImage
    let theme: Theme

    var body: some View {
        let icon = Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        if let rim = theme.appIconRim {
            icon
                .shadow(color: rim, radius: 0.6)
                .shadow(color: theme.appIconShadow, radius: theme.appIconShadowRadius, y: 1)
        } else {
            icon.shadow(color: theme.appIconShadow, radius: theme.appIconShadowRadius, y: 1)
        }
    }
}

/// 右上角 12pt「↗」角标；外圈 1.5pt 与行背景同色，把角标和图标分开。
struct ExternalBadge: View {
    let ring: Color
    let theme: Theme

    var body: some View {
        ZStack {
            Circle().fill(ring).frame(width: 15, height: 15)
            Circle().fill(theme.extBg).frame(width: 12, height: 12)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 6.5, weight: .bold))
                .foregroundStyle(theme.extFg)
        }
        .frame(width: 15, height: 15)
    }
}

struct RowMenu: View {
    @ObservedObject var model: AppModel
    let row: SidebarRow

    var body: some View {
        switch row.session.host {
        case .missing:
            Button("在其他目录打开…") { model.relocateMissing(row) }
            Button("移除") { model.removeMissing(row) }
        default:
            Button("在 Finder 中打开") { model.revealInFinder(row) }
            if row.session.sessionID != nil {
                Button("复制恢复命令") { model.copyResumeCommand(row) }
            }
            if !row.session.host.isEmbedded {
                Button("在这里接管") { model.takeOver(row) }
                    .disabled(row.session.sessionID == nil || row.session.pid == nil || model.isTakingOver(row))
            }
            Divider()
            if row.session.host.isEmbedded {
                Button("关闭") { model.close(row) }
            } else {
                Button("结束进程") { model.killExternal(row) }
            }
        }
    }
}
