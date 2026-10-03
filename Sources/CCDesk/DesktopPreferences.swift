import Foundation
import Combine
import CCDeskCore

/// 菜单栏图标 / 全局快捷键的开关（UserDefaults，键见 `DesktopSettings`）。只在主线程使用；
/// 菜单栏控制器和全局快捷键订阅它的变化，SwiftUI 菜单直接绑定。
final class DesktopPreferences: ObservableObject {
    static let shared = DesktopPreferences()

    @Published var menuBarIconShown: Bool {
        didSet { defaults.set(menuBarIconShown, forKey: DesktopSettings.menuBarIconShownKey) }
    }
    @Published var globalHotkeysEnabled: Bool {
        didSet { defaults.set(globalHotkeysEnabled, forKey: DesktopSettings.globalHotkeysEnabledKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuBarIconShown = DesktopSettings.menuBarIconShown(defaults)
        globalHotkeysEnabled = DesktopSettings.globalHotkeysEnabled(defaults)
    }
}
