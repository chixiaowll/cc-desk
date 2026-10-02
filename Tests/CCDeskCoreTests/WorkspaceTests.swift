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
}
