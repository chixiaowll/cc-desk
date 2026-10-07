import Foundation

/// 一次或一段调用的 token 用量。各 agent 的口径统一为：
/// input = 未命中缓存的输入，cacheRead = 读缓存的输入，cacheWrite = 写缓存的输入，output = 输出（含思考 / 推理）。
public struct TokenUsage: Equatable, Hashable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public static let zero = TokenUsage()

    public var total: Int { input + output + cacheRead + cacheWrite }
    public var isZero: Bool { total == 0 }

    /// 输入中命中缓存的比例（0–1）；没有输入时为 nil。
    public var cacheHitRate: Double? {
        let all = input + cacheRead + cacheWrite
        return all > 0 ? Double(cacheRead) / Double(all) : nil
    }

    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, output: a.output + b.output,
                   cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }

    public static func += (a: inout TokenUsage, b: TokenUsage) { a = a + b }

    /// 紧凑数字：950、12.3K、4.56M、1.2B。
    public static func compact(_ n: Int) -> String {
        let v = Double(n)
        func fmt(_ x: Double, _ unit: String) -> String {
            let digits = x >= 100 ? 0 : (x >= 10 ? 1 : 2)
            var s = String(format: "%.\(digits)f", x)
            if s.contains(".") {
                while s.hasSuffix("0") { s.removeLast() }
                if s.hasSuffix(".") { s.removeLast() }
            }
            return s + unit
        }
        if n < 1000 { return "\(n)" }
        if v < 1e6 { return fmt(v / 1e3, "K") }
        if v < 1e9 { return fmt(v / 1e6, "M") }
        return fmt(v / 1e9, "B")
    }
}

/// 会话记录里的一条用量。
public struct TokenRecord: Equatable, Sendable {
    /// 去重键：Claude 的一条回复会分成多行写入（同一 message.id），续接会话也可能重放旧回复；nil 表示不去重。
    public let key: String?
    public let date: Date
    public let model: String?
    public let usage: TokenUsage

    public init(key: String?, date: Date, model: String?, usage: TokenUsage) {
        self.key = key
        self.date = date
        self.model = model
        self.usage = usage
    }
}

/// 逐行解析会话记录里的用量。有状态（Codex 的用量是累计值、模型在 turn_context 里），每个文件一个实例，按顺序喂行。
///
/// - Claude：`{"type":"assistant","timestamp","message":{"id","model","usage":{input_tokens, output_tokens,
///   cache_creation_input_tokens, cache_read_input_tokens}}}`；同一 message.id 的多行用量相同，按 id 去重（取最后一行）。
/// - Codex：`{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{input_tokens(含缓存),
///   cached_input_tokens, output_tokens(含推理)}, "last_token_usage", "model_context_window"}}}`；
///   取累计值的增量（重复上报同一累计值时增量为 0）；模型取自最近的 `turn_context.payload.model`。
/// - pi：`{"type":"message","id","timestamp","message":{"role":"assistant","model","usage":{input, output, cacheRead, cacheWrite}}}`。
public struct TokenUsageParser: Sendable {
    public let kind: AgentKind
    private var codexTotal = TokenUsage.zero
    private var codexModel: String?
    /// Codex 最近一次请求占用的上下文（token）与上下文窗口。
    public private(set) var contextUsed: Int?
    public private(set) var contextWindow: Int?

    public init(kind: AgentKind) {
        self.kind = kind
    }

    /// 快速预筛：不可能含用量的行直接跳过，不做 JSON 解析（Claude 的记录大部分是工具结果）。
    static func mayContainUsage(_ line: UnsafeBufferPointer<UInt8>, kind: AgentKind) -> Bool {
        switch kind {
        case .claude: return ByteScan.find(line, "\"usage\":{") != nil
        case .codex: return ByteScan.find(line, "\"token_count\"") != nil || ByteScan.find(line, "\"turn_context\"") != nil
        case .pi, .opencode: return ByteScan.find(line, "\"usage\"") != nil
        case .other: return false
        }
    }

    public mutating func consume(_ line: Data) -> TokenRecord? {
        line.withUnsafeBytes { consume($0.bindMemory(to: UInt8.self)) }
    }

    /// 一行（不含换行符）。
    public mutating func consume(_ line: UnsafeBufferPointer<UInt8>) -> TokenRecord? {
        guard Self.mayContainUsage(line, kind: kind) else { return nil }
        if kind == .claude { return Self.claudeFast(line) }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { return nil }
        return consume(obj)
    }

