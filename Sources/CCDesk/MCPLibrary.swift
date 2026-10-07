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

    // MARK: 移到全局（设计 §31.1）

    @Published private(set) var promoting: String?

    /// 确认后把一个 Claude 本地 / 项目范围的 MCP 加到全局（用户范围），本地范围的可选同时删掉原来那份。
    /// 配置原样交给 `claude mcp add-json`，不显示、不记日志。只在主线程调用。
    func confirmPromote(_ entry: MCPServerEntry) {
        guard MCPPromotion.canPromote(entry), promoting == nil else { return }
        if MCPPromotion.existsInUserScope(entry.name) {
            let alert = NSAlert()
            alert.messageText = L("mcp.promote.exists.title", entry.name)
            alert.informativeText = L("mcp.promote.exists.message")
            alert.addButton(withTitle: L("action.ok"))
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = L("mcp.promote.title", entry.name)
        let removable = MCPPromotion.canRemoveOriginal(entry)
        alert.informativeText = removable ? L("mcp.promote.message.local") : L("mcp.promote.message.project")
        if removable { alert.addButton(withTitle: L("mcp.promote.move")) }
        alert.addButton(withTitle: L("mcp.promote.copy"))
        alert.addButton(withTitle: L("action.cancel"))
        let response = alert.runModal()
        let remove: Bool
        switch (removable, response) {
        case (true, .alertFirstButtonReturn): remove = true
        case (true, .alertSecondButtonReturn), (false, .alertFirstButtonReturn): remove = false
        default: return
        }
        promote(entry, removeOriginal: remove)
    }

    private func promote(_ entry: MCPServerEntry, removeOriginal: Bool) {
        promoting = entry.id
        queue.async { [weak self] in
            let failure = Self.runPromotion(entry, removeOriginal: removeOriginal)
            DispatchQueue.main.async {
                guard let self else { return }
                self.promoting = nil
                AssistantDiag.log("mcp promote name=\(entry.name) remove=\(removeOriginal) ok=\(failure == nil)")
                if let failure {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = L("mcp.promote.failed", entry.name)
                    alert.informativeText = failure
                    alert.addButton(withTitle: L("action.ok"))
                    alert.runModal()
                }
                self.refresh()
            }
        }
    }

    /// 只在后台队列调用；返回失败原因（nil 为成功）。
    private static func runPromotion(_ entry: MCPServerEntry, removeOriginal: Bool) -> String? {
        guard let exe = AssistantClient.shared.resolvedClaude() else { return L("mcp.check.noClaude") }
        guard let config = MCPPromotion.rawConfig(for: entry),
              let addArgs = MCPPromotion.addArguments(name: entry.name, config: config) else {
            return L("mcp.promote.notFound")
        }
        var env = LaunchSpec.sanitizedEnvironment(base: ProcessInfo.processInfo.environment)
        if let path = exe.searchPath { env["PATH"] = path }
        func run(_ args: [String], cwd: String) -> String? {
            switch ProcessRunner.capture(exe.path, args, environment: env, cwd: URL(fileURLWithPath: cwd), timeout: 30,
                                         maxOutputBytes: 64 * 1024) {
            case .exited(let out) where out.status == 0: return nil
            // 只给出 claude 的报错第一行（不含我们传进去的配置）。
            case .exited(let out):
                let line = (out.stderr + "\n" + out.stdout).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                return String(line.prefix(200))
            case .failed(let message): return message
            case .timedOut: return L("mcp.check.timeout")
            }
        }
        if let failure = run(addArgs, cwd: NSHomeDirectory()) { return failure }
        if removeOriginal, case .claudeLocal(let project) = entry.source {
            if let failure = run(MCPPromotion.removeArguments(name: entry.name), cwd: project) {
                return L("mcp.promote.removeFailed", failure)
            }
        }
        return nil
    }
}
