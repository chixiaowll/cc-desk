import Foundation

/// SKILL.md / 命令 / 子 agent 文件开头的 YAML frontmatter（宽松的子集）：只取顶层的标量字段——
/// `key: value`（可带单 / 双引号）、`key: |` / `key: >`（含 `|-` `>-` 等）块标量、以及续写在缩进行上的多行普通标量。
/// 嵌套的映射 / 列表（如 `metadata:` 下的内容）忽略。没有 frontmatter 时 fields 为空、body 为全文。
public struct SkillFrontmatter: Equatable, Sendable {
    public let fields: [String: String]
    public let body: String

    public static func parse(_ text: String) -> SkillFrontmatter {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[first].trimmingCharacters(in: .whitespaces) == "---",
              let end = lines[(first + 1)...].firstIndex(where: {
                  let t = $0.trimmingCharacters(in: .whitespaces)
                  return t == "---" || t == "..."
              })
        else { return SkillFrontmatter(fields: [:], body: text) }
        let body = lines[(end + 1)...].joined(separator: "\n")
        return SkillFrontmatter(fields: fields(Array(lines[(first + 1)..<end])), body: body)
    }

    /// 顶层字段。
    static func fields(_ lines: [String]) -> [String: String] {
        var fields: [String: String] = [:]
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard let key = topLevelKey(line) else { continue }
            let colon = line.firstIndex(of: ":") ?? line.endIndex
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // 后面缩进（或空）的行属于这个键。
            var continuation: [String] = []
            while index < lines.count, topLevelKey(lines[index]) == nil {
                let next = lines[index]
                if !next.isEmpty, !next.hasPrefix(" "), !next.hasPrefix("\t"), !next.hasPrefix("#") { break }
                if !next.hasPrefix("#") { continuation.append(next) }
                index += 1
            }
            if let style = value.first, style == "|" || style == ">" {
                fields[key] = block(continuation, folded: style == ">")
            } else if value.isEmpty {
                // 多行普通标量（不是嵌套映射 / 列表时）。
                let parts = continuation.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if let firstPart = parts.first, !firstPart.hasPrefix("- "), !looksLikeMapping(firstPart) {
                    fields[key] = unquote(parts.joined(separator: " "))
                }
            } else {
                let more = continuation.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                fields[key] = unquote(([value] + more).joined(separator: " "))
            }
        }
        return fields
    }

    /// 顶层的 `key:`（不缩进、不是注释 / 列表项）。
    static func topLevelKey(_ line: String) -> String? {
        guard let f = line.first, f != " ", f != "\t", f != "#", f != "-", let colon = line.firstIndex(of: ":") else {
            return nil
        }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { return nil }
        let after = line.index(after: colon)
        guard after == line.endIndex || line[after] == " " || line[after] == "\t" else { return nil }
        return key.lowercased()
    }

    static func looksLikeMapping(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9_.-]+:(\s|$)"#, options: .regularExpression) != nil
    }

    /// 块标量：去掉公共缩进；`|` 保留换行，`>` 把行折成空格（空行保留为换行）。
    static func block(_ lines: [String], folded: Bool) -> String {
        var lines = lines
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        let stripped = lines.map { $0.count >= indent ? String($0.dropFirst(indent)) : "" }
        guard folded else { return stripped.joined(separator: "\n") }
        var out = ""
        for line in stripped {
            if line.isEmpty {
                out += "\n"
            } else {
                if !out.isEmpty, !out.hasSuffix("\n") { out += " " }
                out += line
            }
        }
        return out
    }

    /// 去掉成对的引号；双引号里处理 `\"` `\\` `\n`，单引号里 `''` 表示一个单引号。
    static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, let f = t.first, let l = t.last, f == l, f == "\"" || f == "'" else { return t }
        let inner = String(t.dropFirst().dropLast())
        if f == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        var out = ""
        var escaping = false
        for ch in inner {
            if escaping {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(ch)
                }
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// 正文里第一段说明文字（跳过标题、空行、代码块围栏、HTML 注释与表格），折成一行。
    public static func firstParagraph(_ body: String) -> String {
        var collected: [String] = []
        var inFence = false
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                if !collected.isEmpty { break }
                continue
            }
            if inFence { continue }
            if line.isEmpty {
                if !collected.isEmpty { break }
                continue
            }
            if line.hasPrefix("#") || line.hasPrefix("<!--") || line.hasPrefix("|") || line.hasPrefix("---") {
                if !collected.isEmpty { break }
                continue
            }
            collected.append(line)
        }
        return collected.joined(separator: " ")
    }
}
