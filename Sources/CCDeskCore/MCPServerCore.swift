import Foundation

/// stdio MCP 服务器的协议部分（设计 §13，`CCDesk --mcp`）：JSON-RPC 2.0，每行一条消息。
/// 支持 initialize / notifications/initialized / ping / tools/list / tools/call；工具调用交给 `callTool`
/// （App 里转发到控制接口）。纯逻辑，便于测试。
public struct MCPServerCore {
    /// 支持的协议版本，新的在前；客户端请求的版本在列表里就沿用，否则回复最新的。
    public static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static let serverName = AssistantTools.mcpServerName

    /// 工具调用结果：文字内容，isError 时模型会看到这是一次失败的调用。
    public struct ToolOutcome: Equatable, Sendable {
        public let text: String
        public let isError: Bool

        public init(text: String, isError: Bool = false) {
            self.text = text
            self.isError = isError
        }
    }

    public enum ErrorCode: Int {
        case parseError = -32700
        case invalidRequest = -32600
        case methodNotFound = -32601
        case invalidParams = -32602
    }

    public let tools: [AssistantToolSpec]
    public let version: String
    private let callTool: (String, [String: JSONValue]) -> ToolOutcome
    public private(set) var negotiatedVersion: String?

    public init(tools: [AssistantToolSpec] = AssistantTools.all, version: String = "1",
                callTool: @escaping (String, [String: JSONValue]) -> ToolOutcome) {
        self.tools = tools
        self.version = version
        self.callTool = callTool
    }

    /// 处理一行输入；返回要写回的一行（通知没有回复，返回 nil）。
    public mutating func handle(line: String) -> String? {
        guard let message = JSONValue.parse(line) else {
            return Self.error(id: .null, .parseError, "Parse error")
        }
        guard let obj = message.objectValue, obj["jsonrpc"]?.stringValue == "2.0" else {
            return Self.error(id: message["id"] ?? .null, .invalidRequest, "Invalid Request")
        }
        // 没有 id 的是通知（含 notifications/initialized、notifications/cancelled）：不回复。
        guard let id = obj["id"], id != .null else { return nil }
        guard let method = obj["method"]?.stringValue else {
            // 客户端发来的响应（我们不发请求），忽略。
            return obj["result"] != nil || obj["error"] != nil ? nil : Self.error(id: id, .invalidRequest, "Invalid Request")
        }
        let params = obj["params"]?.objectValue ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? ""
            let chosen = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            negotiatedVersion = chosen
            return Self.result(id: id, [
                "protocolVersion": .string(chosen),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(Self.serverName), "version": .string(version)],
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": .array(tools.map(\.mcpDescriptor))])
        case "tools/call":
            guard let name = params["name"]?.stringValue, tools.contains(where: { $0.name == name }) else {
                return Self.error(id: id, .invalidParams, "Unknown tool: \(params["name"]?.stringValue ?? "")")
            }
            let arguments = params["arguments"]?.objectValue ?? [:]
            let outcome = callTool(name, arguments)
            return Self.result(id: id, [
                "content": [["type": "text", "text": .string(outcome.text)]],
                "isError": .bool(outcome.isError),
            ])
        default:
            return Self.error(id: id, .methodNotFound, "Method not found: \(method)")
        }
    }

    static func result(id: JSONValue, _ result: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).compact
    }

    static func error(id: JSONValue, _ code: ErrorCode, _ message: String) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id,
                          "error": ["code": .number(Double(code.rawValue)), "message": .string(message)]]).compact
    }

    /// 控制接口的结果 → 给模型看的文字：有 `text` 字段就用它，否则用紧凑 JSON。
    public static func outcome(from response: Result<JSONValue, ControlError>) -> ToolOutcome {
        switch response {
        case .success(let value):
            if let text = value["text"]?.stringValue, value.objectValue?.count == 1 { return ToolOutcome(text: text) }
            if let text = value.stringValue { return ToolOutcome(text: text) }
            return ToolOutcome(text: value.compact)
        case .failure(let error):
            return ToolOutcome(text: error.message, isError: true)
        }
    }

    /// `--mcp-config` 的内容：`ccdesk` 服务器 = 本程序加 `--mcp`，控制接口路径经环境变量传入。
    public static func configJSON(executable: String, socketPath: String) -> String {
        let server: JSONValue = [
            "type": "stdio", "command": .string(executable), "args": ["--mcp"],
            "env": [ControlProtocol.socketEnvironmentKey: .string(socketPath)],
        ]
        return JSONValue.object(["mcpServers": [serverName: server]]).compact
    }
}
