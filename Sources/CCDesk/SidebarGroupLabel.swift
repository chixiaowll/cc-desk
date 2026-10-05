import SwiftUI
import CCDeskCore

/// 目录行的内容（图标、目录名、分支、计数、折叠箭头），固定 28pt 高（随界面文字倍率）；不含悬停、点击与拖放。
struct GroupHeaderLabel: View {
    let group: SessionGroup
    let collapsed: Bool
    /// 悬停时操作按钮盖在计数的位置上，计数隐藏但仍占位（不重排）。
    var countsHidden = false
    let theme: Theme
    @Environment(\.uiScale) private var uiScale

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .uiFont(size: 12.5)
                    .foregroundStyle(theme.fg2)
                    .frame(width: uiScale.metric(30))
                HStack(spacing: 6) {
                    Text(group.title)
                        .uiFont(size: 13, weight: .semibold)
                        .foregroundStyle(theme.fg1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    if let branch = group.branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .labelStyle(.titleAndIcon)
                            .uiFont(size: 11)
                            .foregroundStyle(theme.fg3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            GroupCounts(group: group, collapsed: collapsed, theme: theme)
                .opacity(countsHidden ? 0 : 1)
            Image(systemName: "chevron.down")
                .uiFont(size: 9, weight: .semibold)
                .foregroundStyle(theme.fg3)
                .rotationEffect(.degrees(collapsed ? -90 : 0))
                .animation(.easeInOut(duration: 0.15), value: collapsed)
                .frame(width: uiScale.metric(16))
        }
        .padding(.trailing, 6)
        .frame(height: uiScale.metric(28))
    }
}

/// 目录行右侧的状态计数：等批准实心橙、已完成·未读实心鼠尾草绿、处理中实心雾蓝带呼吸白点、空闲灰色（仅收起时）。
struct GroupCounts: View {
    let group: SessionGroup
    let collapsed: Bool
    let theme: Theme

    var body: some View {
        HStack(spacing: 3) {
            if group.waitingCount > 0 {
                CountChip(text: "\(group.waitingCount)", bg: theme.pillWaitBg, fg: theme.pillWaitFg)
            }
            if group.unreadCount > 0 {
                CountChip(text: "\(group.unreadCount)", bg: theme.chipUnreadBg, fg: theme.chipUnreadFg)
            }
            if group.workingCount > 0 {
                HStack(spacing: 4) {
                    BreathingDot(color: theme.chipWorkFg, size: 5)
                    Text("\(group.workingCount)")
                }
                .modifier(CountChipStyle(bg: theme.chipWorkBg, fg: theme.chipWorkFg, leading: 5, trailing: 6))
            }
            if collapsed && group.idleCount > 0 {
                CountChip(text: "\(group.idleCount)", bg: theme.chip, fg: theme.fg2)
            }
        }
        .fixedSize()
        .help(helpText)
    }

    private var helpText: String {
        [group.waitingCount > 0 ? L("group.help.waiting", group.waitingCount) : nil,
         group.unreadCount > 0 ? L("group.help.unread", group.unreadCount) : nil,
         group.workingCount > 0 ? L("group.help.working", group.workingCount) : nil,
         group.idleCount > 0 ? L("group.help.idle", group.idleCount) : nil]
            .compactMap { $0 }
            .joined(separator: L("list.separator.clause"))
    }
}

struct CountChip: View {
    let text: String
    let bg: Color
    let fg: Color

    var body: some View {
        Text(text).modifier(CountChipStyle(bg: bg, fg: fg, leading: 5, trailing: 5))
    }
}

struct CountChipStyle: ViewModifier {
    let bg: Color
    let fg: Color
    let leading: CGFloat
    let trailing: CGFloat
    @Environment(\.uiScale) private var uiScale

    func body(content: Content) -> some View {
        content
            .uiFont(size: 10.5, weight: .semibold, monospacedDigit: true)
            .foregroundStyle(fg)
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .frame(minWidth: uiScale.metric(16), minHeight: uiScale.metric(16), maxHeight: uiScale.metric(16))
            .background(Capsule().fill(bg))
    }
}
