import Foundation

// MARK: - 通用助手（设计 §24）：命令行、设置与引擎、回答解析、朗读切分

/// 通用助手的 claude 参数（claude 2.1.280 实测，见设计 §24 实现记录）。由常驻会话类拼在
/// `-p --model sonnet --input-format stream-json --output-format stream-json --verbose` 之后。
///
/// - `--restricted`：不读用户 / 项目 / 本地 settings（用户的 hook 不运行），文件工具限定在工作目录；
/// - `--strict-mcp-config`（没有 `--mcp-config`）：不加载任何 MCP 服务器；
/// - `--tools WebSearch,WebFetch` + `--allowedTools WebSearch,WebFetch`：init 里只有这两个工具，调用不需要批准；
///   不允许上网时 `--tools ""`（一个工具都没有）；
/// - `--permission-prompts none`：其他任何需要批准的调用自动拒绝，不会卡住；
/// - `--system-prompt-snapshot off`：系统提示词不记进会话，接回时用这次启动传入的（人设 / 上网开关改了，
///   重启进程即可生效，记忆不丢）。
public enum CompanionCommand {
    public static let model = "sonnet"
    public static let webTools = ["WebSearch", "WebFetch"]
    /// 一次回答的超时。
    public static let timeout: TimeInterval = 90
    /// 上下文（最后一次模型调用的输入）超过这么多 token 时，这次回答之后换新会话（网页结果会让上下文涨得很快）。
    public static let rotateInputTokens = 40_000
    /// 最多排队的问题数（不含正在回答的那个）。
    public static let maxQueued = 3

    public static func toolArguments(web: Bool) -> [String] {
        var args = ["--restricted", "--strict-mcp-config", "--permission-prompts", "none", "--system-prompt-snapshot", "off"]
        if web {
            let tools = webTools.joined(separator: ",")
            args += ["--tools", tools, "--allowedTools", tools]
        } else {
            args += ["--tools", ""]
        }
        return args
    }
}

/// 设置 › 语音 › 通用助手的开关（UserDefaults）。
public struct CompanionPreferences: Equatable, Sendable {
    public static let enabledKey = "companionEnabled"
    public static let webKey = "companionWeb"

    public var enabled: Bool
    /// 允许上网搜索（只对 Claude Code 有效；通用 API 没有搜索工具）。
    public var web: Bool

    public init(enabled: Bool = true, web: Bool = true) {
        self.enabled = enabled
        self.web = web
    }

    public static func load(_ defaults: UserDefaults = .standard) -> CompanionPreferences {
        CompanionPreferences(enabled: defaults.object(forKey: enabledKey) as? Bool ?? true,
                             web: defaults.object(forKey: webKey) as? Bool ?? true)
    }
}

/// 通用助手用哪个模型：跟着语音助手的后端走。
public enum CompanionEngine: Equatable, Sendable {
    /// Claude Code 的 Sonnet 常驻会话。
    case claude(model: String, web: Bool)
    /// 通用 API：设置里的「通用助手模型」，没填时与助手相同；没有上网工具。
    case api(model: String)
    case unavailable(Reason)

    public enum Reason: String, Equatable, Sendable {
        /// 设置里关掉了。
        case disabled
        /// 助手是「仅本地规则」（没有模型）。
        case localOnly
        /// 还在解析 claude（几秒内就好）。
        case resolving
    }

    /// companionModel：设置里的「通用助手模型」（空 = 与助手相同）。
    public static func resolve(_ preferences: CompanionPreferences, backend: AssistantBackendKind?,
                               api: AssistantAPISettings, companionModel: String) -> CompanionEngine {
        guard preferences.enabled else { return .unavailable(.disabled) }
        switch backend {
        case nil: return .unavailable(.resolving)
        case .claude?: return .claude(model: CompanionCommand.model, web: preferences.web)
        case .api?: return .api(model: api.companionModel(companionModel))
        case .local?: return .unavailable(.localOnly)
        }
    }

    /// 显示用的模型名（Claude 时 "sonnet"）；不可用时 nil。
    public var model: String? {
        switch self {
        case .claude(let model, _), .api(let model): return model
        case .unavailable: return nil
        }
    }
}

extension AssistantAPISettings {
    public static let companionModelKey = "assistantAPICompanionModel"

    /// 通用助手用的模型（设置里的「通用助手模型」）；空 = 与助手相同。
    public static func companionModel(_ defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: companionModelKey) ?? ""
    }

    /// 通用助手实际用的模型：own（设置里填的）为空时与助手相同。
    public func companionModel(_ own: String) -> String {
        let trimmed = own.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? trimmedModel : trimmed
    }
}

// MARK: - 回答

/// 回答里列出的网页来源。
public struct CompanionSource: Equatable, Codable, Sendable {
    public let title: String
    public let url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

public enum CompanionAnswer {
    static let sourceHeaders = ["sources", "source", "references", "来源", "参考来源", "资料来源", "参考资料", "信息来源"]

