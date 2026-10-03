import Foundation
import CCDeskCore

/// 顾问 / 派活 / 专业 agent 工具（设计 §14）。执行在 AssistantWork 里；这里只做参数解析与给模型看的结果。
extension AssistantToolbox {
    func consult(_ args: ToolArgs, _ done: @escaping Completion) {
        guard let model else { return done(Self.shuttingDown) }
        guard let question = args.text("question"), ConversationText.isMeaningful(question) else {
            return done(.failure(ControlError(.invalidParams, "question is empty")))
        }
        var profile: AgentProfile?
        if let ref = args.string("profile") {
            let profiles = model.work.currentProfiles()
            guard let found = AgentProfileStore.find(ref, in: profiles) else {
                return done(Self.failure("No agent profile matches \"\(ref)\". Profiles: " +
                                         profiles.map(\.name).joined(separator: ", ")))
            }
            guard found.isReadOnly else {
                return done(Self.failure("\(found.name) can run commands or edit files, so it cannot be a background " +
                                         "consult; use delegate with profile \(found.name) instead"))
            }
            profile = found
        }
        let path: String
        switch projectPath(args.string("project")) {
        case .failure(let error): return done(.failure(error))
        case .success(let p): path = p
        }
        let level = ConsultLevel(loose: args.string("level"))
        let name = URL(fileURLWithPath: path).lastPathComponent
        switch model.work.startConsult(question: question, level: level, profile: profile, project: path) {
        case .success(let job):
            show(L("assistant.activity.consult", job.model.capitalized, name))
            done(Self.text("Started consult \(job.id) with \(job.model)\(profile.map { " as \($0.name)" } ?? "") in \(name) " +
                           "(background, read-only, up to 5 minutes). Tell the user in a few words that you asked the " +
                           "senior assistant; its answer will arrive later as a [CONSULT_RESULT] message."))
        case .failure(.tooMany(let running)):
            done(Self.failure("Already running \(running.count) consults (\(running.joined(separator: ", "))); wait for one " +
                              "to finish or cancel_consult"))
        case .failure(.noClaude):
            done(Self.failure("Claude Code was not found"))
        case .failure(.failed(let message)):
            done(Self.failure(message))
        }
    }

    func delegate(_ args: ToolArgs, _ done: @escaping Completion) {
        guard let model else { return done(Self.shuttingDown) }
        guard let task = args.text("task"), ConversationText.isMeaningful(task) else {
            return done(.failure(ControlError(.invalidParams, "task is empty")))
        }
        var profile: AgentProfile?
        if let ref = args.string("profile") {
            let profiles = model.work.currentProfiles()
            guard let found = AgentProfileStore.find(ref, in: profiles) else {
                return done(Self.failure("No agent profile matches \"\(ref)\". Profiles: " +
                                         profiles.map(\.name).joined(separator: ", ")))
            }
            profile = found
        }
        let agentName = (args.string("agent") ?? "claude").lowercased()
        guard let agent = AgentKind(rawValue: agentName), agent.isAgent, AgentAdapters.adapter(for: agent) != nil else {
            return done(.failure(ControlError(.invalidParams, "agent must be claude, codex or pi")))
        }
        if profile != nil, agent != .claude {
            return done(.failure(ControlError(.invalidParams, "profiles only work with agent claude")))
        }
        guard args.string("project") != nil else {
            return done(.failure(ControlError(.invalidParams, "project is required (see list_projects)")))
        }
        let cwd: String
        switch projectPath(args.string("project")) {
        case .failure(let error): return done(.failure(error))
        case .success(let p): cwd = p
        }
        guard model.availability(of: agent) != .notInstalled else {
            return done(Self.failure("\(agent.displayName) is not installed"))
        }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        var command: String?
        var sessionID: String?
        if agent == .claude {
            // 预先指定会话 id：派出的任务一启动就能对上会话记录。
            let sid = UUID().uuidString.lowercased()
            var launch: (name: String, jsonFile: String)?
            if let profile {
                guard let file = model.work.writeLaunchFile(profile) else {
                    return done(Self.failure("could not prepare the \(profile.name) profile"))
                }
                launch = (profile.name, file)
            }
            command = DelegateCommand.claude(task: task, sessionID: sid, profile: launch)
            sessionID = sid
        }
        let who = profile?.title ?? agent.displayName
        show(L("assistant.activity.delegate", name, who))
        guard let tid = model.newSession(cwd: cwd, kind: agent, prompt: task, command: command, select: false) else {
            return done(Self.failure("could not start \(agent.displayName) in \(name)"))
        }
        let rowID = "term:\(tid.uuidString)"
        model.work.recordDelegation(Delegation(rowID: rowID, terminalID: tid.uuidString, sessionID: sessionID,
                                               project: cwd, task: task, agent: agent.rawValue, profile: profile?.name,
                                               startedAt: Date()))
        model.inputs.record(.created(rowID: rowID, title: name))
        AssistantDiag.log("delegate \(rowID) agent=\(agent.rawValue) profile=\(profile?.name ?? "-") cwd=\(cwd) " +
                          "task=\"\(AssistantContext.clip(task, 120))\"")
        done(Self.text("Delegated to \(shortID(forRow: rowID)) (\(profile.map { "\($0.name) profile" } ?? agent.rawValue) " +
                       "in \(name)); the task was sent as its first message. It runs as a visible session in the sidebar " +
                       "(not selected); CC Desk will send you an [EVENT] when it needs approval or finishes a turn."))
    }

    func listAgents(_ done: @escaping Completion) {
        guard let model else { return done(Self.shuttingDown) }
        show(L("assistant.activity.list"))
        let profiles = model.work.currentProfiles()
        done(.success(["agents": .array(profiles.map(\.json)),
                       "directory": .string("~/.cc-desk/agents (Claude Code subagent format)")]))
    }

    func listConsults(_ done: @escaping Completion) {
        guard let model else { return done(Self.shuttingDown) }
        show(L("assistant.activity.list"))
        done(.success(["consults": .array(model.work.consults.jobs.prefix(10).map(\.json))]))
    }

    func cancelConsult(_ args: ToolArgs, _ done: @escaping Completion) {
        guard let model else { return done(Self.shuttingDown) }
        guard let id = model.work.cancelConsult(args.string("job")) else {
            return done(Self.failure("No running consult" + (args.string("job").map { " with id \($0)" } ?? "")))
        }
        show(L("assistant.activity.cancelConsult"))
        done(Self.text("cancelled consult \(id)"))
    }

    /// 项目引用 → 存在的目录；省略时用选中会话的项目。
    private func projectPath(_ ref: String?) -> Result<String, ControlError> {
        guard let model else { return .failure(ControlError(.unavailable, "CC Desk is shutting down")) }
        let raw: String
        if let ref {
            switch project(ref) {
            case .failure(let error): return .failure(error)
            case .success(let p): raw = p.path
            }
        } else if let row = model.selectedRow {
            raw = row.session.cwd
        } else {
            return .failure(ControlError(.invalidParams, "No project given and no session selected"))
        }
        let cwd = ProjectResolver.canonical(raw)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            return .failure(ControlError(.failed, "directory does not exist: \(cwd)"))
        }
        return .success(cwd)
    }
}
