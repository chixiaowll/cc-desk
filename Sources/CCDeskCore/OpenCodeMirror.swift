import Foundation
import SQLite3

/// OpenCode 的会话存在 SQLite（`~/.local/share/opencode/opencode.db`：session / message / part 三张表，data 列是 JSON）。
/// CC Desk 其他部分都按「jsonl 会话记录」读（标题、模型、改动 / 提到的文件、token、助手用的上下文摘要），
/// 所以这里把每个 OpenCode 会话增量同步成一个 pi 格式的 jsonl 镜像（设计 §30），之后 OpenCode 就按 pi 的解析器读：
///
/// - 首行 `{"type":"session","id","timestamp","cwd"}`；标题变化时追加 `{"type":"session_info","name"}`；
/// - 消息 `{"type":"message","id","timestamp","message":{"role","content":[…],"model","provider","usage"}}`：
///   用户消息的 text 片段 → `{"type":"text"}`；助手的 text → `text`，工具调用 → `{"type":"toolCall","name","arguments"}`
///   （`filePath` 改名为 `path`，与 pi 的 write / edit 一致），patch 片段里的文件 → `edit`；
///   token：input / cacheRead / cacheWrite 原样，output = output + reasoning。
/// - 子 agent 会话（parent_id 非空）的消息并入顶层会话的镜像（改动的文件、token 都算在发起它的会话上）。
/// - 助手消息完成（`time.completed`）后才写入，之后不再改；用户消息直接写。按 (time_created, id) 顺序推进，
///   进度记在 `state.json`；进度丢失时整个重建。
///
/// 只读打开数据库（不改 OpenCode 的数据）。非线程安全；只在单个串行队列上使用。
public final class OpenCodeMirror {
    public static let defaultDatabase = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".local/share/opencode/opencode.db")
    public static let defaultRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".cc-desk/opencode", isDirectory: true)

    struct Progress: Codable, Equatable {
        var lastCreated: Int64
        var lastID: String
        var title: String?
    }

    struct State: Codable {
        var version = 1
        /// 已处理到的会话更新时间（毫秒）。
        var watermark: Int64 = 0
        /// 镜像会话（顶层）-> 进度；子会话按自己的 id 记进度，写进父会话的镜像。
        var sessions: [String: Progress] = [:]
    }

    public let database: URL
    public let root: URL
    private let fileManager: FileManager
    private var state = State()
    private var loaded = false
    private var lastStamp: (Date?, Date?)?

    public init(database: URL = OpenCodeMirror.defaultDatabase, root: URL = OpenCodeMirror.defaultRoot,
                fileManager: FileManager = .default) {
        self.database = database
        self.root = root
        self.fileManager = fileManager
    }

    /// 某个会话的镜像文件。
    public func path(sessionID: String) -> URL {
        root.appendingPathComponent(Self.fileName(sessionID))
    }

    static func fileName(_ sessionID: String) -> String {
        sessionID.replacingOccurrences(of: "/", with: "_") + ".jsonl"
    }

    /// 数据库（或其 WAL）变过才同步；返回是否有镜像被改写。
    @discardableResult
    public func sync() -> Bool {
        guard fileManager.fileExists(atPath: database.path) else { return false }
        let stamp = (mtime(database.path), mtime(database.path + "-wal"))
        if let lastStamp, lastStamp.0 == stamp.0, lastStamp.1 == stamp.1 { return false }
        loadState()
        guard let db = open() else { return false }
        defer { sqlite3_close(db) }
        var changed = false
        // 留 2 秒余量：同一毫秒里更新的会话不会漏掉。
        let since = max(state.watermark - 2000, 0)
        let sessions = query(db, """
            SELECT id, parent_id, directory, title, time_created, time_updated FROM session
            WHERE time_updated > ? ORDER BY time_updated
            """, bind: [.int(since)]) { row in
            SessionRow(id: row.text(0) ?? "", parent: row.text(1), directory: row.text(2) ?? "",
                       title: row.text(3) ?? "", created: row.int(4), updated: row.int(5))
        }
        let parents = parentMap(db, ids: sessions.compactMap(\.parent))
        for s in sessions where !s.id.isEmpty {
            let top = topLevel(of: s, parents: parents)
            if sync(db, session: s, into: top) { changed = true }
            state.watermark = max(state.watermark, s.updated)
        }
        saveState()
        // 写完后再记数据库时间：同步期间 OpenCode 又写入时，下次还会再看一遍。
        lastStamp = stamp
        return changed
    }

    // MARK: 同步一个会话

    struct SessionRow {
        let id: String
        let parent: String?
        let directory: String
        let title: String
        let created: Int64
        let updated: Int64
    }

    /// 顶层会话（沿 parent_id 往上，最多 8 层）。
    private func topLevel(of s: SessionRow, parents: [String: (parent: String?, row: SessionRow)]) -> SessionRow {
        var current = s
        var hops = 0
        while let p = current.parent, let up = parents[p], hops < 8 {
            current = up.row
            hops += 1
        }
        return current
    }

    private func parentMap(_ db: OpaquePointer, ids: [String]) -> [String: (parent: String?, row: SessionRow)] {
        var result: [String: (parent: String?, row: SessionRow)] = [:]
        var pending = Set(ids)
        var rounds = 0
        while !pending.isEmpty, rounds < 8 {
            rounds += 1
            var next: Set<String> = []
            for id in pending where result[id] == nil {
                let rows = query(db, "SELECT id, parent_id, directory, title, time_created, time_updated FROM session WHERE id = ?",
                                 bind: [.text(id)]) { row in
                    SessionRow(id: row.text(0) ?? "", parent: row.text(1), directory: row.text(2) ?? "",
                               title: row.text(3) ?? "", created: row.int(4), updated: row.int(5))
                }
                if let r = rows.first {
                    result[id] = (r.parent, r)
                    if let p = r.parent { next.insert(p) }
                }
            }
            pending = next
        }
        return result
    }

    /// 把会话 s 的新消息追加到顶层会话 top 的镜像里；返回是否写了东西。
    private func sync(_ db: OpaquePointer, session s: SessionRow, into top: SessionRow) -> Bool {
        let file = path(sessionID: top.id)
        var lines: [String] = []
        if state.sessions[top.id] == nil || !fileManager.fileExists(atPath: file.path) {
            // 新镜像（或镜像丢了）：从头写，相关进度清零。
            try? fileManager.removeItem(at: file)
            state.sessions[top.id] = Progress(lastCreated: 0, lastID: "", title: nil)
            if s.id != top.id { state.sessions[s.id] = nil }
            lines.append(Self.json(["type": "session", "id": top.id, "timestamp": Self.iso(top.created), "cwd": top.directory]))
        }
        if s.id == top.id, let name = Self.customTitle(top.title), state.sessions[top.id]?.title != name {
            lines.append(Self.json(["type": "session_info", "name": name]))
            state.sessions[top.id]?.title = name
        }
        var progress = state.sessions[s.id] ?? Progress(lastCreated: 0, lastID: "", title: nil)
        let messages = query(db, """
            SELECT id, time_created, data FROM message
            WHERE session_id = ? AND (time_created > ? OR (time_created = ? AND id > ?))
            ORDER BY time_created, id
            """, bind: [.text(s.id), .int(progress.lastCreated), .int(progress.lastCreated), .text(progress.lastID)]) { row in
            (id: row.text(0) ?? "", created: row.int(1), data: row.text(2) ?? "")
        }
        for m in messages {
            guard let info = Self.object(m.data) else { continue }
            let role = info["role"] as? String
            // 助手消息还在生成：停在这里，下次从它开始（保持顺序）。
            if role == "assistant", ((info["time"] as? [String: Any])?["completed"]) == nil, info["error"] == nil { break }
            let parts = query(db, "SELECT data FROM part WHERE message_id = ? ORDER BY id", bind: [.text(m.id)]) { row in
                row.text(0) ?? ""
            }.compactMap(Self.object)
            if let line = Self.mirrorLine(id: m.id, created: m.created, info: info, parts: parts) { lines.append(line) }
            progress.lastCreated = m.created
            progress.lastID = m.id
        }
        state.sessions[s.id] = progress
        guard !lines.isEmpty else { return false }
        append(lines, to: file)
        return true
    }

    /// 一条 OpenCode 消息 → 一行 pi 格式；没有可用内容时为 nil。
    static func mirrorLine(id: String, created: Int64, info: [String: Any], parts: [[String: Any]]) -> String? {
        let role = info["role"] as? String
        var content: [[String: Any]] = []
        for p in parts {
            switch p["type"] as? String {
            case "text":
                if p["synthetic"] as? Bool == true { continue }
                if let t = p["text"] as? String, !t.isEmpty { content.append(["type": "text", "text": t]) }
            case "tool" where role == "assistant":
                let name = (p["tool"] as? String) ?? ""
                var args = ((p["state"] as? [String: Any])?["input"] as? [String: Any]) ?? [:]
                if let fp = args["filePath"] { args["path"] = fp }
                content.append(["type": "toolCall", "name": name, "arguments": args])
            case "patch" where role == "assistant":
                // apply_patch / 多文件编辑：patch 片段列出改动的文件，按 edit 记。
                for f in (p["files"] as? [String]) ?? [] {
                    content.append(["type": "toolCall", "name": "edit", "arguments": ["path": f]])
                }
            default:
                continue
            }
        }
        var message: [String: Any] = ["role": role ?? "user", "content": content]
        if role == "assistant" {
            if let model = info["modelID"] as? String { message["model"] = model }
            if let provider = info["providerID"] as? String { message["provider"] = provider }
            if let t = info["tokens"] as? [String: Any] {
                let cache = t["cache"] as? [String: Any] ?? [:]
                func n(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
                message["usage"] = ["input": n(t["input"]), "output": n(t["output"]) + n(t["reasoning"]),
                                    "cacheRead": n(cache["read"]), "cacheWrite": n(cache["write"])]
            }
        } else if let model = info["model"] as? [String: Any], let m = model["modelID"] as? String {
            message["model"] = m
            if let p = model["providerID"] as? String { message["provider"] = p }
        }
        guard !content.isEmpty || message["usage"] != nil else { return nil }
        return json(["type": "message", "id": id, "timestamp": iso(created), "message": message])
    }

    /// OpenCode 新会话的默认标题是「New session - <时间>」，不算自定义标题。
    static func customTitle(_ title: String) -> String? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("New session - ") || t.hasPrefix("Child session - ") { return nil }
        return t
    }

    // MARK: 文件

    private func append(_ lines: [String], to file: URL) {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: file.path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }

    private var statePath: URL { root.appendingPathComponent("state.json") }

    private func loadState() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: statePath), let s = try? JSONDecoder().decode(State.self, from: data), s.version == 1 {
            state = s
        } else {
            // 进度丢失：旧镜像作废，从头重建。
            if let files = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                for f in files where f.pathExtension == "jsonl" { try? fileManager.removeItem(at: f) }
            }
            state = State()
        }
    }

    private func saveState() {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: statePath, options: .atomic) }
    }

    private func mtime(_ path: String) -> Date? {
        (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: SQLite

    enum Bind {
        case int(Int64)
        case text(String)
    }

    struct Row {
        let stmt: OpaquePointer
        func text(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    }

    private func open() -> OpaquePointer? {
        var db: OpaquePointer?
        // 只读；OpenCode 用 WAL，读者需要能打开 -shm（同一用户，可以）。
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 500)
        return db
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func query<T>(_ db: OpaquePointer, _ sql: String, bind: [Bind], map: (Row) -> T) -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, b) in bind.enumerated() {
            switch b {
            case .int(let v): sqlite3_bind_int64(stmt, Int32(i + 1), v)
            case .text(let v): sqlite3_bind_text(stmt, Int32(i + 1), v, -1, Self.transient)
            }
        }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(map(Row(stmt: stmt))) }
        return out
    }

    // MARK: JSON

    static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    static func json(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func iso(_ ms: Int64) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}
