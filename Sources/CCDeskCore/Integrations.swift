import Foundation

/// 状态集成（Codex hook / pi 扩展）的安装状态。
public enum IntegrationStatus: Equatable, Sendable {
    /// 本机没有该 agent 的配置目录（未安装或从未运行过）。
    case agentMissing
    case notInstalled
    case installed
    /// 部分安装或文件已过期，原因见附带文字；可重新安装修复。
    case needsRepair(String)

    public var label: String {
        switch self {
        case .agentMissing: return "未检测到"
        case .notInstalled: return "未安装"
        case .installed: return "已安装"
        case .needsRepair(let why): return "需要修复：\(why)"
        }
    }
}

public struct IntegrationError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// 安装记录 `~/.cc-desk/integrations.json`：记下安装时改动了什么，卸载时只还原这些改动。
struct IntegrationLedger: Codable, Equatable {
    struct Codex: Codable, Equatable {
        /// 安装前 `[features]` 下 hooks 键的原始行；nil 表示原本没有该键。
        var previousHooksLine: String?
        /// `[features]` 表是否由 CC Desk 新建。
        var createdFeaturesTable: Bool
        /// config.toml 是否被 CC Desk 改动过（原本已是 hooks = true 时为 false）。
        var changedConfig: Bool
        /// hooks.json 是否由 CC Desk 新建。
        var createdHooksFile: Bool
    }
    var codex: Codex?

    static func load(_ url: URL) -> IntegrationLedger {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(IntegrationLedger.self, from: data) else { return IntegrationLedger() }
        return ledger
    }

    func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

enum IntegrationFiles {
    /// 原子写入；已有文件时沿用其权限（如 config.toml 的 0600），不因重写而放宽。
    static func write(_ data: Data, to url: URL, executable: Bool = false) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let previous = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
        try data.write(to: url, options: .atomic)
        if executable {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } else if let previous {
            try fm.setAttributes([.posixPermissions: previous], ofItemAtPath: url.path)
        }
    }

    static func write(_ text: String, to url: URL, executable: Bool = false) throws {
        try write(Data(text.utf8), to: url, executable: executable)
    }

    /// 修改前备份为 `<文件>.cc-desk.bak`（覆盖旧备份）。文件不存在时不备份。
    static func backup(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let bak = URL(fileURLWithPath: url.path + ".cc-desk.bak")
        try? FileManager.default.removeItem(at: bak)
        try FileManager.default.copyItem(at: url, to: bak)   // copyItem 保留原文件权限
    }
}

/// `~/.codex/config.toml` 的最小改动：只读写顶层 `[features]` 表里的 `hooks` 键，其余内容逐字保留。
public enum CodexConfigEdit {
    public struct Enabled: Equatable {
        public let content: String
        public let changed: Bool
        public let previousHooksLine: String?
        public let createdFeaturesTable: Bool
    }

