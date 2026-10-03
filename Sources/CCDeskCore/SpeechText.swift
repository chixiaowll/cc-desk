import Foundation

/// 朗读前的文字整理（自然语音用；系统声音也可以用）：去掉 markdown / 代码，让技术词读得出来。
///
/// - 代码块整段去掉，行内代码只去反引号；链接留文字，网址只留域名；路径只留文件名。
/// - 标识符里的 `-` / `_` 换成空格（cc-desk → cc desk）；没有元音的 2–3 个字母的短词逐个字母读（cc → C C，rm → R M）。
/// - 命令行参数：`-rf` → 「杠 R F」，`--force` → 「杠杠 force」（英文为 dash）。
/// - 数字保持原样（版本号、日期、范围不拆）。
public enum SpeechText {
    /// language：界面语言（"zh-Hans" / "en"），决定「杠 / dash」「点 / dot」的读法。
    public static func normalize(_ input: String, language: String = "zh-Hans") -> String {
        let zh = language.hasPrefix("zh")
        var text = input
        // 代码块：整段去掉。
        text = replace(#"```[\s\S]*?(```|$)"#, in: text, with: " ")
        // markdown 链接 / 图片：留文字。
        text = replace(#"!?\[([^\]]*)\]\([^)]*\)"#, in: text, with: "$1")
        // 网址：只留域名。
        text = replace(#"https?://(?:www\.)?([A-Za-z0-9.-]+)[^\s，。）)]*"#, in: text, with: "$1")
        // 行首的标题 / 列表 / 引用标记。
        text = replace(#"(?m)^\s*(#{1,6}\s+|[-*+]\s+|>\s*|\d+\.\s+)"#, in: text, with: "")
        // 强调与行内代码的符号。
        text = replace(#"\*\*|__|[`*]"#, in: text, with: "")
        text = replace(#"\s*(->|=>|→)\s*"#, in: text, with: zh ? "，" : ", ")
        // 中文里夹着的 ASCII 技术词（不要求空格分隔）逐个处理。
        text = mapTokens(in: text) { technical($0, zh: zh) }
        // 剩余的杂项符号。
        text = replace(#"[|{}\[\]<>#~^\\]"#, in: text, with: " ")
        text = replace(#"\s+"#, in: text, with: " ")
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// 切成适合逐句合成的片段：按句末标点 / 换行切，太短的并入下一句，太长的再按逗号切。
    public static func sentences(_ text: String, maxLength: Int = 80) -> [String] {
        var pieces: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            if c.isNewline {
                pieces.append(current)
                current = ""
                continue
            }
            current.append(c)
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            let ends: Bool
            switch c {
            case "。", "！", "？", "；", "!", "?", ";", "…": ends = true
            // 英文句点：后面是空白或结尾才算（不拆 1.5、main.py）。
            case ".": ends = next == nil || next?.isWhitespace == true
            default: ends = false
            }
            // 连续的句末标点（「？！」「……」）留在同一句。
            if ends, let next, "。！？；!?;…".contains(next) { continue }
            if ends {
                pieces.append(current)
                current = ""
            }
        }
        pieces.append(current)
        let trimmed = pieces.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        var merged: [String] = []
        var carry = ""
        for piece in trimmed {
            let joined = carry.isEmpty ? piece : carry + (needsSpace(carry, piece) ? " " : "") + piece
            if spokenLength(joined) < 4 {
                carry = joined
            } else {
                merged.append(joined)
                carry = ""
            }
        }
        if !carry.isEmpty {
            if let last = merged.popLast() {
                merged.append(last + (needsSpace(last, carry) ? " " : "") + carry)
            } else {
                merged.append(carry)
            }
        }
        return merged.flatMap { split($0, maxLength: maxLength) }
    }

    // MARK: - 内部

    /// 找出 ASCII 技术词（字母数字与 ~ . / _ - :），末尾的句点 / 冒号不算在内。
    private static func mapTokens(in text: String, _ transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9~./_:-]*[A-Za-z0-9_]"#) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            result += transform(ns.substring(with: match.range))
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func technical(_ token: String, zh: Bool) -> String {
        guard token.contains(where: { $0.isLetter }) else { return token }
        var t = token
        // 命令行参数：-rf / --force。
        if let m = t.firstMatch(of: #/^(-{1,2})([A-Za-z][A-Za-z0-9-]*)$/#) {
            let dash = zh ? "杠" : "dash"
            let dashes = Array(repeating: dash, count: m.1.count).joined(separator: zh ? "" : " ")
            let name = String(m.2)
            let spoken = m.1.count == 1 && name.count <= 4 ? spell(name) : words(name)
            return dashes + " " + spoken
        }
        // 路径：只留最后一段。
        if t.contains("/") {
            let parts = t.split(separator: "/").filter { !$0.isEmpty }
            if parts.count >= 2 || t.hasPrefix("~") || t.hasPrefix("/") || t.hasPrefix(".") {
                t = String(parts.last ?? Substring(t))
            }
        }
        // 文件名：name.ext → name 点 ext。
        if let m = t.firstMatch(of: #/^([A-Za-z0-9_-]{2,})\.([A-Za-z]{1,5})$/#) {
            return words(String(m.1)) + (zh ? " 点 " : " dot ") + String(m.2)
        }
        return words(t)
    }

    /// 标识符：`-` / `_` 变空格，每一段再看要不要逐个字母读。
    private static func words(_ s: String) -> String {
        // 数字之间的 - 保留（2026-10-03、3-5）。
        if s.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "." || $0 == ":" }) { return s }
        return s.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { part -> String in
            let p = String(part)
            return isSpellable(p) ? spell(p) : p
        }.joined(separator: " ")
    }

    /// 2–3 个字母且没有元音（cc、rm、ls、npm、pwd）：逐个字母读。
    private static func isSpellable(_ s: String) -> Bool {
        guard (2...3).contains(s.count), s.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return !s.lowercased().contains(where: { "aeiouy".contains($0) })
    }

    private static func spell(_ s: String) -> String {
        s.uppercased().map(String.init).joined(separator: " ")
    }

    private static func split(_ sentence: String, maxLength: Int) -> [String] {
        guard sentence.count > maxLength else { return [sentence] }
        var out: [String] = []
        var current = ""
        for c in sentence {
            current.append(c)
            if "，,、：:".contains(c), current.count >= maxLength / 3 {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else if current.count >= maxLength {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    /// 读出来的长度（不算标点和空白）。
    private static func spokenLength(_ s: String) -> Int {
        s.filter { $0.isLetter || $0.isNumber }.count
    }

    private static func needsSpace(_ a: String, _ b: String) -> Bool {
        guard let x = a.last, let y = b.first else { return false }
        return x.isASCII && y.isASCII
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}
