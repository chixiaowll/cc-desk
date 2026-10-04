import Foundation

/// 内嵌终端的明暗（设计 §18）：决定 ANSI 16 色调色板、`COLORFGBG` 与主题变化报告（mode 2031）。
public enum TerminalColorScheme: String, Sendable, CaseIterable {
    case light, dark

    /// 写进会话环境的 `COLORFGBG`（"前景;背景" 的 ANSI 色号）：Claude Code 的 Auto 主题、vim 等据最后一段判断底色。
    /// 浅色底为 "0;15"（黑字白底），深色底为 "15;0"。
    public var colorFGBG: String { self == .light ? "0;15" : "15;0" }

    /// 外层终端发给 tmux 的主题变化报告（DEC mode 2031 的 `CSI ? 997 ; 1|2 n`，1 = 深色、2 = 浅色）。
    /// tmux ≥ 3.6 收到后重新查询外层终端的前景 / 背景色（OSC 10/11），并转发给开启了 2031 的窗格程序。
    public var themeReport: String { self == .dark ? "\u{1b}[?997;1n" : "\u{1b}[?997;2n" }

    public var palette: TerminalPalette { self == .light ? .light : .dark }
}

/// 一套终端配色：底色、前景色与 ANSI 16 色（0–7 普通、8–15 明亮），均为 0xRRGGBB。
public struct TerminalPalette: Equatable, Sendable {
    public let background: UInt32
    public let foreground: UInt32
    public let ansi: [UInt32]

    /// 浅色：为 #F3EAD3 Everforest Light（Soft）底设计（色相取自 Everforest，按对比度要求加深）。普通色（含 0 黑、7 白）对底色 ≥ 4.5:1，明亮色 ≥ 3:1；
    /// 色相取自 App 的陶土红 / 雾蓝 / 鼠尾草绿，「白」是暖灰（浅底上纯白看不见）。
    public static let light = TerminalPalette(
        background: 0xF3EAD3, foreground: 0x525F66,
        ansi: [
            0x525F66, 0xC4332C, 0x616E01, 0x886200, 0x2B6F94, 0xB02C88, 0x257557, 0x5F6C5E,
            0x768675, 0xE0453E, 0x798A01, 0xA97A00, 0x3588B5, 0xD849AB, 0x2E926C, 0x708070,
        ])

    /// 深色：为 #1B1A18 设计。普通色 1–7 与明亮色 9–15 对底色 ≥ 4.5:1，8（亮黑，常用作注释）≥ 3:1；
    /// 0 黑接近底色（程序多用它作选中 / 状态栏底色）。
    public static let dark = TerminalPalette(
        background: 0x1B1A18, foreground: 0xD8D3CB,
        ansi: [
            0x4A4640, 0xE06C5A, 0x8DB79A, 0xD9B061, 0x82A8CF, 0xC792BF, 0x7DB8B6, 0xCFC9BF,
            0x7A746B, 0xF08A70, 0xA6CDB1, 0xE9C77D, 0xA3C2E2, 0xDBA9D3, 0x9DD0CD, 0xF2EEE8,
        ])

    /// 0xRRGGBB 拆成 8 位分量。
    public static func components(_ hex: UInt32) -> (red: UInt8, green: UInt8, blue: UInt8) {
        (UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF))
    }
}

/// WCAG 2.x 对比度（纯函数）。
public enum ColorContrast {
    /// sRGB 相对亮度（0 黑 … 1 白）。
    public static func relativeLuminance(_ hex: UInt32) -> Double {
        func linear(_ value: UInt32) -> Double {
            let c = Double(value & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(hex >> 16) + 0.7152 * linear(hex >> 8) + 0.0722 * linear(hex)
    }

    /// 对比度 (L1 + 0.05) / (L2 + 0.05)，1…21，与顺序无关。
    public static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

/// 终端字体的选择（设计 §18）：默认「自动」优先用已安装的、中文按两格等宽设计的等宽字体，
/// 没有时用系统等宽字体（SF Mono，中文由苹方回退，字形窄于两格会留缝）。
public enum TerminalFontChoice {
    public static let familyKey = "terminalFontFamily"
    public static let sizeKey = "terminalFontSize"
    public static let defaultSize: Double = 13
    public static let sizeRange: ClosedRange<Double> = 11...18

    /// 「自动」时按顺序找的中文等宽字体族。
    public static let preferredCJKFamilies = [
        "Maple Mono NF CN", "Maple Mono CN", "Sarasa Term SC", "Sarasa Mono SC",
        "LXGW WenKai Mono", "Noto Sans Mono CJK SC",
    ]

    /// 没有中文等宽字体时提示的安装命令。
    public static let installHint = "brew install --cask font-maple-mono-nf-cn"

    /// 解析后的字体：某个字体族，或系统等宽字体（nil）。
    /// `family` 为用户选的字体族（nil / 空 = 自动）；选中的字体已卸载时退回自动。
    public static func resolve(family: String?, installed: Set<String>) -> String? {
        if let family, !family.isEmpty, installed.contains(family) { return family }
        return autoFamily(installed: installed)
    }

    /// 「自动」会用的字体族；都没装时为 nil（系统等宽字体）。
    public static func autoFamily(installed: Set<String>) -> String? {
        preferredCJKFamilies.first { installed.contains($0) }
    }

    /// 字号取整并限制在 11–18 之间；没有设置（0 / 非数）时用默认 13。
    public static func clampedSize(_ size: Double) -> Double {
        guard size.isFinite, size > 0 else { return defaultSize }
        return min(max(size.rounded(), sizeRange.lowerBound), sizeRange.upperBound)
    }
}
