import SwiftUI
import AppKit

/// 颜色常量，取自 docs/design/sidebar-mockup.html 的 `:root`（浅色）与 dark 变量。
/// 视图里用 `Theme.of(colorScheme)` 选择；不要在视图里写死黑 / 白。
struct Theme {
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

    static func of(_ scheme: ColorScheme) -> Theme { scheme == .dark ? dark : light }

    static let light = Theme(
        side: Color(hex: 0xF3F1ED), main: Color(hex: 0xFBFAF8), line: Color(hex: 0xE4E0D9),
        fg1: Color(hex: 0x1F1E1C), fg2: Color(hex: 0x6B675F), fg3: Color(hex: 0x8A857D), chip: Color(hex: 0xE7E3DC),
        sel: Color(hex: 0xFFFFFF), selLine: Color(hex: 0xE2DDD5), selShadow: Color(red: 60 / 255, green: 50 / 255, blue: 40 / 255).opacity(0.08),
        hover: Color(hex: 0xEAE6DF), waitRow: Color(hex: 0xF9EDE6),
        pillWaitBg: Color(hex: 0xC4552B), pillWaitFg: Color(hex: 0xFFFFFF),
        pillWorkBg: Color(hex: 0xE5ECF3), pillWorkFg: Color(hex: 0x35618E), dot: Color(hex: 0x4A7BAD),
        chipWorkBg: Color(hex: 0x3F6E9E), chipWorkFg: Color(hex: 0xFFFFFF),
        pillIdleBg: Color(hex: 0xECE8E2), pillIdleFg: Color(hex: 0x5C5852),
        pillMissBg: Color(hex: 0xF1E4E2), pillMissFg: Color(hex: 0x8E5A55),
        tileEmbBg: Color(hex: 0xE2DCD2), tileEmbFg: Color(hex: 0x3A362F),
        tileTermBg: Color(hex: 0xECE8E2), tileTermFg: Color(hex: 0x6B675F),
        tileMissBg: Color(hex: 0xF1E4E2), tileMissFg: Color(hex: 0x8E5A55),
        accent: Color(hex: 0xB24E26), action: Color(hex: 0x2B2925),
        extBg: Color(hex: 0xFFFFFF), extFg: Color(hex: 0x5C5852), extRing: Color(hex: 0xDDD8D0),
        appIconShadow: Color(red: 60 / 255, green: 50 / 255, blue: 40 / 255).opacity(0.18), appIconShadowRadius: 1,
        appIconRim: nil,
        backdrop: Color(red: 30 / 255, green: 25 / 255, blue: 20 / 255).opacity(0.16),
        popShadow: Color(red: 40 / 255, green: 30 / 255, blue: 20 / 255).opacity(0.18),
        terminal: .light, isDark: false)

    static let dark = Theme(
        side: Color(hex: 0x1F1E1C), main: Color(hex: 0x252422), line: Color(hex: 0x34322E),
        fg1: Color(hex: 0xEDEBE7), fg2: Color(hex: 0xA39E96), fg3: Color(hex: 0x837E76), chip: Color(hex: 0x2E2C29),
        sel: Color(hex: 0x33312D), selLine: Color(hex: 0x403D38), selShadow: Color.black.opacity(0.35),
        hover: Color(hex: 0x2A2825), waitRow: Color(hex: 0x2E211A),
        pillWaitBg: Color(hex: 0xE2875F), pillWaitFg: Color(hex: 0x1E120C),
        pillWorkBg: Color(hex: 0x22303D), pillWorkFg: Color(hex: 0x9DBBDA), dot: Color(hex: 0x82A8CF),
        chipWorkBg: Color(hex: 0x82A8CF), chipWorkFg: Color(hex: 0x101C27),
        pillIdleBg: Color(hex: 0x2F2D2A), pillIdleFg: Color(hex: 0xB8B3AB),
        pillMissBg: Color(hex: 0x352826), pillMissFg: Color(hex: 0xC9A09A),
        tileEmbBg: Color(hex: 0x3A3732), tileEmbFg: Color(hex: 0xE2DDD5),
        tileTermBg: Color(hex: 0x2E2C29), tileTermFg: Color(hex: 0xA39E96),
        tileMissBg: Color(hex: 0x352826), tileMissFg: Color(hex: 0xC9A09A),
        accent: Color(hex: 0xE2875F), action: Color(hex: 0xEDEBE7),
        extBg: Color(hex: 0x4A4741), extFg: Color(hex: 0xF2EFEA), extRing: Color(hex: 0x1F1E1C),
        appIconShadow: Color.black.opacity(0.6), appIconShadowRadius: 2,
        appIconRim: Color.white.opacity(0.55),
        backdrop: Color.black.opacity(0.35),
        popShadow: Color.black.opacity(0.45),
        terminal: .dark, isDark: true)
}

/// 内嵌终端配色（SwiftTerm 用 NSColor）。
struct TerminalTheme {
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor

    static let light = TerminalTheme(background: NSColor(hex: 0xFFFEFC), foreground: NSColor(hex: 0x2A2925),
                                     cursor: NSColor(hex: 0x2A2925))
    static let dark = TerminalTheme(background: NSColor(hex: 0x1B1A18), foreground: NSColor(hex: 0xD8D3CB),
                                    cursor: NSColor(hex: 0xD8D3CB))

    static func of(_ appearance: NSAppearance) -> TerminalTheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
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
