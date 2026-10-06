import AppKit
import CoreServices
import CCDeskCore

/// 轮询节奏（设计 §26.2，规则在 Core `PollCadence`）：看着 CC Desk 时每秒一次，否则每 4 秒；
/// 回到前台 / 窗口重新可见 / 解锁 / hook 状态或 Claude 注册表文件变化时立即补一次。只在主线程使用。
final class PollPacer {
    private let poll: () -> Void
    private let watchPaths: [String]
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var watcher: StateFilesWatcher?
    private var screenLocked = false
    private var displayAsleep = false
    /// 上一次轮询开始的时刻（单调时钟）。
    private var lastPollStart: TimeInterval = 0
    private var inFlight = false
    /// 轮询进行中又有文件变化 / 回到前台：这一轮结束后尽快再来一次。
    private var pendingChange = false
    private(set) var running = false

    /// watchPaths：变化时立即轮询的目录（默认 hook 状态目录与 Claude 注册表目录；自检时换成临时目录）。
    init(watchPaths: [String] = [HookStateReader.defaultDirectory.path, RegistryReader.defaultDirectory.path],
         poll: @escaping () -> Void) {
        self.watchPaths = watchPaths
        self.poll = poll
    }

    var conditions: PollConditions {
        let windowVisible = NSApp.windows.contains {
            $0.isVisible && $0.canBecomeMain && $0.occlusionState.contains(.visible)
        }
        return PollConditions(appActive: NSApp.isActive, windowVisible: windowVisible,
                              screenLocked: screenLocked, displayAsleep: displayAsleep)
    }

    var interval: TimeInterval { PollCadence.interval(conditions) }

    func start() {
        guard !running else { return }
        running = true
        observe()
        let watcher = StateFilesWatcher(paths: watchPaths) { [weak self] in self?.changed() }
        watcher.start()
        self.watcher = watcher
        fire()
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        watcher?.stop()
        watcher = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    /// AppModel.poll() 开始后台读取时调用。
    func pollStarted() {
        lastPollStart = ProcessInfo.processInfo.systemUptime
        inFlight = true
    }

    /// AppModel.poll() 的结果合并完成后调用：按当前条件排下一次。
    func pollFinished() {
        inFlight = false
        let changed = pendingChange
        pendingChange = false
        schedule(changed: changed)
    }

    /// 状态文件变化 / 回到前台：尽快补一次轮询。
    func changed() {
        guard running else { return }
        if inFlight {
            pendingChange = true
        } else {
            schedule(changed: true)
        }
    }

    private func schedule(changed: Bool) {
        guard running else { return }
        let interval = self.interval
        let elapsed = ProcessInfo.processInfo.systemUptime - lastPollStart
        let delay = PollCadence.delay(elapsed: elapsed, interval: interval, changed: changed)
        timer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.fire() }
        timer.tolerance = changed ? 0.05 : PollCadence.tolerance(for: interval)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func fire() {
        timer = nil
        poll()
        // poll() 因上一轮还没结束而直接返回时，pollFinished 会排下一次；否则这里兜底，避免停摆。
        if !inFlight { schedule(changed: false) }
    }

    private func observe() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        func add(_ c: NotificationCenter, _ name: Notification.Name, _ body: @escaping (PollPacer) -> Void) {
            let token = c.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                body(self)
            }
            observers.append((c, token))
        }
        // 变快：立即补一次；变慢：下一次按新间隔排（不打断已排好的那次）。
        add(center, NSApplication.didBecomeActiveNotification) { $0.changed() }
        add(center, NSWindow.didChangeOcclusionStateNotification) { pacer in
            if pacer.interval == PollCadence.fast { pacer.changed() }
        }
        add(workspace, NSWorkspace.screensDidSleepNotification) { $0.displayAsleep = true }
        add(workspace, NSWorkspace.screensDidWakeNotification) { pacer in
            pacer.displayAsleep = false
            pacer.changed()
        }
        add(workspace, NSWorkspace.didWakeNotification) { $0.changed() }
        add(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true }
        add(distributed, Notification.Name("com.apple.screenIsUnlocked")) { pacer in
            pacer.screenLocked = false
            pacer.changed()
        }
    }
}

/// hook 状态目录与 Claude 注册表目录的文件级 FSEvents（延迟 0.2 秒合并一阵写入）。目录不存在时也可以监视，
/// 创建后开始报告。回调在主线程；只读这两处，App 自己的读取不会产生事件。
private final class StateFilesWatcher {
    private let paths: [String]
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "cc-desk.state-watch")

    init(paths: [String], onChange: @escaping () -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    func start() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<StateFilesWatcher>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { watcher.onChange() }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags)
        else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    /// 停止后不再回调（FSEventStreamInvalidate 同步完成；之前已派发到主线程的回调持有的是 self，PollPacer 仍会检查 running）。
    func stop() {
        guard let stream else { return }
        self.stream = nil
        queue.sync {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    deinit { stop() }
}
