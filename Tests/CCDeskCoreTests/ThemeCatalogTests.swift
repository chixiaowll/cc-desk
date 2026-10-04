import XCTest
@testable import CCDeskCore

final class ThemeCatalogTests: XCTestCase {
    // MARK: 目录

    func testCatalogCoversEveryIDOnceWithMatchingKind() {
        let ids = ThemeCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "主题 id 重复")
        XCTAssertEqual(Set(ids), Set(ThemeID.allCases))
        for theme in ThemeCatalog.all {
            XCTAssertEqual(theme.kind, theme.id.kind, theme.id.rawValue)
            XCTAssertEqual(ThemeCatalog.definition(theme.id).id, theme.id)
        }
        XCTAssertEqual(ThemeCatalog.themes(.light).count, 7)
        XCTAssertEqual(ThemeCatalog.themes(.dark).count, 7)
    }

    func testRawValuesAreStableAndCodable() throws {
        XCTAssertEqual(ThemeID.catppuccinLatte.rawValue, "catppuccin-latte")
        XCTAssertEqual(ThemeID.ccDeskDark.rawValue, "cc-desk-dark")
        let data = try JSONEncoder().encode([ThemeID.nord, .warmPaper])
        XCTAssertEqual(try JSONDecoder().decode([ThemeID].self, from: data), [.nord, .warmPaper])
    }

    /// 暖纸 / Latte / CC Desk 深色保留原来手调的配色。
    func testHandTunedThemesKeepTheirTokens() {
        XCTAssertEqual(ThemeID.warmPaper.definition.tokens.main, 0xF4EFE6)
        XCTAssertEqual(ThemeID.warmPaper.definition.tokens.fg1, 0x2A2622)
        XCTAssertEqual(ThemeID.catppuccinLatte.definition.tokens.side, 0xE6E9EF)
        XCTAssertEqual(ThemeID.ccDeskDark.definition.tokens.main, 0x252422)
        XCTAssertEqual(ThemeID.ccDeskDark.definition.tokens.accent, 0xE2875F)
    }

    // MARK: 界面对比度

    func testTextTokensContrastAgainstMainAndSide() {
        for theme in ThemeCatalog.all {
            let t = theme.tokens, name = theme.id.rawValue
            for back in [t.main, t.side] {
                XCTAssertGreaterThanOrEqual(ColorContrast.ratio(t.fg1, back), 5, "\(name) fg1")
                XCTAssertGreaterThanOrEqual(ColorContrast.ratio(t.fg2, back), 4, "\(name) fg2")
                XCTAssertGreaterThanOrEqual(ColorContrast.ratio(t.fg3, back), 3, "\(name) fg3")
            }
            // 强调色提示与「已完成」状态色也直接写在主区上（多为图标 / 粗体短字）：≥ 3.5:1。
            XCTAssertGreaterThanOrEqual(ColorContrast.ratio(t.accent, t.main), 3.5, "\(name) accent")
            XCTAssertGreaterThanOrEqual(ColorContrast.ratio(t.unread, t.main), 3.5, "\(name) unread")
        }
    }

    /// 胶囊 / 计数 / 图标上的文字（粗体小字）≥ 4:1，终端图标的次级字 ≥ 3:1。
    func testStatusPillsAndTilesAreReadable() {
        for theme in ThemeCatalog.all {
            let t = theme.tokens, name = theme.id.rawValue
            let pairs: [(String, UInt32, UInt32, Double)] = [
                ("pillWait", t.pillWaitFg, t.pillWaitBg, 4),
                ("pillWork", t.pillWorkFg, t.pillWorkBg, 4),
                ("chipWork", t.chipWorkFg, t.chipWorkBg, 4),
                ("chipUnread", t.chipUnreadFg, t.chipUnreadBg, 4),
                ("pillIdle", t.pillIdleFg, t.pillIdleBg, 4),
                ("pillMiss", t.pillMissFg, t.pillMissBg, 4),
                ("tileEmb", t.tileEmbFg, t.tileEmbBg, 4),
                ("tileTerm", t.tileTermFg, t.tileTermBg, 3),
                ("tileMiss", t.tileMissFg, t.tileMissBg, 4),
            ]
            for (label, fg, bg, minimum) in pairs {
                XCTAssertGreaterThanOrEqual(ColorContrast.ratio(fg, bg), minimum, "\(name) \(label)")
            }
        }
    }

    /// 状态色语义跨主题一致：等待偏暖（红 / 橙），进行中偏蓝，已完成偏绿。
    func testStatusHuesStayRecognizable() {
        func hue(_ hex: UInt32) -> Double { ColorMath.hsl(hex).h }
        for theme in ThemeCatalog.all {
            let t = theme.tokens, name = theme.id.rawValue
            let wait = hue(t.pillWaitBg)
            XCTAssertTrue(wait >= 330 || wait <= 40, "\(name) wait hue \(wait)")
            // Gruvbox 的「蓝」偏青（约 157°）、「绿」偏橄榄（约 57°），仍在可辨认的范围里。
            XCTAssertTrue((150...250).contains(hue(t.dot)), "\(name) work hue \(hue(t.dot))")
            XCTAssertTrue((50...160).contains(hue(t.unread)), "\(name) done hue \(hue(t.unread))")
        }
    }

    // MARK: 持久化

    func testResolveFallsBackToDefaultsForMissingInvalidOrWrongKind() {
        XCTAssertEqual(ThemeSelection.resolve(nil, kind: .light), .catppuccinLatte)
        XCTAssertEqual(ThemeSelection.resolve(nil, kind: .dark), .ccDeskDark)
        XCTAssertEqual(ThemeSelection.resolve("bogus", kind: .light), .catppuccinLatte)
        XCTAssertEqual(ThemeSelection.resolve("nord", kind: .light), .catppuccinLatte)
        XCTAssertEqual(ThemeSelection.resolve("nord", kind: .dark), .nord)
        XCTAssertEqual(ThemeSelection.resolve("solarized-light", kind: .light), .solarizedLight)
    }

    func testStoreAndReadBackPerKind() throws {
        let suite = "ThemeCatalogTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ThemeSelection.stored(.light, defaults: defaults), .catppuccinLatte)
        ThemeSelection.store(.gruvboxLightSoft, defaults: defaults)
        ThemeSelection.store(.tokyoNightStorm, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "lightTheme"), "gruvbox-light-soft")
        XCTAssertEqual(defaults.string(forKey: "darkTheme"), "tokyo-night-storm")
        XCTAssertEqual(ThemeSelection.stored(.light, defaults: defaults), .gruvboxLightSoft)
        XCTAssertEqual(ThemeSelection.stored(.dark, defaults: defaults), .tokyoNightStorm)
    }

    // MARK: 颜色运算

    func testEnsuringKeepsPassingColorsAndFixesFailingOnesKeepingHue() {
        XCTAssertEqual(ColorMath.ensuring(0x000000, contrast: 4.5, against: [0xFFFFFF], lighten: false), 0x000000)
        let fixed = ColorMath.ensuring(0xDC322F, contrast: 7, against: [0xFDF6E3], lighten: false)
        XCTAssertGreaterThanOrEqual(ColorContrast.ratio(fixed, 0xFDF6E3), 7)
        XCTAssertEqual(ColorMath.hsl(fixed).h, ColorMath.hsl(0xDC322F).h, accuracy: 3)
        let lifted = ColorMath.ensuring(0x4C566A, contrast: 3, against: [0x2E3440], lighten: true)
        XCTAssertGreaterThanOrEqual(ColorContrast.ratio(lifted, 0x2E3440), 3)
        XCTAssertGreaterThan(ColorMath.hsl(lifted).l, ColorMath.hsl(0x4C566A).l)
    }

    func testHSLRoundTripAndMix() {
        for hex: UInt32 in [0x000000, 0xFFFFFF, 0xB24E26, 0x3760BF, 0x8DB79A, 0x7F7F7F] {
            XCTAssertEqual(ColorMath.hex(h: ColorMath.hsl(hex).h, s: ColorMath.hsl(hex).s, l: ColorMath.hsl(hex).l), hex)
        }
        XCTAssertEqual(ColorMath.mix(0x000000, 0xFFFFFF, 0.5), 0x808080)
        XCTAssertEqual(ColorMath.mix(0x123456, 0xABCDEF, 0), 0x123456)
        XCTAssertEqual(ColorMath.mix(0x123456, 0xABCDEF, 1), 0xABCDEF)
    }

    /// 打印每个主题修正后的关键色，供设计文档核对（不做断言）。
    func testDumpKeyColors() {
        func h(_ v: UInt32) -> String { String(format: "#%06X", v) }
        for theme in ThemeCatalog.all {
            let t = theme.tokens, p = theme.palette
            print("THEME \(theme.id.rawValue): side \(h(t.side)) main \(h(t.main)) fg1 \(h(t.fg1)) fg2 \(h(t.fg2)) "
                  + "fg3 \(h(t.fg3)) accent \(h(t.accent)) wait \(h(t.pillWaitBg)) work \(h(t.dot)) done \(h(t.unread)) "
                  + "term \(h(p.background))/\(h(p.foreground)) ansi \(p.ansi.map(h).joined(separator: " "))")
        }
    }
}
