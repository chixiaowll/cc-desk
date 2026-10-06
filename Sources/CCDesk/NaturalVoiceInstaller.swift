import AppKit
import CCDeskCore

/// 在本机安装自然语音（菜单「朗读声音 → 自然语音」第一次选择时）：
/// 1. 在登录 shell 里找 uv（与解析 claude 的方式相同）；
/// 2. `uv venv -p 3.12` 建虚拟环境，`uv pip install` 固定版本的 mlx-audio；
/// 3. 用打包的 tts_server.py `--download` 下载模型（约 1.9 GB，加上依赖共约 2.5 GB）；
/// 4. 写安装完成标记。
/// 进度用提示条显示；任何一步失败都保持系统声音并提示原因。
final class NaturalVoiceInstaller: ObservableObject, @unchecked Sendable {
    static let shared = NaturalVoiceInstaller()

    @Published private(set) var installing = false

    private let queue = DispatchQueue(label: "cc-desk.tts.install")

    /// 询问后安装；hint：显示提示条；completion(true)：已装好。
    func confirmAndInstall(hint: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) {
        guard !installing else { return hint(L("naturalVoice.hint.installing")) }
        let alert = NSAlert()
        alert.messageText = L("naturalVoice.install.title")
        alert.informativeText = L("naturalVoice.install.message")
        alert.addButton(withTitle: L("naturalVoice.install.confirm"))
        alert.addButton(withTitle: L("action.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return completion(false) }
        install(hint: hint, completion: completion)
    }

    /// 当前步骤的提示（安装期间每 2 秒刷新一次提示条，免得 2 秒后消失）。
    private enum Step {
        case python, packages, download
    }

    private let lock = NSLock()
    private var step: Step = .python

    private func setStep(_ value: Step) {
        lock.lock()
        step = value
        lock.unlock()
    }

    private func status() -> String {
        lock.lock()
        let value = step
        lock.unlock()
        switch value {
        case .python: return L("naturalVoice.hint.step.python")
        case .packages: return L("naturalVoice.hint.step.packages")
        case .download:
            // 大文件可能先落在 HF_HOME 的分块缓存里再拼到模型目录，两处一起算。
            let bytes = Self.directorySize(NaturalVoice.modelDir) + Self.directorySize(NaturalVoice.hfHome)
            let percent = min(99, Int(bytes * 100 / NaturalVoice.modelBytes))
            return L("naturalVoice.hint.downloading", percent)
        }
    }

    private func install(hint: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) {
        installing = true
        setStep(.python)
        hint(status())
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            hint(self.status())
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        queue.async { [self] in
            let result = runSteps()
            DispatchQueue.main.async { [self] in
                timer.invalidate()
                installing = false
                switch result {
                case .success:
                    AssistantDiag.log("natural voice installed")
                    hint(L("naturalVoice.hint.ready"))
                    completion(true)
                case .failure(let message):
                    AssistantDiag.log("natural voice install failed: \(message)")
                    hint(L("naturalVoice.hint.failed", message))
                    completion(false)
                }
            }
        }
    }

    private enum StepResult {
        case success
        case failure(String)
    }

    /// 只在 queue 上调用。
    private func runSteps() -> StepResult {
        guard let script = NaturalVoice.serverScript else { return .failure("tts_server.py missing") }
        guard let uv = Self.locateUV() else { return .failure(L("naturalVoice.error.noUV")) }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: NaturalVoice.hfHome, withIntermediateDirectories: true)
        } catch {
            return .failure(error.localizedDescription)
        }
        try? fm.removeItem(at: NaturalVoice.marker)
        var env = ProcessInfo.processInfo.environment
        env["VIRTUAL_ENV"] = NaturalVoice.venv.path
        env.removeValue(forKey: "PYTHONPATH")
        env.removeValue(forKey: "PYTHONHOME")

        if !fm.isExecutableFile(atPath: NaturalVoice.python.path) {
            if case .failure(let message) = run(uv, ["venv", "-p", "3.12", NaturalVoice.venv.path], env: env, timeout: 600) {
                return .failure(message)
            }
        }
        setStep(.packages)
        let install = ["pip", "install", "--python", NaturalVoice.python.path] + NaturalVoice.packages
        if case .failure(let message) = run(uv, install, env: env, timeout: 1800) { return .failure(message) }

        setStep(.download)
        var downloadEnv = NaturalVoice.serverEnvironment()
        downloadEnv.removeValue(forKey: "HF_HUB_OFFLINE")
        let download = [script.path, "--download", NaturalVoice.modelDir.path]
        if case .failure(let message) = run(NaturalVoice.python.path, download, env: downloadEnv, timeout: 3 * 3600) {
            return .failure(message)
        }
        // 下载用的分块缓存不再需要。
        try? fm.removeItem(at: NaturalVoice.hfHome.appendingPathComponent("xet"))
        do {
            try NaturalVoice.writeMarker()
        } catch {
            return .failure(error.localizedDescription)
        }
        return NaturalVoice.isInstalled ? .success : .failure("incomplete install")
    }

    private func run(_ exe: String, _ args: [String], env: [String: String], timeout: TimeInterval) -> StepResult {
        switch ProcessRunner.run(exe, args, environment: env, cwd: NaturalVoice.root, timeout: timeout) {
        case .finished: return .success
        case .failed(let message): return .failure(String(message.suffix(160)))
        case .timedOut: return .failure(L("naturalVoice.error.timeout"))
        }
    }

    /// 在登录交互 shell 里 `command -v uv`，退到常见安装位置。
    static func locateUV() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let script = "printf '__CCDESK_UV__%s\\n' \"$(command -v uv)\""
        var found: String?
        if case .finished(let out) = ProcessRunner.run(shell, ["-l", "-i", "-c", script], environment: nil, cwd: nil,
                                                       timeout: 6) {
            for line in out.split(whereSeparator: \.isNewline) where line.hasPrefix("__CCDESK_UV__") {
                found = String(line.dropFirst("__CCDESK_UV__".count))
            }
        }
        let home = NSHomeDirectory()
        var candidates = [found ?? "", "\(home)/.local/bin/uv", "\(home)/.cargo/bin/uv", "/opt/homebrew/bin/uv",
                          "/usr/local/bin/uv"]
        let frameworks = "/Library/Frameworks/Python.framework/Versions"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: frameworks) {
            candidates += versions.sorted().reversed().map { "\(frameworks)/\($0)/bin/uv" }
        }
        return candidates.first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
