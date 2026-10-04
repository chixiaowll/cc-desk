import XCTest
@testable import CCDeskCore

/// 顾问 / git_status 的 git 安全环境。
final class GitSafetyTests: XCTestCase {
    func testEnvironmentOverridesRepositoryConfig() {
        let env = GitSafety.environment(["PATH": "/bin", "GIT_CONFIG_KEY_7": "core.fsmonitor", "GIT_CONFIG_VALUE_7": "x",
                                         "GIT_CONFIG_PARAMETERS": "'core.fsmonitor'='evil'", "GIT_EXTERNAL_DIFF": "evil"])
        XCTAssertEqual(env["PATH"], "/bin")
        XCTAssertNil(env["GIT_CONFIG_KEY_7"])
        XCTAssertNil(env["GIT_CONFIG_PARAMETERS"])
        XCTAssertNil(env["GIT_EXTERNAL_DIFF"])
        let count = Int(env["GIT_CONFIG_COUNT"] ?? "") ?? 0
        var config: [String: String] = [:]
        for i in 0..<count { config[env["GIT_CONFIG_KEY_\(i)"] ?? ""] = env["GIT_CONFIG_VALUE_\(i)"] }
        XCTAssertEqual(config["core.fsmonitor"], "false")
        XCTAssertEqual(config["core.pager"], "cat")
        XCTAssertTrue(config["diff.external"]?.contains("/usr/bin/diff") == true)
        XCTAssertEqual(env["GIT_NO_REPLACE_OBJECTS"], "1")
        XCTAssertEqual(env["GIT_TERMINAL_PROMPT"], "0")
    }
}
