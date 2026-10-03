import XCTest
@testable import CCDeskCore

/// 合成音频：静音 = 0，「语音」= 200ms 正弦 + 100ms 很弱的间隙（模拟音节，避免被滚动噪声底当成稳态噪声）。
private enum Synth {
    static let rate = 16_000

    static func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(rate)))
    }

    static func tone(_ seconds: Double, amplitude: Float = 0.1) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { i in amplitude * sinf(Float(i) * 2 * .pi * 220 / Float(rate)) }
    }

    static func speech(_ seconds: Double, amplitude: Float = 0.1) -> [Float] {
        var out: [Float] = []
        while Double(out.count) < seconds * Double(rate) {
            out += tone(0.2, amplitude: amplitude)
            out += tone(0.1, amplitude: 0.001)
        }
        return Array(out.prefix(Int(seconds * Double(rate))))
    }
}

final class VoiceActivityDetectorTests: XCTestCase {
    private func run(_ samples: [Float], chunk: Int = 1600, vad: inout VoiceActivityDetector) -> [VoiceActivityDetector.Event] {
        var events: [VoiceActivityDetector.Event] = []
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + chunk)
            events += vad.process(Array(samples[i..<end]))
            i = end
        }
        return events
    }

    private func utterances(_ events: [VoiceActivityDetector.Event]) -> [[Float]] {
        events.compactMap { if case .utterance(let s) = $0 { return s } else { return nil } }
    }

    private func seconds(_ samples: [Float]) -> Double { Double(samples.count) / 16_000 }

    func testSilenceProducesNothing() {
        var vad = VoiceActivityDetector()
        XCTAssertEqual(run(Synth.silence(5), vad: &vad), [])
    }

    func testSingleUtteranceAfterSilence() {
        var vad = VoiceActivityDetector()
        let events = run(Synth.silence(1) + Synth.speech(2) + Synth.silence(1.5), vad: &vad)
        XCTAssertEqual(events.first, .speechStarted)
        let segs = utterances(events)
        XCTAssertEqual(segs.count, 1)
        // 前置 0.3s + 约 2s 语音 + 尾部 ≤0.3s
        XCTAssertEqual(seconds(segs[0]), 2.5, accuracy: 0.25)
        XCTAssertFalse(vad.isSpeaking)
    }

    func testUtteranceNeedsOneSecondOfSilenceToEnd() {
        var vad = VoiceActivityDetector()
        let events = run(Synth.silence(1) + Synth.speech(2) + Synth.silence(0.8), vad: &vad)
        XCTAssertEqual(utterances(events).count, 0)
        XCTAssertTrue(vad.isSpeaking)
        XCTAssertEqual(utterances(run(Synth.silence(0.3), vad: &vad)).count, 1)
    }

    func testShortBurstIsDiscarded() {
        var vad = VoiceActivityDetector()
        let events = run(Synth.silence(1) + Synth.tone(0.2) + Synth.silence(1.5), vad: &vad)
        XCTAssertEqual(events, [.speechStarted, .discarded])
    }

    func testSingleClickDoesNotStartSpeech() {
        var vad = VoiceActivityDetector()
        XCTAssertEqual(run(Synth.silence(1) + Synth.tone(0.03) + Synth.silence(1.5), vad: &vad), [])
    }

    func testShortPauseKeepsOneUtteranceLongPauseSplits() {
        var vad = VoiceActivityDetector()
        let one = run(Synth.silence(1) + Synth.speech(1) + Synth.silence(0.5) + Synth.speech(1) + Synth.silence(1.5),
                      vad: &vad)
        XCTAssertEqual(utterances(one).count, 1)

        var vad2 = VoiceActivityDetector()
        let two = run(Synth.silence(1) + Synth.speech(1) + Synth.silence(1.5) + Synth.speech(1) + Synth.silence(1.5),
                      vad: &vad2)
        XCTAssertEqual(utterances(two).count, 2)
    }

    func testMaxDurationSplitsLongSpeech() {
        var vad = VoiceActivityDetector()
        let events = run(Synth.silence(1) + Synth.speech(35) + Synth.silence(1.5), vad: &vad)
        let segs = utterances(events)
        XCTAssertEqual(segs.count, 2)
        XCTAssertLessThanOrEqual(seconds(segs[0]), 30.5)
        XCTAssertGreaterThan(seconds(segs[0]), 29)
        XCTAssertEqual(seconds(segs[1]), 5.5, accuracy: 0.6)
    }

    func testChunkSizeDoesNotMatter() {
        let audio = Synth.silence(1) + Synth.speech(1.5) + Synth.silence(1.2) + Synth.speech(0.8) + Synth.silence(1.5)
        var a = VoiceActivityDetector()
        var b = VoiceActivityDetector()
        XCTAssertEqual(run(audio, chunk: 333, vad: &a), run(audio, chunk: 4096, vad: &b))
    }

    func testSteadyHumIsNotSpeechButSpeechOverHumIs() {
        let hum = Synth.tone(6, amplitude: 0.01)
        var vad = VoiceActivityDetector()
        XCTAssertEqual(utterances(run(hum, vad: &vad)).count, 0)

        let speech = Synth.speech(1.5, amplitude: 0.15)
        let humAgain = Synth.tone(1.5, amplitude: 0.01)
        let mixed = zip(speech, Synth.tone(1.5, amplitude: 0.01)).map { $0 + $1 }
        XCTAssertEqual(utterances(run(mixed + humAgain, vad: &vad)).count, 1)
    }

    func testResetDropsPartialUtterance() {
        var vad = VoiceActivityDetector()
        _ = run(Synth.silence(1) + Synth.speech(1), vad: &vad)
        XCTAssertTrue(vad.isSpeaking)
        vad.reset()
        XCTAssertFalse(vad.isSpeaking)
        XCTAssertEqual(utterances(run(Synth.silence(1.5), vad: &vad)).count, 0)
    }
}

