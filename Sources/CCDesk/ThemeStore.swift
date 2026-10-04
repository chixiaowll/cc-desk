import SwiftUI
import AppKit
import Combine
import CCDeskCore

/// 当前选用的浅色 / 深色主题（UserDefaults `lightTheme` / `darkTheme`，设计 §19）。只在主线程使用。
/// 视图观察它并用 `theme(for: colorScheme)` 取配色；选主题时在同一个 CATransaction 里给所有终端换色，不重建终端。
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    @Published private(set) var lightID: ThemeID
    @Published private(set) var darkID: ThemeID

    /// 内嵌终端池（App 启动时设置）：选主题后立即换色。
    weak var pool: TerminalPool?

    private let defaults: UserDefaults
    private var cache: [ThemeID: Theme] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lightID = ThemeSelection.stored(.light, defaults: defaults)
        darkID = ThemeSelection.stored(.dark, defaults: defaults)
    }

    func selectedID(_ kind: TerminalColorScheme) -> ThemeID { kind == .light ? lightID : darkID }

    func theme(_ id: ThemeID) -> Theme {
        if let cached = cache[id] { return cached }
        let theme = Theme(ThemeCatalog.definition(id))
        cache[id] = theme
        return theme
    }

    func theme(kind: TerminalColorScheme) -> Theme { theme(selectedID(kind)) }

    func theme(for scheme: ColorScheme) -> Theme { theme(kind: scheme == .dark ? .dark : .light) }

    /// 按 App 当前（或给定）外观取终端配色。
    func terminalTheme(for appearance: NSAppearance) -> TerminalTheme {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return theme(kind: dark ? .dark : .light).terminal
    }

    /// 选用某个主题（按它的明暗替换浅色或深色主题）。当前外观正好是这一档时，终端在同一个 CATransaction 里换色。
    func select(_ id: ThemeID) {
        guard selectedID(id.kind) != id else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ThemeSelection.store(id, defaults: defaults)
        if id.kind == .light { lightID = id } else { darkID = id }
        pool?.apply(terminalTheme(for: NSApp.effectiveAppearance))
        CATransaction.commit()
    }

    /// 设置 / 菜单里显示的主题名。
    static func name(_ id: ThemeID) -> String {
        switch id {
        case .warmPaper: return L("theme.warmPaper")
        case .catppuccinLatte: return L("theme.catppuccinLatte")
        case .rosePineDawn: return L("theme.rosePineDawn")
        case .everforestLightSoft: return L("theme.everforestLightSoft")
        case .tokyoNightDay: return L("theme.tokyoNightDay")
        case .solarizedLight: return L("theme.solarizedLight")
        case .gruvboxLightSoft: return L("theme.gruvboxLightSoft")
        case .ccDeskDark: return L("theme.ccDeskDark")
        case .catppuccinMocha: return L("theme.catppuccinMocha")
        case .rosePineMoon: return L("theme.rosePineMoon")
        case .everforestDarkMedium: return L("theme.everforestDarkMedium")
        case .tokyoNightStorm: return L("theme.tokyoNightStorm")
        case .gruvboxDark: return L("theme.gruvboxDark")
        case .nord: return L("theme.nord")
        }
    }
}
