import XCTest
import SQLite3
@testable import CCDeskCore

/// OpenCode 镜像：用临时 SQLite 库模拟 OpenCode 的 session / message / part 三张表（实测 opencode 1.18.35 的结构）。
final class OpenCodeMirrorTests: XCTestCase {
    private var dir: URL!
    private var dbURL: URL { dir.appendingPathComponent("opencode.db") }
    private var root: URL { dir.appendingPathComponent("mirror") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("oc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try exec("""
            CREATE TABLE session (id text PRIMARY KEY, project_id text, parent_id text, slug text, directory text,
              title text, version text, time_created integer, time_updated integer);
            CREATE TABLE message (id text PRIMARY KEY, session_id text, time_created integer, time_updated integer, data text);
            CREATE TABLE part (id text PRIMARY KEY, message_id text, session_id text, time_created integer,
              time_updated integer, data text);
            """)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func exec(_ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw NSError(domain: "sql", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }

    private func session(_ id: String, parent: String? = nil, title: String, updated: Int64) throws {
        try exec("INSERT OR REPLACE INTO session VALUES (\(q(id)), 'p', \(parent.map(q) ?? "NULL"), 's', '/proj', \(q(title)), '1', 1000, \(updated))")
    }

    private func message(_ id: String, session: String, created: Int64, _ data: String) throws {
        try exec("INSERT OR REPLACE INTO message VALUES (\(q(id)), \(q(session)), \(created), \(created), \(q(data)))")
    }

    private func part(_ id: String, message: String, session: String, _ data: String) throws {
        try exec("INSERT OR REPLACE INTO part VALUES (\(q(id)), \(q(message)), \(q(session)), 0, 0, \(q(data)))")
    }

    private func lines(_ sessionID: String) -> [[String: Any]] {
        let text = (try? String(contentsOf: root.appendingPathComponent("\(sessionID).jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { OpenCodeMirror.object(String($0)) }
    }

    func testMirrorsMessagesAsPiFormatAndWaitsForCompletion() throws {
        try session("ses_a", title: "New session - 2026-10-07T07:00:43.992Z", updated: 2000)
        try message("msg_1", session: "ses_a", created: 1100, #"{"role":"user","time":{"created":1100},"model":{"providerID":"opencode","modelID":"big-pickle"}}"#)
        try part("prt_1", message: "msg_1", session: "ses_a", #"{"type":"text","text":"write hello"}"#)
        try message("msg_2", session: "ses_a", created: 1200, #"{"role":"assistant","modelID":"big-pickle","providerID":"opencode","time":{"created":1200,"completed":1300},"tokens":{"input":10,"output":5,"reasoning":3,"cache":{"read":100,"write":0}}}"#)
        try part("prt_2", message: "msg_2", session: "ses_a", #"{"type":"tool","tool":"write","state":{"status":"completed","input":{"filePath":"/proj/hello.txt","content":"hi"}}}"#)
        try part("prt_3", message: "msg_2", session: "ses_a", #"{"type":"text","text":"Created /proj/hello.txt"}"#)
        // 还在生成的助手消息：不写，下次再看。
        try message("msg_3", session: "ses_a", created: 1400, #"{"role":"assistant","modelID":"big-pickle","time":{"created":1400}}"#)

        let mirror = OpenCodeMirror(database: dbURL, root: root)
        XCTAssertTrue(mirror.sync())
        var out = lines("ses_a")
        XCTAssertEqual(out.map { $0["type"] as? String }, ["session", "message", "message"])
        XCTAssertEqual(out[0]["cwd"] as? String, "/proj")
        let assistant = out[2]["message"] as? [String: Any]
        XCTAssertEqual(assistant?["model"] as? String, "big-pickle")
        let usage = assistant?["usage"] as? [String: Any]
        XCTAssertEqual(usage?["output"] as? Int, 8, "output 含推理")
        XCTAssertEqual(usage?["cacheRead"] as? Int, 100)
        let tool = (assistant?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(tool?["name"] as? String, "write")
        XCTAssertEqual((tool?["arguments"] as? [String: Any])?["path"] as? String, "/proj/hello.txt")

        // 现有的 pi 解析器能读镜像：会话头、改动的文件、token。
        let header = AgentTranscriptReader.header(kind: .opencode, head: Data(try String(contentsOf: root.appendingPathComponent("ses_a.jsonl"), encoding: .utf8).utf8))
        XCTAssertEqual(header?.sessionID, "ses_a")
        var parser = TokenUsageParser(kind: .opencode)
        XCTAssertEqual(parser.consume(OpenCodeMirror.object(OpenCodeMirror.json(out[2])) ?? [:])?.usage,
                       TokenUsage(input: 10, output: 8, cacheRead: 100))

        // 完成后再同步：只追加新完成的那条，并带上 OpenCode 生成的标题。
        try message("msg_3", session: "ses_a", created: 1400, #"{"role":"assistant","modelID":"big-pickle","time":{"created":1400,"completed":1500},"tokens":{"input":1,"output":1,"reasoning":0,"cache":{"read":0,"write":0}}}"#)
        try session("ses_a", title: "Writing hello", updated: 3000)
        XCTAssertTrue(mirror.sync())
        out = lines("ses_a")
        XCTAssertEqual(out.map { $0["type"] as? String }, ["session", "message", "message", "session_info", "message"])
        XCTAssertEqual(out[3]["name"] as? String, "Writing hello")
        // 没变化：不再写。
        XCTAssertFalse(mirror.sync())
    }

    func testChildSessionsGoIntoParentMirrorAndProgressSurvivesRestart() throws {
        try session("ses_p", title: "Parent", updated: 2000)
        try session("ses_c", parent: "ses_p", title: "Child session - x", updated: 2100)
        try message("m_c", session: "ses_c", created: 1500, #"{"role":"assistant","modelID":"m","time":{"created":1500,"completed":1600},"tokens":{"input":2,"output":2,"reasoning":0,"cache":{"read":0,"write":0}}}"#)
        try part("p_c", message: "m_c", session: "ses_c", #"{"type":"patch","files":["/proj/a.swift"]}"#)
        XCTAssertTrue(OpenCodeMirror(database: dbURL, root: root).sync())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ses_c.jsonl").path))
        let out = lines("ses_p")
        let edit = ((out.last?["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(edit?["name"] as? String, "edit")
        // 新的镜像实例（App 重启）读回进度，不重复追加。
        let count = out.count
        try session("ses_p", title: "Parent", updated: 5000)
        _ = OpenCodeMirror(database: dbURL, root: root).sync()
        XCTAssertEqual(lines("ses_p").count, count)
    }

    func testDefaultTitlesAreNotCustom() {
        XCTAssertNil(OpenCodeMirror.customTitle("New session - 2026-10-07T07:00:43.992Z"))
        XCTAssertNil(OpenCodeMirror.customTitle("  "))
        XCTAssertEqual(OpenCodeMirror.customTitle("Fix login"), "Fix login")
    }

    func testProcessMatchingAndResume() {
        func proc(_ argv: [String]) -> ProcInfo {
            ProcInfo(pid: 10, ppid: 1, tty: "ttys001", command: argv[0], args: argv.joined(separator: " "))
        }
        XCTAssertEqual(AgentProcessMatcher.kind(of: proc(["opencode"])), .opencode)
        XCTAssertEqual(AgentProcessMatcher.kind(of: proc(["opencode", "-m", "opencode/big-pickle"])), .opencode)
        XCTAssertNil(AgentProcessMatcher.kind(of: proc(["opencode", "serve"])))
        XCTAssertNil(AgentProcessMatcher.kind(of: proc(["opencode", "run", "hi"])))
        XCTAssertEqual(AgentProcessMatcher.sessionHint(kind: .opencode, argv: ["opencode", "--session", "ses_x"]), "ses_x")
        XCTAssertEqual(AgentProcessMatcher.sessionHint(kind: .opencode, argv: ["opencode", "-s", "ses_y"]), "ses_y")
        XCTAssertNil(AgentProcessMatcher.sessionHint(kind: .opencode, argv: ["opencode", "-s", "ses_y", "--fork"]))
        XCTAssertEqual(OpenCodeAdapter().resumeCommand(sessionID: "ses_x"), "opencode --session 'ses_x'")
        let adapter: AgentAdapter = OpenCodeAdapter()
        XCTAssertEqual(adapter.launchCommand(prompt: "fix it"), "opencode --prompt 'fix it'")
        XCTAssertNotNil(BundledManifests.openCode)
    }
}
