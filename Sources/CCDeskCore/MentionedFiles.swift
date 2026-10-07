import Foundation

/// agent 在自己的回复文字里提到的文件（设计 §17.1「提到 / 生成的文件」）。
///
/// - 只看 agent 自己说的话：Claude `assistant` 行的 `text` 块；Codex `response_item` 里 assistant 的 `output_text`
///   与 `event_msg` 的 `agent_message`；pi `message`（role assistant）的 `text` 块。不看工具输出与用户输入。
/// - 路径片段的切分与清理沿用 `TerminalPaths`（空白 / 引号 / 反引号 / 括号 / 中文标点为边界，去掉 `file://`、
///   末尾标点、`:行[:列]`、`#L行`，排除 URL 与纯数字）；另外去掉 Markdown 的 `*`，
///   紧贴着中文的路径（「已保存到out/a.png里」）再试一次去掉两端的非 ASCII 文字。
/// - 相对路径按该行的 `cwd`（没有时按会话 cwd）解析，`~/` 展开；**只收存在的普通文件**（目录不收）。
public enum MentionedFiles {
    /// 每条消息最多看这么多字符 / 这么多个路径片段（长篇输出里的路径很少是产出）。
    static let maxTextLength = 20_000
    static let maxTokensPerMessage = 300
    /// 每个会话最多保留的提到的文件（最近提到的优先）。
    public static let maxKept = 200

    /// 一行里可能有 agent 回复文字的特征字节；不含这些的行不做 JSON 解析。
    static func markers(for kind: AgentKind) -> [Data] {
        switch kind {
        case .claude, .pi, .opencode: return [Data(#""type":"text""#.utf8)]
        case .codex: return [Data(#""output_text""#.utf8), Data(#""agent_message""#.utf8)]
        case .other: return []
        }
    }

    /// 一行会话记录里 agent 自己说的话。
    static func texts(kind: AgentKind, obj: [String: Any]) -> [String] {
        switch kind {
        case .claude:
            guard obj["type"] as? String == "assistant", let message = obj["message"] as? [String: Any] else { return [] }
            return textBlocks(message["content"], type: "text")
        case .codex:
            guard let payload = obj["payload"] as? [String: Any] else { return [] }
            switch (obj["type"] as? String, payload["type"] as? String) {
            case ("response_item", "message"):
                guard payload["role"] as? String == "assistant" else { return [] }
                return textBlocks(payload["content"], type: "output_text")
            case ("event_msg", "agent_message"):
                return (payload["message"] as? String).map { [$0] } ?? []
            default:
                return []
            }
        case .pi, .opencode:
            guard obj["type"] as? String == "message", let message = obj["message"] as? [String: Any],
                  message["role"] as? String == "assistant" else { return [] }
            return textBlocks(message["content"], type: "text")
        case .other:
            return []
        }
    }

    private static func textBlocks(_ content: Any?, type: String) -> [String] {
        if let text = content as? String { return [text] }
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { $0["type"] as? String == type ? $0["text"] as? String : nil }
    }

    /// 文字里像路径的片段（已清理），按出现顺序去重，最多 `maxTokensPerMessage` 个。
    public static func tokens(in text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        var current = ""
        func flush() {
            defer { current = "" }
            guard !current.isEmpty, current.count <= 1024 else { return }
            let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            guard let token = TerminalPaths.clean(trimmed), looksLikePath(token), !token.contains("://") else { return }
            if seen.insert(token).inserted { out.append(token) }
        }
        for c in text.prefix(maxTextLength) {
            if TerminalPaths.isDelimiter(c) {
                flush()
                if out.count >= maxTokensPerMessage { break }
            } else {
                current.append(c)
            }
        }
        if out.count < maxTokensPerMessage { flush() }
        return out
    }

    /// 含 "/"，或以 1–8 个字母数字的扩展名结尾（如 report.md）。
    static func looksLikePath(_ token: String) -> Bool {
        if token.contains("/") { return true }
        guard let dot = token.lastIndex(of: "."), dot != token.startIndex else { return false }
        let ext = token[token.index(after: dot)...]
        return (1...8).contains(ext.count) && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// 一个片段的候选写法：原样；开头 / 结尾紧贴着非 ASCII 文字（中文句子里没有空格）时，再试去掉它们的版本。
    static func variants(of token: String) -> [String] {
        var out = [token]
        func add(_ s: Substring) {
            let v = String(s)
            if !v.isEmpty, !out.contains(v), let cleaned = TerminalPaths.clean(v), looksLikePath(cleaned) { out.append(cleaned) }
        }
        let startsWide = token.first.map { !$0.isASCII } ?? false
        let endsWide = token.last.map { !$0.isASCII } ?? false
        guard startsWide || endsWide else { return out }
        var s = Substring(token)
        if startsWide, let first = s.firstIndex(where: \.isASCII) { s = s[first...] }
        if endsWide, let last = s.lastIndex(where: \.isASCII) { s = s[...last] }
        add(s)
        return out
    }

    /// 文字里提到、且确实存在的普通文件的绝对路径（按出现顺序）。
    public static func paths(in text: String, base: String, home: String = NSHomeDirectory(),
                             isFile: (String) -> Bool = MentionedFiles.isRegularFile) -> [String] {
        var out: [String] = []
        for token in tokens(in: text) {
            let found = variants(of: token).lazy
                .flatMap { TerminalPaths.candidates(for: $0, cwd: base, home: home) }
                .first(where: isFile)
            if let found, !out.contains(found) { out.append(found) }
        }
        return out
    }

    /// 存在且是普通文件（跟随符号链接；目录、FIFO、设备都不算）。
    public static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }
}

/// 一个会话里提到的文件（可增量追加，最多保留 `MentionedFiles.maxKept` 个最近提到的）。
public struct MentionedFilesLog: Sendable {
    struct Entry: Sendable {
        var first: Date?
        var last: Date?
        var count = 0
        var sequence = 0
    }

    private(set) var entries: [String: Entry] = [:]
    private var sequence = 0
    public let kind: AgentKind
    public let cwd: String

    public init(kind: AgentKind, cwd: String) {
        self.kind = kind
        self.cwd = cwd
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// 一行（已解析的）记录里提到的文件。
    mutating func ingest(obj: [String: Any], time: Date?, isFile: (String) -> Bool = MentionedFiles.isRegularFile) {
        let texts = MentionedFiles.texts(kind: kind, obj: obj)
        guard !texts.isEmpty else { return }
        let base = (obj["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? cwd
        for text in texts {
            for path in MentionedFiles.paths(in: text, base: base, isFile: isFile) { record(path, at: time) }
        }
    }

    mutating func record(_ path: String, at time: Date?) {
        sequence += 1
        var e = entries[path] ?? Entry()
        e.count += 1
        e.first = e.first ?? time
        if let time { e.last = max(e.last ?? time, time) }
        e.sequence = sequence
        entries[path] = e
        if entries.count > MentionedFiles.maxKept, let oldest = entries.min(by: { $0.value.sequence < $1.value.sequence }) {
            entries[oldest.key] = nil
        }
    }

    /// 快照：最近提到的在前。
    public func files(exists: (String) -> Bool = MentionedFiles.isRegularFile) -> [TouchedFile] {
        entries.sorted { $0.value.sequence > $1.value.sequence }.map { path, e in
            TouchedFile(path: path, firstTouched: e.first, lastTouched: e.last, action: .modified, count: e.count,
                        isDocument: TouchedFiles.isDocument(path), exists: exists(path), origin: .mentioned)
        }
    }
}
