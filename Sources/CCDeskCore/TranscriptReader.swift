import Foundation

/// 会话标题相关字段，取自 transcript 尾部反复追加的记录（见 TranscriptReader）。
public struct TranscriptMeta: Equatable, Sendable {
    public let customTitle: String?
    public let aiTitle: String?
    public let lastPrompt: String?

    public init(customTitle: String? = nil, aiTitle: String? = nil, lastPrompt: String? = nil) {
        self.customTitle = customTitle
        self.aiTitle = aiTitle
        self.lastPrompt = lastPrompt
    }

    /// 标题规则：customTitle → aiTitle → lastPrompt 前 20 个字符（单行化）→ 非派生的 fallbackName → "新会话"。
    /// 所有候选都会先 trim 空白，空的候选会被跳过。
    public func displayTitle(fallbackName: String?, fallbackIsDerived: Bool) -> String {
        let candidates: [String?] = [
            customTitle,
            aiTitle,
            lastPrompt.map(Self.truncatedPrompt),
            fallbackIsDerived ? nil : fallbackName,
        ]
        for candidate in candidates {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { continue }
            return trimmed
        }
        return "新会话"
    }

    private static func truncatedPrompt(_ prompt: String) -> String {
        let collapsed = prompt
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > 20 else { return collapsed }
        return String(collapsed.prefix(20)) + "…"
    }
}

/// 读取 `~/.claude/projects/<编码目录>/<sessionId>.jsonl` 的标题与 cwd 字段。
/// 文件可达 100MB+，禁止整文件读取：标题只读尾部，cwd 只读头部。
public enum TranscriptReader {
    public static let defaultTailBytes = 256 * 1024
    public static let defaultHeadBytes = 64 * 1024

    public static func readTail(_ url: URL, bytes: Int = defaultTailBytes) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return Data() }
        let readBytes = min(UInt64(max(0, bytes)), size)
        let offset = size - readBytes
        guard (try? handle.seek(toOffset: offset)) != nil else { return Data() }
        return (try? handle.readToEnd()) ?? Data()
    }

    public static func readHead(_ url: URL, bytes: Int = defaultHeadBytes) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: max(0, bytes))) ?? Data()
    }

    /// 逐行解析，取最后出现的 customTitle / aiTitle / 带文本的 lastPrompt。
    /// 容忍首行残缺（tail 截断导致）：残缺行无法解析为 JSON，直接跳过。
    public static func meta(fromTail data: Data) -> TranscriptMeta {
        var customTitle: String?
        var aiTitle: String?
        var lastPrompt: String?
        for line in lines(in: data) {
            guard let obj = jsonObject(line) else { continue }
            if let v = obj["customTitle"] as? String { customTitle = v }
            if let v = obj["aiTitle"] as? String { aiTitle = v }
            if let v = obj["lastPrompt"] as? String, !v.isEmpty { lastPrompt = v }
        }
        return TranscriptMeta(customTitle: customTitle, aiTitle: aiTitle, lastPrompt: lastPrompt)
    }

    /// 第一个含非空 cwd 字段的记录。
    public static func cwd(fromHead data: Data) -> String? {
        for line in lines(in: data) {
            guard let obj = jsonObject(line), let cwd = obj["cwd"] as? String, !cwd.isEmpty else { continue }
            return cwd
        }
        return nil
    }

    /// 按换行拆分字节，逐行独立解码为 UTF-8；块边界处可能出现无效 UTF-8 或残缺字节，解码失败的行直接跳过。
    private static func lines(in data: Data) -> [String] {
        data.split(separator: UInt8(ascii: "\n")).compactMap { chunk in
            String(data: chunk, encoding: .utf8)
        }
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        return obj
    }
}
