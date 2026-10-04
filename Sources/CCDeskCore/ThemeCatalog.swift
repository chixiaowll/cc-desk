import Foundation

/// 配色主题的标识（设计 §19）；原始值写进 UserDefaults（`lightTheme` / `darkTheme`）。
public enum ThemeID: String, Codable, CaseIterable, Sendable, Identifiable {
    // 浅色
    case warmPaper = "warm-paper"
    case catppuccinLatte = "catppuccin-latte"
    case rosePineDawn = "rose-pine-dawn"
    case everforestLightSoft = "everforest-light-soft"
    case tokyoNightDay = "tokyo-night-day"
    case solarizedLight = "solarized-light"
    case gruvboxLightSoft = "gruvbox-light-soft"
    // 深色
    case ccDeskDark = "cc-desk-dark"
    case catppuccinMocha = "catppuccin-mocha"
    case rosePineMoon = "rose-pine-moon"
    case everforestDarkMedium = "everforest-dark-medium"
    case tokyoNightStorm = "tokyo-night-storm"
    case gruvboxDark = "gruvbox-dark"
    case nord

    public var id: String { rawValue }
    public var definition: ThemeDefinition { ThemeCatalog.definition(self) }
    public var kind: TerminalColorScheme {
        switch self {
        case .warmPaper, .catppuccinLatte, .rosePineDawn, .everforestLightSoft, .tokyoNightDay, .solarizedLight,
             .gruvboxLightSoft:
            return .light
        case .ccDeskDark, .catppuccinMocha, .rosePineMoon, .everforestDarkMedium, .tokyoNightStorm, .gruvboxDark, .nord:
            return .dark
        }
    }
}

/// 带透明度的颜色（阴影 / 遮罩用）。
public struct ThemeRGBA: Equatable, Sendable {
    public let rgb: UInt32
    public let alpha: Double

    public init(_ rgb: UInt32, _ alpha: Double) {
        self.rgb = rgb
        self.alpha = alpha
    }
}

/// 界面配色的语义色（0xRRGGBB），与 App 的 `Theme` 一一对应。
public struct ThemeTokens: Equatable, Sendable {
    public var side: UInt32
    public var main: UInt32
    public var line: UInt32
    public var fg1: UInt32
    public var fg2: UInt32
    public var fg3: UInt32
    public var chip: UInt32
    public var sel: UInt32
    public var selLine: UInt32
    public var selShadow: ThemeRGBA
    public var hover: UInt32
    public var waitRow: UInt32
    public var pillWaitBg: UInt32
    public var pillWaitFg: UInt32
    public var pillWorkBg: UInt32
    public var pillWorkFg: UInt32
    public var dot: UInt32
    public var chipWorkBg: UInt32
    public var chipWorkFg: UInt32
    public var unread: UInt32
    public var chipUnreadBg: UInt32
    public var chipUnreadFg: UInt32
    public var pillIdleBg: UInt32
    public var pillIdleFg: UInt32
    public var pillMissBg: UInt32
    public var pillMissFg: UInt32
    public var tileEmbBg: UInt32
    public var tileEmbFg: UInt32
    public var tileTermBg: UInt32
    public var tileTermFg: UInt32
    public var tileMissBg: UInt32
    public var tileMissFg: UInt32
    public var accent: UInt32
    public var action: UInt32
    public var extBg: UInt32
    public var extFg: UInt32
    public var extRing: UInt32
    public var appIconShadow: ThemeRGBA
    public var appIconShadowRadius: Double
    public var appIconRim: ThemeRGBA?
    public var backdrop: ThemeRGBA
    public var popShadow: ThemeRGBA

    /// 正文三级文字对主区与侧栏底色的最低对比度。
    public static let minimumTextContrast: (fg1: Double, fg2: Double, fg3: Double) = (5, 4, 3)

    /// 三级文字不达标时保持色相加深（浅色）/ 提亮（深色），与终端调色板同一规则。
    func normalized(_ kind: TerminalColorScheme) -> ThemeTokens {
        var t = self
        let backs = [main, side], lighten = kind == .dark
        let m = Self.minimumTextContrast
        t.fg1 = ColorMath.ensuring(fg1, contrast: m.fg1, against: backs, lighten: lighten)
        t.fg2 = ColorMath.ensuring(fg2, contrast: m.fg2, against: backs, lighten: lighten)
        t.fg3 = ColorMath.ensuring(fg3, contrast: m.fg3, against: backs, lighten: lighten)
        return t
    }
}

