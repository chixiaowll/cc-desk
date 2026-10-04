import AppKit
import Quartz
import UniformTypeIdentifiers
import CCDeskCore

/// 系统「快速查看」面板的控制者（设计 §17）。QLPreviewPanel 沿 key window 的响应链找控制者，
/// 所以显示前把自己插到主窗口之后（window.nextResponder），面板列表与终端 ⌘-点击共用。
/// 面板打开时 ↑ / ↓（及 ← / →）切换上一个 / 下一个文件并同步列表选中，空格关闭，与访达一致。只在主线程使用。
final class FilePreviewController: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private(set) var items: [URL] = []
    private(set) var index = 0
    /// 面板里切换了文件（参数为新的下标），由列表同步选中。
    private var onMove: ((Int) -> Void)?

    static var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// 显示 `items[index]`；面板已打开时只换内容。
    func show(_ items: [URL], index: Int, in window: NSWindow?, onMove: ((Int) -> Void)? = nil) {
        guard !items.isEmpty else { return }
        self.items = items
        self.index = min(max(index, 0), items.count - 1)
        self.onMove = onMove
        install(in: window ?? NSApp.keyWindow ?? NSApp.mainWindow)
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.reloadData()
            panel.currentPreviewItemIndex = self.index
        } else {
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
            panel.currentPreviewItemIndex = self.index
        }
    }

    /// 打开时更新内容（列表选中变化、文件列表刷新），不弹出面板。
    func update(_ items: [URL], index: Int) {
        guard Self.isVisible, QLPreviewPanel.shared().dataSource === self, !items.isEmpty else { return }
        let changed = items != self.items || index != self.index
        self.items = items
        self.index = min(max(index, 0), items.count - 1)
        if changed {
            QLPreviewPanel.shared().reloadData()
            QLPreviewPanel.shared().currentPreviewItemIndex = self.index
        }
    }

    func close() {
        guard Self.isVisible else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    /// 插到窗口响应链末尾（只插一次）。
    private func install(in window: NSWindow?) {
        guard let window else { return }
        var responder: NSResponder? = window
        while let r = responder {
            if r === self { return }
            responder = r.nextResponder
        }
        nextResponder = window.nextResponder
        window.nextResponder = self
    }

    // MARK: QLPreviewPanelController

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = index
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard items.indices.contains(index) else { return nil }
        return items[index] as NSURL
    }

    // MARK: QLPreviewPanelDelegate

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        switch event.keyCode {
        case 125, 124: move(by: 1, panel: panel) // ↓ →
        case 126, 123: move(by: -1, panel: panel) // ↑ ←
        case 49: panel.orderOut(nil) // 空格
        default: return false
        }
        return true
    }

    private func move(by delta: Int, panel: QLPreviewPanel) {
        let next = index + delta
        guard items.indices.contains(next) else { return }
        index = next
        panel.currentPreviewItemIndex = next
        onMove?(next)
    }
}

/// 文件的常用动作：默认 App 打开、在访达中显示、VS Code 打开、复制路径。
enum FileActions {
    /// 用默认 App 打开；会直接运行的文件（App、终端脚本、带可执行位的脚本…，见 `FileOpenPolicy`）改为在访达里显示。
    static func open(_ path: String) {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let executable = exists && FileManager.default.isExecutableFile(atPath: path)
        if FileOpenPolicy.shouldReveal(path: path, isDirectory: isDir.boolValue, isExecutable: executable) {
            return reveal(path)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static var iconCache: [String: NSImage] = [:]

    /// 文件图标：存在时取实际文件的图标，否则按扩展名；按路径缓存（只在主线程）。
    static func icon(for path: String, exists: Bool) -> NSImage {
        let key = (exists ? "f:" : "x:") + path
        if let cached = iconCache[key] { return cached }
        let image: NSImage
        if exists {
            image = NSWorkspace.shared.icon(forFile: path)
        } else {
            let ext = (path as NSString).pathExtension
            image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
        if iconCache.count > 500 { iconCache.removeAll() }
        iconCache[key] = image
        return image
    }
}
