import Foundation

/// 一个会话（含 Claude 子 agent）的累计用量。
public struct SessionTokenSummary: Equatable, Sendable {
    public var usage: TokenUsage
    /// 回复次数（去重后的用量记录数）。
    public var replies: Int
    /// Codex：最近一次请求占用的上下文与上下文窗口。
    public var contextUsed: Int?
    public var contextWindow: Int?

    public init(usage: TokenUsage = .zero, replies: Int = 0, contextUsed: Int? = nil, contextWindow: Int? = nil) {
        self.usage = usage
        self.replies = replies
        self.contextUsed = contextUsed
        self.contextWindow = contextWindow
    }

    /// 上下文已用比例（0–1）；不知道窗口时为 nil。
    public var contextFraction: Double? {
        guard let used = contextUsed, let window = contextWindow, window > 0 else { return nil }
        return min(Double(used) / Double(window), 1)
    }
}

/// 一段时间内的用量汇总。
public struct TokenSummary: Equatable, Sendable {
    public struct Slice: Equatable, Sendable, Identifiable {
        public let name: String
        public let usage: TokenUsage
        public var id: String { name }

        public init(name: String, usage: TokenUsage) {
            self.name = name
            self.usage = usage
        }
    }

    public var total: TokenUsage
    /// 都按 total 从大到小。
    public var byAgent: [Slice]
    public var byProject: [Slice]
    public var byModel: [Slice]

    public init(total: TokenUsage = .zero, byAgent: [Slice] = [], byProject: [Slice] = [], byModel: [Slice] = []) {
        self.total = total
        self.byAgent = byAgent
        self.byProject = byProject
        self.byModel = byModel
    }

    public static let empty = TokenSummary()
}

/// 统计 Claude / Codex / pi 会话记录里的 token 用量。只增量读取文件新增的部分（记住读到的位置），
/// 只看最近 `window` 内写过的文件（更早的文件不可能有窗口内的记录）。
/// 非线程安全；只在单个串行队列上使用。
public final class TokenLedger {
    public struct Roots: Sendable {
        public var claude: URL
        public var codex: URL
        public var pi: URL
        public var openCode: URL

        public init(claude: URL = TranscriptIndex.defaultRoot, codex: URL = AgentSessionIndex.defaultCodexRoot,
                    pi: URL = AgentSessionIndex.defaultPiRoot, openCode: URL = OpenCodeMirror.defaultRoot) {
            self.claude = claude
            self.codex = codex
            self.pi = pi
            self.openCode = openCode
        }
    }

    private struct FileState {
        let kind: AgentKind
        /// Claude 子 agent 的记录归到父会话。
        let sessionID: String
        var cwd: String?
        var offset: UInt64 = 0
        var size: UInt64 = 0
        var mtime: Date = .distantPast
        var parser: TokenUsageParser
        var records: [TokenRecord] = []
    }

    public static let window: TimeInterval = 7 * 86400

    private let roots: Roots
    private let fileManager: FileManager
    private var files: [String: FileState] = [:]
    /// 增量读取时一次最多读这么多（超大文件分几轮读完，避免一次占用太多内存）。
    static let chunkBytes = 4 * 1024 * 1024

    public init(roots: Roots = Roots(), fileManager: FileManager = .default) {
        self.roots = roots
        self.fileManager = fileManager
    }

