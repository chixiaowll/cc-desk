import XCTest
@testable import CCDeskCore

final class TurnDigestTests: XCTestCase {
    private func data(_ lines: [[String: Any]]) -> Data {
        let text = lines.map { obj -> String in
            let d = try! JSONSerialization.data(withJSONObject: obj)
            return String(data: d, encoding: .utf8)!
        }.joined(separator: "\n")
        return Data(text.utf8)
    }

    func testClaudeExtractsTextToolsAndResults() {
        let tail = Data("{\"truncated\":".utf8) + Data("\n".utf8) + data([
            ["type": "user", "message": ["role": "user", "content": "把排序改成按时间"]],
            ["type": "user", "isMeta": true, "message": ["role": "user", "content": "meta"]],
            ["type": "user", "message": ["role": "user", "content": "<command-name>/clear</command-name>"]],
            ["type": "assistant", "message": ["role": "assistant", "content": [
                ["type": "thinking", "thinking": "secret"],
                ["type": "text", "text": "我来改一下。"],
                ["type": "tool_use", "id": "1", "name": "Edit", "input": ["file_path": "/r/Sidebar.swift", "old_string": "a"]],
                ["type": "tool_use", "id": "2", "name": "Bash", "input": ["command": "swift test"]],
                ["type": "tool_use", "id": "3", "name": "Grep", "input": ["pattern": "rank"]],
            ]]],
            ["type": "user", "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "2", "content": "Executed 12 tests, with 1 failure", "is_error": true],
                ["type": "tool_result", "tool_use_id": "3", "content": [["type": "text", "text": "found"]]],
            ]]],
            ["type": "assistant", "isSidechain": true, "message": ["role": "assistant", "content": [["type": "text", "text": "sub"]]]],
            ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "测试有一个失败。"]]]],
            ["type": "last-prompt", "lastPrompt": "x"],
        ])
        XCTAssertEqual(TurnDigest.entries(kind: .claude, tail: tail), [
            .user("把排序改成按时间"),
            .assistant("我来改一下。"),
            .edit("/r/Sidebar.swift"),
            .command("swift test"),
            .tool("Grep rank"),
            .output("Executed 12 tests, with 1 failure", isError: true),
            .output("found", isError: false),
            .assistant("测试有一个失败。"),
        ])
    }

    func testCodexExtractsMessagesCallsAndPatches() {
        let patch = "*** Begin Patch\n*** Update File: src/a.rs\n@@\n-x\n+y\n*** Add File: src/b.rs\n+z\n*** End Patch"
        let tail = data([
            ["type": "session_meta", "payload": ["id": "x", "cwd": "/r"]],
            ["type": "response_item", "payload": ["type": "message", "role": "developer", "content": [["type": "input_text", "text": "dev"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [
                ["type": "input_text", "text": "<environment_context>..</environment_context>"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "跑一下测试"]]]],
            ["type": "response_item", "payload": ["type": "reasoning", "content": [["type": "text", "text": "think"]]]],
            ["type": "response_item", "payload": ["type": "function_call", "name": "exec_command", "arguments": "{\"cmd\":\"cargo test\"}", "call_id": "c1"]],
            ["type": "response_item", "payload": ["type": "function_call_output", "call_id": "c1", "output": "test result: ok. 3 passed"]],
            ["type": "response_item", "payload": ["type": "function_call", "name": "shell",
                                                  "arguments": "{\"command\":[\"bash\",\"-lc\",\"ls -la\"]}", "call_id": "c2"]],
            ["type": "response_item", "payload": ["type": "function_call_output", "call_id": "c2",
                                                  "output": "{\"output\":\"denied\",\"metadata\":{\"exit_code\":1}}"]],
            ["type": "response_item", "payload": ["type": "custom_tool_call", "name": "apply_patch", "input": patch]],
            ["type": "event_msg", "payload": ["type": "agent_message", "message": "duplicate"]],
            ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "都通过了。"]]]],
        ])
        XCTAssertEqual(TurnDigest.entries(kind: .codex, tail: tail), [
            .user("跑一下测试"),
            .command("cargo test"),
            .output("test result: ok. 3 passed", isError: false),
            .command("ls -la"),
            .output("denied", isError: true),
            .edit("src/a.rs"),
            .edit("src/b.rs"),
            .assistant("都通过了。"),
        ])
    }

    func testPiExtractsMessagesToolCallsAndResults() {
        let tail = data([
            ["type": "session", "id": "p", "cwd": "/r"],
            ["type": "message", "message": ["role": "user", "content": [["type": "text", "text": "写个 hello"]]]],
            ["type": "message", "message": ["role": "assistant", "content": [
                ["type": "thinking", "thinking": "hmm"],
                ["type": "toolCall", "id": "t1", "name": "write", "arguments": ["path": "hello.py", "content": "print()"]],
                ["type": "toolCall", "id": "t2", "name": "bash", "arguments": ["command": "python hello.py"]],
            ]]],
            ["type": "message", "message": ["role": "toolResult", "toolCallId": "t2", "toolName": "bash",
                                            "content": [["type": "text", "text": "hello"]], "isError": false]],
            ["type": "message", "message": ["role": "assistant", "content": [["type": "text", "text": "完成了。"]]]],
        ])
        XCTAssertEqual(TurnDigest.entries(kind: .pi, tail: tail), [
            .user("写个 hello"),
            .edit("hello.py"),
            .command("python hello.py"),
            .output("hello", isError: false),
            .assistant("完成了。"),
        ])
    }

    func testRenderKeepsNewestEntriesWithinCap() {
        let entries: [DigestEntry] = (0..<500).map { .assistant("第\($0)条 " + String(repeating: "字", count: 50)) }
        let text = TurnDigest.render(entries, maxChars: 6000)
        XCTAssertLessThanOrEqual(text.count, 6000)
        XCTAssertTrue(text.hasSuffix(String(repeating: "字", count: 50)))
        XCTAssertTrue(text.components(separatedBy: "\n").last!.hasPrefix("ASSISTANT: 第499条"))
        XCTAssertFalse(text.contains("第0条"))
    }

    func testLinesAreSingleLineAndClipped() {
        let text = TurnDigest.render([.output(String(repeating: "x\n", count: 500), isError: false), .user("a\n\nb")])
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].count, "OUTPUT: ".count + 240)
        XCTAssertEqual(lines[1], "USER: a b")
    }

    func testLastTurnsStartsAtNthLastUserMessage() {
        let entries: [DigestEntry] = [.user("一"), .assistant("a"), .user("二"), .command("swift test"), .assistant("b"),
                                      .user("三"), .edit("x.swift")]
        XCTAssertEqual(TurnDigest.lastTurns(entries, turns: 1), [.user("三"), .edit("x.swift")])
        XCTAssertEqual(TurnDigest.lastTurns(entries, turns: 2).first, .user("二"))
        XCTAssertEqual(TurnDigest.lastTurns(entries, turns: 9), entries)
        XCTAssertEqual(TurnDigest.lastTurns([.assistant("only")], turns: 1), [.assistant("only")])
    }
}
