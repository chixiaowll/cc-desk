import XCTest
@testable import CCDeskCore

final class JumpScriptTests: XCTestCase {
    func testBuildsScriptForValidTTY() throws {
        let script = try XCTUnwrap(JumpScript.terminalApp(tty: "ttys007"))
        XCTAssertTrue(script.contains("tell application \"Terminal\""))
        XCTAssertTrue(script.contains("\"/dev/ttys007\""))
    }

    func testRejectsUnexpectedTTY() {
        XCTAssertNil(JumpScript.terminalApp(tty: "ttys007\" & do shell script \"x"))
        XCTAssertNil(JumpScript.terminalApp(tty: ""))
        XCTAssertNil(JumpScript.terminalApp(tty: "pts/1"))
    }
}
