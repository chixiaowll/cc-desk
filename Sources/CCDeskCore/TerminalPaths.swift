import Foundation

/// 终端里 ⌘-点击的文件路径识别（设计 §17）：从一行文字和点击的列取出路径片段，再解析成候选绝对路径。
/// 只处理单行（不跨折行）；路径里不能有空白。
public enum TerminalPaths {
    /// 路径片段的边界：空白、引号、括号、尖括号、竖线、逗号、分号，以及常见的中文标点。
    static let delimiters: Set<Character> = [
        " ", "\t", "\"", "'", "`", "(", ")", "[", "]", "{", "}", "<", ">", "|", ",", ";",
        "，", "。", "；", "：", "、", "“", "”", "‘", "’", "（", "）", "【", "】", "「", "」", "《", "》",
        "⏺", "⎿", "│", "─", "•", "·",
    ]
    /// 宽字符（中日韩文字等）后面那个占位单元格在行文字里的替身：不是分隔符（路径里的中文不会被拆开），
    /// 取出片段后去掉。用零宽空格：它自成一个字符（列号与字符下标仍一一对应），也不算空白。
    public static let wideSpacer: Character = "\u{200B}"

    /// 一行终端单元格 → 行文字（每格一个字符）：宽字符后面的占位格（字符为 "\0"、前一格宽 2）换成 `wideSpacer`，
    /// 其他空单元格（"\0"）换成空格。cells：每格的字符与宽度。
    public static func lineText(_ cells: [(character: Character, width: Int)]) -> String {
        var out = ""
        for (i, cell) in cells.enumerated() {
            if cell.character == "\0" {
                out.append(i > 0 && cells[i - 1].width == 2 ? wideSpacer : " ")
            } else {
                out.append(cell.character)
            }
        }
        return out
    }

    /// 片段末尾要去掉的标点。
    static let trailingPunctuation: Set<Character> = [".", ",", ":", ";", "!", "?", "…"]

    /// `line` 第 `column` 个字符（终端单元格）处的路径片段：向两侧扩展到分隔符，
    /// 去掉 `file://` 前缀、末尾标点与 `:行号[:列号]` / `#L行号` 后缀。不像路径（既没有 / 也没有 .）时返回 nil。
    public static func token(in line: String, column: Int) -> String? {
        let chars = Array(line)
        guard column >= 0, column < chars.count, !delimiters.contains(chars[column]), !chars[column].isWhitespace else {
            return nil
        }
        var start = column, end = column
        while start > 0, !isDelimiter(chars[start - 1]) { start -= 1 }
        while end + 1 < chars.count, !isDelimiter(chars[end + 1]) { end += 1 }
        return clean(String(chars[start...end].filter { $0 != wideSpacer }))
    }

    static func isDelimiter(_ c: Character) -> Bool {
        delimiters.contains(c) || c.isWhitespace
    }

    /// 去掉前后缀，保留路径本体。
    public static func clean(_ raw: String) -> String? {
        var s = raw
        if s.hasPrefix("file://") {
            s = String(s.dropFirst("file://".count))
            s = s.removingPercentEncoding ?? s
        }
        // 去掉 git diff 的 "a/" "b/" 前缀之外的部分由调用方的候选列表处理。
        if s.hasPrefix("@") { s.removeFirst() }
        s = stripTrailing(s)
        // `#L12` / `#L12-L20`
        if let range = s.range(of: #"#L\d+(-L?\d+)?$"#, options: .regularExpression) { s.removeSubrange(range) }
        // `:12` / `:12:3` / `:12-20`
        if let range = s.range(of: #"(:\d+){1,2}(-\d+)?$"#, options: .regularExpression) { s.removeSubrange(range) }
        s = stripTrailing(s)
        guard !s.isEmpty, s != "~", s.contains("/") || s.contains(".") else { return nil }
        // 纯标点 / 纯数字（如版本号 1.2.3）不是路径。
        if s.allSatisfy({ $0 == "." || $0 == "/" }) { return nil }
        if s.range(of: #"^[\d.]+$"#, options: .regularExpression) != nil { return nil }
        // URL 交给终端自己的链接处理。
        if s.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, options: .regularExpression) != nil { return nil }
        return s
    }

    static func stripTrailing(_ s: String) -> String {
        var s = s
        while let last = s.last, trailingPunctuation.contains(last) {
            // 保留 "." 与 ".." 本身（目录引用）。
            if s == "." || s == ".." { break }
            s.removeLast()
        }
        return s
    }

    /// 候选绝对路径（按优先级）：按 cwd / ~ 解析；git diff 的 `a/` `b/` 前缀再试一次去掉前缀的版本。
    public static func candidates(for token: String, cwd: String, home: String = NSHomeDirectory()) -> [String] {
        var out: [String] = []
        func add(_ raw: String) {
            if let p = TouchedFiles.resolve(raw, base: cwd, home: home), !out.contains(p) { out.append(p) }
        }
        add(token)
        if token.hasPrefix("a/") || token.hasPrefix("b/") { add(String(token.dropFirst(2))) }
        return out
    }

    /// 一步到位：第一个存在的候选路径。
    public static func resolve(line: String, column: Int, cwd: String, home: String = NSHomeDirectory(),
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        guard let token = token(in: line, column: column) else { return nil }
        return candidates(for: token, cwd: cwd, home: home).first(where: exists)
    }
}
