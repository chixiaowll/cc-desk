import Foundation
import CCDeskCore

/// 自然语音（Qwen3-TTS 0.6B 8bit，说话人 serena，经 mlx-audio 在本机合成）的安装位置与选择状态。
///
/// 安装在 `~/Library/Application Support/CC Desk/tts/`：
/// - `venv/`：uv 建的 Python 3.12 虚拟环境（mlx-audio 固定版本）；
/// - `hf/<模型名>/`：模型文件（约 1.9 GB），`hf/cache/` 作 HF_HOME；
/// - `installed.json`：安装完成标记（没有它就算没装好）；`server.log`：服务的 stderr。
enum NaturalVoice {
    static let modelName = "Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"
    static let packages = ["mlx-audio==0.5.7", "mlx==0.32.3"]
    /// 模型文件的大致总字节数（下载进度用）。
    static let modelBytes: Int64 = 1_973_572_801

    static var root: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("CC Desk/tts", isDirectory: true)
    }

    static var venv: URL { root.appendingPathComponent("venv", isDirectory: true) }
    static var python: URL { venv.appendingPathComponent("bin/python") }
    static var hfHome: URL { root.appendingPathComponent("hf/cache", isDirectory: true) }
    static var modelDir: URL { root.appendingPathComponent("hf/\(modelName)", isDirectory: true) }
    static var marker: URL { root.appendingPathComponent("installed.json") }
    static var logURL: URL { root.appendingPathComponent("server.log") }

    /// 打包在 App 资源里的服务脚本。
    static var serverScript: URL? {
        Localization.resourceBundle(named: "CCDesk_CCDesk")?.url(forResource: "tts_server", withExtension: "py")
    }

    static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: marker.path)
            && fm.isExecutableFile(atPath: python.path)
            && fm.fileExists(atPath: modelDir.appendingPathComponent("model.safetensors").path)
            && fm.fileExists(atPath: modelDir.appendingPathComponent("speech_tokenizer/model.safetensors").path)
    }

    /// 测试用：强制选中 / 不选自然语音（nil = 按偏好）。
    nonisolated(unsafe) static var selectionOverride: Bool?

    /// 朗读是否用自然语音：菜单里选了它；或从没选过声音且已安装（装好即默认）。
    static var isSelected: Bool {
        if let selectionOverride { return selectionOverride }
        guard isInstalled else { return false }
        guard let stored = UserDefaults.standard.string(forKey: SpeechVoiceRanking.defaultsKey) else { return true }
        return stored == NaturalVoiceProtocol.preferenceID
    }

    /// 服务进程的环境：离线使用本地模型，缓存放在安装目录里。
    static func serverEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HF_HOME"] = hfHome.path
        env["HF_HUB_OFFLINE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env.removeValue(forKey: "VIRTUAL_ENV")
        env.removeValue(forKey: "PYTHONPATH")
        env.removeValue(forKey: "PYTHONHOME")
        return env
    }

    /// 写安装完成标记。
    static func writeMarker() throws {
        let info: [String: Any] = ["model": modelName, "packages": packages,
                                   "installedAt": ISO8601DateFormatter().string(from: Date())]
        let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: marker, options: .atomic)
    }
}
