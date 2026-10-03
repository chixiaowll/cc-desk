import Foundation

/// Codex / pi 会话文件的头部信息。
public struct AgentSessionHeader: Equatable, Sendable {
    public let sessionID: String
    public let cwd: String
    public let startedAt: Date?

    public init(sessionID: String, cwd: String, startedAt: Date?) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.startedAt = startedAt
    }
}

/// 解析 Codex / pi 的 jsonl 会话文件。与 TranscriptReader 一样只读头部 / 尾部，禁止整文件读取。
///
/// - Codex：`~/.codex/sessions/YYYY/MM/DD/rollout-<本地时间>-<uuid>.jsonl`，首行
///   `{"type":"session_meta","payload":{"session_id"|"id","cwd","timestamp",...}}`；用户消息为
///   `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":…}]}}`
///   （以 "<" 开头的是注入的环境 / 指令块，跳过），旧版本为 `event_msg` / `user_message`。
/// - pi：`~/.pi/agent/sessions/<编码 cwd>/<ISO 时间>_<uuid>.jsonl`，首行
///   `{"type":"session","id","timestamp","cwd"}`；用户消息为 `{"type":"message","message":{"role":"user","content":[{"type":"text","text":…}]}}`；
///   `/name` 写入 `{"type":"session_info","name":…}`。
public enum AgentTranscriptReader {
    public static let headBytes = 256 * 1024

    public static func header(kind: AgentKind, head: Data) -> AgentSessionHeader? {
        for line in TranscriptReader.lines(in: head).prefix(20) {
            guard let obj = TranscriptReader.jsonObject(line) else { continue }
            switch kind {
            case .codex:
                guard obj["type"] as? String == "session_meta", let p = obj["payload"] as? [String: Any] else { continue }
                let sid = (p["session_id"] as? String).flatMap(nonEmpty) ?? (p["id"] as? String).flatMap(nonEmpty)
                guard let sid, let cwd = (p["cwd"] as? String).flatMap(nonEmpty) else { return nil }
                let ts = (p["timestamp"] as? String) ?? (obj["timestamp"] as? String)
                return AgentSessionHeader(sessionID: sid, cwd: cwd, startedAt: ts.flatMap(parseISODate))
            case .pi:
                guard obj["type"] as? String == "session" else { continue }
                guard let sid = (obj["id"] as? String).flatMap(nonEmpty),
                      let cwd = (obj["cwd"] as? String).flatMap(nonEmpty) else { return nil }
                return AgentSessionHeader(sessionID: sid, cwd: cwd,
                                          startedAt: (obj["timestamp"] as? String).flatMap(parseISODate))
            case .claude, .other:
                return nil
            }
        }
        return nil
    }

    /// firstPrompt 取自头部，lastPrompt / 会话名取自尾部（尾部首行可能残缺，解析失败的行会被跳过）。
    public static func meta(kind: AgentKind, head: Data, tail: Data) -> TranscriptMeta {
        let first = TranscriptReader.lines(in: head).lazy.compactMap { userPrompt(kind: kind, line: $0) }.first
        var last: String?
        var name: String?
        for line in TranscriptReader.lines(in: tail) {
            if let prompt = userPrompt(kind: kind, line: line) { last = prompt }
            if kind == .pi, let obj = TranscriptReader.jsonObject(line), obj["type"] as? String == "session_info" {
                name = (obj["name"] as? String).flatMap(trimmedNonEmpty)
            }
        }
        if kind == .pi, name == nil {
            for line in TranscriptReader.lines(in: head) {
                guard let obj = TranscriptReader.jsonObject(line), obj["type"] as? String == "session_info" else { continue }
                name = (obj["name"] as? String).flatMap(trimmedNonEmpty)
            }
        }
        return TranscriptMeta(customTitle: name, aiTitle: nil, lastPrompt: last, firstPrompt: first)
    }

