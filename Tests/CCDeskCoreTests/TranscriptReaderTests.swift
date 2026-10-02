import XCTest
@testable import CCDeskCore

final class TranscriptReaderTests: XCTestCase {
    private func data(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    // MARK: - meta(fromTail:)

    func testMetaPicksLastCustomTitleAiTitleAndNonEmptyLastPrompt() {
        let d = data([
            #"{"type":"ai-title","aiTitle":"第一个标题","sessionId":"s"}"#,
            #"{"type":"last-prompt","leafUuid":"x","sessionId":"s"}"#,
            #"{"type":"ai-title","aiTitle":"第二个标题","sessionId":"s"}"#,
            #"{"type":"custom-title","customTitle":"手动标题","sessionId":"s"}"#,
            #"{"type":"last-prompt","lastPrompt":"帮我写一个函数","leafUuid":"y","sessionId":"s"}"#,
        ])
        let meta = TranscriptReader.meta(fromTail: d)
        XCTAssertEqual(meta.customTitle, "手动标题")
        XCTAssertEqual(meta.aiTitle, "第二个标题")
        XCTAssertEqual(meta.lastPrompt, "帮我写一个函数")
    }

    func testMetaSkipsLastPromptWithoutText() {
        let d = data([
            #"{"type":"last-prompt","lastPrompt":"有内容","leafUuid":"x","sessionId":"s"}"#,
            #"{"type":"last-prompt","leafUuid":"y","sessionId":"s"}"#,
        ])
        XCTAssertEqual(TranscriptReader.meta(fromTail: d).lastPrompt, "有内容")
    }

    func testMetaToleratesTruncatedFirstLine() {
        var d = Data("tle\":\"腰斩的半行\",\"sessionId\":\"s\"}\n".utf8)
        d.append(Data(#"{"type":"ai-title","aiTitle":"完整标题","sessionId":"s"}"#.utf8))
        let meta = TranscriptReader.meta(fromTail: d)
        XCTAssertEqual(meta.aiTitle, "完整标题")
    }

    func testMetaSkipsLinesWithInvalidUTF8AtChunkBoundary() {
        var d = Data([0xFF, 0xFE, 0x0A]) // invalid utf8 bytes then newline
        d.append(Data(#"{"type":"ai-title","aiTitle":"有效标题","sessionId":"s"}"#.utf8))
        let meta = TranscriptReader.meta(fromTail: d)
        XCTAssertEqual(meta.aiTitle, "有效标题")
    }

    func testMetaWithNoRecognizedLinesReturnsAllNil() {
        let d = data([#"{"type":"mode","mode":"normal","sessionId":"s"}"#])
        let meta = TranscriptReader.meta(fromTail: d)
        XCTAssertNil(meta.customTitle)
        XCTAssertNil(meta.aiTitle)
        XCTAssertNil(meta.lastPrompt)
    }

    // MARK: - cwd(fromHead:)

    func testCwdReturnsFirstRecordWithCwd() {
        let d = data([
            #"{"type":"last-prompt","sessionId":"s"}"#,
            #"{"type":"mode","mode":"normal","sessionId":"s"}"#,
            #"{"parentUuid":null,"cwd":"/Users/x/poems","sessionId":"s"}"#,
            #"{"parentUuid":null,"cwd":"/Users/x/other","sessionId":"s"}"#,
        ])
        XCTAssertEqual(TranscriptReader.cwd(fromHead: d), "/Users/x/poems")
    }

    func testCwdReturnsNilWhenAbsent() {
        let d = data([#"{"type":"mode","mode":"normal","sessionId":"s"}"#])
        XCTAssertNil(TranscriptReader.cwd(fromHead: d))
    }

    func testCwdIgnoresEmptyString() {
        let d = data([
            #"{"cwd":"","sessionId":"s"}"#,
            #"{"cwd":"/Users/x/poems","sessionId":"s"}"#,
        ])
        XCTAssertEqual(TranscriptReader.cwd(fromHead: d), "/Users/x/poems")
    }

    // MARK: - readTail / readHead (real file I/O, no whole-file reads)

    func testReadTailReturnsOnlyLastNBytes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.jsonl")
        let content = "0123456789ABCDEFGHIJ"
        try content.write(to: url, atomically: true, encoding: .utf8)

        let tail = TranscriptReader.readTail(url, bytes: 5)
        XCTAssertEqual(String(data: tail, encoding: .utf8), "FGHIJ")
    }

    func testReadTailReturnsWholeFileWhenSmallerThanLimit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.jsonl")
        try "short".write(to: url, atomically: true, encoding: .utf8)

        let tail = TranscriptReader.readTail(url, bytes: 256 * 1024)
        XCTAssertEqual(String(data: tail, encoding: .utf8), "short")
    }

    func testReadHeadReturnsOnlyFirstNBytes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.jsonl")
        let content = "0123456789ABCDEFGHIJ"
        try content.write(to: url, atomically: true, encoding: .utf8)

        let head = TranscriptReader.readHead(url, bytes: 5)
        XCTAssertEqual(String(data: head, encoding: .utf8), "01234")
    }

    func testReadTailOfMissingFileReturnsEmptyData() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString).jsonl")
        XCTAssertEqual(TranscriptReader.readTail(url, bytes: 10), Data())
        XCTAssertEqual(TranscriptReader.readHead(url, bytes: 10), Data())
    }

    // MARK: - TranscriptMeta.displayTitle

    func testDisplayTitlePrefersCustomTitle() {
        let meta = TranscriptMeta(customTitle: "自定义", aiTitle: "AI标题", lastPrompt: "随便写点什么内容超过二十个字符用于截断测试")
        XCTAssertEqual(meta.displayTitle(fallbackName: "fallback", fallbackIsDerived: false), "自定义")
    }

    func testDisplayTitleFallsBackToAiTitle() {
        let meta = TranscriptMeta(customTitle: nil, aiTitle: "AI标题", lastPrompt: "随便写点什么")
        XCTAssertEqual(meta.displayTitle(fallbackName: "fallback", fallbackIsDerived: false), "AI标题")
    }

    func testDisplayTitleFallsBackToTruncatedLastPrompt() {
        let meta = TranscriptMeta(customTitle: nil, aiTitle: nil, lastPrompt: "这是一个很长的提示词用来测试超过二十个字符时的截断行为和省略号")
        let title = meta.displayTitle(fallbackName: "fallback", fallbackIsDerived: false)
        XCTAssertEqual(title, "这是一个很长的提示词用来测试超过二十个字…")
        XCTAssertEqual(title.count, 21) // 20 chars + ellipsis
    }

    func testDisplayTitleCollapsesNewlinesInLastPrompt() {
        let meta = TranscriptMeta(customTitle: nil, aiTitle: nil, lastPrompt: "第一行\n第二行")
        XCTAssertEqual(meta.displayTitle(fallbackName: nil, fallbackIsDerived: false), "第一行 第二行")
    }

    func testDisplayTitleDoesNotAppendEllipsisWhenNotTruncated() {
        let meta = TranscriptMeta(customTitle: nil, aiTitle: nil, lastPrompt: "短提示")
        XCTAssertEqual(meta.displayTitle(fallbackName: nil, fallbackIsDerived: false), "短提示")
    }

    func testDisplayTitleFallsBackToNonDerivedFallbackName() {
        let meta = TranscriptMeta(customTitle: nil, aiTitle: nil, lastPrompt: nil)
        XCTAssertEqual(meta.displayTitle(fallbackName: "poems-06", fallbackIsDerived: false), "poems-06")
    }

    func testDisplayTitleSkipsDerivedFallbackName() {
        let meta = TranscriptMeta(customTitle: nil, aiTitle: nil, lastPrompt: nil)
        XCTAssertEqual(meta.displayTitle(fallbackName: "poems-06", fallbackIsDerived: true), "新会话")
    }

    func testDisplayTitleSkipsEmptyOrWhitespaceCandidates() {
        let meta = TranscriptMeta(customTitle: "   ", aiTitle: "", lastPrompt: "  ")
        XCTAssertEqual(meta.displayTitle(fallbackName: " ", fallbackIsDerived: false), "新会话")
    }

    func testDisplayTitleTrimsWhitespace() {
        let meta = TranscriptMeta(customTitle: "  带空格的标题  ", aiTitle: nil, lastPrompt: nil)
        XCTAssertEqual(meta.displayTitle(fallbackName: nil, fallbackIsDerived: false), "带空格的标题")
    }

    func testDisplayTitleDefaultsToNewSessionWhenNothingAvailable() {
        let meta = TranscriptMeta(customTitle: nil, aiTitle: nil, lastPrompt: nil)
        XCTAssertEqual(meta.displayTitle(fallbackName: nil, fallbackIsDerived: false), "新会话")
    }
}
