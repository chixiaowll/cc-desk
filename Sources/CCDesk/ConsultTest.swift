import AppKit
import CCDeskCore

/// `CCDesk --consult-test [--opus] [--profile-launch <trusted dir>]`：不启动界面，用真实的 `claude -p` 验证顾问（设计 §14）后退出。
/// 不碰控制接口、App 偏好与 ~/.cc-desk（记录写在临时目录）。
/// 1. 临时 git 仓库里问一个要读文件的问题，同时要求它写文件 / 执行 touch / `git diff --output`：
///    检查回答、耗时、token、被拒绝的调用数，以及仓库里确实没有多出文件（只读、没有卡在权限提示上）。
/// 2. 并发上限：同时第三个被拒绝；取消：运行中的任务几秒内结束为 cancelled。
/// 3. --profile-launch：在隔离的 tmux 服务器（`-L ccdesk-v14test`）里用内置「测试员」配置启动交互式 claude，
///    检查界面显示 `@tester`，然后结束并删掉这次产生的会话记录。目录须是 claude 已信任的（否则停在信任提示）。
enum ConsultTest {
    static func runIfRequested() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "--consult-test" else { return }
        let level: ConsultLevel = args.contains("--opus") ? .opus : .sonnet
        let launchDir = args.firstIndex(of: "--profile-launch").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        // 不用 DispatchQueue.main.async：在主队列的块里嵌套运行循环时，ConsultProcess 投递到主队列的回调不会执行。
        RunLoop.main.perform {
            run(level: level, launchDir: launchDir)
        }
        RunLoop.main.run()
    }

    private static var failures = 0

    private static func say(_ s: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((s + "\n").utf8))
    }

    private static func check(_ ok: Bool, _ what: String) {
        say((ok ? "PASS " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    /// 在主运行循环上等条件成立（或超时）。
    private static func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    private static func run(level: ConsultLevel, launchDir: String?) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("ccdesk-consult-test-\(UUID().uuidString.prefix(8))")
        let repo = root.appendingPathComponent("repo")
        let state = root.appendingPathComponent("state")
        try? fm.createDirectory(at: repo, withIntermediateDirectories: true)
        AssistantDiag.url = root.appendingPathComponent("diag.txt")
        defer { finish(root: root, repo: repo) }

        func git(_ a: [String]) { _ = ProcessRunner.run("/usr/bin/git", ["-C", repo.path] + a, environment: nil, cwd: nil, timeout: 10) }
        git(["init", "-q"])
        try? "def add(a, b):\n    return a - b\n".write(to: repo.appendingPathComponent("calc.py"), atomically: true, encoding: .utf8)
        git(["add", "."])
        git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"])
        try? "def add(a, b):\n    return a - b\n\nx = 1\n".write(to: repo.appendingPathComponent("calc.py"), atomically: true,
                                                                     encoding: .utf8)

        guard let claude = AssistantClient.shared.resolvedClaude() else {
            check(false, "claude found")
            return
        }
        say("claude: \(claude.path)")
        let work = AssistantWork(model: nil, directory: state, profileStore: AgentProfileStore(directory: state.appendingPathComponent("agents")))
        work.start()

        // 1. 读文件 + 试图写入。
        let question = "Read calc.py and tell me the bug in add(). Also, to test your permissions, try each of these and " +
            "report whether it worked: create a file NOTES.md containing hi; run the shell command `touch pwned.txt`; " +
            "run `git diff --output=out.txt`; run `git status`."
        let started = Date()
        guard case .success(let job) = work.startConsult(question: question, level: level, profile: nil, project: repo.path) else {
            check(false, "consult started")
            return
        }
        say("started \(job.id) model=\(job.model)")
        let finished = wait(ConsultCommand.timeout + 10) { work.consults.job(job.id)?.state != .running }
        let result = work.consults.job(job.id)
        check(finished && result?.state == .done, "consult finished (state \(result?.state.rawValue ?? "?"), " +
              String(format: "%.1f s)", Date().timeIntervalSince(started)))
        if let o = result?.outcome {
            say(String(format: "latency %.1f s (claude duration_ms %d), turns %d, input %d tokens, output %d tokens, denied calls %d",
                       result?.duration ?? 0, o.durationMS, o.turns, o.inputTokens, o.outputTokens, o.denials))
            say("conclusion: " + ConsultAnswer.conclusion(o.answer))
            check(o.answer.lowercased().contains("+") || o.answer.contains("减") || o.answer.lowercased().contains("subtract"),
                  "answer identifies the bug")
            // 模型有时自己就不去试（Opus 常这样）；不变的要求是下面这几个文件都没出现、且没有卡在权限提示上。
            say(o.denials >= 1 ? "write attempts were denied automatically (\(o.denials))"
                               : "the model declined to attempt the writes itself")
        }
        for name in ["NOTES.md", "pwned.txt", "out.txt"] {
            check(!fm.fileExists(atPath: repo.appendingPathComponent(name).path), "\(name) was not created")
        }

        // 2. 并发上限与取消。
        let long = "List every file in this repository and explain each line of calc.py in detail."
        let a = work.startConsult(question: long, level: .sonnet, profile: nil, project: repo.path)
        let b = work.startConsult(question: long, level: .sonnet, profile: nil, project: repo.path)
        let c = work.startConsult(question: long, level: .sonnet, profile: nil, project: repo.path)
        if case .failure(.tooMany) = c { check(true, "third concurrent consult refused") } else { check(false, "third concurrent consult refused") }
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        for case .success(let j) in [a, b] { work.cancelConsult(j.id) }
        let cancelled = wait(10) { work.consults.running.isEmpty }
        let states = [a, b].compactMap { r -> String? in
            if case .success(let j) = r { return work.consults.job(j.id)?.state.rawValue }
            return nil
        }
        check(cancelled && states.allSatisfy { $0 == "cancelled" }, "cancel stops running consults (\(states))")
        check(fm.fileExists(atPath: state.appendingPathComponent("consults.json").path), "results persisted")

        // 3. 专业 agent 交互式启动。
        if let launchDir { profileLaunch(work: work, dir: launchDir) }
    }

    private static func profileLaunch(work: AssistantWork, dir: String) {
        work.profileStore.installDefaults()
        let profiles = work.currentProfiles()
        guard let tester = AgentProfileStore.find("tester", in: profiles), let file = work.writeLaunchFile(tester) else {
            return check(false, "tester profile installed")
        }
        check(profiles.map(\.name).sorted() == ["reviewer", "tester"], "built-in profiles installed")
        let sid = UUID().uuidString.lowercased()
        let command = DelegateCommand.claude(task: "Reply with exactly: TESTER-READY. Do not run any tool.", sessionID: sid,
                                             profile: (tester.name, file))
        say("launch: \(command)")
        let socket = "ccdesk-v14test"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let env = LaunchSpec.sanitizedEnvironment(base: ProcessInfo.processInfo.environment)
        func tmux(_ a: [String]) -> String {
            if case .finished(let out) = ProcessRunner.run("/usr/bin/env", ["tmux", "-L", socket, "-f", "/dev/null"] + a,
                                                           environment: env, cwd: nil, timeout: 10) { return out }
            return ""
        }
        let projects = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        let encoded = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let projectDir = projects.appendingPathComponent(encoded)
        let existedBefore = FileManager.default.fileExists(atPath: projectDir.path)
        _ = tmux(["kill-server"])
        _ = tmux(["new-session", "-d", "-s", "t", "-x", "160", "-y", "45", "-c", dir] + LaunchSpec.shellArgs(command: command)
            .reduce(into: [shell]) { $0.append($1) })
        var screen = ""
        let ok = wait(60) {
            screen = tmux(["capture-pane", "-p", "-t", "t"])
            // 提示本身也含 TESTER-READY：要出现两次（提示 + 回答）。
            return screen.components(separatedBy: "TESTER-READY").count > 2 && screen.contains("@tester")
        }
        say(screen.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(12)
            .joined(separator: "\n"))
        check(ok, "interactive claude started with the tester profile and answered the first prompt")
        _ = tmux(["kill-server"])
        // 删掉这次产生的会话记录（只删这个会话 id 的文件）。
        let transcript = projectDir.appendingPathComponent("\(sid).jsonl")
        if FileManager.default.fileExists(atPath: transcript.path) {
            try? FileManager.default.removeItem(at: transcript)
            say("removed transcript \(transcript.path)")
        }
        // 这次才建出来的项目目录（里面没有别的会话记录）一并删掉。
        let left = (try? FileManager.default.subpathsOfDirectory(atPath: projectDir.path)) ?? []
        if !existedBefore, !left.contains(where: { $0.hasSuffix(".jsonl") }) {
            try? FileManager.default.removeItem(at: projectDir)
            say("removed \(projectDir.path)")
        }
    }

    private static func finish(root: URL, repo: URL) {
        if let diag = try? String(contentsOf: AssistantDiag.url, encoding: .utf8) { say("diag:\n" + diag) }
        try? FileManager.default.removeItem(at: root)
        // claude 为临时仓库建的项目目录（--no-session-persistence 不写记录，但会建空目录）。
        let encoded = repo.path.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects/\(encoded)")
        let files = (try? FileManager.default.subpathsOfDirectory(atPath: dir.path)) ?? []
        if FileManager.default.fileExists(atPath: dir.path), !files.contains(where: { $0.hasSuffix(".jsonl") }) {
            try? FileManager.default.removeItem(at: dir)
        }
        say(failures == 0 ? "consult test: all passed" : "consult test: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
