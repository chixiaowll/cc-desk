import XCTest
@testable import CCDeskCore

final class AgentProfilesTests: XCTestCase {
    func testParsesClaudeCodeSubagentFrontmatter() throws {
        let text = """
        ---
        name: reviewer
        title: 审查员
        description: "Reviews code: finds bugs"
        model: opus
        tools: Read, Grep, Glob, Bash(git log:*), Bash(git diff:*)
        ---

        You are a reviewer.
        Be terse.
        """
        let p = try AgentProfileParser.parse(text, fileName: "reviewer.md").get()
        XCTAssertEqual(p.name, "reviewer")
        XCTAssertEqual(p.title, "审查员")
        XCTAssertEqual(p.description, "Reviews code: finds bugs")
        XCTAssertEqual(p.model, "opus")
        XCTAssertEqual(p.tools, ["Read", "Grep", "Glob", "Bash(git log:*)", "Bash(git diff:*)"])
        XCTAssertEqual(p.prompt, "You are a reviewer.\nBe terse.")
        XCTAssertTrue(p.isReadOnly)
    }

    func testParsesYamlListsAndDefaults() throws {
        let text = "---\nname: helper\ntools:\n  - Read\n  - Bash\nmodel: inherit\n---\nHelp.\n"
        let p = try AgentProfileParser.parse(text, fileName: "helper.md").get()
        XCTAssertEqual(p.tools, ["Read", "Bash"])
        XCTAssertNil(p.model)
        XCTAssertEqual(p.title, "helper")
        XCTAssertFalse(p.isReadOnly, "plain Bash can run anything")

        let inline = try AgentProfileParser.parse("---\nname: x\ntools: [Read, 'Grep']\n---\nX", fileName: "x.md").get()
        XCTAssertEqual(inline.tools, ["Read", "Grep"])
        XCTAssertTrue(inline.isReadOnly)
    }

    func testNoToolsIsNotReadOnly() throws {
        let p = try AgentProfileParser.parse("---\nname: all\n---\nAnything.", fileName: "all.md").get()
        XCTAssertEqual(p.tools, [])
        XCTAssertFalse(p.isReadOnly, "no tools line = inherits every tool")
    }

    func testRejectsInvalidProfiles() {
        XCTAssertEqual(AgentProfileParser.parse("name: x\nbody", fileName: "a.md"), .failure(.noFrontmatter))
        XCTAssertEqual(AgentProfileParser.parse("---\ndescription: d\n---\nbody", fileName: "a.md"), .failure(.missingName))
        XCTAssertEqual(AgentProfileParser.parse("---\nname: Bad Name\n---\nbody", fileName: "a.md"),
                       .failure(.invalidName("Bad Name")))
        XCTAssertEqual(AgentProfileParser.parse("---\nname: ok\n---\n  \n", fileName: "a.md"), .failure(.emptyPrompt))
        XCTAssertEqual(AgentProfileParser.parse("---\nname: x;rm\n---\nb", fileName: "a.md"), .failure(.invalidName("x;rm")))
    }

    func testAgentsJSONForClaudeFlag() throws {
        let p = AgentProfile(name: "tester", title: "测试员", description: "Runs tests", model: "sonnet",
                             tools: ["Read", "Bash"], prompt: "Run \"tests\".", fileName: "tester.md")
        let json = try XCTUnwrap(JSONValue.parse(p.agentsJSON))
        XCTAssertEqual(json["tester"]?["description"], "Runs tests")
        XCTAssertEqual(json["tester"]?["prompt"], "Run \"tests\".")
        XCTAssertEqual(json["tester"]?["model"], "sonnet")
        XCTAssertEqual(json["tester"]?["tools"]?.arrayValue?.count, 2)
    }

