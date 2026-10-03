import XCTest
@testable import CCDeskCore

final class AssistantTests: ZhHansTestCase {
    private func context(selectedWaiting: Bool = false, pending: String = "") -> AssistantContext {
        AssistantContext(
            sessions: [
                AssistantSessionInfo(rowID: "term:A", title: "中国诗歌视频课程", dir: "poems", agent: .claude,
                                     status: selectedWaiting ? .waiting("Bash: rm -rf build") : .idle, isSelected: true),
                AssistantSessionInfo(rowID: "term:B", title: "修复侧栏排序", dir: "herdr", agent: .codex,
                                     status: .working, isSelected: false),
            ],
            projects: [AssistantProject(name: "poems", path: "/Users/u/poems"),
                       AssistantProject(name: "herdr", path: "/Users/u/herdr")],
            history: [AssistantHistoryInfo(sessionID: "hist-1", title: "旅行攻略生成", dir: "rec", agent: .claude)],
            pendingText: pending, lastTurnSummary: nil, language: "zh-Hans")
    }

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // MARK: 上下文

    func testContextJSONShape() throws {
        let obj = try object(context(selectedWaiting: true, pending: "帮我改一下").json())
        let sessions = try XCTUnwrap(obj["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0]["id"] as? String, "s1")
        XCTAssertEqual(sessions[0]["title"] as? String, "中国诗歌视频课程")
        XCTAssertEqual(sessions[0]["dir"] as? String, "poems")
        XCTAssertEqual(sessions[0]["agent"] as? String, "claude")
        XCTAssertEqual(sessions[0]["status"] as? String, "waiting_for_approval")
        XCTAssertEqual(sessions[0]["waitingFor"] as? String, "Bash: rm -rf build")
        XCTAssertEqual(sessions[0]["selected"] as? Bool, true)
        XCTAssertNil(sessions[0]["embedded"])
        XCTAssertEqual(sessions[1]["id"] as? String, "s2")
        XCTAssertEqual(sessions[1]["status"] as? String, "working")
        XCTAssertNil(sessions[1]["selected"])
        XCTAssertNil(sessions[1]["waitingFor"])
        XCTAssertEqual(obj["projects"] as? [String], ["poems", "herdr"])
        XCTAssertNil(obj["history"])
        XCTAssertEqual(obj["pendingText"] as? String, "帮我改一下")
        XCTAssertEqual(obj["uiLanguage"] as? String, "zh-Hans")
        XCTAssertNil(obj["lastTurnSummary"])
        XCTAssertNil(try object(context().json())["pendingText"])
        // 真实行 id 不暴露给模型。
        XCTAssertFalse(context().json().contains("term:A"))
    }

    func testContextKeepsAssignedShortIDsAndMarksExternal() throws {
        let ctx = AssistantContext(sessions: [
            AssistantSessionInfo(rowID: "pid:9", shortID: "s7", title: "外部", dir: "d", agent: .codex, status: .idle,
                                 isSelected: false, isEmbedded: false),
        ], language: "en")
        let first = try XCTUnwrap((try object(ctx.json())["sessions"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["id"] as? String, "s7")
        XCTAssertEqual(first["embedded"] as? Bool, false)
    }

    func testContextTruncatesLongFieldsAndLists() throws {
        let long = String(repeating: "长", count: 100)
        let sessions = (0..<40).map {
            AssistantSessionInfo(rowID: "r\($0)", title: long + "\n第二行", dir: "d", agent: .pi, status: .idle, isSelected: $0 == 0)
        }
        let ctx = AssistantContext(sessions: sessions,
                                   projects: [AssistantProject(name: "a", path: "/a"), AssistantProject(name: "a", path: "/a")],
                                   history: (0..<30).map { AssistantHistoryInfo(sessionID: "h\($0)", title: "t", dir: "d", agent: .claude) },
                                   pendingText: String(repeating: "字", count: 1000), lastTurnSummary: long + long + long + long,
                                   language: "en")
        XCTAssertEqual(ctx.sessions.count, AssistantContext.maxSessions)
        XCTAssertEqual(ctx.history.count, AssistantContext.maxHistory)
        XCTAssertEqual(ctx.history.last?.shortID, "h15")
        XCTAssertEqual(ctx.projects.count, 1)
        let obj = try object(ctx.json())
        let title = try XCTUnwrap((obj["sessions"] as? [[String: Any]])?.first?["title"] as? String)
        XCTAssertEqual(title.count, AssistantContext.titleLimit)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertFalse(title.contains("\n"))
        XCTAssertEqual((obj["pendingText"] as? String)?.count, AssistantContext.pendingLimit)
        XCTAssertEqual((obj["lastTurnSummary"] as? String)?.count, AssistantContext.summaryLimit)
    }

    func testResidentMessages() {
        let message = AssistantPrompt.residentUtterance(utterance: "切到 poems 那个", events: ["typed \"x\" into poems"],
                                                        contextJSON: nil)
        XCTAssertEqual(message, "[UTTERANCE]\nEvents: typed \"x\" into poems\nUtterance: 切到 poems 那个\nContext: unchanged")
        let withContext = AssistantPrompt.residentUtterance(utterance: "u", events: [], contextJSON: context().json())
        XCTAssertTrue(withContext.contains("Context: {"))
        XCTAssertFalse(withContext.contains("Events"))
        let summary = AssistantPrompt.residentSummary(title: "t", digest: "RUN: swift test", language: "en")
        XCTAssertTrue(summary.hasPrefix("[SUMMARIZE] uiLanguage=en\n"))
        XCTAssertTrue(summary.hasSuffix("RUN: swift test"))
    }

    func testResidentSystemPromptMentionsToolsNotJSONActions() {
        let prompt = AssistantPrompt.residentSystem
        for tool in ["type_text", "press_key", "respond_approval", "read_transcript", "read_screen", "clear_input"] {
            XCTAssertTrue(prompt.contains(tool), tool)
            XCTAssertNotNil(AssistantTools.spec(named: tool), tool)
        }
        XCTAssertTrue(prompt.contains("[SUMMARIZE]"))
        XCTAssertFalse(prompt.contains("\"action\""))
    }

    func testSpokenTextIsCleaned() {
        XCTAssertEqual(AssistantSpeech.clean("**好的**\n切过去了"), "好的 切过去了")
        XCTAssertEqual(AssistantSpeech.clean("```swift\nx\n```\n它改了 `a.swift`。"), "它改了 a.swift。")
        XCTAssertEqual(AssistantSpeech.clean(String(repeating: "啊", count: 300))?.count, 160)
        XCTAssertNil(AssistantSpeech.clean("  \n "))
    }

    // MARK: 输出信封

    func testEnvelopeParsesResultAndUsage() {
        let out = #"{"type":"result","is_error":false,"result":"```json\n{}\n```","usage":{"input_tokens":2460,"cache_read_input_tokens":40,"output_tokens":265}}"#
        let env = AssistantEnvelope.parse("warning: something\n" + out)
        XCTAssertEqual(env, AssistantEnvelope(result: "```json\n{}\n```", inputTokens: 2500, outputTokens: 265))
        XCTAssertNil(AssistantEnvelope.parse(#"{"type":"result","is_error":true,"result":"boom"}"#))
        XCTAssertEqual(env?.contextTokens, 2500)
        XCTAssertNil(AssistantEnvelope.parse("garbage"))
    }

    func testEnvelopeContextTokensComeFromLastIteration() {
        let out = #"{"result":"好","type":"result","usage":{"input_tokens":10,"cache_read_input_tokens":30000,"output_tokens":40,"iterations":[{"input_tokens":4,"cache_read_input_tokens":14000},{"input_tokens":6,"cache_read_input_tokens":15990,"cache_creation_input_tokens":10}]}}"#
        let env = AssistantEnvelope.parse(out)
        XCTAssertEqual(env?.inputTokens, 30010)
        XCTAssertEqual(env?.contextTokens, 16006)
    }

    func testTurnTextKeepsOnlyWordsAfterLastToolCall() throws {
        var turn = AssistantTurnText()
        let lines = [
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"我来看看。"},{"type":"tool_use","name":"mcp__ccdesk__read_transcript","input":{}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"{\"type\":\"assistant\"}"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"它在修两个排序测试。"}]}}"#,
        ]
        for line in lines { turn.consume(try XCTUnwrap(JSONValue.parse(line))) }
        XCTAssertEqual(turn.spoken(result: "我来看看。\n\n它在修两个排序测试。"), "它在修两个排序测试。")
        // 没有工具调用之后的文字时退回 result。
        var silent = AssistantTurnText()
        silent.consume(try XCTUnwrap(JSONValue.parse(lines[0])))
        XCTAssertEqual(silent.spoken(result: "好了"), "好了")
    }

    // MARK: 本地回答

    func testWaitingQuestionDetection() {
        for s in ["哪些在等我", "有哪些在等我？", "嗯，谁在等我呀", "What's waiting for me?"] {
            XCTAssertTrue(AssistantLocal.isWaitingQuestion(s), s)
        }
        for s in ["等我一下", "帮我把等待逻辑改一下", "发了吧"] {
            XCTAssertFalse(AssistantLocal.isWaitingQuestion(s), s)
        }
    }

    func testWaitingAnswer() {
        XCTAssertEqual(AssistantLocal.waitingAnswer(sessions: context().sessions), "没有会话在等你")
        XCTAssertEqual(AssistantLocal.waitingAnswer(sessions: context(selectedWaiting: true).sessions), "中国诗歌视频课程在等你")
        let many = context(selectedWaiting: true).sessions + [
            AssistantSessionInfo(rowID: "r", title: "另一个", dir: "d", agent: .pi, status: .waiting(nil), isSelected: false),
        ]
        XCTAssertEqual(AssistantLocal.waitingAnswer(sessions: many), "2 个在等你：中国诗歌视频课程、另一个")
    }

    // MARK: 会话列表

    func testListQuestionAnsweredLocally() {
        XCTAssertTrue(AssistantLocal.isListQuestion("现在有哪些会话？"))
        XCTAssertTrue(AssistantLocal.isListQuestion("帮我列出会话"))
        XCTAssertFalse(AssistantLocal.isListQuestion("它刚才改了哪些文件"))
        XCTAssertEqual(AssistantLocal.listAnswer(sessions: context().sessions), "共 2 个会话：poems空闲、herdr在处理")
        XCTAssertEqual(AssistantLocal.listAnswer(sessions: []), "现在没有会话")
    }

    func testRelayContent() {
        XCTAssertEqual(AssistantLocal.relayContent("你问他一下有没有开发完成。"), "有没有开发完成。")
        XCTAssertEqual(AssistantLocal.relayContent("我说他在这个终端里面输入现在已经运行完了吗?"), "现在已经运行完了吗?")
        XCTAssertEqual(AssistantLocal.relayContent("跟它说，把测试跑一下"), "把测试跑一下")
        XCTAssertEqual(AssistantLocal.relayContent("让它继续"), "继续")
        XCTAssertNil(AssistantLocal.relayContent("帮我切到 poems 那个"))
        XCTAssertNil(AssistantLocal.relayContent("它刚才改了哪些文件"))
        XCTAssertNil(AssistantLocal.relayContent("问他"))
    }
}
