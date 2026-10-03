import Foundation

/// 控制接口服务端（设计 §13）：Unix socket（目录 0700、socket 0600），只接受同一用户的连接，JSON 行协议。
/// 配置了 `token` 时每条请求必须带上同一口令（同一用户的其他进程——如内嵌终端里的 agent——拿不到它），否则拒绝。
/// 读写在后台队列；每条请求交给 `handler`（由调用方切到主线程执行），handler 可以异步回复（需确认的工具会等待用户）。
/// 回复按连接对象投递：连接断开后迟到的回复被丢弃，不会写给复用了同一 fd 的新连接。
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = (ControlRequest, @escaping (ControlResponse) -> Void) -> Void

    public let path: String
    private let token: String?
    private let handler: Handler
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "cc-desk.control")
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]

    private final class Connection {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer = LineBuffer()

        init(fd: Int32, source: DispatchSourceRead) {
            self.fd = fd
            self.source = source
        }
    }

    /// log：诊断信息（App 里写 AssistantDiag）。token：nil 时不鉴权（只用于测试）。
    public init(path: String, token: String? = nil, log: @escaping @Sendable (String) -> Void = { _ in },
                handler: @escaping Handler) {
        self.path = path
        self.token = token
        self.log = log
        self.handler = handler
    }

    /// 绑定并开始监听。已有活着的实例占用该路径时返回 false；残留的 socket 文件会被删除。
    public func start() -> Bool {
        queue.sync { startLocked() }
    }

    public func stop() {
        queue.sync {
            for connection in connections.values { connection.source.cancel() }
            connections = [:]
            listenSource?.cancel()
            listenSource = nil
            if listenFD >= 0 {
                close(listenFD)
                listenFD = -1
                unlink(path)
            }
        }
    }

    // MARK: 只在 queue 上调用

    private func startLocked() -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)
        if fm.fileExists(atPath: path) {
            if ControlClient.isAlive(path: path) {
                log("control: \(path) is owned by another CC Desk; not starting")
                return false
            }
            unlink(path)
        }
        guard var address = ControlClient.address(path) else {
            log("control: socket path too long: \(path)")
            return false
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            log("control: bind/listen failed errno=\(errno)")
            close(fd)
            return false
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.resume()
        listenSource = source
        log("control: listening on \(path)")
        return true
    }

    private func acceptConnections() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                log("control: rejected connection from uid \(uid)")
                close(fd)
                continue
            }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let connection = Connection(fd: fd, source: source)
            source.setEventHandler { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.read(connection)
            }
            source.setCancelHandler { close(fd) }
            connections[fd] = connection
            source.resume()
        }
    }

    private func read(_ connection: Connection) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = Darwin.read(connection.fd, &chunk, chunk.count)
        if n < 0, errno == EAGAIN || errno == EINTR { return }
        guard n > 0 else { return drop(connection) }
        let (lines, overflow) = connection.buffer.append(Data(chunk[0..<n]))
        if overflow { return drop(connection) }
        for line in lines {
            switch ControlRequest.parse(line) {
            case .failure(let response):
                write(response, to: connection)
            case .success(let request):
                if let token, !ControlToken.matches(request.token, expected: token) {
                    log("control: rejected \(request.method): missing or wrong token")
                    write(ControlResponse(id: request.id, error: ControlError(.unauthorized, "unauthorized")), to: connection)
                    continue
                }
                handler(request) { [weak self, weak connection] response in
                    guard let self else { return }
                    self.queue.async {
                        guard let connection else { return }
                        self.write(response, to: connection)
                    }
                }
            }
        }
    }

    private func write(_ response: ControlResponse, to connection: Connection) {
        // 连接可能已断开（客户端超时）；fd 也可能已被新连接复用：只写给仍登记的同一个连接对象。
        let fd = connection.fd
        guard connections[fd] === connection else { return }
        let bytes = Array((response.line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                offset += n
            } else if n < 0, errno == EAGAIN || errno == EINTR {
                usleep(1000)
            } else {
                return
            }
        }
    }

    private func drop(_ connection: Connection) {
        if connections[connection.fd] === connection { connections[connection.fd] = nil }
        connection.source.cancel()
    }
}

/// 控制接口客户端（`--mcp` 模式用）：每次调用新建连接，阻塞等待一行响应。
public enum ControlClient {
    public static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    private static func connect(path: String) -> Int32? {
        guard var address = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let ok = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else {
            close(fd)
            return nil
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// 有进程在该路径上接受连接。
    public static func isAlive(path: String) -> Bool {
        guard let fd = connect(path: path) else { return false }
        close(fd)
        return true
    }

    /// 发一条请求并等待响应；连不上 / 超时返回对应的错误。每次请求用唯一的 id，只接受 id 相同的响应。
    public static func call(path: String, method: String, params: [String: JSONValue], timeout: TimeInterval,
                            token: String? = nil) -> Result<JSONValue, ControlError> {
        guard let fd = connect(path: path) else {
            return .failure(ControlError(.unavailable, "CC Desk is not running (no control socket at \(path))"))
        }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let requestID = JSONValue.string(UUID().uuidString)
        let request = ControlRequest(id: requestID, method: method, params: params, token: token)
        let bytes = Array((request.line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { return .failure(ControlError(.unavailable, "control socket write failed")) }
            offset += n
        }
        var buffer = LineBuffer()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            let (lines, overflow) = buffer.append(Data(chunk[0..<n]))
            if overflow { return .failure(ControlError(.failed, "response too large")) }
            for line in lines {
                guard let response = ControlResponse.parse(line) else {
                    return .failure(ControlError(.failed, "invalid response from CC Desk"))
                }
                if response.id == requestID { return response.outcome }
                // 服务端没能解析请求时 id 为 null。
                if response.id == .null, case .failure = response.outcome { return response.outcome }
            }
        }
        return .failure(ControlError(.timeout, "CC Desk did not answer in time"))
    }
}
