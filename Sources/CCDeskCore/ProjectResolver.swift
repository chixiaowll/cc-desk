import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ProjectRef: Equatable, Hashable, Sendable {
    /// 分组键：git 仓库主目录（worktree 归入主仓库），非 git 目录为 cwd 本身。
    public let root: String
    /// cwd 位于 worktree 时的分支名。
    public let branch: String?
    /// 已 canonicalize（realpath）的 cwd；由 ProjectResolver.compute 填充并按 cwd 缓存，
    /// 供调用方（如 SidebarBuilder）比较路径前缀而无需再次触碰文件系统。
    public let cwd: String

    public init(root: String, branch: String?, cwd: String) {
        self.root = root
        self.branch = branch
        self.cwd = cwd
    }
}

/// 非线程安全；只在单个串行队列上使用。
public final class ProjectResolver {
    /// 在 cwd 下执行 `git <args>`，成功返回 stdout，失败返回 nil。
    public typealias Git = (_ cwd: String, _ args: [String]) -> String?

    private struct CacheEntry {
        let ref: ProjectRef
        /// 非 git 结果需要在一段时间后重新探测（例如之后执行了 `git init`，或探测只是暂时失败）。
        let isGit: Bool
        let computedAt: Date
    }

    private static let nonGitRecheckInterval: TimeInterval = 30

    private let git: Git
    private let now: () -> Date
    private var cache: [String: CacheEntry] = [:]

    public init(git: @escaping Git, now: @escaping () -> Date = Date.init) {
        self.git = git
        self.now = now
    }

    /// 用 realpath(3) 解析符号链接和中间目录；失败时原样返回。
    /// 刻意不用 URL.resolvingSymlinksInPath：它会把 /tmp 映射成 /private/tmp 之外的反向结果
    /// （在 macOS 上会把 /private/tmp 映射回 /tmp），与 git/Claude 实际汇报的路径方向相反。
    public static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public func resolve(_ cwd: String) -> ProjectRef {
        let nowDate = now()
        if let cached = cache[cwd],
           cached.isGit || nowDate.timeIntervalSince(cached.computedAt) < Self.nonGitRecheckInterval {
            return cached.ref
        }
        let (ref, isGit) = compute(cwd)
        cache[cwd] = CacheEntry(ref: ref, isGit: isGit, computedAt: nowDate)
        return ref
    }

    private func run(_ cwd: String, _ args: [String]) -> String? {
        guard let out = git(cwd, args)?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else { return nil }
        return out
    }

    private func compute(_ cwd: String) -> (ProjectRef, Bool) {
        let canonicalCwd = Self.canonical(cwd)
        let nonGit = (ProjectRef(root: canonicalCwd, branch: nil, cwd: canonicalCwd), false)

        guard let raw = git(cwd, ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir", "--show-toplevel"]) else {
            return nonGit
        }
        let lines = raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 3, !lines[0].isEmpty, !lines[1].isEmpty, !lines[2].isEmpty else {
            return nonGit
        }
        let gitDir = lines[0]
        let commonDir = lines[1]
        let toplevel = lines[2]

        if gitDir == commonDir {
            // 主仓库检出，或子模块（子模块的 toplevel 是子模块自身目录）。
            return (ProjectRef(root: toplevel, branch: nil, cwd: canonicalCwd), true)
        }

        // 关联 worktree：按主仓库（commonDir 的父目录，若其末段是 ".git"；否则 commonDir 本身即裸仓库）分组。
        let commonURL = URL(fileURLWithPath: commonDir)
        let root = commonURL.lastPathComponent == ".git" ? commonURL.deletingLastPathComponent().path : commonDir
        var branch = run(cwd, ["rev-parse", "--abbrev-ref", "HEAD"])
        if branch == nil || branch == "HEAD" {
            branch = run(cwd, ["rev-parse", "--short", "HEAD"])
        }
        return (ProjectRef(root: root, branch: branch, cwd: canonicalCwd), true)
    }
}