/// 从主题的几个基础色推导整套语义色（新加的主题用；早期手调过的主题直接写全套 `ThemeTokens`）。
/// 状态色的语义在各主题间保持一致：等待 = 暖橙 / 红，进行中 = 蓝，已完成 / 未读 = 绿，只换成该主题自己的色相。
struct ThemeSeed {
    var side: UInt32
    var main: UInt32
    var line: UInt32
    /// 计数胶囊 / 悬停 / 空闲胶囊底色。
    var chip: UInt32
    /// 选中行底色。
    var sel: UInt32
    var selLine: UInt32
    /// 内嵌会话图标底色（深色下也是外部 App 图标底）。
    var surface: UInt32
    var fg1: UInt32
    var fg2: UInt32
    var fg3: UInt32
    var wait: UInt32
    var work: UInt32
    var done: UInt32
    var miss: UInt32
    var accent: UInt32
    /// 浅色主题阴影的色相（一般取正文色）；深色主题用黑色。
    var shadow: UInt32 = 0x000000

    func tokens(_ kind: TerminalColorScheme) -> ThemeTokens {
        kind == .light ? lightTokens() : darkTokens()
    }

    private func ensure(_ color: UInt32, _ minimum: Double, _ backs: [UInt32], lighten: Bool) -> UInt32 {
        ColorMath.ensuring(color, contrast: minimum, against: backs, lighten: lighten)
    }

    private func lightTokens() -> ThemeTokens {
        let white: UInt32 = 0xFFFFFF
        let pillWorkBg = ColorMath.mix(main, work, 0.12)
        let pillMissBg = ColorMath.mix(main, miss, 0.10)
        let pillMissFg = ensure(ColorMath.mix(miss, fg2, 0.35), 4.5, [pillMissBg], lighten: false)
        let unread = ensure(done, 4.5, [main, side, white], lighten: false)
        return ThemeTokens(
            side: side, main: main, line: line, fg1: fg1, fg2: fg2, fg3: fg3, chip: chip,
            sel: sel, selLine: selLine, selShadow: ThemeRGBA(shadow, 0.08),
            hover: chip, waitRow: ColorMath.mix(main, wait, 0.12),
            pillWaitBg: ensure(wait, 4.5, [white], lighten: false), pillWaitFg: white,
            pillWorkBg: pillWorkBg, pillWorkFg: ensure(work, 4.5, [pillWorkBg], lighten: false), dot: work,
            chipWorkBg: ensure(work, 4.5, [white], lighten: false), chipWorkFg: white,
            unread: unread, chipUnreadBg: unread, chipUnreadFg: white,
            pillIdleBg: chip, pillIdleFg: ensure(fg2, 4.5, [chip], lighten: false),
            pillMissBg: pillMissBg, pillMissFg: pillMissFg,
            tileEmbBg: surface, tileEmbFg: ensure(fg1, 4.5, [surface], lighten: false),
            tileTermBg: chip, tileTermFg: ensure(fg3, 3, [chip], lighten: false),
            tileMissBg: pillMissBg, tileMissFg: pillMissFg,
            accent: ensure(accent, 4.5, [main], lighten: false), action: fg1,
            extBg: sel, extFg: fg2, extRing: selLine,
            appIconShadow: ThemeRGBA(shadow, 0.18), appIconShadowRadius: 1, appIconRim: nil,
            backdrop: ThemeRGBA(shadow, 0.16), popShadow: ThemeRGBA(shadow, 0.18))
    }

