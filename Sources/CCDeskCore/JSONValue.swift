import Foundation

/// 任意 JSON 值（控制接口 / MCP 消息用）：可比较、可跨线程传递，键按字典序编码，便于测试。
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: 取值

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// 数字，或能解析成数字的字符串（模型偶尔把数字写成字符串）。
    public var intValue: Int? {
        switch self {
        case .number(let d): return d.isFinite ? Int(d) : nil
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// 布尔，或 "true" / "false" 字符串。
    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s):
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    // MARK: 与 Foundation 互转

    /// 从 JSONSerialization 的结果转换；不支持的类型返回 nil。
    public init?(any value: Any) {
        switch value {
        case is NSNull: self = .null
        case let n as NSNumber:
            // NSNumber 的布尔要单独识别，否则 true 会变成 1。
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]:
            var out: [JSONValue] = []
            for item in a {
                guard let v = JSONValue(any: item) else { return nil }
                out.append(v)
            }
            self = .array(out)
        case let o as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (k, item) in o {
                guard let v = JSONValue(any: item) else { return nil }
                out[k] = v
            }
            self = .object(out)
        default: return nil
        }
    }

    public var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let d):
            if d.rounded() == d, abs(d) < 1e15 { return Int(d) }
            return d
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    /// 解析一段 JSON 文本（允许顶层为任意值）。
    public static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue(any: obj)
    }

    /// 单行紧凑 JSON（键按字典序，不转义斜杠）。
    public var compact: String {
        guard let data = try? JSONSerialization.data(withJSONObject: any,
                                                     options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}