    /// 一行记录若是用户真正输入的消息，返回其文本。
    static func userPrompt(kind: AgentKind, line: String) -> String? {
        guard let obj = TranscriptReader.jsonObject(line) else { return nil }
        switch kind {
        case .codex:
            guard let p = obj["payload"] as? [String: Any] else { return nil }
            let type = obj["type"] as? String
            if type == "response_item", p["type"] as? String == "message", p["role"] as? String == "user" {
                return userText(p["content"], partType: "input_text")
            }
            if type == "event_msg", p["type"] as? String == "user_message" {
                return (p["message"] as? String).flatMap(cleanPrompt)
            }
            return nil
        case .pi:
            guard obj["type"] as? String == "message", let m = obj["message"] as? [String: Any],
                  m["role"] as? String == "user" else { return nil }
            if let s = m["content"] as? String { return cleanPrompt(s) }
            return userText(m["content"], partType: "text")
        case .claude, .other:
            return nil
        }
    }

    private static func userText(_ content: Any?, partType: String) -> String? {
        guard let parts = content as? [[String: Any]] else { return nil }
        let text = parts
            .filter { $0["type"] as? String == partType }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        return cleanPrompt(text)
    }

    /// 去掉空白；以 "<" 开头的是注入的 `<environment_context>` / `<user_instructions>` 等块，不算用户输入。
    private static func cleanPrompt(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        return trimmed
    }

