import SwiftUI
import AppKit
import CCDeskCore

/// 技能库右侧的详情：名字、描述、来源与路径、目录里的文件、文件内容（等宽纯文本），以及打开 / 显示 / 复制 / 快速查看。
struct SkillDetailView: View {
    let entry: SkillEntry
    let library: SkillLibrary
    let theme: Theme
    @State private var content: String?
    @State private var truncated = false
    @State private var files: [String] = []
    @State private var filesTruncated = false

    private var home: String { NSHomeDirectory() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.displayName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.fg1)
                        .textSelection(.enabled)
                    if entry.title != nil {
                        Text(entry.name).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(theme.fg3)
                    }
                    SkillBadges(entry: entry, theme: theme).padding(.top, 2)
                }
                if !entry.description.isEmpty {
                    Text(entry.description)
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.fg2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                info
                actions
                if entry.folderPath != nil, !files.isEmpty { fileList }
                contentView
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: entry.id) { await load() }
    }

    private var info: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                label(L("skills.detail.source"))
                Text(entry.sources.map(\.sectionTitle).joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(theme.fg1)
            }
            GridRow {
                label(L("skills.detail.path"))
                Text(SkillCatalog.tildePath(entry.filePath, home: home))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.fg1)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(theme.fg3).gridColumnAlignment(.trailing)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { FileActions.open(entry.filePath) } label: { Label(L("skills.action.open"), systemImage: "pencil") }
            Button { FileActions.reveal(entry.folderPath ?? entry.filePath) } label: {
                Label(L("skills.action.reveal"), systemImage: "folder")
            }
            Button { FileActions.copy(entry.filePath) } label: { Label(L("skills.action.copyPath"), systemImage: "doc.on.doc") }
            Button { library.quickLook(entry.filePath) } label: { Label(L("skills.action.quickLook"), systemImage: "eye") }
        }
        .controlSize(.small)
    }

    /// 目录里的文件：单击快速查看，双击用默认 App 打开（会直接运行的文件改为在访达中显示）。
    private var fileList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("skills.detail.files", files.count) + (filesTruncated ? "+" : ""))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.fg2)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(files, id: \.self) { file in
                    SkillFileRow(relative: file, folder: entry.folderPath ?? "", library: library, theme: theme)
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.side))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var contentView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.filePath.split(separator: "/").last.map(String.init) ?? "")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.fg2)
            Group {
                if let content {
                    Text(content + (truncated ? "\n\n" + L("skills.detail.truncated") : ""))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(theme.fg1)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.side))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line, lineWidth: 1))
        }
    }

    /// 后台读文件内容与目录列表。
    private func load() async {
        let path = entry.filePath
        let folder = entry.folderPath
        let loaded = await Task.detached(priority: .userInitiated) { () -> (String, Bool, [String], Bool) in
            let text = SkillScanner.readText(path)
            let listing: (files: [String], truncated: Bool) = folder.map { SkillScanner.folderFiles($0) } ?? ([], false)
            return (text?.text ?? L("skills.detail.unreadable"), text?.truncated ?? false, listing.files, listing.truncated)
        }.value
        content = loaded.0
        truncated = loaded.1
        files = loaded.2
        filesTruncated = loaded.3
    }
}

/// 技能目录里的一个文件。
struct SkillFileRow: View {
    let relative: String
    let folder: String
    let library: SkillLibrary
    let theme: Theme
    @State private var hovering = false

    private var path: String { (folder as NSString).appendingPathComponent(relative) }

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: FileActions.icon(for: path, exists: true))
                .resizable()
                .frame(width: 14, height: 14)
            Text(relative)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(theme.fg1)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? theme.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { FileActions.open(path) }
        .onTapGesture { library.quickLook(path) }
        .help(L("skills.detail.fileHelp"))
    }
}

// MARK: - 显示文案

extension SkillSource {
    /// 分区标题。
    var sectionTitle: String {
        switch self {
        case .claudeUser: return L("skills.section.claudeUser")
        case .claudeSynced: return L("skills.section.claudeSynced")
        case .claudePlugin(let plugin, _, _, _): return L("skills.section.plugin", plugin)
        case .claudeProject(let root): return L("skills.section.project", (root as NSString).lastPathComponent)
        case .agentsShared: return L("skills.section.agentsShared")
        case .agentsProject(let root): return L("skills.section.agentsProject", (root as NSString).lastPathComponent)
        case .codex: return "Codex"
        case .pi: return "pi"
        case .ccdesk: return L("skills.section.ccdesk")
        }
    }

    /// 分区标题后的灰字：目录 / 市场与版本。
    var sectionDetail: String {
        let home = NSHomeDirectory()
        switch self {
        case .claudeUser: return "~/.claude"
        case .claudeSynced: return "~/.claude/skills/synced"
        case .claudePlugin(_, let marketplace, let version, _):
            return [marketplace, version.map { "v\($0)" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case .claudeProject(let root): return SkillCatalog.tildePath(root, home: home) + "/.claude"
        case .agentsShared: return "~/.agents/skills"
        case .agentsProject(let root): return SkillCatalog.tildePath(root, home: home) + "/.agents/skills"
        case .codex: return "~/.codex/skills"
        case .pi: return "~/.pi/agent/skills"
        case .ccdesk: return "~/.cc-desk/agents"
        }
    }

    /// 行上的来源徽章。
    var badge: String {
        switch self {
        case .claudeUser: return L("skills.badge.personal")
        case .claudeSynced: return L("skills.badge.synced")
        case .claudePlugin(let plugin, _, _, _): return plugin
        case .claudeProject, .agentsProject: return L("skills.badge.project")
        case .agentsShared: return L("skills.badge.shared")
        case .codex: return "Codex"
        case .pi: return "pi"
        case .ccdesk: return L("skills.badge.ccdesk")
        }
    }
}

extension SkillKind {
    /// 种类徽章（技能本身不加）。
    var badge: String? {
        switch self {
        case .skill, .ccdeskAgent: return nil
        case .command: return L("skills.badge.command")
        case .agent: return L("skills.badge.agent")
        }
    }
}