    private func darkTokens() -> ThemeTokens {
        let black: UInt32 = 0x000000
        let pillWaitFg = ColorMath.mix(wait, black, 0.85)
        let pillWorkBg = ColorMath.mix(main, work, 0.15)
        let chipWorkFg = ColorMath.mix(work, black, 0.85)
        let chipUnreadFg = ColorMath.mix(done, black, 0.85)
        let unread = ensure(done, 4.5, [main, side, chipUnreadFg], lighten: true)
        let pillMissBg = ColorMath.mix(main, miss, 0.14)
        let pillMissFg = ensure(ColorMath.mix(miss, fg1, 0.4), 4.5, [pillMissBg], lighten: true)
        return ThemeTokens(
            side: side, main: main, line: line, fg1: fg1, fg2: fg2, fg3: fg3, chip: chip,
            sel: sel, selLine: selLine, selShadow: ThemeRGBA(black, 0.35),
            hover: chip, waitRow: ColorMath.mix(main, wait, 0.12),
            pillWaitBg: ensure(wait, 4.5, [pillWaitFg], lighten: true), pillWaitFg: pillWaitFg,
            pillWorkBg: pillWorkBg, pillWorkFg: ensure(ColorMath.mix(work, fg1, 0.25), 4.5, [pillWorkBg], lighten: true),
            dot: work,
            chipWorkBg: ensure(work, 4.5, [chipWorkFg], lighten: true), chipWorkFg: chipWorkFg,
            unread: unread, chipUnreadBg: unread, chipUnreadFg: chipUnreadFg,
            pillIdleBg: chip, pillIdleFg: ensure(fg2, 4.5, [chip], lighten: true),
            pillMissBg: pillMissBg, pillMissFg: pillMissFg,
            tileEmbBg: surface, tileEmbFg: ensure(fg1, 4.5, [surface], lighten: true),
            tileTermBg: chip, tileTermFg: ensure(fg2, 3, [chip], lighten: true),
            tileMissBg: pillMissBg, tileMissFg: pillMissFg,
            accent: ensure(accent, 4.5, [main], lighten: true), action: fg1,
            extBg: surface, extFg: fg1, extRing: side,
            appIconShadow: ThemeRGBA(black, 0.6), appIconShadowRadius: 2, appIconRim: ThemeRGBA(0xFFFFFF, 0.55),
            backdrop: ThemeRGBA(black, 0.35), popShadow: ThemeRGBA(black, 0.45))
    }
}

/// 一个主题：界面语义色 + 终端调色板，均已按对比度下限修正过。
public struct ThemeDefinition: Sendable, Identifiable {
    public let id: ThemeID
    public let kind: TerminalColorScheme
    public let tokens: ThemeTokens
    public let palette: TerminalPalette

    init(id: ThemeID, kind: TerminalColorScheme, tokens: ThemeTokens, palette: TerminalPalette) {
        self.id = id
        self.kind = kind
        self.tokens = tokens.normalized(kind)
        self.palette = palette.enforcingContrast(for: kind)
    }

    init(id: ThemeID, kind: TerminalColorScheme, seed: ThemeSeed, palette: TerminalPalette) {
        self.init(id: id, kind: kind, tokens: seed.tokens(kind), palette: palette)
    }
}

/// 主题选择的持久化：UserDefaults 里存 `ThemeID` 原始值，读不到 / 明暗不符时用默认主题。
public enum ThemeSelection {
    public static let lightKey = "lightTheme"
    public static let darkKey = "darkTheme"
    public static let defaultLight = ThemeID.catppuccinLatte
    public static let defaultDark = ThemeID.ccDeskDark

    public static func key(_ kind: TerminalColorScheme) -> String { kind == .light ? lightKey : darkKey }
    public static func defaultID(_ kind: TerminalColorScheme) -> ThemeID { kind == .light ? defaultLight : defaultDark }

    /// 存储的原始值 -> 主题；无效或明暗不符时回退到该明暗的默认主题。
    public static func resolve(_ stored: String?, kind: TerminalColorScheme) -> ThemeID {
        guard let stored, let id = ThemeID(rawValue: stored), id.kind == kind else { return defaultID(kind) }
        return id
    }

    public static func stored(_ kind: TerminalColorScheme, defaults: UserDefaults = .standard) -> ThemeID {
        resolve(defaults.string(forKey: key(kind)), kind: kind)
    }

    public static func store(_ id: ThemeID, defaults: UserDefaults = .standard) {
        defaults.set(id.rawValue, forKey: key(id.kind))
    }
}

/// 主题目录（设计 §19）。官方调色板的出处见设计文档；不达标的终端色 / 文字色在构造时按规则修正。
public enum ThemeCatalog {
    public static let all: [ThemeDefinition] = [
        warmPaper, catppuccinLatte, rosePineDawn, everforestLightSoft, tokyoNightDay, solarizedLight, gruvboxLightSoft,
        ccDeskDark, catppuccinMocha, rosePineMoon, everforestDarkMedium, tokyoNightStorm, gruvboxDark, nord,
    ]

    public static func themes(_ kind: TerminalColorScheme) -> [ThemeDefinition] { all.filter { $0.kind == kind } }

    public static func definition(_ id: ThemeID) -> ThemeDefinition {
        // `all` 覆盖每个 ThemeID（有单元测试守住）；万一缺失按明暗回退到默认主题，避免崩溃。
        if let found = all.first(where: { $0.id == id }) { return found }
        return id.kind == .dark ? ccDeskDark : catppuccinLatte
    }

