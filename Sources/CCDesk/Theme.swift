import SwiftUI
import AppKit
import CCDeskCore

/// 界面配色：由 Core `ThemeCatalog` 里的主题（`ThemeTokens` + `TerminalPalette`）换算成 SwiftUI / AppKit 颜色（设计 §19）。
/// 视图里用 `ThemeStore.shared.theme(for: colorScheme)`（并观察 `ThemeStore` 以便切换主题时刷新）；不要在视图里写死黑 / 白。
struct Theme {
    let id: ThemeID
    let side: Color
    let main: Color
    let line: Color
    let fg1: Color
    let fg2: Color
    let fg3: Color
    let chip: Color
    let sel: Color
    let selLine: Color
    let selShadow: Color
    let hover: Color
    let waitRow: Color
    let pillWaitBg: Color
    let pillWaitFg: Color
    let pillWorkBg: Color
    let pillWorkFg: Color
    let dot: Color
    let chipWorkBg: Color
    let chipWorkFg: Color
    /// 已完成·未读（绿）：文字 / 状态点、计数胶囊底色与文字。
    let unread: Color
    let chipUnreadBg: Color
    let chipUnreadFg: Color
    let pillIdleBg: Color
    let pillIdleFg: Color
    let pillMissBg: Color
    let pillMissFg: Color
    let tileEmbBg: Color
    let tileEmbFg: Color
    let tileTermBg: Color
    let tileTermFg: Color
    let tileMissBg: Color
    let tileMissFg: Color
    let accent: Color
    let action: Color
    let extBg: Color
    let extFg: Color
    let extRing: Color
    /// 外部 App 图标的投影；深色下另加一圈半透明白色描边（`appIconRim`）避免黑色图标融进背景。
    let appIconShadow: Color
    let appIconShadowRadius: CGFloat
    let appIconRim: Color?
    let backdrop: Color
    let popShadow: Color
    let terminal: TerminalTheme
    let isDark: Bool

    init(_ definition: ThemeDefinition) {
        let t = definition.tokens
        func c(_ hex: UInt32) -> Color { Color(hex: hex) }
        func c(_ rgba: ThemeRGBA) -> Color { Color(hex: rgba.rgb).opacity(rgba.alpha) }
        id = definition.id
        side = c(t.side); main = c(t.main); line = c(t.line)
        fg1 = c(t.fg1); fg2 = c(t.fg2); fg3 = c(t.fg3); chip = c(t.chip)
        sel = c(t.sel); selLine = c(t.selLine); selShadow = c(t.selShadow)
        hover = c(t.hover); waitRow = c(t.waitRow)
        pillWaitBg = c(t.pillWaitBg); pillWaitFg = c(t.pillWaitFg)
        pillWorkBg = c(t.pillWorkBg); pillWorkFg = c(t.pillWorkFg); dot = c(t.dot)
        chipWorkBg = c(t.chipWorkBg); chipWorkFg = c(t.chipWorkFg)
        unread = c(t.unread); chipUnreadBg = c(t.chipUnreadBg); chipUnreadFg = c(t.chipUnreadFg)
        pillIdleBg = c(t.pillIdleBg); pillIdleFg = c(t.pillIdleFg)
        pillMissBg = c(t.pillMissBg); pillMissFg = c(t.pillMissFg)
        tileEmbBg = c(t.tileEmbBg); tileEmbFg = c(t.tileEmbFg)
        tileTermBg = c(t.tileTermBg); tileTermFg = c(t.tileTermFg)
        tileMissBg = c(t.tileMissBg); tileMissFg = c(t.tileMissFg)
        accent = c(t.accent); action = c(t.action)
        extBg = c(t.extBg); extFg = c(t.extFg); extRing = c(t.extRing)
        appIconShadow = c(t.appIconShadow)
        appIconShadowRadius = CGFloat(t.appIconShadowRadius)
        appIconRim = t.appIconRim.map { c($0) }
        backdrop = c(t.backdrop); popShadow = c(t.popShadow)
        terminal = TerminalTheme(definition)
        isDark = definition.kind == .dark
    }
}

/// 内嵌终端配色（SwiftTerm 用 NSColor）：底色 / 前景 / 光标与 ANSI 16 色都取自主题的 `TerminalPalette`（设计 §18、§19）。
struct TerminalTheme {
    /// 主题 id：终端池据此跳过重复换色。
    let id: ThemeID
    /// 明暗：决定 COLORFGBG 与 mode 2031 报告。
    let scheme: TerminalColorScheme
    let palette: TerminalPalette
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor

    init(_ definition: ThemeDefinition) {
        id = definition.id
        scheme = definition.kind
        palette = definition.palette
        background = NSColor(hex: palette.background)
        foreground = NSColor(hex: palette.foreground)
        cursor = NSColor(hex: palette.foreground)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

/// 呼吸点：不透明度在 1 与 0.55 之间往复（1.6s 一周期）；开启「减少动态效果」时静止。
struct BreathingDot: View {
    let color: Color
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Circle().fill(color).frame(width: size, height: size)
        } else {
            PhaseAnimator([1.0, 0.55]) { phase in
                Circle().fill(color).frame(width: size, height: size).opacity(phase)
            } animation: { _ in .easeInOut(duration: 0.8) }
        }
    }
}
