import Foundation

/// 技能库要扫描的目录（测试里换成临时目录）。
public struct SkillLocations: Sendable {
    public var home: URL
    /// `~/.claude`（skills / commands / agents / plugins / settings.json）。
    public var claudeDir: URL
    /// `~/.agents/skills`。
    public var agentsSkillsDir: URL
    /// `~/.codex/skills`。
    public var codexSkillsDir: URL
    /// `~/.pi/agent/skills`。
    public var piSkillsDir: URL
    /// `~/.cc-desk/agents`。
    public var ccdeskAgentsDir: URL
    /// 侧栏里的项目根目录（扫描 `<root>/.claude/skills` 与 `<root>/.agents/skills`）。
    public var projectRoots: [String]

    public init(home: URL, claudeDir: URL, agentsSkillsDir: URL, codexSkillsDir: URL, piSkillsDir: URL,
                ccdeskAgentsDir: URL, projectRoots: [String]) {
        self.home = home
        self.claudeDir = claudeDir
        self.agentsSkillsDir = agentsSkillsDir
        self.codexSkillsDir = codexSkillsDir
        self.piSkillsDir = piSkillsDir
        self.ccdeskAgentsDir = ccdeskAgentsDir
        self.projectRoots = projectRoots
    }

    /// 以 home 为根的标准位置。
    public static func standard(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                                projectRoots: [String] = []) -> SkillLocations {
        SkillLocations(home: home, claudeDir: home.appendingPathComponent(".claude"),
                       agentsSkillsDir: home.appendingPathComponent(".agents/skills"),
                       codexSkillsDir: home.appendingPathComponent(".codex/skills"),
                       piSkillsDir: home.appendingPathComponent(".pi/agent/skills"),
                       ccdeskAgentsDir: home.appendingPathComponent(".cc-desk/agents"),
                       projectRoots: projectRoots)
    }
}

/// 扫描技能目录（只读：从不写任何文件）。目录不存在、读不了、JSON 坏了都按「没有」处理。
/// 同一个文件经符号链接出现在多处时合并成一项（先扫到的来源为主来源）。
public enum SkillScanner {
    /// frontmatter / 描述只读文件开头这么多字节。
    static let headBytes = 64 * 1024

    public static func scan(_ locations: SkillLocations) -> [SkillEntry] {
        var found: [Found] = []
        let claude = locations.claudeDir
        // Claude 个人：skills（跳过 synced）、commands、agents。
        found += skills(in: claude.appendingPathComponent("skills"), source: .claudeUser, skipping: ["synced"])
        found += files(in: claude.appendingPathComponent("commands"), kind: .command, source: .claudeUser)
        found += files(in: claude.appendingPathComponent("agents"), kind: .agent, source: .claudeUser)
        // claude.ai 同步的技能：synced/<bucket>/<skill>/SKILL.md。
        for bucket in children(of: claude.appendingPathComponent("skills/synced")) where isDirectory(bucket) {
            found += skills(in: bucket, source: .claudeSynced)
        }
        for plugin in plugins(claudeDir: claude) {
            found += skills(in: plugin.root.appendingPathComponent("skills"), source: plugin.source)
            found += files(in: plugin.root.appendingPathComponent("commands"), kind: .command, source: plugin.source)
            found += files(in: plugin.root.appendingPathComponent("agents"), kind: .agent, source: plugin.source)
        }
        var roots: [String] = []
        for root in locations.projectRoots where !root.isEmpty && !roots.contains(root) { roots.append(root) }
        for root in roots {
            let url = URL(fileURLWithPath: root)
            found += skills(in: url.appendingPathComponent(".claude/skills"), source: .claudeProject(root: root))
            found += files(in: url.appendingPathComponent(".claude/commands"), kind: .command,
                           source: .claudeProject(root: root))
            found += files(in: url.appendingPathComponent(".claude/agents"), kind: .agent, source: .claudeProject(root: root))
        }
        found += skills(in: locations.agentsSkillsDir, source: .agentsShared)
        for root in roots {
            found += skills(in: URL(fileURLWithPath: root).appendingPathComponent(".agents/skills"),
                            source: .agentsProject(root: root))
        }
        found += skills(in: locations.codexSkillsDir, source: .codex)
        found += skills(in: locations.codexSkillsDir.appendingPathComponent(".system"), source: .codex)
        found += skills(in: locations.piSkillsDir, source: .pi)
        found += files(in: locations.piSkillsDir, kind: .skill, source: .pi)
        found += ccdeskAgents(in: locations.ccdeskAgentsDir)
        return SkillCatalog.sorted(merge(found))
    }