final class ConversationCommandTests: XCTestCase {
    func parse(_ s: String, waiting: Bool = false) -> ConversationCommand? {
        ConversationCommands.parse(s, waiting: waiting)
    }

    func testSendVariants() {
        for s in ["发送", "发送。", "发送吧", "发出去", "提交", "提交了", "Send.", "send it", "Submit!", "嗯，发送", "發送", "好，发送吧"] {
            XCTAssertEqual(parse(s), .send, s)
        }
    }

    func testCancelVariants() {
        for s in ["取消", "清空", "算了", "算了吧", "Cancel.", "clear", "Never mind."] {
            XCTAssertEqual(parse(s), .cancel, s)
        }
    }

    func testStopVariants() {
        for s in ["退出对话模式", "停止对话", "退出对话模式吧。", "Stop listening.", "exit conversation mode"] {
            XCTAssertEqual(parse(s), .stop, s)
        }
    }

    func testApprovalOnlyWhileWaiting() {
        for s in ["同意", "可以", "好的", "是", "确认", "是的。", "Yes.", "approve", "可以啊"] {
            XCTAssertEqual(parse(s, waiting: true), .approve, s)
            XCTAssertNil(parse(s, waiting: false), s)
        }
        for s in ["拒绝", "不行", "不要", "否", "No.", "deny"] {
            XCTAssertEqual(parse(s, waiting: true), .deny, s)
            XCTAssertNil(parse(s, waiting: false), s)
        }
    }

    func testCommandsWorkWhileWaitingToo() {
        XCTAssertEqual(parse("发送", waiting: true), .send)
        XCTAssertEqual(parse("取消", waiting: true), .cancel)
    }

    func testWholeUtteranceOnly() {
        for s in ["帮我发送一封邮件", "把这个提交到 git", "取消这个函数的调用", "send the email to bob", "是不是这个问题", ""] {
            XCTAssertNil(parse(s, waiting: true), s)
        }
    }
}

final class ConversationTextTests: XCTestCase {
    func testMeaningful() {
        XCTAssertTrue(ConversationText.isMeaningful("帮我跑一下测试"))
        XCTAssertTrue(ConversationText.isMeaningful("ok"))
        for s in ["", "。", "  ，！ ", "嗯", "嗯嗯。", "啊…", "Um.", "uh", "Hmm"] {
            XCTAssertFalse(ConversationText.isMeaningful(s), s)
        }
    }

    func testInsertionSeparators() {
        XCTAssertEqual(ConversationText.insertion("你好", after: ""), "你好")
        XCTAssertEqual(ConversationText.insertion("再写测试", after: "写一个函数"), "再写测试")
        XCTAssertEqual(ConversationText.insertion("再写测试", after: "写一个函数。"), "再写测试")
        XCTAssertEqual(ConversationText.insertion("and tests", after: "write a function"), " and tests")
        XCTAssertEqual(ConversationText.insertion("加上 tests", after: "write code"), " 加上 tests")
        XCTAssertEqual(ConversationText.insertion("tests", after: "写代码"), " tests")
        XCTAssertEqual(ConversationText.insertion("more", after: "done "), "more")
    }
}

