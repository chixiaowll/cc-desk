import Foundation

/// 屏幕规则命中的状态（对应 herdr 清单里的 `state`）。
public enum ScreenState: String, Equatable, Sendable {
    case working
    case blocked
    case idle
    case unknown

    /// 转为侧栏状态；unknown 返回 nil。
    public func agentStatus(message: String? = nil) -> AgentStatus? {
        switch self {
        case .working: return .working
        case .blocked: return .waiting(message)
        case .idle: return .idle
        case .unknown: return nil
        }
    }
}

/// 规则里的 AND / OR / NOT 门：`contains`（全部包含，忽略大小写）、`regex`（全部命中）、
/// `line_regex`（每个都至少有一行命中）、`all`（全部子门）、`any`（任一子门）、`not`（没有任何子门命中）。
public struct RuleGate: Sendable {
    public var contains: [String] = []
    public var regex: [NSRegularExpression] = []
    public var lineRegex: [NSRegularExpression] = []
    public var all: [RuleGate] = []
    public var any: [RuleGate] = []
    public var not: [RuleGate] = []

    func matches(_ text: String, lower: String, lines: [String]) -> Bool {
        if !contains.allSatisfy({ lower.contains($0) }) { return false }
        let range = NSRange(text.startIndex..., in: text)
        if !regex.allSatisfy({ $0.firstMatch(in: text, range: range) != nil }) { return false }
        if !lineRegex.allSatisfy({ re in
            lines.contains { line in re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil }
        }) { return false }
        if !all.allSatisfy({ $0.matches(text, lower: lower, lines: lines) }) { return false }
        if !any.isEmpty, !any.contains(where: { $0.matches(text, lower: lower, lines: lines) }) { return false }
        if not.contains(where: { $0.matches(text, lower: lower, lines: lines) }) { return false }
        return true
    }
}

public struct ScreenRule: Sendable {
    public let id: String
    public let state: ScreenState
    public let priority: Int
    public let region: String
    public let skipStateUpdate: Bool
    public let gate: RuleGate
}

/// 一份 agent 屏幕规则清单（herdr `src/detect/manifests/*.toml` 格式的子集）。
public struct DetectionManifest: Sendable {
    public let id: String
    public let rules: [ScreenRule]
    /// 因区域 / 字段不受支持或正则无效而跳过的规则：(id, 原因)。
    public let skipped: [(id: String, reason: String)]

    static let ruleKeys: Set<String> = ["id", "state", "priority", "region", "visible_idle", "visible_blocker",
                                        "visible_working", "skip_state_update", "all", "any", "not",
                                        "contains", "regex", "line_regex"]
    static let gateKeys: Set<String> = ["all", "any", "not", "contains", "regex", "line_regex"]

    public static func parse(_ toml: String) throws -> DetectionManifest {
        let doc = try MiniTOML.parse(toml)
        let id = doc["id"]?.stringValue ?? ""
        var rules: [ScreenRule] = []
        var skipped: [(String, String)] = []
        for (index, value) in (doc["rules"]?.arrayValue ?? []).enumerated() {
            guard let t = value.tableValue else { continue }
            let ruleID = t["id"]?.stringValue ?? "#\(index)"
            do {
                if let bad = t.keys.first(where: { !ruleKeys.contains($0) }) { throw RuleError("不支持的字段 \(bad)") }
                let region = (t["region"]?.stringValue ?? "whole_recent").trimmingCharacters(in: .whitespaces)
                guard ScreenRegion.isSupported(region) else { throw RuleError("不支持的区域 \(region)") }
                let state = t["state"]?.stringValue.flatMap(ScreenState.init(rawValue:)) ?? .unknown
                let gate = try buildGate(t)
                rules.append(ScreenRule(id: ruleID, state: state, priority: t["priority"]?.intValue ?? 0,
                                        region: region, skipStateUpdate: t["skip_state_update"]?.boolValue ?? false,
                                        gate: gate))
            } catch let e as RuleError {
                skipped.append((ruleID, e.message))
            }
        }
        return DetectionManifest(id: id, rules: rules, skipped: skipped)
    }

    struct RuleError: Error {
        let message: String
        init(_ m: String) { message = m }
    }

    static func buildGate(_ t: [String: TOMLValue], nested: Bool = false) throws -> RuleGate {
        if nested, let bad = t.keys.first(where: { !gateKeys.contains($0) }) { throw RuleError("不支持的门字段 \(bad)") }
        func strings(_ key: String) throws -> [String] {
            guard let v = t[key] else { return [] }
            guard let arr = v.arrayValue else { throw RuleError("\(key) 必须是数组") }
            return try arr.map { item in
                guard let s = item.stringValue else { throw RuleError("\(key) 只能包含字符串") }
                return s
            }
        }
        func regexes(_ key: String) throws -> [NSRegularExpression] {
            try strings(key).map { pattern in
                do { return try NSRegularExpression(pattern: pattern) } catch { throw RuleError("无效的正则 \(pattern)") }
            }
        }
        func gates(_ key: String) throws -> [RuleGate] {
            guard let v = t[key] else { return [] }
            guard let arr = v.arrayValue else { throw RuleError("\(key) 必须是数组") }
            return try arr.map { item in
                guard let sub = item.tableValue else { throw RuleError("\(key) 只能包含表") }
                return try buildGate(sub, nested: true)
            }
        }
        var g = RuleGate()
        g.contains = try strings("contains").map { $0.lowercased() }
        g.regex = try regexes("regex")
        g.lineRegex = try regexes("line_regex")
        g.all = try gates("all")
        g.any = try gates("any")
        g.not = try gates("not")
        return g
    }
}

