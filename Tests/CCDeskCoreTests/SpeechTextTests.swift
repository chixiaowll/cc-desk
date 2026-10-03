import XCTest
@testable import CCDeskCore

final class SpeechTextTests: XCTestCase {
    private func n(_ s: String, _ language: String = "zh-Hans") -> String { SpeechText.normalize(s, language: language) }

    func testHyphenatedIdentifierAndShortWordsAreSpelled() {
        XCTAssertEqual(n("cc-desk 想执行 rm -rf build，需要你批准。"), "C C desk 想执行 R M 杠 R F build，需要你批准。")
        XCTAssertEqual(n("cc-desk想执行"), "C C desk想执行")
        XCTAssertEqual(n("foo_bar_baz"), "foo bar baz")
        XCTAssertEqual(n("npm install"), "N P M install")
    }

    func testLongFlagsAndEnglishDash() {
        XCTAssertEqual(n("git push --force"), "git push 杠杠 force")
        XCTAssertEqual(n("rm -rf build", "en"), "R M dash R F build")
        XCTAssertEqual(n("ls --dry-run"), "L S 杠杠 dry run")
    }

    func testPathsShortenToFileName() {
        XCTAssertEqual(n("改了 Sources/CCDesk/ConversationMode.swift 和 ~/Documents/notes"),
                       "改了 ConversationMode 点 swift 和 notes")
        XCTAssertEqual(n("看看 /usr/local/bin/claude"), "看看 claude")
        XCTAssertEqual(n("main.py", "en"), "main dot py")
    }

    func testMarkdownAndCodeAreStripped() {
        XCTAssertEqual(n("**完成了**，运行 `swift test` 即可。"), "完成了，运行 swift test 即可。")
        XCTAssertEqual(n("结果如下：\n```swift\nlet x = 1\n```\n都通过了"), "结果如下： 都通过了")
        XCTAssertEqual(n("# 标题\n- 第一项\n- 第二项"), "标题 第一项 第二项")
        XCTAssertEqual(n("见 [文档](https://example.com/a/b)"), "见 文档")
        XCTAssertEqual(n("打开 https://github.com/foo/bar 看看"), "打开 github 点 com 看看")
    }

    func testNumbersStayReadable() {
        XCTAssertEqual(n("测试 375 个，跳过 3 个"), "测试 375 个，跳过 3 个")
        XCTAssertEqual(n("版本 1.2.3，日期 2026-10-03，第 3-5 行"), "版本 1.2.3，日期 2026-10-03，第 3-5 行")
        XCTAssertEqual(n("温度 -5 度"), "温度 -5 度")
        XCTAssertEqual(n("用了 1.5 秒。"), "用了 1.5 秒。")
    }

    func testPlainWordsUnchanged() {
        XCTAssertEqual(n("poems 那个会话已经完成了"), "poems 那个会话已经完成了")
        XCTAssertEqual(n("Claude Code is ready."), "Claude Code is ready.")
        XCTAssertEqual(n("OK"), "OK")
    }

    func testSentencesSplitOnTerminators() {
        XCTAssertEqual(SpeechText.sentences("poems 完成了。要我帮你看看吗？好"),
                       ["poems 完成了。", "要我帮你看看吗？好"])
        XCTAssertEqual(SpeechText.sentences("It works. Tests pass! OK?"), ["It works.", "Tests pass! OK?"])
        XCTAssertEqual(SpeechText.sentences("版本 1.5 已发布。main.py 改了。"), ["版本 1.5 已发布。", "main.py 改了。"])
    }

    func testSentencesMergeTinyPiecesAndKeepRunsOfPunctuation() {
        XCTAssertEqual(SpeechText.sentences("好。我马上去做。"), ["好。我马上去做。"])
        XCTAssertEqual(SpeechText.sentences("你说的是真的吗？！太好了，谢谢。"), ["你说的是真的吗？！", "太好了，谢谢。"])
        XCTAssertEqual(SpeechText.sentences("第一行\n第二行内容"), ["第一行第二行内容"])
        XCTAssertEqual(SpeechText.sentences(""), [])
        XCTAssertEqual(SpeechText.sentences("嗯"), ["嗯"])
    }

    func testLongSentenceSplitsAtCommas() {
        let long = String(repeating: "这是一段比较长的话，", count: 12) + "结束。"
        let pieces = SpeechText.sentences(long, maxLength: 40)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 40 })
        XCTAssertEqual(pieces.joined(), long)
    }
}
