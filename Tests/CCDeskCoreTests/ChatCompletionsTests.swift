import XCTest
@testable import CCDeskCore

/// OpenAI 兼容接口（设计 §22）：请求体、函数工具的 JSON Schema、响应解析、后端选择与接口设置。
final class ChatCompletionsTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: 请求

    func testBodyCarriesMessagesAndFunctionTools() throws {
        let call = ChatToolCall(id: "call_1", name: "list_sessions", arguments: "{}")
        let messages: [ChatMessage] = [.system("sys"), .user("[UTTERANCE]\nhi"),
                                       ChatMessage(role: "assistant", content: nil, toolCalls: [call]),
                                       .tool(id: "call_1", "s1 poems")]
        let body = ChatAPI.body(model: "deepseek-chat", messages: messages, tools: AssistantTools.all)
        XCTAssertEqual(body["model"], "deepseek-chat")
        XCTAssertEqual(body["stream"], false)
        XCTAssertNil(body["tool_choice"])
        let sent = try XCTUnwrap(body["messages"]?.arrayValue)
        XCTAssertEqual(sent.map { $0["role"]?.stringValue }, ["system", "user", "assistant", "tool"])
        XCTAssertEqual(sent[2]["content"], "", "assistant content with tool calls is an empty string, not null")
        XCTAssertEqual(sent[2]["tool_calls"]?.arrayValue?.first?["function"]?["name"], "list_sessions")
        XCTAssertEqual(sent[2]["tool_calls"]?.arrayValue?.first?["type"], "function")
        XCTAssertEqual(sent[3]["tool_call_id"], "call_1")

        let tools = try XCTUnwrap(body["tools"]?.arrayValue)
        XCTAssertEqual(tools.count, AssistantTools.all.count)
        let typeText = try XCTUnwrap(tools.first { $0["function"]?["name"] == "type_text" })
        XCTAssertEqual(typeText["type"], "function")
        let parameters = try XCTUnwrap(typeText["function"]?["parameters"])
        XCTAssertEqual(parameters, AssistantTools.spec(named: "type_text")?.inputSchema)
        XCTAssertEqual(parameters["required"], ["text"])
        XCTAssertEqual(parameters["properties"]?["submit"]?["type"], "boolean")
        let pressKey = try XCTUnwrap(tools.first { $0["function"]?["name"] == "press_key" })
        XCTAssertEqual(pressKey["function"]?["parameters"]?["properties"]?["key"]?["enum"]?.arrayValue?.count, 6)
    }

    func testForcedTextAndNoToolsBodies() {
        let forced = ChatAPI.body(model: "m", messages: [.user("x")], tools: AssistantTools.all, toolChoice: "none")
        XCTAssertEqual(forced["tool_choice"], "none")
        let plain = ChatAPI.body(model: "m", messages: [.user("x")], tools: [])
        XCTAssertNil(plain["tools"])
        XCTAssertNil(plain["tool_choice"])
    }

    func testRequestHeadersAndURLs() throws {
        let base = try XCTUnwrap(URL(string: "https://api.deepseek.com/v1"))
        XCTAssertEqual(ChatAPI.completionsURL(base).absoluteString, "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(ChatAPI.modelsURL(base).absoluteString, "https://api.deepseek.com/v1/models")
        let withKey = ChatAPI.request(url: ChatAPI.completionsURL(base), body: ["a": 1], apiKey: " sk-1 ", timeout: 30)
        XCTAssertEqual(withKey.httpMethod, "POST")
        XCTAssertEqual(withKey.value(forHTTPHeaderField: "Authorization"), "Bearer sk-1")
        XCTAssertEqual(withKey.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(withKey.timeoutInterval, 30)
        let noKey = ChatAPI.request(url: ChatAPI.modelsURL(base), method: "GET", body: nil, apiKey: "", timeout: 5)
        XCTAssertNil(noKey.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(noKey.httpBody)
    }

    // MARK: 响应

    func testParsesTextReplyAndUsage() throws {
        let json = #"{"model":"deepseek-chat","choices":[{"message":{"role":"assistant","content":"好的"},"finish_reason":"stop"}],"usage":{"prompt_tokens":120,"completion_tokens":7}}"#
        let reply = try ChatAPI.parse(status: 200, data: data(json)).get()
        XCTAssertEqual(reply.content, "好的")
        XCTAssertEqual(reply.toolCalls, [])
        XCTAssertEqual(reply.finishReason, "stop")
        XCTAssertEqual(reply.promptTokens, 120)
        XCTAssertEqual(reply.completionTokens, 7)
        XCTAssertEqual(reply.model, "deepseek-chat")
    }

    func testParsesMultipleToolCallsObjectArgumentsAndMissingIDs() throws {
        let json = """
        {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[
          {"id":"a","type":"function","function":{"name":"list_sessions","arguments":""}},
          {"type":"function","function":{"name":"type_text","arguments":{"text":"跑测试"}}},
          {"id":"c","type":"function","function":{"name":"press_key","arguments":"{\\"key\\":\\"enter\\"}"}},
          {"id":"d","type":"function","function":{"arguments":"{}"}}
        ]},"finish_reason":"tool_calls"}]}
        """
        let reply = try ChatAPI.parse(status: 200, data: data(json)).get()
        XCTAssertNil(reply.content)
        XCTAssertEqual(reply.finishReason, "tool_calls")
        XCTAssertEqual(reply.toolCalls.map(\.name), ["list_sessions", "type_text", "press_key"], "nameless calls are dropped")
        XCTAssertEqual(reply.toolCalls.map(\.id), ["a", "call_2", "c"])
        XCTAssertEqual(try reply.toolCalls[0].parsedArguments().get(), [:])
        XCTAssertEqual(try reply.toolCalls[1].parsedArguments().get(), ["text": "跑测试"])
        XCTAssertEqual(try reply.toolCalls[2].parsedArguments().get(), ["key": "enter"])
    }

    func testMalformedArgumentsAreReportedNotThrown() {
        for bad in ["{\"text\": ", "[1,2]", "\"x\""] {
            let call = ChatToolCall(id: "1", name: "type_text", arguments: bad)
            guard case .failure(let error) = call.parsedArguments() else { return XCTFail(bad) }
            XCTAssertTrue(error.message.contains("type_text"), bad)
        }
        XCTAssertEqual(try ChatToolCall(id: "1", name: "x", arguments: "  null ").parsedArguments().get(), [:])
    }

    func testErrorsAndFinishReasons() {
        XCTAssertEqual(ChatAPI.parse(status: 401, data: data(#"{"error":{"message":"Invalid API key"}}"#)),
                       .failure(.http(401, "Invalid API key")))
        XCTAssertEqual(ChatAPI.parse(status: 500, data: data("oops")), .failure(.http(500, nil)))
        XCTAssertEqual(ChatAPI.parse(status: 200, data: data(#"{"error":"rate limited"}"#)), .failure(.provider("rate limited")))
        XCTAssertEqual(ChatAPI.parse(status: 200, data: data("<html>")), .failure(.invalidResponse("not JSON")))
        XCTAssertEqual(ChatAPI.parse(status: 200, data: data(#"{"choices":[]}"#)), .failure(.invalidResponse("no choices")))
        let length = #"{"choices":[{"message":{"content":"半句"},"finish_reason":"length"}]}"#
        XCTAssertEqual(try ChatAPI.parse(status: 200, data: data(length)).get().finishReason, "length")
        XCTAssertEqual(ChatAPIError.http(429, "x").short, "HTTP 429")
    }

    func testModelListIsSortedAndDeduplicated() {
        let json = #"{"object":"list","data":[{"id":"qwen3:8b"},{"id":"qwen3:14b"},{"id":"qwen3:8b"},{"id":""}]}"#
        XCTAssertEqual(try ChatAPI.parseModels(status: 200, data: data(json)).get(), ["qwen3:8b", "qwen3:14b"])
        XCTAssertEqual(ChatAPI.parseModels(status: 404, data: data("")), .failure(.http(404, nil)))
    }

    func testThinkingIsStripped() {
        XCTAssertEqual(ChatAPI.stripThinking("<think>想一想\n很多</think>\n好的，已发送"), "好的，已发送")
        XCTAssertEqual(ChatAPI.stripThinking("推理过程</think>结论"), "结论")
        XCTAssertEqual(ChatAPI.stripThinking("  普通回复 "), "普通回复")
    }

    // MARK: 后端选择与设置

    func testBackendSelection() {
        typealias S = AssistantBackendSelector
        XCTAssertEqual(S.resolve(.auto, claudeAvailable: true, apiConfigured: true), .claude)
        XCTAssertEqual(S.resolve(.auto, claudeAvailable: false, apiConfigured: true), .api)
        XCTAssertEqual(S.resolve(.auto, claudeAvailable: false, apiConfigured: false), .local)
        XCTAssertEqual(S.resolve(.claude, claudeAvailable: false, apiConfigured: true), .local, "never silently switch provider")
        XCTAssertEqual(S.resolve(.api, claudeAvailable: true, apiConfigured: false), .local)
        XCTAssertEqual(S.resolve(.api, claudeAvailable: true, apiConfigured: true), .api)
        XCTAssertEqual(S.resolve(.local, claudeAvailable: true, apiConfigured: true), .local)
        XCTAssertTrue(S.needsClaude(.auto))
        XCTAssertFalse(S.needsClaude(.api))
        XCTAssertEqual(AssistantBackendChoice(stored: nil), .auto)
        XCTAssertEqual(AssistantBackendChoice(stored: "bogus"), .auto)
        XCTAssertEqual(AssistantBackendChoice(stored: "api"), .api)
    }

    func testAPISettings() throws {
        var s = AssistantAPISettings(preset: .deepseek, baseURL: " https://api.deepseek.com/v1/ ", model: " deepseek-chat ")
        XCTAssertEqual(s.endpoint?.absoluteString, "https://api.deepseek.com/v1")
        XCTAssertFalse(s.isConfigured(hasKey: false), "DeepSeek needs a key")
        XCTAssertTrue(s.isConfigured(hasKey: true))
        XCTAssertEqual(s.effectiveConsultModel, "deepseek-chat")
        s.consultModel = "deepseek-reasoner"
        XCTAssertEqual(s.effectiveConsultModel, "deepseek-reasoner")
        XCTAssertEqual(s.label, "DeepSeek · deepseek-chat")

        let ollama = AssistantAPISettings(preset: .ollama, baseURL: AssistantAPIPreset.ollama.baseURL, model: "qwen3:14b")
        XCTAssertTrue(ollama.isConfigured(hasKey: false))
        XCTAssertFalse(ollama.sendsKeyInPlaintext(hasKey: true), "localhost is fine")
        let lan = AssistantAPISettings(preset: .custom, baseURL: "http://192.168.1.9:8000/v1", model: "m")
        XCTAssertTrue(lan.isConfigured(hasKey: false))
        XCTAssertTrue(lan.sendsKeyInPlaintext(hasKey: true))
        XCTAssertFalse(lan.sendsKeyInPlaintext(hasKey: false))
        XCTAssertEqual(lan.label, "192.168.1.9 · m")
        for bad in ["", "api.deepseek.com", "ftp://x/v1", "https://"] {
            XCTAssertNil(AssistantAPISettings(preset: .custom, baseURL: bad, model: "m").endpoint, bad)
        }
        XCTAssertFalse(AssistantAPISettings(preset: .ollama, baseURL: "http://localhost:11434/v1", model: " ")
            .isConfigured(hasKey: false))
        XCTAssertEqual(Set(AssistantAPIPreset.allCases.map(\.keyAccount)).count, AssistantAPIPreset.allCases.count)
    }

    func testAPISettingsLoadDefaults() throws {
        let suite = "ccdesk-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AssistantAPISettings.load(defaults).baseURL, AssistantAPIPreset.deepseek.baseURL)
        defaults.set("ollama", forKey: AssistantAPISettings.presetKey)
        defaults.set("qwen3:14b", forKey: AssistantAPISettings.modelKey)
        let loaded = AssistantAPISettings.load(defaults)
        XCTAssertEqual(loaded.preset, .ollama)
        XCTAssertEqual(loaded.baseURL, AssistantAPIPreset.ollama.baseURL)
        XCTAssertEqual(loaded.model, "qwen3:14b")
    }

    func testProbe() {
        let body = AssistantAPIProbe.body(model: "m")
        XCTAssertEqual(body["tools"]?.arrayValue?.count, 1)
        let called = ChatCompletion(content: nil, toolCalls: [ChatToolCall(id: "1", name: "ping", arguments: "{}")], model: "m2")
        XCTAssertEqual(AssistantAPIProbe.evaluate(.success(called)), .ok(toolCalling: true, model: "m2"))
        XCTAssertEqual(AssistantAPIProbe.evaluate(.success(ChatCompletion(content: "ok"))), .ok(toolCalling: false, model: nil))
        XCTAssertEqual(AssistantAPIProbe.evaluate(.failure(.timeout)), .failed(.timeout))
    }

    func testAPISystemPromptKeepsTheResidentRules() {
        let system = AssistantPrompt.apiSystem
        XCTAssertTrue(system.hasPrefix(String(AssistantPrompt.residentSystem.prefix(200))))
        for marker in ["[UTTERANCE]", "[EVENT]", "[CONSULT_RESULT]", "[SUMMARIZE]", "<untrusted_", "function calling"] {
            XCTAssertTrue(system.contains(marker), marker)
        }
        XCTAssertFalse(system.contains("ccdesk tools"))
    }
}
