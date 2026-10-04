import Foundation

/// 增量读取一个会话记录文件：记住读到的偏移，只读新增部分；文件变短（被重写）时从头再读。
/// 非线程安全；只在一个串行队列上使用。
public final class TouchedFilesTracker {
    public let url: URL
    private(set) public var log: TouchedFilesLog
    private var offset: UInt64 = 0
    /// 上次读到的不完整末行。
    private var pending = Data()
    private var lastSize: UInt64 = 0
    private var lastModified: Date?
    /// 一次最多读这么多，避免首次读大文件时占用过多内存（分块读完）。
    static let chunkSize = 4 * 1024 * 1024

    public init(url: URL, kind: AgentKind, cwd: String) {
        self.url = url
        self.log = TouchedFilesLog(kind: kind, cwd: cwd)
    }

    /// 文件大小 / 修改时间变了才读新增部分；返回记录是否可能有变化。
    /// `shouldContinue` 在每块之间检查：返回 false 时停下（已读的部分保留，下次从停下处继续）。
    @discardableResult
    public func refresh(shouldContinue: () -> Bool = { true }) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return false }
        let modified = attrs[.modificationDate] as? Date
        if size == lastSize, modified == lastModified { return false }
        if size < offset {
            // 文件被截断或重写：从头再来。
            log = TouchedFilesLog(kind: log.kind, cwd: log.cwd)
            offset = 0
            pending = Data()
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            while offset < size {
                guard shouldContinue() else { return false }
                let want = Int(min(UInt64(Self.chunkSize), size - offset))
                guard let data = try handle.read(upToCount: want), !data.isEmpty else { break }
                offset += UInt64(data.count)
                var buffer = pending + data
                if let lastNewline = buffer.lastIndex(of: UInt8(ascii: "\n")) {
                    let complete = buffer[buffer.startIndex...lastNewline]
                    log.ingest(Data(complete))
                    buffer = Data(buffer[buffer.index(after: lastNewline)...])
                }
                pending = buffer
            }
        } catch {
            return false
        }
        lastSize = size
        lastModified = modified
        return true
    }
}
