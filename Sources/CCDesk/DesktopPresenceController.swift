import AppKit
import Combine
import SwiftUI
import CCDeskCore

/// 常驻桌面（设计 §15）：菜单栏状态项、全局快捷键、登录启动时收起主窗口。
/// 内嵌会话托管在 tmux 里、App 退出后仍在运行，没人看着就会错过等批准；登录启动 + 菜单栏让 CC Desk 一直在场。
/// 只在主线程使用。
final class DesktopPresence {
    private weak var delegate: AppDelegate?
    private let statusBar: StatusBarController
    private let preferences = DesktopPreferences.shared
    private let hotkeys = GlobalHotkeyCenter.shared
    private var cancellables: Set<AnyCancellable> = []
    /// 登录启动后、用户主动打开之前，主窗口一出现就收起。
    private var suppressing = false
    private var occlusionObserver: NSObjectProtocol?

    init(delegate: AppDelegate) {
        self.delegate = delegate
        let model = delegate.model
        statusBar = StatusBarController(model: model, actions: .init(
            showMainWindow: { [weak delegate] in delegate?.showMainWindow() },
            newSession: { [weak delegate] in delegate?.showNewSession() },
            toggleConversation: { [weak model] in model?.conversation.toggle() }))
    }

    func start() {
        statusBar.start()
        hotkeys.onAction = { [weak self] action in self?.perform(action) }
        // 第一次（启动时）注册失败只在菜单里提示；用户之后主动开启时再弹窗说明。
        var initial = true
        preferences.$globalHotkeysEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                let failed = self.hotkeys.apply(enabled: enabled)
                // 模态框不在 Combine 回调（设置开关的绑定还在更新中）里直接弹出，放到下一轮主循环。
                if !initial, enabled, !failed.isEmpty {
                    DispatchQueue.main.async { [weak self] in self?.hotkeys.alertUnavailable(failed) }
                }
                initial = false
            }
            .store(in: &cancellables)
        // 用户可能在系统设置里改了登录项；回到 App 时刷新勾选状态。
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { _ in LoginItemController.shared.refresh() }
            .store(in: &cancellables)
    }

    private func perform(_ action: GlobalHotkey.Action) {
        switch action {
        case .toggleMainWindow: delegate?.toggleMainWindow()
        case .toggleConversation: delegate?.model.conversation.toggle()
        }
    }

    // MARK: 登录启动

    /// SwiftUI 的 `Window` scene 启动时总会创建并显示主窗口；登录启动时它一变为可见就收起（orderOut，不销毁，
    /// 这样 ContentView 注入的 openMainWindow 仍可用），App 也不主动激活。几秒后或用户主动打开时停止。
    func suppressMainWindowAtLaunch() {
        suppressing = true
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.hideMainWindowIfSuppressing()
        }
        for delay in [0.0, 0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.hideMainWindowIfSuppressing() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.endLaunchSuppression() }
    }

    func endLaunchSuppression() {
        suppressing = false
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
    }

    private func hideMainWindowIfSuppressing() {
        guard suppressing, let main = delegate?.mainWindow, main.isVisible else { return }
        main.orderOut(nil)
    }
}
