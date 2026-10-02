import XCTest
@testable import CCDeskCore

final class WorkspaceTests: XCTestCase {
    func testRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID())/workspace.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = WorkspaceFile(entries: [
            WorkspaceEntry(terminalID: UUID(), cwd: "/a", sessionID: "s1", name: "a"),
            WorkspaceEntry(terminalID: UUID(), cwd: "/b", sessionID: nil, name: "b"),
        ])
        try WorkspaceStore.save(file, to: url)
        XCTAssertEqual(WorkspaceStore.load(from: url), file)
    }

    func testLoadMissingOrBrokenReturnsNil() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(WorkspaceStore.load(from: dir.appendingPathComponent("none.json")))
        let broken = dir.appendingPathComponent("broken.json")
        try Data("{".utf8).write(to: broken)
        XCTAssertNil(WorkspaceStore.load(from: broken))
    }

    func testLoadMovesBrokenFileAsideInsteadOfLosingIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspace.json")
        try Data("not json at all".utf8).write(to: url)

        XCTAssertNil(WorkspaceStore.load(from: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "broken file should have been moved aside")

        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let movedName = try XCTUnwrap(siblings.first { $0.hasPrefix("workspace.broken-") && $0.hasSuffix(".json") })
        let movedContents = try String(contentsOf: dir.appendingPathComponent(movedName), encoding: .utf8)
        XCTAssertEqual(movedContents, "not json at all")
    }

    func testUnknownKindValueDecodesLenientlyToNil() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspace.json")
        let tid = UUID()
        let futureJSON = """
        {"version":1,"entries":[{"terminalID":"\(tid.uuidString)","cwd":"/a","name":"a","kind":"aider"}]}
        """
        try Data(futureJSON.utf8).write(to: url)

        let loaded = try XCTUnwrap(WorkspaceStore.load(from: url))
        XCTAssertEqual(loaded.entries.count, 1)
        XCTAssertNil(loaded.entries[0].kind)
        XCTAssertEqual(loaded.entries[0].cwd, "/a")
        XCTAssertEqual(loaded.entries[0].name, "a")
    }

    func testOldJSONWithoutKindFieldStillDecodes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspace.json")
        let tid = UUID()
        let legacyJSON = """
        {"version":1,"entries":[{"terminalID":"\(tid.uuidString)","cwd":"/a","name":"a"}]}
        """
        try Data(legacyJSON.utf8).write(to: url)

        let loaded = try XCTUnwrap(WorkspaceStore.load(from: url))
        XCTAssertEqual(loaded.entries.count, 1)
        XCTAssertNil(loaded.entries[0].kind)
        XCTAssertEqual(loaded.entries[0].cwd, "/a")
    }

    func testKnownAgentKindsDecode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspace.json")
        let json = """
        {"version":1,"entries":[{"terminalID":"\(UUID().uuidString)","cwd":"/a","name":"a","kind":"codex"},\
        {"terminalID":"\(UUID().uuidString)","cwd":"/b","name":"b","kind":"pi"}]}
        """
        try Data(json.utf8).write(to: url)
        let loaded = try XCTUnwrap(WorkspaceStore.load(from: url))
        XCTAssertEqual(loaded.entries.map(\.kind), [.codex, .pi])
    }
}
