import XCTest
@testable import CCDeskCore

final class RegistryReaderTests: XCTestCase {
    private func entry(_ json: String) -> RegistryEntry? {
        RegistryReader.parse(Data(json.utf8))
    }

    func testParsesBusySession() throws {
        let e = try XCTUnwrap(entry("""
        {"pid":12667,"sessionId":"b4ef","cwd":"/Users/x/poems","kind":"interactive","entrypoint":"cli",
         "name":"poems-06","nameSource":"derived","status":"busy","statusUpdatedAt":1790906699870}
        """))
        XCTAssertEqual(e.pid, 12667)
        XCTAssertEqual(e.sessionID, "b4ef")
        XCTAssertEqual(e.cwd, "/Users/x/poems")
        XCTAssertEqual(e.name, "poems-06")
        XCTAssertTrue(e.nameIsDerived)
        XCTAssertEqual(e.status, .working)
        XCTAssertEqual(e.entrypoint, "cli")
        XCTAssertEqual(e.statusUpdatedAt.timeIntervalSince1970, 1790906699.870, accuracy: 0.001)
    }

    func testParsesWaitingWithReason() throws {
        let e = try XCTUnwrap(entry("""
        {"pid":1,"sessionId":"s","cwd":"/a","status":"waiting","waitingFor":"input needed","statusUpdatedAt":1}
        """))
        XCTAssertEqual(e.status, .waiting("input needed"))
    }

    func testIdleAndUnknownStatus() throws {
        XCTAssertEqual(try XCTUnwrap(entry(#"{"pid":1,"sessionId":"s","cwd":"/a","status":"idle"}"#)).status, .idle)
        XCTAssertEqual(try XCTUnwrap(entry(#"{"pid":1,"sessionId":"s","cwd":"/a","status":"weird"}"#)).status, .unknown)
        XCTAssertEqual(try XCTUnwrap(entry(#"{"pid":1,"sessionId":"s","cwd":"/a"}"#)).status, .unknown)
    }

    func testAutoNameIsNotDerived() throws {
        let e = try XCTUnwrap(entry(#"{"pid":1,"sessionId":"s","cwd":"/a","name":"refactor","nameSource":"auto"}"#))
        XCTAssertFalse(e.nameIsDerived)
    }

    func testFallsBackToUpdatedAtThenStartedAt() throws {
        let a = try XCTUnwrap(entry(#"{"pid":1,"sessionId":"s","cwd":"/a","updatedAt":2000}"#))
        XCTAssertEqual(a.statusUpdatedAt.timeIntervalSince1970, 2, accuracy: 0.001)
        let b = try XCTUnwrap(entry(#"{"pid":1,"sessionId":"s","cwd":"/a","startedAt":3000}"#))
        XCTAssertEqual(b.statusUpdatedAt.timeIntervalSince1970, 3, accuracy: 0.001)
    }

    func testRejectsNonInteractiveSpareAndBroken() {
        XCTAssertNil(entry(#"{"pid":1,"sessionId":"s","cwd":"/a","kind":"background"}"#))
        XCTAssertNil(entry(#"{"pid":1,"sessionId":"s","cwd":"/a","spare":true}"#))
        XCTAssertNil(entry(#"{"pid":1,"cwd":"/a"}"#))
        XCTAssertNil(entry(#"{"pid":1,"sessionId":"","cwd":"/a"}"#))
        XCTAssertNil(entry("not json"))
    }

    func testReadAllSkipsNonJSONAndBrokenFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"pid":5,"sessionId":"ok","cwd":"/a"}"#.utf8).write(to: dir.appendingPathComponent("5.json"))
        try Data("{broken".utf8).write(to: dir.appendingPathComponent("6.json"))
        try Data("secret".utf8).write(to: dir.appendingPathComponent("5.abc.key"))
        let all = RegistryReader.readAll(directory: dir)
        XCTAssertEqual(all.map(\.sessionID), ["ok"])
    }

    func testReadAllMissingDirectoryIsEmpty() {
        XCTAssertEqual(RegistryReader.readAll(directory: URL(fileURLWithPath: "/nonexistent/\(UUID())")), [])
    }
}