    // MARK: 浅色

    /// 暖纸：CC Desk 最初的奶油纸色（取自 docs/design/sidebar-mockup.html，提高过次级文字对比度）。
    static let warmPaper = ThemeDefinition(
        id: .warmPaper, kind: .light,
        tokens: ThemeTokens(
            side: 0xECE7DE, main: 0xF4EFE6, line: 0xDED6CA,
            fg1: 0x2A2622, fg2: 0x5F5B54, fg3: 0x736E66, chip: 0xE3DDD2,
            sel: 0xFAF7F1, selLine: 0xDCD4C7, selShadow: ThemeRGBA(0x3C3228, 0.08),
            hover: 0xE4DED3, waitRow: 0xF4E4D9,
            pillWaitBg: 0xC4552B, pillWaitFg: 0xFFFFFF,
            pillWorkBg: 0xE5ECF3, pillWorkFg: 0x35618E, dot: 0x4A7BAD,
            chipWorkBg: 0x3F6E9E, chipWorkFg: 0xFFFFFF,
            unread: 0x4F7D5B, chipUnreadBg: 0x4F7D5B, chipUnreadFg: 0xFFFFFF,
            pillIdleBg: 0xE5DFD5, pillIdleFg: 0x5C5852,
            pillMissBg: 0xF1E4E2, pillMissFg: 0x8E5A55,
            tileEmbBg: 0xDDD5C8, tileEmbFg: 0x3A362F,
            tileTermBg: 0xE5DFD5, tileTermFg: 0x6B675F,
            tileMissBg: 0xF1E4E2, tileMissFg: 0x8E5A55,
            accent: 0xB24E26, action: 0x2B2925,
            extBg: 0xFAF7F1, extFg: 0x5C5852, extRing: 0xD6CEC1,
            appIconShadow: ThemeRGBA(0x3C3228, 0.18), appIconShadowRadius: 1, appIconRim: nil,
            backdrop: ThemeRGBA(0x1E1914, 0.16), popShadow: ThemeRGBA(0x281E14, 0.18)),
        palette: TerminalPalette(
            background: 0xF4EFE6, foreground: 0x2E2A25,
            ansi: [
                0x2E2A25, 0xB23A2B, 0x3F7348, 0x8A6200, 0x2F5F8F, 0x8E4A84, 0x2A6F73, 0x6B655C,
                0x7D776E, 0xC5502F, 0x4E8A5C, 0xA07A1A, 0x4A7BAD, 0xA35F98, 0x3A878B, 0x8C857B,
            ]))

    /// Catppuccin Latte：base #EFF1F5 / mantle #E6E9EF / crust #DCE0E8，text #4C4F69。
    static let catppuccinLatte = ThemeDefinition(
        id: .catppuccinLatte, kind: .light,
        tokens: ThemeTokens(
            side: 0xE6E9EF, main: 0xEFF1F5, line: 0xCCD0DA,
            fg1: 0x4C4F69, fg2: 0x5C5F77, fg3: 0x6C6F85, chip: 0xDCE0E8,
            sel: 0xF7F8FA, selLine: 0xCCD0DA, selShadow: ThemeRGBA(0x4C4F69, 0.08),
            hover: 0xDCE0E8, waitRow: 0xF5E3DE,
            pillWaitBg: 0xC4552B, pillWaitFg: 0xFFFFFF,
            pillWorkBg: 0xE5ECF3, pillWorkFg: 0x35618E, dot: 0x4A7BAD,
            chipWorkBg: 0x3F6E9E, chipWorkFg: 0xFFFFFF,
            unread: 0x4F7D5B, chipUnreadBg: 0x4F7D5B, chipUnreadFg: 0xFFFFFF,
            pillIdleBg: 0xDCE0E8, pillIdleFg: 0x5C5F77,
            pillMissBg: 0xF1E4E2, pillMissFg: 0x8E5A55,
            tileEmbBg: 0xCCD0DA, tileEmbFg: 0x4C4F69,
            tileTermBg: 0xDCE0E8, tileTermFg: 0x6C6F85,
            tileMissBg: 0xF1E4E2, tileMissFg: 0x8E5A55,
            accent: 0xB24E26, action: 0x4C4F69,
            extBg: 0xF7F8FA, extFg: 0x5C5F77, extRing: 0xCCD0DA,
            appIconShadow: ThemeRGBA(0x4C4F69, 0.18), appIconShadowRadius: 1, appIconRim: nil,
            backdrop: ThemeRGBA(0x323750, 0.16), popShadow: ThemeRGBA(0x373C55, 0.18)),
        palette: TerminalPalette(
            background: 0xEFF1F5, foreground: 0x4C4F69,
            ansi: [
                0x5C5F77, 0xD20F39, 0x317B21, 0x976014, 0x145FF5, 0xC51E99, 0x13777D, 0x666C82,
                0x6C6F85, 0xDE293E, 0x419B36, 0xC07910, 0x456EFF, 0xCF4FAE, 0x2A969E, 0x81889F,
            ]))

