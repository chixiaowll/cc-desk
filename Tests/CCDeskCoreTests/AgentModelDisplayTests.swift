import XCTest
@testable import CCDeskCore

/// 模型信息接到侧栏行 / 菜单栏菜单 / 助手会话列表。
final class AgentModelDisplayTests: ZhHansTestCase {
    private func session(_ kind: AgentKind = .claude, host: SessionHost = .vscode) -> AgentSession {
        AgentSession(id: "a", kind: kind, sessionID: kind.isAgent ? "a" : nil, pid: 1, tty: nil, cwd: "/r/poems",
                     name: "n", nameIsDerived: false, host: host, status: .idle, statusChangedAt: Date(timeIntervalSince1970: 0))
    }

    private func row(_ s: AgentSession, model: AgentModelInfo?) -> SidebarRow {
        SidebarBuilder.row(for: s, ref: ProjectRef(root: "/r/poems", branch: nil, cwd: "/r/poems"), groupTitle: "poems",
                           meta: TranscriptMeta(customTitle: "t", model: model))
    }

    func testRowCarriesModelLabelAndTooltip() {
        let r = row(session(), model: AgentModelInfo(id: "claude-fable-5-1", effort: "medium"))
        XCTAssertEqual(r.modelName, "Fable 5.1")
        XCTAssertEqual(r.agentModelLabel, "Claude · Fable 5.1")
        XCTAssertTrue(r.tooltip.contains("模型：claude-fable-5-1 · effort medium"), r.tooltip)
        XCTAssertEqual(StatusMenu.entry(for: r).detail, "空闲 · Claude · Fable 5.1")
    }

    func testRowWithoutModelShowsAgentOnly() {
        let r = row(session(), model: nil)
        XCTAssertNil(r.modelName)
        XCTAssertEqual(r.agentModelLabel, "Claude")
        XCTAssertFalse(r.tooltip.contains("模型"))
        XCTAssertEqual(StatusMenu.entry(for: r).detail, "空闲 · Claude")
    }

    func testPlainShellNeverShowsModel() {
        let r = row(session(.other, host: .embedded(terminalID: UUID())), model: AgentModelInfo(id: "x"))
        XCTAssertNil(r.model)
        XCTAssertNil(r.agentModelLabel)
    }

    func testAssistantSessionJSONIncludesModel() {
        let info = AssistantSessionInfo(rowID: "a", shortID: "s1", title: "t", dir: "poems", agent: .codex, status: .idle,
                                        isSelected: false, model: AgentModelInfo(id: "qwen/qwen3.8-27b:free", effort: "high"))
        guard case .object(let item) = info.json, case .object(let model)? = item["model"] else {
            return XCTFail("model missing")
        }
        XCTAssertEqual(model["name"], .string("qwen3.8-27b:free · high"))
        XCTAssertEqual(model["id"], .string("qwen/qwen3.8-27b:free"))
        let bare = AssistantSessionInfo(rowID: "b", title: "t", dir: "d", agent: .claude, status: .idle, isSelected: false)
        guard case .object(let plain) = bare.json else { return XCTFail() }
        XCTAssertNil(plain["model"])
    }
}
