import Foundation

public enum JumpScript {
    /// 选中 Terminal.app 中 tty 匹配的标签并置前；找到返回 true。tty 形如 "ttys007"。
    public static func terminalApp(tty: String) -> String? {
        guard tty.range(of: #"^ttys[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        return """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "/dev/\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
    }
}