    static func tableHeader(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), !t.hasPrefix("#") else { return nil }
        let closing = t.hasPrefix("[[") ? "]]" : "]"
        guard let r = t.range(of: closing) else { return nil }
        let header = String(t[..<r.upperBound])
        let rest = t[r.upperBound...].trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty || rest.hasPrefix("#") else { return nil }
        return header
    }

    static func isKey(_ line: String, _ key: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), t.hasPrefix(key) else { return false }
        return t.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
    }

    static func isTrue(_ line: String) -> Bool {
        let value = line.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
        let v = (value.split(separator: "#").first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
        return v == "true"
    }

    /// 定位 `[features]` 表头与其中的 hooks 键所在行。
    static func locate(_ lines: [String]) -> (header: Int?, hooks: Int?) {
        var inFeatures = false
        var header: Int?
        var hooks: Int?
        for (i, line) in lines.enumerated() {
            if let h = tableHeader(line) {
                inFeatures = h == "[features]"
                if inFeatures, header == nil { header = i }
                continue
            }
            if inFeatures, hooks == nil, isKey(line, "hooks") { hooks = i }
        }
        return (header, hooks)
    }

    static func split(_ content: String) -> (lines: [String], trailingNewline: Bool) {
        guard !content.isEmpty else { return ([], false) }
        var lines = content.components(separatedBy: "\n")
        let trailing = content.hasSuffix("\n")
        if trailing { lines.removeLast() }
        return (lines, trailing)
    }

    static func join(_ lines: [String], trailingNewline: Bool) -> String {
        lines.joined(separator: "\n") + (trailingNewline && !lines.isEmpty ? "\n" : "")
    }

    public static func enableHooks(_ content: String) -> Enabled {
        var (lines, trailing) = split(content)
        let (header, hooks) = locate(lines)
        if let hooks {
            if isTrue(lines[hooks]) {
                return Enabled(content: content, changed: false, previousHooksLine: lines[hooks], createdFeaturesTable: false)
            }
            let previous = lines[hooks]
            lines[hooks] = "hooks = true"
            return Enabled(content: join(lines, trailingNewline: trailing), changed: true,
                           previousHooksLine: previous, createdFeaturesTable: false)
        }
        if let header {
            lines.insert("hooks = true", at: header + 1)
            return Enabled(content: join(lines, trailingNewline: trailing), changed: true,
                           previousHooksLine: nil, createdFeaturesTable: false)
        }
        var result = content
        while result.hasSuffix("\n") { result.removeLast() }
        if !result.isEmpty { result += "\n\n" }
        result += "[features]\nhooks = true\n"
        return Enabled(content: result, changed: true, previousHooksLine: nil, createdFeaturesTable: true)
    }

    /// 还原 enableHooks 的改动：只在 hooks 键仍为 true 时动它；表是 CC Desk 新建且已空时一并移除。
    public static func restoreHooks(_ content: String, previousHooksLine: String?, createdFeaturesTable: Bool) -> String {
        var (lines, trailing) = split(content)
        let (header, hooks) = locate(lines)
        guard let hooks, isTrue(lines[hooks]) else { return content }
        if let previous = previousHooksLine {
            lines[hooks] = previous
            return join(lines, trailingNewline: trailing)
        }
        lines.remove(at: hooks)
        if createdFeaturesTable, let header {
            // 表内只剩空行时移除表头。
            var end = header + 1
            while end < lines.count, tableHeader(lines[end]) == nil { end += 1 }
            let body = lines[(header + 1)..<end]
            if body.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                lines.removeSubrange(header..<end)
                // 新建的表追加在文件末尾、前面补了空行：表在末尾时一并去掉末尾空行。
                if header == lines.count {
                    while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
                }
            }
        }
        return join(lines, trailingNewline: trailing || !lines.isEmpty)
    }
}

/// `~/.codex/hooks.json` 的结构化合并：`{"hooks":{"<Event>":[{"hooks":[{"type":"command","command":…,"timeout":…}]}]}}`。
public enum CodexHooksEdit {
    /// (事件, 传给脚本的动作)。
    public static let events: [(event: String, action: String)] = [
        ("SessionStart", "session"),
        ("UserPromptSubmit", "working"),
        ("PermissionRequest", "waiting"),
        ("PostToolUse", "working"),
        ("Stop", "idle"),
        ("Interrupt", "idle"),
    ]

    public static func command(scriptPath: String, action: String) -> String {
        "/bin/sh \(ShellQuote.quote(scriptPath)) \(action)"
    }

    static func isOurs(_ hook: Any, scriptPath: String) -> Bool {
        guard let h = hook as? [String: Any], let cmd = h["command"] as? String else { return false }
        return cmd.contains(scriptPath)
    }

