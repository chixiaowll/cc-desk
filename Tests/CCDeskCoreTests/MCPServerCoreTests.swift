import XCTest
@testable import CCDeskCore

final class MCPServerCoreTests: XCTestCase {
    private var calls: [(String, [String: JSONValue])] = []

    private func server() -> MCPServerCore {
        MCPServerCore(version: "1.3") { [unowned self] name, args in
            self.calls.append((name, args))
            return name == "close_session" ? .init(text: "cancelled by the user") : .init(text: "ok \(name)")
        }
    }

    private func reply(_ core: inout MCPServerCore, _ line: String) throws -> JSONValue {
        try XCTUnwrap(JSONValue.parse(try XCTUnwrap(core.handle(line: line))))
    }

    func testInitializeNegotiatesVersion() throws {
        var core = server()
        let r = try reply(&core, #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2"}}}"#)
        XCTAssertEqual(r["id"], 0)
        XCTAssertEqual(r["result"]?["protocolVersion"], "2025-06-18")
        XCTAssertEqual(r["result"]?["serverInfo"]?["name"], "ccdesk")
        XCTAssertEqual(r["result"]?["serverInfo"]?["version"], "1.3")
        XCTAssertNotNil(r["result"]?["capabilities"]?["tools"])
        XCTAssertEqual(core.negotiatedVersion, "2025-06-18")

        var other = server()
        let unknown = try reply(&other, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual(unknown["result"]?["protocolVersion"]?.stringValue, MCPServerCore.supportedVersions[0])
    }

    func testNotificationsGetNoReply() {
        var core = server()
        XCTAssertNil(core.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(core.handle(line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#))
        XCTAssertNil(core.handle(line: #"{"jsonrpc":"2.0","id":5,"result":{}}"#))
    }

    func testPingAndUnknownMethod() throws {
        var core = server()
        XCTAssertEqual(try reply(&core, #"{"jsonrpc":"2.0","id":"p","method":"ping"}"#)["result"], [:])
        let r = try reply(&core, #"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#)
        XCTAssertEqual(r["error"]?["code"], -32601)
    }

    func testMalformedInput() throws {
        var core = server()
        XCTAssertEqual(try reply(&core, "{oops")["error"]?["code"], -32700)
        XCTAssertEqual(try reply(&core, #"{"id":1,"method":"ping"}"#)["error"]?["code"], -32600)
    }

    func testToolsListUsesCatalog() throws {
        var core = server()
        let tools = try XCTUnwrap(try reply(&core, #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)["result"]?["tools"]?.arrayValue)
        XCTAssertEqual(tools.compactMap { $0["name"]?.stringValue }, AssistantTools.all.map(\.name))
        let type = try XCTUnwrap(tools.first { $0["name"] == "type_text" })
        XCTAssertEqual(type["inputSchema"]?["type"], "object")
        XCTAssertEqual(type["inputSchema"]?["required"], ["text"])
        XCTAssertEqual(type["inputSchema"]?["properties"]?["submit"]?["type"], "boolean")
        XCTAssertEqual(type["annotations"]?["readOnlyHint"], false)
    }

    func testToolsCallForwardsAndWrapsText() throws {
        var core = server()
        let r = try reply(&core, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"type_text","arguments":{"session":"s1","text":"hi"}}}"#)
        XCTAssertEqual(r["result"]?["content"], [["type": "text", "text": "ok type_text"]])
        XCTAssertEqual(r["result"]?["isError"], false)
        XCTAssertEqual(calls.first?.0, "type_text")
        XCTAssertEqual(calls.first?.1["text"], "hi")
        // 没有 arguments 也行。
        _ = try reply(&core, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_sessions"}}"#)
        XCTAssertEqual(calls.last?.1, [:])
    }

    func testUnknownToolIsProtocolError() throws {
        var core = server()
        let r = try reply(&core, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"rm_rf"}}"#)
        XCTAssertEqual(r["error"]?["code"], -32602)
        XCTAssertTrue(calls.isEmpty)
    }

    func testOutcomeFromControlResult() {
        XCTAssertEqual(MCPServerCore.outcome(from: .success(["text": "done"])), .init(text: "done"))
        XCTAssertEqual(MCPServerCore.outcome(from: .success(["sessions": []])), .init(text: #"{"sessions":[]}"#))
        XCTAssertEqual(MCPServerCore.outcome(from: .failure(ControlError(.unavailable, "not running"))),
                       .init(text: "not running", isError: true))
    }

    func testConfigJSON() throws {
        let json = try XCTUnwrap(JSONValue.parse(MCPServerCore.configJSON(executable: "/Applications/CC Desk.app/Contents/MacOS/CCDesk",
                                                                          socketPath: "/Users/u/.cc-desk/control.sock")))
        let server = try XCTUnwrap(json["mcpServers"]?["ccdesk"])
        XCTAssertEqual(server["type"], "stdio")
        XCTAssertEqual(server["command"], "/Applications/CC Desk.app/Contents/MacOS/CCDesk")
        XCTAssertEqual(server["args"], ["--mcp"])
        XCTAssertEqual(server["env"]?["CCDESK_CONTROL_SOCKET"], "/Users/u/.cc-desk/control.sock")
    }
}

final class AssistantToolsTests: XCTestCase {
    func testCatalogCoversSpecTable() {
        let names = Set(AssistantTools.all.map(\.name))
        for name in ["list_sessions", "read_screen", "read_transcript", "list_history", "list_projects", "git_status",
                     "switch_to", "type_text", "press_key", "respond_approval", "new_session", "resume_session",
                     "close_session", "take_over", "clear_input"] {
            XCTAssertTrue(names.contains(name), name)
        }
        XCTAssertEqual(names.count, AssistantTools.all.count, "duplicate tool names")
    }

    func testSchemasAreWellFormed() {
        for tool in AssistantTools.all {
            let schema = tool.inputSchema
            XCTAssertEqual(schema["type"], "object", tool.name)
            let properties = schema["properties"]?.objectValue ?? [:]
            XCTAssertEqual(Set(properties.keys), Set(tool.parameters.map(\.name)), tool.name)
            for required in schema["required"]?.arrayValue ?? [] {
                XCTAssertNotNil(properties[required.stringValue ?? ""], tool.name)
            }
            XCTAssertFalse(tool.description.isEmpty)
        }
        XCTAssertEqual(AssistantTools.spec(named: "press_key")?.inputSchema["properties"]?["key"]?["enum"],
                       ["enter", "escape", "ctrl-c", "up", "down", "tab"])
        XCTAssertEqual(AssistantTools.spec(named: "list_sessions")?.readOnly, true)
        XCTAssertEqual(AssistantTools.spec(named: "close_session")?.readOnly, false)
    }

    func testKeysParseLenientlyAndFollowCursorMode() {
        XCTAssertEqual(AssistantKey(spoken: "Enter"), .enter)
        XCTAssertEqual(AssistantKey(spoken: "ctrl+c"), .ctrlC)
        XCTAssertEqual(AssistantKey(spoken: "ESC"), .escape)
        XCTAssertNil(AssistantKey(spoken: "f5"))
        XCTAssertEqual(AssistantKey.up.bytes(applicationCursor: false), "\u{1b}[A")
        XCTAssertEqual(AssistantKey.up.bytes(applicationCursor: true), "\u{1b}OA")
        XCTAssertEqual(AssistantKey.ctrlC.bytes(applicationCursor: false), "\u{03}")
    }
}
