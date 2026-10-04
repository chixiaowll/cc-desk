import XCTest
@testable import CCDeskCore

/// 「提到的文件」：从 agent 回复文字里抽路径，只收存在的普通文件。
final class MentionedFilesTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mentions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("out/anime-test"), withIntermediateDirectories: true)
        root = dir.path
        for name in ["out/anime-test/sheet.jpg", "report.md", "out/clip.mp4", "src/main.py"] {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func line(_ obj: [String: Any]) -> Data {
        let d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return d + Data("\n".utf8)
    }

    private func mentioned(_ kind: AgentKind, _ lines: [[String: Any]]) -> [String] {
        var log = TouchedFilesLog(kind: kind, cwd: root)
        log.ingest(lines.map(line).reduce(Data(), +))
        return log.mentions.files().map(\.path)
    }

    func testTokensStripQuotesBracketsCJKPunctuationAndLineNumbers() {
        let text = "生成了 `out/a.png`，见（docs/plan.md:12:3）和 **report.md**。[链接](src/x.py#L4) https://x.com/a.png 版本 1.2.3"
        XCTAssertEqual(MentionedFiles.tokens(in: text), ["out/a.png", "docs/plan.md", "report.md", "src/x.py"])
    }

    func testVariantsDropCJKGluedToThePath() {
        XCTAssertEqual(MentionedFiles.variants(of: "已保存到out/a.png里"), ["已保存到out/a.png里", "out/a.png"])
        XCTAssertEqual(MentionedFiles.variants(of: "out/a.png"), ["out/a.png"])
    }

    func testClaudeAssistantTextResolvesRelativeAndChecksExistence() {
        let paths = mentioned(.claude, [
            ["type": "assistant", "timestamp": "2026-10-03T06:00:01.000Z",
             "message": ["role": "assistant", "content": [
                ["type": "text", "text": "图已生成：out/anime-test/sheet.jpg，缺失的 out/missing.png 不会列出；目录 out/ 也不列。"],
                ["type": "tool_use", "name": "Bash", "input": ["command": "ls report.md"]]]]],
            // 用户说的话不算。
            ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": "看看 report.md"]]]],
        ])
        XCTAssertEqual(paths, [root + "/out/anime-test/sheet.jpg"])
    }

    func testClaudeUsesLineCwdAndHome() {
        let paths = mentioned(.claude, [
            ["type": "assistant", "cwd": root + "/out",
             "message": ["role": "assistant", "content": [["type": "text", "text": "视频在 clip.mp4"]]]],
        ])
        XCTAssertEqual(paths, [root + "/out/clip.mp4"])
        let home = MentionedFiles.paths(in: "见 ~/report.md", base: "/nowhere", home: root)
        XCTAssertEqual(home, [root + "/report.md"])
    }

    func testCodexAgentMessages() {
        let paths = mentioned(.codex, [
            ["type": "response_item", "payload": ["type": "message", "role": "assistant",
                                                  "content": [["type": "output_text", "text": "Wrote report.md."]]]],
            ["type": "event_msg", "payload": ["type": "agent_message", "message": "Saved \"out/clip.mp4\""]],
            ["type": "response_item", "payload": ["type": "message", "role": "user",
                                                  "content": [["type": "input_text", "text": "src/main.py"]]]],
        ])
        XCTAssertEqual(Set(paths), [root + "/report.md", root + "/out/clip.mp4"])
    }

    func testPiAssistantText() {
        let paths = mentioned(.pi, [
            ["type": "message", "message": ["role": "assistant", "content": [
                ["type": "thinking", "thinking": "src/main.py"],
                ["type": "text", "text": "改好了 src/main.py:10"]]]],
        ])
        XCTAssertEqual(paths, [root + "/src/main.py"])
    }

    func testMentionLogKeepsNewestFirstAndCaps() {
        var log = MentionedFilesLog(kind: .claude, cwd: root)
        for i in 0..<(MentionedFiles.maxKept + 5) { log.record("/p/\(i).md", at: nil) }
        let files = log.files(exists: { _ in true })
        XCTAssertEqual(files.count, MentionedFiles.maxKept)
        XCTAssertEqual(files.first?.path, "/p/\(MentionedFiles.maxKept + 4).md")
        XCTAssertFalse(files.contains { $0.path == "/p/0.md" })
        XCTAssertEqual(files.first?.origin, .mentioned)
    }

    func testMediaCountsAsDocument() {
        XCTAssertTrue(TouchedFiles.isDocument("/a/clip.mp4"))
        XCTAssertTrue(TouchedFiles.isDocument("/a/voice.wav"))
        XCTAssertFalse(TouchedFiles.isDocument("/a/main.py"))
    }
}
