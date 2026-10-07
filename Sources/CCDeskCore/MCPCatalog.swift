import Foundation

/// MCP 一览（设计 §31）：只读汇总本机各 agent 配置的 MCP 服务器。配置里常有密钥，所以这里只留下
/// 名字、传输方式、命令 / 地址（打码）、环境变量与请求头的「名字」，从不保留它们的值。

public enum MCPTransport: String, Equatable, Sendable {
    case stdio, http, sse

    public var label: String {
        switch self {
        case .stdio: return "stdio"
        case .http: return "HTTP"
        case .sse: return "SSE"
        }
    }
}

/// 配置来自哪里。
public enum MCPSource: Equatable, Hashable, Sendable {
    /// Claude Code 用户范围（~/.claude.json 顶层 mcpServers）。
    case claudeUser
    /// Claude Code 本地范围（~/.claude.json 里某个项目的 mcpServers，只在该目录生效）。
    case claudeLocal(project: String)
    /// 项目里的 .mcp.json（团队共享，Claude Code 读）。
    case claudeProject(project: String)
    /// Claude Code 插件自带的 MCP。
    case claudePlugin(plugin: String, enabled: Bool)
    /// claude.ai 账号里加的连接器（只能从 `claude mcp list` 得知）。
    case claudeConnector
    /// Codex（~/.codex/config.toml 的 [mcp_servers.*]）。
    case codex
    /// OpenCode 全局配置（~/.config/opencode/opencode.json[c] 的 mcp）。
    case openCodeGlobal
    /// OpenCode 项目配置（项目里的 opencode.json[c]）。
    case openCodeProject(project: String)

    public var agent: AgentKind {
        switch self {
        case .claudeUser, .claudeLocal, .claudeProject, .claudePlugin, .claudeConnector: return .claude
        case .codex: return .codex
        case .openCodeGlobal, .openCodeProject: return .opencode
        }
    }

    /// 列表分组用的键（同一来源一组；项目按目录分开）。
    public var groupID: String {
        switch self {
        case .claudeUser: return "claude-user"
        case .claudeLocal(let p): return "claude-local:" + p
        case .claudeProject(let p): return "claude-project:" + p
        case .claudePlugin: return "claude-plugin"
        case .claudeConnector: return "claude-connector"
        case .codex: return "codex"
        case .openCodeGlobal: return "opencode"
        case .openCodeProject(let p): return "opencode-project:" + p
        }
    }

    public var title: String {
        func short(_ p: String) -> String { (p as NSString).lastPathComponent }
        switch self {
        case .claudeUser: return L("mcp.source.claudeUser")
        case .claudeLocal(let p): return L("mcp.source.claudeLocal", short(p))
        case .claudeProject(let p): return L("mcp.source.claudeProject", short(p))
        case .claudePlugin: return L("mcp.source.claudePlugin")
        case .claudeConnector: return L("mcp.source.claudeConnector")
        case .codex: return "Codex"
        case .openCodeGlobal: return "OpenCode"
        case .openCodeProject(let p): return L("mcp.source.openCodeProject", short(p))
        }
    }
}

/// `claude mcp list` 报告的连接状态。
public enum MCPHealth: Equatable, Sendable {
    case connected
    case needsAuth
    case failed(String)
    case unknown(String)
}

public struct MCPServerEntry: Equatable, Identifiable, Sendable {
    public let name: String
    public let source: MCPSource
    public let transport: MCPTransport
    /// stdio：命令与参数（参数里像密钥的已打码）。
    public let command: String?
    public let args: [String]
    /// http / sse：地址（查询参数的值已打码）。
    public let url: String?
    public let envKeys: [String]
    public let headerKeys: [String]
    /// 配置里明确停用（Codex `enabled = false`、OpenCode `enabled: false`、插件停用）。
    public let enabled: Bool
    /// 配置文件（连接器为 nil）。
    public let configPath: String?
    public var health: MCPHealth?

    public var id: String { source.groupID + "/" + name }

