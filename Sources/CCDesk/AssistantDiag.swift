import Foundation

/// 语音助手诊断日志：~/.cc-desk/assistant-diag.txt（只记本机，超过 256KB 时清空重写）。
enum AssistantDiag {
    private static let queue = DispatchQueue(label: "cc-desk.assistant.diag")
    /// 测试模式（`--consult-test`）改写到临时目录，不碰正在运行的 App 的日志。只在启动时设置一次。
    static var url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cc-desk/assistant-diag.txt")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func log(_ message: @autoclosure () -> String) {
        let line = "\(formatter.string(from: Date())) \(message())\n"
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 256 * 1024 {
                try? fm.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
