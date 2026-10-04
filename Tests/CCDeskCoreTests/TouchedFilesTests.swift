import XCTest
@testable import CCDeskCore

final class TouchedFilesTests: XCTestCase {
    private func data(_ lines: [[String: Any]]) -> Data {
        let text = lines.map { obj -> String in
            let d = try! JSONSerialization.data(withJSONObject: obj)
            return String(data: d, encoding: .utf8)!
        }.joined(separator: "\n")
        return Data((text + "\n").utf8)
    }

    private func log(_ kind: AgentKind, cwd: String = "/r", _ lines: [[String: Any]]) -> TouchedFilesLog {
        var log = TouchedFilesLog(kind: kind, cwd: cwd)
        log.ingest(data(lines))
        return log
    }

    private func ts(_ second: Int) -> String {
        String(format: "2026-10-03T06:00:%02d.000Z", second)
    }

    private func claudeTool(_ name: String, _ input: [String: Any], at second: Int, cwd: String? = nil) -> [String: Any] {
        var line: [String: Any] = ["type": "assistant", "timestamp": ts(second),
                                   "message": ["role": "assistant", "content": [
                                       ["type": "tool_use", "id": "t\(second)", "name": name, "input": input]]]]
        if let cwd { line["cwd"] = cwd }
        return line
    }

    // MARK: Claude

