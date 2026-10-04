import XCTest
@testable import CCDeskCore

/// 技能库：frontmatter 的各种写法与扫描（临时目录里的假 home）。
final class SkillFrontmatterTests: XCTestCase {
    func testPlainQuotedAndBlockScalars() {
        let text = """
        ---
        name: "imagegen"
        description: 'It''s for images'
        license: Complete terms
        metadata:
          short-description: nested, ignored
        ---
        # Title
        Body
        """
        let fm = SkillFrontmatter.parse(text)
        XCTAssertEqual(fm.fields["name"], "imagegen")
        XCTAssertEqual(fm.fields["description"], "It's for images")
        XCTAssertNil(fm.fields["short-description"])
        XCTAssertNil(fm.fields["metadata"])
        XCTAssertEqual(fm.body, "# Title\nBody")
    }

    func testLiteralAndFoldedBlocks() {
        let literal = SkillFrontmatter.parse("---\nname: a\ndescription: |\n  line one\n  line two\nmodel: inherit\n---\n")
        XCTAssertEqual(literal.fields["description"], "line one\nline two")
        XCTAssertEqual(literal.fields["model"], "inherit")
        let folded = SkillFrontmatter.parse("---\ndescription: >-\n  folded\n  text\n\n  next\n---\nx")
        XCTAssertEqual(folded.fields["description"], "folded text\nnext")
    }

    func testMultilinePlainScalarAndEscapes() {
        let fm = SkillFrontmatter.parse("---\nname: x\ndescription: starts here\n  and continues\n---\n")
        XCTAssertEqual(fm.fields["description"], "starts here and continues")
        let empty = SkillFrontmatter.parse("---\ndescription:\n  on the next line\n---\n")
        XCTAssertEqual(empty.fields["description"], "on the next line")
        let escaped = SkillFrontmatter.parse("---\ndescription: \"say \\\"hi\\\"\"\n---\n")
        XCTAssertEqual(escaped.fields["description"], "say \"hi\"")
        let list = SkillFrontmatter.parse("---\ntools:\n  - Read\n  - Grep\n---\n")
        XCTAssertNil(list.fields["tools"])
    }

    func testNoFrontmatterAndFirstParagraph() {
        let fm = SkillFrontmatter.parse("# Heading\n\n```\ncode\n```\n<!-- note -->\nFirst line\nsecond line\n\nLater")
        XCTAssertTrue(fm.fields.isEmpty)
        XCTAssertEqual(SkillFrontmatter.firstParagraph(fm.body), "First line second line")
        XCTAssertEqual(SkillFrontmatter.parse("\u{FEFF}---\nname: bom\n---\n").fields["name"], "bom")
        XCTAssertTrue(SkillFrontmatter.parse("---\nname: unterminated\n").fields.isEmpty)
    }
}

