import Foundation
import CCDeskCore

/// 各个工具的实现（设计 §13 工具表）。结果是给模型看的简短英文；朗读与提示条用界面语言。
extension AssistantToolbox {
    // MARK: 只读

    func listSessions(_ done: @escaping Completion) {
        guard let model else { return done(Self.shuttingDown) }
        show(L("assistant.activity.list"))
        let sessions = model.assistantSessions()
        done(.success(["sessions": .array(sessions.map(\.json))]))
    }

    func readScreen(_ args: ToolArgs, _ done: @escaping Completion) {
        switch resolveEmbedded(args.string("session")) {
        case .failure(let error): done(.failure(error))
        case .success(let (target, terminal)):
            show(L("assistant.activity.read", target.name))
            let lines = min(max(args.int("lines") ?? 40, 1), 200)
            terminal.screenText(lines: lines) { screen in
                done(Self.text("Screen of \(target.info.shortID) (\(target.info.dir)), bottom \(lines) lines:\n" + screen))
            }
        }
    }

    func readTranscript(_ args: ToolArgs, _ done: @escaping Completion) {
        guard let model else { return done(Self.shuttingDown) }
        switch resolve(args.string("session")) {
        case .failure(let error): done(.failure(error))
        case .success(let target):
            show(L("assistant.activity.read", target.name))
            let turns = min(max(args.int("turns") ?? 1, 1), 5)
            model.transcriptDigest(for: target.row, turns: turns) { digest in
                guard let digest, !digest.digest.isEmpty else {
                    return done(Self.failure("No transcript found for \(target.info.shortID); try read_screen"))
                }
                done(Self.text("Transcript of \(target.info.shortID) (\(target.info.dir), status " +
                               "\(AssistantContext.statusCode(digest.status))), last \(turns) turn(s):\n" + digest.digest))
            }
        }
    }

    func listHistory(_ args: ToolArgs, _ done: @escaping Completion) {
        show(L("assistant.activity.list"))
        var items = historyItems()
        if let query = args.string("query") {
            items = AssistantReferences.fuzzy(query.lowercased(), in: items) { [$0.title, $0.dir, $0.agent.rawValue] }
        }
        done(.success(["history": .array(items.prefix(AssistantContext.maxHistory).map(\.json))]))
    }

    func listProjects(_ done: @escaping Completion) {
        guard let model else { return done(Self.shuttingDown) }
        show(L("assistant.activity.list"))
        let home = NSHomeDirectory()
        done(.success(["projects": .array(model.assistantProjects().map { p in
            let path = p.path.hasPrefix(home + "/") ? "~" + p.path.dropFirst(home.count) : p.path
            return ["name": .string(p.name), "path": .string(path)]
        })]))
    }

    func gitStatus(_ args: ToolArgs, _ done: @escaping Completion) {
        guard let model else { return done(Self.shuttingDown) }
        let path: String
        if let ref = args.string("project") {
            switch project(ref) {
            case .failure(let error): return done(.failure(error))
            case .success(let p): path = p.path
            }
        } else if let row = model.selectedRow {
            path = ProjectResolver.canonical(row.session.cwd)
        } else {
            return done(Self.failure("No project given and no session selected"))
        }
        show(L("assistant.activity.git", URL(fileURLWithPath: path).lastPathComponent))
        DispatchQueue.global(qos: .userInitiated).async {
            let text = Self.gitSummary(path)
            DispatchQueue.main.async { done(text) }
        }
    }

    /// 只读 git 命令，各 5 秒超时；不执行仓库配置里的外部程序（GitSafety）。
    private static func gitSummary(_ path: String) -> Result<JSONValue, ControlError> {
        let env = GitSafety.environment(ProcessInfo.processInfo.environment)
        func git(_ args: [String]) -> String? {
            if case .finished(let out) = ProcessRunner.run("/usr/bin/git", ["-C", path] + args, environment: env, cwd: nil,
                                                          timeout: 5) { return out }
            return nil
        }
        guard let status = git(["status", "--short", "--branch"]) else {
            return failure("\(path) is not a git repository (or git timed out)")
        }
        var lines = status.split(whereSeparator: \.isNewline).map(String.init)
        let branch = lines.isEmpty ? "" : lines.removeFirst()
        let changed = lines.prefix(30).joined(separator: "\n") + (lines.count > 30 ? "\n… \(lines.count - 30) more" : "")
        let log = git(["log", "-5", "--format=%h %s (%cr)"]) ?? ""
        return text("Branch: \(branch.replacingOccurrences(of: "## ", with: ""))\nChanged files (\(lines.count)):\n" +
                    (changed.isEmpty ? "none" : changed) + "\nLast commits:\n" + log)
    }