    /// Rosé Pine Dawn：base #FAF4ED / surface #FFFAF3 / overlay #F2E9E1，text #575279。
    static let rosePineDawn = ThemeDefinition(
        id: .rosePineDawn, kind: .light,
        tokens: ThemeTokens(
            side: 0xF2E9E1, main: 0xFAF4ED, line: 0xDFDAD9,
            fg1: 0x575279, fg2: 0x6E6A86, fg3: 0x797593, chip: 0xEBE3DB,
            sel: 0xFFFAF3, selLine: 0xDFDAD9, selShadow: ThemeRGBA(0x575279, 0.08),
            hover: 0xEBE3DB, waitRow: 0xF6E3DC,
            pillWaitBg: 0xC4552B, pillWaitFg: 0xFFFFFF,
            pillWorkBg: 0xE5ECF3, pillWorkFg: 0x35618E, dot: 0x4A7BAD,
            chipWorkBg: 0x3F6E9E, chipWorkFg: 0xFFFFFF,
            unread: 0x4F7D5B, chipUnreadBg: 0x4F7D5B, chipUnreadFg: 0xFFFFFF,
            pillIdleBg: 0xEBE3DB, pillIdleFg: 0x625E7E,
            pillMissBg: 0xF1E4E2, pillMissFg: 0x8E5A55,
            tileEmbBg: 0xE4DCD4, tileEmbFg: 0x4E4A6E,
            tileTermBg: 0xEBE3DB, tileTermFg: 0x6E6A86,
            tileMissBg: 0xF1E4E2, tileMissFg: 0x8E5A55,
            accent: 0xB24E26, action: 0x575279,
            extBg: 0xFFFAF3, extFg: 0x625E7E, extRing: 0xDFDAD9,
            appIconShadow: ThemeRGBA(0x575279, 0.18), appIconShadowRadius: 1, appIconRim: nil,
            backdrop: ThemeRGBA(0x3C3755, 0.16), popShadow: ThemeRGBA(0x463C5A, 0.18)),
        palette: TerminalPalette(
            background: 0xFAF4ED, foreground: 0x575279,
            ansi: [
                0x575279, 0xAB526B, 0x286983, 0x9C6110, 0x45767F, 0x7D649A, 0xC1423C, 0x6F6B89,
                0x8B869A, 0xB4637A, 0x286983, 0xC17814, 0x55929C, 0x907AA9, 0xD06B67, 0x797593,
            ]))

    /// Everforest Light（Soft）：bg0 #F3EAD3 / bg1 #EAE4CA / bg3 #DDD8BE，fg #5C6A72。
    static let everforestLightSoft = ThemeDefinition(
        id: .everforestLightSoft, kind: .light,
        tokens: ThemeTokens(
            side: 0xEAE4CA, main: 0xF3EAD3, line: 0xDDD8BE,
            fg1: 0x4A565D, fg2: 0x5C6A72, fg3: 0x6A766E, chip: 0xE2DCC2,
            sel: 0xFBF6E6, selLine: 0xD5CFB6, selShadow: ThemeRGBA(0x463C1E, 0.08),
            hover: 0xE2DCC2, waitRow: 0xF2DFC8,
            pillWaitBg: 0xC4552B, pillWaitFg: 0xFFFFFF,
            pillWorkBg: 0xE5ECF3, pillWorkFg: 0x35618E, dot: 0x4A7BAD,
            chipWorkBg: 0x3F6E9E, chipWorkFg: 0xFFFFFF,
            unread: 0x4F7D5B, chipUnreadBg: 0x4F7D5B, chipUnreadFg: 0xFFFFFF,
            pillIdleBg: 0xE2DCC2, pillIdleFg: 0x55615A,
            pillMissBg: 0xF1E4E2, pillMissFg: 0x8E5A55,
            tileEmbBg: 0xDAD4BA, tileEmbFg: 0x45514A,
            tileTermBg: 0xE2DCC2, tileTermFg: 0x5C6A72,
            tileMissBg: 0xF1E4E2, tileMissFg: 0x8E5A55,
            accent: 0xB24E26, action: 0x4A565D,
            extBg: 0xFBF6E6, extFg: 0x55615A, extRing: 0xD5CFB6,
            appIconShadow: ThemeRGBA(0x463C1E, 0.18), appIconShadowRadius: 1, appIconRim: nil,
            backdrop: ThemeRGBA(0x322D19, 0.16), popShadow: ThemeRGBA(0x3C3219, 0.18)),
        palette: TerminalPalette(
            background: 0xF3EAD3, foreground: 0x525F66,
            ansi: [
                0x525F66, 0xC4332C, 0x616E01, 0x886200, 0x2B6F94, 0xB02C88, 0x257557, 0x5F6C5E,
                0x768675, 0xE0453E, 0x798A01, 0xA97A00, 0x3588B5, 0xD849AB, 0x2E926C, 0x708070,
            ]))

