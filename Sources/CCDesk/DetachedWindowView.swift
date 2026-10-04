import SwiftUI
import AppKit
import CCDeskCore

/// 独立窗口的内容（设计 §20.3）：一条小标题条（状态点、会话名、agent · 目录、状态胶囊、「放回主窗口」）
/// + 铺满的终端，配色跟随主题。语音浮层只在这个终端是语音目标（选中）时显示。
struct DetachedWindowView: View {
    @ObservedObject var model: AppModel
    let terminalID: UUID
    let onTitle: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var themes = ThemeStore.shared

    var body: some View {
        let theme = themes.theme(for: colorScheme)
        let row = model.row(forTerminal: terminalID)
        let title = row?.displayName ?? model.pool.terminal(terminalID)?.title ?? ""
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                PaneStatusDot(row: row, theme: theme)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.fg1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let row {
                    let path = row.session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                    Text(row.agentLabel.map { "\($0) · \(path)" } ?? path)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.fg3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 8)
                if let row {
                    StatusPill(status: row.session.status, label: row.statusLabel, missing: false,
                               unread: row.showsUnread, theme: theme)
                }
                SidebarIconButton(systemName: "rectangle.portrait.and.arrow.forward",
                                  help: L("detached.reattach.help"), theme: theme) {
                    model.reattachDetached(terminalID)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 36)
            .background(theme.main)
            .help(row?.tooltip ?? "")
            theme.line.frame(height: 1)
            ZStack {
                DetachedTerminalSlot(model: model, terminalID: terminalID, background: theme.terminal.background)
                if model.selectedTerminalID == terminalID {
                    VoiceOverlay(voice: model.voice, theme: theme)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 16)
                }
            }
            .background(Color(nsColor: theme.terminal.background))
        }
        .onChange(of: title, initial: true) { _, new in onTitle(new) }
    }
}

/// 独立窗口里托管终端视图的容器：只在这个终端确实分离着（`DetachedWindows.contains`）时托管，
/// 否则交出视图（窗口正在关闭、视图已回到主窗口）。
struct DetachedTerminalSlot: NSViewRepresentable {
    let model: AppModel
    let terminalID: UUID
    let background: NSColor

    func makeNSView(context: Context) -> SingleTerminalHostView {
        let view = SingleTerminalHostView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ host: SingleTerminalHostView, context: Context) {
        host.layer?.backgroundColor = background.cgColor
        let owned = model.detachedWindows.contains(terminalID)
        let view = owned ? model.pool.terminal(terminalID)?.view : nil
        let changed = host.host(view)
        if changed, let view {
            DispatchQueue.main.async {
                guard view.superview === host, let window = host.window, window.isKeyWindow else { return }
                window.makeFirstResponder(view)
            }
        }
    }
}

/// 只托管一个终端视图，四周留白铺满。
final class SingleTerminalHostView: NSView {
    static let insets = NSEdgeInsets(top: 12, left: 16, bottom: 14, right: 16)
    private(set) weak var terminalView: NSView?

    /// 托管 `view`（nil 时交出当前视图）；返回是否换了视图。
    @discardableResult
    func host(_ view: NSView?) -> Bool {
        if let current = terminalView, current !== view, current.superview === self {
            current.removeFromSuperview()
        }
        let changed = terminalView !== view || (view != nil && view?.superview !== self)
        terminalView = view
        if let view, view.superview !== self {
            view.removeFromSuperview()
            addSubview(view)
        }
        view?.isHidden = false
        if changed { needsLayout = true }
        return changed
    }

    override func layout() {
        super.layout()
        let insets = Self.insets
        terminalView?.frame = NSRect(x: insets.left, y: insets.bottom,
                                     width: max(0, bounds.width - insets.left - insets.right),
                                     height: max(0, bounds.height - insets.top - insets.bottom))
    }
}