    // MARK: 操作

    func switchTo(_ args: ToolArgs, _ done: @escaping Completion) {
        guard let model else { return done(Self.shuttingDown) }
        switch resolve(args.string("session")) {
        case .failure(let error): done(.failure(error))
        case .success(let target) where target.row.session.host.isEmbedded:
            show(L("assistant.activity.switch", target.name))
            let previous = model.selectedID
            guard previous != target.row.id else { return done(Self.text("\(target.info.shortID) is already selected")) }
            model.activate(target.row)
            if let previous {
                let title = model.assistantRow(previous).map { AssistantContext.clip($0.title, 20) } ?? ""
                model.inputs.record(.switched(from: previous, title: title))
            }
            done(Self.text("switched to \(target.info.shortID) (\(target.info.dir))"))
        case .success(let target):
            // 外部终端里的会话：语音没法输入进去，问一句是否接管到 CC Desk。
            guard model.canTakeOver(target.row) else {
                return done(Self.failure("\(target.info.shortID) runs in an external terminal and cannot be taken over"))
            }
            confirmTakeOver(target, done)
        }
    }

    func typeText(_ args: ToolArgs, _ done: @escaping Completion) {
        guard let model else { return done(Self.shuttingDown) }
        guard let text = args.text("text"), ConversationText.isMeaningful(text) else {
            return done(.failure(ControlError(.invalidParams, "text is empty")))
        }
        switch resolveEmbedded(args.string("session")) {
        case .failure(let error): done(.failure(error))
        case .success(let (target, terminal)):
            let submit = args.bool("submit") ?? false
            let preview = AssistantContext.clip(text, 30)
            show(submit ? L("assistant.activity.typeSubmit", target.name, preview) : L("assistant.activity.type", target.name, preview),
                 quiet: !submit)
            model.inputs.type(text, into: terminal, title: target.name, submit: submit)
            done(Self.text(submit ? "typed and sent to \(target.info.shortID)"
                                  : "typed into \(target.info.shortID), not sent yet (the user can say 发送, or call press_key enter)"))
        }
    }

    func clearInput(_ args: ToolArgs, _ done: @escaping Completion) {
        guard let model else { return done(Self.shuttingDown) }
        switch resolveEmbedded(args.string("session")) {
        case .failure(let error): done(.failure(error))
        case .success(let (target, terminal)):
            show(L("assistant.activity.clear", target.name))
            let count = model.inputs.clear(terminal)
            done(Self.text(count > 0 ? "cleared \(count) characters in \(target.info.shortID)"
                                     : "nothing typed by CC Desk is pending in \(target.info.shortID)"))
        }
    }

    func pressKey(_ args: ToolArgs, _ done: @escaping Completion) {
        guard let model else { return done(Self.shuttingDown) }
        guard let key = args.string("key").flatMap(AssistantKey.init(spoken:)) else {
            return done(.failure(ControlError(.invalidParams, "key must be one of " +
                                              AssistantKey.allCases.map(\.rawValue).joined(separator: ", "))))
        }
        switch resolveEmbedded(args.string("session")) {
        case .failure(let error): done(.failure(error))
        case .success(let (target, terminal)):
            show(L("assistant.activity.key", target.name, key.rawValue))
            let press = {
                terminal.sendKeys(key.bytes(applicationCursor: terminal.applicationCursor))
                if key == .enter || key == .ctrlC { model.inputs.submitted(terminal.id) }
                done(Self.text("pressed \(key.rawValue) in \(target.info.shortID)"))
            }
            guard key == .ctrlC else { return press() }
            confirm(question: L("assistant.confirm.interrupt", target.name),
                    toast: L("assistant.toast.confirmInterrupt", target.name)) { ok in
                ok ? press() : done(Self.text("cancelled by the user"))
            }
        }
    }