    /// 把回答拆成正文与末尾的来源列表（WebSearch 会让模型在最后加「Sources:」与 markdown 链接）。
    public static func parse(_ raw: String) -> (text: String, sources: [CompanionSource]) {
        let lines = raw.components(separatedBy: .newlines)
        guard let start = lines.lastIndex(where: isSourceHeader) else {
            return (raw.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        let text = lines[..<start].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var sources: [CompanionSource] = []
        let tail = lines[start...].joined(separator: "\n")
        let link = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#)
        let range = NSRange(tail.startIndex..., in: tail)
        for match in link?.matches(in: tail, range: range) ?? [] {
            guard let t = Range(match.range(at: 1), in: tail), let u = Range(match.range(at: 2), in: tail) else { continue }
            let url = String(tail[u])
            if !sources.contains(where: { $0.url == url }) { sources.append(CompanionSource(title: String(tail[t]), url: url)) }
        }
        // 没有 markdown 链接时取裸网址。
        if sources.isEmpty, let bare = try? NSRegularExpression(pattern: #"https?://[^\s)\]]+"#) {
            for match in bare.matches(in: tail, range: range) {
                guard let u = Range(match.range, in: tail) else { continue }
                let url = String(tail[u])
                if !sources.contains(where: { $0.url == url }) { sources.append(CompanionSource(title: url, url: url)) }
            }
        }
        // 「来源」行之后什么链接都没有：不是来源列表，原样保留。
        guard !sources.isEmpty else { return (raw.trimmingCharacters(in: .whitespacesAndNewlines), []) }
        return (text, sources)
    }

    static func isSourceHeader(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#*_ "))
            .lowercased()
        return sourceHeaders.contains { header in
            t == header || t.hasPrefix(header + ":") || t.hasPrefix(header + "：")
        }
    }

    /// 上网用过的搜索词 / 网址（结果面板里显示）。
    public static func webLookups(_ uses: [AssistantToolUse]) -> [String] {
        uses.filter { CompanionCommand.webTools.contains($0.name) && !$0.detail.isEmpty }.map(\.detail)
    }
}

// MARK: - 朗读

/// 通用助手的回答怎么念：只念开头两三句（第一段），其余在结果面板里，「继续说」再念下一段。
public enum CompanionSpeech {
    public static let maxSentences = 3

    /// 朗读用的纯文字：去掉代码、链接网址、markdown 符号与列表标记，每段合成一行，段之间空一行。
    public static func plain(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        let paragraphs = t.components(separatedBy: "\n\n").map { paragraph -> String in
            paragraph.components(separatedBy: .newlines).map { line -> String in
                var l = line.trimmingCharacters(in: .whitespaces)
                l = l.replacingOccurrences(of: #"^([-*+•]|\d+[.)、])\s+"#, with: "", options: .regularExpression)
                l = l.replacingOccurrences(of: #"[`*#_>|]"#, with: "", options: .regularExpression)
                return l.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }.joined(separator: " ")
        }.filter { !$0.isEmpty }
        return paragraphs.joined(separator: "\n\n")
    }

    /// 分句：在 。！？；… 与英文句末标点（后面是空白或结尾）之后断开；标点留在句子里。
    public static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            let breaks: Bool
            switch ch {
            case "。", "！", "？", "；", "…": breaks = next.map { !"。！？…”」』)）".contains($0) } ?? true
            case ".", "!", "?", ";": breaks = next.map { $0.isWhitespace } ?? true
            case "\n": breaks = true
            default: breaks = false
            }
            if breaks {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { out.append(s) }
                current = ""
            }
        }
        let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { out.append(s) }
        return out
    }

    /// 一次念多少：中文约 110 字、英文约 260 个字符（各约 30 秒以内）。
    static func budget(_ text: String) -> Int {
        text.unicodeScalars.contains(where: TranscriptCleaner.isCJK) ? 110 : 260
    }

    /// 切出这次要念的部分与剩下的：只在第一段里取，最多 `maxSentences` 句、不超过字数（至少一句；
    /// 一句本身太长时在逗号处截断）。剩下的为空时 rest 为 nil。
    public static func split(_ text: String) -> (head: String, rest: String?) {
        let plainText = plain(text)
        var paragraphs = plainText.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { return ("", nil) }
        let first = paragraphs.removeFirst()
        let limit = budget(first)
        var sentences = Self.sentences(first)
        var head: [String] = []
        var used = 0
        while let next = sentences.first, head.count < maxSentences, head.isEmpty || used + next.count <= limit {
            head.append(next)
            used += next.count
            sentences.removeFirst()
        }
        var spoken = join(head)
        if spoken.count > limit * 2 {
            // 一句太长：在限度内最后一个逗号处断开，后半句放回剩余部分。
            let prefix = String(spoken.prefix(limit * 2))
            if let cut = prefix.lastIndex(where: { "，,、：:".contains($0) }) {
                sentences.insert(String(spoken[spoken.index(after: cut)...]).trimmingCharacters(in: .whitespaces), at: 0)
                spoken = String(spoken[...cut])
            }
        }
        let restParts = (sentences.isEmpty ? [] : [join(sentences)]) + paragraphs
        let rest = restParts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (spoken, rest.isEmpty ? nil : rest)
    }

    /// 拼句子：中文之间不加空格，其他加一个空格。
    static func join(_ parts: [String]) -> String {
        parts.reduce("") { acc, s in acc.isEmpty ? s : acc + ConversationText.insertion(s, after: acc) }
    }

    static let continuePhrases: Set<String> = [
        "继续说", "接着说", "说下去", "继续讲", "接着讲", "往下说", "继续念", "接着念", "继续读", "接着读", "后面呢", "继续往下说",
        "goon", "continue", "keepgoing", "carryon", "keepreading",
    ]

    /// 「继续说」：接着念通用助手上一个回答剩下的部分（本地规则，不经过语音助手）。
    public static func isContinue(_ utterance: String) -> Bool {
        ConversationCommands.candidates(ConversationCommands.normalize(utterance)).contains(where: continuePhrases.contains)
    }
}
