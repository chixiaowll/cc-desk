import SwiftUI
import AppKit
import CCDeskCore

/// 窗格区域的几何（设计 §20）：单窗格与原来一样四周留白、没有标题条；多窗格时每个窗格顶部一条标题条，
/// 终端在其下方留出较小的内边距。放大时只有放大的窗格（仍带标题条，方便还原）。坐标原点在左上角。
struct PaneGeometry {
    static let singleInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
    static let paneInsets = NSEdgeInsets(top: 2, left: 10, bottom: 8, right: 10)
    static let headerHeight: CGFloat = 30

    /// 显示标题条与焦点边框（多于一个窗格，含放大时）。
    let showsChrome: Bool
    let paneFrames: [UUID: CGRect]
    let terminalFrames: [UUID: CGRect]
    let dividers: [PaneDivider]

    init(layout: PaneLayout, size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        showsChrome = layout.isSplit
        if let zoomed = layout.zoomed {
            paneFrames = [zoomed: bounds]
            dividers = []
        } else {
            paneFrames = layout.frames(in: bounds)
            dividers = layout.dividers(in: bounds)
        }
        let chrome = showsChrome
        terminalFrames = paneFrames.mapValues { frame in
            let insets = chrome ? Self.paneInsets : Self.singleInsets
            let top = chrome ? Self.headerHeight + insets.top : insets.top
            return CGRect(x: frame.minX + insets.left, y: frame.minY + top,
                          width: max(0, frame.width - insets.left - insets.right),
                          height: max(0, frame.height - top - insets.bottom)).integral
        }
    }
}

/// 详情区的窗格区域：底下是托管所有终端的 AppKit 容器，上面叠标题条、焦点边框和分隔线（多窗格时）。
struct PaneArea: View {
    @ObservedObject var model: AppModel
    @ObservedObject var panes: PaneLayoutModel
    let theme: Theme

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let layout = panes.layout
            let geometry = PaneGeometry(layout: layout, size: size)
            ZStack(alignment: .topLeading) {
                PaneTerminalHost(
                    pool: model.pool, owned: model.pool.terminals.map(\.id),
                    terminalFrames: geometry.terminalFrames, paneFrames: geometry.paneFrames,
                    focused: layout.focused, background: theme.terminal.background, accent: NSColor(theme.accent),
                    canDrop: { model.canDrop($0, on: $1, zone: $2) },
                    onDrop: { model.drop($0, on: $1, zone: $2) },
                    onClickPane: { model.focusPane($0) })
                if layout.isEmpty {
                    Text(L("detail.empty"))
                        .font(.system(size: 13))
                        .foregroundStyle(theme.fg3)
                        .frame(width: size.width, height: size.height)
                        .allowsHitTesting(false)
                }
                if geometry.showsChrome {
                    ForEach(geometry.dividers, id: \.path) { divider in
                        PaneDividerHandle(divider: divider, size: size, model: model, panes: panes, theme: theme)
                    }
                    ForEach(layout.leaves, id: \.self) { id in
                        if let frame = geometry.paneFrames[id] {
                            PaneChrome(model: model, terminalID: id, focused: layout.focused == id,
                                       zoomed: layout.zoomed == id, theme: theme)
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .coordinateSpace(name: PaneDividerHandle.space)
            .onAppear { panes.areaSize = size }
            .onChange(of: size) { _, new in panes.areaSize = new }
        }
    }
}

/// 一个窗格的标题条与焦点边框。只有标题条接收点击，其余部分让给下面的终端。
struct PaneChrome: View {
    @ObservedObject var model: AppModel
    let terminalID: UUID
    let focused: Bool
    let zoomed: Bool
    let theme: Theme

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(model: model, terminalID: terminalID, focused: focused, zoomed: zoomed, theme: theme)
            Color.clear.allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(focused ? theme.accent.opacity(0.75) : Color.clear, lineWidth: 1.5)
                .padding(2)
                .allowsHitTesting(false)
        }
    }
}