    func respondApproval(_ args: ToolArgs, _ done: @escaping Completion) {
        guard let model else { return done(Self.shuttingDown) }
        guard let approve = args.bool("approve") else {
            return done(.failure(ControlError(.invalidParams, "approve (true/false) is required")))
        }
        switch resolveEmbedded(args.string("session")) {
        case .failure(let error): done(.failure(error))
        case .success(let (target, _)):
            // 不在等批准时回车会把输入框里的内容发出去，Esc 会打断 agent：一律不执行。
            guard case .waiting(let reason) = target.row.session.status,
                  let episode = model.waitingEpisodes.episode(target.row.id) else {
                return done(Self.failure("\(target.info.shortID) is not waiting for approval " +
                                         "(status \(AssistantContext.statusCode(target.row.session.status)))"))
            }
            // 刚主动播报过这个会话的等批准（设计 §14）：只批准用户听到的那个请求（同一次等待），请求已变就不执行。
            let announced = model.work.announcement(rowID: target.row.id)
            let expectedReason = announced?.reason ?? reason
            let expectedEpisode = announced?.episode ?? episode.id
            let apply = { [weak self] in
                guard let self else { return done(Self.shuttingDown) }
                done(self.applyApproval(target, approve: approve, expectedReason: expectedReason,
                                        expectedEpisode: expectedEpisode))
            }
            // 用户这句话要在请求出现（和播报）之后才开始说，否则先语音确认：说「批准」时可能还没听到 / 看到这个请求。
            let spokenAt = args.turn?.spokenAt
            guard AssistantToolPolicy.approvalNeedsConfirmation(spokenAt: spokenAt, waitingSince: episode.since,
                                                                announcedAt: announced?.at) else { return apply() }
            let question: String
            if !approve {
                question = L("assistant.confirm.deny", target.name)
            } else if let what = SpokenStatus.shorten(reason) {
                question = L("assistant.confirm.approveReason", target.name, what)
            } else {
                question = L("assistant.confirm.approve", target.name)
            }
            let toast = approve ? L("assistant.toast.confirmApprove", target.name)
                                : L("assistant.toast.confirmDeny", target.name)
            confirm(question: question, toast: toast) { ok in
                ok ? apply() : done(Self.text("cancelled by the user"))
            }
        }
    }

    /// 复核后发键（ApprovalNotification.decide：仍在等同一次请求）。
    private func applyApproval(_ target: Target, approve: Bool, expectedReason: String?,
                               expectedEpisode: Int) -> Result<JSONValue, ControlError> {
        guard let model else { return Self.shuttingDown }
        let decision = model.assistantRespondApproval(rowID: target.row.id, expectedReason: expectedReason,
                                                      expectedEpisode: expectedEpisode, approve: approve)
        switch decision {
        case .apply:
            show(approve ? L("assistant.activity.approve", target.name) : L("assistant.activity.deny", target.name))
            return Self.text(approve ? "approved in \(target.info.shortID)" : "denied in \(target.info.shortID)")
        case .reasonChanged:
            var current = ""
            if case .waiting(let reason?) = model.sidebarRow(target.row.id)?.session.status { current = reason }
            return Self.failure("\(target.info.shortID): the permission request changed since the user heard about " +
                                "it (now it wants: \(AssistantContext.clip(current, 120))); tell the user what it wants " +
                                "now and ask again")
        case .notWaiting:
            return Self.failure("\(target.info.shortID) is no longer waiting for approval")
        case .gone, .notEmbedded:
            return Self.failure("\(target.info.shortID) is gone")
        }
    }

    func newSession(_ args: ToolArgs, _ done: @escaping Completion) {
        guard let model else { return done(Self.shuttingDown) }
        let agentName = (args.string("agent") ?? "claude").lowercased()
        guard let agent = AgentKind(rawValue: agentName), agent.isAgent, AgentAdapters.adapter(for: agent) != nil else {
            return done(.failure(ControlError(.invalidParams, "agent must be claude, codex or pi")))
        }
        let path: String
        switch project(args.string("project")) {
        case .failure(let error): return done(.failure(error))
        case .success(let p): path = p.path
        }
        let cwd = ProjectResolver.canonical(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            return done(Self.failure("directory does not exist: \(cwd)"))
        }
        guard model.availability(of: agent) != .notInstalled else {
            return done(Self.failure("\(agent.displayName) is not installed"))
        }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        show(L("assistant.activity.new", name, agent.displayName))
        let prompt = args.text("prompt").flatMap { ConversationText.isMeaningful($0) ? $0 : nil }
        guard let tid = model.newSession(cwd: cwd, kind: agent, prompt: prompt) else {
            return done(Self.failure("could not start \(agent.displayName) in \(name)"))
        }
        let rowID = "term:\(tid.uuidString)"
        model.inputs.record(.created(rowID: rowID, title: name))
        done(Self.text("started \(agent.rawValue) in \(name) as \(shortID(forRow: rowID))" +
                       (prompt == nil ? "" : ", first message sent")))
    }

