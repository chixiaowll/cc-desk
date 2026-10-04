import XCTest
@testable import CCDeskCore

/// 项目监视的过滤规则、生成记录与三个来源的合并。
final class GeneratedFilesTests: XCTestCase {
    func testIncludesOrdinaryOutputsUnderRoot() {
        let root = "/p/proj"
        XCTAssertTrue(ProjectWatchRules.shouldInclude(path: "/p/proj/out/anime-test/sheet.jpg", root: root))
        XCTAssertTrue(ProjectWatchRules.shouldInclude(path: "/p/proj/report.md", root: root + "/"))
        XCTAssertTrue(ProjectWatchRules.shouldInclude(path: "/p/proj/.github/workflows/ci.yml", root: root))
        XCTAssertFalse(ProjectWatchRules.shouldInclude(path: "/p/proj", root: root))
        XCTAssertFalse(ProjectWatchRules.shouldInclude(path: "/p/project2/a.md", root: root))
        XCTAssertFalse(ProjectWatchRules.shouldInclude(path: "/other/a.md", root: root))
    }

    func testIgnoresBuildDependencyAndCacheDirectories() {
        let root = "/p/proj"
        for dir in [".git", "node_modules", ".build", "build", "dist", "DerivedData", "__pycache__", ".venv", "venv",
                    "target", ".next", ".cache"] {
            XCTAssertFalse(ProjectWatchRules.shouldInclude(path: "\(root)/\(dir)/x/y.txt", root: root), dir)
            XCTAssertFalse(ProjectWatchRules.shouldInclude(path: "\(root)/sub/\(dir)/y.png", root: root), dir)
        }
        // 名字只是包含这些词的目录不受影响。
        XCTAssertTrue(ProjectWatchRules.shouldInclude(path: "\(root)/builder/y.png", root: root))
    }

    func testIgnoresTempAndSwapFiles() {
        let root = "/p/proj"
        for name in [".DS_Store", "a.md.swp", ".a.md.swo", "notes.txt~", ".#notes.txt", "4913", "x.tmp", "m.pyc"] {
            XCTAssertFalse(ProjectWatchRules.shouldInclude(path: "\(root)/docs/\(name)", root: root), name)
        }
    }

    func testRefusesHomeRootAndBroadFolders() {
        let home = "/Users/me"
        XCTAssertEqual(ProjectWatchRules.refusal(root: "/", home: home), .tooBroad)
        XCTAssertEqual(ProjectWatchRules.refusal(root: home, home: home), .tooBroad)
        XCTAssertEqual(ProjectWatchRules.refusal(root: "/Users", home: home), .tooBroad)
        XCTAssertEqual(ProjectWatchRules.refusal(root: home + "/Documents", home: home), .tooBroad)
        XCTAssertEqual(ProjectWatchRules.refusal(root: home + "/Downloads/", home: home), .tooBroad)
        XCTAssertNil(ProjectWatchRules.refusal(root: home + "/Documents/work/app", home: home))
        XCTAssertNil(ProjectWatchRules.refusal(root: "/opt/src/app", home: home))
    }

    func testGeneratedLogCollapsesBurstsAndCaps() {
        var log = GeneratedFilesLog()
        let t0 = Date(timeIntervalSince1970: 100)
        log.record("/p/a.png", created: true, at: t0)
        log.record("/p/a.png", created: false, at: t0.addingTimeInterval(1))
        log.record("/p/b.py", created: false, at: t0.addingTimeInterval(2))
        let files = log.files(exists: { _ in true })
        XCTAssertEqual(files.map(\.path), ["/p/b.py", "/p/a.png"])
        XCTAssertEqual(files.last?.action, .created)
        XCTAssertEqual(files.last?.count, 2)
        XCTAssertEqual(files.first?.action, .modified)
        XCTAssertEqual(files.first?.origin, .generated)
        log.remove("/p/b.py")
        XCTAssertEqual(log.count, 1)
        for i in 0..<(GeneratedFilesLog.maxKept + 3) { log.record("/p/\(i).txt", created: true, at: t0) }
        XCTAssertEqual(log.count, GeneratedFilesLog.maxKept)
        XCTAssertFalse(log.files(exists: { _ in true }).contains { $0.path == "/p/a.png" })
    }

    private func file(_ path: String, _ origin: TouchOrigin, at second: TimeInterval, action: TouchAction = .created) -> TouchedFile {
        let t = Date(timeIntervalSince1970: second)
        return TouchedFile(path: path, firstTouched: t, lastTouched: t, action: action, count: 1,
                           isDocument: TouchedFiles.isDocument(path), exists: true, origin: origin)
    }

    func testMergeDedupesWithMostInformativeOriginAndOrdersDocumentsFirst() {
        let tool = [file("/p/plan.md", .tool, at: 1)]
        let generated = [file("/p/plan.md", .generated, at: 5), file("/p/out/sheet.jpg", .generated, at: 3),
                         file("/p/run.py", .generated, at: 9)]
        let mentioned = [file("/p/out/sheet.jpg", .mentioned, at: 4), file("/p/notes.txt", .mentioned, at: 2),
                         file("/p/plan.md", .mentioned, at: 6)]
        let merged = TouchedFilesMerge.merge(tool: tool, generated: generated, mentioned: mentioned)
        XCTAssertEqual(merged.tool.map(\.path), ["/p/plan.md"])
        // plan.md 只在工具列表里；sheet.jpg 取「生成」；文档在前、代码在后，各自按时间倒序。
        XCTAssertEqual(merged.extra.map(\.path), ["/p/out/sheet.jpg", "/p/notes.txt", "/p/run.py"])
        XCTAssertEqual(merged.extra.map(\.origin), [.generated, .mentioned, .generated])
    }
}
