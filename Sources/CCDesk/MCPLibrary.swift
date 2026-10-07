import AppKit
import CCDeskCore

/// MCP 一览（设计 §31）：后台读各 agent 的 MCP 配置（只读、密钥打码）；「检查连接」时跑一次 `claude mcp list`，
/// 补上 claude.ai 连接器和每个 Claude MCP 的连接状态（要联网，约十几秒）。只在主线程使用。
final class MCPLibrary: ObservableObject {
    @Published private(set) var entries: [MCPServerEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isChecking = false
    /// 最近一次「检查连接」的时间与失败原因。
    @Published private(set) var checkedAt: Date?
    @Published private(set) var checkError: String?

    weak var model: AppModel?
    private let queue = DispatchQueue(label: "cc-desk.mcp", qos: .userInitiated)
    /// 最近一次 `claude mcp list` 的结果：重新读配置后再合进去。
    private var claudeList: [(name: String, target: String, health: MCPHealth)] = []

    init(model: AppModel?) {
        self.model = model
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let roots = model?.groups.map(\.id) ?? []
        queue.async { [weak self] in
            let scanned = MCPScanner.scan(.init(projectRoots: roots))
            DispatchQueue.main.async {
                guard let self else { return }
                self.entries = MCPCatalog.merge(claudeList: self.claudeList, into: scanned)
                self.isLoading = false
            }
        }
    }

    /// 跑 `claude mcp list`（在家目录下，不带项目范围），合并连接器与状态。
    func checkConnections() {
        guard !isChecking else { return }
        isChecking = true
        checkError = nil
        queue.async { [weak self] in
            var list: [(name: String, target: String, health: MCPHealth)] = []
            var failure: String?
            if let exe = AssistantClient.shared.resolvedClaude() {
                var env = LaunchSpec.sanitizedEnvironment(base: ProcessInfo.processInfo.environment)
                if let path = exe.searchPath { env["PATH"] = path }
                switch ProcessRunner.run(exe.path, ["mcp", "list"], environment: env,
                                         cwd: URL(fileURLWithPath: NSHomeDirectory()), timeout: 90) {
                case .finished(let out): list = MCPCatalog.parseClaudeList(out)
                case .failed(let message): failure = message
                case .timedOut: failure = L("mcp.check.timeout")
                }
            } else {
                failure = L("mcp.check.noClaude")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isChecking = false
                self.checkedAt = Date()
                self.checkError = failure
                if failure == nil {
                    self.claudeList = list
                    self.entries = MCPCatalog.merge(claudeList: list, into: self.entries)
                }
            }
        }
    }
}