    public init(name: String, source: MCPSource, transport: MCPTransport, command: String? = nil, args: [String] = [],
                url: String? = nil, envKeys: [String] = [], headerKeys: [String] = [], enabled: Bool = true,
                configPath: String? = nil, health: MCPHealth? = nil) {
        self.name = name
        self.source = source
        self.transport = transport
        self.command = command
        self.args = args
        self.url = url
        self.envKeys = envKeys
        self.headerKeys = headerKeys
        self.enabled = enabled
        self.configPath = configPath
        self.health = health
    }

    /// 列表第二行：命令行或地址。
    public var summary: String {
        if let url { return url }
        return ([command].compactMap { $0 } + args).joined(separator: " ")
    }
}

public enum MCPCatalog {
    // MARK: 打码

    static let secretWords = ["key", "token", "secret", "password", "passwd", "auth", "bearer", "credential", "cookie", "sig"]

    static func looksSecretName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return secretWords.contains { lower.contains($0) }
    }

    /// 长得像密钥的值：sk-… / ghp_… / xox… / 很长的字母数字串。
    static func looksSecretValue(_ value: String) -> Bool {
        let prefixes = ["sk-", "sk_", "ghp_", "gho_", "github_pat_", "xoxb-", "xoxp-", "AKIA", "AIza", "glpat-", "pk_", "rk_"]
        if prefixes.contains(where: value.hasPrefix) { return true }
        let core = value.filter { $0.isLetter || $0.isNumber }
        return value.count >= 24 && !value.contains("/") && !value.contains(".") && Double(core.count) / Double(value.count) > 0.85
            && value.contains(where: \.isNumber) && value.contains(where: \.isLetter)
    }

    static let mask = "••••"

    /// 参数打码：`--api-key xxx` / `--token=xxx` / `KEY=xxx` 的值，以及本身像密钥的参数。
    public static func maskArgs(_ args: [String]) -> [String] {
        var out: [String] = []
        var hideNext = false
        for arg in args {
            if hideNext {
                out.append(mask)
                hideNext = false
                continue
            }
            if let eq = arg.firstIndex(of: "="), looksSecretName(String(arg[..<eq])) {
                out.append(String(arg[...eq]) + mask)
            } else if arg.hasPrefix("-"), looksSecretName(arg) {
                out.append(arg)
                hideNext = true
            } else if looksSecretValue(arg) {
                out.append(mask)
            } else {
                out.append(maskURL(arg))
            }
        }
        return out
    }

    /// 地址打码：查询参数的值、用户名密码。
    public static func maskURL(_ s: String) -> String {
        guard s.contains("://"), let parts = URLComponents(string: s), let scheme = parts.scheme, let host = parts.host
        else { return s }
        var out = scheme + "://"
        if parts.user != nil || parts.password != nil {
            out += mask + (parts.password != nil ? ":" + mask : "") + "@"
        }
        out += host
        if let port = parts.port { out += ":\(port)" }
        let segments = parts.path.split(separator: "/", omittingEmptySubsequences: false)
            .map { looksSecretValue(String($0)) ? mask : String($0) }
        out += segments.joined(separator: "/")
        if let items = parts.queryItems, !items.isEmpty {
            out += "?" + items.map { "\($0.name)=\(mask)" }.joined(separator: "&")
        }
        return out
    }

    // MARK: Claude Code

    /// 一个 mcpServers 表（~/.claude.json、.mcp.json、插件）。
    public static func claudeServers(_ table: [String: Any], source: MCPSource, configPath: String) -> [MCPServerEntry] {
        table.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { name in
            guard let s = table[name] as? [String: Any] else { return nil }
            let type = (s["type"] as? String)?.lowercased()
            let url = s["url"] as? String
            let transport: MCPTransport = type == "sse" ? .sse : (type == "http" || (type == nil && url != nil) ? .http : .stdio)
            let enabled: Bool
            if case .claudePlugin(_, let on) = source { enabled = on } else { enabled = true }
            return MCPServerEntry(
                name: name, source: source, transport: transport,
                command: transport == .stdio ? s["command"] as? String : nil,
                args: transport == .stdio ? maskArgs((s["args"] as? [Any] ?? []).compactMap { $0 as? String }) : [],
                url: transport == .stdio ? nil : url.map(maskURL),
                envKeys: ((s["env"] as? [String: Any]) ?? [:]).keys.sorted(),
                headerKeys: ((s["headers"] as? [String: Any]) ?? [:]).keys.sorted(),
                enabled: enabled, configPath: configPath)
        }
    }

    /// ~/.claude.json：顶层 mcpServers（用户范围）+ projects[目录].mcpServers（本地范围）。
    public static func claudeConfig(_ root: [String: Any], path: String) -> [MCPServerEntry] {
        var out = claudeServers((root["mcpServers"] as? [String: Any]) ?? [:], source: .claudeUser, configPath: path)
        let projects = (root["projects"] as? [String: Any]) ?? [:]
        for dir in projects.keys.sorted() {
            guard let p = projects[dir] as? [String: Any], let servers = p["mcpServers"] as? [String: Any], !servers.isEmpty
            else { continue }
            out += claudeServers(servers, source: .claudeLocal(project: dir), configPath: path)
        }
        return out
    }

    /// `claude mcp list` 的输出：每行 `名字: 目标 - 状态`（claude.ai 连接器的名字以「claude.ai 」开头）。
    public static func parseClaudeList(_ output: String) -> [(name: String, target: String, health: MCPHealth)] {
        output.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            guard let colon = line.range(of: ": "), let dash = line.range(of: " - ", options: .backwards),
                  colon.upperBound <= dash.lowerBound else { return nil }
            let name = String(line[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
            let target = String(line[colon.upperBound..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            let status = String(line[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.hasPrefix("Checking") else { return nil }
            let health: MCPHealth
            if status.contains("Connected") { health = .connected }
            else if status.localizedCaseInsensitiveContains("auth") { health = .needsAuth }
            else if status.contains("Failed") || status.hasPrefix("✘") {
                let detail = status.replacingOccurrences(of: "✘", with: "")
                    .replacingOccurrences(of: "Failed to connect", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " —-"))
                health = .failed(detail)
            } else { health = .unknown(status) }
            return (name, target, health)
        }
    }

    /// 把 `claude mcp list` 的结果合进 Claude 的条目：同名的补上状态；本地没有的「claude.ai …」作为连接器加入。
    public static func merge(claudeList: [(name: String, target: String, health: MCPHealth)],
                             into entries: [MCPServerEntry]) -> [MCPServerEntry] {
        var out = entries
        for item in claudeList {
            if item.name.hasPrefix("claude.ai ") {
                let name = String(item.name.dropFirst("claude.ai ".count))
                let url = maskURL(item.target)
                if let i = out.firstIndex(where: { $0.source == .claudeConnector && $0.name == name }) {
                    out[i].health = item.health
                } else {
                    out.append(MCPServerEntry(name: name, source: .claudeConnector,
                                              transport: item.target.hasSuffix("/sse") ? .sse : .http,
                                              url: url, health: item.health))
                }
                continue
            }
            for i in out.indices where out[i].source.agent == .claude && out[i].name == item.name {
                out[i].health = item.health
            }
        }
        return out
    }

    // MARK: Codex

    /// config.toml 里的 [mcp_servers.<名字>]。整份配置可能有解析器不支持的写法，所以只截出这些表单独解析。
    public static func codexServers(_ text: String, path: String) -> [MCPServerEntry] {
        var sections: [(name: String, body: String)] = []
        var current: (name: String, lines: [String])?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                if let c = current { sections.append((c.name, c.lines.joined(separator: "\n"))) }
                current = nil
                if line.hasPrefix("[mcp_servers."), line.hasSuffix("]"), !line.hasPrefix("[[") {
                    var name = String(line.dropFirst("[mcp_servers.".count).dropLast())
                    // [mcp_servers.x.env] 这类子表：并到 x 下（只用来取键名）。
                    if name.hasPrefix("\"") , let end = name.dropFirst().firstIndex(of: "\"") {
                        name = String(name[name.index(after: name.startIndex)..<end])
                        current = (name, [])
                    } else if let dot = name.firstIndex(of: ".") {
                        let parent = String(name[..<dot])
                        let sub = String(name[name.index(after: dot)...])
                        current = (parent, ["[\(sub)]"])
                    } else {
                        current = (name, [])
                    }
                }
                continue
            }
            current?.lines.append(raw)
        }
        if let c = current { sections.append((c.name, c.lines.joined(separator: "\n"))) }
        var merged: [String: String] = [:]
        var order: [String] = []
        for s in sections {
            if merged[s.name] == nil { order.append(s.name) }
            merged[s.name, default: ""] += "\n" + s.body
        }
        return order.compactMap { name in
            guard let body = merged[name], let t = try? MiniTOML.parse(body) else { return nil }
            let url = t["url"]?.stringValue
            let env = (t["env"]?.tableValue?.keys.sorted() ?? []) + (t["env_vars"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let headers = (t["http_headers"]?.tableValue?.keys.sorted() ?? [])
                + (t["env_http_headers"]?.tableValue?.keys.sorted() ?? [])
            return MCPServerEntry(
                name: name, source: .codex, transport: url == nil ? .stdio : .http,
                command: t["command"]?.stringValue,
                args: maskArgs(t["args"]?.arrayValue?.compactMap(\.stringValue) ?? []),
                url: url.map(maskURL), envKeys: env, headerKeys: headers,
                enabled: t["enabled"]?.boolValue ?? true, configPath: path)
        }
    }

    // MARK: OpenCode

    /// opencode.json[c] 的 mcp：`{名字: {type: "local", command: [...], environment} | {type: "remote", url, headers}}`。
    public static func openCodeServers(_ root: [String: Any], source: MCPSource, path: String) -> [MCPServerEntry] {
        let table = (root["mcp"] as? [String: Any]) ?? [:]
        return table.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { name in
            guard let s = table[name] as? [String: Any] else { return nil }
            let remote = (s["type"] as? String) == "remote" || s["url"] != nil
            let command = (s["command"] as? [Any] ?? []).compactMap { $0 as? String }
            return MCPServerEntry(
                name: name, source: source, transport: remote ? .http : .stdio,
                command: remote ? nil : command.first, args: remote ? [] : maskArgs(Array(command.dropFirst())),
                url: remote ? (s["url"] as? String).map(maskURL) : nil,
                envKeys: ((s["environment"] as? [String: Any]) ?? [:]).keys.sorted(),
                headerKeys: ((s["headers"] as? [String: Any]) ?? [:]).keys.sorted(),
                enabled: s["enabled"] as? Bool ?? true, configPath: path)
        }
    }

    /// JSONC → JSON：去掉 // 与 /* */ 注释（字符串里的不动）和对象 / 数组末尾多余的逗号。
    public static func stripJSONC(_ text: String) -> String {
        var out = ""
        var chars = Array(text)
        var i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < chars.count { out.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            out.append(c)
            i += 1
        }
        // 末尾逗号：「, 」后面紧跟 } 或 ]。
        chars = Array(out)
        var result = ""
        inString = false
        i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                result.append(c)
                if c == "\\", i + 1 < chars.count { result.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true }
            if c == "," {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" { i += 1; continue }
            }
            result.append(c)
            i += 1
        }
        return result
    }

    // MARK: 过滤

    public static func filter(_ entries: [MCPServerEntry], query: String, agent: AgentKind?) -> [MCPServerEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return entries.filter { e in
            if let agent, e.source.agent != agent { return false }
            let hay = (e.name + " " + e.summary + " " + e.source.title).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }
}

/// 读本机配置文件（只读）。`claude mcp list`（连接器与连接状态）要起子进程、联网，由 App 层另行调用后 `merge`。
public enum MCPScanner {
    public struct Locations: Sendable {
        public var home: URL
        public var projectRoots: [String]

        public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), projectRoots: [String] = []) {
            self.home = home
            self.projectRoots = projectRoots
        }
    }

    public static func scan(_ loc: Locations) -> [MCPServerEntry] {
        var out: [MCPServerEntry] = []
        let claudeJSON = loc.home.appendingPathComponent(".claude.json")
        if let root = readJSON(claudeJSON) { out += MCPCatalog.claudeConfig(root, path: claudeJSON.path) }
        for project in loc.projectRoots.sorted() {
            let file = URL(fileURLWithPath: project).appendingPathComponent(".mcp.json")
            if let root = readJSON(file) {
                out += MCPCatalog.claudeServers((root["mcpServers"] as? [String: Any]) ?? [:],
                                                source: .claudeProject(project: project), configPath: file.path)
            }
        }
        for plugin in SkillScanner.plugins(claudeDir: loc.home.appendingPathComponent(".claude")) {
            guard case .claudePlugin(let name, _, _, let enabled) = plugin.source else { continue }
            let source = MCPSource.claudePlugin(plugin: name, enabled: enabled)
            let mcpFile = plugin.root.appendingPathComponent(".mcp.json")
            if let root = readJSON(mcpFile) {
                let table = (root["mcpServers"] as? [String: Any]) ?? root
                out += MCPCatalog.claudeServers(table, source: source, configPath: mcpFile.path)
            }
            let manifest = plugin.root.appendingPathComponent(".claude-plugin/plugin.json")
            if let table = readJSON(manifest)?["mcpServers"] as? [String: Any] {
                out += MCPCatalog.claudeServers(table, source: source, configPath: manifest.path)
            }
        }
        let codex = loc.home.appendingPathComponent(".codex/config.toml")
        if let text = try? String(contentsOf: codex, encoding: .utf8) { out += MCPCatalog.codexServers(text, path: codex.path) }
        for name in ["opencode.json", "opencode.jsonc", "config.json"] {
            let file = loc.home.appendingPathComponent(".config/opencode/\(name)")
            if let root = readJSONC(file) { out += MCPCatalog.openCodeServers(root, source: .openCodeGlobal, path: file.path) }
        }
        for project in loc.projectRoots.sorted() {
            for name in ["opencode.json", "opencode.jsonc"] {
                let file = URL(fileURLWithPath: project).appendingPathComponent(name)
                if let root = readJSONC(file) {
                    out += MCPCatalog.openCodeServers(root, source: .openCodeProject(project: project), path: file.path)
                }
            }
        }
        return out
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func readJSONC(_ url: URL) -> [String: Any]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(MCPCatalog.stripJSONC(text).utf8))) as? [String: Any]
    }
}

