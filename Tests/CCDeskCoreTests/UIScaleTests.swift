import XCTest
@testable import CCDeskCore

final class UIScaleTests: XCTestCase {
    func testPresetFactorsAreOrderedAndStandardIsOne() {
        XCTAssertEqual(UIScalePreset.allCases, [.small, .standard, .large, .extraLarge])
        XCTAssertEqual(UIScalePreset.allCases.map(\.factor), [0.9, 1.0, 1.15, 1.3])
        XCTAssertEqual(UIScalePreset.default, .standard)
        XCTAssertEqual(UIScalePreset.default.factor, 1)
    }

    func testResolveFallsBackToStandard() {
        XCTAssertEqual(UIScalePreset.resolve(nil), .standard)
        XCTAssertEqual(UIScalePreset.resolve(""), .standard)
        XCTAssertEqual(UIScalePreset.resolve("huge"), .standard)
        for preset in UIScalePreset.allCases {
            XCTAssertEqual(UIScalePreset.resolve(preset.rawValue), preset)
        }
    }

    func testFontSizeRoundsToHalfPoint() {
        XCTAssertEqual(UIScaleMath.fontSize(12, factor: 1), 12)
        XCTAssertEqual(UIScaleMath.fontSize(12.5, factor: 1), 12.5)
        XCTAssertEqual(UIScaleMath.fontSize(12, factor: 1.15), 14)     // 13.8
        XCTAssertEqual(UIScaleMath.fontSize(11, factor: 1.3), 14.5)    // 14.3
        XCTAssertEqual(UIScaleMath.fontSize(11, factor: 0.9), 10)      // 9.9
        XCTAssertEqual(UIScaleMath.fontSize(6.5, factor: 0.9), 6)      // 5.85
    }

    func testMetricRoundsToWholePoints() {
        XCTAssertEqual(UIScaleMath.metric(28, factor: 1), 28)
        XCTAssertEqual(UIScaleMath.metric(28, factor: 1.3), 36)        // 36.4
        XCTAssertEqual(UIScaleMath.metric(30, factor: 1.15), 35)       // 34.5 → 35
        XCTAssertEqual(UIScaleMath.metric(36, factor: 0.9), 32)        // 32.4
        XCTAssertEqual(UIScaleMath.metric(1, factor: 0.9), 1)
    }

    func testScalingIsMonotonicAcrossPresets() {
        for base in [6.5, 9, 10.5, 11, 12, 12.5, 13, 18, 28, 30, 36] {
            let fonts = UIScalePreset.allCases.map { UIScaleMath.fontSize(base, factor: $0.factor) }
            let metrics = UIScalePreset.allCases.map { UIScaleMath.metric(base, factor: $0.factor) }
            XCTAssertEqual(fonts, fonts.sorted(), "font \(base)")
            XCTAssertEqual(metrics, metrics.sorted(), "metric \(base)")
        }
    }

    func testInvalidInputsAreHarmless() {
        XCTAssertEqual(UIScaleMath.fontSize(12, factor: 0), 12)
        XCTAssertEqual(UIScaleMath.fontSize(12, factor: .nan), 12)
        XCTAssertEqual(UIScaleMath.metric(28, factor: -2), 28)
        XCTAssertEqual(UIScaleMath.metric(0, factor: 1.3), 0)
        XCTAssertEqual(UIScaleMath.fontSize(0.4, factor: 0.9), 1)
    }
}