/// 一次检测的结果。
public struct ScreenDetection: Equatable, Sendable {
    public let state: ScreenState
    /// 命中的规则要求「不更新状态」（如 Codex 的 transcript 查看器）：调用方应保留上一次的状态。
    public let skipStateUpdate: Bool
    public let ruleID: String?

    public init(state: ScreenState, skipStateUpdate: Bool, ruleID: String?) {
        self.state = state
        self.skipStateUpdate = skipStateUpdate
        self.ruleID = ruleID
    }
}

public enum ScreenDetector {
    /// 按清单匹配：取 priority 最高的命中规则（同优先级取先出现的）；没有规则命中时视为空闲（与 herdr 一致）。
    /// `screen` 为终端底部可见区域的文本（每行去掉行尾空白，用 "\n" 连接），`oscTitle` 为终端标题。
    public static func detect(_ manifest: DetectionManifest, screen: String, oscTitle: String = "") -> ScreenDetection {
        var best: ScreenRule?
        var regionCache: [String: (String, String, [String])] = [:]
        for rule in manifest.rules {
            let prepared: (String, String, [String])
            if let cached = regionCache[rule.region] {
                prepared = cached
            } else {
                let text = ScreenRegion.extract(rule.region, screen: screen, oscTitle: oscTitle)
                prepared = (text, text.lowercased(), ScreenRegion.lines(text))
                regionCache[rule.region] = prepared
            }
            guard rule.gate.matches(prepared.0, lower: prepared.1, lines: prepared.2) else { continue }
            if let b = best, b.priority >= rule.priority { continue }
            best = rule
        }
        guard let best else { return ScreenDetection(state: .idle, skipStateUpdate: false, ruleID: nil) }
        return ScreenDetection(state: best.state, skipStateUpdate: best.skipStateUpdate, ruleID: best.id)
    }
}

/// 规则区域（移植自 herdr `src/detect/manifest.rs` 的子集）。
public enum ScreenRegion {
    static let fixed: Set<String> = ["whole_recent", "osc_title", "after_last_prompt_marker",
                                     "before_current_prompt_marker", "whole_recent_without_current_prompt_marker"]

    public static func isSupported(_ region: String) -> Bool {
        fixed.contains(region) || count(region, "bottom_lines") != nil
            || count(region, "bottom_non_empty_lines") != nil || count(region, "top_non_empty_lines") != nil
    }

    static func count(_ spec: String, _ name: String) -> Int? {
        guard spec.hasPrefix(name + "("), spec.hasSuffix(")") else { return nil }
        let inner = spec.dropFirst(name.count + 1).dropLast()
        guard !inner.isEmpty, inner.allSatisfy(\.isASCII), let n = Int(inner), n > 0 else { return nil }
        return n
    }

    /// 与 Rust `str::lines()` 一致：按 "\n" 拆分、去掉行尾 "\r"，末尾的换行不产生空行。
    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
        }
        if text.hasSuffix("\n") { parts.removeLast() }
        return parts
    }

    /// 从第 index 行开始到结尾。
    private static func from(_ lines: [String], _ index: Int, original: String) -> String {
        guard index > 0 else { return original }
        guard index < lines.count else { return "" }
        var out = lines[index...].joined(separator: "\n")
        if original.hasSuffix("\n") { out += "\n" }
        return out
    }

    /// 前 count 行（含每行的换行符）。
    private static func prefix(_ lines: [String], _ count: Int, original: String) -> String {
        guard count < lines.count else { return original }
        return lines[..<count].map { $0 + "\n" }.joined()
    }

    public static func extract(_ region: String, screen: String, oscTitle: String) -> String {
        if region == "osc_title" { return oscTitle }
        let ls = lines(screen)
        switch region {
        case "whole_recent":
            return screen
        case "after_last_prompt_marker":
            guard let idx = ls.lastIndex(where: codexPromptLine) else { return screen }
            return from(ls, idx + 1, original: screen)
        case "before_current_prompt_marker":
            guard let idx = currentPromptIndex(ls) else { return screen }
            return prefix(ls, idx, original: screen)
        case "whole_recent_without_current_prompt_marker":
            return currentPromptIndex(ls) == nil ? screen : ""
        default:
            if let n = count(region, "bottom_lines") {
                return from(ls, max(0, ls.count - n), original: screen)
            }
            if let n = count(region, "bottom_non_empty_lines") {
                let nonEmpty = ls.indices.filter { !ls[$0].trimmingCharacters(in: .whitespaces).isEmpty }
                guard let start = nonEmpty.suffix(n).first else { return "" }
                return from(ls, start, original: screen)
            }
            if let n = count(region, "top_non_empty_lines") {
                let nonEmpty = ls.indices.filter { !ls[$0].trimmingCharacters(in: .whitespaces).isEmpty }
                guard let end = nonEmpty.prefix(n).last else { return "" }
                return prefix(ls, end + 1, original: screen)
            }
            return ""
        }
    }

    static func codexPromptLine(_ line: String) -> Bool {
        line == "›" || line.hasPrefix("› ")
    }

    static func codexBlockMarkerLine(_ line: String) -> Bool {
        line.hasPrefix("•") || line.hasPrefix("■") || line.hasPrefix("✗") || line.hasPrefix("✓")
    }

    /// 最后一个 Codex 输入提示行，且其后没有新的输出块标记。
    static func currentPromptIndex(_ ls: [String]) -> Int? {
        guard let idx = ls.lastIndex(where: codexPromptLine) else { return nil }
        if ls[(idx + 1)...].contains(where: codexBlockMarkerLine) { return nil }
        return idx
    }
}
