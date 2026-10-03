import AppKit
import CCDeskCore

/// `CCDesk --tts-test [--silent] "<句子>"…`：不启动界面，验证自然语音引擎并打印耗时后退出。
/// 不碰控制接口、不读写 App 偏好。
/// 1. 启动服务 → 就绪耗时；2. 逐句朗读 → 首个音频 / 读完耗时与路线（natural / system）；
/// 3. 打断：长句出声 1 秒后 stop()，测服务端结束这段的耗时与下一句的首个音频；
/// 4. 后备：杀掉服务后立刻朗读应走系统声音，随后自动重启；暂停服务（SIGSTOP）时 2.5 秒后改用系统声音。
/// --silent：静音（播放照常进行，只是音量为 0）。
enum NaturalSpeechTest {
    private static let long = "好的，我先看一下 poems 那个会话。它刚才改了三个文件，测试全部通过了。接下来要我帮你提交吗？如果不需要，我就先待命。"

    static func runIfRequested() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "--tts-test" else { return }
        let silent = args.contains("--silent")
        let texts = args.dropFirst().filter { $0 != "--silent" }
        NaturalVoice.selectionOverride = true
        let engine = NaturalSpeechEngine.shared
        engine.keepWarm = true
        engine.muted = silent
        let output = SpeechOutput(engine: engine)
        output.muted = silent
        Task { @MainActor in
            await run(engine: engine, output: output, texts: Array(texts), silent: silent)
            engine.keepWarm = false
            engine.unload()
            try? await Task.sleep(nanoseconds: 500_000_000)
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

    private static func say(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }

    private static func ms(_ seconds: TimeInterval) -> String { String(format: "%.0f ms", seconds * 1000) }

    @MainActor
    private static func run(engine: NaturalSpeechEngine, output: SpeechOutput, texts: [String], silent: Bool) async {
        guard NaturalVoice.isInstalled else { return say("natural voice not installed at \(NaturalVoice.root.path)") }
        say("server script: \(NaturalVoice.serverScript?.path ?? "missing")")
        var t0 = Date()
        let ready = await waitReady(engine, timeout: 90)
        say("ready=\(ready) in \(ms(Date().timeIntervalSince(t0))) server=\(engine.readyInfo ?? "-") pid=\(engine.processID ?? 0)")
        guard ready else { return }

        for text in texts {
            let r = await speak(output, text)
            say("speak route=\(r.route.map { "\($0)" } ?? "-") firstAudio=\(r.first.map(ms) ?? "-") total=\(ms(r.total)) \"\(text)\"")
        }
        if !texts.isEmpty, !silent { return say("(audible run: skipping cancel / fallback tests)") }

        // 打断。
        // 服务端对被打断的每一句都回 end(cancelled)；正在合成的那句最慢，取最后一个。
        var serverEnd: (Date, String)?
        engine.onServerEnd = { id, stats in if stats.contains("\"cancelled\": true") { serverEnd = (Date(), "\(id) \(stats)") } }
        t0 = Date()
        var started: Date?
        output.onStart = { _ in started = started ?? Date() }
        output.speak(long)
        while started == nil, Date().timeIntervalSince(t0) < 10 { await pause(0.02) }
        await pause(1.0)
        let stopAt = Date()
        output.stop()
        await pause(1.5)
        say("cancel: firstAudio=\(started.map { ms($0.timeIntervalSince(t0)) } ?? "-") serverAck=\(serverEnd.map { ms($0.0.timeIntervalSince(stopAt)) } ?? "none") \(serverEnd?.1 ?? "")")
        engine.onServerEnd = nil
        let next = await speak(output, "收到，我停下了。")
        say("after cancel: route=\(next.route.map { "\($0)" } ?? "-") firstAudio=\(next.first.map(ms) ?? "-")")

        // 后备 1：服务被杀。
        if let pid = engine.processID { kill(pid, SIGKILL) }
        await pause(0.2)
        let killed = await speak(output, "服务挂了也要能说话。")
        say("server killed: state=\(engine.state) route=\(killed.route.map { "\($0)" } ?? "-") firstAudio=\(killed.first.map(ms) ?? "-")")
        t0 = Date()
        let restarted = await waitReady(engine, timeout: 90)
        say("auto restart ready=\(restarted) in \(ms(Date().timeIntervalSince(t0)))")

        // 后备 2：服务卡住（SIGSTOP），2.5 秒内没有音频。
        if restarted, let pid = engine.processID {
            kill(pid, SIGSTOP)
            let stuck = await speak(output, "服务卡住时，两秒半后改用系统声音。")
            say("server stopped: route=\(stuck.route.map { "\($0)" } ?? "-") firstAudio=\(stuck.first.map(ms) ?? "-")")
            kill(pid, SIGCONT)
            await pause(0.5)
            let back = await speak(output, "恢复了。")
            say("after SIGCONT: route=\(back.route.map { "\($0)" } ?? "-") firstAudio=\(back.first.map(ms) ?? "-")")
        }
        if let pid = engine.processID {
            let rss = ProcessRunner.run("/bin/ps", ["-o", "rss=", "-p", "\(pid)"], environment: nil, cwd: nil, timeout: 5)
            if case .finished(let out) = rss {
                say("server rss=\((Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) / 1024) MB")
            }
        }
    }

    @MainActor
    private static func waitReady(_ engine: NaturalSpeechEngine, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { cont in
            engine.whenReady(timeout: timeout) { cont.resume(returning: $0) }
        }
    }

    /// 读一句，等到读完；返回路线、首个音频耗时、总耗时。
    @MainActor
    private static func speak(_ output: SpeechOutput, _ text: String) async -> (route: SpeechOutput.Route?, first: TimeInterval?, total: TimeInterval) {
        let t0 = Date()
        var first: TimeInterval?
        var route: SpeechOutput.Route?
        var done = false
        output.onStart = { r in
            if first == nil { first = Date().timeIntervalSince(t0) }
            route = r
        }
        output.onFinish = { if !output.isSpeaking { done = true } }
        output.speak(text)
        while !done, Date().timeIntervalSince(t0) < 60 { await pause(0.02) }
        output.onStart = nil
        output.onFinish = nil
        return (route ?? output.lastRoute, first, Date().timeIntervalSince(t0))
    }

    private static func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
