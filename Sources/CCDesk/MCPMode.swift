import Foundation
import CCDeskCore

/// `CCDesk --mcp`：助手会话的 stdio MCP 工具服务器（设计 §13）。不启动界面；每个工具调用转发到控制接口，
/// 结果作为文字内容返回。stdout 只写 JSON-RPC 消息，诊断写 stderr。
enum MCPMode {
    /// 需确认的工具最多等 15 秒语音确认，留出余量。
    static let callTimeout: TimeInterval = 45

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let socket = ControlProtocol.socketPath()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        var core = MCPServerCore(version: version) { name, arguments in
            MCPServerCore.outcome(from: ControlClient.call(path: socket, method: name, params: arguments,
                                                           timeout: callTimeout))
        }
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = core.handle(line: line) {
                // claude 已退出（stdout 断开）时没必要继续。
                do { try FileHandle.standardOutput.write(contentsOf: Data((reply + "\n").utf8)) } catch { exit(0) }
            }
        }
        exit(0)
    }
}
