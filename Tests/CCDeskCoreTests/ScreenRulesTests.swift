import XCTest
@testable import CCDeskCore

final class MiniTOMLTests: XCTestCase {
    func testParsesTopLevelArraysOfTablesAndValues() throws {
        let doc = try MiniTOML.parse(#"""
        # comment
        id = "codex"   # trailing
        version = 3
        flag = true
        ratio = 1.5

        [[rules]]
        id = 'lit\no-escape'
        contains = ["a", "b",]
        any = [
          { contains = ["x"] },  # comment inside array
          { regex = ['\A> y'], not = [{ line_regex = ["^z$"] }] },
        ]

        [[rules]]
        id = "esc\té"
        multi = """
        line1
        line2"""
        """#)
        XCTAssertEqual(doc["id"], .string("codex"))
        XCTAssertEqual(doc["version"], .int(3))
        XCTAssertEqual(doc["flag"], .bool(true))
        XCTAssertEqual(doc["ratio"], .double(1.5))
        let rules = try XCTUnwrap(doc["rules"]?.arrayValue)
        XCTAssertEqual(rules.count, 2)
        let r0 = try XCTUnwrap(rules[0].tableValue)
        XCTAssertEqual(r0["id"], .string(#"lit\no-escape"#))
        XCTAssertEqual(r0["contains"], .array([.string("a"), .string("b")]))
        let any = try XCTUnwrap(r0["any"]?.arrayValue)
        XCTAssertEqual(any.count, 2)
        XCTAssertEqual(any[1].tableValue?["regex"], .array([.string(#"\A> y"#)]))
        XCTAssertEqual(any[1].tableValue?["not"]?.arrayValue?.first?.tableValue?["line_regex"], .array([.string("^z$")]))
        let r1 = try XCTUnwrap(rules[1].tableValue)
        XCTAssertEqual(r1["id"], .string("esc\té"))
        XCTAssertEqual(r1["multi"], .string("line1\nline2"))
    }

    func testRejectsUnsupportedSyntax() {
        XCTAssertThrowsError(try MiniTOML.parse("a.b = 1"))
        XCTAssertThrowsError(try MiniTOML.parse("[a.b]\nx = 1"))
        XCTAssertThrowsError(try MiniTOML.parse("x = \"unterminated"))
        XCTAssertThrowsError(try MiniTOML.parse("x = 1 2"))
        XCTAssertThrowsError(try MiniTOML.parse("x = 1\nx = 2"))
    }
}

final class ScreenRulesTests: XCTestCase {
    func manifest(_ rules: String) throws -> DetectionManifest {
        try DetectionManifest.parse("id = \"t\"\n" + rules)
    }

    func testNoMatchFallsBackToIdle() throws {
        let m = try manifest("""
        [[rules]]
        id = "w"
        state = "working"
        contains = ["Working"]
        """)
        XCTAssertEqual(ScreenDetector.detect(m, screen: "nothing here"), ScreenDetection(state: .idle, skipStateUpdate: false, ruleID: nil))
    }

    func testContainsIsCaseInsensitiveAndRequiresAll() throws {
        let m = try manifest("""
        [[rules]]
        id = "w"
        state = "working"
        contains = ["esc to", "INTERRUPT"]
        """)
        XCTAssertEqual(ScreenDetector.detect(m, screen: "• Working (1s • ESC to interrupt)").state, .working)
        XCTAssertEqual(ScreenDetector.detect(m, screen: "esc to cancel").state, .idle)
    }

    func testHighestPriorityWinsAndTiesKeepFirst() throws {
        let m = try manifest("""
        [[rules]]
        id = "low"
        state = "working"
        priority = 10
        contains = ["x"]

        [[rules]]
        id = "high"
        state = "blocked"
        priority = 20
        contains = ["x"]

        [[rules]]
        id = "tie"
        state = "idle"
        priority = 20
        contains = ["x"]
        """)
        let d = ScreenDetector.detect(m, screen: "x")
        XCTAssertEqual(d.state, .blocked)
        XCTAssertEqual(d.ruleID, "high")
    }

    func testAnyAllNotGates() throws {
        let m = try manifest("""
        [[rules]]
        id = "g"
        state = "blocked"
        all = [{ any = [{ contains = ["a"] }, { contains = ["b"] }] }]
        not = [{ contains = ["veto"] }]
        """)
        XCTAssertEqual(ScreenDetector.detect(m, screen: "has b").state, .blocked)
        XCTAssertEqual(ScreenDetector.detect(m, screen: "has a and veto").state, .idle)
        XCTAssertEqual(ScreenDetector.detect(m, screen: "neither").state, .idle)
    }

    func testRegexAndLineRegex() throws {
        let m = try manifest(#"""
        [[rules]]
        id = "r"
        state = "working"
        regex = ['(?m)^\d+s\z']
        line_regex = ['^── [⠋⠙] Working ─+$']
        """#)
        XCTAssertEqual(ScreenDetector.detect(m, screen: "── ⠋ Working ────\n12s").state, .working)
        XCTAssertEqual(ScreenDetector.detect(m, screen: "x ── ⠋ Working ────\n12s").state, .idle)
        XCTAssertEqual(ScreenDetector.detect(m, screen: "── ⠋ Working ────\n12s later").state, .idle)
    }

    func testRegionsBottomTopAndOscTitle() throws {
        let m = try manifest("""
        [[rules]]
        id = "bottom"
        state = "working"
        region = "bottom_non_empty_lines(2)"
        contains = ["old"]

        [[rules]]
        id = "top"
        state = "blocked"
        priority = 5
        region = "top_non_empty_lines(1)"
        contains = ["trust"]

        [[rules]]
        id = "title"
        state = "idle"
        priority = 1
        region = "osc_title"
        contains = ["ready"]
        """)
        XCTAssertEqual(ScreenDetector.detect(m, screen: "old\n\nnew1\n\nnew2\n").state, .idle)
        XCTAssertEqual(ScreenDetector.detect(m, screen: "old\nnew1\n\n").state, .working)
        XCTAssertEqual(ScreenDetector.detect(m, screen: "\ntrust me\nold\nx").state, .blocked)
        XCTAssertEqual(ScreenDetector.detect(m, screen: "x\ntrust", oscTitle: "ready").ruleID, "title")
    }

    func testPromptMarkerRegions() {
        let screen = "• did work\n› old prompt\n• more output\n› \n  footer"
        XCTAssertEqual(ScreenRegion.extract("after_last_prompt_marker", screen: screen, oscTitle: ""), "  footer")
        XCTAssertEqual(ScreenRegion.extract("before_current_prompt_marker", screen: screen, oscTitle: ""),
                       "• did work\n› old prompt\n• more output\n")
        XCTAssertEqual(ScreenRegion.extract("whole_recent_without_current_prompt_marker", screen: screen, oscTitle: ""), "")
        // 提示行之后又出现输出块：不再是「当前」提示。
        let stale = "› typed\n• response"
        XCTAssertNil(ScreenRegion.currentPromptIndex(ScreenRegion.lines(stale)))
        XCTAssertEqual(ScreenRegion.extract("whole_recent_without_current_prompt_marker", screen: stale, oscTitle: ""), stale)
        XCTAssertEqual(ScreenRegion.extract("before_current_prompt_marker", screen: stale, oscTitle: ""), stale)
        XCTAssertEqual(ScreenRegion.extract("bottom_lines(1)", screen: "a\nb\nc", oscTitle: ""), "c")
    }

    func testSkipStateUpdateIsReported() throws {
        let m = try manifest("""
        [[rules]]
        id = "viewer"
        state = "unknown"
        skip_state_update = true
        contains = ["q to quit"]
        """)
        let d = ScreenDetector.detect(m, screen: "q to quit")
        XCTAssertEqual(d.state, .unknown)
        XCTAssertTrue(d.skipStateUpdate)
    }

    func testUnsupportedRegionFieldOrRegexSkipsOnlyThatRule() throws {
        let m = try manifest("""
        [[rules]]
        id = "region"
        state = "working"
        region = "prompt_box_body"
        contains = ["x"]

        [[rules]]
        id = "field"
        state = "working"
        frobnicate = true
        contains = ["x"]

        [[rules]]
        id = "gatefield"
        state = "working"
        any = [{ wat = ["x"] }]

        [[rules]]
        id = "badregex"
        state = "working"
        regex = ["(unclosed"]

        [[rules]]
        id = "ok"
        state = "blocked"
        contains = ["x"]
        """)
        XCTAssertEqual(m.rules.map(\.id), ["ok"])
        XCTAssertEqual(Set(m.skipped.map(\.id)), ["region", "field", "gatefield", "badregex"])
        XCTAssertEqual(ScreenDetector.detect(m, screen: "x").ruleID, "ok")
    }

    /// 打包的清单必须能被引擎完整解析（只做 schema 校验，不对具体 agent 的屏幕写断言）。
    func testBundledManifestsParseWithoutSkippedRules() throws {
        let codex = try XCTUnwrap(BundledManifests.codex)
        XCTAssertEqual(codex.id, "codex")
        XCTAssertFalse(codex.rules.isEmpty)
        XCTAssertTrue(codex.skipped.isEmpty, "\(codex.skipped)")
        let pi = try XCTUnwrap(BundledManifests.pi)
        XCTAssertEqual(pi.id, "pi")
        XCTAssertFalse(pi.rules.isEmpty)
        XCTAssertTrue(pi.skipped.isEmpty, "\(pi.skipped)")
    }
}
