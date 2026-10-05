import SwiftUI
import AppKit
import CCDeskCore

/// 界面文字大小（设计 §25）：窗口根视图用 `.uiScaleRoot()` 把当前倍率放进环境，界面里的固定字号用
/// `.uiFont(size:…)`、固定尺寸用 `uiScale.metric(…)`。倍率只在用户改设置时变化，平时不引起额外的重绘。
/// 终端字号不受影响（另见 `TerminalFontPreferences`）。
struct UIScale: Equatable {
    let factor: CGFloat

    static let standard = UIScale(factor: 1)
    /// 窗口工具栏里的内容最多放大到这个倍率（工具栏高度由系统决定）。
    static let toolbarMaxFactor: CGFloat = 1.15

    /// 缩放后的字号（取到 0.5pt）。
    func font(_ size: CGFloat) -> CGFloat {
        CGFloat(UIScaleMath.fontSize(Double(size), factor: Double(factor)))
    }

    /// 缩放后的布局尺寸（取整点），用于行高、标题条、工具栏、胶囊、侧栏宽度等会挤压文字的地方。
    func metric(_ value: CGFloat) -> CGFloat {
        CGFloat(UIScaleMath.metric(Double(value), factor: Double(factor)))
    }
}

private struct UIScaleKey: EnvironmentKey {
    static let defaultValue = UIScale.standard
}

extension EnvironmentValues {
    var uiScale: UIScale {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

/// 设置 › 通用 › 界面文字绑定的偏好（UserDefaults `uiTextScale`）。只在主线程使用。
final class UIScalePreferences: ObservableObject {
    static let shared = UIScalePreferences()

    @Published var preset: UIScalePreset {
        didSet {
            guard preset != oldValue else { return }
            defaults.set(preset.rawValue, forKey: UIScalePreset.defaultsKey)
        }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preset = UIScalePreset.resolve(defaults.string(forKey: UIScalePreset.defaultsKey))
    }

    var scale: UIScale { UIScale(factor: CGFloat(preset.factor)) }
}

extension UIScalePreset {
    var label: String {
        switch self {
        case .small: return L("settings.general.uiScale.small")
        case .standard: return L("settings.general.uiScale.standard")
        case .large: return L("settings.general.uiScale.large")
        case .extraLarge: return L("settings.general.uiScale.extraLarge")
        }
    }

    /// 系统控件（按钮、开关、选择器）的尺寸档：控件里的文字跟着控件尺寸走，不读环境字体。
    var controlSize: ControlSize {
        switch self {
        case .small: return .small
        case .standard: return .regular
        case .large, .extraLarge: return .large
        }
    }
}

/// 窗口根视图：观察偏好，把倍率、默认字体（13pt × 倍率）和控件尺寸放进环境。
private struct UIScaleRoot: ViewModifier {
    @ObservedObject private var preferences = UIScalePreferences.shared
    /// 测试用：固定倍率，不跟随偏好。
    var fixed: UIScalePreset?

    func body(content: Content) -> some View {
        let preset = fixed ?? preferences.preset
        let scale = UIScale(factor: CGFloat(preset.factor))
        content
            .environment(\.uiScale, scale)
            .font(.system(size: scale.font(13)))
            .controlSize(preset.controlSize)
    }
}

/// 按环境倍率缩放的系统字体。
private struct UIFontModifier: ViewModifier {
    @Environment(\.uiScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let monospacedDigit: Bool

    func body(content: Content) -> some View {
        let font = Font.system(size: scale.font(size), weight: weight, design: design)
        content.font(monospacedDigit ? font.monospacedDigit() : font)
    }
}

extension View {
    /// 界面文字的固定字号（按界面文字倍率缩放）；图标（SF Symbols）也用它，跟文字等比例。
    func uiFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default,
                monospacedDigit: Bool = false) -> some View {
        modifier(UIFontModifier(size: size, weight: weight, design: design, monospacedDigit: monospacedDigit))
    }

    /// 每个窗口的根视图调用一次（主窗口、设置、技能库、独立窗口等）。
    func uiScaleRoot(fixed: UIScalePreset? = nil) -> some View {
        modifier(UIScaleRoot(fixed: fixed))
    }
}
