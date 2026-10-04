import XCTest
@testable import CCDeskCore

final class JSONValueTests: XCTestCase {
    func testRoundTripAndAccessors() throws {
        let value = try XCTUnwrap(JSONValue.parse(#"{"a":1,"b":true,"c":"x","d":[null,2.5],"e":{"f":"g"}}"#))
        XCTAssertEqual(value["a"]?.intValue, 1)
        XCTAssertEqual(value["b"]?.boolValue, true)
        XCTAssertEqual(value["c"]?.stringValue, "x")
        XCTAssertEqual(value["d"]?.arrayValue, [.null, .number(2.5)])
        XCTAssertEqual(value["e"]?["f"], "g")
        XCTAssertEqual(value.compact, #"{"a":1,"b":true,"c":"x","d":[null,2.5],"e":{"f":"g"}}"#)
        XCTAssertEqual(JSONValue.parse(value.compact), value)
    }

    func testLenientScalars() {
        XCTAssertEqual(JSONValue.string("12").intValue, 12)
        XCTAssertEqual(JSONValue.string("true").boolValue, true)
        XCTAssertEqual(JSONValue.string("no").boolValue, false)
        XCTAssertNil(JSONValue.string("maybe").boolValue)
        XCTAssertNil(JSONValue.bool(true).intValue)
        XCTAssertNil(JSONValue.parse("{broken"))
    }

    /// 模型 / 服务端给的数字不可信：超大、负的超大、小数、写成字符串的科学计数法都不能让 Int 转换崩溃。
    func testIntValueRejectsUnrepresentableNumbers() throws {
        XCTAssertNil(JSONValue.number(1e30).intValue)
        XCTAssertNil(JSONValue.number(-1e30).intValue)
        XCTAssertNil(JSONValue.number(.nan).intValue)
        XCTAssertNil(JSONValue.number(.infinity).intValue)
        XCTAssertNil(JSONValue.number(9.2e18).intValue)
        XCTAssertEqual(JSONValue.number(1.5).intValue, 1)
        XCTAssertEqual(JSONValue.number(-1.5).intValue, -1)
        XCTAssertEqual(JSONValue.number(8.9e15).intValue, 8_900_000_000_000_000)
        XCTAssertNil(JSONValue.string("1e30").intValue)
        XCTAssertNil(JSONValue.string("1.5").intValue)
        XCTAssertNil(JSONValue.string("9223372036854775807").intValue)
        XCTAssertEqual(JSONValue.string(" 42 ").intValue, 42)
        // 经 JSON 解析来的同样安全。
        let parsed = try XCTUnwrap(JSONValue.parse(#"{"count":1e30,"neg":-1e30,"big":"1e30"}"#))
        XCTAssertNil(parsed["count"]?.intValue)
        XCTAssertNil(parsed["neg"]?.intValue)
        XCTAssertNil(parsed["big"]?.intValue)
    }

    func testSlashesAndUnicodeAreNotEscaped() {
        XCTAssertEqual(JSONValue.object(["p": "/Users/u/诗"]).compact, #"{"p":"/Users/u/诗"}"#)
    }
}

final class ControlProtocolTests: XCTestCase {
    func testParsesRequest() throws {
        let request = try ControlRequest.parse(#"{"id":7,"method":"type_text","params":{"session":"s2","text":"跑测试"}}"#).get()
        XCTAssertEqual(request.id, 7)
        XCTAssertEqual(request.method, "type_text")
        XCTAssertEqual(request.params["text"], "跑测试")
        XCTAssertEqual(try ControlRequest.parse(request.line).get(), request)
        XCTAssertEqual(try ControlRequest.parse(#"{"id":"a","method":"list_sessions"}"#).get().params, [:])
    }

    func testInvalidRequestsBecomeErrorResponses() {
        guard case .failure(let bad) = ControlRequest.parse("not json") else { return XCTFail() }
        XCTAssertEqual(bad.line, #"{"error":{"code":-32600,"message":"invalid JSON"},"id":null}"#)
        guard case .failure(let noMethod) = ControlRequest.parse(#"{"id":3}"#) else { return XCTFail() }
        XCTAssertEqual(noMethod.id, 3)
        guard case .failure(let badParams) = ControlRequest.parse(#"{"id":4,"method":"x","params":[1]}"#) else { return XCTFail() }
        XCTAssertEqual(badParams.outcome, .failure(ControlError(.invalidParams, "params must be an object")))
    }

    func testResponseEncodingRoundTrips() {
        let ok = ControlResponse(id: 1, result: ["text": "done"])
        XCTAssertEqual(ok.line, #"{"id":1,"result":{"text":"done"}}"#)
        XCTAssertEqual(ControlResponse.parse(ok.line), ok)
        let err = ControlResponse(id: "x", error: ControlError(.timeout, "slow"))
        XCTAssertEqual(err.line, #"{"error":{"code":-32001,"message":"slow"},"id":"x"}"#)
        XCTAssertEqual(ControlResponse.parse(err.line), err)
        XCTAssertNil(ControlResponse.parse(#"{"id":1}"#))
    }

    func testSocketPathHonoursEnvironment() {
        XCTAssertEqual(ControlProtocol.socketPath(environment: [:], home: "/Users/u"), "/Users/u/.cc-desk/control.sock")
        XCTAssertEqual(ControlProtocol.socketPath(environment: ["CCDESK_CONTROL_SOCKET": "/tmp/x.sock"], home: "/Users/u"),
                       "/tmp/x.sock")
    }

    func testLineBufferSplitsAcrossChunks() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("{\"a\":".utf8)).lines, [])
        XCTAssertEqual(buffer.append(Data("1}\r\n\n{\"b\":2}\n{\"c\"".utf8)).lines, [#"{"a":1}"#, #"{"b":2}"#])
        XCTAssertEqual(buffer.append(Data(":3}\n".utf8)).lines, [#"{"c":3}"#])
        let huge = buffer.append(Data(repeating: 0x61, count: ControlProtocol.maxLineBytes + 1))
        XCTAssertTrue(huge.overflow)
        XCTAssertEqual(buffer.append(Data("ok\n".utf8)).lines, ["ok"])
    }
}
