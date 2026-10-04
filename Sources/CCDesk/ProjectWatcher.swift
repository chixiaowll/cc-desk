import CoreServices
import Foundation
import CCDeskCore

/// 选中会话的项目目录监视（设计 §17.1「生成的文件」）：FSEvents 文件级事件，延迟 1 秒合并一阵连续写入。
/// App 一次只开一个（`TouchedFilesModel` 在选中变化时停掉旧的）。流的创建、回调、停止都在自己的串行队列上，
/// 停止之后不会再有回调；结果快照回到主线程交给 `onChange`。
///
/// - 只记普通文件的新建 / 改动（`ProjectWatchRules.shouldInclude` 过滤依赖、构建、缓存目录与临时文件），
///   文件被删 / 移走就去掉；时间取文件的修改时间（回放的历史事件也准确）。
/// - `since`：从这个事件编号开始回放（上次停在这个会话时的位置，或第一次看到这个会话时的位置），
///   切走再切回来时中间生成的文件也能补上；没有时从现在开始。
final class ProjectWatcher {
    let root: String
    /// FSEvents 报的是真实路径（/var → /private/var 等）：按它比较，再换回 root 的写法。
    private let realRoot: String
    private let queue = DispatchQueue(label: "cc-desk.project-watcher", qos: .utility)
    private let since: FSEventStreamEventId?
    /// 只有在这之后诞生的文件才算「新建」：FSEvents 的 ItemCreated 标志会粘在同一文件后来的事件上
    /// （刚开始监视前建的文件，第一次改动也带着它），所以再用文件的创建时间核对一次。
    private let createdAfter: Date
    private let onChange: ([TouchedFile]) -> Void
    /// 以下只在 `queue` 上访问。
    private var stream: FSEventStreamRef?
    private var log: GeneratedFilesLog
    private var lastEventID: FSEventStreamEventId

    static let latency: CFTimeInterval = 1.0

    /// since / sinceDate：回放起点的事件编号与当时的时刻（没有时从现在开始）。
    init(root: String, log: GeneratedFilesLog = GeneratedFilesLog(), since: FSEventStreamEventId? = nil,
         sinceDate: Date? = nil, onChange: @escaping ([TouchedFile]) -> Void) {
        self.root = URL(fileURLWithPath: root).standardized.path
        // 用 realpath：URL.resolvingSymlinksInPath 会把 /private/var 反过来缩成 /var。
        self.realRoot = realpath(root, nil).map { buffer in
            defer { free(buffer) }
            return String(cString: buffer)
        } ?? URL(fileURLWithPath: root).standardized.path
        self.log = log
        self.since = since
        self.createdAfter = sinceDate ?? Date()
        self.lastEventID = since ?? FSEventsGetCurrentEventId()
        self.onChange = onChange
    }

    /// 当前全局事件编号（记下「第一次看到会话」的位置，供之后回放）。
    static func currentEventID() -> FSEventStreamEventId { FSEventsGetCurrentEventId() }

    /// 开始监视；completion（主线程）告诉调用方是否成功，并先给一次已有记录的快照。
    func start(completion: @escaping (Bool) -> Void = { _ in }) {
        queue.async { [self] in
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                retain: { info in
                    guard let info else { return nil }
                    _ = Unmanaged<ProjectWatcher>.fromOpaque(info).retain()
                    return info
                },
                release: { info in
                    guard let info else { return }
                    Unmanaged<ProjectWatcher>.fromOpaque(info).release()
                },
                copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
                guard let info else { return }
                let watcher = Unmanaged<ProjectWatcher>.fromOpaque(info).takeUnretainedValue()
                let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray) as? [String] ?? []
                watcher.handle(paths: list, flags: Array(UnsafeBufferPointer(start: flags, count: count)),
                               ids: Array(UnsafeBufferPointer(start: ids, count: count)))
            }
            let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
            guard let created = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, [realRoot] as CFArray,
                since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, flags)
            else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                DispatchQueue.main.async { completion(false) }
                return
            }
            stream = created
            let snapshot = log.files()
            DispatchQueue.main.async { [onChange] in
                completion(true)
                onChange(snapshot)
            }
        }
    }

    /// 停止监视；completion（主线程）带回累计的记录与停下时的事件编号（下次从这里回放）。
    func stop(completion: @escaping (GeneratedFilesLog, FSEventStreamEventId) -> Void = { _, _ in }) {
        queue.async { [self] in
            if let stream {
                lastEventID = max(lastEventID, FSEventStreamGetLatestEventId(stream))
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
            let result = (log, lastEventID)
            DispatchQueue.main.async { completion(result.0, result.1) }
        }
    }

    /// 只在 `queue` 上调用（FSEvents 回调）。
    private func handle(paths: [String], flags: [FSEventStreamEventFlags], ids: [FSEventStreamEventId]) {
        guard stream != nil else { return }
        var changed = false
        for (index, rawPath) in paths.enumerated() where index < flags.count {
            let flag = Int(flags[index])
            if index < ids.count { lastEventID = max(lastEventID, ids[index]) }
            guard flag & kFSEventStreamEventFlagItemIsFile != 0 else { continue }
            let path = mapToRoot(rawPath)
            guard ProjectWatchRules.shouldInclude(path: path, root: root) else { continue }
            guard let times = Self.regularFileTimes(path) else {
                if log.contains(path) {
                    log.remove(path)
                    changed = true
                }
                continue
            }
            let createdFlag = flag & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0
            let wrote = flag & kFSEventStreamEventFlagItemModified != 0
            guard createdFlag || wrote else { continue }
            log.record(path, created: createdFlag && times.born >= createdAfter, at: times.modified)
            changed = true
        }
        guard changed else { return }
        let snapshot = log.files()
        DispatchQueue.main.async { [onChange] in onChange(snapshot) }
    }

    private func mapToRoot(_ path: String) -> String {
        guard realRoot != root else { return path }
        if path == realRoot { return root }
        if path.hasPrefix(realRoot + "/") { return root + path.dropFirst(realRoot.count) }
        return path
    }

    /// 存在且是普通文件时返回创建 / 修改时间。
    static func regularFileTimes(_ path: String) -> (born: Date, modified: Date)? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        func date(_ t: timespec) -> Date {
            Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9)
        }
        return (date(info.st_birthtimespec), date(info.st_mtimespec))
    }
}
