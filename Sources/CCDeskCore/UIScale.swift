import Foundation

/// 界面文字大小（设置 › 通用「界面文字」，设计 §25）：几档固定倍率，应用到 App 窗口里的界面文字与相关的
/// 固定尺寸（行高、标题条、工具栏、胶囊），不影响终端字号（终端另有 `TerminalFontChoice`）。
public enum UIScalePreset: String, CaseIterable, Sendable {
    case small, standard, large, extraLarge

    public static let defaultsKey = "uiTextScale"
    public static let `default` = UIScalePreset.standard

    /// 倍率：小 0.9、标准 1.0、大 1.15、特大 1.3。
    public var factor: Double {
        switch self {
        case .small: return 0.9
        case .standard: return 1.0
        case .large: return 1.15
        case .extraLarge: return 1.3
        }
    }

    /// 读 UserDefaults 里存的值；没有或无法识别时为标准。
    public static func resolve(_ raw: String?) -> UIScalePreset {
        raw.flatMap(UIScalePreset.init(rawValue:)) ?? .default
    }
}

/// 按倍率换算尺寸的纯函数：字号取到 0.5pt，布局尺寸取到整点（避免半像素模糊），都不小于 1。
public enum UIScaleMath {
    /// 缩放后的字号。
    public static func fontSize(_ base: Double, factor: Double) -> Double {
        guard base.isFinite, base > 0 else { return base }
        return max(1, (base * sanitized(factor) * 2).rounded() / 2)
    }

    /// 缩放后的布局尺寸（行高、宽度、图标框等）。
    public static func metric(_ base: Double, factor: Double) -> Double {
        guard base.isFinite, base > 0 else { return base }
        return max(1, (base * sanitized(factor)).rounded())
    }

    /// 非法倍率（0、负数、非数）按 1 处理。
    static func sanitized(_ factor: Double) -> Double {
        factor.isFinite && factor > 0 ? factor : 1
    }
}
