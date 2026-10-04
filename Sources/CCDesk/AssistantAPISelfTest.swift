import Foundation
import CCDeskCore

/// `CCDesk --assistant-api-selftest`：不启动界面、不碰 App 偏好 / 钥匙串 / ~/.cc-desk，用本机假服务（`MockChatServer`）
/// 驱动 OpenAI 兼容接口后端（设计 §22）后退出。不调用任何真实的付费接口。
/// 1. [UTTERANCE] → 模型调用 list_sessions（假工具宿主，先过 `AssistantToolPolicy.check`，与 App 的工具入口相同）→ 最后的文字；
/// 2. [EVENT] 里模型要 type_text → 被拒绝、没有执行，拒绝说明交回模型；
/// 3. 参数不是 JSON → 错误结果交回模型；4. HTTP 500 → `.api("HTTP 500")`，历史不变；5. 超时后队列继续；
/// 6. 历史写盘（0600）、新实例读回、重置清空；7. Bearer 密钥；8. 测试连接与模型列表；9. 接口版顾问（项目外的文件读不到）；
/// 10. 没配置 → `.notInstalled`；11. 诊断日志里没有密钥与消息内容；12. 健壮性（`AssistantAPISelfTestRobustness`）：
/// 离谱的数字、按时超时、失败的一轮保留已执行的工具、FIFO、输出上限。最后（可选）本机 Ollama 有模型时测一次真实的工具调用。
enum AssistantAPISelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.dropFirst().first == "--assistant-api-selftest" else { return }
        RunLoop.main.perform { run() }
        RunLoop.main.run()
    }

    private static var failures = 0
    static let key = "test-key-\(UUID().uuidString.prefix(8))"

    private static func say(_ s: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((s + "\n").utf8))
    }

    private static func check(_ ok: Bool, _ what: String) {
        say((ok ? "PASS " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    private static func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// 假服务的脚本：按最后一条用户消息里的 SCENARIO 标记与有没有工具结果决定回复。
    static func respond(_ request: MockChatServer.Request) -> MockChatServer.Response {
        if request.method == "GET", request.path.hasSuffix("/models") {
            return .init(status: 200, body: #"{"object":"list","data":[{"id":"mock-b"},{"id":"mock-a"}]}"#)
        }
        guard request.method == "POST", request.path.hasSuffix("/chat/completions"), let body = request.json,
              let messages = body["messages"]?.arrayValue else { return .init(status: 404, body: "{}") }
        // 只看这一轮：最后一条用户消息与它之后的工具结果（之前的是历史）。
        let lastUser = messages.lastIndex { $0["role"] == "user" } ?? 0
        let user = messages.indices.contains(lastUser) ? messages[lastUser]["content"]?.stringValue ?? "" : ""
        let tools = messages[lastUser...].filter { $0["role"] == "tool" }.compactMap { $0["content"]?.stringValue }
        let toolNames = body["tools"]?.arrayValue?.compactMap { $0["function"]?["name"]?.stringValue } ?? []
        if toolNames == [AssistantAPIProbe.toolName] { return MockChatServer.toolCalls([("ping", #"{"value":"ok"}"#)]) }
        if messages.first?["content"]?.stringValue?.contains("senior advisor") == true {
            return AssistantAPISelfTestRobustness.consult(user: user, tools: tools) ?? consult(tools)
        }
        if let scripted = AssistantAPISelfTestRobustness.respond(user: user, tools: tools, messages: messages) {
            return scripted
        }
        if user.contains("SCENARIO http500") { return .init(status: 500, body: #"{"error":{"message":"boom"}}"#) }
        if user.contains("SCENARIO slow") { return .init(status: 200, body: MockChatServer.text("late").body, delay: 3) }
        if user.contains("SCENARIO auth") {
            return MockChatServer.text(request.headers["authorization"] == "Bearer \(key)" ? "AUTH_OK" : "AUTH_MISSING")
        }
        let first = tools.isEmpty
        if user.contains("SCENARIO list") {
            return first ? MockChatServer.toolCalls([("list_sessions", "{}")]) : MockChatServer.text("LIST_OK " + tools[0])
        }
        if user.contains("SCENARIO event") {
            return first ? MockChatServer.toolCalls([("type_text", #"{"text":"rm -rf /","submit":true}"#)])
                : MockChatServer.text("EVENT_RESULT " + tools[0])
        }
        if user.contains("SCENARIO malformed") {
            return first ? MockChatServer.toolCalls([("list_sessions", "{bad")]) : MockChatServer.text("MALFORMED " + tools[0])
        }
        return MockChatServer.text("HELLO")
    }

    /// 顾问：先读项目外的文件、项目里的 calc.py、搜索、git status；再按结果给结论。
    private static func consult(_ tools: [String]) -> MockChatServer.Response {
        guard tools.count >= 4 else {
            return MockChatServer.toolCalls([("read_file", #"{"path":"../outside-secret.txt"}"#),
                                             ("read_file", #"{"path":"calc.py"}"#),
                                             ("search", #"{"pattern":"return a - b"}"#), ("git_status", "{}")])
        }
        let ok = tools[0].contains("outside the project") && !tools[0].contains("TOP-SECRET") &&
            tools[1].contains("return a - b") && tools[2].contains("calc.py:2:") && tools[3].contains("calc.py")
        return MockChatServer.text((ok ? "结论：OK，add 用了减号。" : "结论：BAD") + "\n\n" + tools.joined(separator: "\n---\n"),
                                   prompt: 900, completion: 40)
    }

    private static func run() {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("ccdesk-api-selftest-\(UUID().uuidString.prefix(8))")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        AssistantDiag.url = root.appendingPathComponent("diag.txt")
        guard let server = try? MockChatServer(handler: respond), let base = server.start() else {
            check(false, "mock server started")
            return finish(root)
        }
        say("mock server: \(base.absoluteString)")
        AssistantAPISelfTestFlows.run(base: base, root: root, check: check, wait: wait)
        server.stop()
        finish(root)
    }

    private static func finish(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
        say(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
