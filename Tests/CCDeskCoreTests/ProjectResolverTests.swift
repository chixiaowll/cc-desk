import XCTest
@testable import CCDeskCore

final class ProjectResolverTests: XCTestCase {
    func testNonGitDirectoryIsItsOwnCanonicalRoot() {
        let r = ProjectResolver { _, _ in nil }
        XCTAssertEqual(r.resolve("/tmp/a"), ProjectRef(root: ProjectResolver.canonical("/tmp/a"), branch: nil, cwd: ProjectResolver.canonical("/tmp/a")))
    }

    func testMainCheckoutUsesToplevel() {
        let r = ProjectResolver { cwd, args in
            XCTAssertTrue(args.contains("--path-format=absolute"))
            switch args.last {
            case "--show-toplevel": return "/repo/.git\n/repo/.git\n/repo\n"
            default: return nil
            }
        }
        XCTAssertEqual(r.resolve("/repo/src"), ProjectRef(root: "/repo", branch: nil, cwd: "/repo/src"))
    }

    func testSubmoduleGitDirEqualsCommonDirUsesToplevel() {
        // Submodule: gitDir == commonDir (both point at the modules/ directory inside the superproject),
        // but show-toplevel correctly reports the submodule's own working directory.
        let r = ProjectResolver { cwd, args in
            switch args.last {
            case "--show-toplevel": return "/super/.git/modules/sub\n/super/.git/modules/sub\n/super/sub\n"
            default: return nil
            }
        }
        XCTAssertEqual(r.resolve("/super/sub"), ProjectRef(root: "/super/sub", branch: nil, cwd: "/super/sub"))
    }

    func testLinkedWorktreeIsItsOwnGroupWithBranch() {
        let r = ProjectResolver { cwd, args in
            switch args.last {
            case "--show-toplevel": return "/repo/.git/worktrees/fix\n/repo/.git\n/wt/fix\n"
            case "HEAD" where args.contains("--abbrev-ref"): return "issue/42-fix\n"
            default: return nil
            }
        }
        XCTAssertEqual(r.resolve("/wt/fix"), ProjectRef(root: "/wt/fix", branch: "issue/42-fix", cwd: "/wt/fix"))
    }

    func testLinkedWorktreeWithDetachedHeadFallsBackToShortSHA() {
        let r = ProjectResolver { cwd, args in
            switch args.last {
            case "--show-toplevel": return "/repo/.git/worktrees/fix\n/repo/.git\n/wt/fix\n"
            case "HEAD" where args.contains("--abbrev-ref"): return "HEAD\n"
            case "HEAD" where args.contains("--short"): return "a1b2c3d\n"
            default: return nil
            }
        }
        XCTAssertEqual(r.resolve("/wt/fix"), ProjectRef(root: "/wt/fix", branch: "a1b2c3d", cwd: "/wt/fix"))
    }

    func testLinkedWorktreeOfBareRepoIsItsOwnGroup() {
        let r = ProjectResolver { cwd, args in
            switch args.last {
            case "--show-toplevel": return "/bare/worktrees/fix\n/bare\n/wt/fix\n"
            case "HEAD" where args.contains("--abbrev-ref"): return "main\n"
            default: return nil
            }
        }
        XCTAssertEqual(r.resolve("/wt/fix"), ProjectRef(root: "/wt/fix", branch: "main", cwd: "/wt/fix"))
    }

    func testResultsAreCached() {
        var calls = 0
        let r = ProjectResolver(git: { _, _ in calls += 1; return nil }, now: { Date(timeIntervalSince1970: 0) })
        _ = r.resolve("/a")
        _ = r.resolve("/a")
        XCTAssertEqual(calls, 1)
    }

    func testNonGitResultIsRecheckedAfter30Seconds() {
        var calls = 0
        var t: TimeInterval = 0
        let r = ProjectResolver(git: { _, _ in calls += 1; return nil }, now: { Date(timeIntervalSince1970: t) })
        _ = r.resolve("/a")
        t = 10
        _ = r.resolve("/a")
        XCTAssertEqual(calls, 1, "within 30s should reuse cached non-git result")
        t = 31
        _ = r.resolve("/a")
        XCTAssertEqual(calls, 2, "after 30s should re-check")
    }

    func testGitResultIsNotRecheckedAfter30Seconds() {
        var calls = 0
        var t: TimeInterval = 0
        let r = ProjectResolver(git: { cwd, args in
            calls += 1
            guard args.last == "--show-toplevel" else { return nil }
            return "/repo/.git\n/repo/.git\n/repo\n"
        }, now: { Date(timeIntervalSince1970: t) })
        _ = r.resolve("/repo")
        t = 1000
        _ = r.resolve("/repo")
        XCTAssertEqual(calls, 1)
    }

    func testMainRevParseCallUsesPinnedArgumentOrder() {
        // Output lines are positional (git-dir, then git-common-dir, then show-toplevel);
        // reordering the args without updating the line parsing below would silently
        // misattribute paths, so the exact order is pinned here.
        var capturedArgs: [String]?
        let r = ProjectResolver { cwd, args in
            if args.last == "--show-toplevel" { capturedArgs = args }
            return nil
        }
        _ = r.resolve("/repo")
        XCTAssertEqual(capturedArgs, [
            "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir", "--show-toplevel",
        ])
    }

    func testCanonicalResolvesRealSymlinkedTmpOnMacOS() {
        XCTAssertEqual(ProjectResolver.canonical("/tmp"), "/private/tmp")
    }

    func testCanonicalReturnsInputUnchangedForNonexistentPath() {
        let p = "/nonexistent/\(UUID())"
        XCTAssertEqual(ProjectResolver.canonical(p), p)
    }
}
