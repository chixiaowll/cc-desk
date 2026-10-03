import Foundation

/// 只够解析屏幕规则清单的 TOML 子集：顶层 `key = value`、`[table]` / `[[array-of-tables]]`（单段名）、
/// 基本 / 字面 / 多行字符串、整数、浮点、布尔、（可跨行、可尾逗号、可带注释的）数组、内联表。
/// 不支持点号键、日期时间等；遇到不支持的语法抛错，由调用方整体放弃该清单。
public indirect enum TOMLValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int? { if case .int(let v) = self { return v }; return nil }
    public var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var arrayValue: [TOMLValue]? { if case .array(let v) = self { return v }; return nil }
    public var tableValue: [String: TOMLValue]? { if case .table(let v) = self { return v }; return nil }
}

public struct TOMLError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public let offset: Int
    public var description: String { "TOML 解析失败（位置 \(offset)）：\(message)" }
}

public enum MiniTOML {
    public static func parse(_ text: String) throws -> [String: TOMLValue] {
        var p = Parser(Array(text.unicodeScalars))
        return try p.document()
    }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0

        init(_ s: [Unicode.Scalar]) { self.s = s }

        var atEnd: Bool { i >= s.count }
        func peek(_ k: Int = 0) -> Unicode.Scalar? { i + k < s.count ? s[i + k] : nil }

        func fail(_ m: String) -> TOMLError { TOMLError(message: m, offset: i) }

        mutating func document() throws -> [String: TOMLValue] {
            var root: [String: TOMLValue] = [:]
            var current: [String: TOMLValue] = [:]
            enum Target { case root, table(String), arrayItem(String) }
            var target = Target.root

            func flush(_ root: inout [String: TOMLValue], _ current: [String: TOMLValue], _ target: Target) {
                switch target {
                case .root: break
                case .table(let name): root[name] = .table(current)
                case .arrayItem(let name):
                    var arr = root[name]?.arrayValue ?? []
                    arr.append(.table(current))
                    root[name] = .array(arr)
                }
            }

            while true {
                skipBlankLinesAndComments()
                if atEnd { break }
                if peek() == "[" {
                    let isArray = peek(1) == "["
                    i += isArray ? 2 : 1
                    skipSpaces()
                    let name = try key()
                    skipSpaces()
                    guard peek() == "]" else { throw fail("表头只支持单段名") }
                    i += 1
                    if isArray {
                        guard peek() == "]" else { throw fail("缺少 ]]") }
                        i += 1
                    }
                    try endOfLine()
                    if case .root = target { root.merge(current) { _, new in new } } else { flush(&root, current, target) }
                    current = [:]
                    target = isArray ? .arrayItem(name) : .table(name)
                    continue
                }
                let k = try key()
                skipSpaces()
                guard peek() == "=" else { throw fail("缺少 =") }
                i += 1
                skipSpaces()
                let v = try value()
                guard current[k] == nil else { throw fail("重复的键 \(k)") }
                current[k] = v
                try endOfLine()
            }
            if case .root = target { root.merge(current) { _, new in new } } else { flush(&root, current, target) }
            return root
        }

        mutating func skipSpaces() {
            while let c = peek(), c == " " || c == "\t" { i += 1 }
        }

        mutating func skipComment() {
            if peek() == "#" { while let c = peek(), c != "\n" { i += 1 } }
        }

        mutating func skipBlankLinesAndComments() {
            while true {
                skipSpaces()
                skipComment()
                if peek() == "\n" { i += 1; continue }
                if peek() == "\r", peek(1) == "\n" { i += 2; continue }
                break
            }
        }

        mutating func endOfLine() throws {
            skipSpaces()
            skipComment()
            if atEnd { return }
            if peek() == "\n" { i += 1; return }
            if peek() == "\r", peek(1) == "\n" { i += 2; return }
            throw fail("行尾有多余内容")
        }

        static func isBare(_ c: Unicode.Scalar) -> Bool {
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_" || c == "-"
        }

        mutating func key() throws -> String {
            if peek() == "\"" { return try basicString() }
            if peek() == "'" { return try literalString() }
            var out = String.UnicodeScalarView()
            while let c = peek(), Self.isBare(c) { out.append(c); i += 1 }
            guard !out.isEmpty else { throw fail("缺少键名") }
            if peek() == "." { throw fail("不支持点号键") }
            return String(out)
        }

        mutating func value() throws -> TOMLValue {
            guard let c = peek() else { throw fail("缺少值") }
            switch c {
            case "\"":
                if peek(1) == "\"", peek(2) == "\"" { return .string(try multilineBasic()) }
                return .string(try basicString())
            case "'":
                if peek(1) == "'", peek(2) == "'" { return .string(try multilineLiteral()) }
                return .string(try literalString())
            case "[":
                return try array()
            case "{":
                return try inlineTable()
            case "t", "f":
                if match("true") { return .bool(true) }
                if match("false") { return .bool(false) }
                throw fail("无法识别的值")
            default:
                return try number()
            }
        }