    /// Tokyo Night Day：bg #E1E2E7 / bg_dark #D0D5E3 / bg_highlight #C4C8DA，fg #3760BF。终端色取 extras/alacritty。
    static let tokyoNightDay = ThemeDefinition(
        id: .tokyoNightDay, kind: .light,
        seed: ThemeSeed(
            side: 0xD6D8E2, main: 0xE1E2E7, line: 0xC4C8DA, chip: 0xD0D5E3, sel: 0xEDEEF2, selLine: 0xC4C8DA,
            surface: 0xC4C8DA, fg1: 0x3760BF, fg2: 0x6172B0, fg3: 0x68709A,
            wait: 0xB15C00, work: 0x2E7DE9, done: 0x587539, miss: 0xC64343, accent: 0xB15C00, shadow: 0x3760BF),
        palette: TerminalPalette(
            background: 0xE1E2E7, foreground: 0x3760BF,
            ansi: [
                0xB4B5B9, 0xF52A65, 0x587539, 0x8C6C3E, 0x2E7DE9, 0x9854F1, 0x007197, 0x6172B0,
                0xA1A6C5, 0xFF4774, 0x5C8524, 0xA27629, 0x358AFF, 0xA463FF, 0x007EA8, 0x3760BF,
            ]))

    /// Solarized Light：base3 #FDF6E3 / base2 #EEE8D5，正文 base01 #586E75。
    /// 官方的 7「白」= base2、15「亮白」= base3 与底色几乎相同，按 HSL 加深会变成土黄；这里改用 base00 / base0（再按规则加深）。
    static let solarizedLight = ThemeDefinition(
        id: .solarizedLight, kind: .light,
        seed: ThemeSeed(
            side: 0xEEE8D5, main: 0xFDF6E3, line: 0xE0D9C3, chip: 0xE6DFCA, sel: 0xFFFBF0, selLine: 0xDDD6C1,
            surface: 0xE0D9C3, fg1: 0x073642, fg2: 0x586E75, fg3: 0x657B83,
            wait: 0xCB4B16, work: 0x268BD2, done: 0x859900, miss: 0xDC322F, accent: 0xCB4B16, shadow: 0x073642),
        palette: TerminalPalette(
            background: 0xFDF6E3, foreground: 0x586E75,
            ansi: [
                0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0x657B83,
                0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0x839496,
            ]))

    /// Gruvbox Light（Soft）：light0_soft #F2E5BC / light1 #EBDBB2 / light2 #D5C4A1，fg dark1 #3C3836。
    /// ANSI 0 官方取底色 #FBF1C7（「黑」与底同色）；这里按常规改为 dark1 #3C3836，其余为官方值。
    static let gruvboxLightSoft = ThemeDefinition(
        id: .gruvboxLightSoft, kind: .light,
        seed: ThemeSeed(
            side: 0xEBDBB2, main: 0xF2E5BC, line: 0xD5C4A1, chip: 0xE5D5AB, sel: 0xFBF1C7, selLine: 0xD5C4A1,
            surface: 0xD5C4A1, fg1: 0x3C3836, fg2: 0x504945, fg3: 0x665C54,
            wait: 0xAF3A03, work: 0x076678, done: 0x79740E, miss: 0x9D0006, accent: 0xAF3A03, shadow: 0x3C3836),
        palette: TerminalPalette(
            background: 0xF2E5BC, foreground: 0x3C3836,
            ansi: [
                0x3C3836, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0x7C6F64,
                0x928374, 0x9D0006, 0x79740E, 0xB57614, 0x076678, 0x8F3F71, 0x427B58, 0x3C3836,
            ]))

