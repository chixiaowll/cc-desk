import Foundation
import CCDeskCore

/// 下载语音模型前的检查（设计 §29）：本机芯片、下载源连通性。网络检查会阻塞，只在后台线程调用。
enum ModelHubProbe {
    /// 是否 Apple 芯片（Rosetta 下运行也算）。
    static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }()

    private static let cache = Locked<[String: (ok: Bool, at: Date)]>([:])
    /// 连通性结果记这么久（设置页里点「检查」会忽略缓存）。
    static let cacheTTL: TimeInterval = 300

    /// 地址能否在几秒内连上（任何 HTTP 响应都算；超时 / DNS / TLS 失败算连不上）。
    static func reachable(_ endpoint: String, timeout: TimeInterval = 6, useCache: Bool = true) -> Bool {
        if useCache, let hit = cache.withLock({ $0[endpoint] }), Date().timeIntervalSince(hit.at) < cacheTTL {
            return hit.ok
        }
        guard let url = ModelHub.probeURL(endpoint) else { return false }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        let done = DispatchSemaphore(value: 0)
        let ok = Locked(false)
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if error == nil, let http = response as? HTTPURLResponse, http.statusCode < 500 { ok.withLock { $0 = true } }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 1) == .timedOut { task.cancel() }
        let result = ok.withLock { $0 }
        cache.withLock { $0[endpoint] = (result, Date()) }
        return result
    }

    /// 按设置选下载地址；都连不上时返回原因。
    static func resolve(source: ModelHubSource = .stored, useCache: Bool = true) -> Result<String, VoiceSupport.Problem> {
        if let endpoint = ModelHub.choose(source: source, reachable: { reachable($0, useCache: useCache) }) {
            AssistantDiag.log("model hub: source=\(source.rawValue) endpoint=\(endpoint)")
            return .success(endpoint)
        }
        AssistantDiag.log("model hub: source=\(source.rawValue) unreachable")
        return .failure(.hubUnreachable(source))
    }
}

/// 把 VoiceSupport.Problem 当作错误抛出（下载失败的提示条显示它的说明）。
struct VoiceSupportError: LocalizedError {
    let problem: VoiceSupport.Problem
    var errorDescription: String? { problem.message }
}