    /// 扫描目录，读取所有最近 `window` 内写过的文件的新增部分；窗口外且不再变化的文件丢弃。
    public func refresh(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.window)
        var seen: Set<String> = []
        for (url, kind, sessionID) in candidates() {
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date, mtime >= cutoff else { continue }
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            seen.insert(url.path)
            update(path: url.path, kind: kind, sessionID: sessionID, mtime: mtime, size: size)
        }
        for path in files.keys where !seen.contains(path) { files[path] = nil }
    }

    /// 某个会话的累计用量（含 Claude 子 agent）；没有记录时为 nil。
    public func session(kind: AgentKind, sessionID: String) -> SessionTokenSummary? {
        var summary = SessionTokenSummary()
        var keys: Set<String> = []
        var found = false
        for (_, f) in files where f.kind == kind && f.sessionID == sessionID {
            found = true
            for r in Self.dedupe(f.records, seen: &keys) {
                summary.usage += r.usage
                summary.replies += 1
            }
            if f.parser.contextUsed != nil {
                summary.contextUsed = f.parser.contextUsed
                summary.contextWindow = f.parser.contextWindow
            }
        }
        return found && summary.replies > 0 ? summary : nil
    }

    /// `since` 之后的用量汇总；project 把 cwd 映射成项目名（nil cwd 记为「其他」）。
    public func summary(since: Date, project: (String?) -> String) -> TokenSummary {
        var total = TokenUsage.zero
        var agents: [String: TokenUsage] = [:]
        var projects: [String: TokenUsage] = [:]
        var models: [String: TokenUsage] = [:]
        var keys: Set<String> = []
        // 按路径排序，去重结果稳定（续接会话重放的旧回复只算一次）。
        for path in files.keys.sorted() {
            guard let f = files[path] else { continue }
            let proj = project(f.cwd)
            for r in Self.dedupe(f.records, seen: &keys) where r.date >= since {
                total += r.usage
                agents[f.kind.displayName, default: .zero] += r.usage
                projects[proj, default: .zero] += r.usage
                models[r.model ?? "?", default: .zero] += r.usage
            }
        }
        func slices(_ d: [String: TokenUsage]) -> [TokenSummary.Slice] {
            d.map { TokenSummary.Slice(name: $0.key, usage: $0.value) }
                .sorted { $0.usage.total != $1.usage.total ? $0.usage.total > $1.usage.total : $0.name < $1.name }
        }
        return TokenSummary(total: total, byAgent: slices(agents), byProject: slices(projects), byModel: slices(models))
    }

    // MARK: 内部

    /// 按 key 去重，同一 key 取最后一条（Claude 流式写入时后面的行用量更完整）。
    private static func dedupe(_ records: [TokenRecord], seen: inout Set<String>) -> [TokenRecord] {
        var lastIndex: [String: Int] = [:]
        for (i, r) in records.enumerated() { if let k = r.key { lastIndex[k] = i } }
        var out: [TokenRecord] = []
        for (i, r) in records.enumerated() {
            guard let k = r.key else { out.append(r); continue }
            guard lastIndex[k] == i, !seen.contains(k) else { continue }
            seen.insert(k)
            out.append(r)
        }
        return out
    }

    private func update(path: String, kind: AgentKind, sessionID: String, mtime: Date, size: UInt64) {
        var f = files[path] ?? FileState(kind: kind, sessionID: sessionID, parser: TokenUsageParser(kind: kind))
        if size < f.offset {
            // 文件被截断或重写：从头再读。
            f = FileState(kind: kind, sessionID: sessionID, parser: TokenUsageParser(kind: kind))
        }
        if size == f.size, mtime == f.mtime, files[path] != nil { return }
        f.size = size
        f.mtime = mtime
        read(&f, path: path, size: size)
        files[path] = f
    }

    private func read(_ f: inout FileState, path: String, size: UInt64) {
        guard f.offset < size, let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        var more = true
        while more, f.offset < size {
            // 每块读完就释放（块数据和每行的 JSON 临时对象），否则首次扫描会把几百 MB 攒到最后。
            more = autoreleasepool { readChunk(&f, handle: handle, size: size) }
        }
    }

    /// 读一块并处理其中完整的行；最后半行（还在写）留到下次。返回是否还要继续读。
    private func readChunk(_ f: inout FileState, handle: FileHandle, size: UInt64) -> Bool {
        do { try handle.seek(toOffset: f.offset) } catch { return false }
        let want = Int(min(size - f.offset, UInt64(Self.chunkBytes)))
        guard let data = try? handle.read(upToCount: want), !data.isEmpty else { return false }
        let consumed = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress else { return 0 }
            var start = 0
            while start < bytes.count,
                  let nl = memchr(base + start, Int32(UInt8(ascii: "\n")), bytes.count - start) {
                let end = base.distance(to: nl.assumingMemoryBound(to: UInt8.self))
                if end > start {
                    let line = UnsafeBufferPointer(rebasing: bytes[start..<end])
                    if f.cwd == nil { f.cwd = Self.cwd(kind: f.kind, line: line) }
                    if let r = f.parser.consume(line) { f.records.append(r) }
                }
                start = end + 1
            }
            return start
        }
        if consumed == 0 {
            // 超长的单行（大于一块）整块跳过，避免卡住。
            guard data.count >= Self.chunkBytes else { return false }
            f.offset += UInt64(data.count)
            return true
        }
        f.offset += UInt64(consumed)
        return true
    }

    /// 从行里取工作目录：Claude 每行都有 cwd，Codex 在 session_meta，pi 在首行 session。
    static func cwd(kind: AgentKind, line: UnsafeBufferPointer<UInt8>) -> String? {
        guard ByteScan.find(line, "\"cwd\"") != nil,
              let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { return nil }
        switch kind {
        case .claude, .pi, .opencode: return (obj["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        case .codex: return ((obj["payload"] as? [String: Any])?["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        case .other: return nil
        }
    }

    /// 文件对应的会话 id：Claude 为文件名（子 agent 为上两级目录名），Codex / pi 取文件名末尾的 uuid。
    static func sessionID(kind: AgentKind, url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        switch kind {
        case .claude:
            if url.deletingLastPathComponent().lastPathComponent == "subagents" {
                return url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            }
            return name
        case .codex, .pi:
            // rollout-2026-10-03T13-03-11-<uuid> / 2026-10-03T06-01-30-000Z_<uuid>：uuid 是最后 36 个字符。
            return name.count >= 36 ? String(name.suffix(36)) : name
        case .opencode, .other:
            return name
        }
    }

    private func candidates() -> [(URL, AgentKind, String)] {
        var out: [(URL, AgentKind, String)] = []
        for dir in subdirectories(of: roots.claude) {
            for url in jsonl(in: dir) { out.append((url, .claude, Self.sessionID(kind: .claude, url: url))) }
            // <项目>/<sessionId>/subagents/agent-*.jsonl
            for session in subdirectories(of: dir) {
                for url in jsonl(in: session.appendingPathComponent("subagents", isDirectory: true)) {
                    out.append((url, .claude, session.lastPathComponent))
                }
            }
        }
        for year in subdirectories(of: roots.codex) {
            for month in subdirectories(of: year) {
                for day in subdirectories(of: month) {
                    for url in jsonl(in: day) { out.append((url, .codex, Self.sessionID(kind: .codex, url: url))) }
                }
            }
        }
        for dir in subdirectories(of: roots.pi) {
            for url in jsonl(in: dir) { out.append((url, .pi, Self.sessionID(kind: .pi, url: url))) }
        }
        for url in jsonl(in: roots.openCode) { out.append((url, .opencode, Self.sessionID(kind: .opencode, url: url))) }
        return out
    }

    private func jsonl(in dir: URL) -> [URL] {
        ((try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
    }

    private func subdirectories(of dir: URL) -> [URL] {
        ((try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false }
    }
}

/// 侧栏底部 / 用量详情里的 token 汇总：今天（本地时区零点起）与最近 7 天。
public struct TokenOverview: Equatable, Sendable {
    public var today: TokenSummary
    public var week: TokenSummary

    public init(today: TokenSummary, week: TokenSummary) {
        self.today = today
        self.week = week
    }

    public var isEmpty: Bool { week.total.isZero }
}

extension TokenUsage {
    /// 「输入 2K · 输出 30K · 缓存读 1.1M · 缓存写 40K」，为 0 的项省略。
    public var breakdownText: String {
        var parts: [String] = []
        if input > 0 { parts.append(L("tokens.input", TokenUsage.compact(input))) }
        if output > 0 { parts.append(L("tokens.output", TokenUsage.compact(output))) }
        if cacheRead > 0 { parts.append(L("tokens.cacheRead", TokenUsage.compact(cacheRead))) }
        if cacheWrite > 0 { parts.append(L("tokens.cacheWrite", TokenUsage.compact(cacheWrite))) }
        return parts.joined(separator: " · ")
    }
}

extension SessionTokenSummary {
    /// 会话行悬停提示里的一段：「Token 1.2M（输入 2K · 输出 30K · …）\n缓存命中 95% · 上下文 62%」。
    public var tooltipText: String {
        var lines = [L("tokens.sessionLine", TokenUsage.compact(usage.total), usage.breakdownText)]
        var extra: [String] = []
        if let hit = usage.cacheHitRate, usage.cacheRead > 0 {
            extra.append(L("tokens.cacheHit", Int((hit * 100).rounded())))
        }
        if let ctx = contextFraction { extra.append(L("tokens.context", Int((ctx * 100).rounded()))) }
        if !extra.isEmpty { lines.append(extra.joined(separator: " · ")) }
        return lines.joined(separator: "\n")
    }
}
