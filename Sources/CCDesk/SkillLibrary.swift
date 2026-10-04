import AppKit
import SwiftUI
import CCDeskCore

/// 技能库（设计 §21）：后台扫描本机各 agent 的技能并缓存，窗口打开时 / 点刷新时重扫；助手的 list_skills 复用缓存。
/// 只读：从不写 ~/.claude、~/.codex、~/.agents、~/.pi。只在主线程使用（扫描本身在后台队列）。
final class SkillLibrary: ObservableObject {
    @Published private(set) var entries: [SkillEntry] = []
    @Published private(set) var isLoading = false
    /// 最近一次扫描完成的时刻；nil 为还没扫过。
    @Published private(set) var loadedAt: Date?

    weak var model: AppModel?
    private let queue = DispatchQueue(label: "cc-desk.skills", qos: .userInitiated)
    private var waiting: [([SkillEntry]) -> Void] = []
    private var window: NSWindow?
    /// 窗口里的「快速查看」。
    let preview = FilePreviewController()

    init(model: AppModel?) {
        self.model = model
    }

    /// 重新扫描；completion 在主线程拿到新结果。扫描进行中时并到这一次里。
    func refresh(completion: (([SkillEntry]) -> Void)? = nil) {
        if let completion { waiting.append(completion) }
        guard !isLoading else { return }
        isLoading = true
        let roots = model?.groups.map(\.id) ?? []
        queue.async { [weak self] in
            let scanned = SkillScanner.scan(.standard(projectRoots: roots))
            DispatchQueue.main.async {
                guard let self else { return }
                self.entries = scanned
                self.loadedAt = Date()
                self.isLoading = false
                let callbacks = self.waiting
                self.waiting = []
                callbacks.forEach { $0(scanned) }
            }
        }
    }

    /// 缓存不超过 maxAge 秒时直接用，否则重扫（助手工具用）。
    func current(maxAge: TimeInterval = 30, completion: @escaping ([SkillEntry]) -> Void) {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < maxAge, !isLoading { return completion(entries) }
        refresh(completion: completion)
    }

    // MARK: 当前会话

    /// 「只看当前会话可用」用的会话：主窗口聚焦的窗格（没有时为全局选中），必须是 agent 会话。
    struct SessionContext: Equatable {
        let name: String
        let kind: AgentKind
        let cwd: String
        let projectRoot: String?
    }

    var currentSession: SessionContext? {
        guard let model, let row = model.mainWindowRow, row.session.kind.isAgent else { return nil }
        let root = model.groups.first { group in group.rows.contains { $0.id == row.id } }?.id
        return SessionContext(name: row.displayName, kind: row.session.kind, cwd: row.session.cwd, projectRoot: root)
    }

    // MARK: 窗口

    /// 打开技能库窗口（已打开时拿到最前），并重新扫描。
    func showWindow() {
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.identifier = NSUserInterfaceItemIdentifier("skills")
            window.title = L("skills.title")
            window.minSize = NSSize(width: 760, height: 460)
            let content = NSHostingView(rootView: SkillsLibraryView(library: self))
            content.sizingOptions = []
            window.contentView = content
            if !window.setFrameUsingName("CCDeskSkillsLibrary") { window.center() }
            window.setFrameAutosaveName("CCDeskSkillsLibrary")
            self.window = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    /// 快速查看一个文件（面板挂在技能库窗口上）。
    func quickLook(_ path: String) {
        preview.show([URL(fileURLWithPath: path)], index: 0, in: window)
    }
}