    func resumeSession(_ args: ToolArgs, _ done: @escaping Completion) {
        guard let model else { return done(Self.shuttingDown) }
        let items = historyItems()
        switch AssistantReferences.history(args.string("history_id"), in: items) {
        case .notFound:
            done(Self.failure("No past session matches \"\(args.string("history_id") ?? "")\"; use list_history"))
        case .ambiguous(let candidates):
            done(.failure(ControlError(.invalidParams, "Several past sessions match, ask which one: " +
                                       candidates.map { "\($0.shortID) \($0.dir) / \(AssistantContext.clip($0.title, 30))" }
                                       .joined(separator: "; "))))
        case .found(let info):
            guard let entry = model.history.first(where: { $0.item.sessionID == info.sessionID }) else {
                return done(Self.failure("that session is no longer in history"))
            }
            let cwd = ProjectResolver.canonical(entry.item.cwd)
            guard FileManager.default.fileExists(atPath: cwd) else { return done(Self.failure("directory is gone: \(cwd)")) }
            show(L("assistant.activity.resume", AssistantContext.clip(info.title, 20)))
            model.resumeHistory(entry.item)
            done(Self.text("resumed \(info.shortID) (\(info.dir))"))
        }
    }

    func closeSession(_ args: ToolArgs, _ done: @escaping Completion) {
        guard let model else { return done(Self.shuttingDown) }
        switch resolve(args.string("session")) {
        case .failure(let error): done(.failure(error))
        case .success(let target):
            guard target.row.session.host.isEmbedded else {
                return done(Self.failure("\(target.info.shortID) runs in an external terminal; CC Desk only closes its own sessions"))
            }
            show(L("assistant.activity.close", target.name))
            confirm(question: L("assistant.confirm.close", target.name), toast: L("assistant.toast.confirmClose", target.name)) { ok in
                guard ok else { return done(Self.text("cancelled by the user")) }
                guard let row = model.sidebarRow(target.row.id) else { return done(Self.failure("session is already gone")) }
                model.closeWithoutConfirmation(row)
                done(Self.text("closed \(target.info.shortID)"))
            }
        }
    }

    func takeOver(_ args: ToolArgs, _ done: @escaping Completion) {
        guard let model else { return done(Self.shuttingDown) }
        switch resolve(args.string("session")) {
        case .failure(let error): done(.failure(error))
        case .success(let target):
            guard !target.row.session.host.isEmbedded else {
                return done(Self.failure("\(target.info.shortID) is already inside CC Desk"))
            }
            guard model.canTakeOver(target.row) else {
                return done(Self.failure("\(target.info.shortID) cannot be taken over (no resumable session id)"))
            }
            confirmTakeOver(target, done)
        }
    }

    private func confirmTakeOver(_ target: Target, _ done: @escaping Completion) {
        guard let model else { return done(Self.shuttingDown) }
        show(L("assistant.activity.takeOver", target.name))
        confirm(question: L("assistant.confirm.takeOver", target.name), toast: L("assistant.toast.confirmTakeOver", target.name)) { ok in
            guard ok else { return done(Self.text("cancelled by the user")) }
            guard let row = model.sidebarRow(target.row.id) else { return done(Self.failure("session is already gone")) }
            model.takeOver(row, confirmed: true)
            done(Self.text("taking over \(target.info.shortID): it restarts inside CC Desk in a few seconds"))
        }
    }

    // MARK: 辅助

    private func historyItems() -> [AssistantHistoryInfo] {
        guard let model else { return [] }
        return model.history.prefix(100).map {
            AssistantHistoryInfo(sessionID: $0.item.sessionID, shortID: shortID(forHistory: $0.item.sessionID),
                                 title: $0.item.title, dir: $0.projectTitle, agent: $0.item.kind)
        }
    }

    /// 项目名 / 路径；不在列表里但目录存在的绝对路径（或 ~ 开头）也接受。
    func project(_ ref: String?) -> Result<AssistantProject, ControlError> {
        guard let model else { return .failure(ControlError(.unavailable, "CC Desk is shutting down")) }
        let projects = model.assistantProjects()
        switch AssistantReferences.project(ref, in: projects) {
        case .found(let p): return .success(p)
        case .ambiguous(let candidates):
            return .failure(ControlError(.invalidParams, "Several projects match, ask which one: " +
                                         candidates.map { "\($0.name) (\($0.path))" }.joined(separator: "; ")))
        case .notFound:
            if let ref, ref.hasPrefix("/") || ref.hasPrefix("~") {
                let path = (ref as NSString).expandingTildeInPath
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    return .success(AssistantProject(name: URL(fileURLWithPath: path).lastPathComponent, path: path))
                }
            }
            return .failure(ControlError(.invalidParams, "No project matches \"\(ref ?? "")\". Projects: " +
                                         projects.prefix(15).map(\.name).joined(separator: ", ")))
        }
    }
}