final class WakeWordMatcherTests: XCTestCase {
    let matcher = WakeWordMatcher(wakeWord: "嬴政同学")

    func testExactAndHomophones() {
        for s in ["嬴政同学", "赢政同学", "营政同学", "嬴正同学", "迎政同学", "英政同学。", "Ying Zheng同学", "嬴政同学！"] {
            XCTAssertEqual(matcher.match(s), "", s)
        }
    }

    func testRemainderAfterWakeWord() {
        XCTAssertEqual(matcher.match("嬴政同学，帮我跑一下测试"), "帮我跑一下测试")
        XCTAssertEqual(matcher.match("赢政同学 发送"), "发送")
        XCTAssertEqual(matcher.match("嬴政同学。Run the tests."), "Run the tests.")
    }

    func testLeadingFillers() {
        XCTAssertEqual(matcher.match("嗯，嬴政同学"), "")
        XCTAssertEqual(matcher.match("那个嬴政同学，看一下日志"), "看一下日志")
        XCTAssertEqual(matcher.match("喂 营政同学"), "")
    }

    func testSmallMishearingsWithinEditDistance() {
        XCTAssertEqual(matcher.match("英镇同学"), "")   // yingzhen：差 1
        XCTAssertEqual(matcher.match("嬴政同学们好"), "们好")
    }

    func testNonMatching() {
        for s in ["赢了比赛同学们", "帮我跑一下测试", "同学你好", "应该同学", "发送", "", "嬴政"] {
            XCTAssertNil(matcher.match(s), s)
        }
    }

    func testOtherWakeWord() {
        let m = WakeWordMatcher(wakeWord: "小助手")
        XCTAssertEqual(m.match("小助手，发送"), "发送")
        XCTAssertNil(m.match("嬴政同学"))
    }
}

final class ConversationSessionTests: XCTestCase {
    var session = ConversationSession()

    func testStartsInStandbyAndIgnoresPlainSpeech() {
        XCTAssertEqual(session.state, .standby)
        XCTAssertEqual(session.handle(transcript: "帮我跑一下测试", waiting: false, now: 0), [])
        XCTAssertEqual(session.handle(transcript: "发送", waiting: false, now: 1), [])
        XCTAssertEqual(session.state, .standby)
    }

    func testWakeThenInsertThenSendReturnsToStandby() {
        XCTAssertEqual(session.handle(transcript: "嬴政同学", waiting: false, now: 0), [.wake])
        XCTAssertEqual(session.state, .active)
        XCTAssertEqual(session.handle(transcript: "帮我看看这个函数", waiting: false, now: 2), [.insert("帮我看看这个函数")])
        XCTAssertEqual(session.handle(transcript: "发送", waiting: false, now: 4), [.send, .standby])
        XCTAssertEqual(session.state, .standby)
    }

    func testWakeWithRemainderInSameUtterance() {
        XCTAssertEqual(session.handle(transcript: "嬴政同学，帮我跑一下测试", waiting: false, now: 0),
                       [.wake, .insert("帮我跑一下测试")])
        XCTAssertEqual(session.state, .active)

        var s2 = ConversationSession()
        XCTAssertEqual(s2.handle(transcript: "赢政同学 发送", waiting: false, now: 0), [.wake, .send, .standby])
        XCTAssertEqual(s2.state, .standby)
    }

    func testCancelReturnsToStandbyAndStopEndsMode() {
        _ = session.handle(transcript: "嬴政同学", waiting: false, now: 0)
        XCTAssertEqual(session.handle(transcript: "算了", waiting: false, now: 1), [.cancel, .standby])
        XCTAssertEqual(session.state, .standby)
        XCTAssertEqual(session.handle(transcript: "退出对话模式", waiting: false, now: 2), [],
                       "standby 下没有唤醒词的指令不生效")
        XCTAssertEqual(session.handle(transcript: "嬴政同学，退出对话模式", waiting: false, now: 3), [.wake, .stop])
    }

