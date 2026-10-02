import Foundation

/// 历史会话列表中的一条记录。
public struct HistoryItem: Identifiable, Equatable, Sendable {
    public let sessionID: String
    public let cwd: String
    public let title: String
    public let lastPrompt: String?
    public let modifiedAt: Date
    public let kind: AgentKind
    public var id: String { sessionID }

    public init(sessionID: String, cwd: String, title: String, lastPrompt: String?, modifiedAt: Date,
                kind: AgentKind = .claude) {
        self.kind = kind
        self.sessionID = sessionID
        self.cwd = cwd
        self.title = title
        self.lastPrompt = lastPrompt
        self.modifiedAt = modifiedAt
    }
}

/// 索引 `~/.claude/projects/<编码目录>/<sessionId>.jsonl`，提供会话标题查询与历史会话列表。
/// 非线程安全；只在单个串行队列（如 poll 队列）上使用。
public final class TranscriptIndex {
    public static let defaultRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/projects", isDirectory: true)

    private struct CacheEntry {
        let mtime: Date
        let size: Int
        let cwd: String?
        let meta: TranscriptMeta
    }

    private let root: URL
    private let fileManager: FileManager
    private var cache: [String: CacheEntry] = [:]
    /// sessionId -> 文件路径；首次通过枚举定位后缓存，避免每次查询都扫描全目录。
    private var sessionPaths: [String: URL] = [:]

    public init(root: URL = TranscriptIndex.defaultRoot, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    /// 返回某个 sessionId 对应 transcript 的标题字段；找不到文件时返回 nil。
    public func meta(forSession id: String) -> TranscriptMeta? {
        guard let url = locate(sessionID: id) else { return nil }
        return entry(for: url)?.meta
    }

    /// 所有 transcript 按 mtime 倒序排列，排除 live 会话与无 cwd 的文件。
    public func history(excluding live: Set<String>, limit: Int = 300) -> [HistoryItem] {
        var items: [HistoryItem] = []
        for url in allTranscriptFiles() {
            let sessionID = url.deletingPathExtension().lastPathComponent
            if live.contains(sessionID) { continue }
            guard let e = entry(for: url), let cwd = e.cwd else { continue }
            let title = e.meta.displayTitle(fallbackName: nil, fallbackIsDerived: true)
            items.append(HistoryItem(sessionID: sessionID, cwd: cwd, title: title, lastPrompt: e.meta.lastPrompt, modifiedAt: e.mtime,
                                     kind: .claude))
        }
        items.sort { $0.modifiedAt > $1.modifiedAt }
        if items.count > limit { items = Array(items.prefix(limit)) }
        return items
    }

    private func locate(sessionID: String) -> URL? {
        if let cached = sessionPaths[sessionID] { return cached }
        for url in allTranscriptFiles() {
            sessionPaths[url.deletingPathExtension().lastPathComponent] = url
        }
        return sessionPaths[sessionID]
    }

    private func allTranscriptFiles() -> [URL] {
        guard let projectDirs = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var files: [URL] = []
        for dir in projectDirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            guard let entries = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            files.append(contentsOf: entries.filter { $0.pathExtension == "jsonl" })
        }
        return files
    }

    /// 按 (path, mtime, size) 缓存解析结果；未变化时不重读文件。
    private func entry(for url: URL) -> CacheEntry? {
        let path = url.path
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.intValue
        else { return nil }

        if let cached = cache[path], cached.mtime == mtime, cached.size == size {
            return cached
        }

        let meta = TranscriptReader.meta(fromTail: TranscriptReader.readTail(url))
        let cwd = TranscriptReader.cwd(fromHead: TranscriptReader.readHead(url))
        let fresh = CacheEntry(mtime: mtime, size: size, cwd: cwd, meta: meta)
        cache[path] = fresh
        return fresh
    }
}
