import XCTest
@testable import CCDeskCore

final class CodexConfigEditTests: XCTestCase {
    let sample = """
    model = "x"
    # [features] in a comment
    [model_providers.custom]
    name = "c"
    hooks = false
    """ + "\n"

    func testAppendsFeaturesTableWhenMissingAndRestoresExactly() {
        let e = CodexConfigEdit.enableHooks(sample)
        XCTAssertTrue(e.changed)
        XCTAssertTrue(e.createdFeaturesTable)
        XCTAssertNil(e.previousHooksLine)
        XCTAssertTrue(e.content.hasPrefix(sample))
        XCTAssertTrue(e.content.hasSuffix("\n\n[features]\nhooks = true\n"))
        // 其他表里的同名键不受影响。
        XCTAssertTrue(e.content.contains("[model_providers.custom]\nname = \"c\"\nhooks = false\n"))
        let r = CodexConfigEdit.restoreHooks(e.content, previousHooksLine: nil, createdFeaturesTable: true)
        XCTAssertEqual(r, sample)
    }

    func testInsertsIntoExistingFeaturesTable() {
        let text = "[features]\nother = 1\n\n[x]\ny = 2\n"
        let e = CodexConfigEdit.enableHooks(text)
        XCTAssertEqual(e.content, "[features]\nhooks = true\nother = 1\n\n[x]\ny = 2\n")
        XCTAssertFalse(e.createdFeaturesTable)
        XCTAssertEqual(CodexConfigEdit.restoreHooks(e.content, previousHooksLine: nil, createdFeaturesTable: false), text)
    }

    func testFlipsFalseAndRestoresPreviousLine() {
        let text = "[features]\nhooks = false # off\n"
        let e = CodexConfigEdit.enableHooks(text)
        XCTAssertEqual(e.content, "[features]\nhooks = true\n")
        XCTAssertEqual(e.previousHooksLine, "hooks = false # off")
        XCTAssertEqual(CodexConfigEdit.restoreHooks(e.content, previousHooksLine: e.previousHooksLine, createdFeaturesTable: false), text)
    }

    func testAlreadyEnabledIsUnchanged() {
        let text = "[features]\nhooks = true\n"
        let e = CodexConfigEdit.enableHooks(text)
        XCTAssertFalse(e.changed)
        XCTAssertEqual(e.content, text)
    }

    func testRestoreLeavesUserChangedValueAlone() {
        let text = "[features]\nhooks = false\n"
        XCTAssertEqual(CodexConfigEdit.restoreHooks(text, previousHooksLine: nil, createdFeaturesTable: true), text)
    }

    func testRestoreKeepsTableWhenUserAddedKeys() {
        let text = "a = 1\n\n[features]\nhooks = true\nmine = 2\n"
        XCTAssertEqual(CodexConfigEdit.restoreHooks(text, previousHooksLine: nil, createdFeaturesTable: true),
                       "a = 1\n\n[features]\nmine = 2\n")
    }

    func testEmptyConfig() {
        let e = CodexConfigEdit.enableHooks("")
        XCTAssertEqual(e.content, "[features]\nhooks = true\n")
        XCTAssertEqual(CodexConfigEdit.restoreHooks(e.content, previousHooksLine: nil, createdFeaturesTable: true), "")
    }
}

final class IntegrationsTests: XCTestCase {
    private var home: URL!

