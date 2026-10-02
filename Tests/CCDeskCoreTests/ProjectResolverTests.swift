import XCTest
@testable import CCDeskCore

final class ProjectResolverTests: XCTestCase {
    func testNonGitDirectoryIsItsOwnRoot() {
        let r = ProjectResolver { _, _ in nil }
        XCTAssertEqual(r.resolve("/tmp/a"), ProjectRef(root: "/tmp/a", branch: nil))
    }

    func testMainCheckoutUsesParentOfGitDir() {
        let r = ProjectResolver { cwd, args in
            switch args.last {
            case "--git-common-dir": return "/repo/.git\n"
            case "--show-toplevel": return "/repo\n"
            default: return nil
            }
        }
        XCTAssertEqual(r.resolve("/repo/src"), ProjectRef(root: "/repo", branch: nil))
    }

    func testWorktreeGroupsUnderMainRepoWithBranch() {
        let r = ProjectResolver { cwd, args in
            switch args.last {
            case "--git-common-dir": return "/repo/.git\n"
            case "--show-toplevel": return "/wt/feature\n"
            case "HEAD": return "issue/42-fix\n"
            default: return nil
            }
        }
        XCTAssertEqual(r.resolve("/wt/feature"), ProjectRef(root: "/repo", branch: "issue/42-fix"))
    }

    func testResultsAreCached() {
        var calls = 0
        let r = ProjectResolver { _, _ in calls += 1; return nil }
        _ = r.resolve("/a")
        _ = r.resolve("/a")
        XCTAssertEqual(calls, 1)
    }
}
