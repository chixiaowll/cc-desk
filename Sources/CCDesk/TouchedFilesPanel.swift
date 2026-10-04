import SwiftUI
import AppKit
import CCDeskCore

/// 详情区右侧的「改动的文件」面板（设计 §17）：文档与产出在前、代码在后，各自按最后改动时间倒序；
/// 最后是「提到 / 生成的文件」（agent 回复里提到的、命令在项目目录里生成的；文档与图片 / 视频在前）。
/// 单击选中；空格 / 眼睛按钮快速查看；双击 / 回车用默认 App 打开；右键更多动作。查看都交给系统（快速查看、默认 App）。
struct TouchedFilesPanel: View {
    @ObservedObject var files: TouchedFilesModel
    let now: Date
    let theme: Theme
    @FocusState private var focused: Bool
    /// 宿主窗口（快速查看要插到它的响应链里）。
    @State private var window: NSWindow?

    static let width: CGFloat = 300
    static let filterThreshold = 15

    var body: some View {
        let list = files.visibleFiles
        let documents = list.filter { $0.origin == .tool && $0.isDocument }
        let code = list.filter { $0.origin == .tool && !$0.isDocument }
        let extra = list.filter { $0.origin != .tool }
        VStack(spacing: 0) {
            header
            if files.allFiles.count > Self.filterThreshold { filterField }
            theme.line.opacity(0.7).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if !documents.isEmpty {
                            sectionTitle(L("files.section.documents"), count: documents.count)
                            ForEach(documents) { row($0) }
                        }
                        if !code.isEmpty {
                            sectionTitle(L("files.section.code"), count: code.count)
                                .padding(.top, documents.isEmpty ? 0 : 8)
                            ForEach(code) { row($0) }
                        }
                        if !extra.isEmpty {
                            sectionTitle(L("files.section.extra"), count: extra.count)
                                .padding(.top, documents.isEmpty && code.isEmpty ? 0 : 8)
                            ForEach(extra) { row($0) }
                        }
                        if let note = files.watchNote { watchNote(note) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
                .overlay { emptyState(list: list) }
                .onChange(of: files.selection) { _, selection in
                    if let selection { proxy.scrollTo(selection) }
                }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { files.moveSelection(by: -1); return .handled }
            .onKeyPress(.downArrow) { files.moveSelection(by: 1); return .handled }
            .onKeyPress(.space) {
                guard files.selection != nil else { return .ignored }
                files.toggleQuickLook(window: window)
                return .handled
            }
            .onKeyPress(.return) {
                guard let path = files.selection, let file = files.allFiles.first(where: { $0.path == path }), file.exists
                else { return .ignored }
                FileActions.open(path)
                return .handled
            }
        }
        .frame(width: files.panelWidth)
        .background(theme.side)
        .background(WindowReader(window: $window))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(L("files.title"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.fg1)
            if !files.allFiles.isEmpty {
                Text("\(files.allFiles.count)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.fg2)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Capsule().fill(theme.chip))
            }
            Spacer(minLength: 0)
            Button {
                files.toggleQuickLook(window: window)
            } label: {
                Image(systemName: "eye").font(.system(size: 12))
                    .foregroundStyle(files.selection == nil ? theme.fg3 : theme.fg2)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(files.selection == nil)
            .help(L("files.quickLook.help"))
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { files.isShown = false }
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.fg2)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("files.collapse.help"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 36)
    }

    private var filterField: some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)).foregroundStyle(theme.fg3)
            TextField(L("files.filter.placeholder"), text: $files.filter)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.main))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line, lineWidth: 1))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        Text("\(title) · \(count)")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(theme.fg3)
            .padding(.leading, 6)
            .padding(.vertical, 4)
    }

    /// 项目监视没开时的说明（列表末尾的小字）。
    private func watchNote(_ note: TouchedFilesModel.WatchNote) -> some View {
        Text(note == .tooBroad ? L("files.watch.tooBroad") : L("files.watch.failed"))
            .font(.system(size: 10.5))
            .foregroundStyle(theme.fg3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
            .padding(.top, 10)
    }

    private func row(_ file: TouchedFile) -> some View {
        TouchedFileRow(file: file, directory: files.displayDirectory(file), selected: files.selection == file.path,
                       now: now, theme: theme,
                       onQuickLook: { files.toggleQuickLook(file.path, window: window) })
            .id(file.path)
            .onTapGesture(count: 2) {
                files.selection = file.path
                if file.exists { FileActions.open(file.path) }
            }
            .simultaneousGesture(TapGesture().onEnded {
                files.selection = file.path
                focused = true
            })
            .contextMenu { TouchedFileMenu(file: file, relativePath: files.relativePath(file),
                                           quickLook: { files.toggleQuickLook(file.path, window: window) }) }
    }

    @ViewBuilder
    private func emptyState(list: [TouchedFile]) -> some View {
        if list.isEmpty {
            let text: String = {
                if !files.allFiles.isEmpty { return L("files.empty.filtered") }
                switch files.phase {
                case .noSession: return L("files.empty.noSession")
                case .locating: return L("files.empty.loading")
                case .notFound: return L("files.empty.notFound")
                case .loaded: return L("files.empty.none")
                }
            }()
            Text(text)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.fg3)
                .padding(.horizontal, 24)
        }
    }
}