    func testClaudeWriteEditAndUpdateResult() {
        let l = log(.claude, [
            claudeTool("Write", ["file_path": "/r/docs/plan.md", "content": "x"], at: 1),
            claudeTool("Edit", ["file_path": "/r/Sources/A.swift", "old_string": "a", "new_string": "b"], at: 2),
            claudeTool("Write", ["file_path": "/r/README.md", "content": "y"], at: 3),
            ["type": "user", "timestamp": ts(4), "toolUseResult": ["type": "update", "filePath": "/r/README.md"],
             "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t3", "content": "ok"]]]],
            claudeTool("Edit", ["file_path": "/r/docs/plan.md", "old_string": "a", "new_string": "b"], at: 5),
            claudeTool("NotebookEdit", ["notebook_path": "/r/nb.ipynb", "new_source": "x"], at: 6),
            claudeTool("Read", ["file_path": "/r/ignored.md"], at: 7),
        ])
        let files = l.files(exists: { _ in true })
        XCTAssertEqual(files.map(\.path), ["/r/docs/plan.md", "/r/README.md", "/r/nb.ipynb", "/r/Sources/A.swift"])
        XCTAssertEqual(files.map(\.action), [.created, .modified, .modified, .modified])
        XCTAssertEqual(files.map(\.count), [2, 1, 1, 1])
        XCTAssertEqual(files.map(\.isDocument), [true, true, false, false])
        let plan = files[0]
        XCTAssertEqual(plan.firstTouched, AgentTranscriptReader.parseISODate(ts(1)))
        XCTAssertEqual(plan.lastTouched, AgentTranscriptReader.parseISODate(ts(5)))
    }

    func testClaudeRelativePathsUseLineCwdThenSessionCwd() {
        let l = log(.claude, cwd: "/session", [
            claudeTool("Write", ["file_path": "out/report.html"], at: 1, cwd: "/line/cwd"),
            claudeTool("Edit", ["file_path": "./src/../lib/b.swift"], at: 2),
            claudeTool("Write", ["file_path": "~/notes.txt"], at: 3),
        ])
        let paths = Set(l.files(exists: { _ in true }).map(\.path))
        XCTAssertEqual(paths, ["/line/cwd/out/report.html", "/session/lib/b.swift", NSHomeDirectory() + "/notes.txt"])
    }

    // MARK: Codex

    func testCodexPatchActionsAndWorkdir() {
        let patch = "*** Begin Patch\n*** Add File: docs/new.md\n+hi\n*** Update File: src/a.rs\n@@\n-x\n+y\n" +
            "*** Delete File: old.txt\n*** Update File: src/m.rs\n*** Move to: src/n.rs\n*** End Patch"
        let execArgs = try! JSONSerialization.data(withJSONObject: [
            "cmd": "apply_patch <<'EOF'\n*** Begin Patch\n*** Update File: b.rs\n*** End Patch\nEOF", "workdir": "/r/sub"])
        let l = log(.codex, [
            ["type": "session_meta", "timestamp": ts(0), "payload": ["id": "x", "cwd": "/r"]],
            ["type": "response_item", "timestamp": ts(1), "payload": ["type": "custom_tool_call", "name": "apply_patch", "input": patch]],
            ["type": "response_item", "timestamp": ts(2), "payload": ["type": "function_call", "name": "exec_command",
                                                                      "arguments": String(data: execArgs, encoding: .utf8)!]],
            ["type": "response_item", "timestamp": ts(3), "payload": ["type": "function_call", "name": "exec_command",
                                                                      "arguments": "{\"cmd\":\"cat '*** Add File' notes\"}"]],
        ])
        let files = l.files(exists: { $0 != "/r/old.txt" })
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        XCTAssertEqual(byPath["/r/docs/new.md"]?.action, .created)
        XCTAssertEqual(byPath["/r/src/a.rs"]?.action, .modified)
        XCTAssertEqual(byPath["/r/old.txt"]?.action, .deleted)
        XCTAssertEqual(byPath["/r/old.txt"]?.exists, false)
        XCTAssertEqual(byPath["/r/src/m.rs"]?.action, .deleted)
        XCTAssertEqual(byPath["/r/src/n.rs"]?.action, .created)
        XCTAssertEqual(byPath["/r/sub/b.rs"]?.action, .modified)
        XCTAssertEqual(Set(files.prefix(2).map(\.path)), ["/r/docs/new.md", "/r/old.txt"], "documents first")
        XCTAssertEqual(files.count, 6)
    }

    // MARK: pi

    func testPiWriteAndEdit() {
        func call(_ name: String, _ args: [String: Any], _ second: Int) -> [String: Any] {
            ["type": "message", "timestamp": ts(second), "message": ["role": "assistant", "content": [
                ["type": "toolCall", "id": "c\(second)", "name": name, "arguments": args]]]]
        }
        let l = log(.pi, [
            call("write", ["path": "out.csv", "content": "a,b"], 1),
            call("edit", ["path": "/r/main.py", "oldText": "a", "newText": "b"], 2),
            call("bash", ["command": "ls"], 3),
            call("write", ["path": "/r/main.py", "content": "z"], 4),
        ])
        let files = l.files(exists: { _ in true })
        XCTAssertEqual(files.map(\.path), ["/r/out.csv", "/r/main.py"])
        XCTAssertEqual(files.map(\.action), [.created, .modified])
        XCTAssertEqual(files[1].count, 2)
    }

    // MARK: 排序、去重、临时文件

    func testOrderMostRecentFirstWithinSectionsAndDeleteThenRecreate() {
        var l = TouchedFilesLog(kind: .codex, cwd: "/r")
        l.apply(.modify("/r/a.swift"), at: Date(timeIntervalSince1970: 10))
        l.apply(.modify("/r/b.swift"), at: Date(timeIntervalSince1970: 20))
        l.apply(.create("/r/x.md"), at: Date(timeIntervalSince1970: 5))
        l.apply(.modify("/r/a.swift"), at: Date(timeIntervalSince1970: 30))
        l.apply(.delete("/r/y.txt"), at: nil)
        l.apply(.create("/r/y.txt"), at: nil)
        let files = l.files(exists: { _ in true })
        XCTAssertEqual(files.map(\.path), ["/r/x.md", "/r/y.txt", "/r/a.swift", "/r/b.swift"])
        XCTAssertEqual(files[1].action, .created)
    }

    func testTemporaryFilesOnlyWhenNothingElse() {
        var l = TouchedFilesLog(kind: .claude, cwd: "/r")
        l.apply(.write("/tmp/scratch.md"), at: nil)
        XCTAssertEqual(l.files(exists: { _ in true }).map(\.path), ["/tmp/scratch.md"])
        l.apply(.write("/r/real.md"), at: nil)
        XCTAssertEqual(l.files(exists: { _ in true }).map(\.path), ["/r/real.md"])
    }

    func testMissingFilesAreMarked() {
        var l = TouchedFilesLog(kind: .claude, cwd: "/r")
        l.apply(.write("/r/gone.md"), at: nil)
        let file = l.files(exists: { _ in false })[0]
        XCTAssertFalse(file.exists)
        XCTAssertEqual(file.action, .created)
    }

    func testClassification() {
        for doc in ["/r/a.md", "/r/b.PDF", "/r/c.png", "/r/d.xlsx", "/r/docs/api.json", "/r/doc/x.yaml", "/r/e.html"] {
            XCTAssertTrue(TouchedFiles.isDocument(doc), doc)
        }
        for code in ["/r/a.swift", "/r/package.json", "/r/config.yaml", "/r/Makefile", "/r/docs.json"] {
            XCTAssertFalse(TouchedFiles.isDocument(code), code)
        }
    }

    func testRelativePath() {
        XCTAssertEqual(TouchedFiles.relativePath("/p/root/docs/a.md", root: "/p/root", home: "/h"), "docs/a.md")
        XCTAssertEqual(TouchedFiles.relativePath("/h/other/a.md", root: "/p/root", home: "/h"), "~/other/a.md")
        XCTAssertEqual(TouchedFiles.relativePath("/etc/hosts", root: nil, home: "/h"), "/etc/hosts")
    }

    // MARK: 增量读取

    func testTrackerReadsIncrementallyAndKeepsPartialLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("touched-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.jsonl")
        let first = data([claudeTool("Write", ["file_path": "/r/a.md"], at: 1)])
        let second = data([claudeTool("Edit", ["file_path": "/r/b.swift"], at: 2)])
        // 第二行先只写一半。
        let half = second.count / 2
        try (first + second.prefix(half)).write(to: url)
        let tracker = TouchedFilesTracker(url: url, kind: .claude, cwd: "/r")
        XCTAssertTrue(tracker.refresh())
        XCTAssertEqual(tracker.log.files(exists: { _ in true }).map(\.path), ["/r/a.md"])
        XCTAssertFalse(tracker.refresh(), "unchanged file is not re-read")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: second.suffix(from: half))
        try handle.close()
        XCTAssertTrue(tracker.refresh())
        XCTAssertEqual(tracker.log.files(exists: { _ in true }).map(\.path), ["/r/a.md", "/r/b.swift"])
        // 文件被重写变短：从头再读。
        try data([claudeTool("Edit", ["file_path": "/r/c.swift"], at: 3)]).write(to: url)
        XCTAssertTrue(tracker.refresh())
        XCTAssertEqual(tracker.log.files(exists: { _ in true }).map(\.path), ["/r/c.swift"])
    }
}

