import XCTest
@testable import CCDeskCore

/// 接口后端的对话历史（设计 §22）：按整轮裁剪、结构校验、持久化（权限 0600 / 0700）与提示词版本。
final class AssistantChatHistoryTests: XCTestCase {
    private func turn(_ n: Int, tool: Bool = false, size: Int = 10) -> [ChatMessage] {
        let user = ChatMessage.user("u\(n) " + String(repeating: "x", count: size))
        guard tool else { return [user, ChatMessage(role: "assistant", content: "a\(n)")] }
        let call = ChatToolCall(id: "c\(n)", name: "list_sessions", arguments: "{}")
        return [user, ChatMessage(role: "assistant", content: "", toolCalls: [call]), .tool(id: "c\(n)", "r\(n)"),
                ChatMessage(role: "assistant", content: "a\(n)")]
    }

    func testTrimDropsWholeOldestTurns() {
        var history = AssistantChatHistory(promptVersion: 5)
        XCTAssertFalse(history.append(turn(1, tool: true), maxChars: 1000, maxTurns: 3))
        XCTAssertFalse(history.append(turn(2), maxChars: 1000, maxTurns: 3))
        XCTAssertFalse(history.append(turn(3, tool: true), maxChars: 1000, maxTurns: 3))
        XCTAssertTrue(history.append(turn(4), maxChars: 1000, maxTurns: 3))
        XCTAssertEqual(history.turnCount, 3)
        XCTAssertEqual(history.messages.first?.content?.hasPrefix("u2"), true)
        XCTAssertEqual(history.messages.first?.role, "user", "never starts with an orphaned tool result")

        // 按大小：一轮很大时把之前的都丢掉，但至少留下最新的一轮。
        XCTAssertTrue(history.append(turn(5, size: 5000), maxChars: 1000, maxTurns: 10))
        XCTAssertEqual(history.turnCount, 1)
        XCTAssertEqual(history.messages.first?.content?.hasPrefix("u5"), true)
    }

    func testIncompleteTurnsAreDropped() {
        let dangling = [ChatMessage.user("u1"),
                        ChatMessage(role: "assistant", content: "",
                                    toolCalls: [ChatToolCall(id: "x", name: "list_sessions", arguments: "{}")])]
        let wrongID = [ChatMessage.user("u2"),
                       ChatMessage(role: "assistant", content: "",
                                   toolCalls: [ChatToolCall(id: "y", name: "list_sessions", arguments: "{}")]),
                       ChatMessage.tool(id: "z", "r"), ChatMessage(role: "assistant", content: "a")]
        let orphan = [ChatMessage.tool(id: "q", "r"), ChatMessage(role: "assistant", content: "a")]
        let history = AssistantChatHistory(promptVersion: 1, messages: orphan + dangling + wrongID + turn(3, tool: true))
        XCTAssertEqual(history.turnCount, 1)
        XCTAssertEqual(history.messages.first?.content, turn(3, tool: true).first?.content)
    }

    func testStoreRoundTripPermissionsAndVersion() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ccdesk-history-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let store = AssistantChatHistoryStore(url: root.appendingPathComponent("assistant/api-history.json"))
        XCTAssertEqual(store.load(promptVersion: 5).turnCount, 0, "missing file = empty history")

        var history = AssistantChatHistory(promptVersion: 5)
        history.append(turn(1, tool: true))
        history.append(turn(2))
        try store.save(history)
        let mode = { (path: String) in ((try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? Int) ?? -1 }
        XCTAssertEqual(mode(store.url.path), 0o600)
        XCTAssertEqual(mode(store.url.deletingLastPathComponent().path), 0o700)
        XCTAssertEqual(store.load(promptVersion: 5), history)
        XCTAssertEqual(store.load(promptVersion: 6).turnCount, 0, "a new prompt version starts over")
        let leftovers = try fm.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["api-history.json"], "no temporary files left behind")

        try Data("garbage".utf8).write(to: store.url)
        XCTAssertEqual(store.load(promptVersion: 5).turnCount, 0)
        store.remove()
        XCTAssertFalse(fm.fileExists(atPath: store.url.path))
    }
}