/// 一行：图标 + 文件名 + 徽标 + 时间；第二行是所在目录（淡色，见 `TouchedFiles.displayDirectory`）。
struct TouchedFileRow: View {
    let file: TouchedFile
    let directory: String
    let selected: Bool
    let now: Date
    let theme: Theme
    let onQuickLook: () -> Void
    @State private var hovering = false

    private var background: Color {
        if selected { return theme.sel }
        if hovering { return theme.hover }
        return .clear
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: FileActions.icon(for: file.path, exists: file.exists))
                .resizable()
                .frame(width: 20, height: 20)
                .opacity(file.exists ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(file.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(file.exists ? theme.fg1 : theme.fg3)
                        .strikethrough(file.action == .deleted, color: theme.fg3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    badge
                    Spacer(minLength: 0)
                    if (hovering || selected) && file.exists {
                        Button(action: onQuickLook) {
                            Image(systemName: "eye").font(.system(size: 11)).foregroundStyle(theme.fg2)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L("files.quickLook.help"))
                    } else if let last = file.lastTouched {
                        Text(RelativeTime.short(from: last, now: now))
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(theme.fg3)
                    }
                }
                .frame(height: 16)
                Text(directory)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.fg3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(height: 14)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(background))
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 7).strokeBorder(theme.selLine, lineWidth: 1) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(file.path)
    }

    /// 徽标：新 / 已改 / 已删除；生成的新文件「生成」，提到的「提到」；文件已不在时显示「不存在」。
    private var badgeStyle: (text: String, bg: Color, fg: Color) {
        if file.action == .deleted { return (L("files.badge.deleted"), theme.pillMissBg, theme.pillMissFg) }
        if !file.exists { return (L("files.badge.missing"), theme.pillMissBg, theme.pillMissFg) }
        if file.origin == .mentioned { return (L("files.badge.mentioned"), theme.pillIdleBg, theme.pillIdleFg) }
        if file.origin == .generated, file.action == .created {
            return (L("files.badge.generated"), theme.chipUnreadBg.opacity(0.16), theme.unread)
        }
        if file.action == .created { return (L("files.badge.new"), theme.chipUnreadBg.opacity(0.16), theme.unread) }
        return (L("files.badge.modified"), theme.pillIdleBg, theme.pillIdleFg)
    }

    private var badge: some View {
        let style = badgeStyle
        return Text(style.text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(style.fg)
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(Capsule().fill(style.bg))
            .fixedSize()
    }
}

/// 右键菜单。已删除 / 不存在的文件只能复制路径。
struct TouchedFileMenu: View {
    let file: TouchedFile
    let relativePath: String
    let quickLook: () -> Void

    var body: some View {
        if file.exists {
            Button(L("files.menu.quickLook"), action: quickLook)
            Button(L("files.menu.open")) { FileActions.open(file.path) }
            Button(L("files.menu.reveal")) { FileActions.reveal(file.path) }
            if Jumper.vsCodeURL != nil {
                Button(L("files.menu.vscode")) { Jumper.openInVSCode(file: file.path) }
            }
            Divider()
        }
        Button(L("files.menu.copyPath")) { FileActions.copy(file.path) }
        if file.exists {
            Button(L("files.menu.copyRelativePath")) { FileActions.copy(relativePath) }
        }
    }
}

/// 标题栏里的面板开关：线条图标（与标题栏其他控件同一字重 / 字号，fg2），打开时加一层浅底表示选中；
/// 选中会话新建了没看过的文档时右上角显示陶土色小圆点。
struct TouchedFilesToggle: View {
    @ObservedObject var files: TouchedFilesModel
    let theme: Theme
    @State private var hovering = false

    var body: some View {
        Button {
            files.isShown.toggle()
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(files.isShown || hovering ? theme.fg1 : theme.fg2)
                .frame(width: 28, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(background))
                .overlay(alignment: .topTrailing) {
                    if files.hasUnseenDocument && !files.isShown {
                        Circle().fill(theme.accent).frame(width: 6, height: 6).offset(x: -3, y: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(files.hasUnseenDocument ? L("files.toggle.newHelp") : L("files.toggle.help"))
    }

    private var background: Color {
        if files.isShown { return theme.chip }
        return hovering ? theme.hover : .clear
    }
}

/// 取得 SwiftUI 视图所在的 NSWindow。
struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    final class Probe: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.onWindow = { w in DispatchQueue.main.async { if window !== w { window = w } } }
        return view
    }

    func updateNSView(_ nsView: Probe, context: Context) {}
}
