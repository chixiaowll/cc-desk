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

    func testAppendsFeaturesTableWhenMissingAndRestoresExactly() throws {
        let e = try CodexConfigEdit.enableHooks(sample)
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

    func testInsertsIntoExistingFeaturesTable() throws {
        let text = "[features]\nother = 1\n\n[x]\ny = 2\n"
        let e = try CodexConfigEdit.enableHooks(text)
        XCTAssertEqual(e.content, "[features]\nhooks = true\nother = 1\n\n[x]\ny = 2\n")
        XCTAssertFalse(e.createdFeaturesTable)
        XCTAssertEqual(CodexConfigEdit.restoreHooks(e.content, previousHooksLine: nil, createdFeaturesTable: false), text)
    }

    func testFlipsFalseAndRestoresPreviousLine() throws {
        let text = "[features]\nhooks = false # off\n"
        let e = try CodexConfigEdit.enableHooks(text)
        XCTAssertEqual(e.content, "[features]\nhooks = true\n")
        XCTAssertEqual(e.previousHooksLine, "hooks = false # off")
        XCTAssertEqual(CodexConfigEdit.restoreHooks(e.content, previousHooksLine: e.previousHooksLine, createdFeaturesTable: false), text)
    }

    func testAlreadyEnabledIsUnchanged() throws {
        let text = "[features]\nhooks = true\n"
        let e = try CodexConfigEdit.enableHooks(text)
        XCTAssertFalse(e.changed)
        XCTAssertEqual(e.content, text)
    }

    func testRestoreLeavesUserChangedValueAlone() throws {
        let text = "[features]\nhooks = false\n"
        XCTAssertEqual(CodexConfigEdit.restoreHooks(text, previousHooksLine: nil, createdFeaturesTable: true), text)
    }

    func testRestoreKeepsTableWhenUserAddedKeys() throws {
        let text = "a = 1\n\n[features]\nhooks = true\nmine = 2\n"
        XCTAssertEqual(CodexConfigEdit.restoreHooks(text, previousHooksLine: nil, createdFeaturesTable: true),
                       "a = 1\n\n[features]\nmine = 2\n")
    }

    func testEmptyConfig() throws {
        let e = try CodexConfigEdit.enableHooks("")
        XCTAssertEqual(e.content, "[features]\nhooks = true\n")
        XCTAssertEqual(CodexConfigEdit.restoreHooks(e.content, previousHooksLine: nil, createdFeaturesTable: true), "")
    }

    // MARK: 点号键 / 行内表

    func testDottedFeaturesKeysGetADottedHooksKey() throws {
        let text = "model = \"x\"\nfeatures.web_search = true\n\n[profiles.a]\nfeatures = 1\n"
        let e = try CodexConfigEdit.enableHooks(text)
        XCTAssertEqual(e.content, "model = \"x\"\nfeatures.web_search = true\nfeatures.hooks = true\n\n[profiles.a]\nfeatures = 1\n")
        XCTAssertFalse(e.content.contains("[features]"), "a [features] header after dotted keys redefines the table")
        XCTAssertFalse(e.createdFeaturesTable)
        XCTAssertFalse(try CodexConfigEdit.enableHooks(e.content).changed, "idempotent")
        XCTAssertEqual(CodexConfigEdit.restoreHooks(e.content, previousHooksLine: nil, createdFeaturesTable: false), text)
    }

    func testDottedHooksFalseIsFlippedInPlace() throws {
        let text = "\"features\" . hooks = false\n[x]\ny = 1\n"
        let e = try CodexConfigEdit.enableHooks(text)
        XCTAssertEqual(e.content, "features.hooks = true\n[x]\ny = 1\n")
        XCTAssertEqual(e.previousHooksLine, "\"features\" . hooks = false")
        XCTAssertEqual(CodexConfigEdit.restoreHooks(e.content, previousHooksLine: e.previousHooksLine, createdFeaturesTable: false), text)
    }

    func testInlineFeaturesTableIsNotRewritten() throws {
        XCTAssertThrowsError(try CodexConfigEdit.enableHooks("features = { web_search = true }\n"))
        XCTAssertFalse(try CodexConfigEdit.enableHooks("features = { web_search = true, hooks = true }\n").changed)
    }

    func testDottedKeysInsideOtherTablesAreIgnored() throws {
        let text = "[profiles.a]\nfeatures.hooks = false\n"
        let e = try CodexConfigEdit.enableHooks(text)
        XCTAssertEqual(e.content, text + "\n[features]\nhooks = true\n")
        XCTAssertTrue(e.createdFeaturesTable)
    }
}
final class IntegrationsTests: ZhHansTestCase {
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

    func testConfigPermissionsArePreserved() throws {
        try write(config, ".codex/config.toml")
        let path = home.appendingPathComponent(".codex/config.toml").path
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let c = CodexIntegration(home: home)
        try c.install()
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path + ".cc-desk.bak")[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try c.uninstall()
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
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

    // MARK: 读不出的配置 / 备份

    func testUnreadableConfigAbortsWithoutOverwriting() throws {
        let bytes = Data([0x6d, 0x6f, 0x64, 0x65, 0x6c, 0x20, 0x3d, 0x20, 0xff, 0xfe, 0x0a]) // 非 UTF-8
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let url = home.appendingPathComponent(".codex/config.toml")
        try bytes.write(to: url)
        let c = CodexIntegration(home: home)
        XCTAssertThrowsError(try c.install()) { error in
            XCTAssertTrue((error as? IntegrationError)?.message.contains("config.toml") ?? false)
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes, "the unreadable file is left exactly as it was")
        XCTAssertNil(read(".codex/config.toml.cc-desk.bak"))
    }

    func testInlineFeaturesAbortsInstall() throws {
        let text = "features = { web_search = true }\n"
        try write(text, ".codex/config.toml")
        XCTAssertThrowsError(try CodexIntegration(home: home).install())
        XCTAssertEqual(read(".codex/config.toml"), text)
    }

    func testBackupsNeverClobberEachOther() throws {
        try write("v1\n", ".codex/config.toml")
        let url = home.appendingPathComponent(".codex/config.toml")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try XCTUnwrap(try IntegrationFiles.backup(url, now: now))
        XCTAssertEqual(first.lastPathComponent, "config.toml.cc-desk.bak")
        try write("v2\n", ".codex/config.toml")
        let second = try XCTUnwrap(try IntegrationFiles.backup(url, now: now))
        try write("v3\n", ".codex/config.toml")
        let third = try XCTUnwrap(try IntegrationFiles.backup(url, now: now))
        XCTAssertEqual(Set([first, second, third].map(\.path)).count, 3)
        XCTAssertTrue(second.lastPathComponent.hasPrefix("config.toml.cc-desk.2"))
        XCTAssertTrue(third.lastPathComponent.hasSuffix("-1.bak"))
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "v1\n", "the first backup keeps the original")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "v2\n")
        XCTAssertEqual(try String(contentsOf: third, encoding: .utf8), "v3\n")
    }
}