    // MARK: 发现

    struct Found {
        var name: String
        var title: String?
        var description: String
        var kind: SkillKind
        var sources: [SkillSource]
        var filePath: String
        var folderPath: String?
        var resolved: String
    }

    /// 同一个（解析符号链接后的）文件合并成一项，来源按发现顺序并起来。
    static func merge(_ found: [Found]) -> [SkillEntry] {
        var order: [String] = []
        var byPath: [String: Found] = [:]
        for item in found {
            let key = item.kind.rawValue + "|" + item.resolved
            if var existing = byPath[key] {
                for source in item.sources where !existing.sources.contains(source) { existing.sources.append(source) }
                byPath[key] = existing
            } else {
                order.append(key)
                byPath[key] = item
            }
        }
        return order.compactMap { byPath[$0] }.map {
            SkillEntry(name: $0.name, title: $0.title, description: $0.description, kind: $0.kind, sources: $0.sources,
                       filePath: $0.filePath, folderPath: $0.folderPath, resolvedPath: $0.resolved)
        }
    }

    /// `<dir>/<name>/SKILL.md` 形式的技能（子目录可以是符号链接；没有 SKILL.md 的目录跳过）。
    static func skills(in dir: URL, source: SkillSource, skipping: Set<String> = []) -> [Found] {
        children(of: dir).compactMap { folder in
            guard !skipping.contains(folder.lastPathComponent), isDirectory(folder) else { return nil }
            let file = folder.appendingPathComponent("SKILL.md")
            guard isFile(file) else { return nil }
            let fm = SkillFrontmatter.parse(readHead(file))
            return Found(name: nonEmpty(fm.fields["name"]) ?? folder.lastPathComponent,
                         description: describe(fm), kind: .skill, sources: [source], filePath: file.path,
                         folderPath: folder.path, resolved: file.resolvingSymlinksInPath().path)
        }
    }

    /// 目录下的 `*.md` 单文件条目（命令 / 子 agent / pi 根部的技能）。
    static func files(in dir: URL, kind: SkillKind, source: SkillSource) -> [Found] {
        children(of: dir).compactMap { file in
            guard file.pathExtension.lowercased() == "md", isFile(file) else { return nil }
            let fm = SkillFrontmatter.parse(readHead(file))
            let stem = file.deletingPathExtension().lastPathComponent
            return Found(name: nonEmpty(fm.fields["name"]) ?? stem, description: describe(fm), kind: kind,
                         sources: [source], filePath: file.path, folderPath: nil,
                         resolved: file.resolvingSymlinksInPath().path)
        }
    }

    /// CC Desk 专业 agent：用 `AgentProfileParser` 解析（取 title）；格式不对时退回通用解析。
    static func ccdeskAgents(in dir: URL) -> [Found] {
        children(of: dir).compactMap { file in
            guard file.pathExtension.lowercased() == "md", isFile(file) else { return nil }
            let text = readHead(file)
            let resolved = file.resolvingSymlinksInPath().path
            if case .success(let profile) = AgentProfileParser.parse(text, fileName: file.lastPathComponent) {
                return Found(name: profile.name, title: profile.title == profile.name ? nil : profile.title,
                             description: profile.description, kind: .ccdeskAgent, sources: [.ccdesk],
                             filePath: file.path, folderPath: nil, resolved: resolved)
            }
            let fm = SkillFrontmatter.parse(text)
            return Found(name: nonEmpty(fm.fields["name"]) ?? file.deletingPathExtension().lastPathComponent,
                         title: nonEmpty(fm.fields["title"]), description: describe(fm), kind: .ccdeskAgent,
                         sources: [.ccdesk], filePath: file.path, folderPath: nil, resolved: resolved)
        }
    }

