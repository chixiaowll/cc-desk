import XCTest
@testable import CCDeskCore

final class VoiceHotkeyTests: XCTestCase {
    func testHoldLongEnoughThenReleaseFinishes() {
        var m = VoiceHotkey()
        XCTAssertEqual(m.press(at: 10), .beginCapture)
        XCTAssertEqual(m.tick(at: 10.1), .none)
        XCTAssertEqual(m.tick(at: 10.35), .reveal)
        XCTAssertEqual(m.tick(at: 10.5), .none, "reveal fires only once")
        XCTAssertEqual(m.release(at: 11), .finish)
        XCTAssertFalse(m.isHolding)
    }

    func testShortPressIsDiscarded() {
        var m = VoiceHotkey()
        XCTAssertEqual(m.press(at: 0), .beginCapture)
        XCTAssertEqual(m.release(at: 0.2), .discard)
        XCTAssertFalse(m.isHolding)
    }

    func testReleaseAfterThresholdWithoutTickStillFinishes() {
        var m = VoiceHotkey()
        _ = m.press(at: 0)
        XCTAssertEqual(m.release(at: 0.31), .finish)
    }

    func testOtherKeyWhileHoldingDiscardsAndIgnoresRelease() {
        var m = VoiceHotkey()
        _ = m.press(at: 0)
        XCTAssertEqual(m.interrupt(), .discard)
        XCTAssertFalse(m.isHolding)
        XCTAssertEqual(m.tick(at: 1), .none)
        XCTAssertEqual(m.release(at: 2), .none)
    }

    func testEscapeCancels() {
        var m = VoiceHotkey()
        _ = m.press(at: 0)
        _ = m.tick(at: 0.5)
        XCTAssertEqual(m.escape(), .cancel)
        XCTAssertEqual(m.release(at: 1), .none)
    }

    func testIdleEventsDoNothing() {
        var m = VoiceHotkey()
        XCTAssertEqual(m.release(at: 1), .none)
        XCTAssertEqual(m.interrupt(), .none)
        XCTAssertEqual(m.escape(), .none)
        XCTAssertEqual(m.tick(at: 1), .none)
    }

    func testRepeatedPressWhileHoldingIsIgnored() {
        var m = VoiceHotkey()
        _ = m.press(at: 0)
        XCTAssertEqual(m.press(at: 0.1), .none)
        XCTAssertEqual(m.release(at: 1), .finish)
    }

    func testMaxDurationAutoFinishes() {
        var m = VoiceHotkey(minHold: 0.3, maxDuration: 60)
        _ = m.press(at: 0)
        _ = m.tick(at: 1)
        XCTAssertEqual(m.tick(at: 60), .finish)
        XCTAssertFalse(m.isHolding)
        XCTAssertEqual(m.release(at: 61), .none)
    }

    func testCanPressAgainAfterFinish() {
        var m = VoiceHotkey()
        _ = m.press(at: 0)
        _ = m.release(at: 1)
        XCTAssertEqual(m.press(at: 2), .beginCapture)
    }
}

final class VoiceKeyTests: XCTestCase {
    // NSEvent.ModifierFlags.option = 1<<19；设备相关位：左 ⌥ 0x20、右 ⌥ 0x40。
    let option: UInt = 1 << 19
    let shift: UInt = 1 << 17

    func testRightOptionDownAlone() {
        XCTAssertEqual(VoiceKey.classify(keyCode: 61, flags: option | 0x40), .rightOptionDown)
    }

    func testRightOptionUp() {
        XCTAssertEqual(VoiceKey.classify(keyCode: 61, flags: 0), .rightOptionUp)
    }

    func testRightOptionUpWhileLeftStillHeld() {
        XCTAssertEqual(VoiceKey.classify(keyCode: 61, flags: option | 0x20), .rightOptionUp)
    }

    func testRightOptionDownWithOtherModifierIsOther() {
        XCTAssertEqual(VoiceKey.classify(keyCode: 61, flags: option | 0x40 | shift), .otherModifier)
        XCTAssertEqual(VoiceKey.classify(keyCode: 61, flags: option | 0x40 | 0x20), .otherModifier)
    }

    func testLeftOptionIsOther() {
        XCTAssertEqual(VoiceKey.classify(keyCode: 58, flags: option | 0x20), .otherModifier)
        XCTAssertEqual(VoiceKey.classify(keyCode: 58, flags: 0), .otherModifier)
    }

    func testCapsLockOnDoesNotBlockRightOption() {
        let capsLock: UInt = 1 << 16
        XCTAssertEqual(VoiceKey.classify(keyCode: 61, flags: option | 0x40 | capsLock), .rightOptionDown)
    }
}

final class TranscriptCleanerTests: XCTestCase {
    func testTrimAndCollapseWhitespace() {
        XCTAssertEqual(TranscriptCleaner.clean("  run   the\n tests  "), "run the tests")
    }

    func testRemovesSpacesBetweenChineseButKeepsAroundEnglish() {
        XCTAssertEqual(TranscriptCleaner.clean("帮我 把这个函数 改成 async 的"), "帮我把这个函数改成 async 的")
    }

    func testJoinsChineseLinesWithoutSpace() {
        XCTAssertEqual(TranscriptCleaner.clean("帮我改一下\n然后跑测试"), "帮我改一下然后跑测试")
    }

    func testTraditionalToSimplified() {
        XCTAssertEqual(TranscriptCleaner.clean("幫我把這個函數改成異步的"), "帮我把这个函数改成异步的")
    }

    func testStripsSpecialTokens() {
        XCTAssertEqual(TranscriptCleaner.clean("<|startoftranscript|><|zh|>你好<|endoftext|>"), "你好")
    }

    func testStripsBracketedNonSpeech() {
        XCTAssertEqual(TranscriptCleaner.clean("[音乐] 你好 [Music]"), "你好")
        XCTAssertEqual(TranscriptCleaner.clean("【掌声】你好"), "你好")
    }

    func testStripsSubtitleCreditsInParentheses() {
        XCTAssertEqual(TranscriptCleaner.clean("你好（字幕由 Amara.org 社区提供）"), "你好")
        XCTAssertEqual(TranscriptCleaner.clean("(字幕制作:贝尔)你好"), "你好")
    }

    func testKeepsOrdinaryParentheses() {
        XCTAssertEqual(TranscriptCleaner.clean("调用 foo(bar) 函数"), "调用 foo(bar) 函数")
    }

    func testDropsKnownHallucinationLines() {
        XCTAssertEqual(TranscriptCleaner.clean("请不吝点赞 订阅 转发 打赏支持明镜与点点栏目"), "")
        XCTAssertEqual(TranscriptCleaner.clean("跑一下测试\n谢谢观看!"), "跑一下测试")
        XCTAssertEqual(TranscriptCleaner.clean("Thank you for watching."), "")
    }

    func testCollapsesRepeatedLines() {
        XCTAssertEqual(TranscriptCleaner.clean("跑一下测试\n跑一下测试\n跑一下测试"), "跑一下测试")
    }

    func testCollapsesRepeatedSentences() {
        XCTAssertEqual(TranscriptCleaner.clean("好的。好的。好的。然后提交"), "好的。然后提交")
    }

    func testDropsReplacementCharacters() {
        XCTAssertEqual(TranscriptCleaner.clean("帮我跑一下测试\u{FFFD}"), "帮我跑一下测试")
        XCTAssertEqual(TranscriptCleaner.clean("\u{FFFD}"), "")
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(TranscriptCleaner.clean("   \n "), "")
    }
}