    func testIdleTimeoutReturnsToStandby() {
        _ = session.handle(transcript: "嬴政同学", waiting: false, now: 0)
        XCTAssertEqual(session.tick(now: 20), [])
        session.noteSpeech(now: 20)
        XCTAssertEqual(session.tick(now: 49), [])
        XCTAssertEqual(session.tick(now: 50.1), [.standby])
        XCTAssertEqual(session.state, .standby)
        XCTAssertEqual(session.tick(now: 100), [])
    }

    func testFillerAndEmptyTranscriptsIgnoredWhenActive() {
        _ = session.handle(transcript: "嬴政同学", waiting: false, now: 0)
        XCTAssertEqual(session.handle(transcript: "嗯。", waiting: false, now: 1), [])
        XCTAssertEqual(session.handle(transcript: "", waiting: false, now: 1), [])
    }

    func testApprovalInStandbyNeedsRecentAnnouncement() {
        XCTAssertEqual(session.handle(transcript: "同意", waiting: true, now: 10), [], "没播报过")
        session.noteWaitingAnnounced(now: 100)
        XCTAssertEqual(session.handle(transcript: "同意", waiting: true, now: 150), [.approve])
        XCTAssertEqual(session.state, .standby)
        session.noteWaitingAnnounced(now: 200)
        XCTAssertEqual(session.handle(transcript: "拒绝", waiting: true, now: 319), [.deny])
        XCTAssertEqual(session.handle(transcript: "拒绝", waiting: true, now: 321), [], "超过 2 分钟")
        session.noteWaitingAnnounced(now: 400)
        XCTAssertEqual(session.handle(transcript: "同意", waiting: false, now: 401), [], "已不在等批准")
    }

    func testApprovalWhileActive() {
        _ = session.handle(transcript: "嬴政同学", waiting: false, now: 0)
        XCTAssertEqual(session.handle(transcript: "好的", waiting: true, now: 1), [.approve])
        XCTAssertEqual(session.state, .active)
        XCTAssertEqual(session.handle(transcript: "好的", waiting: false, now: 2), [.insert("好的")])
    }

    func testWakeWordPlusApproval() {
        XCTAssertEqual(session.handle(transcript: "嬴政同学，同意", waiting: true, now: 0), [.wake, .approve])
    }

    func testSegmentPolicy() {
        XCTAssertEqual(session.transcriptionPolicy(duration: 2), .full)
        XCTAssertEqual(session.transcriptionPolicy(duration: 4), .full)
        XCTAssertEqual(session.transcriptionPolicy(duration: 12), .prefixThenFull(3))
        _ = session.handle(transcript: "嬴政同学", waiting: false, now: 0)
        XCTAssertEqual(session.transcriptionPolicy(duration: 12), .full)
    }

    func testStopLeavesActive() {
        _ = session.handle(transcript: "嬴政同学", waiting: false, now: 0)
        XCTAssertEqual(session.handle(transcript: "stop listening", waiting: false, now: 1), [.stop])
        XCTAssertEqual(session.state, .standby)
    }
}

final class SpokenStatusTests: ZhHansTestCase {
    func testAnnouncements() {
        XCTAssertEqual(SpokenStatus.announcement(previous: .working, current: .waiting("Claude 需要使用 Bash")),
                       "需要批准：Claude 需要使用 Bash")
        XCTAssertEqual(SpokenStatus.announcement(previous: .working, current: .waiting(nil)), "需要批准")
        XCTAssertEqual(SpokenStatus.announcement(previous: .working, current: .idle), "已完成")
        XCTAssertNil(SpokenStatus.announcement(previous: nil, current: .idle))
        XCTAssertNil(SpokenStatus.announcement(previous: .waiting(nil), current: .waiting("x")))
        XCTAssertNil(SpokenStatus.announcement(previous: .idle, current: .working))
        XCTAssertNil(SpokenStatus.announcement(previous: .idle, current: .idle))
    }

    func testReasonIsShortened() {
        let long = String(repeating: "很长的原因", count: 20) + "\n第二行"
        let text = SpokenStatus.announcement(previous: .working, current: .waiting(long)) ?? ""
        XCTAssertLessThanOrEqual(text.count, 50)
        XCTAssertFalse(text.contains("第二行"))
    }

    func testEnglish() {
        Localization.languageOverride = "en"
        XCTAssertEqual(SpokenStatus.announcement(previous: .working, current: .waiting("Bash")), "Needs approval: Bash")
        XCTAssertEqual(SpokenStatus.announcement(previous: .working, current: .idle), "Done")
    }
}