    static func describe(_ fm: SkillFrontmatter) -> String {
        let raw = nonEmpty(fm.fields["description"]) ?? SkillFrontmatter.firstParagraph(fm.body)
        return raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    // MARK: 插件

    struct Plugin {
        let root: URL
        let source: SkillSource
    }

    /// 已安装的插件（`plugins/installed_plugins.json`），每个插件一个安装位置（优先 user 范围）；
    /// 启用状态取自 `settings.json` 的 enabledPlugins（项目范围的安装另看该项目的 `.claude/settings*.json`），没写为停用。
    static func plugins(claudeDir: URL) -> [Plugin] {
        let installed = readJSON(claudeDir.appendingPathComponent("plugins/installed_plugins.json"))
        let table = (installed?["plugins"] as? [String: Any]) ?? installed?.filter { $0.key != "version" } ?? [:]
        let userEnabled = enabledPlugins(claudeDir.appendingPathComponent("settings.json"))
        var result: [Plugin] = []
        for key in table.keys.sorted() {
            let records = (table[key] as? [[String: Any]]) ?? (table[key] as? [String: Any]).map { [$0] } ?? []
            guard let record = records.first(where: { ($0["scope"] as? String ?? "user") == "user" }) ?? records.first,
                  let path = record["installPath"] as? String, isDirectory(URL(fileURLWithPath: path))
            else { continue }
            var enabled = userEnabled[key]
            if enabled == nil, let project = record["projectPath"] as? String {
                let dir = URL(fileURLWithPath: project).appendingPathComponent(".claude")
                enabled = enabledPlugins(dir.appendingPathComponent("settings.local.json"))[key]
                    ?? enabledPlugins(dir.appendingPathComponent("settings.json"))[key]
            }
            let (plugin, marketplace) = splitPluginKey(key)
            let version = (record["version"] as? String).flatMap { $0.isEmpty || $0 == "unknown" ? nil : $0 }
            result.append(Plugin(root: URL(fileURLWithPath: path),
                                 source: .claudePlugin(plugin: plugin, marketplace: marketplace, version: version,
                                                       enabled: enabled ?? false)))
        }
        return result
    }

    /// "name@marketplace" → (name, marketplace)。
    static func splitPluginKey(_ key: String) -> (String, String) {
        guard let at = key.lastIndex(of: "@"), at != key.startIndex else { return (key, "") }
        return (String(key[..<at]), String(key[key.index(after: at)...]))
    }

    static func enabledPlugins(_ settings: URL) -> [String: Bool] {
        guard let table = readJSON(settings)?["enabledPlugins"] as? [String: Any] else { return [:] }
        return table.compactMapValues { $0 as? Bool }
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: 文件系统

    /// 目录的直接子项（不含隐藏项），按名字排序；目录不存在时为空。
    static func children(of dir: URL) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.sorted().map { dir.appendingPathComponent($0) }
    }

    /// 是目录（跟随符号链接；断开的链接为 false）。
    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func isFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// 读文件开头（UTF-8，坏字节替换）；读不了时为空串。
    static func readHead(_ url: URL, limit: Int = headBytes) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// 详情区显示的文件内容（最多 limit 字节，超出时 truncated 为 true）。
    public static func readText(_ path: String, limit: Int = 256 * 1024) -> (text: String, truncated: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1) else { return nil }
        let truncated = data.count > limit
        return (String(decoding: truncated ? data.prefix(limit) : data, as: UTF8.self), truncated)
    }

    /// 技能目录里的文件（相对路径，递归、不含隐藏项、不跟随目录符号链接），最多 limit 个。
    public static func folderFiles(_ folder: String, limit: Int = 200) -> (files: [String], truncated: Bool) {
        // 技能目录本身可能是符号链接：先解析，再列出真实目录里的内容。
        let root = URL(fileURLWithPath: folder).resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], false) }
        var files: [String] = []
        let base = root.path
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true || values?.isSymbolicLink == true else { continue }
            if files.count >= limit { return (files, true) }
            let path = url.path
            files.append(path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent)
        }
        return (files.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, false)
    }
}
