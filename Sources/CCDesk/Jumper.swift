import AppKit
import CCDeskCore

enum Jumper {
    /// 成功找到并置前返回 true；脚本出错（如未授权自动化）或未找到返回 false。
    static func jumpToTerminalApp(tty: String) -> Bool {
        guard let source = JumpScript.terminalApp(tty: tty), let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return false }
        return result.booleanValue
    }

    /// 本机安装的 VS Code（未安装时为 nil）。
    static var vsCodeURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")
    }

    static func openInVSCode(cwd: String) {
        let url = URL(fileURLWithPath: cwd)
        guard let app = vsCodeURL else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// 用 VS Code 打开一个文件（未安装时用默认 App）。
    static func openInVSCode(file path: String) {
        openInVSCode(cwd: path)
    }
}
