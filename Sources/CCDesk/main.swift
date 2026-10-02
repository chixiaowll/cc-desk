import AppKit
import SwiftTerm

final class DemoDelegate: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let term = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
        term.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        term.processDelegate = self
        window = NSWindow(contentRect: term.frame, styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "SwiftTerm demo"
        window.contentView = term
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(term)
        var env = ProcessInfo.processInfo.environment
        env = env.filter { !$0.key.hasPrefix("CLAUDE_CODE_") && $0.key != "CLAUDECODE" }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        term.startProcess(executable: "/bin/zsh", args: ["-l", "-i"],
                          environment: env.map { "\($0.key)=\($0.value)" },
                          currentDirectory: NSHomeDirectory())
        NSApp.activate(ignoringOtherApps: true)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { window.title = title }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = DemoDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
