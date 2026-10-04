import CoreServices
import Foundation
import CCDeskCore

/// 一个会话停止监视时留下的记录与回放位置（切回来时从这里继续，中间生成的文件由 FSEvents 回放补上）。
struct WatchMemory {
    struct Start {
        let eventID: FSEventStreamEventId
        let date: Date
    }

    let root: String
    let log: GeneratedFilesLog
    let start: Start
}

/// 「生成的文件」：选中会话期间监视它的项目根目录（设计 §17.1）。一次只有一个 `ProjectWatcher`；
/// 根目录是家目录 / 根目录 / 家目录下的常用大目录时不监视，面板里说明原因。只在主线程调用。
extension TouchedFilesModel {
    /// 最多记住这么多个会话的监视记录。
    static let watchMemoryLimit = 16
    static let firstSeenLimit = 300

    /// 侧栏里新出现的 agent 会话（只在会话集合变化时由 AppModel 调用）：记下当时的事件编号，
    /// 第一次选中它时从这里回放，会话开始后、选中之前生成的文件也能列出（会话在 CC Desk 启动前就开始时，从启动时算起）。
    func noteNewSessions(_ sessionIDs: Set<String>) {
        guard !sessionIDs.isEmpty else { return }
        let start = WatchMemory.Start(eventID: ProjectWatcher.currentEventID(), date: Date())
        for sid in sessionIDs where firstSeen[sid] == nil { firstSeen[sid] = start }
        if firstSeen.count > Self.firstSeenLimit {
            let oldest = firstSeen.sorted { $0.value.eventID < $1.value.eventID }.prefix(firstSeen.count - Self.firstSeenLimit)
            for (sid, _) in oldest { firstSeen[sid] = nil }
        }
    }

    /// 选中的会话变了：停掉旧的监视（记下它的记录与位置），为新会话开一个。
    func restartWatcher(root: String?) {
        stopWatcher()
        watchNote = nil
        guard let target, let root, !root.isEmpty else { return }
        if ProjectWatchRules.refusal(root: root) != nil {
            watchNote = .tooBroad
            return
        }
        let key = target.key
        let memory = watchMemory[key].flatMap { $0.root == root ? $0 : nil }
        let start = memory?.start ?? firstSeen[target.sessionID]
        let generation = currentGeneration
        let watcher = ProjectWatcher(root: root, log: memory?.log ?? GeneratedFilesLog(),
                                     since: start?.eventID, sinceDate: start?.date) { [weak self] files in
            guard let self, self.currentGeneration == generation else { return }
            guard files != self.generatedSnapshot else { return }
            self.generatedSnapshot = files
            self.recomputeFiles()
        }
        self.watcher = watcher
        watcher.start { [weak self] ok in
            guard let self, self.currentGeneration == generation, !ok else { return }
            self.watchNote = .failed
            self.watcher = nil
        }
    }

    /// 停止当前监视；记录与停下的位置存进 `watchMemory`（按会话，最多 `watchMemoryLimit` 个）。
    func stopWatcher() {
        guard let watcher, let target else {
            self.watcher?.stop()
            self.watcher = nil
            return
        }
        self.watcher = nil
        let key = target.key
        let root = watcher.root
        let stoppedAt = Date()
        watcher.stop { [weak self] log, eventID in
            guard let self else { return }
            self.watchMemory[key] = WatchMemory(root: root, log: log, start: .init(eventID: eventID, date: stoppedAt))
            self.watchMemoryOrder.removeAll { $0 == key }
            self.watchMemoryOrder.append(key)
            while self.watchMemoryOrder.count > Self.watchMemoryLimit {
                self.watchMemory[self.watchMemoryOrder.removeFirst()] = nil
            }
        }
    }
}
