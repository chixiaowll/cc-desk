import Foundation
import Network
import CCDeskCore

/// `--assistant-api-selftest` 用的本机假 OpenAI 兼容服务（Network.framework，只听回环接口的随机端口）。
/// 每个连接读一个 HTTP/1.1 请求（按 Content-Length 读完正文），交给 `handler` 决定状态码、正文与延迟，回完即关闭连接。
final class MockChatServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
        var json: JSONValue? { JSONValue.parse(String(decoding: body, as: UTF8.self)) }
    }

    struct Response {
        var status: Int
        var body: String
        var delay: TimeInterval = 0
    }

    private let queue = DispatchQueue(label: "cc-desk.mock-chat")
    private let listener: NWListener
    private let handler: (Request) -> Response
    private(set) var port: UInt16 = 0

    init(handler: @escaping (Request) -> Response) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
        self.handler = handler
    }

    /// 启动并等到开始监听（最多 5 秒）；返回 `http://127.0.0.1:<port>/v1`。
    func start() -> URL? {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(connection, buffer: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else { return nil }
        self.port = port
        return URL(string: "http://127.0.0.1:\(port)/v1")
    }

    func stop() {
        listener.cancel()
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                let response = self.handler(request)
                self.queue.asyncAfter(deadline: .now() + response.delay) { Self.reply(connection, response) }
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    /// 完整的请求（头 + Content-Length 字节的正文）；还没收完时 nil。
    static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private static func reply(_ connection: NWConnection, _ response: Response) {
        let body = Data(response.body.utf8)
        let head = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Error")\r\n" +
            "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: 回复的写法

    static func text(_ s: String, prompt: Int = 100, completion: Int = 5) -> Response {
        let message: JSONValue = ["role": "assistant", "content": .string(s)]
        return Response(status: 200, body: envelope(message, finish: "stop", prompt: prompt, completion: completion))
    }

    static func toolCalls(_ calls: [(name: String, arguments: String)]) -> Response {
        let items: [JSONValue] = calls.enumerated().map { i, call in
            ["id": .string("call_\(i + 1)"), "type": "function",
             "function": ["name": .string(call.name), "arguments": .string(call.arguments)]]
        }
        let message: JSONValue = ["role": "assistant", "content": .null, "tool_calls": .array(items)]
        return Response(status: 200, body: envelope(message, finish: "tool_calls", prompt: 120, completion: 12))
    }

    private static func envelope(_ message: JSONValue, finish: String, prompt: Int, completion: Int) -> String {
        JSONValue.object([
            "id": "chatcmpl-mock", "object": "chat.completion", "model": "mock-model",
            "choices": [["index": 0, "message": message, "finish_reason": .string(finish)]],
            "usage": ["prompt_tokens": .number(Double(prompt)), "completion_tokens": .number(Double(completion))],
        ]).compact
    }
}
