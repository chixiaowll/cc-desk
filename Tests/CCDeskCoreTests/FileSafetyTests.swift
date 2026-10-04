import XCTest
@testable import CCDeskCore

/// ⌘-点击路径里的宽字符、默认 App 打开可执行文件的规则。
final class WideCharacterPathTests: XCTestCase {
    /// 字符串 → 单元格：宽字符后面跟一个 "\0" 占位格（与终端的排布一致）。
    private func cells(_ text: String) -> [(character: Character, width: Int)] {
        var out: [(character: Character, width: Int)] = []
        for c in text {
            let wide = c.unicodeScalars.contains { $0.value >= 0x1100 && ($0.value <= 0x115F || $0.value >= 0x2E80) }
            out.append((c, wide ? 2 : 1))
            if wide { out.append(("\0", 0)) }
        }
        return out
    }

    func testSpacerCellsDoNotSplitCJKPaths() {
        let line = TerminalPaths.lineText(cells("见 文档/说明.md 了"))
        // 列：见(0) 占位(1) 空格(2) 文(3) 占位(4) 档(5) 占位(6) /(7) 说(8) 占位(9) 明(10) 占位(11) .(12) m d …
        XCTAssertEqual(TerminalPaths.token(in: line, column: 3), "文档/说明.md")
        XCTAssertEqual(TerminalPaths.token(in: line, column: 9), "文档/说明.md", "clicking the right half of a wide char")
        XCTAssertEqual(TerminalPaths.token(in: line, column: 13), "文档/说明.md")
    }

    func testCJKTextBeforeAPathDoesNotShiftColumns() {
        let line = TerminalPaths.lineText(cells("修改了 src/main.swift"))
        let column = 3 * 2 + 1 + 4  // 三个宽字符 + 空格，再往后 4 格
        XCTAssertEqual(TerminalPaths.token(in: line, column: column), "src/main.swift")
    }

    func testEmptyCellsStayDelimiters() {
        var raw = cells("a.txt")
        raw += [("\0", 1), ("\0", 1)]
        raw += cells("b.txt")
        let line = TerminalPaths.lineText(raw)
        XCTAssertEqual(TerminalPaths.token(in: line, column: 0), "a.txt")
        XCTAssertEqual(TerminalPaths.token(in: line, column: 8), "b.txt")
    }

    func testResolveFindsCJKFile() {
        let line = TerminalPaths.lineText(cells("打开 报告.md"))
        XCTAssertEqual(TerminalPaths.resolve(line: line, column: 6, cwd: "/p", exists: { $0 == "/p/报告.md" }), "/p/报告.md")
    }
}

final class FileOpenPolicyTests: XCTestCase {
    func testExecutableTypesAreRevealed() {
        for path in ["/x/Evil.app", "/x/run.command", "/x/a.tool", "/x/s.terminal", "/x/f.workflow", "/x/i.pkg"] {
            XCTAssertTrue(FileOpenPolicy.shouldReveal(path: path, isDirectory: path.hasSuffix(".app"), isExecutable: false),
                          path)
        }
        XCTAssertTrue(FileOpenPolicy.shouldReveal(path: "/x/build.sh", isDirectory: false, isExecutable: true))
        XCTAssertTrue(FileOpenPolicy.shouldReveal(path: "/x/tool.py", isDirectory: false, isExecutable: true))
        XCTAssertTrue(FileOpenPolicy.shouldReveal(path: "/x/a.out", isDirectory: false, isExecutable: true))
        XCTAssertTrue(FileOpenPolicy.shouldReveal(path: "/x/mybinary", isDirectory: false, isExecutable: true))
    }

    func testDocumentsOpen() {
        XCTAssertFalse(FileOpenPolicy.shouldReveal(path: "/x/build.sh", isDirectory: false, isExecutable: false))
        XCTAssertFalse(FileOpenPolicy.shouldReveal(path: "/x/README.md", isDirectory: false, isExecutable: true))
        XCTAssertFalse(FileOpenPolicy.shouldReveal(path: "/x/report.pdf", isDirectory: false, isExecutable: false))
        XCTAssertFalse(FileOpenPolicy.shouldReveal(path: "/x/folder", isDirectory: true, isExecutable: true))
    }
}
