import XCTest
@testable import CCDeskCore

final class NaturalVoiceProtocolTests: XCTestCase {
    typealias P = NaturalVoiceProtocol

    private func floatBytes(_ values: [Float]) -> Data {
        var data = Data()
        for v in values {
            var bits = v.bitPattern.littleEndian
            data.append(Data(bytes: &bits, count: 4))
        }
        return data
    }

    func testFrameLayoutMatchesServer() {
        // 与 tts_server.py 的 write_frame 一致：>I 长度 | kind | id 长度 | id | payload。
        let frame = P.Frame(kind: .end, id: "u1.0", payload: Data("{}".utf8))
        XCTAssertEqual([UInt8](frame.encoded()), [0, 0, 0, 8, 2, 4] + Array("u1.0".utf8) + Array("{}".utf8))
    }

    func testDecoderHandlesArbitraryChunking() throws {
        let audio = P.Frame(kind: .audio, id: "u2.1", payload: floatBytes([0, 0.5, -1, 0.25]))
        let end = P.Frame(kind: .end, id: "u2.1", payload: Data(#"{"cancelled": true}"#.utf8))
        let ready = P.Frame(kind: .ready, id: "", payload: Data(#"{"ready_s": 2.0}"#.utf8))
        let stream = ready.encoded() + audio.encoded() + end.encoded()
        var decoder = P.Decoder()
        var frames: [P.Frame] = []
        // 一次喂 3 个字节，模拟管道任意切分。
        var i = stream.startIndex
        while i < stream.endIndex {
            let j = min(i + 3, stream.endIndex)
            frames += try decoder.append(stream.subdata(in: i..<j))
            i = j
        }
        XCTAssertEqual(frames, [ready, audio, end])
        XCTAssertEqual(frames[1].samples, [0, 0.5, -1, 0.25])
        XCTAssertTrue(frames[2].cancelled)
        XCTAssertFalse(frames[0].cancelled)
    }

    func testDecoderSkipsUnknownKindAndRejectsOversizedFrames() throws {
        var decoder = P.Decoder()
        var unknown = Data([0, 0, 0, 3, 9, 1]) + Data("x".utf8)
        unknown += P.Frame(kind: .error, id: "", payload: Data("boom".utf8)).encoded()
        let frames = try decoder.append(unknown)
        XCTAssertEqual(frames.map(\.kind), [.error])
        XCTAssertEqual(frames.first?.text, "boom")

        var bad = P.Decoder()
        XCTAssertThrowsError(try bad.append(Data([0x7f, 0xff, 0xff, 0xff, 0, 0])))
        // 出错后缓冲被清空，可以继续解码新帧。
        XCTAssertEqual(try bad.append(P.Frame(kind: .ready, id: "").encoded()).count, 1)
    }

    func testRequestsAreSingleJSONLines() throws {
        let speak = P.speakRequest(id: "u3.0", text: "你好\n世界", lang: "chinese")
        XCTAssertEqual(speak.last, 0x0A)
        XCTAssertEqual(speak.filter { $0 == 0x0A }.count, 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: speak) as? [String: String])
        XCTAssertEqual(json, ["id": "u3.0", "text": "你好\n世界", "voice": "serena", "lang": "chinese"])
        let cancel = try XCTUnwrap(JSONSerialization.jsonObject(with: P.cancelRequest("*")) as? [String: String])
        XCTAssertEqual(cancel, ["cancel": "*"])
        XCTAssertEqual(P.langCode(forUILanguage: "zh-Hans"), "chinese")
        XCTAssertEqual(P.langCode(forUILanguage: "en"), "english")
    }
}
