import AppKit
import CCDeskCore

/// 终端里 ⌘-点击文件路径（设计 §17）：⌘-点击快速查看，⇧⌘-点击用默认 App 打开。
/// 相对路径先按该终端里 agent 会话的 cwd 解析，再按终端启动目录；文件不存在时不处理（交还 SwiftTerm）。
extension AppModel {
    func installTerminalPathClicks() {
        DetectingTerminalView.pathClickHandler = { [weak self] view, line, column, openWithApp in
            guard let self, let terminal = self.pool.terminals.first(where: { $0.view === view }) else { return false }
            let rowCwd = self.groups.lazy.flatMap(\.rows)
                .first { $0.session.host == .embedded(terminalID: terminal.id) }?.session.cwd
            let bases = [rowCwd, terminal.cwd].compactMap { $0 }
            let path = bases.lazy.compactMap { TerminalPaths.resolve(line: line, column: column, cwd: $0) }.first
            guard let path else { return false }
            if openWithApp {
                FileActions.open(path)
            } else {
                self.touchedFiles.quickLook(path: path, window: view.window)
            }
            return true
        }
    }
}
