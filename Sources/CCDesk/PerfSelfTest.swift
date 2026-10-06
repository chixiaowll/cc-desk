import AppKit
import SwiftUI
import CCDeskCore

/// `CCDesk --perf-selftest`：不启动界面、不连接正在运行的 CC Desk，量出空闲时每分钟的固定开销（设计 §26）：
/// - 侧栏显示时钟：典型侧栏一小时里需要前进几次（以前每秒一次）；
/// - 一次时钟前进让侧栏重绘的 CPU 时间（屏幕外窗口里渲染 10 行会话 + 底部用量）；
/// - 一次轮询的进程表耗时（原生 vs ps）与每分钟的轮询次数（看着 / 不看着）；
/// - 轮询节奏器实测：不在前台时按慢速档排、临时目录里写文件后立即补一次轮询；
/// - 加 `--whisper` 时加载 → 卸载 → 再加载本机语音模型，对比内存与重新加载耗时（需已下载模型；新进程第一次加载
///   要编译 ANE 程序，可能需要几分钟）。
enum PerfSelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.dropFirst().contains("--perf-selftest") else { return }
        exit(run(whisper: CommandLine.arguments.contains("--whisper")) ? 0 : 1)
    }

    private static var ok = true

    private static func check(_ condition: Bool, _ message: String) {
        print((condition ? "PASS " : "FAIL ") + message)
        if !condition { ok = false }
    }

    static func run(whisper: Bool) -> Bool {
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared
        let ticks = clockTicks()
        let renderMS = renderCostPerTick()
        print(String(format: "sidebar redraw per clock tick: %.2f ms CPU; per minute before %.0f ms, after %.1f ms",
                     renderMS, renderMS * 60, renderMS * ticks))
        pollCost()
        pacerLive()
        if whisper { whisperMemory() }
        print(ok ? "perf selftest passed" : "perf selftest FAILED")
        return ok
    }

    // MARK: 显示时钟

    /// 典型侧栏：几行会话（刚刚 / 几分钟 / 几十分钟 / 几小时 / 几天前）+ 用量（2 分钟前更新，3 小时与 4 天后重置）。
    private static func sampleDates(now: Date) -> [Date] {
        [-20, -200, -900, -2_700, -7_200, -18_000, -90_000, -260_000].map { now.addingTimeInterval(TimeInterval($0)) }
    }

    private static func sampleUsage(now: Date) -> ClaudeUsage {
        let limits = [
            UsageLimit(kind: "session", group: nil, percent: 42, severity: .normal, resetsAt: now.addingTimeInterval(3 * 3600),
                       scopeLabel: nil, isActive: false),
            UsageLimit(kind: "weekly_all", group: nil, percent: 61, severity: .normal,
                       resetsAt: now.addingTimeInterval(4 * 86400), scopeLabel: nil, isActive: false),
        ]
        return ClaudeUsage(planLabel: "Max", limits: limits, fetchedAt: now.addingTimeInterval(-120),
                           extraUsageEnabled: false, extraUsageDisabledReason: nil)
    }

    /// 返回每分钟的平均前进次数。
    private static func clockTicks() -> Double {
        let start = Date()
        let dates = sampleDates(now: start)
        let usage = sampleUsage(now: start)
        var now = start
        var ticks = 0
        let end = start.addingTimeInterval(3600)
        while let next = DisplayClock.nextChange(dates: dates, usage: usage, after: now, calendar: .current), next < end {
            // 轮询粒度：到点后的下一次轮询才前进（看着时 1 秒）。
            now = max(next, now.addingTimeInterval(PollCadence.fast))
            ticks += 1
        }
        let perMinute = Double(ticks) / 60
        print(String(format: "sidebar clock ticks in one hour: before 3600 (every second), after %d (%.2f per minute)",
                     ticks, perMinute))
        check(ticks < 3600 / 10, "display clock ticks at least 10x less often")
        return perMinute
    }

    private final class Clock: ObservableObject {
        @Published var now = Date()
    }

    private struct SidebarProbe: View {
        @ObservedObject var clock: Clock
        let rows: [SidebarRow]
        let usage: ClaudeUsage
        let theme: Theme

        var body: some View {
            VStack(spacing: 2) {
                ForEach(rows) { row in
                    SessionRowView(row: row, selected: false, now: clock.now, appIcon: nil, theme: theme)
                }
                SidebarFooter(rows: rows, usage: usage, now: clock.now, theme: theme)
            }
            .frame(width: 280)
        }
    }

    /// 屏幕外窗口里让时钟前进 N 次、每次强制排版与绘制，取进程 CPU 时间的平均值（毫秒）。
    private static func renderCostPerTick() -> Double {
        let now = Date()
        let theme = ThemeStore.shared.theme(for: .light)
        let statuses: [AgentStatus] = [.working, .idle, .waiting("Bash"), .idle, .working, .idle, .unknown, .idle, .idle, .idle]
        let rows = sampleDates(now: now).enumerated().map { i, date -> SidebarRow in
            let session = AgentSession(id: "perf-\(i)", kind: .claude, sessionID: "s\(i)", pid: nil, tty: nil,
                                       cwd: "/tmp/project", name: "会话 \(i) session", nameIsDerived: false,
                                       host: .embedded(terminalID: UUID()), status: statuses[i % statuses.count],
                                       statusChangedAt: date, backgroundWork: false)
            return SidebarRow(session: session, displayName: "会话 \(i) session", groupTitle: "project", subtitle: nil,
                              sourceLabel: nil, agentLabel: "Claude", tooltip: "")
        } + [0, 1].map { i -> SidebarRow in
            let session = AgentSession(id: "perf-x\(i)", kind: .claude, sessionID: "x\(i)", pid: nil, tty: nil,
                                       cwd: "/tmp/other", name: "other \(i)", nameIsDerived: false,
                                       host: .embedded(terminalID: UUID()), status: .idle,
                                       statusChangedAt: now.addingTimeInterval(-40), backgroundWork: false)
            return SidebarRow(session: session, displayName: "other \(i)", groupTitle: "other", subtitle: nil,
                              sourceLabel: nil, agentLabel: "Claude", tooltip: "")
        }
        let clock = Clock()
        let probe = SidebarProbe(clock: clock, rows: rows, usage: sampleUsage(now: now), theme: theme).uiScaleRoot()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: probe)
        hosting.frame = NSRect(x: 0, y: 0, width: 280, height: 700)
        window.contentView = hosting
        func settle() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            hosting.layoutSubtreeIfNeeded()
            hosting.display()
        }
        for _ in 0..<5 {
            clock.now = clock.now.addingTimeInterval(1)
            settle()
        }
        let runs = 60
        var idle: Double = 0
        let base = cpuMilliseconds()
        for _ in 0..<runs { settle() }
        idle = cpuMilliseconds() - base
        let start = cpuMilliseconds()
        for _ in 0..<runs {
            clock.now = clock.now.addingTimeInterval(1)
            settle()
        }
        let total = cpuMilliseconds() - start
        return max(0, total - idle) / Double(runs)
    }

    private static func cpuMilliseconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec) / 1000
        let system = Double(usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_stime.tv_usec) / 1000
        return user + system
    }

    // MARK: 轮询

    private static func pollCost() {
        let reader = NativeProcessReader()
        _ = reader.table()
        let nativeStart = cpuMilliseconds()
        let wallStart = Date()
        for _ in 0..<20 { _ = reader.table() }
        let nativeCPU = (cpuMilliseconds() - nativeStart) / 20
        let nativeWall = Date().timeIntervalSince(wallStart) * 1000 / 20
        let psStart = Date()
        for _ in 0..<3 { _ = SystemProbe.psProcessTable() }
        let psWall = Date().timeIntervalSince(psStart) * 1000 / 3
        print(String(format: "process table per poll: ps %.1f ms wall (2 child processes), native %.2f ms wall / %.2f ms CPU",
                     psWall, nativeWall, nativeCPU))
        print(String(format: "polls per minute: before 60 always; after %.0f while watched, %.0f otherwise " +
                     "(plus one per hook / registry change, at most every %.1f s)",
                     60 / PollCadence.fast, 60 / PollCadence.slow, PollCadence.minGap))
        check(nativeWall < psWall, "native process table is faster than ps")
    }

    /// 实测节奏器：自检进程不在前台，应按慢速档排；在监视目录里写文件后很快补一次轮询。
    private static func pacerLive() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ccdesk-perf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 让建目录本身的 FSEvents 先过去，不算进「定时」轮询。
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        var polls: [TimeInterval] = []
        var pacer: PollPacer?
        pacer = PollPacer(watchPaths: [dir.path]) {
            polls.append(ProcessInfo.processInfo.systemUptime)
            pacer?.pollStarted()
            DispatchQueue.main.async { pacer?.pollFinished() }
        }
        guard let pacer else { return }
        check(pacer.interval == PollCadence.slow, "background (inactive, no window) uses the slow cadence \(pacer.interval) s")
        let start = ProcessInfo.processInfo.systemUptime
        pacer.start()
        let window = PollCadence.slow * 2 - 0.5
        RunLoop.main.run(until: Date().addingTimeInterval(window))
        let regular = polls.count
        check(regular == 2, "regular polls in \(window) s: \(regular) " +
              "at \(polls.map { String(format: "%.1f", $0 - start) })")
        let written = ProcessInfo.processInfo.systemUptime
        FileManager.default.createFile(atPath: dir.appendingPathComponent("state.json").path, contents: Data("{}".utf8))
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let after = polls.first { $0 > written }.map { $0 - written }
        check(after.map { $0 < 1.2 } ?? false,
              "state file change triggers a poll within \(after.map { String(format: "%.2f s", $0) } ?? "never")")
        pacer.stop()
    }

    // MARK: 语音模型

    /// (phys_footprint, resident_size) MB。模型权重多为文件映射（resident 里有、footprint 里没有），ANE 上的程序在系统进程里。
    private static func memoryMB() -> (footprint: Double, resident: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (-1, -1) }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.resident_size) / 1_048_576)
    }

    /// 进程里映射着的模型文件数（`lsof`，只看自己）。
    private static func mappedModelFiles() -> Int {
        let output = SystemProbe.run("/usr/sbin/lsof", ["-p", String(getpid())], timeout: 10) ?? ""
        return output.split(separator: "\n").filter { $0.contains(".mlmodelc") }.count
    }

    /// 加载 → 卸载 → 再加载（量重新加载要多久，即空闲卸载后第一次用语音的等待）→ 卸载。
    private static func whisperMemory() {
        let transcriber = WhisperTranscriber.shared
        guard transcriber.isDownloaded else { return print("SKIP whisper (model not downloaded)") }
        func wait(_ body: @escaping @Sendable () async -> Void) {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await body()
                done.signal()
            }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        }
        func show(_ label: String, _ m: (footprint: Double, resident: Double)) {
            print(String(format: "whisper %@: footprint %.0f MB, resident %.0f MB, mapped model files %d",
                         label, m.footprint, m.resident, mappedModelFiles()))
        }
        show("before", memoryMB())
        var loads: [TimeInterval] = []
        var loaded = memoryMB()
        var unloaded = memoryMB()
        for round in 1...2 {
            let started = Date()
            wait {
                do { try await transcriber.prepare(progress: { _ in }) } catch { print("whisper load failed: \(error)") }
            }
            loads.append(Date().timeIntervalSince(started))
            loaded = memoryMB()
            show(String(format: "loaded #%d (%.1f s)", round, loads[round - 1]), loaded)
            wait { await transcriber.unload() }
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            unloaded = memoryMB()
            show("unloaded #\(round)", unloaded)
        }
        check(unloaded.footprint <= loaded.footprint, "unloading the voice model does not grow memory")
    }
}