    // MARK: 深色

    /// CC Desk 深色：暖炭灰，与暖纸同一套色相。
    static let ccDeskDark = ThemeDefinition(
        id: .ccDeskDark, kind: .dark,
        tokens: ThemeTokens(
            side: 0x1F1E1C, main: 0x252422, line: 0x34322E,
            fg1: 0xEDEBE7, fg2: 0xA39E96, fg3: 0x8F8A82, chip: 0x2E2C29,
            sel: 0x33312D, selLine: 0x403D38, selShadow: ThemeRGBA(0x000000, 0.35),
            hover: 0x2A2825, waitRow: 0x2E211A,
            pillWaitBg: 0xE2875F, pillWaitFg: 0x1E120C,
            pillWorkBg: 0x22303D, pillWorkFg: 0x9DBBDA, dot: 0x82A8CF,
            chipWorkBg: 0x82A8CF, chipWorkFg: 0x101C27,
            unread: 0x8DB79A, chipUnreadBg: 0x8DB79A, chipUnreadFg: 0x102016,
            pillIdleBg: 0x2F2D2A, pillIdleFg: 0xB8B3AB,
            pillMissBg: 0x352826, pillMissFg: 0xC9A09A,
            tileEmbBg: 0x3A3732, tileEmbFg: 0xE2DDD5,
            tileTermBg: 0x2E2C29, tileTermFg: 0xA39E96,
            tileMissBg: 0x352826, tileMissFg: 0xC9A09A,
            accent: 0xE2875F, action: 0xEDEBE7,
            extBg: 0x4A4741, extFg: 0xF2EFEA, extRing: 0x1F1E1C,
            appIconShadow: ThemeRGBA(0x000000, 0.6), appIconShadowRadius: 2, appIconRim: ThemeRGBA(0xFFFFFF, 0.55),
            backdrop: ThemeRGBA(0x000000, 0.35), popShadow: ThemeRGBA(0x000000, 0.45)),
        palette: TerminalPalette(
            background: 0x1B1A18, foreground: 0xD8D3CB,
            ansi: [
                0x4A4640, 0xE06C5A, 0x8DB79A, 0xD9B061, 0x82A8CF, 0xC792BF, 0x7DB8B6, 0xCFC9BF,
                0x7A746B, 0xF08A70, 0xA6CDB1, 0xE9C77D, 0xA3C2E2, 0xDBA9D3, 0x9DD0CD, 0xF2EEE8,
            ]))

    /// Catppuccin Mocha：base #1E1E2E / mantle #181825 / surface0 #313244，text #CDD6F4。终端色取 catppuccin/alacritty。
    static let catppuccinMocha = ThemeDefinition(
        id: .catppuccinMocha, kind: .dark,
        seed: ThemeSeed(
            side: 0x181825, main: 0x1E1E2E, line: 0x313244, chip: 0x2A2B3C, sel: 0x313244, selLine: 0x45475A,
            surface: 0x45475A, fg1: 0xCDD6F4, fg2: 0xA6ADC8, fg3: 0x9399B2,
            wait: 0xFAB387, work: 0x89B4FA, done: 0xA6E3A1, miss: 0xF38BA8, accent: 0xFAB387),
        palette: TerminalPalette(
            background: 0x1E1E2E, foreground: 0xCDD6F4,
            ansi: [
                0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
                0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8,
            ]))

    /// Rosé Pine Moon：base #232136 / surface #2A273F / overlay #393552，text #E0DEF4。
    /// 官方调色板没有绿色：「已完成」用与 foam / pine 协调的灰绿 #9CCFA8。
    static let rosePineMoon = ThemeDefinition(
        id: .rosePineMoon, kind: .dark,
        seed: ThemeSeed(
            side: 0x232136, main: 0x2A273F, line: 0x393552, chip: 0x312D49, sel: 0x393552, selLine: 0x44415A,
            surface: 0x44415A, fg1: 0xE0DEF4, fg2: 0x908CAA, fg3: 0x6E6A86,
            wait: 0xEB6F92, work: 0x3E8FB0, done: 0x9CCFA8, miss: 0xEB6F92, accent: 0xEA9A97),
        palette: TerminalPalette(
            background: 0x232136, foreground: 0xE0DEF4,
            ansi: [
                0x393552, 0xEB6F92, 0x3E8FB0, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEA9A97, 0xE0DEF4,
                0x6E6A86, 0xEB6F92, 0x3E8FB0, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEA9A97, 0xE0DEF4,
            ]))