    /// 加入 CC Desk 的条目（已有则不重复），保留其他所有内容。
    public static func install(_ root: [String: Any], scriptPath: String) throws -> [String: Any] {
        var root = try uninstall(root, scriptPath: scriptPath)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, action) in events {
            guard var entries = (hooks[event] ?? []) as? [Any] else {
                throw IntegrationError("hooks.json 中 \(event) 不是数组，未做改动")
            }
            entries.append(["hooks": [["type": "command", "command": command(scriptPath: scriptPath, action: action), "timeout": 10]]])
            hooks[event] = entries
        }
        root["hooks"] = hooks
        return root
    }

    /// 只移除命令里含 CC Desk 脚本路径的 hook；因此变空的条目 / 事件一并移除。
    public static func uninstall(_ root: [String: Any], scriptPath: String) throws -> [String: Any] {
        var root = root
        guard let rawHooks = root["hooks"] else { return root }
        guard var hooks = rawHooks as? [String: Any] else { throw IntegrationError("hooks.json 的 hooks 不是对象，未做改动") }
        for (event, value) in hooks {
            guard let entries = value as? [Any] else { continue }
            var kept: [Any] = []
            for entry in entries {
                guard var e = entry as? [String: Any], let inner = e["hooks"] as? [Any] else { kept.append(entry); continue }
                let remaining = inner.filter { !isOurs($0, scriptPath: scriptPath) }
                if remaining.count == inner.count { kept.append(entry); continue }
                if remaining.isEmpty { continue }
                e["hooks"] = remaining
                kept.append(e)
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks
        return root
    }

    public static func isInstalled(_ root: [String: Any], scriptPath: String) -> Bool {
        guard let hooks = root["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event, action in
            ((hooks[event] as? [Any]) ?? []).contains { entry in
                ((entry as? [String: Any])?["hooks"] as? [Any] ?? []).contains {
                    ($0 as? [String: Any])?["command"] as? String == command(scriptPath: scriptPath, action: action)
                }
            }
        }
    }

    static func hasAnyEntries(_ root: [String: Any]) -> Bool {
        if root.keys.contains(where: { $0 != "hooks" }) { return true }
        return !((root["hooks"] as? [String: Any]) ?? [:]).isEmpty
    }
}

/// Codex 状态集成：hook 脚本 `~/.cc-desk/hooks/codex-state.sh` + `~/.codex/hooks.json` 条目 + config.toml 的 `[features] hooks = true`。
public struct CodexIntegration {
    public let home: URL

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) { self.home = home }

    public var codexDir: URL { home.appendingPathComponent(".codex", isDirectory: true) }
    public var hooksFile: URL { codexDir.appendingPathComponent("hooks.json") }
    public var configFile: URL { codexDir.appendingPathComponent("config.toml") }
    public var scriptFile: URL { home.appendingPathComponent(".cc-desk/hooks/codex-state.sh") }
    var ledgerFile: URL { home.appendingPathComponent(".cc-desk/integrations.json") }

    func readHooks() throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: hooksFile) else { return nil }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IntegrationError("hooks.json 不是 JSON 对象，未做改动")
        }
        return obj
    }

    func writeHooks(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try IntegrationFiles.write(data + Data("\n".utf8), to: hooksFile)
    }

    public func status() -> IntegrationStatus {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: codexDir.path, isDirectory: &isDir), isDir.boolValue else { return .agentMissing }
        let hooks = (try? readHooks()) ?? nil
        let entries = hooks.map { CodexHooksEdit.isInstalled($0, scriptPath: scriptFile.path) } ?? false
        let script = (try? String(contentsOf: scriptFile, encoding: .utf8)) == IntegrationAssets.codexHookScript
        let config = (try? String(contentsOf: configFile, encoding: .utf8)).map { !CodexConfigEdit.enableHooks($0).changed } ?? false
        if entries && script && config { return .installed }
        let anyOurs = hooks.map { root -> Bool in
            let stripped = (try? CodexHooksEdit.uninstall(root, scriptPath: scriptFile.path)) ?? root
            return !NSDictionary(dictionary: stripped).isEqual(to: root)
        } ?? false
        if !anyOurs && !FileManager.default.fileExists(atPath: scriptFile.path) { return .notInstalled }
        if !entries { return .needsRepair("hooks.json 条目不完整") }
        if !script { return .needsRepair("hook 脚本缺失或已过期") }
        return .needsRepair("config.toml 未开启 [features] hooks")
    }

    /// 安装：写脚本；备份并合并 hooks.json；备份并在 config.toml 中开启 hooks（只改这一个键）。可重复执行。
    public func install() throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: codexDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw IntegrationError("没有找到 \(codexDir.path)，请先安装并运行一次 Codex")
        }
        var ledger = IntegrationLedger.load(ledgerFile)

        let existing = try readHooks()
        let merged = try CodexHooksEdit.install(existing ?? [:], scriptPath: scriptFile.path)

        let configText = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
        let enabled = CodexConfigEdit.enableHooks(configText)

        try IntegrationFiles.write(IntegrationAssets.codexHookScript, to: scriptFile, executable: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".cc-desk/state", isDirectory: true),
                                                withIntermediateDirectories: true)

        if existing.map({ !NSDictionary(dictionary: merged).isEqual(to: $0) }) ?? true {
            try IntegrationFiles.backup(hooksFile)
            try writeHooks(merged)
        }

        var record = ledger.codex ?? IntegrationLedger.Codex(previousHooksLine: nil, createdFeaturesTable: false,
                                                            changedConfig: false, createdHooksFile: false)
        if ledger.codex == nil { record.createdHooksFile = existing == nil }
        if enabled.changed {
            try IntegrationFiles.backup(configFile)
            try IntegrationFiles.write(enabled.content, to: configFile)
            record.previousHooksLine = enabled.previousHooksLine
            record.createdFeaturesTable = enabled.createdFeaturesTable
            record.changedConfig = true
        }
        ledger.codex = record
        try ledger.save(ledgerFile)
    }

    /// 卸载：只移除 CC Desk 的 hook 条目与脚本；config.toml 只还原 CC Desk 自己改动过的 hooks 键。
    public func uninstall() throws {
        var ledger = IntegrationLedger.load(ledgerFile)
        if let existing = try readHooks() {
            let stripped = try CodexHooksEdit.uninstall(existing, scriptPath: scriptFile.path)
            if !NSDictionary(dictionary: stripped).isEqual(to: existing) {
                try IntegrationFiles.backup(hooksFile)
                if ledger.codex?.createdHooksFile == true, !CodexHooksEdit.hasAnyEntries(stripped) {
                    try FileManager.default.removeItem(at: hooksFile)
                } else {
                    try writeHooks(stripped)
                }
            }
        }
        if let record = ledger.codex, record.changedConfig,
           let text = try? String(contentsOf: configFile, encoding: .utf8) {
            let restored = CodexConfigEdit.restoreHooks(text, previousHooksLine: record.previousHooksLine,
                                                        createdFeaturesTable: record.createdFeaturesTable)
            if restored != text {
                try IntegrationFiles.backup(configFile)
                try IntegrationFiles.write(restored, to: configFile)
            }
        }
        try? FileManager.default.removeItem(at: scriptFile)
        ledger.codex = nil
        try ledger.save(ledgerFile)
    }
}

