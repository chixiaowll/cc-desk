import XCTest
@testable import CCDeskCore

final class ProcArgsTests: XCTestCase {
    private func buffer(argc: Int32, exec: String, padding: Int = 3, strings: [String]) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc) { Array($0) }
        bytes += Array(exec.utf8) + [UInt8](repeating: 0, count: padding)
        for s in strings { bytes += Array(s.utf8) + [0] }
        return bytes
    }

    func testParsesExecPathArgvAndIgnoresEnvironment() throws {
        let raw = buffer(argc: 3, exec: "/opt/homebrew/bin/codex",
                         strings: ["node", "/opt/homebrew/bin/codex", "resume", "PATH=/usr/bin", "HOME=/x"])
        let parsed = try XCTUnwrap(ProcArgs.parse(raw))
        XCTAssertEqual(parsed.execPath, "/opt/homebrew/bin/codex")
        XCTAssertEqual(parsed.argv, ["node", "/opt/homebrew/bin/codex", "resume"])
        XCTAssertEqual(parsed.command, "node")
        XCTAssertEqual(parsed.args, "node /opt/homebrew/bin/codex resume")
    }

    /// node 改 process.title 后 argv 区域被 "pi" 加若干 \0 覆盖：每个 \0 都算一个（空）参数，不吃进环境变量。
    func testOverwrittenTitleKeepsEmptyArguments() throws {
        let raw = buffer(argc: 3, exec: "/opt/homebrew/bin/node", strings: ["pi", "", "", "TERM=xterm"])
        let parsed = try XCTUnwrap(ProcArgs.parse(raw))
        XCTAssertEqual(parsed.argv, ["pi", "", ""])
        XCTAssertEqual(parsed.command, "pi")
        XCTAssertEqual(parsed.args, "pi")
    }

    func testEmptyArgv0FallsBackToExecPath() throws {
        let parsed = try XCTUnwrap(ProcArgs.parse(buffer(argc: 1, exec: "/bin/zsh", strings: [""])))
        XCTAssertEqual(parsed.command, "/bin/zsh")
        XCTAssertNil(parsed.args)
    }

    func testTruncatedBufferDropsUnterminatedArgument() throws {
        var raw = buffer(argc: 2, exec: "/bin/sh", strings: ["sh"])
        raw += Array("-c tr".utf8)
        let parsed = try XCTUnwrap(ProcArgs.parse(raw))
        XCTAssertEqual(parsed.argv, ["sh"])
    }

    func testRejectsTooShortBuffer() {
        XCTAssertNil(ProcArgs.parse([1, 0]))
    }

    func testControlCharactersAreEscapedLikePs() {
        let parsed = ProcArgs.Parsed(execPath: "/bin/zsh", argv: ["/bin/zsh", "-c", "echo 中文\nexec \\x\t1"])
        XCTAssertEqual(parsed.args, "/bin/zsh -c echo 中文\\012exec \\x\\0111")
    }

    func testCommandKeyRefreshPolicy() {
        let start = Date(timeIntervalSince1970: 1_000)
        let key = ProcessCommandKey(startSec: 1_000, startUsec: 0, shortName: "node")
        // 新进程：没有缓存。
        XCTAssertTrue(key.needsRefresh(cached: nil, now: start.addingTimeInterval(60)))
        // 刚启动（可能还会改标题）：每次重读。
        XCTAssertTrue(key.needsRefresh(cached: key, now: start.addingTimeInterval(2)))
        // 稳定之后命中缓存。
        XCTAssertFalse(key.needsRefresh(cached: key, now: start.addingTimeInterval(ProcessCommandKey.settleAge + 1)))
        // pid 复用（启动时间不同）或 exec（短名不同）：重读。
        let reused = ProcessCommandKey(startSec: 2_000, startUsec: 0, shortName: "node")
        XCTAssertTrue(reused.needsRefresh(cached: key, now: start.addingTimeInterval(5_000)))
        let execd = ProcessCommandKey(startSec: 1_000, startUsec: 0, shortName: "claude")
        XCTAssertTrue(execd.needsRefresh(cached: key, now: start.addingTimeInterval(60)))
    }

    /// 本机实际读取：自己的进程一定在表里，命令行可读；与 ProcessDetails 的启动时间一致。
    func testNativeReaderSeesOwnProcess() throws {
        let reader = NativeProcessReader()
        let table = try XCTUnwrap(reader.table())
        let me = try XCTUnwrap(table.byPID[getpid()])
        XCTAssertEqual(me.ppid, getppid())
        XCTAssertFalse(me.command.isEmpty)
        XCTAssertNotNil(me.args)
        XCTAssertNil(table.byPID[0], "ps -ax 不列出 pid 0")
        // 第二次命中缓存，结果相同。
        XCTAssertEqual(reader.table()?.byPID[getpid()], me)
    }
}
