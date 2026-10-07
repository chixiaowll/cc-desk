import XCTest
@testable import CCDeskCore

final class ProjectFileTreeTests: XCTestCase {
    private let tree = ProjectFileTree(files: [
        "README.md", "Sources/App/main.swift", "Sources/App/View.swift", "Sources/Core/Model.swift",
        "docs/spec.md", "file10.txt", "file2.txt",
    ])

    func testChildrenListDirectoriesFirstThenNaturalOrder() {
        XCTAssertEqual(tree.children(of: "").map(\.name), ["docs", "Sources", "file2.txt", "file10.txt", "README.md"])
        XCTAssertEqual(tree.children(of: "Sources").map(\.relativePath), ["Sources/App", "Sources/Core"])
        XCTAssertTrue(tree.children(of: "Sources").allSatisfy(\.isDirectory))
        XCTAssertEqual(tree.children(of: "Sources/App").map(\.name), ["main.swift", "View.swift"])
    }

    func testVisibleEntriesFollowExpandedDirectories() {
        XCTAssertEqual(tree.visibleEntries(expanded: []).count, 5)
        let open = tree.visibleEntries(expanded: ["Sources", "Sources/Core"]).map(\.relativePath)
        XCTAssertEqual(open, ["docs", "Sources", "Sources/App", "Sources/Core", "Sources/Core/Model.swift",
                              "file2.txt", "file10.txt", "README.md"])
        // 父目录收起时，展开过的子目录也不显示。
        XCTAssertFalse(tree.visibleEntries(expanded: ["Sources/Core"]).contains { $0.relativePath.hasPrefix("Sources/") })
        XCTAssertEqual(ProjectFileEntry(relativePath: "Sources/Core/Model.swift", isDirectory: false).depth, 2)
    }

    func testSearchRanksFileNameMatchesFirst() {
        let hits = tree.search("swift").map(\.relativePath)
        XCTAssertEqual(Set(hits), ["Sources/App/main.swift", "Sources/App/View.swift", "Sources/Core/Model.swift"])
        XCTAssertEqual(tree.search("model").first?.relativePath, "Sources/Core/Model.swift")
        XCTAssertEqual(tree.search("app view").map(\.relativePath), ["Sources/App/View.swift"])
        XCTAssertEqual(tree.search("  "), [])
        // 文件名开头命中排在只在目录名里命中之前。
        let docs = ProjectFileTree(files: ["spec/notes.md", "docs/spec.md"])
        XCTAssertEqual(docs.search("spec").first?.relativePath, "docs/spec.md")
    }

    func testAncestorDirectoriesAndGitParsing() {
        XCTAssertEqual(ProjectFileTree.ancestorDirectories(of: ["a/b/c.txt", "a/d.txt", "e.txt"]), ["a", "a/b"])
        XCTAssertEqual(ProjectFileTree.parseGitList("a.txt\0目录/文件 名.md\0"), ["a.txt", "目录/文件 名.md"])
    }

    func testQuoteIfNeeded() {
        XCTAssertEqual(ShellQuote.quoteIfNeeded("docs/spec-v2.md"), "docs/spec-v2.md")
        XCTAssertEqual(ShellQuote.quoteIfNeeded("文档/设计.md"), "文档/设计.md")
        XCTAssertEqual(ShellQuote.quoteIfNeeded("my file.md"), "'my file.md'")
        XCTAssertEqual(ShellQuote.quoteIfNeeded("it's.md"), "'it'\\''s.md'")
        XCTAssertEqual(ShellQuote.quoteIfNeeded("a$b"), "'a$b'")
    }

    func testCapMarksTruncated() {
        let many = (0..<(ProjectFileTree.maxFiles + 5)).map { "f\($0)" }
        let big = ProjectFileTree(files: many)
        XCTAssertTrue(big.truncated)
        XCTAssertEqual(big.files.count, ProjectFileTree.maxFiles)
        XCTAssertFalse(tree.truncated)
    }

    func testScanSkipsHeavyAndHiddenDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["src/a.swift", "node_modules/x/index.js", ".git/HEAD", ".hidden/secret", ".env.example",
                     "notes.md", "tmp.swp", ".DS_Store"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let scanned = ProjectFileTree.scan(root: root.path)
        XCTAssertEqual(Set(scanned.files), ["src/a.swift", ".env.example", "notes.md"])
        XCTAssertFalse(scanned.truncated)
        XCTAssertTrue(ProjectFileTree.scan(root: root.path, limit: 2).truncated)
    }
}
