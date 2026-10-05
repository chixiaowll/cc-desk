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
}

/// 一套终端配色：底色、前景色与 ANSI 16 色（0–7 普通、8–15 明亮），均为 0xRRGGBB。
public struct TerminalPalette: Equatable, Sendable {
    public let background: UInt32
    public let foreground: UInt32
    public let ansi: [UInt32]

    public init(background: UInt32, foreground: UInt32, ansi: [UInt32]) {
        self.background = background
        self.foreground = foreground
        self.ansi = ansi
    }

    /// 0xRRGGBB 拆成 8 位分量。
    public static func components(_ hex: UInt32) -> (red: UInt8, green: UInt8, blue: UInt8) {
        (UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF))
    }
}

extension TerminalPalette {
    /// 前景色对底色的最低对比度：浅色 5:1（低眩光主题刻意略低于 7:1），深色 7:1。
    public static func minimumForegroundContrast(_ kind: TerminalColorScheme) -> Double {
        kind == .light ? 5 : 7
    }

    /// ANSI 色对底色的最低对比度（nil = 不要求）。
    /// 浅色：普通色 0–7（含「白」）≥ 4.5:1，明亮色 8–15 ≥ 3:1；
    /// 深色：1–7 与 9–15 ≥ 4.5:1，8（亮黑，常用作注释）≥ 3:1，0 黑是背景类颜色，不要求。
    public static func minimumContrast(ansi index: Int, kind: TerminalColorScheme) -> Double? {
        switch kind {
        case .light: return index < 8 ? 4.5 : 3
        case .dark:
            if index == 0 { return nil }
            return index == 8 ? 3 : 4.5
        }
    }

    /// 按上面的下限修正：不达标的颜色保持色相，浅色主题加深、深色主题提亮（设计 §19）；已达标的原样保留。
    public func enforcingContrast(for kind: TerminalColorScheme) -> TerminalPalette {
        let lighten = kind == .dark
        let fg = ColorMath.ensuring(foreground, contrast: Self.minimumForegroundContrast(kind),
                                    against: [background], lighten: lighten)
        let colors = ansi.enumerated().map { index, color -> UInt32 in
            guard let minimum = Self.minimumContrast(ansi: index, kind: kind) else { return color }
            return ColorMath.ensuring(color, contrast: minimum, against: [background], lighten: lighten)
        }
        return TerminalPalette(background: background, foreground: fg, ansi: colors)
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
    public static let sizeRange: ClosedRange<Double> = 9...24
    /// 快捷键放大 / 缩小一次的步长（pt）。
    public static let sizeStep: Double = 1

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

    /// 字号取整并限制在 9–24 之间；没有设置（0 / 非数）时用默认 13。
    public static func clampedSize(_ size: Double) -> Double {
        guard size.isFinite, size > 0 else { return defaultSize }
        return min(max(size.rounded(), sizeRange.lowerBound), sizeRange.upperBound)
    }

    /// 放大（steps > 0）/ 缩小（steps < 0）若干步后的字号，先按 `clampedSize` 规整再限制在范围内。
    public static func steppedSize(_ size: Double, by steps: Int) -> Double {
        clampedSize(clampedSize(size) + Double(steps) * sizeStep)
    }

    /// 还能再放大 / 缩小（菜单项据此禁用）。
    public static func canStep(_ size: Double, by steps: Int) -> Bool {
        steppedSize(size, by: steps) != clampedSize(size)
    }
}