/// 「移到全局」（设计 §31.1）：从原配置里取出某个 Claude MCP 的完整配置（含密钥，只交给 `claude mcp add-json`，
/// 不显示、不记日志）。只支持 Claude 的本地范围与项目范围。
public enum MCPPromotion {
    public static func canPromote(_ entry: MCPServerEntry) -> Bool {
        switch entry.source {
        case .claudeLocal, .claudeProject: return true
        default: return false
        }
    }

    /// 本地范围可以删掉原配置；项目范围的 .mcp.json 是团队共享文件，只复制。
    public static func canRemoveOriginal(_ entry: MCPServerEntry) -> Bool {
        if case .claudeLocal = entry.source { return true }
        return false
    }

    /// 原始配置（JSON 对象）；找不到时为 nil。
    public static func rawConfig(for entry: MCPServerEntry, home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [String: Any]? {
        switch entry.source {
        case .claudeLocal(let project):
            let root = MCPScanner.readJSON(home.appendingPathComponent(".claude.json"))
            let projects = root?["projects"] as? [String: Any]
            let servers = (projects?[project] as? [String: Any])?["mcpServers"] as? [String: Any]
            return servers?[entry.name] as? [String: Any]
        case .claudeProject(let project):
            let root = MCPScanner.readJSON(URL(fileURLWithPath: project).appendingPathComponent(".mcp.json"))
            return (root?["mcpServers"] as? [String: Any])?[entry.name] as? [String: Any]
        default:
            return nil
        }
    }

    /// 全局（用户范围）里是否已有同名 MCP。
    public static func existsInUserScope(_ name: String, home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Bool {
        let root = MCPScanner.readJSON(home.appendingPathComponent(".claude.json"))
        return (root?["mcpServers"] as? [String: Any])?[name] != nil
    }

    /// `claude mcp add-json -s user <名字> <json>` 的参数。
    public static func addArguments(name: String, config: [String: Any]) -> [String]? {
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return ["mcp", "add-json", "-s", "user", name, String(decoding: data, as: UTF8.self)]
    }

    /// 删除本地范围的那份：在原项目目录下 `claude mcp remove -s local <名字>`。
    public static func removeArguments(name: String) -> [String] {
        ["mcp", "remove", "-s", "local", name]
    }
}
