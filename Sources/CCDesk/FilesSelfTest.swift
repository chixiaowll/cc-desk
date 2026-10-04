import CoreServices
import Foundation
import CCDeskCore

/// `CCDesk --files-selftest`：不启动界面，在临时目录里自检「提到 / 生成的文件」（设计 §17.1）：
/// 1. 项目监视：开 `ProjectWatcher`，建普通文件、改文件、删文件，再在 .git / node_modules / build 里建文件、
///    建 .DS_Store / *.swp / *~，确认只报告该报告的文件；
/// 2. 回放：停掉后再建文件，用停下时的事件编号重新开始，确认中间的文件被补上；
/// 3. 提到的文件：写一个假的 Claude 记录（提到一个存在的文件和一个不存在的文件），确认只收存在的。
/// 只读写自己建的临时目录，不碰正在运行的 CC Desk。
enum FilesSelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.dropFirst().contains("--files-selftest") else { return }
        exit(run() ? 0 : 1)
    }

    private static var failures = 0

    private static func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "ok  " : "FAIL") \(what)")
        if !ok { failures += 1 }
    }

    /// 在主线程跑事件循环，直到条件成立或超时。
    private static func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private static func write(_ root: URL, _ relative: String, _ text: String = "x") {
        let url = root.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
    }

    static func run() -> Bool {
        setvbuf(stdout, nil, _IOLBF, 0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccdesk-files-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        write(root, "existing.txt")
        check(ProjectWatchRules.refusal(root: root.path) == nil, "temp project can be watched")
        check(ProjectWatchRules.refusal(root: NSHomeDirectory()) == .tooBroad, "home directory is refused")

        // 1. 实时监视
        var reported: [TouchedFile] = []
        var started = false
        let watcher = ProjectWatcher(root: root.path) { reported = $0 }
        watcher.start { started = $0 }
        check(wait(3) { started }, "watcher started")
        // 让流先就位，避免把创建前的事件算进来 / 漏掉。
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        write(root, "out/anime-test/sheet.jpg")
        write(root, "report.md")
        write(root, "existing.txt", "changed")
        write(root, "gone.png")
        write(root, ".git/objects/ab/cdef")
        write(root, "node_modules/pkg/index.js")
        write(root, "build/app.o")
        write(root, "sub/__pycache__/m.pyc")
        write(root, "docs/.DS_Store")
        write(root, "docs/.plan.md.swp")
        write(root, "docs/plan.md~")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try? FileManager.default.removeItem(at: root.appendingPathComponent("gone.png"))
        let expected: Set<String> = ["out/anime-test/sheet.jpg", "report.md", "existing.txt"]
        func relative(_ files: [TouchedFile]) -> Set<String> {
            Set(files.map { TouchedFiles.relativePath($0.path, root: root.path) })
        }
        let settled = wait(8) { relative(reported) == expected }
        check(settled, "only expected files reported: \(relative(reported).sorted())")
        let byName = Dictionary(reported.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        check(byName["sheet.jpg"]?.action == .created && byName["sheet.jpg"]?.origin == .generated, "new file is generated/created")
        check(byName["existing.txt"]?.action == .modified, "pre-existing file is modified")

        // 2. 回放
        var stoppedLog = GeneratedFilesLog()
        var resumeID: FSEventStreamEventId = 0
        var stopped = false
        let stoppedAt = Date()
        watcher.stop { log, id in
            stoppedLog = log
            resumeID = id
            stopped = true
        }
        check(wait(3) { stopped }, "watcher stopped with \(stoppedLog.count) files")
        write(root, "while-away.csv")
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        var replayed: [TouchedFile] = []
        let resumed = ProjectWatcher(root: root.path, log: stoppedLog, since: resumeID,
                                     sinceDate: stoppedAt) { replayed = $0 }
        resumed.start()
        let caughtUp = wait(8) { relative(replayed).contains("while-away.csv") }
        check(caughtUp, "files created while not watching are replayed: \(relative(replayed).sorted())")
        check(relative(replayed).isSuperset(of: expected), "earlier records are kept after resuming")
        check(replayed.first { $0.name == "while-away.csv" }?.action == .created, "replayed new file counts as created")
        var done = false
        resumed.stop { _, _ in done = true }
        _ = wait(3) { done }

        // 3. 提到的文件
        let transcript = root.appendingPathComponent("transcript.jsonl")
        let line: [String: Any] = [
            "type": "assistant", "cwd": root.path, "timestamp": "2026-10-04T10:00:00.000Z",
            "message": ["role": "assistant", "content": [
                ["type": "text", "text": "图已生成：`out/anime-test/sheet.jpg`，另见 missing/nope.png。"]]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: line)) ?? Data()
        try? (data + Data("\n".utf8)).write(to: transcript)
        let tracker = TouchedFilesTracker(url: transcript, kind: .claude, cwd: root.path)
        tracker.refresh()
        let mentioned = relative(tracker.log.mentions.files())
        check(mentioned == ["out/anime-test/sheet.jpg"], "mentioned: only the existing file: \(mentioned.sorted())")

        let merged = TouchedFilesMerge.merge(tool: tracker.log.files(), generated: replayed,
                                             mentioned: tracker.log.mentions.files())
        let sheet = merged.extra.filter { $0.name == "sheet.jpg" }
        check(sheet.count == 1 && sheet.first?.origin == .generated, "merged once with the generated badge")
        check(merged.extra.first?.isDocument == true, "documents and images first")

        print(failures == 0 ? "files selftest passed" : "files selftest: \(failures) failure(s)")
        return failures == 0
    }
}