    /// Everforest Dark（Medium）：bg_dim #232A2E / bg0 #2D353B / bg1 #343F44 / bg2 #3D484D，fg #D3C6AA。
    static let everforestDarkMedium = ThemeDefinition(
        id: .everforestDarkMedium, kind: .dark,
        seed: ThemeSeed(
            side: 0x232A2E, main: 0x2D353B, line: 0x3D484D, chip: 0x343F44, sel: 0x3D484D, selLine: 0x475258,
            surface: 0x4F585E, fg1: 0xD3C6AA, fg2: 0x9DA9A0, fg3: 0x859289,
            wait: 0xE69875, work: 0x7FBBB3, done: 0xA7C080, miss: 0xE67E80, accent: 0xE69875),
        palette: TerminalPalette(
            background: 0x2D353B, foreground: 0xD3C6AA,
            ansi: [
                0x475258, 0xE67E80, 0xA7C080, 0xDBBC7F, 0x7FBBB3, 0xD699B6, 0x83C092, 0xD3C6AA,
                0x475258, 0xE67E80, 0xA7C080, 0xDBBC7F, 0x7FBBB3, 0xD699B6, 0x83C092, 0xD3C6AA,
            ]))

    /// Tokyo Night Storm：bg #24283B / bg_dark #1F2335 / bg_highlight #292E42，fg #C0CAF5。终端色取 extras/alacritty。
    static let tokyoNightStorm = ThemeDefinition(
        id: .tokyoNightStorm, kind: .dark,
        seed: ThemeSeed(
            side: 0x1F2335, main: 0x24283B, line: 0x3B4261, chip: 0x292E42, sel: 0x2F354E, selLine: 0x3B4261,
            surface: 0x414868, fg1: 0xC0CAF5, fg2: 0xA9B1D6, fg3: 0x737AA2,
            wait: 0xFF9E64, work: 0x7AA2F7, done: 0x9ECE6A, miss: 0xF7768E, accent: 0xFF9E64),
        palette: TerminalPalette(
            background: 0x24283B, foreground: 0xC0CAF5,
            ansi: [
                0x1D202F, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
                0x414868, 0xFF899D, 0x9FE044, 0xFABA4A, 0x8DB0FF, 0xC7A9FF, 0xA4DAFF, 0xC0CAF5,
            ]))

    /// Gruvbox Dark：dark0_hard #1D2021 / dark0 #282828 / dark1 #3C3836，fg light1 #EBDBB2。
    static let gruvboxDark = ThemeDefinition(
        id: .gruvboxDark, kind: .dark,
        seed: ThemeSeed(
            side: 0x1D2021, main: 0x282828, line: 0x3C3836, chip: 0x32302F, sel: 0x3C3836, selLine: 0x504945,
            surface: 0x504945, fg1: 0xEBDBB2, fg2: 0xBDAE93, fg3: 0xA89984,
            wait: 0xFE8019, work: 0x83A598, done: 0xB8BB26, miss: 0xFB4934, accent: 0xFE8019),
        palette: TerminalPalette(
            background: 0x282828, foreground: 0xEBDBB2,
            ansi: [
                0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
                0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
            ]))

    /// Nord：Polar Night nord0–3（#2E3440 #3B4252 #434C5E #4C566A），Snow Storm nord4 #D8DEE9。
    /// 侧栏比 nord0 略深一级；次级文字取官方 alacritty 的 dim_foreground #A5ABB6。
    static let nord = ThemeDefinition(
        id: .nord, kind: .dark,
        seed: ThemeSeed(
            side: 0x292E39, main: 0x2E3440, line: 0x3B4252, chip: 0x3B4252, sel: 0x434C5E, selLine: 0x4C566A,
            surface: 0x4C566A, fg1: 0xD8DEE9, fg2: 0xA5ABB6, fg3: 0x8690A2,
            wait: 0xD08770, work: 0x81A1C1, done: 0xA3BE8C, miss: 0xBF616A, accent: 0xD08770),
        palette: TerminalPalette(
            background: 0x2E3440, foreground: 0xD8DEE9,
            ansi: [
                0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
                0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4,
            ]))
}