final class TerminalPathsTests: XCTestCase {
    private func token(_ line: String, at needle: String, offset: Int = 1) -> String? {
        guard let range = line.range(of: needle) else { return nil }
        let column = line.distance(from: line.startIndex, to: range.lowerBound) + offset
        return TerminalPaths.token(in: line, column: column)
    }

    func testTokensStripPunctuationQuotesAndLineNumbers() {
        XCTAssertEqual(token("error at Sources/App/foo.swift:12:3: bad", at: "foo"), "Sources/App/foo.swift")
        XCTAssertEqual(token("see \"/Users/me/docs/plan.md\".", at: "plan"), "/Users/me/docs/plan.md")
        XCTAssertEqual(token("⏺ Update(src/main.rs)", at: "main"), "src/main.rs")
        XCTAssertEqual(token("wrote ~/out/report.html, done", at: "report"), "~/out/report.html")
        XCTAssertEqual(token("已写入 docs/说明.md。", at: "说明"), "docs/说明.md")
        XCTAssertEqual(token("open file:///tmp/a%20b.txt now", at: "tmp"), "/tmp/a b.txt")
        XCTAssertEqual(token("link src/a.ts#L10-L20", at: "a.ts"), "src/a.ts")
        XCTAssertEqual(token("(README.md)", at: "README"), "README.md")
    }

    func testNonPathsAreRejected() {
        XCTAssertNil(token("hello world", at: "hello"))
        XCTAssertNil(token("version 1.2.3", at: "1.2"))
        XCTAssertNil(token("visit https://example.com/x", at: "example"))
        XCTAssertNil(TerminalPaths.token(in: "a b", column: 1), "space")
        XCTAssertNil(TerminalPaths.token(in: "abc", column: 10), "out of range")
    }

    func testCandidatesResolveRelativeHomeAndDiffPrefixes() {
        XCTAssertEqual(TerminalPaths.candidates(for: "src/a.swift", cwd: "/r", home: "/h"), ["/r/src/a.swift"])
        XCTAssertEqual(TerminalPaths.candidates(for: "~/x.md", cwd: "/r", home: "/h"), ["/h/x.md"])
        XCTAssertEqual(TerminalPaths.candidates(for: "b/src/a.swift", cwd: "/r", home: "/h"),
                       ["/r/b/src/a.swift", "/r/src/a.swift"])
        XCTAssertEqual(TerminalPaths.resolve(line: "M b/src/a.swift", column: 4, cwd: "/r", home: "/h",
                                             exists: { $0 == "/r/src/a.swift" }), "/r/src/a.swift")
        XCTAssertNil(TerminalPaths.resolve(line: "M src/none.swift", column: 4, cwd: "/r", home: "/h", exists: { _ in false }))
    }
}