/// pi 状态集成：扩展文件 `~/.pi/agent/extensions/cc-desk-state.ts`。
public struct PiIntegration {
    public let home: URL

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) { self.home = home }

    public var agentDir: URL { home.appendingPathComponent(".pi/agent", isDirectory: true) }
    public var extensionFile: URL { agentDir.appendingPathComponent("extensions/cc-desk-state.ts") }

    public func status() -> IntegrationStatus {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: agentDir.path, isDirectory: &isDir), isDir.boolValue else { return .agentMissing }
        guard let text = try? String(contentsOf: extensionFile, encoding: .utf8) else { return .notInstalled }
        guard text.contains(IntegrationAssets.marker) else { return .needsRepair("同名文件不是 CC Desk 安装的") }
        return text == IntegrationAssets.piExtension ? .installed : .needsRepair("扩展文件已过期")
    }

    public func install() throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: agentDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw IntegrationError("没有找到 \(agentDir.path)，请先安装并运行一次 pi")
        }
        if let text = try? String(contentsOf: extensionFile, encoding: .utf8), !text.contains(IntegrationAssets.marker) {
            throw IntegrationError("\(extensionFile.path) 已存在且不是 CC Desk 安装的，未做改动")
        }
        try IntegrationFiles.write(IntegrationAssets.piExtension, to: extensionFile)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".cc-desk/state", isDirectory: true),
                                                withIntermediateDirectories: true)
    }

    public func uninstall() throws {
        guard let text = try? String(contentsOf: extensionFile, encoding: .utf8) else { return }
        guard text.contains(IntegrationAssets.marker) else {
            throw IntegrationError("\(extensionFile.path) 不是 CC Desk 安装的，未删除")
        }
        try FileManager.default.removeItem(at: extensionFile)
    }
}
