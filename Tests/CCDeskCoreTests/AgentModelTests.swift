import XCTest
@testable import CCDeskCore

final class AgentModelTests: XCTestCase {
    // MARK: 合成样本（字段位置取自本机 Claude Code / codex-cli / pi 的真实记录，内容为虚构）

    private func data(_ lines: [String]) -> Data { Data(lines.joined(separator: "\n").utf8) }

    let claudeLines = [
        #"{"type":"user","message":{"role":"user","content":"hi"},"cwd":"/w"}"#,
        #"{"type":"assistant","effort":"high","message":{"model":"claude-opus-5-5","role":"assistant","content":[]}}"#,
        #"{"type":"assistant","effort":"medium","message":{"model":"claude-fable-5-1","role":"assistant","content":[]}}"#,
        #"{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[]}}"#,
        #"{"type":"assistant","message":{"model":"","role":"assistant","content":[]}}"#,
        #"{"type":"ai-title","aiTitle":"标题"}"#,
    ]

    let codexLines = [
        #"{"type":"session_meta","payload":{"session_id":"c1","cwd":"/w","model_provider":"custom","base_instructions":{"provenance":{"model":"x"}}}}"#,
        #"{"type":"turn_context","payload":{"cwd":"/w","model":"gpt-5.5","effort":"low"}}"#,
        #"{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"qwen/qwen3.8-27b:free","reasoning_effort":"high"}}}"#,
        #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"跑测试"}]}}"#,
    ]

    let piLines = [
        #"{"type":"session","version":3,"id":"p1","cwd":"/w"}"#,
        #"{"type":"model_change","provider":"openrouter","modelId":"qwen/qwen3.8-27b:free"}"#,
        #"{"type":"thinking_level_change","thinkingLevel":"medium"}"#,
        #"{"type":"message","message":{"role":"user","content":"hi"}}"#,
        #"{"type":"message","message":{"role":"assistant","provider":"anthropic","model":"claude-sonnet-5","content":[]}}"#,
    ]

    // MARK: 提取

    func testClaudeLatestAssistantModelWinsAndSyntheticIsSkipped() {
        let meta = TranscriptReader.meta(fromTail: data(claudeLines))
        XCTAssertEqual(meta.model, AgentModelInfo(id: "claude-fable-5-1", effort: "medium"))
        XCTAssertEqual(meta.aiTitle, "标题")
    }

    func testClaudeWithoutAssistantHasNoModel() {
        XCTAssertNil(TranscriptReader.meta(fromTail: data([claudeLines[0], claudeLines[3]])).model)
    }

    func testClaudeFallsBackToHeadWhenTailHasNoModel() {
        let meta = TranscriptReader.meta(fromTail: data([claudeLines[5]]), head: data(Array(claudeLines.prefix(2))))
        XCTAssertEqual(meta.model?.id, "claude-opus-5-5")
        // 尾部有模型时不看头部。
        let tailWins = TranscriptReader.meta(fromTail: data([claudeLines[2]]), head: data([claudeLines[1]]))
        XCTAssertEqual(tailWins.model?.id, "claude-fable-5-1")
    }

    func testCodexLatestModelWithEffortAndProviderFromHead() {
        let meta = AgentTranscriptReader.meta(kind: .codex, head: data(codexLines), tail: data(Array(codexLines.dropFirst())))
        XCTAssertEqual(meta.model, AgentModelInfo(id: "qwen/qwen3.8-27b:free", provider: "custom", effort: "high"))
        XCTAssertEqual(meta.lastPrompt, "跑测试")
    }

    func testCodexTurnContextAfterSettingsWins() {
        let lines = [codexLines[2], #"{"type":"turn_context","payload":{"model":"gpt-5.5","reasoning_effort":"xhigh"}}"#]
        let meta = AgentTranscriptReader.meta(kind: .codex, head: Data(), tail: data(lines))
        XCTAssertEqual(meta.model, AgentModelInfo(id: "gpt-5.5", effort: "xhigh"))
    }

    func testCodexSessionMetaAloneHasNoModel() {
        XCTAssertNil(AgentTranscriptReader.meta(kind: .codex, head: data([codexLines[0]]), tail: data([codexLines[0]])).model)
    }

    func testPiAssistantMessageAfterModelChangeWinsAndThinkingLevelComesFromHead() {
        let meta = AgentTranscriptReader.meta(kind: .pi, head: data(piLines), tail: data(Array(piLines.suffix(2))))
        XCTAssertEqual(meta.model, AgentModelInfo(id: "claude-sonnet-5", provider: "anthropic", effort: "medium"))
    }

    func testPiModelChangeOnly() {
        let lines = Array(piLines.prefix(3)) + [#"{"type":"thinking_level_change","thinkingLevel":"off"}"#]
        let meta = AgentTranscriptReader.meta(kind: .pi, head: data(lines), tail: data(lines))
        XCTAssertEqual(meta.model, AgentModelInfo(id: "qwen/qwen3.8-27b:free", provider: "openrouter", effort: nil))
    }

    func testPiFreshSessionHasNoModel() {
        XCTAssertNil(AgentTranscriptReader.meta(kind: .pi, head: data([piLines[0]]), tail: data([piLines[0]])).model)
    }

    // MARK: 显示

    func testClaudeFriendlyNames() {
        let cases = [
            "claude-opus-5-5": "Opus 5.5",
            "claude-sonnet-5": "Sonnet 5",
            "claude-fable-5-1": "Fable 5.1",
            "claude-haiku-4-5-20251001": "Haiku 4.5",
            "claude-opus-4-1-20250805": "Opus 4.1",
            "claude-3-5-sonnet-20241022": "Sonnet 3.5",
            "claude-opus-5-5[1m]": "Opus 5.5",
            "anthropic/claude-sonnet-4.5": "Sonnet 4.5",
        ]
        for (id, name) in cases {
            XCTAssertEqual(AgentModelFormat.claudeName(id), name, id)
            XCTAssertEqual(AgentModelInfo(id: id, effort: "medium").shortName, name, "Claude 短名不带 effort")
        }
    }

    func testUnknownIdsFallBackToRawOrLastComponent() {
        XCTAssertNil(AgentModelFormat.claudeName("claude-"))
        XCTAssertNil(AgentModelFormat.claudeName("claude-x2-1"))
        XCTAssertEqual(AgentModelInfo(id: "claude-x2-1").shortName, "claude-x2-1")
        XCTAssertEqual(AgentModelInfo(id: "gpt-5.5").shortName, "gpt-5.5")
        XCTAssertEqual(AgentModelInfo(id: "qwen/qwen3.8-27b:free", effort: "high").shortName, "qwen3.8-27b:free · high")
        XCTAssertEqual(AgentModelInfo(id: "a/").shortName, "a")
    }

    func testDetail() {
        XCTAssertEqual(AgentModelInfo(id: "claude-fable-5-1").detail, "claude-fable-5-1")
        XCTAssertEqual(AgentModelInfo(id: "qwen/q", provider: "openrouter", effort: "high").detail,
                       "qwen/q · effort high · openrouter")
    }
}