    func testBuiltInDefaultsParse() throws {
        for (file, contents) in AgentProfileDefaults.all {
            let p = try AgentProfileParser.parse(contents, fileName: file).get()
            XCTAssertEqual(p.fileName, file)
        }
        let reviewer = try AgentProfileParser.parse(AgentProfileDefaults.reviewer, fileName: "reviewer.md").get()
        XCTAssertEqual(reviewer.model, "opus")
        XCTAssertTrue(reviewer.isReadOnly)
        XCTAssertEqual(reviewer.title, "审查员")
        let tester = try AgentProfileParser.parse(AgentProfileDefaults.tester, fileName: "tester.md").get()
        XCTAssertEqual(tester.model, "sonnet")
        XCTAssertFalse(tester.isReadOnly)
        XCTAssertFalse(tester.tools.contains("Edit"))
    }

    // MARK: 安装内置配置

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testInstallsDefaultsOnlyWhenAbsentAndNeverOverwrites() throws {
        let dir = try tempDir()
        let store = AgentProfileStore(directory: dir)
        let defaults = [(fileName: "a.md", contents: "---\nname: a\n---\nA"), (fileName: "b.md", contents: "---\nname: b\n---\nB")]
        XCTAssertEqual(store.installDefaults(defaults), ["a.md", "b.md"])

        // 用户改了 a.md：再次安装不覆盖。
        let edited = "---\nname: a\nmodel: opus\n---\nMine"
        try edited.write(to: dir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(store.installDefaults(defaults), [])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a.md"), encoding: .utf8), edited)

        // 用户删了 b.md：不再装回。
        try FileManager.default.removeItem(at: dir.appendingPathComponent("b.md"))
        XCTAssertEqual(store.installDefaults(defaults), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.md").path))

        // 新增的内置配置照常安装。
        let more = defaults + [(fileName: "c.md", contents: "---\nname: c\n---\nC")]
        XCTAssertEqual(store.installDefaults(more), ["c.md"])
    }

    func testPreexistingUserFileCountsAsInstalled() throws {
        let dir = try tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: reviewer\n---\nCustom".write(to: dir.appendingPathComponent("reviewer.md"), atomically: true,
                                                    encoding: .utf8)
        let store = AgentProfileStore(directory: dir)
        XCTAssertEqual(store.installDefaults(), ["tester.md"])
        let loaded = store.load()
        XCTAssertEqual(loaded.profiles.map(\.name), ["reviewer", "tester"])
        XCTAssertEqual(loaded.profiles.first?.prompt, "Custom")
    }

    func testLoadSkipsInvalidAndDuplicateNames() throws {
        let dir = try tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: x\n---\nfirst".write(to: dir.appendingPathComponent("1.md"), atomically: true, encoding: .utf8)
        try "---\nname: x\n---\nsecond".write(to: dir.appendingPathComponent("2.md"), atomically: true, encoding: .utf8)
        try "no frontmatter".write(to: dir.appendingPathComponent("3.md"), atomically: true, encoding: .utf8)
        try "ignored".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let loaded = AgentProfileStore(directory: dir).load()
        XCTAssertEqual(loaded.profiles.map(\.prompt), ["first"])
        XCTAssertEqual(loaded.invalid.map(\.0), ["3.md"])
    }

    func testFindByNameTitleOrFile() {
        let profiles = [AgentProfile(name: "reviewer", title: "审查员", description: "", model: nil, tools: [], prompt: "p",
                                     fileName: "reviewer.md"),
                        AgentProfile(name: "tester", title: "测试员", description: "", model: nil, tools: [], prompt: "p",
                                     fileName: "tester.md")]
        XCTAssertEqual(AgentProfileStore.find("Reviewer", in: profiles)?.name, "reviewer")
        XCTAssertEqual(AgentProfileStore.find("测试员", in: profiles)?.name, "tester")
        XCTAssertEqual(AgentProfileStore.find("让测试员", in: profiles)?.name, "tester")
        XCTAssertNil(AgentProfileStore.find("planner", in: profiles))
    }
}
