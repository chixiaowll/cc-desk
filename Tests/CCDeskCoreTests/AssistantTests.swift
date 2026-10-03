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
        XCTAssertEqual(sessions[0]["isSelected"] as? Bool, true)
        XCTAssertEqual(sessions[1]["id"] as? String, "s2")
        XCTAssertEqual(sessions[1]["status"] as? String, "working")
        XCTAssertNil(sessions[1]["waitingFor"])
        XCTAssertEqual((obj["history"] as? [[String: Any]])?.first?["id"] as? String, "h1")
        XCTAssertEqual((obj["projects"] as? [[String: Any]])?.last?["path"] as? String, "/Users/u/herdr")
        XCTAssertEqual(obj["pendingText"] as? String, "帮我改一下")
        XCTAssertEqual(obj["uiLanguage"] as? String, "zh-Hans")
        XCTAssertNil(obj["lastTurnSummary"])
        // 真实行 id 不暴露给模型。
        XCTAssertFalse(context().json().contains("term:A"))
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
        XCTAssertEqual(ctx.projects.count, 1)
        let obj = try object(ctx.json())
        let title = try XCTUnwrap((obj["sessions"] as? [[String: Any]])?.first?["title"] as? String)
        XCTAssertEqual(title.count, AssistantContext.titleLimit)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertFalse(title.contains("\n"))
        XCTAssertEqual((obj["pendingText"] as? String)?.count, AssistantContext.pendingLimit)
        XCTAssertEqual((obj["lastTurnSummary"] as? String)?.count, AssistantContext.summaryLimit)
    }

    func testIntentMessageContainsUtteranceAndContext() {
        let message = AssistantPrompt.intentMessage(utterance: "切到 poems 那个", context: context())
        XCTAssertTrue(message.hasPrefix("Utterance: 切到 poems 那个\nContext: {"))
        XCTAssertTrue(message.contains("\"s2\""))
        XCTAssertTrue(AssistantPrompt.intentSystem.contains("\"action\""))
    }

    func testSummaryAndQueryPromptsFollowLanguage() {
        XCTAssertTrue(AssistantPrompt.summarySystem(language: "zh-Hans").contains("Simplified Chinese"))
        XCTAssertTrue(AssistantPrompt.querySystem(language: "en").contains("English"))
        let q = AssistantPrompt.queryMessage(question: "测试过了吗", title: "t", status: .working, digest: "RUN: swift test")
        XCTAssertTrue(q.contains("status: working"))
        XCTAssertTrue(q.hasSuffix("RUN: swift test"))
    }

    // MARK: 模型输出

    func testParsesFencedJSON() {
        let text = "```json\n{\"action\":\"switch\",\"args\":{\"session_id\":\"s2\"},\"speak\":\"好的，切过去了\"}\n```"
        let d = AssistantResponse.decide(modelText: text, utterance: "切到 herdr", context: context())
        XCTAssertEqual(d, AssistantDecision(command: .switchTo(rowID: "term:B"), speak: "好的，切过去了"))
    }

    func testToleratesProseAroundJSON() {
        let text = "Here you go: {\"action\":\"send\",\"args\":{},\"speak\":\"发送了\"} done"
        XCTAssertEqual(AssistantResponse.decide(modelText: text, utterance: "发了吧", context: context()).command, .send)
    }

    func testBadJSONFallsBackToInsertOfUtterance() {
        for text in ["", "not json", "{\"action\":", "{\"action\":\"explode\",\"args\":{}}", "[1,2]"] {
            let d = AssistantResponse.decide(modelText: text, utterance: "帮我把这个函数改成异步的", context: context())
            XCTAssertEqual(d.command, .insert("帮我把这个函数改成异步的"), text)
            XCTAssertEqual(d.speak, "没听懂，已填入")
            XCTAssertTrue(d.isFallback)
        }
    }

    func testUnknownSessionIDFallsBack() {
        let text = #"{"action":"switch","args":{"session_id":"s9"},"speak":"好"}"#
        let d = AssistantResponse.decide(modelText: text, utterance: "切到那个", context: context())
        XCTAssertTrue(d.isFallback)
        XCTAssertEqual(d.command, .insert("切到那个"))
        let close = #"{"action":"close","args":{"session_id":"term:Z"},"speak":"好"}"#
        XCTAssertTrue(AssistantResponse.decide(modelText: close, utterance: "关掉", context: context()).isFallback)
        let query = #"{"action":"query","args":{"question":"q","session_id":"x"},"speak":""}"#
        XCTAssertTrue(AssistantResponse.decide(modelText: query, utterance: "q", context: context()).isFallback)
    }

    func testInsertUsesCleanedTextOrUtterance() {
        let a = #"{"action":"insert","args":{"text":"把这个函数改成异步的"},"speak":""}"#
        XCTAssertEqual(AssistantResponse.decide(modelText: a, utterance: "嗯把这个函数改成异步的", context: context()).command,
                       .insert("把这个函数改成异步的"))
        let b = #"{"action":"insert","args":{},"speak":""}"#
        XCTAssertEqual(AssistantResponse.decide(modelText: b, utterance: "原话", context: context()).command, .insert("原话"))
    }

    func testApproveOnlyWhenSelectedIsWaiting() {
        let text = #"{"action":"approve","args":{},"speak":"已同意"}"#
        XCTAssertEqual(AssistantResponse.decide(modelText: text, utterance: "让它继续", context: context(selectedWaiting: true)).command,
                       .approve)
        let d = AssistantResponse.decide(modelText: text, utterance: "让它继续", context: context())
        XCTAssertTrue(d.isFallback)
        XCTAssertEqual(d.command, .insert("让它继续"))
    }

    func testCloseDefaultsToSelected() {
        let text = #"{"action":"close","args":{},"speak":"确认关闭吗？"}"#
        XCTAssertEqual(AssistantResponse.decide(modelText: text, utterance: "关掉这个", context: context()).command,
                       .close(rowID: "term:A"))
    }

    func testNewValidatesProjectAndAgent() {
        let ok = #"{"action":"new","args":{"dir":"/Users/u/herdr","agent":"codex"},"speak":"好的"}"#
        XCTAssertEqual(AssistantResponse.decide(modelText: ok, utterance: "u", context: context()).command,
                       .new(dir: "/Users/u/herdr", agent: .codex))
        let byName = #"{"action":"new","args":{"dir":"HERDR","agent":"gpt"},"speak":""}"#
        XCTAssertEqual(AssistantResponse.decide(modelText: byName, utterance: "u", context: context()).command,
                       .new(dir: "/Users/u/herdr", agent: .claude))
        let missingDir = #"{"action":"new","args":{"agent":"pi"},"speak":""}"#
        XCTAssertEqual(AssistantResponse.decide(modelText: missingDir, utterance: "u", context: context()).command,
                       .new(dir: "/Users/u/poems", agent: .pi))
        let unknown = #"{"action":"new","args":{"dir":"/etc","agent":"claude"},"speak":""}"#
        XCTAssertTrue(AssistantResponse.decide(modelText: unknown, utterance: "u", context: context()).isFallback)
    }

    func testResumeByIDOrQuery() {
        let byID = #"{"action":"resume","args":{"history_session_id":"h1"},"speak":"好"}"#
        XCTAssertEqual(AssistantResponse.decide(modelText: byID, utterance: "u", context: context()).command,
                       .resume(sessionID: "hist-1"))
        let byQuery = #"{"action":"resume","args":{"query":"旅行攻略"},"speak":"好"}"#
        XCTAssertEqual(AssistantResponse.decide(modelText: byQuery, utterance: "u", context: context()).command,
                       .resume(sessionID: "hist-1"))
        let none = #"{"action":"resume","args":{"query":"不存在"},"speak":"好"}"#
        let d = AssistantResponse.decide(modelText: none, utterance: "u", context: context())
        XCTAssertEqual(d.command, .none)
        XCTAssertEqual(d.speak, "没找到匹配的历史会话")
    }

    func testQueryDefaultsToSelectedSession() {
        let text = #"{"action":"query","args":{"question":"刚才改了哪些文件"},"speak":""}"#
        XCTAssertEqual(AssistantResponse.decide(modelText: text, utterance: "u", context: context()).command,
                       .query(question: "刚才改了哪些文件", rowID: "term:A"))
        let named = #"{"action":"query","args":{"question":"它在干嘛","session_id":"s2"},"speak":""}"#
        XCTAssertEqual(AssistantResponse.decide(modelText: named, utterance: "u", context: context()).command,
                       .query(question: "它在干嘛", rowID: "term:B"))
    }

    func testSpeakIsCleanedAndCapped() {
        XCTAssertEqual(AssistantResponse.cleanSpeak("**好的**\n切过去了"), "好的 切过去了")
        XCTAssertEqual(AssistantResponse.cleanSpeak(String(repeating: "啊", count: 100)).count, AssistantResponse.speakLimit)
        XCTAssertEqual(AssistantResponse.cleanSpokenAnswer("```swift\nx\n```\n它改了 `a.swift`。"), "它改了 a.swift。")
        XCTAssertNil(AssistantResponse.cleanSpokenAnswer("  \n "))
    }

    // MARK: 输出信封

    func testEnvelopeParsesResultAndUsage() {
        let out = #"{"type":"result","is_error":false,"result":"```json\n{}\n```","usage":{"input_tokens":2460,"cache_read_input_tokens":40,"output_tokens":265}}"#
        let env = AssistantEnvelope.parse("warning: something\n" + out)
        XCTAssertEqual(env, AssistantEnvelope(result: "```json\n{}\n```", inputTokens: 2500, outputTokens: 265))
        XCTAssertNil(AssistantEnvelope.parse(#"{"type":"result","is_error":true,"result":"boom"}"#))
        XCTAssertNil(AssistantEnvelope.parse("garbage"))
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
}
