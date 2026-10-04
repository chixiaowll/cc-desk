import Foundation

/// 「用默认 App 打开」（⇧⌘-点击路径、open_file、改动的文件面板）的安全规则：会直接运行的文件类型
/// （App、终端脚本、自动化流程、安装包…以及带可执行位的脚本 / 无扩展名程序）不打开，改为在访达里显示。
/// 这些文件可能是 agent（或它读到的内容）写出来的，打开 = 执行。
public enum FileOpenPolicy {
    /// 打开即运行 / 安装的扩展名（不看可执行位）。
    static let alwaysReveal: Set<String> = [
        "app", "command", "tool", "terminal", "workflow", "action", "pkg", "mpkg", "jar", "fileloc", "inetloc",
        "webloc", "osax", "prefpane", "saver", "qlgenerator", "kext", "systemextension",
    ]
    /// 有可执行位时默认 App 会运行它们（终端 / Python Launcher 等）。
    static let executableScripts: Set<String> = [
        "sh", "bash", "zsh", "csh", "tcsh", "ksh", "fish", "py", "pyw", "rb", "pl", "php", "js", "mjs", "lua", "tcl",
        "bin", "out", "run", "exe",
    ]

    /// true：不打开，改为在访达里显示。isExecutable：文件的可执行位（目录忽略）。
    public static func shouldReveal(path: String, isDirectory: Bool, isExecutable: Bool) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if alwaysReveal.contains(ext) { return true }
        guard !isDirectory, isExecutable else { return false }
        return ext.isEmpty || executableScripts.contains(ext)
    }
}
