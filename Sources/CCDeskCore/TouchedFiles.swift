import Foundation

/// 「改动的文件」面板（设计 §17）里一个文件最后的状态。
public enum TouchAction: String, Equatable, Sendable {
    case created, modified, deleted
}

/// 文件是怎么进到列表里的。合并时信息量大的优先：工具写入 > 项目目录里新生成 / 改动 > 在回复里提到。
public enum TouchOrigin: Int, Equatable, Sendable, Comparable {
    /// Write / Edit / apply_patch 等工具调用（徽标：新 / 已改 / 已删除）。
    case tool = 0
    /// 选中会话期间项目目录里新出现 / 被改动的文件（FSEvents，徽标：生成 / 已改）。
    case generated = 1
    /// agent 在回复文字里提到、且确实存在的文件（徽标：提到）。
    case mentioned = 2

    public static func < (a: TouchOrigin, b: TouchOrigin) -> Bool { a.rawValue < b.rawValue }
}

/// agent 在一个会话里写过的一个文件（同一路径合并为一条）。
public struct TouchedFile: Identifiable, Equatable, Sendable {
    /// 绝对路径（已展开 ~、按会话 cwd 解析相对路径、去掉 . / ..）。
    public let path: String
    public let firstTouched: Date?
    public let lastTouched: Date?
    public let action: TouchAction
    /// 写入次数（Write / Edit / 补丁里出现一次算一次）。
    public let count: Int
    /// 文档类产出（见 `TouchedFiles.isDocument`）排在代码前面。
    public let isDocument: Bool
    /// 文件当前是否还在（快照时检查）。
    public let exists: Bool
    /// 来源（工具写入 / 生成 / 提到）。
    public let origin: TouchOrigin
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, firstTouched: Date?, lastTouched: Date?, action: TouchAction, count: Int,
                isDocument: Bool, exists: Bool, origin: TouchOrigin = .tool) {
        self.path = path
        self.firstTouched = firstTouched
        self.lastTouched = lastTouched
        self.action = action
        self.count = count
        self.isDocument = isDocument
        self.exists = exists
        self.origin = origin
    }

    /// 相对 `root` 的路径（不在其下时用 ~ 缩写的绝对路径）。
    public func relativePath(root: String?, home: String = NSHomeDirectory()) -> String {
        TouchedFiles.relativePath(path, root: root, home: home)
    }
}

/// 从会话记录行里抽出的一次写文件动作。
enum TouchEvent: Equatable {
    /// 新建（Codex `*** Add File`）。
    case create(String)
    /// 修改（Edit / MultiEdit / `*** Update File`）。
    case modify(String)
    /// 删除（`*** Delete File`）。
    case delete(String)
    /// 写入整个文件，可能是新建也可能覆盖（Claude Write、pi write）：首次出现按新建算。
    case write(String)
    /// Claude 的 `toolUseResult.type == "update"`：刚才的 Write 覆盖的是已有文件（不计次数）。
    case existed(String)
}

/// 「改动的文件」的抽取与分类（纯函数 + 累加器，设计 §17）。
///
/// - Claude：`assistant` 行的 `tool_use` Write / Edit / MultiEdit（`file_path`）、NotebookEdit（`notebook_path`）；
///   `user` 行的 `toolUseResult.type == "update"` 把刚才的 Write 改判为「已改」。相对路径按该行的 `cwd` 解析。
/// - Codex：`response_item` 的 apply_patch（`custom_tool_call` / `function_call`，或 exec_command / shell 里的补丁），
///   按 `*** Add File:` / `*** Update File:`（含 `*** Move to:`）/ `*** Delete File:` 判断；相对路径按 `workdir` 或会话 cwd。
/// - pi：`message` 的 `toolCall` write / edit（`path` / `file_path`）。
/// - 不识别通过 shell 命令（`cat >`、`sed -i`、`mv`）改的文件。
public enum TouchedFiles {
    /// 文档类扩展名：文字、网页、PDF、图片、表格与 Office / iWork 文档。
    public static let documentExtensions: Set<String> = [
        "md", "markdown", "txt", "rtf", "html", "htm", "pdf",
        "png", "jpg", "jpeg", "gif", "svg", "webp",
        "csv", "tsv", "xlsx", "xls", "docx", "doc", "pptx", "ppt", "key", "pages", "numbers",
    ]
    /// 图片 / 视频 / 音频产出（脚本生成的截图、视频、配音等），同样算「文档与产出」。
    public static let mediaExtensions: Set<String> = [
        "heic", "tif", "tiff", "bmp", "avif",
        "mp4", "mov", "m4v", "webm", "mkv", "avi", "mp3", "wav", "m4a", "aac", "flac", "ogg",
    ]
    /// 只有放在 docs/ 或 doc/ 目录下才算文档的数据格式。
    public static let docsOnlyExtensions: Set<String> = ["json", "yaml", "yml"]