    private static func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }

    private static func trimmedNonEmpty(_ s: String) -> String? {
        nonEmpty(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func parseISODate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// 一个 Codex / pi 会话文件（已解析头部）。
public struct AgentSessionFile: Equatable, Sendable {
    public let kind: AgentKind
    public let sessionID: String
    public let cwd: String
    public let path: String
    /// 会话创建时间（头部时间戳；缺失时为 nil）。
    public let createdAt: Date?
    public let modifiedAt: Date

    public init(kind: AgentKind, sessionID: String, cwd: String, path: String, createdAt: Date?, modifiedAt: Date) {
        self.kind = kind
        self.sessionID = sessionID
        self.cwd = cwd
        self.path = path
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

/// 一个正在运行的 Codex / pi 进程（用于与会话文件配对）。
public struct AgentProcessCandidate: Equatable, Sendable {
    public let pid: Int32
    public let kind: AgentKind
    public let cwd: String?
    public let startedAt: Date?
    /// 明确知道的会话：hook 上报的 session_id，或命令行 `codex resume <id>` / `pi --session <id|path>`。
    public let sessionHint: String?

    public init(pid: Int32, kind: AgentKind, cwd: String?, startedAt: Date?, sessionHint: String?) {
        self.pid = pid
        self.kind = kind
        self.cwd = cwd
        self.startedAt = startedAt
        self.sessionHint = sessionHint
    }
}

public enum AgentSessionMatcher {
    /// 进程启动时间与文件时间比较时的容差。
    static let slack: TimeInterval = 2

    /// 为每个进程找到它正在写的会话文件。
    /// 1. 有 sessionHint：按 sessionId（允许前缀）或文件路径精确匹配。
    /// 2. 否则在同种类、同 cwd、且自进程启动后创建或写入过的文件中选：优先本进程启动后新建的，再按最近写入；
    ///    较晚启动的进程先选，已被选走的文件不再分配（同目录多个会话时仍可能误配，hook 上报的 session_id 可纠正）。
    public static func match(processes: [AgentProcessCandidate], files: [AgentSessionFile]) -> [Int32: AgentSessionFile] {
        var result: [Int32: AgentSessionFile] = [:]
        var claimed: Set<String> = []

        for p in processes {
            guard let hint = p.sessionHint, !hint.isEmpty else { continue }
            let found = files.first { $0.kind == p.kind && ($0.sessionID == hint || $0.path == hint) }
                ?? files.first { $0.kind == p.kind && hint.count >= 8 && $0.sessionID.hasPrefix(hint) }
            if let found, !claimed.contains(found.path) {
                result[p.pid] = found
                claimed.insert(found.path)
            }
        }

        let rest = processes
            .filter { result[$0.pid] == nil && $0.sessionHint == nil }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        for p in rest {
            guard let cwd = p.cwd else { continue }
            let start = (p.startedAt ?? .distantPast).addingTimeInterval(-slack)
            let eligible = files.filter { f in
                f.kind == p.kind && f.cwd == cwd && !claimed.contains(f.path)
                    && ((f.createdAt.map { $0 >= start } ?? false) || f.modifiedAt >= start)
            }
            let best = eligible.max { a, b in
                let an = a.createdAt.map { $0 >= start } ?? false
                let bn = b.createdAt.map { $0 >= start } ?? false
                if an != bn { return !an }
                return a.modifiedAt < b.modifiedAt
            }
            if let best {
                result[p.pid] = best
                claimed.insert(best.path)
            }
        }
        return result
    }
}

/// 索引 Codex（`~/.codex/sessions`）与 pi（`~/.pi/agent/sessions`）的会话文件：配对运行中的进程、提供标题与历史列表。
/// 非线程安全；只在单个串行队列（如 poll 队列）上使用。
public final class AgentSessionIndex {
    public static let defaultCodexRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions", isDirectory: true)
    public static let defaultPiRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".pi/agent/sessions", isDirectory: true)

    private struct CacheEntry {
        let mtime: Date
        let size: Int
        let header: AgentSessionHeader?
        let meta: TranscriptMeta
    }

    private let codexRoot: URL
    private let piRoot: URL
    private let fileManager: FileManager
    private let calendar: Calendar
    private var cache: [String: CacheEntry] = [:]
    /// sessionId -> 文件路径。
    private var sessionPaths: [String: String] = [:]
    /// 找不到的 "<kind>:<sessionId>" -> 上次扫描的时间：`missTTL` 内不再扫描整棵目录树。
    private var misses: [String: Date] = [:]
    public static let missTTL: TimeInterval = 12
    private let now: () -> Date

    public init(codexRoot: URL = AgentSessionIndex.defaultCodexRoot, piRoot: URL = AgentSessionIndex.defaultPiRoot,
                fileManager: FileManager = .default, calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.codexRoot = codexRoot
        self.piRoot = piRoot
        self.fileManager = fileManager
        self.calendar = calendar
        self.now = now
    }

    /// pi 的会话目录名：`--<cwd 去掉开头的 / 后把 / \ : 换成 ->--`（见 pi 的 getDefaultSessionDir）。
    public static func piDirectoryName(cwd: String) -> String {
        var path = cwd
        if path.hasPrefix("/") || path.hasPrefix("\\") { path.removeFirst() }
        let mapped = path.map { c -> Character in (c == "/" || c == "\\" || c == ":") ? "-" : c }
        return "--\(String(mapped))--"
    }

    /// 配对运行中的进程：只看可能相关的文件（Codex 为进程启动日起最多 7 天的日期目录，pi 为各 cwd 的目录），
    /// 再加上按 sessionHint 定位到的文件。
    public func match(processes: [AgentProcessCandidate], now: Date = Date()) -> [Int32: AgentSessionFile] {
        var paths: [String: AgentKind] = [:]
        let codexProcs = processes.filter { $0.kind == .codex }
        if !codexProcs.isEmpty {
            let earliest = codexProcs.compactMap(\.startedAt).min() ?? now
            for dir in codexDayDirectories(from: earliest, to: now) {
                for url in jsonlFiles(in: dir) { paths[url.path] = .codex }
            }
        }
        for cwd in Set(processes.filter { $0.kind == .pi }.compactMap(\.cwd)) {
            let dir = piRoot.appendingPathComponent(Self.piDirectoryName(cwd: cwd), isDirectory: true)
            for url in jsonlFiles(in: dir) { paths[url.path] = .pi }
        }
        for p in processes {
            guard let hint = p.sessionHint else { continue }
            if hint.hasPrefix("/") {
                paths[hint] = p.kind
            } else if let path = locate(kind: p.kind, sessionID: hint) {
                paths[path] = p.kind
            }
        }
        var files: [AgentSessionFile] = []
        for (path, kind) in paths {
            if let f = file(at: path, kind: kind) { files.append(f) }
        }
        return AgentSessionMatcher.match(processes: processes, files: files)
    }

    /// 某个会话文件的标题字段。
    public func meta(path: String, kind: AgentKind) -> TranscriptMeta? {
        entry(path: path, kind: kind)?.meta
    }

    /// 按 sessionId 定位会话文件；首次通过枚举定位后缓存。找不到时 `missTTL` 秒内直接返回 nil，不再扫描。
    public func locate(kind: AgentKind, sessionID: String) -> String? {
        if let p = sessionPaths[sessionID], fileManager.fileExists(atPath: p) { return p }
        let key = "\(kind.rawValue):\(sessionID)"
        let time = now()
        if let missedAt = misses[key], time.timeIntervalSince(missedAt) < Self.missTTL { return nil }
        for url in allFiles(kind: kind) where url.lastPathComponent.contains(sessionID) {
            sessionPaths[sessionID] = url.path
            misses[key] = nil
            return url.path
        }
        misses = misses.filter { time.timeIntervalSince($0.value) < Self.missTTL }
        misses[key] = time
        return nil
    }

    /// 所有 Codex / pi 会话按 mtime 倒序，排除 live 会话。
    public func history(excluding live: Set<String>, limit: Int = 300) -> [HistoryItem] {
        var items: [HistoryItem] = []
        for kind in [AgentKind.codex, .pi] {
            for url in allFiles(kind: kind) {
                guard let e = entry(path: url.path, kind: kind), let header = e.header else { continue }
                sessionPaths[header.sessionID] = url.path
                if live.contains(header.sessionID) { continue }
                let title = e.meta.displayTitle(fallbackName: nil, fallbackIsDerived: true)
                items.append(HistoryItem(sessionID: header.sessionID, cwd: header.cwd, title: title,
                                         lastPrompt: e.meta.lastPrompt, modifiedAt: e.mtime, kind: kind))
            }
        }
        items.sort { $0.modifiedAt > $1.modifiedAt }
        if items.count > limit { items = Array(items.prefix(limit)) }
        return items
    }

    // MARK: 内部

    private func file(at path: String, kind: AgentKind) -> AgentSessionFile? {
        guard let e = entry(path: path, kind: kind), let h = e.header else { return nil }
        sessionPaths[h.sessionID] = path
        return AgentSessionFile(kind: kind, sessionID: h.sessionID, cwd: h.cwd, path: path,
                                createdAt: h.startedAt, modifiedAt: e.mtime)
    }

    private func codexDayDirectories(from start: Date, to end: Date) -> [URL] {
        var dirs: [URL] = []
        var day = calendar.startOfDay(for: max(start, end.addingTimeInterval(-6 * 86400)))
        let last = calendar.startOfDay(for: end)
        while day <= last {
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            if let y = c.year, let m = c.month, let d = c.day {
                dirs.append(codexRoot
                    .appendingPathComponent(String(format: "%04d", y), isDirectory: true)
                    .appendingPathComponent(String(format: "%02d", m), isDirectory: true)
                    .appendingPathComponent(String(format: "%02d", d), isDirectory: true))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return dirs
    }

    private func jsonlFiles(in dir: URL) -> [URL] {
        ((try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
    }

    private func allFiles(kind: AgentKind) -> [URL] {
        switch kind {
        case .codex:
            var files: [URL] = []
            for year in subdirectories(of: codexRoot) {
                for month in subdirectories(of: year) {
                    for day in subdirectories(of: month) { files.append(contentsOf: jsonlFiles(in: day)) }
                }
            }
            return files
        case .pi:
            return subdirectories(of: piRoot).flatMap(jsonlFiles)
        case .claude, .other:
            return []
        }
    }

    private func subdirectories(of dir: URL) -> [URL] {
        ((try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false }
    }

    /// 按 (path, mtime, size) 缓存解析结果；未变化时不重读文件。
    private func entry(path: String, kind: AgentKind) -> CacheEntry? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.intValue
        else { return nil }
        let key = "\(kind.rawValue):\(path)"
        if let cached = cache[key], cached.mtime == mtime, cached.size == size { return cached }
        let url = URL(fileURLWithPath: path)
        let head = TranscriptReader.readHead(url, bytes: AgentTranscriptReader.headBytes)
        let tail = TranscriptReader.readTail(url)
        let fresh = CacheEntry(mtime: mtime, size: size,
                               header: AgentTranscriptReader.header(kind: kind, head: head),
                               meta: AgentTranscriptReader.meta(kind: kind, head: head, tail: tail))
        cache[key] = fresh
        return fresh
    }
}
