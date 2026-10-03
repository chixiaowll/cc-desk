import XCTest
@testable import CCDeskCore

final class SpeechVoiceRankingTests: XCTestCase {
    private let voices = [
        SpeechVoiceInfo(identifier: "tingting", name: "Tingting", language: "zh-CN", quality: .standard),
        SpeechVoiceInfo(identifier: "lili-premium", name: "Lili", language: "zh-CN", quality: .premium),
        SpeechVoiceInfo(identifier: "yu-shu-enh", name: "Yu-shu", language: "zh-CN", quality: .enhanced),
        SpeechVoiceInfo(identifier: "meijia", name: "Meijia", language: "zh-TW", quality: .premium),
        SpeechVoiceInfo(identifier: "samantha", name: "Samantha", language: "en-US", quality: .standard),
        SpeechVoiceInfo(identifier: "zoe", name: "Zoe", language: "en-US", quality: .enhanced),
        SpeechVoiceInfo(identifier: "bells", name: "Bells", language: "en-US", quality: .premium, isNovelty: true),
    ]

    func testPrefersPremiumThenEnhancedInPreferredLocale() {
        XCTAssertEqual(SpeechVoiceRanking.candidates(voices, uiLanguage: "zh-Hans").map(\.identifier),
                       ["lili-premium", "yu-shu-enh", "tingting"])
        XCTAssertEqual(SpeechVoiceRanking.best(voices, uiLanguage: "zh-Hans")?.identifier, "lili-premium")
        XCTAssertEqual(SpeechVoiceRanking.best(voices, uiLanguage: "en")?.identifier, "zoe")
    }

    func testUserChoiceWinsWhenInstalled() {
        XCTAssertEqual(SpeechVoiceRanking.best(voices, uiLanguage: "zh-Hans", preferredID: "tingting")?.identifier, "tingting")
        XCTAssertEqual(SpeechVoiceRanking.best(voices, uiLanguage: "zh-Hans", preferredID: "gone")?.identifier, "lili-premium")
    }

    func testFallsBackToSameLanguageOtherRegion() {
        let onlyTW = voices.filter { $0.language == "zh-TW" }
        XCTAssertEqual(SpeechVoiceRanking.best(onlyTW, uiLanguage: "zh-Hans")?.identifier, "meijia")
        XCTAssertNil(SpeechVoiceRanking.best([], uiLanguage: "zh-Hans"))
    }

    func testQualityHint() {
        XCTAssertFalse(SpeechVoiceRanking.needsQualityHint(voices, uiLanguage: "zh-Hans"))
        let basic = voices.filter { $0.quality == .standard }
        XCTAssertTrue(SpeechVoiceRanking.needsQualityHint(basic, uiLanguage: "zh-Hans"))
        XCTAssertTrue(SpeechVoiceRanking.needsQualityHint([], uiLanguage: "zh-Hans"))
    }
}
