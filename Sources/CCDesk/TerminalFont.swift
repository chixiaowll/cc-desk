import AppKit
import Combine
import CCDeskCore

/// 内嵌终端字体（设计 §18）：UserDefaults 里存字体族（空 = 自动）与字号，选择规则在 Core 的 `TerminalFontChoice`。
enum TerminalFont {
    /// 本机已安装的字体族。
    static func installedFamilies() -> Set<String> {
        Set(NSFontManager.shared.availableFontFamilies)
    }

    /// 按当前设置得到的终端字体；字体族取不到常规字重时退回系统等宽字体。
    static func current(defaults: UserDefaults = .standard) -> NSFont {
        let size = CGFloat(TerminalFontChoice.clampedSize(defaults.double(forKey: TerminalFontChoice.sizeKey)))
        let family = TerminalFontChoice.resolve(family: defaults.string(forKey: TerminalFontChoice.familyKey),
                                                installed: installedFamilies())
        if let family, let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// 设置里可选的字体族：已安装的等宽字体，加上已安装的中文等宽字体（有的中文等宽字体不带等宽标记），按名称排序。
    static func pickableFamilies() -> [String] {
        let manager = NSFontManager.shared
        var families = Set<String>()
        for name in manager.availableFontNames(with: .fixedPitchFontMask) ?? [] {
            if let family = NSFont(name: name, size: 13)?.familyName, !family.hasPrefix(".") { families.insert(family) }
        }
        let installed = installedFamilies()
        families.formUnion(TerminalFontChoice.preferredCJKFamilies.filter { installed.contains($0) })
        return families.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// 设置 › 通用 › 终端字体绑定的偏好（设置页在改动后让终端池立即换字体）。只在主线程使用。
final class TerminalFontPreferences: ObservableObject {
    static let shared = TerminalFontPreferences()

    /// 空字符串 = 自动。
    @Published var family: String {
        didSet {
            guard family != oldValue else { return }
            defaults.set(family, forKey: TerminalFontChoice.familyKey)
        }
    }
    @Published var size: Double {
        didSet {
            guard size != oldValue else { return }
            defaults.set(size, forKey: TerminalFontChoice.sizeKey)
        }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        family = defaults.string(forKey: TerminalFontChoice.familyKey) ?? ""
        size = TerminalFontChoice.clampedSize(defaults.double(forKey: TerminalFontChoice.sizeKey))
    }
}
