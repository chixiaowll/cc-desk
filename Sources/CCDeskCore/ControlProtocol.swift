import Foundation

/// CC Desk 控制接口（设计 §13）：`~/.cc-desk/control.sock` 上的 JSON 行协议。
/// 请求 `{"id","method","params"}` → 响应 `{"id","result"}` 或 `{"id","error":{"code","message"}}`，每条一行。
public enum ControlProtocol {
    public static let socketEnvironmentKey = "CCDESK_CONTROL_SOCKET"
    /// 单行上限，防止异常客户端占满内存。
    public static let maxLineBytes = 1 << 20

    /// 控制接口路径：环境变量 `CCDESK_CONTROL_SOCKET` 优先（测试用），否则 `~/.cc-desk/control.sock`。
    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: String = NSHomeDirectory()) -> String {
        if let path = environment[socketEnvironmentKey], !path.isEmpty { return path }
        return (home as NSString).appendingPathComponent(".cc-desk/control.sock")
    }
}

public struct ControlRequest: Equatable, Sendable {
    public let id: JSONValue
    public let method: String
    public let params: [String: JSONValue]

    public init(id: JSONValue, method: String, params: [String: JSONValue] = [:]) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// 解析一行请求；无效时返回错误响应（id 能取到就带上）。
    public static func parse(_ line: String) -> Result<ControlRequest, ControlResponse> {
        guard let value = JSONValue.parse(line), let obj = value.objectValue else {
            return .failure(ControlResponse(id: .null, error: ControlError(.invalidRequest, "invalid JSON")))
        }
        let id = obj["id"] ?? .null
        guard let method = obj["method"]?.stringValue, !method.isEmpty else {
            return .failure(ControlResponse(id: id, error: ControlError(.invalidRequest, "missing method")))
        }
        let params: [String: JSONValue]
        switch obj["params"] {
        case nil, .null?: params = [:]
        case .object(let o)?: params = o
        default: return .failure(ControlResponse(id: id, error: ControlError(.invalidParams, "params must be an object")))
        }
        return .success(ControlRequest(id: id, method: method, params: params))
    }

    public var line: String {
        JSONValue.object(["id": id, "method": .string(method), "params": .object(params)]).compact
    }
}

public struct ControlError: Error, Equatable, Sendable {
    public enum Code: Int, Sendable {
        case invalidRequest = -32600
        case unknownMethod = -32601
        case invalidParams = -32602
        case failed = -32000
        case timeout = -32001
        case unavailable = -32002
    }

    public let code: Code
    public let message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    var json: JSONValue { ["code": .number(Double(code.rawValue)), "message": .string(message)] }
}

public struct ControlResponse: Error, Equatable, Sendable {
    public let id: JSONValue
    public let outcome: Result<JSONValue, ControlError>

    public init(id: JSONValue, result: JSONValue) {
        self.id = id
        outcome = .success(result)
    }

    public init(id: JSONValue, error: ControlError) {
        self.id = id
        outcome = .failure(error)
    }

    public init(id: JSONValue, outcome: Result<JSONValue, ControlError>) {
        self.id = id
        self.outcome = outcome
    }

    public var line: String {
        switch outcome {
        case .success(let result): return JSONValue.object(["id": id, "result": result]).compact
        case .failure(let error): return JSONValue.object(["id": id, "error": error.json]).compact
        }
    }

    public static func parse(_ line: String) -> ControlResponse? {
        guard let obj = JSONValue.parse(line)?.objectValue else { return nil }
        let id = obj["id"] ?? .null
        if let error = obj["error"]?.objectValue {
            let code = error["code"]?.intValue.flatMap(ControlError.Code.init(rawValue:)) ?? .failed
            return ControlResponse(id: id, error: ControlError(code, error["message"]?.stringValue ?? "error"))
        }
        guard let result = obj["result"] else { return nil }
        return ControlResponse(id: id, result: result)
    }
}

/// 按换行切分字节流（连接上的读缓冲）。
public struct LineBuffer: Sendable {
    private var data = Data()

    public init() {}

    /// 追加数据并取出所有完整的行（去掉行尾 \r）；超过上限的半行被丢弃并返回 overflow。
    public mutating func append(_ chunk: Data) -> (lines: [String], overflow: Bool) {
        data.append(chunk)
        var lines: [String] = []
        while let nl = data.firstIndex(of: 0x0A) {
            var lineData = data[data.startIndex..<nl]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            data.removeSubrange(data.startIndex...nl)
            if let line = String(data: lineData, encoding: .utf8), !line.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(line)
            }
        }
        if data.count > ControlProtocol.maxLineBytes {
            data = Data()
            return (lines, true)
        }
        return (lines, false)
    }
}