final class SkillScannerTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ relative: String, _ text: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func skill(_ name: String, _ description: String) -> String {
        "---\nname: \(name)\ndescription: \(description)\n---\n# \(name)\n"
    }

    private func scan(projects: [String] = []) -> [SkillEntry] {
        SkillScanner.scan(.standard(home: home, projectRoots: projects))
    }

    func testMissingDirectoriesGiveNothing() {
        XCTAssertEqual(scan(projects: ["/nonexistent/project"]), [])
    }

    func testUserSkillsSkipFoldersWithoutSkillFileAndFallBackToFolderName() throws {
        try write(".claude/skills/alpha/SKILL.md", skill("alpha", "First"))
        try write(".claude/skills/noname/SKILL.md", "# Title\n\nDoes a thing.\n")
        try write(".claude/skills/notes/README.md", "not a skill")
        try write(".claude/skills/.git/HEAD", "ref")
        try write(".claude/skills/synced/bucket/docx/SKILL.md", skill("docx", "Word"))
        let entries = scan()
        XCTAssertEqual(entries.map(\.name), ["alpha", "noname", "docx"])
        XCTAssertEqual(entries[1].description, "Does a thing.")
        XCTAssertEqual(entries[0].source, .claudeUser)
        XCTAssertEqual(entries[2].source, .claudeSynced)
        XCTAssertEqual(entries[0].folderPath, home.appendingPathComponent(".claude/skills/alpha").path)
        XCTAssertEqual(entries[0].agents, [.claude])
    }

    func testPluginsUseInstalledPathAndEnabledFlag() throws {
        let on = ".claude/plugins/cache/mkt/good/1.0.0"
        let off = ".claude/plugins/cache/mkt/quiet/2.0"
        try write("\(on)/skills/brainstorming/SKILL.md", skill("brainstorming", "Ideas"))
        try write("\(on)/commands/brainstorm.md", "---\ndescription: \"Deprecated\"\n---\nbody")
        try write("\(on)/agents/code-reviewer.md", "---\nname: code-reviewer\ndescription: |\n  Reviews\n---\n")
        try write("\(off)/skills/hidden/SKILL.md", skill("hidden", "Disabled one"))
        // 市场克隆与旧版本缓存不算（只认 installed_plugins.json 里的安装位置）。
        try write(".claude/plugins/cache/mkt/good/0.9.0/skills/brainstorming/SKILL.md", skill("brainstorming", "Old"))
        try write(".claude/plugins/marketplaces/mkt/plugins/good/skills/brainstorming/SKILL.md", skill("brainstorming", "M"))
        let installed = """
        {"version": 2, "plugins": {
          "good@mkt": [{"scope": "user", "installPath": "\(home.appendingPathComponent(on).path)", "version": "1.0.0"}],
          "quiet@mkt": [{"scope": "user", "installPath": "\(home.appendingPathComponent(off).path)", "version": "2.0"}],
          "gone@mkt": [{"scope": "user", "installPath": "/nonexistent", "version": "1"}]
        }}
        """
        try write(".claude/plugins/installed_plugins.json", installed)
        try write(".claude/settings.json", #"{"enabledPlugins": {"good@mkt": true, "quiet@mkt": false}}"#)
        let entries = scan()
        XCTAssertEqual(entries.map(\.name), ["brainstorming", "brainstorm", "code-reviewer", "hidden"])
        XCTAssertEqual(entries.map(\.kind), [.skill, .command, .agent, .skill])
        XCTAssertEqual(entries[0].description, "Ideas")
        XCTAssertEqual(entries[2].description, "Reviews")
        XCTAssertEqual(entries[0].source, .claudePlugin(plugin: "good", marketplace: "mkt", version: "1.0.0", enabled: true))
        XCTAssertFalse(entries[0].isDisabled)
        XCTAssertTrue(entries[3].isDisabled)
        XCTAssertTrue(entries[0].applies(to: .claude, cwd: "/x", projectRoot: nil))
        XCTAssertFalse(entries[3].applies(to: .claude, cwd: "/x", projectRoot: nil))
    }

    func testPluginsMissingFromSettingsAreDisabledAndBrokenJSONIsIgnored() throws {
        let root = ".claude/plugins/cache/mkt/p/unknown"
        try write("\(root)/skills/s/SKILL.md", skill("s", "x"))
        try write(".claude/plugins/installed_plugins.json",
                  #"{"plugins": {"p@mkt": {"installPath": "\#(home.appendingPathComponent(root).path)", "version": "unknown"}}}"#)
        try write(".claude/settings.json", "{ not json")
        let entries = scan()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].source, .claudePlugin(plugin: "p", marketplace: "mkt", version: nil, enabled: false))
    }

    func testSymlinkedSkillIsMergedAcrossSources() throws {
        try write(".agents/skills/market-data/SKILL.md", skill("market-data", "Markets"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/skills"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent(".claude/skills/market-data").path,
                                                   withDestinationPath: "../../.agents/skills/market-data")
        // 断开的链接与指向自己的链接都不出错。
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent(".claude/skills/broken").path,
                                                   withDestinationPath: "/nonexistent/skill")
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent(".claude/skills/loop").path,
                                                   withDestinationPath: "loop")
        let entries = scan()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].sources, [.claudeUser, .agentsShared])
        XCTAssertEqual(entries[0].agents, [.claude, .codex, .pi])
        XCTAssertEqual(entries[0].filePath, home.appendingPathComponent(".claude/skills/market-data/SKILL.md").path)
        XCTAssertEqual(SkillScanner.folderFiles(entries[0].folderPath ?? "").files, ["SKILL.md"])
    }

    func testProjectCodexPiAndCCDeskSources() throws {
        let project = home.appendingPathComponent("work/app").path
        try write("work/app/.claude/skills/deploy/SKILL.md", skill("deploy", "Ship it"))
        try write("work/app/.agents/skills/lint/SKILL.md", skill("lint", "Lint"))
        try write("work/other/.claude/skills/elsewhere/SKILL.md", skill("elsewhere", "Not scanned"))
        try write(".codex/skills/.system/imagegen/SKILL.md", skill("\"imagegen\"", "\"Images\""))
        try write(".codex/skills/mine/SKILL.md", skill("mine", "Codex own"))
        try write(".pi/agent/skills/single.md", skill("single", "Root md"))
        try write(".pi/agent/skills/folder/SKILL.md", skill("folder", "Pi folder"))
        try write(".cc-desk/agents/reviewer.md",
                  "---\nname: reviewer\ntitle: 审查员\ndescription: Reviews code\ntools: Read, Grep\n---\nPrompt")
        try write(".cc-desk/agents/broken.md", "no frontmatter at all")
        try write(".cc-desk/agents/.launch/reviewer.json", "{}")
        let entries = scan(projects: [project, project])
        XCTAssertEqual(entries.map(\.name),
                       ["deploy", "lint", "imagegen", "mine", "folder", "single", "broken", "reviewer"])
        XCTAssertEqual(entries[2].description, "Images")
        let reviewer = try XCTUnwrap(entries.last)
        XCTAssertEqual(reviewer.kind, .ccdeskAgent)
        XCTAssertEqual(reviewer.title, "审查员")
        XCTAssertEqual(reviewer.displayName, "审查员")
        XCTAssertEqual(entries[6].description, "no frontmatter at all")

        let claude = SkillCatalog.effective(entries, for: .claude, cwd: project + "/src", projectRoot: project)
        XCTAssertEqual(claude.map(\.name), ["deploy"], "CC Desk 专业 agent 不算会话里的技能")
        XCTAssertEqual(SkillCatalog.effective(entries, for: .claude, cwd: "/tmp", projectRoot: "/tmp"), [])
        let codex = SkillCatalog.effective(entries, for: .codex, cwd: project, projectRoot: project)
        XCTAssertEqual(codex.map(\.name), ["lint", "imagegen", "mine"])
        let pi = SkillCatalog.effective(entries, for: .pi, cwd: "/elsewhere", projectRoot: nil)
        XCTAssertEqual(pi.map(\.name), ["folder", "single"])
        XCTAssertEqual(SkillCatalog.effective(entries, for: .other, cwd: project, projectRoot: project), [])
    }

    func testFilterSortAndJSON() throws {
        try write(".claude/skills/Zeta/SKILL.md", skill("Zeta", "Draws charts"))
        try write(".claude/skills/alpha/SKILL.md", skill("alpha", "Writes docs"))
        try write(".codex/skills/beta/SKILL.md", skill("beta", "Charts for codex"))
        let entries = scan()
        XCTAssertEqual(entries.map(\.name), ["alpha", "Zeta", "beta"])
        XCTAssertEqual(SkillCatalog.filter(entries, query: "chart", agent: nil).map(\.name), ["Zeta", "beta"])
        XCTAssertEqual(SkillCatalog.filter(entries, query: "CHART", agent: .codex).map(\.name), ["beta"])
        XCTAssertEqual(SkillCatalog.filter(entries, query: "  ", agent: .claude).map(\.name), ["alpha", "Zeta"])
        XCTAssertEqual(SkillCatalog.filter(entries, query: "codex charts", agent: nil).map(\.name), ["beta"])
        XCTAssertEqual(SkillCatalog.filter(entries, query: "zeta docs", agent: nil), [])
        let json = entries[0].json(home: home.path)
        XCTAssertEqual(json["path"], "~/.claude/skills/alpha/SKILL.md")
        XCTAssertEqual(json["source"], "claude-user")
        XCTAssertEqual(json["enabled"], .bool(true))
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
    }

    func testTildePathAndProjectContainment() {
        XCTAssertEqual(SkillCatalog.tildePath("/Users/a/x", home: "/Users/a"), "~/x")
        XCTAssertEqual(SkillCatalog.tildePath("/Users/ab/x", home: "/Users/a"), "/Users/ab/x")
        XCTAssertTrue(SkillEntry.path("/p/app/src", isInside: "/p/app"))
        XCTAssertFalse(SkillEntry.path("/p/apple", isInside: "/p/app"))
    }
}
