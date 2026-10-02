import XCTest
@testable import CCDeskCore

final class TranscriptIndexTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    @discardableResult
    private func writeTranscript(project: String, sessionID: String, cwd: String?, lines extraLines: [String] = [],
                                 mtime: Date? = nil) -> URL {
        let dir = root.appendingPathComponent(project, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(sessionID).jsonl")
        var lines: [String] = []
        if let cwd {
            lines.append(#"{"parentUuid":null,"cwd":"\#(cwd)","sessionId":"\#(sessionID)"}"#)
        }
        lines.append(contentsOf: extraLines)
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
        return url
    }

    func testHistoryReturnsItemsSortedByMtimeDescending() {
        writeTranscript(project: "p1", sessionID: "old", cwd: "/r/a",
                        lines: [#"{"type":"ai-title","aiTitle":"旧的","sessionId":"old"}"#],
                        mtime: Date(timeIntervalSince1970: 1000))
        writeTranscript(project: "p2", sessionID: "new", cwd: "/r/b",
                        lines: [#"{"type":"ai-title","aiTitle":"新的","sessionId":"new"}"#],
                        mtime: Date(timeIntervalSince1970: 2000))

        let index = TranscriptIndex(root: root)
        let items = index.history(excluding: [])
        XCTAssertEqual(items.map(\.sessionID), ["new", "old"])
        XCTAssertEqual(items.map(\.title), ["新的", "旧的"])
        XCTAssertEqual(items.map(\.cwd), ["/r/b", "/r/a"])
    }

    func testHistoryExcludesLiveSessions() {
        writeTranscript(project: "p1", sessionID: "live-one", cwd: "/r/a", mtime: Date(timeIntervalSince1970: 1000))
        writeTranscript(project: "p1", sessionID: "history-one", cwd: "/r/a", mtime: Date(timeIntervalSince1970: 1000))

        let index = TranscriptIndex(root: root)
        let items = index.history(excluding: ["live-one"])
        XCTAssertEqual(items.map(\.sessionID), ["history-one"])
    }

    func testHistorySkipsFilesWithoutCwd() {
        writeTranscript(project: "p1", sessionID: "no-cwd", cwd: nil,
                        lines: [#"{"type":"mode","mode":"normal","sessionId":"no-cwd"}"#],
                        mtime: Date(timeIntervalSince1970: 1000))
        writeTranscript(project: "p1", sessionID: "has-cwd", cwd: "/r/a", mtime: Date(timeIntervalSince1970: 1000))

        let index = TranscriptIndex(root: root)
        let items = index.history(excluding: [])
        XCTAssertEqual(items.map(\.sessionID), ["has-cwd"])
    }

    func testHistorySupportsNonASCIICwd() {
        writeTranscript(project: "p1", sessionID: "s", cwd: "/Users/x/中文目录/项目",
                        mtime: Date(timeIntervalSince1970: 1000))

        let index = TranscriptIndex(root: root)
        let items = index.history(excluding: [])
        XCTAssertEqual(items.first?.cwd, "/Users/x/中文目录/项目")
    }

    func testHistoryUsesDisplayTitleFallbackRuleWithDerivedFallback() {
        // 历史列表没有 fallbackName 可用：应退到 "新会话" 而非任何 "#xx" 缩写。
        writeTranscript(project: "p1", sessionID: "s", cwd: "/r/a", mtime: Date(timeIntervalSince1970: 1000))

        let index = TranscriptIndex(root: root)
        let items = index.history(excluding: [])
        XCTAssertEqual(items.first?.title, "新会话")
    }

    func testMetaForSessionLocatesFileAcrossProjectDirectories() {
        writeTranscript(project: "p1", sessionID: "a", cwd: "/r/a",
                        lines: [#"{"type":"ai-title","aiTitle":"甲标题","sessionId":"a"}"#])
        writeTranscript(project: "p2", sessionID: "b", cwd: "/r/b",
                        lines: [#"{"type":"ai-title","aiTitle":"乙标题","sessionId":"b"}"#])

        let index = TranscriptIndex(root: root)
        XCTAssertEqual(index.meta(forSession: "b")?.aiTitle, "乙标题")
        XCTAssertEqual(index.meta(forSession: "a")?.aiTitle, "甲标题")
    }

    func testMetaForUnknownSessionReturnsNil() {
        let index = TranscriptIndex(root: root)
        XCTAssertNil(index.meta(forSession: "nope"))
    }

    func testCacheIsNotRefreshedWhenMtimeAndSizeAreUnchanged() {
        let url = writeTranscript(project: "p1", sessionID: "s", cwd: "/r/a",
                                  lines: [#"{"type":"ai-title","aiTitle":"第一版","sessionId":"s"}"#],
                                  mtime: Date(timeIntervalSince1970: 1000))

        let index = TranscriptIndex(root: root)
        XCTAssertEqual(index.meta(forSession: "s")?.aiTitle, "第一版")

        // 直接改写内容但保持同样的 mtime/size（同样长度的新标题）：索引必须继续返回缓存的旧值。
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let sameSizeReplacement = original.replacingOccurrences(of: "第一版", with: "第二版")
        XCTAssertEqual(original.utf8.count, sameSizeReplacement.utf8.count, "test setup requires equal byte size")
        try? sameSizeReplacement.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: url.path)

        XCTAssertEqual(index.meta(forSession: "s")?.aiTitle, "第一版", "cache should not refresh when mtime/size unchanged")
    }

    func testCacheRefreshesWhenMtimeChanges() {
        let url = writeTranscript(project: "p1", sessionID: "s", cwd: "/r/a",
                                  lines: [#"{"type":"ai-title","aiTitle":"第一版","sessionId":"s"}"#],
                                  mtime: Date(timeIntervalSince1970: 1000))

        let index = TranscriptIndex(root: root)
        XCTAssertEqual(index.meta(forSession: "s")?.aiTitle, "第一版")

        let updated = #"{"parentUuid":null,"cwd":"/r/a","sessionId":"s"}"# + "\n" + #"{"type":"ai-title","aiTitle":"第二版","sessionId":"s"}"#
        try? updated.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: url.path)

        XCTAssertEqual(index.meta(forSession: "s")?.aiTitle, "第二版")
    }

    func testHistoryRespectsLimit() {
        for i in 0..<5 {
            writeTranscript(project: "p1", sessionID: "s\(i)", cwd: "/r/a", mtime: Date(timeIntervalSince1970: Double(i)))
        }
        let index = TranscriptIndex(root: root)
        let items = index.history(excluding: [], limit: 2)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.sessionID), ["s4", "s3"])
    }
}
