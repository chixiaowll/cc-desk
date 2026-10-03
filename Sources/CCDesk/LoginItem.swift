import AppKit
import ServiceManagement
import CCDeskCore

/// 「登录时启动」：SMAppService.mainApp 的注册 / 取消注册（设计 §15）。默认关，不主动询问；
/// 勾选状态始终以系统的实际状态为准（用户可能在系统设置里改过）。只在主线程使用。
final class LoginItemController: ObservableObject {
    static let shared = LoginItemController()

    @Published private(set) var state: LoginItemState = LoginItemController.currentState()

    static func currentState() -> LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .disabled
        @unknown default: return .disabled
        }
    }

    func refresh() {
        let current = Self.currentState()
        if current != state { state = current }
    }

    func toggle() {
        refresh()
        do {
            switch state.toggleAction {
            case .register: try SMAppService.mainApp.register()
            case .unregister: try SMAppService.mainApp.unregister()
            }
        } catch {
            // 注册后待批准时 register() 也可能抛错；这种情况走下面的批准提示。
            refresh()
            if !state.needsApprovalHint {
                alertFailure(error)
                return
            }
        }
        refresh()
        if state.needsApprovalHint { alertNeedsApproval() }
    }

    private func alertNeedsApproval() {
        let alert = NSAlert()
        alert.messageText = L("alert.loginItemApproval.title")
        alert.informativeText = L("alert.loginItemApproval.message")
        alert.addButton(withTitle: L("action.openSystemSettings"))
        alert.addButton(withTitle: L("action.ok"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { SMAppService.openSystemSettingsLoginItems() }
    }

    private func alertFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("alert.loginItemFailed.title")
        alert.informativeText = L("alert.loginItemFailed.message", error.localizedDescription)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// 收集「这次是不是登录时自动启动」的信号，判定逻辑在 CCDeskCore 的 `LoginLaunch`。
enum LoginLaunchDetector {
    /// 启动时的 open-application Apple 事件是否带 keyAELaunchedAsLogInItem。
    /// 只在 applicationWill/DidFinishLaunching 期间有意义（之后 currentAppleEvent 不再是启动事件）。
    static func appleEventSaysLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    /// 当前用户会话开始（本会话 loginwindow 进程启动）到现在的秒数；拿不到时为 nil。
    static func secondsSinceSessionStart(now: Date = Date()) -> TimeInterval? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.loginwindow")
            .first?.processIdentifier, let start = startTime(of: pid) else { return nil }
        return now.timeIntervalSince(start)
    }

    private static func startTime(of pid: pid_t) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    static func detect(appleEventSaysLoginItem: Bool) -> Bool {
        let signals = LoginLaunch.Signals(
            arguments: CommandLine.arguments,
            appleEventSaysLoginItem: appleEventSaysLoginItem,
            loginItemEnabled: LoginItemController.currentState() == .enabled,
            secondsSinceSessionStart: secondsSinceSessionStart())
        return LoginLaunch.isLoginLaunch(signals)
    }
}