/// 窗格标题条：状态点、会话名、agent，右侧放大 / 关闭窗格按钮。点标题条选中这个窗格。
struct PaneHeader: View {
    @ObservedObject var model: AppModel
    let terminalID: UUID
    let focused: Bool
    let zoomed: Bool
    let theme: Theme

    var body: some View {
        let row = model.row(forTerminal: terminalID)
        HStack(spacing: 7) {
            PaneStatusDot(row: row, theme: theme)
            Text(row?.displayName ?? model.pool.terminal(terminalID)?.title ?? "")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(focused ? theme.fg1 : theme.fg2)
                .lineLimit(1)
                .truncationMode(.tail)
            if let row {
                Text(row.agentLabel.map { "\($0) · \(row.statusLabel)" } ?? row.statusLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.fg3)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 4)
            SidebarIconButton(systemName: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                              help: zoomed ? L("pane.unzoom.help") : L("pane.zoom.help"), on: zoomed, theme: theme) {
                model.toggleZoom(terminalID)
            }
            SidebarIconButton(systemName: "xmark", help: L("pane.close.help"), theme: theme) {
                model.closePane(terminalID)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: PaneGeometry.headerHeight)
        .contentShape(Rectangle())
        .onTapGesture { model.focusPane(terminalID) }
        .help(row?.tooltip ?? "")
    }
}

/// 标题条左侧的状态点：等批准橙、处理中呼吸蓝、已完成·未读绿，其余灰色空心。
struct PaneStatusDot: View {
    let row: SidebarRow?
    let theme: Theme

    var body: some View {
        Group {
            if let row, row.session.status == .working {
                BreathingDot(color: theme.dot, size: 7)
            } else if let row, row.session.status.isWaiting {
                Circle().fill(theme.pillWaitBg)
            } else if let row, row.showsUnread {
                Circle().fill(theme.unread)
            } else {
                Circle().strokeBorder(theme.fg3, lineWidth: 1)
            }
        }
        .frame(width: 7, height: 7)
    }
}

/// 窗格之间的分隔线：1pt 细线，两侧各 4pt 的可拖动区域；拖动时按最小窗格尺寸限制比例，松手后保存。
struct PaneDividerHandle: View {
    static let space = "paneArea"
    let divider: PaneDivider
    let size: CGSize
    let model: AppModel
    let panes: PaneLayoutModel
    let theme: Theme

    var body: some View {
        let horizontal = divider.axis == .horizontal
        let line = horizontal
            ? CGRect(x: divider.position - 0.5, y: divider.rect.minY, width: 1, height: divider.rect.height)
            : CGRect(x: divider.rect.minX, y: divider.position - 0.5, width: divider.rect.width, height: 1)
        let grab = line.insetBy(dx: horizontal ? -4 : 0, dy: horizontal ? 0 : -4)
        ZStack {
            theme.line.frame(width: line.width, height: line.height)
            Color.clear
                .frame(width: grab.width, height: grab.height)
                .contentShape(Rectangle())
                .background(ResizeCursorArea(cursor: horizontal ? .resizeLeftRight : .resizeUpDown))
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                    .onChanged { value in update(value.location, save: false) }
                    .onEnded { value in update(value.location, save: true) })
        }
        .frame(width: grab.width, height: grab.height)
        .position(x: grab.midX, y: grab.midY)
    }

    private func update(_ location: CGPoint, save: Bool) {
        let rect = divider.rect
        let proposed = divider.axis == .horizontal
            ? Double((location.x - rect.minX) / max(rect.width, 1))
            : Double((location.y - rect.minY) / max(rect.height, 1))
        let range = panes.layout.ratioRange(at: divider.path, in: size, minPane: PaneLayoutModel.minPane)
        model.setPaneRatio(min(max(proposed, range.lowerBound), range.upperBound), at: divider.path, save: save)
    }
}
