import XCTest
@testable import CCDeskCore

/// 真实 Unix socket 上的控制接口：服务端 + 客户端往返、异步回复、残留文件、单实例、权限。
final class ControlSocketTests: XCTestCase {
    private var dir: URL!
    private var path: String { dir.appendingPathComponent("c.sock").path }

    override func setUpWithError() throws {
        // sun_path 只有 104 字节：用短的临时目录。
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ccd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func echoServer(delay: TimeInterval = 0) -> ControlServer {
        ControlServer(path: path) { request, reply in
            let response: ControlResponse = request.method == "boom"
                ? ControlResponse(id: request.id, error: ControlError(.failed, "boom"))
                : ControlResponse(id: request.id, result: ["method": .string(request.method), "params": .object(request.params)])
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { reply(response) }
        }
    }

    func testRoundTripAndPermissions() throws {
        let server = echoServer()
        XCTAssertTrue(server.start())
        defer { server.stop() }
        let mode = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)
        let result = ControlClient.call(path: path, method: "type_text", params: ["text": "跑测试"], timeout: 2)
        XCTAssertEqual(try result.get()["method"], "type_text")
        XCTAssertEqual(try result.get()["params"]?["text"], "跑测试")
        XCTAssertEqual(ControlClient.call(path: path, method: "boom", params: [:], timeout: 2),
                       .failure(ControlError(.failed, "boom")))
    }

    func testDelayedReplyAndTimeout() {
        let server = echoServer(delay: 0.6)
        XCTAssertTrue(server.start())
        defer { server.stop() }
        XCTAssertNoThrow(try ControlClient.call(path: path, method: "close_session", params: [:], timeout: 3).get())
        guard case .failure(let error) = ControlClient.call(path: path, method: "slow", params: [:], timeout: 0.2) else {
            return XCTFail("expected timeout")
        }
        XCTAssertEqual(error.code, .timeout)
    }

    func testSingleOwnerAndStaleSocket() throws {
        let first = echoServer()
        XCTAssertTrue(first.start())
        XCTAssertFalse(echoServer().start(), "a live owner keeps the socket")
        XCTAssertTrue(ControlClient.isAlive(path: path))
        first.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))

        // 残留的 socket 文件（进程崩溃后没人监听）会被删掉重建。
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try XCTUnwrap(ControlClient.address(path))
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(ControlClient.isAlive(path: path))
        let second = echoServer()
        XCTAssertTrue(second.start())
        defer { second.stop() }
        XCTAssertNoThrow(try ControlClient.call(path: path, method: "list_sessions", params: [:], timeout: 2).get())
    }

    func testUnavailableWhenNobodyListens() {
        guard case .failure(let error) = ControlClient.call(path: path, method: "x", params: [:], timeout: 1) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(error.code, .unavailable)
    }

    func testMalformedLineGetsErrorAndConnectionStaysUsable() throws {
        let server = echoServer()
        XCTAssertTrue(server.start())
        defer { server.stop() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = try XCTUnwrap(ControlClient.address(path))
        let ok = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(ok, 0)
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let payload = Array("garbage\n{\"id\":9,\"method\":\"ping\"}\n".utf8)
        XCTAssertEqual(Darwin.write(fd, payload, payload.count), payload.count)
        var buffer = LineBuffer()
        var lines: [String] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while lines.count < 2 {
            let n = Darwin.read(fd, &chunk, chunk.count)
            guard n > 0 else { break }
            lines += buffer.append(Data(chunk[0..<n])).lines
        }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(ControlResponse.parse(lines[0])?.outcome, .failure(ControlError(.invalidRequest, "invalid JSON")))
        XCTAssertEqual(ControlResponse.parse(lines[1])?.id, 9)
    }

    /// MCP 请求 → 控制接口 → 处理 → 文字结果：`CCDesk --mcp` 里除 stdio 之外的整条路径。
    func testMCPToolCallThroughSocket() throws {
        let server = echoServer()
        XCTAssertTrue(server.start())
        defer { server.stop() }
        let socketPath = path
        var core = MCPServerCore { name, args in
            MCPServerCore.outcome(from: ControlClient.call(path: socketPath, method: name, params: args, timeout: 2))
        }
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"new_session","arguments":{"project":"herdr","agent":"codex"}}}"#
        let reply = try XCTUnwrap(JSONValue.parse(try XCTUnwrap(core.handle(line: line))))
        let text = try XCTUnwrap(reply["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertEqual(JSONValue.parse(text)?["params"]?["agent"], "codex")
        XCTAssertEqual(reply["result"]?["isError"], false)
        server.stop()
        let down = try XCTUnwrap(JSONValue.parse(try XCTUnwrap(core.handle(line: line))))
        XCTAssertEqual(down["result"]?["isError"], true)
    }
}
