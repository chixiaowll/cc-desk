import Foundation

/// 「常驻桌面」相关设置（菜单栏图标、全局快捷键）的 UserDefaults 键与默认值（设计 §15）。
/// 登录时启动不存设置：以 SMAppService 的实际状态为准。
public enum DesktopSettings {
    /// 是否在菜单栏显示状态图标（默认显示）。
    public static let menuBarIconShownKey = "menuBarIconShown"
    /// 是否注册全局快捷键（默认开启）。
    public static let globalHotkeysEnabledKey = "globalHotkeysEnabled"

    /// 读取一个默认为 true 的开关；没存过或类型不对时用默认值。
    public static func bool(_ stored: Any?, default fallback: Bool) -> Bool {
        (stored as? Bool) ?? fallback
    }

    public static func menuBarIconShown(_ defaults: UserDefaults = .standard) -> Bool {
        bool(defaults.object(forKey: menuBarIconShownKey), default: true)
    }

    public static func globalHotkeysEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        bool(defaults.object(forKey: globalHotkeysEnabledKey), default: true)
    }
}

/// 登录项（SMAppService.mainApp）状态在界面上的呈现，与 ServiceManagement 解耦以便测试。
public enum LoginItemState: Equatable, Sendable {
    case enabled
    case disabled
    /// 已注册但需要用户在「系统设置 › 通用 › 登录项」里允许。
    case requiresApproval
    /// 系统找不到这个 App（如从 DMG / 临时目录运行）。
    case notFound

    /// 菜单里的勾选状态：已注册（含待批准）都算「开」，这样再点一次就是取消注册。
    public var isOn: Bool { self == .enabled || self == .requiresApproval }

    /// 点击开关时要做的事。
    public enum Action: Equatable, Sendable { case register, unregister }
    public var toggleAction: Action { isOn ? .unregister : .register }

    /// 注册后是否需要提示用户去系统设置里批准。
    public var needsApprovalHint: Bool { self == .requiresApproval }
}

/// 判断这次启动是不是「登录时自动启动」：是的话不显示 / 不激活主窗口，只留菜单栏图标与 Dock 图标（设计 §15）。
public enum LoginLaunch {
    /// 显式标记（测试或自定义启动方式可传入）。
    public static let argument = "--launched-at-login"
    /// 用户会话开始后这么多秒内由登录项启动，视为登录启动。
    public static let sessionWindow: TimeInterval = 120

    public struct Signals: Equatable, Sendable {
        /// 进程启动参数（含可执行文件路径）。
        public var arguments: [String]
        /// 启动时的 open-application Apple 事件带有 keyAELaunchedAsLogInItem。
        public var appleEventSaysLoginItem: Bool
        /// SMAppService 登录项当前是否已启用。
        public var loginItemEnabled: Bool
        /// 当前用户会话（loginwindow 进程）开始到本进程启动经过的秒数；拿不到时为 nil。
        public var secondsSinceSessionStart: TimeInterval?

        public init(arguments: [String], appleEventSaysLoginItem: Bool, loginItemEnabled: Bool,
                    secondsSinceSessionStart: TimeInterval?) {
            self.arguments = arguments
            self.appleEventSaysLoginItem = appleEventSaysLoginItem
            self.loginItemEnabled = loginItemEnabled
            self.secondsSinceSessionStart = secondsSinceSessionStart
        }
    }

    /// 显式参数或 Apple 事件标记直接判定为登录启动；SMAppService 启动的 App 不一定带 Apple 事件标记，
    /// 所以另加兜底：登录项已启用、且在会话开始后 `sessionWindow` 秒内启动。
    public static func isLoginLaunch(_ signals: Signals) -> Bool {
        if signals.arguments.dropFirst().contains(argument) { return true }
        if signals.appleEventSaysLoginItem { return true }
        guard signals.loginItemEnabled, let age = signals.secondsSinceSessionStart else { return false }
        return age >= 0 && age <= sessionWindow
    }
}
