import SwiftUI
import AppKit
import CCDeskCore

/// 右侧面板「文件」页（设计 §28）：搜索框 + 项目文件树。单击选中（目录单击展开 / 收起），双击 / 回车打开，
/// 空格或眼睛按钮快速查看，← / → 收起 / 展开；选中会话改动过的文件与所在目录标小点。
struct ProjectFilesView: View {
    @Environment(\.uiScale) private var uiScale
    @ObservedObject var project: ProjectFilesModel
    let theme: Theme
    let quickLook: (String) -> Void
    let insertIntoTerminal: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let rows = project.rows
        VStack(spacing: 0) {
            searchField
            theme.line.opacity(0.7).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row($0) }
                        if project.tree.truncated { note(L("tree.truncated")) }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .overlay { emptyState(rows: rows) }
                .onChange(of: project.selection) { _, selection in
                    if let selection { proxy.scrollTo(selection) }
                }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { project.moveSelection(by: -1); return .handled }
            .onKeyPress(.downArrow) { project.moveSelection(by: 1); return .handled }
            .onKeyPress(.leftArrow) { project.horizontal(expand: false); return .handled }
            .onKeyPress(.rightArrow) { project.horizontal(expand: true); return .handled }
            .onKeyPress(.space) {
                guard let selection = project.selection, let path = project.absolutePath(selection) else { return .ignored }
                quickLook(path)
                return .handled
            }
            .onKeyPress(.return) {
                guard let selection = project.selection, let entry = rows.first(where: { $0.relativePath == selection })
                else { return .ignored }
                activate(entry)
                return .handled
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").uiFont(size: 10).foregroundStyle(theme.fg3)
            TextField(L("tree.search.placeholder"), text: $project.query)
                .textFieldStyle(.plain)
                .uiFont(size: 11.5)
                .onSubmit {
                    // 搜索框里回车：打开第一个结果。
                    if let first = project.rows.first { activate(first) }
                }
            if project.isSearching {
                Button { project.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").uiFont(size: 11).foregroundStyle(theme.fg3)
                }
                .buttonStyle(.plain)
                .help(L("tree.search.clear"))
            } else if !project.expanded.isEmpty {
                Button { project.collapseAll() } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").uiFont(size: 10).foregroundStyle(theme.fg3)
                }
                .buttonStyle(.plain)
                .help(L("tree.collapseAll"))
            }
            Button { project.reload() } label: {
                Image(systemName: "arrow.clockwise").uiFont(size: 10).foregroundStyle(theme.fg3)
            }
            .buttonStyle(.plain)
            .help(L("tree.reload"))
        }
        .padding(.horizontal, 8)
        .frame(height: uiScale.metric(24))
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.main))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line, lineWidth: 1))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private func row(_ entry: ProjectFileEntry) -> some View {
        let path = project.absolutePath(entry.relativePath) ?? entry.relativePath
        return ProjectFileRow(entry: entry, searching: project.isSearching,
                              expanded: project.expanded.contains(entry.relativePath),
                              selected: project.selection == entry.relativePath,
                              changed: entry.isDirectory ? project.changedDirectories.contains(entry.relativePath)
                                                         : project.changed.contains(entry.relativePath),
                              absolutePath: path, theme: theme,
                              onQuickLook: { quickLook(path) })
            .id(entry.relativePath)
            .onTapGesture(count: 2) {
                project.selection = entry.relativePath
                if !entry.isDirectory { FileActions.open(path) }
            }
            .simultaneousGesture(TapGesture().onEnded {
                project.selection = entry.relativePath
                focused = true
                if entry.isDirectory, !project.isSearching { project.toggle(entry.relativePath) }
            })
            .contextMenu { menu(entry, path: path) }
    }

    @ViewBuilder
    private func menu(_ entry: ProjectFileEntry, path: String) -> some View {
        if !entry.isDirectory {
            Button(L("files.menu.quickLook")) { quickLook(path) }
            Button(L("files.menu.open")) { FileActions.open(path) }
        }
        Button(L("files.menu.reveal")) { FileActions.reveal(path) }
        if Jumper.vsCodeURL != nil {
            Button(L("files.menu.vscode")) { Jumper.openInVSCode(file: path) }
        }
        if project.isSearching {
            Button(L("tree.menu.showInTree")) { project.reveal(entry.relativePath) }
        }
        Divider()
        Button(L("tree.menu.insert")) { insertIntoTerminal(path) }
        Button(L("files.menu.copyPath")) { FileActions.copy(path) }
        Button(L("files.menu.copyRelativePath")) { FileActions.copy(entry.relativePath) }
    }

    private func activate(_ entry: ProjectFileEntry) {
        project.selection = entry.relativePath
        if entry.isDirectory {
            if project.isSearching { project.reveal(entry.relativePath) } else { project.toggle(entry.relativePath) }
        } else if let path = project.absolutePath(entry.relativePath) {
            FileActions.open(path)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .uiFont(size: 10.5)
            .foregroundStyle(theme.fg3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.top, 10)
    }

    @ViewBuilder
    private func emptyState(rows: [ProjectFileEntry]) -> some View {
        if rows.isEmpty {
            let text: String = {
                if project.root == nil { return L("tree.empty.noSession") }
                if project.isTooBroad { return L("tree.empty.tooBroad") }
                if project.loading { return L("tree.empty.loading") }
                if project.isSearching { return L("files.empty.filtered") }
                return L("tree.empty.none")
            }()
            Text(text)
                .uiFont(size: 12)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.fg3)
                .padding(.horizontal, 24)
        }
    }
}

/// 树里的一行：缩进 + 展开箭头（目录）+ 图标 + 名字（+ 搜索时的所在目录）+ 改动小点 / 悬停时的快速查看按钮。
struct ProjectFileRow: View {
    @Environment(\.uiScale) private var uiScale
    let entry: ProjectFileEntry
    let searching: Bool
    let expanded: Bool
    let selected: Bool
    let changed: Bool
    let absolutePath: String
    let theme: Theme
    let onQuickLook: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            if !searching {
                Color.clear.frame(width: CGFloat(entry.depth) * uiScale.metric(14), height: 1)
                Image(systemName: "chevron.right")
                    .uiFont(size: 8.5, weight: .semibold)
                    .foregroundStyle(theme.fg3)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: uiScale.metric(10))
                    .opacity(entry.isDirectory ? 1 : 0)
            }
            Image(nsImage: entry.isDirectory ? FileActions.folderIcon : FileActions.typeIcon(for: entry.name))
                .resizable()
                .frame(width: uiScale.metric(16), height: uiScale.metric(16))
            Text(entry.name)
                .uiFont(size: 12)
                .foregroundStyle(theme.fg1)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if searching, !entry.parent.isEmpty {
                Text(entry.parent)
                    .uiFont(size: 10.5)
                    .foregroundStyle(theme.fg3)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            if hovering, !entry.isDirectory {
                Button(action: onQuickLook) {
                    Image(systemName: "eye").uiFont(size: 10.5).foregroundStyle(theme.fg2).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("files.quickLook.help"))
            } else if changed {
                Circle().fill(theme.unread).frame(width: 6, height: 6)
                    .help(L("tree.changed.help"))
            }
        }
        .padding(.horizontal, 6)
        .frame(height: uiScale.metric(24))
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? theme.sel : (hovering ? theme.hover : .clear)))
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 6).strokeBorder(theme.selLine, lineWidth: 1) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(entry.relativePath)
    }
}
