import Foundation

// MARK: - OpenAI 兼容的 /chat/completions（设计 §22）：消息、请求、响应。纯数据，便于测试。

/// 对话里的一条消息（system / user / assistant / tool）。
public struct ChatMessage: Equatable, Codable, Sendable {
    public var role: String
    public var content: String?
    /// assistant 消息里的工具调用。
    public var toolCalls: [ChatToolCall]?
    /// tool 消息对应的调用 id。
    public var toolCallID: String?

    public init(role: String, content: String?, toolCalls: [ChatToolCall]? = nil, toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    public static func system(_ text: String) -> ChatMessage { ChatMessage(role: "system", content: text) }
    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: "user", content: text) }
    public static func tool(id: String, _ text: String) -> ChatMessage { ChatMessage(role: "tool", content: text, toolCallID: id) }

    /// 请求体里的样子。带工具调用的 assistant 消息 content 用空字符串（有的服务不接受 null）。
    public var json: JSONValue {
        var obj: [String: JSONValue] = ["role": .string(role)]
        if let toolCalls, !toolCalls.isEmpty {
            obj["content"] = .string(content ?? "")
            obj["tool_calls"] = .array(toolCalls.map(\.json))
        } else {
            obj["content"] = .string(content ?? "")
        }
        if let toolCallID { obj["tool_call_id"] = .string(toolCallID) }
        return .object(obj)
    }

    /// 估算的大小（字符数，含工具调用参数），用于裁剪历史。
    public var size: Int {
        (content?.count ?? 0) + (toolCalls ?? []).reduce(0) { $0 + $1.name.count + $1.arguments.count + 16 }
    }
}

public struct ChatToolCall: Equatable, Codable, Sendable {
    public var id: String
    public var name: String
    /// 原样的参数文本（模型给的 JSON 字符串；可能不合法）。
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    public var json: JSONValue {
        ["id": .string(id), "type": "function", "function": ["name": .string(name), "arguments": .string(arguments)]]
    }

    public struct ArgumentError: Error, Equatable, Sendable {
        public let message: String
    }

    /// 解析参数：空白 = 没有参数；不是 JSON 对象时返回错误说明（交给模型，让它重试）。
    public func parsedArguments() -> Result<[String: JSONValue], ArgumentError> {
        let text = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "null" { return .success([:]) }
        guard let value = JSONValue.parse(text) else {
            return .failure(ArgumentError(message: "arguments are not valid JSON; call \(name) again with a JSON object"))
        }
        guard let object = value.objectValue else {
            return .failure(ArgumentError(message: "arguments must be a JSON object; call \(name) again with a JSON object"))
        }
        return .success(object)
    }
}

/// 一次响应里我们关心的部分。
public struct ChatCompletion: Equatable, Sendable {
    public var content: String?
    public var toolCalls: [ChatToolCall]
    /// stop / tool_calls / length / content_filter…（有的服务不给）。
    public var finishReason: String?
    public var promptTokens: Int
    public var completionTokens: Int
    /// 服务端实际用的模型名（如果给了）。
    public var model: String?

    public init(content: String?, toolCalls: [ChatToolCall] = [], finishReason: String? = nil, promptTokens: Int = 0,
                completionTokens: Int = 0, model: String? = nil) {
        self.content = content
        self.toolCalls = toolCalls
        self.finishReason = finishReason
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.model = model
    }
}

public enum ChatAPIError: Error, Equatable, Sendable {
    /// 非 2xx；detail 是服务端错误信息的开头（可能为空），只用于界面，不写日志。
    case http(Int, String?)
    /// 网络错误（域与错误码）。
    case network(String)
    case timeout
    case cancelled
    /// 响应不是预期的 JSON。
    case invalidResponse(String)
    /// 服务端在 200 响应里报错。
    case provider(String)
    /// macOS 不允许用 http 连这个地址（ATS，NSURLError -1022）：要用 https。
    case httpsRequired

    /// 简短说明（给提示条 / 设置页；不含密钥与消息内容）。
    public var short: String {
        switch self {
        case .http(let code, _): return "HTTP \(code)"
        case .network(let what): return what
        case .timeout: return "timeout"
        case .cancelled: return "cancelled"
        case .invalidResponse: return "invalid response"
        case .provider: return "provider error"
        case .httpsRequired: return "https required"
        }
    }
}

public enum ChatAPI {
    /// `<base>/chat/completions`。
    public static func completionsURL(_ base: URL) -> URL { base.appendingPathComponent("chat/completions") }
    /// `<base>/models`。
    public static func modelsURL(_ base: URL) -> URL { base.appendingPathComponent("models") }

