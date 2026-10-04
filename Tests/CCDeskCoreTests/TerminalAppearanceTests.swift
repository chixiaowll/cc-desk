import XCTest
@testable import CCDeskCore

final class TerminalAppearanceTests: XCTestCase {
    func testContrastRatioMatchesWCAGReferences() {
        XCTAssertEqual(ColorContrast.ratio(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
        XCTAssertEqual(ColorContrast.ratio(0xFFFFFF, 0xFFFFFF), 1, accuracy: 0.0001)
        // WebAIM 参考值：#767676 对白色 4.54:1。
        XCTAssertEqual(ColorContrast.ratio(0x767676, 0xFFFFFF), 4.54, accuracy: 0.01)
        XCTAssertEqual(ColorContrast.ratio(0x123456, 0xABCDEF), ColorContrast.ratio(0xABCDEF, 0x123456))
    }

    func testEveryCatalogPaletteHasSixteenColors() {
        for theme in ThemeCatalog.all {
            XCTAssertEqual(theme.palette.ansi.count, 16, theme.id.rawValue)
        }
        XCTAssertEqual(ThemeCatalog.definition(.catppuccinLatte).palette.background, 0xEFF1F5)
        XCTAssertEqual(ThemeCatalog.definition(.ccDeskDark).palette.background, 0x1B1A18)
    }

    /// 浅色：普通色 0–7（含「白」）≥ 4.5:1，明亮色 8–15 ≥ 3:1；前景 ≥ 5:1
    ///（低眩光主题刻意降低对比以减少刺眼，正文仍明显高于 WCAG AA 的 4.5:1）。
    func testLightPaletteContrastForEveryLightTheme() {
        for theme in ThemeCatalog.themes(.light) {
            let p = theme.palette, name = theme.id.rawValue
            XCTAssertGreaterThanOrEqual(ColorContrast.ratio(p.foreground, p.background), 5, name)
            for i in 0..<8 {
                XCTAssertGreaterThanOrEqual(ColorContrast.ratio(p.ansi[i], p.background), 4.5, "\(name) ansi \(i)")
            }
            for i in 8..<16 {
                XCTAssertGreaterThanOrEqual(ColorContrast.ratio(p.ansi[i], p.background), 3, "\(name) ansi \(i)")
            }
        }
    }

    /// 深色：前景 ≥ 7:1，1–7 与 9–15 ≥ 4.5:1，8（亮黑）≥ 3:1；0 黑是背景类颜色，不要求。
    func testDarkPaletteContrastForEveryDarkTheme() {
        for theme in ThemeCatalog.themes(.dark) {
            let p = theme.palette, name = theme.id.rawValue
            XCTAssertGreaterThanOrEqual(ColorContrast.ratio(p.foreground, p.background), 7, name)
            for i in Array(1..<8) + Array(9..<16) {
                XCTAssertGreaterThanOrEqual(ColorContrast.ratio(p.ansi[i], p.background), 4.5, "\(name) ansi \(i)")
            }
            XCTAssertGreaterThanOrEqual(ColorContrast.ratio(p.ansi[8], p.background), 3, name)
        }
    }

    func testColorFGBGAndThemeReport() {
        XCTAssertEqual(TerminalColorScheme.light.colorFGBG, "0;15")
        XCTAssertEqual(TerminalColorScheme.dark.colorFGBG, "15;0")
        XCTAssertEqual(TerminalColorScheme.dark.themeReport, "\u{1b}[?997;1n")
        XCTAssertEqual(TerminalColorScheme.light.themeReport, "\u{1b}[?997;2n")
        XCTAssertTrue(TmuxVersion(major: 3, minor: 6) >= TmuxVersion.themeReports)
        XCTAssertFalse(TmuxVersion(major: 3, minor: 5) >= TmuxVersion.themeReports)
    }

    func testComponents() {
        let c = TerminalPalette.components(0xB23A2B)
        XCTAssertEqual([c.red, c.green, c.blue], [0xB2, 0x3A, 0x2B])
    }

    // MARK: 字体

    func testAutoPrefersInstalledCJKMonospaceInOrder() {
        XCTAssertEqual(TerminalFontChoice.resolve(family: nil, installed: ["Menlo", "Sarasa Mono SC", "Maple Mono CN"]),
                       "Maple Mono CN")
        XCTAssertEqual(TerminalFontChoice.resolve(family: "", installed: ["Menlo", "Noto Sans Mono CJK SC"]),
                       "Noto Sans Mono CJK SC")
        XCTAssertNil(TerminalFontChoice.resolve(family: nil, installed: ["Menlo", "Monaco"]))
    }

    func testExplicitFamilyWinsAndFallsBackWhenUninstalled() {
        XCTAssertEqual(TerminalFontChoice.resolve(family: "Menlo", installed: ["Menlo", "Maple Mono NF CN"]), "Menlo")
        XCTAssertEqual(TerminalFontChoice.resolve(family: "Gone Mono", installed: ["Menlo", "Maple Mono NF CN"]),
                       "Maple Mono NF CN")
        XCTAssertNil(TerminalFontChoice.resolve(family: "Gone Mono", installed: ["Menlo"]))
    }

    func testFontSizeIsClampedAndRounded() {
        XCTAssertEqual(TerminalFontChoice.clampedSize(0), 13)
        XCTAssertEqual(TerminalFontChoice.clampedSize(.nan), 13)
        XCTAssertEqual(TerminalFontChoice.clampedSize(9), 11)
        XCTAssertEqual(TerminalFontChoice.clampedSize(30), 18)
        XCTAssertEqual(TerminalFontChoice.clampedSize(14.4), 14)
    }
}
