import Foundation

public struct ProjectRef: Equatable, Hashable, Sendable {
    /// 分组键：git 仓库主目录（worktree 归入主仓库），非 git 目录为 cwd 本身。
    public let root: String
    /// cwd 位于 worktree 时的分支名。
    public let branch: String?

    public init(root: String, branch: String?) {
        self.root = root
        self.branch = branch
    }
}

/// 非线程安全；只在单个串行队列上使用。
public final class ProjectResolver {
    /// 在 cwd 下执行 `git <args>`，成功返回 stdout，失败返回 nil。
    public typealias Git = (_ cwd: String, _ args: [String]) -> String?

    private let git: Git
    private var cache: [String: ProjectRef] = [:]

    public init(git: @escaping Git) {
        self.git = git
    }

    public func resolve(_ cwd: String) -> ProjectRef {
        if let cached = cache[cwd] { return cached }
        let ref = compute(cwd)
        cache[cwd] = ref
        return ref
    }

    private func run(_ cwd: String, _ args: [String]) -> String? {
        guard let out = git(cwd, args)?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else { return nil }
        return out
    }

    private func compute(_ cwd: String) -> ProjectRef {
        guard let common = run(cwd, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) else {
            return ProjectRef(root: cwd, branch: nil)
        }
        let commonURL = URL(fileURLWithPath: common)
        let root = commonURL.lastPathComponent == ".git" ? commonURL.deletingLastPathComponent().path : commonURL.path
        var branch: String?
        if let top = run(cwd, ["rev-parse", "--show-toplevel"]), top != root {
            branch = run(cwd, ["rev-parse", "--abbrev-ref", "HEAD"])
        }
        return ProjectRef(root: root, branch: branch)
    }
}
