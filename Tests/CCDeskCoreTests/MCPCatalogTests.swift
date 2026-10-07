import XCTest
@testable import CCDeskCore

final class MCPCatalogTests: ZhHansTestCase {
    func testClaudeConfigUserAndLocalScopesHideSecrets() {
        let root: [String: Any] = [
            "mcpServers": [
                "github": ["command": "npx", "args": ["-y", "@mcp/github", "--token", "ghp_abcdefghijklmnopqrstuvwxyz123456"],
                           "env": ["GITHUB_TOKEN": "ghp_secretsecretsecret"]],
                "docs": ["type": "http", "url": "https://api.example.com/mcp?key=abc123", "headers": ["Authorization": "Bearer x"]],
            ],
            "projects": ["/p/app": ["mcpServers": ["db": ["command": "db-mcp", "args": ["DB_PASSWORD=hunter2"]]]],
                         "/p/empty": ["mcpServers": [String: Any]()]],
        ]
        let entries = MCPCatalog.claudeConfig(root, path: "/h/.claude.json")
        XCTAssertEqual(entries.map(\.name), ["docs", "github", "db"])
        let github = entries[1]
        XCTAssertEqual(github.transport, .stdio)
        XCTAssertEqual(github.args, ["-y", "@mcp/github", "--token", "••••"])
        XCTAssertEqual(github.envKeys, ["GITHUB_TOKEN"])
        XCTAssertEqual(entries[0].url, "https://api.example.com/mcp?key=••••")
        XCTAssertEqual(entries[0].headerKeys, ["Authorization"])
        XCTAssertEqual(entries[2].source, .claudeLocal(project: "/p/app"))
        XCTAssertEqual(entries[2].args, ["DB_PASSWORD=••••"])
        // 任何字段里都不能出现密钥原文。
        let dump = "\(entries)"
        for secret in ["ghp_abc", "secretsecret", "abc123", "hunter2", "Bearer x"] { XCTAssertFalse(dump.contains(secret), secret) }
    }

    func testCodexSectionsOnly() {
        let text = """
        model_provider = "custom"
        model = "x"
        [model_providers.custom]
        api_key = "sk-should-never-appear-0123456789"
        [mcp_servers.fs]
        command = "npx"
        args = ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
        [mcp_servers.fs.env]
        API_KEY = "sk-also-hidden-0123456789abcdef"
        [mcp_servers.remote]
        url = "https://mcp.example.com/sse"
        enabled = false
        [profiles.fast]
        model = "y"
        """
        let entries = MCPCatalog.codexServers(text, path: "/h/.codex/config.toml")
        XCTAssertEqual(entries.map(\.name), ["fs", "remote"])
        XCTAssertEqual(entries[0].command, "npx")
        XCTAssertEqual(entries[0].envKeys, ["API_KEY"])
        XCTAssertEqual(entries[1].transport, .http)
        XCTAssertFalse(entries[1].enabled)
        XCTAssertFalse("\(entries)".contains("sk-"))
    }

