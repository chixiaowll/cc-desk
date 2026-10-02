import AppKit
import CCDeskCore

/// 外部会话的宿主 App：从进程链推出 `.app` 路径，并加载、缓存其图标。只在主线程使用图标缓存。
enum HostApps {
    /// 沿祖先进程由近到远，找第一个位于 `*.app/Contents/` 下的命令，返回最外层 `.app` 的路径
    /// （例如 VS Code 的 "Code Helper.app" 嵌在 "Visual Studio Code.app" 里，取后者）。
    static func bundlePath(ofPID pid: Int32, processes: ProcessTable) -> String? {
        for ancestor in processes.ancestors(of: pid) {
            guard ancestor.command.contains(".app/Contents/MacOS/"),
                  let range = ancestor.command.range(of: ".app/") else { continue }
            return String(ancestor.command[..<range.lowerBound]) + ".app"
        }
        return nil
    }

    /// 外部会话的宿主 App 路径；进程链里找不到时，Terminal / VS Code 按 bundle id 兜底。
    static func bundlePath(for session: AgentSession, processes: ProcessTable) -> String? {
        switch session.host {
        case .terminalApp, .vscode, .other:
            if let pid = session.pid, let path = bundlePath(ofPID: pid, processes: processes) { return path }
            return nil
        case .embedded, .missing:
            return nil
        }
    }

    static func fallbackBundleID(for host: SessionHost) -> String? {
        switch host {
        case .terminalApp: return "com.apple.Terminal"
        case .vscode: return "com.microsoft.VSCode"
        default: return nil
        }
    }

    private static var iconCache: [String: NSImage] = [:]
    private static var bundleURLCache: [String: String?] = [:]

    /// 宿主 App 图标；按路径缓存。
    static func icon(appPath: String?, host: SessionHost) -> NSImage? {
        var path = appPath
        if path == nil, let bundleID = fallbackBundleID(for: host) {
            if let cached = bundleURLCache[bundleID] {
                path = cached
            } else {
                let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
                bundleURLCache[bundleID] = resolved
                path = resolved
            }
        }
        guard let path else { return nil }
        if let cached = iconCache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = image
        return image
    }
}