    /// 文档类产出：扩展名在 `documentExtensions` / `mediaExtensions` 里；或 json / yaml 且路径里有 docs / doc 目录。
    public static func isDocument(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if documentExtensions.contains(ext) || mediaExtensions.contains(ext) { return true }
        guard docsOnlyExtensions.contains(ext) else { return false }
        let dirs = (path as NSString).deletingLastPathComponent.split(separator: "/").map { $0.lowercased() }
        return dirs.contains("docs") || dirs.contains("doc")
    }

    /// 明显的临时文件：/tmp、/private/tmp、/var/folders、/private/var 下。
    public static func isTemporary(_ path: String) -> Bool {
        ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/"].contains { path.hasPrefix($0) }
    }

    /// 展开 ~，相对路径接在 `base` 后面，去掉 . 与 ..（不解析符号链接）。空路径返回 nil。
    public static func resolve(_ raw: String, base: String, home: String = NSHomeDirectory()) -> String? {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return nil }
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + p.dropFirst(1) }
        if !p.hasPrefix("/") {
            guard !base.isEmpty else { return nil }
            p = (base.hasSuffix("/") ? base : base + "/") + p
        }
        return URL(fileURLWithPath: p).standardized.path
    }

    /// 相对 `root` 的路径；不在 root 下时用 ~ 缩写。
    public static func relativePath(_ path: String, root: String?, home: String = NSHomeDirectory()) -> String {
        if let root, !root.isEmpty {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// 面板第二行显示的所在目录（以 "/" 结尾）：在 root 下时相对 root（就在根目录时为 "./"）；
    /// 否则在家目录下时为 "~/…"，再不然是绝对路径。超过 `maxLength` 个字符时从中间省略整段目录，
    /// 保留开头（"~/Documents"）与结尾（离文件最近的几层），如 "~/Documents/…/cc-desk/docs/design/"。
    public static func displayDirectory(_ path: String, root: String?, home: String = NSHomeDirectory(),
                                        maxLength: Int = 36) -> String {
        let relative = relativePath(path, root: root, home: home)
        let dir = (relative as NSString).deletingLastPathComponent
        if dir.isEmpty { return "./" }
        if dir == "/" { return "/" }
        return middleTruncated(dir, maxLength: maxLength) + "/"
    }

    /// 按路径段从中间省略：保留开头两段（"~" + 第一层，或绝对路径的前两层），从末尾往前尽量多留几段。
    /// 最后一段本身就放不下时仍保留它，由界面再截断。
    static func middleTruncated(_ dir: String, maxLength: Int) -> String {
        guard dir.count > maxLength else { return dir }
        let absolute = dir.hasPrefix("/")
        let parts = dir.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let headCount = (parts.first == "~" || absolute) ? 2 : 1
        let headParts = Array(parts.prefix(headCount))
        guard parts.count > headCount + 1 else { return dir }
        let head = (absolute ? "/" : "") + headParts.joined(separator: "/")
        var tail: [String] = [parts[parts.count - 1]]
        var index = parts.count - 2
        while index >= headCount {
            let candidate = [parts[index]] + tail
            if head.count + "/…/".count + candidate.joined(separator: "/").count > maxLength { break }
            tail = candidate
            index -= 1
        }
        return head + "/…/" + tail.joined(separator: "/")
    }

    // MARK: 抽取

    /// 一行里可能有写文件动作的特征字节；不含这些的行不做 JSON 解析（会话记录可能几十 MB）。
    static func markers(for kind: AgentKind) -> [Data] {
        switch kind {
        case .claude: return ["\"file_path\"", "\"notebook_path\"", "\"filePath\""].map { Data($0.utf8) }
        case .codex: return ["*** Add File", "*** Update File", "*** Delete File"].map { Data($0.utf8) }
        case .pi, .opencode: return ["\"toolCall\""].map { Data($0.utf8) }
        case .other: return []
        }
    }

    /// 一行会话记录里的写文件动作与时间（行首层的 `timestamp`）。
    static func events(kind: AgentKind, obj: [String: Any], cwd: String) -> [TouchEvent] {
        switch kind {
        case .claude: return claude(obj, cwd: cwd)
        case .codex: return codex(obj, cwd: cwd)
        case .pi, .opencode: return pi(obj, cwd: cwd)
        case .other: return []
        }
    }

    static func claude(_ obj: [String: Any], cwd: String) -> [TouchEvent] {
        let base = (obj["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? cwd
        switch obj["type"] as? String {
        case "assistant":
            guard let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return [] }
            return blocks.compactMap { b -> TouchEvent? in
                guard b["type"] as? String == "tool_use", let input = b["input"] as? [String: Any] else { return nil }
                switch b["name"] as? String {
                case "Write":
                    return (input["file_path"] as? String).flatMap { resolve($0, base: base) }.map(TouchEvent.write)
                case "Edit", "MultiEdit":
                    return (input["file_path"] as? String).flatMap { resolve($0, base: base) }.map(TouchEvent.modify)
                case "NotebookEdit":
                    let path = (input["notebook_path"] as? String) ?? (input["file_path"] as? String)
                    return path.flatMap { resolve($0, base: base) }.map(TouchEvent.modify)
                default:
                    return nil
                }
            }
        case "user":
            guard let result = obj["toolUseResult"] as? [String: Any], result["type"] as? String == "update",
                  let path = (result["filePath"] as? String).flatMap({ resolve($0, base: base) }) else { return [] }
            return [.existed(path)]
        default:
            return []
        }
    }

    static func codex(_ obj: [String: Any], cwd: String) -> [TouchEvent] {
        guard obj["type"] as? String == "response_item", let p = obj["payload"] as? [String: Any] else { return [] }
        switch p["type"] as? String {
        case "custom_tool_call":
            guard p["name"] as? String == "apply_patch" else { return [] }
            return patchEvents(p["input"] as? String ?? "", base: cwd)
        case "function_call":
            let raw = p["arguments"] as? String
            let args = raw.flatMap { TranscriptReader.jsonObject($0) } ?? [:]
            let base = (args["workdir"] as? String).flatMap { resolve($0, base: cwd) } ?? cwd
            switch p["name"] as? String {
            case "apply_patch":
                return patchEvents((args["input"] as? String) ?? raw ?? "", base: base)
            case "exec_command":
                return patchEvents((args["cmd"] as? String) ?? TurnDigest.shellCommand(args["cmd"]) ?? "", base: base)
            case "shell", "container.exec", "local_shell":
                return patchEvents(TurnDigest.shellCommand(args["command"]) ?? "", base: base)
            default:
                return []
            }
        case "local_shell_call":
            let action = p["action"] as? [String: Any]
            let base = (action?["working_directory"] as? String).flatMap { resolve($0, base: cwd) } ?? cwd
            return patchEvents(TurnDigest.shellCommand(action?["command"]) ?? "", base: base)
        default:
            return []
        }
    }

    /// apply_patch 补丁头：Add → 新建，Update → 修改（随后的 `*** Move to:` 视为删旧建新），Delete → 删除。
    static func patchEvents(_ patch: String, base: String) -> [TouchEvent] {
        guard patch.contains("*** ") else { return [] }
        var out: [TouchEvent] = []
        var lastUpdated: String?
        for line in patch.components(separatedBy: .newlines) {
            func path(after prefix: String) -> String? {
                guard line.hasPrefix(prefix) else { return nil }
                return resolve(String(line.dropFirst(prefix.count)), base: base)
            }
            if let p = path(after: "*** Add File: ") {
                out.append(.create(p))
                lastUpdated = nil
            } else if let p = path(after: "*** Update File: ") {
                out.append(.modify(p))
                lastUpdated = p
            } else if let p = path(after: "*** Delete File: ") {
                out.append(.delete(p))
                lastUpdated = nil
            } else if let p = path(after: "*** Move to: "), let old = lastUpdated {
                if out.last == .modify(old) { out.removeLast() }
                out.append(.delete(old))
                out.append(.create(p))
                lastUpdated = nil
            }
        }
        return out
    }

    static func pi(_ obj: [String: Any], cwd: String) -> [TouchEvent] {
        guard obj["type"] as? String == "message", let m = obj["message"] as? [String: Any],
              m["role"] as? String == "assistant", let blocks = m["content"] as? [[String: Any]] else { return [] }
        return blocks.compactMap { b -> TouchEvent? in
            guard b["type"] as? String == "toolCall", let args = b["arguments"] as? [String: Any],
                  let path = ((args["path"] as? String) ?? (args["file_path"] as? String)).flatMap({ resolve($0, base: cwd) })
            else { return nil }
            switch b["name"] as? String {
            case "write": return .write(path)
            case "edit": return .modify(path)
            default: return nil
            }
        }
    }
}

/// 一个会话的写文件记录（可增量追加）。值类型，不涉及文件读取；`TouchedFilesTracker` 负责读取。
public struct TouchedFilesLog: Sendable {
    struct Entry: Sendable {
        var first: Date?
        var last: Date?
        var count = 0
        var created = false
        var deleted = false
        /// 最后一次动作的序号：时间相同或缺失时按出现顺序排。
        var sequence = 0
    }

    private(set) var entries: [String: Entry] = [:]
    private var sequence = 0
    public let kind: AgentKind
    /// 会话的工作目录：相对路径的基准。
    public let cwd: String

    /// agent 在回复里提到的文件（同一次读取里一起抽取）。
    public private(set) var mentions: MentionedFilesLog

    public init(kind: AgentKind, cwd: String) {
        self.kind = kind
        self.cwd = cwd
        self.mentions = MentionedFilesLog(kind: kind, cwd: cwd)
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// 追加一段完整的行（按 \n 分隔；不完整的末行由调用方留到下次）。
    /// isFile：提到的路径是否是存在的普通文件（测试可注入）。
    public mutating func ingest(_ data: Data, isFile: (String) -> Bool = MentionedFiles.isRegularFile) {
        let markers = TouchedFiles.markers(for: kind)
        let mentionMarkers = MentionedFiles.markers(for: kind)
        guard !markers.isEmpty || !mentionMarkers.isEmpty else { return }
        for chunk in data.split(separator: UInt8(ascii: "\n")) {
            let touches = markers.contains(where: { chunk.range(of: $0) != nil })
            let mentionsText = mentionMarkers.contains(where: { chunk.range(of: $0) != nil })
            guard touches || mentionsText,
                  let obj = try? JSONSerialization.jsonObject(with: Data(chunk)) as? [String: Any] else { continue }
            let time = Self.timestamp(obj["timestamp"])
            if mentionsText { mentions.ingest(obj: obj, time: time, isFile: isFile) }
            guard touches else { continue }
            for event in TouchedFiles.events(kind: kind, obj: obj, cwd: cwd) { apply(event, at: time) }
        }
    }

    mutating func apply(_ event: TouchEvent, at time: Date?) {
        sequence += 1
        switch event {
        case .existed(let path):
            // 只纠正「首次出现就是 Write」的判断；之前已新建过的文件被覆盖仍算新文件。
            if var e = entries[path], e.count == 1, e.created {
                e.created = false
                entries[path] = e
            }
            return
        case .create(let path), .modify(let path), .delete(let path), .write(let path):
            var e = entries[path] ?? Entry()
            let isFirst = e.count == 0
            e.count += 1
            e.first = e.first ?? time
            if let time { e.last = max(e.last ?? time, time) }
            e.sequence = sequence
            switch event {
            case .create:
                e.created = true
                e.deleted = false
            case .write:
                if isFirst || e.deleted { e.created = true }
                e.deleted = false
            case .modify:
                if isFirst { e.created = false }
                e.deleted = false
            case .delete:
                e.deleted = true
            case .existed:
                break
            }
            entries[path] = e
        }
    }

    /// 快照：文档类在前、其余在后，各自按最后改动时间倒序。
    /// 临时目录下的文件只在没有其他文件时列出。`exists` 检查文件是否还在（调用方注入，便于测试）。
    public func files(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [TouchedFile] {
        let paths = entries.keys.filter { !TouchedFiles.isTemporary($0) }
        let chosen = paths.isEmpty ? Array(entries.keys) : paths
        let files = chosen.compactMap { path -> (TouchedFile, Int)? in
            guard let e = entries[path] else { return nil }
            let action: TouchAction = e.deleted ? .deleted : (e.created ? .created : .modified)
            let file = TouchedFile(path: path, firstTouched: e.first, lastTouched: e.last, action: action, count: e.count,
                                   isDocument: TouchedFiles.isDocument(path), exists: e.deleted ? false : exists(path))
            return (file, e.sequence)
        }
        return files.sorted { a, b in
            if a.0.isDocument != b.0.isDocument { return a.0.isDocument }
            let ta = a.0.lastTouched ?? .distantPast, tb = b.0.lastTouched ?? .distantPast
            if ta != tb { return ta > tb }
            return a.1 > b.1
        }.map(\.0)
    }

    /// 行首层的 `timestamp`：ISO 8601 字符串，或数字（毫秒 / 秒）。
    static func timestamp(_ value: Any?) -> Date? {
        if let s = value as? String { return AgentTranscriptReader.parseISODate(s) }
        if let n = value as? NSNumber {
            let v = n.doubleValue
            return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
        }
        return nil
    }
}
