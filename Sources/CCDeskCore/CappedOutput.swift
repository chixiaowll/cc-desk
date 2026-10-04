import Foundation

/// 子进程输出的上限缓冲（接口版顾问的 grep / git，设计 §22）：边读边存，超过 `limit` 字节后只保留前 `limit` 字节、
/// 其余丢弃，调用方在第一次超出时终止进程——输出再大也不会整个读进内存。非线程安全（每个管道一个读线程）。
public struct CappedOutput: Sendable {
    public let limit: Int
    public private(set) var data = Data()
    /// 输出超过了上限（data 只是开头）。
    public private(set) var exceeded = false

    public init(limit: Int) {
        self.limit = max(0, limit)
    }

    /// 追加一段；只有第一次超出上限时返回 true（调用方此时终止进程）。
    @discardableResult
    public mutating func append(_ chunk: Data) -> Bool {
        guard !exceeded else { return false }
        let room = limit - data.count
        if chunk.count <= room {
            data.append(chunk)
            return false
        }
        data.append(chunk.prefix(room))
        exceeded = true
        return true
    }
}