    /// Claude 的回复行常带几 KB 的正文 / 思考，整行解析是首次扫描的大头：只截出 `"usage":{…}` 这一小段解析，
    /// message.id / model / timestamp 按键名直接取字符串值。JSON 字符串里的引号都转义成 `\"`，
    /// 所以未转义的 `"usage":{` 只会是真正的键；取最后一个（message.usage 在正文之后）。
    static func claudeFast(_ bytes: UnsafeBufferPointer<UInt8>) -> TokenRecord? {
        do {
            guard bytes.count > 0, ByteScan.find(bytes, "\"type\":\"assistant\"") != nil,
                  let usageKey = ByteScan.findLast(bytes, "\"usage\":{"),
                  let objStart = Optional(usageKey + 8), let objEnd = ByteScan.matchBrace(bytes, from: objStart),
                  let u = (try? JSONSerialization.jsonObject(with: Data(bytes[objStart...objEnd]))) as? [String: Any]
            else { return nil }
            func int(_ v: Any?) -> Int { max((v as? NSNumber)?.intValue ?? 0, 0) }
            let usage = TokenUsage(input: int(u["input_tokens"]), output: int(u["output_tokens"]),
                                   cacheRead: int(u["cache_read_input_tokens"]),
                                   cacheWrite: int(u["cache_creation_input_tokens"]))
            guard !usage.isZero else { return nil }
            let message = ByteScan.find(bytes, "\"message\":{") ?? 0
            let id = ByteScan.stringValue(bytes, key: "\"id\":\"", from: message)
            let model = ByteScan.stringValue(bytes, key: "\"model\":\"", from: message)
                .flatMap { $0.isEmpty || $0 == "<synthetic>" ? nil : $0 }
            let ts = ByteScan.findLast(bytes, "\"timestamp\":\"").flatMap {
                ByteScan.stringValue(bytes, key: "\"timestamp\":\"", from: $0)
            }
            let date = ts.flatMap { quickISODate($0) ?? fractional.date(from: $0) ?? plain.date(from: $0) } ?? Date()
            return TokenRecord(key: id.map { "claude:\($0)" }, date: date, model: model, usage: usage)
        }
    }

