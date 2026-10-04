import Foundation

/// 颜色运算（纯函数，0xRRGGBB）：混色、HSL 换算，以及「保持色相、调明度直到对比度达标」（设计 §19）。
public enum ColorMath {
    /// 按比例混合两色：`amount` 为 `b` 的占比（0 = a，1 = b）。
    public static func mix(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 {
        let t = min(max(amount, 0), 1)
        let ca = TerminalPalette.components(a), cb = TerminalPalette.components(b)
        func channel(_ x: UInt8, _ y: UInt8) -> UInt32 {
            UInt32((Double(x) * (1 - t) + Double(y) * t).rounded())
        }
        return channel(ca.red, cb.red) << 16 | channel(ca.green, cb.green) << 8 | channel(ca.blue, cb.blue)
    }

    /// 0xRRGGBB -> HSL（h 0…360，s / l 0…1）。
    public static func hsl(_ hex: UInt32) -> (h: Double, s: Double, l: Double) {
        let c = TerminalPalette.components(hex)
        let r = Double(c.red) / 255, g = Double(c.green) / 255, b = Double(c.blue) / 255
        let maxV = max(r, g, b), minV = min(r, g, b)
        let l = (maxV + minV) / 2
        let d = maxV - minV
        guard d > 0 else { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        var h: Double
        switch maxV {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h *= 60
        return (h, s, l)
    }

    /// HSL -> 0xRRGGBB（分量四舍五入到 8 位）。
    public static func hex(h: Double, s: Double, l: Double) -> UInt32 {
        let l = min(max(l, 0), 1), s = min(max(s, 0), 1)
        func channel(_ value: Double) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        guard s > 0 else { return channel(l) << 16 | channel(l) << 8 | channel(l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue(_ tIn: Double) -> Double {
            var t = tIn
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let hn = h / 360
        return channel(hue(hn + 1 / 3)) << 16 | channel(hue(hn)) << 8 | channel(hue(hn - 1 / 3))
    }

    /// 对一组底色的最低对比度。
    public static func minimumContrast(_ color: UInt32, against backgrounds: [UInt32]) -> Double {
        backgrounds.map { ColorContrast.ratio(color, $0) }.min() ?? 21
    }

    /// 对每个底色的对比度都 ≥ `minimum` 时原样返回；否则保持色相与饱和度，逐步降低（`lighten` 为 false，浅色主题）
    /// 或提高（深色主题）HSL 明度直到达标。明度到头仍不够时返回纯黑 / 纯白。
    public static func ensuring(_ color: UInt32, contrast minimum: Double, against backgrounds: [UInt32],
                                lighten: Bool) -> UInt32 {
        if minimumContrast(color, against: backgrounds) >= minimum { return color }
        let (h, s, l0) = hsl(color)
        var l = l0
        let step = lighten ? 0.005 : -0.005
        while (lighten && l < 1) || (!lighten && l > 0) {
            l += step
            let candidate = hex(h: h, s: s, l: l)
            if minimumContrast(candidate, against: backgrounds) >= minimum { return candidate }
        }
        return lighten ? 0xFFFFFF : 0x000000
    }
}
