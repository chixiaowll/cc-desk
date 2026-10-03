import XCTest
@testable import CCDeskCore

/// 实测辅助：设置 CCDESK_SCREEN_DIR（含 screen.txt / title.txt）与 CCDESK_SCREEN_AGENT（codex / pi）时，
/// 用打包的规则检测该屏幕并打印结果；未设置时跳过。不对具体屏幕做断言。
final class LiveScreenProbeTests: XCTestCase {
    func testProbeScreenFromEnvironment() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["CCDESK_SCREEN_DIR"], let agent = env["CCDESK_SCREEN_AGENT"].flatMap(AgentKind.init(rawValue:)) else {
            throw XCTSkip("CCDESK_SCREEN_DIR 未设置")
        }
        let manifest = try XCTUnwrap(BundledManifests.manifest(for: agent))
        let screen = (try? String(contentsOfFile: dir + "/screen.txt", encoding: .utf8)) ?? ""
        let title = (try? String(contentsOfFile: dir + "/title.txt", encoding: .utf8)) ?? ""
        let d = ScreenDetector.detect(manifest, screen: screen, oscTitle: title)
        print("LIVE-PROBE agent=\(agent.rawValue) state=\(d.state.rawValue) rule=\(d.ruleID ?? "-") skip=\(d.skipStateUpdate)")
    }
}

/// 实测辅助：CCDESK_LIVE_INTEGRATION=install|uninstall|status 时对真实 HOME 执行 Codex / pi 集成操作；未设置时跳过。
final class LiveIntegrationTests: XCTestCase {
    func testLiveIntegrationAction() throws {
        guard let action = ProcessInfo.processInfo.environment["CCDESK_LIVE_INTEGRATION"] else {
            throw XCTSkip("CCDESK_LIVE_INTEGRATION 未设置")
        }
        let codex = CodexIntegration()
        let pi = PiIntegration()
        switch action {
        case "install":
            try codex.install()
            try pi.install()
        case "uninstall":
            try codex.uninstall()
            try pi.uninstall()
        default:
            break
        }
        print("LIVE-INTEGRATION codex=\(codex.status().label) pi=\(pi.status().label)")
    }
}

/// 实测辅助：CCDESK_LIVE_PIPELINE=1 时对本机真实进程跑一遍 Codex / pi 发现流程（与 App 的轮询相同的核心逻辑），打印结果。
final class LivePipelineTests: XCTestCase {
    func run(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testLivePipeline() throws {
        guard ProcessInfo.processInfo.environment["CCDESK_LIVE_PIPELINE"] != nil else { throw XCTSkip("CCDESK_LIVE_PIPELINE 未设置") }
        let table = ProcessTable.parse(run(["-axo", "pid=,ppid=,tty=,comm="]), args: run(["-axo", "pid=,args="]))
        let index = AgentSessionIndex()
        let snaps = AgentResolver.resolve(processes: table, details: { pid in
            let d = ProcessDetails.of(pid: pid, includeCwd: true)
            return (d?.cwd, d?.startedAt)
        }, hooks: HookStateReader.readAll(), index: index)
        let infos = snaps.map { s -> AgentProcessInfo in
            let st = AgentResolver.status(hook: s.hook, screen: nil, startedAt: s.startedAt, now: Date())
            return AgentProcessInfo(pid: s.pid, kind: s.kind, tty: s.tty, cwd: s.cwd, sessionID: s.sessionID,
                                    status: st.status, statusChangedAt: st.at)
        }
        let sessions = SessionBuilder.build(registry: [], processes: table, embedded: [], missing: [], agents: infos)
        for (s, row) in zip(snaps, sessions) {
            let meta = s.sessionPath.flatMap { index.meta(path: $0, kind: s.kind) }
            let title = (meta ?? TranscriptMeta()).displayTitle(fallbackName: nil, fallbackIsDerived: true)
            print("LIVE-PIPELINE id=\(row.id) kind=\(s.kind.rawValue) tty=\(s.tty ?? "-") host=\(row.host) cwd=\(s.cwd) "
                  + "session=\(s.sessionID ?? "-") file=\(s.sessionPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "-") "
                  + "hook=\(s.hook.map { "\($0.status.label)@\(Int($0.updatedAt.timeIntervalSince1970))" } ?? "-") "
                  + "status=\(row.status.label) title=\(title)")
        }
        let history = index.history(excluding: [])
        print("LIVE-PIPELINE history codex=\(history.filter { $0.kind == .codex }.count) pi=\(history.filter { $0.kind == .pi }.count)")
        for item in history.prefix(4) { print("LIVE-PIPELINE history \(item.kind.rawValue) \(item.sessionID.prefix(13)) \(item.title)") }
    }
}