    public mutating func consume(_ obj: [String: Any]) -> TokenRecord? {
        switch kind {
        case .claude:
            guard obj["type"] as? String == "assistant", let m = obj["message"] as? [String: Any],
                  let u = m["usage"] as? [String: Any] else { return nil }
            let usage = TokenUsage(input: int(u["input_tokens"]), output: int(u["output_tokens"]),
                                   cacheRead: int(u["cache_read_input_tokens"]),
                                   cacheWrite: int(u["cache_creation_input_tokens"]))
            guard !usage.isZero else { return nil }
            let model = (m["model"] as? String).flatMap { $0.isEmpty || $0 == "<synthetic>" ? nil : $0 }
            let key = (m["id"] as? String).map { "claude:\($0)" }
            return TokenRecord(key: key, date: date(obj["timestamp"]), model: model, usage: usage)
        case .codex:
            guard let p = obj["payload"] as? [String: Any] else { return nil }
            if obj["type"] as? String == "turn_context" {
                if let model = p["model"] as? String, !model.isEmpty { codexModel = model }
                return nil
            }
            guard p["type"] as? String == "token_count", let info = p["info"] as? [String: Any],
                  let t = info["total_token_usage"] as? [String: Any] else { return nil }
            if let last = info["last_token_usage"] as? [String: Any] {
                contextUsed = int(last["input_tokens"]) + int(last["output_tokens"])
            }
            if let w = info["model_context_window"] { contextWindow = int(w) }
            let input = int(t["input_tokens"])
            let cached = min(int(t["cached_input_tokens"]), input)
            let total = TokenUsage(input: input - cached, output: int(t["output_tokens"]), cacheRead: cached,
                                   cacheWrite: int(t["cache_write_input_tokens"]))
            // 累计值变小说明计数重置（新的累计从 0 开始）。
            let base = total.total < codexTotal.total ? .zero : codexTotal
            codexTotal = total
            let delta = TokenUsage(input: max(total.input - base.input, 0), output: max(total.output - base.output, 0),
                                   cacheRead: max(total.cacheRead - base.cacheRead, 0),
                                   cacheWrite: max(total.cacheWrite - base.cacheWrite, 0))
            guard !delta.isZero else { return nil }
            return TokenRecord(key: nil, date: date(obj["timestamp"]), model: codexModel, usage: delta)
        case .pi, .opencode:
            guard obj["type"] as? String == "message", let m = obj["message"] as? [String: Any],
                  m["role"] as? String == "assistant", let u = m["usage"] as? [String: Any] else { return nil }
            let usage = TokenUsage(input: int(u["input"]), output: int(u["output"]),
                                   cacheRead: int(u["cacheRead"]), cacheWrite: int(u["cacheWrite"]))
            guard !usage.isZero else { return nil }
            let key = (obj["id"] as? String).map { "pi:\($0)" }
            return TokenRecord(key: key, date: date(obj["timestamp"] ?? m["timestamp"]),
                               model: (m["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }, usage: usage)
        case .other:
            return nil
        }
    }

    // ISO8601DateFormatter 线程安全；每行新建开销很大（一周的记录有几万行），复用。
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    /// 只认 UTC 的 `YYYY-MM-DDTHH:MM:SS[.fff]Z`（各 agent 实际写的格式）；ISO8601DateFormatter 每次要几十微秒，
    /// 首次扫描有几万行。其他格式返回 nil，交给 formatter。
    static func quickISODate(_ s: String) -> Date? {
        var u = Array(s.utf8)
        guard u.count >= 20, u.last == UInt8(ascii: "Z"), u[4] == 45, u[7] == 45, u[10] == 84, u[13] == 58, u[16] == 58
        else { return nil }
        u.removeLast()
        func num(_ a: Int, _ b: Int) -> Int? {
            var n = 0
            for i in a..<b {
                let c = Int(u[i]) - 48
                guard (0...9).contains(c) else { return nil }
                n = n * 10 + c
            }
            return n
        }
        guard let y = num(0, 4), let mo = num(5, 7), let d = num(8, 10), let h = num(11, 13), let mi = num(14, 16),
              let sec = num(17, 19), (1...12).contains(mo), (1...31).contains(d) else { return nil }
        var frac = 0.0
        if u.count > 19 {
            guard u[19] == 46, u.count > 20, let f = num(20, u.count) else { return nil }
            frac = Double(f) / pow(10, Double(u.count - 20))
        }
        // 公历日期转 Unix 天数（Howard Hinnant 的 days_from_civil）。
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        return Date(timeIntervalSince1970: Double(days * 86400 + h * 3600 + mi * 60 + sec) + frac)
    }

    private func int(_ v: Any?) -> Int {
        if let n = v as? NSNumber { return max(n.intValue, 0) }
        return 0
    }

    /// ISO 字符串或毫秒时间戳；都没有时取「现在」（只影响按天归类）。
    private func date(_ v: Any?) -> Date {
        if let s = v as? String, let d = Self.quickISODate(s) ?? Self.fractional.date(from: s) ?? Self.plain.date(from: s) { return d }
        if let n = v as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue / 1000) }
        return Date()
    }
}

/// 在 UTF-8 字节里找子串（memmem），给逐行预筛和 Claude 快速解析用。
enum ByteScan {
    static func find(_ hay: UnsafeBufferPointer<UInt8>, _ needle: StaticString, from: Int = 0) -> Int? {
        guard let base = hay.baseAddress, from < hay.count else { return nil }
        let n = needle.utf8CodeUnitCount
        guard let p = memmem(base + from, hay.count - from, needle.utf8Start, n) else { return nil }
        return base.distance(to: p.assumingMemoryBound(to: UInt8.self))
    }

    static func findLast(_ hay: UnsafeBufferPointer<UInt8>, _ needle: StaticString) -> Int? {
        var last: Int?
        var from = 0
        while let i = find(hay, needle, from: from) {
            last = i
            from = i + 1
        }
        return last
    }

    /// 从 `{` 开始找到配对的 `}`（跳过字符串里的内容）。
    static func matchBrace(_ b: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        guard start < b.count, b[start] == UInt8(ascii: "{") else { return nil }
        var depth = 0
        var inString = false
        var i = start
        while i < b.count {
            let c = b[i]
            if inString {
                if c == UInt8(ascii: "\\") { i += 1 } else if c == UInt8(ascii: "\"") { inString = false }
            } else if c == UInt8(ascii: "\"") {
                inString = true
            } else if c == UInt8(ascii: "{") {
                depth += 1
            } else if c == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    /// `key` 以 `:"` 结尾；返回其后到下一个未转义引号之间的字符串（不含转义的普通值，如 id / model / 时间）。
    static func stringValue(_ b: UnsafeBufferPointer<UInt8>, key: StaticString, from: Int) -> String? {
        guard let k = find(b, key, from: from) else { return nil }
        let start = k + key.utf8CodeUnitCount
        var i = start
        while i < b.count, b[i] != UInt8(ascii: "\"") {
            if b[i] == UInt8(ascii: "\\") { return nil }
            i += 1
        }
        guard i < b.count else { return nil }
        return String(decoding: UnsafeBufferPointer(rebasing: b[start..<i]), as: UTF8.self)
    }
}