        mutating func match(_ word: String) -> Bool {
            let w = Array(word.unicodeScalars)
            guard i + w.count <= s.count, Array(s[i..<(i + w.count)]) == w else { return false }
            if let next = peek(w.count), Self.isBare(next) { return false }
            i += w.count
            return true
        }

        mutating func number() throws -> TOMLValue {
            var out = ""
            while let c = peek(), Self.isBare(c) || c == "+" || c == "." {
                if c != "_" { out.unicodeScalars.append(c) }
                i += 1
            }
            if let v = Int(out) { return .int(v) }
            if let v = Double(out) { return .double(v) }
            throw fail("无法识别的值 \(out)")
        }

        mutating func array() throws -> TOMLValue {
            i += 1
            var items: [TOMLValue] = []
            while true {
                skipBlankLinesAndComments()
                if peek() == "]" { i += 1; return .array(items) }
                items.append(try value())
                skipBlankLinesAndComments()
                if peek() == "," { i += 1; continue }
                if peek() == "]" { i += 1; return .array(items) }
                throw fail("数组缺少 , 或 ]")
            }
        }

        mutating func inlineTable() throws -> TOMLValue {
            i += 1
            var table: [String: TOMLValue] = [:]
            skipSpaces()
            if peek() == "}" { i += 1; return .table(table) }
            while true {
                skipSpaces()
                let k = try key()
                skipSpaces()
                guard peek() == "=" else { throw fail("内联表缺少 =") }
                i += 1
                skipSpaces()
                table[k] = try value()
                skipSpaces()
                if peek() == "," { i += 1; continue }
                if peek() == "}" { i += 1; return .table(table) }
                throw fail("内联表缺少 , 或 }")
            }
        }

        mutating func literalString() throws -> String {
            i += 1
            var out = String.UnicodeScalarView()
            while let c = peek() {
                if c == "'" { i += 1; return String(out) }
                if c == "\n" { break }
                out.append(c)
                i += 1
            }
            throw fail("字面字符串未结束")
        }

        mutating func multilineLiteral() throws -> String {
            i += 3
            if peek() == "\n" { i += 1 } else if peek() == "\r", peek(1) == "\n" { i += 2 }
            var out = String.UnicodeScalarView()
            while !atEnd {
                if peek() == "'", peek(1) == "'", peek(2) == "'" { i += 3; return String(out) }
                out.append(s[i])
                i += 1
            }
            throw fail("多行字面字符串未结束")
        }

        mutating func escape(into out: inout String.UnicodeScalarView) throws {
            i += 1
            guard let e = peek() else { throw fail("转义未结束") }
            i += 1
            switch e {
            case "b": out.append("\u{08}")
            case "t": out.append("\t")
            case "n": out.append("\n")
            case "f": out.append("\u{0C}")
            case "r": out.append("\r")
            case "e": out.append("\u{1B}")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "u", "U":
                let n = e == "u" ? 4 : 8
                guard i + n <= s.count else { throw fail("\\u 转义不完整") }
                let hex = String(String.UnicodeScalarView(s[i..<(i + n)]))
                guard let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) else { throw fail("无效的 \\u 转义") }
                out.append(scalar)
                i += n
            default:
                throw fail("不支持的转义 \\\(e)")
            }
        }

        mutating func basicString() throws -> String {
            i += 1
            var out = String.UnicodeScalarView()
            while let c = peek() {
                if c == "\"" { i += 1; return String(out) }
                if c == "\n" { break }
                if c == "\\" { try escape(into: &out); continue }
                out.append(c)
                i += 1
            }
            throw fail("字符串未结束")
        }

        mutating func multilineBasic() throws -> String {
            i += 3
            if peek() == "\n" { i += 1 } else if peek() == "\r", peek(1) == "\n" { i += 2 }
            var out = String.UnicodeScalarView()
            while !atEnd {
                if peek() == "\"", peek(1) == "\"", peek(2) == "\"" { i += 3; return String(out) }
                if peek() == "\\" {
                    // 行尾反斜杠：吞掉换行及之后的空白。
                    if let n = peek(1), n == "\n" || n == " " || n == "\t" || n == "\r" {
                        var j = i + 1
                        while j < s.count, s[j] == " " || s[j] == "\t" { j += 1 }
                        if j < s.count, s[j] == "\n" || s[j] == "\r" {
                            i = j
                            while let c = peek(), c == " " || c == "\t" || c == "\n" || c == "\r" { i += 1 }
                            continue
                        }
                    }
                    try escape(into: &out)
                    continue
                }
                out.append(s[i])
                i += 1
            }
            throw fail("多行字符串未结束")
        }
    }
}