    override func setUp() {
        super.setUp()
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    func write(_ text: String, _ rel: String) throws {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ rel: String) -> String? { try? String(contentsOf: home.appendingPathComponent(rel), encoding: .utf8) }

    func json(_ rel: String) -> [String: Any]? {
        guard let d = try? Data(contentsOf: home.appendingPathComponent(rel)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    let foreignHooks = #"""
    {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash /x/herdr-agent-state.sh idle","timeout":10}]}]},"other":1}
    """#
    let config = "model = \"m\"\n[model_providers.custom]\nname = \"c\"\n"

    func testCodexMissingDirectory() {
        let c = CodexIntegration(home: home)
        XCTAssertEqual(c.status(), .agentMissing)
        XCTAssertThrowsError(try c.install())
    }

    func testCodexInstallIsIdempotentAndUninstallLeavesForeignEntries() throws {
        try write(foreignHooks, ".codex/hooks.json")
        try write(config, ".codex/config.toml")
        let c = CodexIntegration(home: home)
        XCTAssertEqual(c.status(), .notInstalled)

        try c.install()
        XCTAssertEqual(c.status(), .installed)
        try c.install()
        XCTAssertEqual(c.status(), .installed)

        let hooks = try XCTUnwrap(json(".codex/hooks.json")?["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2, "foreign + one CC Desk entry, no duplicates")
        XCTAssertEqual((hooks["UserPromptSubmit"] as? [Any])?.count, 1)
        XCTAssertEqual(json(".codex/hooks.json")?["other"] as? Int, 1)
        XCTAssertEqual(read(".codex/config.toml"), config + "\n[features]\nhooks = true\n")
        XCTAssertEqual(read(".codex/config.toml.cc-desk.bak"), config)
        XCTAssertNotNil(read(".codex/hooks.json.cc-desk.bak"))
        XCTAssertEqual(read(".cc-desk/hooks/codex-state.sh"), IntegrationAssets.codexHookScript)
        let perms = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".cc-desk/hooks/codex-state.sh").path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o755)

        try c.uninstall()
        XCTAssertEqual(c.status(), .notInstalled)
        let after = try XCTUnwrap(json(".codex/hooks.json"))
        let afterHooks = try XCTUnwrap(after["hooks"] as? [String: Any])
        XCTAssertEqual(Set(afterHooks.keys), ["Stop"])
        XCTAssertEqual(((afterHooks["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String,
                       "bash /x/herdr-agent-state.sh idle")
        XCTAssertEqual(after["other"] as? Int, 1)
        XCTAssertEqual(read(".codex/config.toml"), config)
        XCTAssertNil(read(".cc-desk/hooks/codex-state.sh"))
    }

    func testCodexUninstallRemovesHooksFileItCreated() throws {
        try write(config, ".codex/config.toml")
        let c = CodexIntegration(home: home)
        try c.install()
        XCTAssertNotNil(read(".codex/hooks.json"))
        try c.uninstall()
        XCTAssertNil(read(".codex/hooks.json"))
        XCTAssertEqual(read(".codex/config.toml"), config)
    }

    func testCodexKeepsConfigWhenAlreadyEnabled() throws {
        let enabled = "[features]\nhooks = true\n"
        try write(enabled, ".codex/config.toml")
        let c = CodexIntegration(home: home)
        try c.install()
        XCTAssertNil(read(".codex/config.toml.cc-desk.bak"))
        try c.uninstall()
        XCTAssertEqual(read(".codex/config.toml"), enabled)
    }

    func testCodexRefusesMalformedHooksFile() throws {
        try write("[1,2]", ".codex/hooks.json")
        try write(config, ".codex/config.toml")
        XCTAssertThrowsError(try CodexIntegration(home: home).install())
        XCTAssertEqual(read(".codex/hooks.json"), "[1,2]")
        XCTAssertEqual(read(".codex/config.toml"), config)
    }

    func testCodexNeedsRepairWhenScriptMissing() throws {
        try write(config, ".codex/config.toml")
        let c = CodexIntegration(home: home)
        try c.install()
        try FileManager.default.removeItem(at: c.scriptFile)
        if case .needsRepair = c.status() {} else { XCTFail("expected needsRepair, got \(c.status())") }
    }

    func testPiInstallUninstall() throws {
        let p = PiIntegration(home: home)
        XCTAssertEqual(p.status(), .agentMissing)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".pi/agent"), withIntermediateDirectories: true)
        try write("// someone else's\n", ".pi/agent/extensions/other.ts")
        XCTAssertEqual(p.status(), .notInstalled)
        try p.install()
        try p.install()
        XCTAssertEqual(p.status(), .installed)
        XCTAssertEqual(read(".pi/agent/extensions/cc-desk-state.ts"), IntegrationAssets.piExtension)
        try p.uninstall()
        XCTAssertEqual(p.status(), .notInstalled)
        XCTAssertEqual(read(".pi/agent/extensions/other.ts"), "// someone else's\n")
    }

    func testPiRefusesForeignFileWithSameName() throws {
        try write("// mine\n", ".pi/agent/extensions/cc-desk-state.ts")
        let p = PiIntegration(home: home)
        XCTAssertThrowsError(try p.install())
        XCTAssertThrowsError(try p.uninstall())
        XCTAssertEqual(read(".pi/agent/extensions/cc-desk-state.ts"), "// mine\n")
    }

    func testCodexHookScriptIsValidShell() throws {
        let url = home.appendingPathComponent("hook.sh")
        try IntegrationAssets.codexHookScript.write(to: url, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-n", url.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }

    func testCodexHookScriptExitsZeroWithoutTTYOrBadInput() throws {
        let url = home.appendingPathComponent("hook.sh")
        try IntegrationAssets.codexHookScript.write(to: url, atomically: true, encoding: .utf8)
        for action in ["working", "bogus", ""] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [url.path, action]
            p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            let input = Pipe()
            p.standardInput = input
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            try p.run()
            input.fileHandleForWriting.write(Data("{not json".utf8))
            try input.fileHandleForWriting.close()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
            XCTAssertEqual(out.fileHandleForReading.readDataToEndOfFile(), Data(), "hook must be silent")
        }
    }
}