    func testOpenCodeJSONC() throws {
        let text = """
        {
          // 注释
          "$schema": "https://opencode.ai/config.json", /* 块注释 */
          "mcp": {
            "local": { "type": "local", "command": ["bun", "x", "my-mcp"], "environment": { "TOKEN": "t" }, },
            "remote": { "type": "remote", "url": "https://x.dev/mcp", "enabled": false },
          },
        }
        """
        let root = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(MCPCatalog.stripJSONC(text).utf8))) as? [String: Any])
        let entries = MCPCatalog.openCodeServers(root, source: .openCodeGlobal, path: "/c")
        XCTAssertEqual(entries.map(\.name), ["local", "remote"])
        XCTAssertEqual(entries[0].command, "bun")
        XCTAssertEqual(entries[0].args, ["x", "my-mcp"])
        XCTAssertEqual(entries[0].envKeys, ["TOKEN"])
        XCTAssertFalse(entries[1].enabled)
        XCTAssertEqual(entries[1].source.agent, .opencode)
    }

    func testClaudeListParsingAndMerge() {
        let output = """
        Checking MCP server health…

        claude.ai Claude Docs: https://api.anthropic.com/v1/pages/mcp - ✔ Connected
        claude.ai Notion: https://mcp.notion.com/mcp - ! Needs authentication
        okr: https://inner.example.com/mcp/okr (HTTP) - ✔ Connected
        claude.ai 123: https://x.example.com/mcp1 - ✘ Failed to connect — Version negotiation probe timed out after 5000ms
        """
        let list = MCPCatalog.parseClaudeList(output)
        XCTAssertEqual(list.map(\.name), ["claude.ai Claude Docs", "claude.ai Notion", "okr", "claude.ai 123"])
        XCTAssertEqual(list[1].health, .needsAuth)
        if case .failed(let why) = list[3].health { XCTAssertTrue(why.contains("timed out")) } else { XCTFail() }
        let local = [MCPServerEntry(name: "okr", source: .claudeUser, transport: .http, url: "https://inner.example.com/mcp/okr")]
        let merged = MCPCatalog.merge(claudeList: list, into: local)
        XCTAssertEqual(merged.first?.health, .connected)
        XCTAssertEqual(merged.filter { $0.source == .claudeConnector }.map(\.name), ["Claude Docs", "Notion", "123"])
        XCTAssertEqual(MCPCatalog.filter(merged, query: "notion", agent: .claude).count, 1)
        XCTAssertEqual(MCPCatalog.filter(merged, query: "", agent: .codex).count, 0)
    }

    func testMaskingKeepsOrdinaryArgs() {
        XCTAssertEqual(MCPCatalog.maskArgs(["-y", "@scope/pkg@1.2.3", "/Users/me/project", "--port", "3000"]),
                       ["-y", "@scope/pkg@1.2.3", "/Users/me/project", "--port", "3000"])
        XCTAssertEqual(MCPCatalog.maskArgs(["--api-key=abc"]), ["--api-key=••••"])
        XCTAssertEqual(MCPCatalog.maskURL("https://user:pw@h.com/x?token=1&a=2"), "https://••••:••••@h.com/x?token=••••&a=••••")
    }
}

final class MCPPromotionTests: XCTestCase {
    func testRawConfigAndArguments() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-home-\(UUID().uuidString)")
        let project = home.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let claude: [String: Any] = [
            "mcpServers": ["existing": ["type": "http", "url": "https://a"]],
            "projects": [project.path: ["mcpServers": ["nav": ["type": "http", "url": "https://nav/mcp",
                                                               "headers": ["Authorization": "Bearer s3cret"]]]]],
        ]
        try JSONSerialization.data(withJSONObject: claude).write(to: home.appendingPathComponent(".claude.json"))
        try JSONSerialization.data(withJSONObject: ["mcpServers": ["team": ["command": "npx", "args": ["x"]]]])
            .write(to: project.appendingPathComponent(".mcp.json"))

        let local = MCPServerEntry(name: "nav", source: .claudeLocal(project: project.path), transport: .http)
        let config = try XCTUnwrap(MCPPromotion.rawConfig(for: local, home: home))
        XCTAssertEqual((config["headers"] as? [String: String])?["Authorization"], "Bearer s3cret", "原样带上密钥")
        let args = try XCTUnwrap(MCPPromotion.addArguments(name: "nav", config: config))
        XCTAssertEqual(Array(args.prefix(5)), ["mcp", "add-json", "-s", "user", "nav"])
        XCTAssertTrue(args[5].contains("\"url\":\"https://nav/mcp\""))
        XCTAssertTrue(MCPPromotion.canRemoveOriginal(local))

        let team = MCPServerEntry(name: "team", source: .claudeProject(project: project.path), transport: .stdio)
        XCTAssertEqual(MCPPromotion.rawConfig(for: team, home: home)?["command"] as? String, "npx")
        XCTAssertTrue(MCPPromotion.canPromote(team))
        XCTAssertFalse(MCPPromotion.canRemoveOriginal(team))

        XCTAssertTrue(MCPPromotion.existsInUserScope("existing", home: home))
        XCTAssertFalse(MCPPromotion.existsInUserScope("nav", home: home))
        XCTAssertFalse(MCPPromotion.canPromote(MCPServerEntry(name: "x", source: .claudeUser, transport: .http)))
        XCTAssertEqual(MCPPromotion.removeArguments(name: "nav"), ["mcp", "remove", "-s", "local", "nav"])
    }
}