    /// 请求体。toolChoice：nil = 不指定（auto），"none" = 不许调用工具（迭代用完时逼出文字回复）。
    public static func body(model: String, messages: [ChatMessage], tools: [AssistantToolSpec], toolChoice: String? = nil,
                            temperature: Double? = 0.3, maxTokens: Int? = nil) -> JSONValue {
        var obj: [String: JSONValue] = [
            "model": .string(model), "messages": .array(messages.map(\.json)), "stream": false,
        ]
        if !tools.isEmpty {
            obj["tools"] = .array(tools.map(\.functionTool))
            if let toolChoice { obj["tool_choice"] = .string(toolChoice) }
        }
        if let temperature { obj["temperature"] = .number(temperature) }
        if let maxTokens { obj["max_tokens"] = .number(Double(maxTokens)) }
        return .object(obj)
    }

    /// HTTP 请求：JSON 体，有密钥时 `Authorization: Bearer`。
    public static func request(url: URL, method: String = "POST", body: JSONValue?, apiKey: String?,
                               timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: max(1, timeout))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = Data(body.compact.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        // OpenRouter 用这个头标识来源（可选，其他服务忽略）。
        request.setValue("CC Desk", forHTTPHeaderField: "X-Title")
        return request
    }

    /// 解析响应（status 为 HTTP 状态码）。
    public static func parse(status: Int, data: Data) -> Result<ChatCompletion, ChatAPIError> {
        let text = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(status) else { return .failure(.http(status, errorMessage(text))) }
        guard let root = JSONValue.parse(text), root.objectValue != nil else {
            return .failure(.invalidResponse("not JSON"))
        }
        if let message = root["error"].flatMap(errorText) { return .failure(.provider(message)) }
        guard let choice = root["choices"]?.arrayValue?.first, let message = choice["message"] else {
            return .failure(.invalidResponse("no choices"))
        }
        var calls: [ChatToolCall] = []
        for (i, call) in (message["tool_calls"]?.arrayValue ?? []).enumerated() {
            guard let function = call["function"], let name = function["name"]?.stringValue, !name.isEmpty else { continue }
            let arguments: String
            switch function["arguments"] {
            case .string(let s)?: arguments = s
            case nil, .null?: arguments = ""
            case let other?: arguments = other.compact  // 有的服务直接给对象
            }
            let id = call["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "call_\(i + 1)"
            calls.append(ChatToolCall(id: id, name: name, arguments: arguments))
        }
        let usage = root["usage"] ?? [:]
        return .success(ChatCompletion(content: message["content"]?.stringValue, toolCalls: calls,
                                       finishReason: choice["finish_reason"]?.stringValue,
                                       promptTokens: usage["prompt_tokens"]?.intValue ?? 0,
                                       completionTokens: usage["completion_tokens"]?.intValue ?? 0,
                                       model: root["model"]?.stringValue))
    }

    /// `GET /models` 的结果：`{"data":[{"id":…}]}` → 排好序的 id。
    public static func parseModels(status: Int, data: Data) -> Result<[String], ChatAPIError> {
        let text = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(status) else { return .failure(.http(status, errorMessage(text))) }
        guard let items = JSONValue.parse(text)?["data"]?.arrayValue else { return .failure(.invalidResponse("no data")) }
        let ids = items.compactMap { $0["id"]?.stringValue }.filter { !$0.isEmpty }
        return .success(Array(Set(ids)).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    /// 错误响应里的说明（`{"error":{"message":…}}` 或 `{"error":"…"}`），截断。
    static func errorMessage(_ text: String) -> String? {
        guard let root = JSONValue.parse(text) else { return nil }
        return root["error"].flatMap(errorText) ?? root["message"]?.stringValue.map { String($0.prefix(200)) }
    }

    private static func errorText(_ error: JSONValue) -> String? {
        if let s = error.stringValue { return String(s.prefix(200)) }
        if let s = error["message"]?.stringValue { return String(s.prefix(200)) }
        return nil
    }

    /// 回复里的「思考」段（qwen3 等本地模型会输出 `<think>…</think>`）不朗读也不存。
    public static func stripThinking(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
        // 只有结束标记（开头被服务端吃掉）：去掉它之前的内容。
        if let end = out.range(of: "</think>") { out = String(out[end.upperBound...]) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension AssistantToolSpec {
    /// OpenAI 函数工具：`{"type":"function","function":{"name","description","parameters"}}`。
    public var functionTool: JSONValue {
        ["type": "function",
         "function": ["name": .string(name), "description": .string(description), "parameters": inputSchema]]
    }
}
