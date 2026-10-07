import Foundation

/// 语音模型（Whisper、自然语音）的下载源（设计 §29）：Hugging Face 官方或国内镜像 hf-mirror.com。
/// 「自动」先试官方，连不上再试镜像；都连不上时下载前就提醒检查网络 / 代理，而不是下到一半报一串英文错误。
public enum ModelHubSource: String, CaseIterable, Sendable {
    case auto, official, mirror

    public static let defaultsKey = "modelHubSource"

    public static var stored: ModelHubSource {
        ModelHubSource(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .auto
    }
}

public enum ModelHub {
    public static let official = "https://huggingface.co"
    public static let mirror = "https://hf-mirror.com"
    /// 用镜像下载模型时，自然语音的 Python 依赖也走国内源（同样的网络环境下 PyPI / GitHub 多半也慢或不通）。
    public static let pypiMirror = "https://pypi.tuna.tsinghua.edu.cn/simple"
    public static let pythonMirror = "https://registry.npmmirror.com/-/binary/python-build-standalone"

    /// 按设置与连通性选下载地址；nil 表示要用的地址都连不上。probe 只在需要时调用（自动模式下官方通了就不试镜像）。
    public static func choose(source: ModelHubSource, reachable probe: (String) -> Bool) -> String? {
        switch source {
        case .official: return probe(official) ? official : nil
        case .mirror: return probe(mirror) ? mirror : nil
        case .auto:
            if probe(official) { return official }
            return probe(mirror) ? mirror : nil
        }
    }

    /// 下载用的环境变量：huggingface_hub / WhisperKit 都认 `HF_ENDPOINT`；走镜像时 uv 也换国内源。
    public static func environment(endpoint: String) -> [String: String] {
        var env = ["HF_ENDPOINT": endpoint]
        if endpoint == mirror {
            env["UV_DEFAULT_INDEX"] = pypiMirror
            env["UV_PYTHON_INSTALL_MIRROR"] = pythonMirror
        }
        return env
    }

    /// 连通性检查用的地址（一个很小的模型信息接口）。
    public static func probeURL(_ endpoint: String) -> URL? {
        URL(string: endpoint + "/api/models/argmaxinc/whisperkit-coreml")
    }
}

/// 本机能不能用某项语音功能（设计 §29）：不能用时给出原因，界面上提前提醒，而不是安装 / 下载到一半才失败。
public enum VoiceSupport {
    public enum Problem: Error, Equatable, Sendable {
        /// 自然语音（MLX）只支持 Apple 芯片。
        case naturalVoiceNeedsAppleSilicon
        /// 自然语音的安装需要 uv。
        case naturalVoiceNeedsUV
        /// 下载源都连不上。
        case hubUnreachable(ModelHubSource)

        public var message: String {
            switch self {
            case .naturalVoiceNeedsAppleSilicon: return L("support.natural.appleSilicon")
            case .naturalVoiceNeedsUV: return L("support.natural.uv")
            case .hubUnreachable(.mirror): return L("support.hub.mirrorUnreachable")
            case .hubUnreachable(.official): return L("support.hub.officialUnreachable")
            case .hubUnreachable(.auto): return L("support.hub.unreachable")
            }
        }
    }

    /// 自然语音装之前的本机检查（不含网络）：先看芯片，再看 uv。
    public static func naturalVoiceProblem(appleSilicon: Bool, hasUV: Bool) -> Problem? {
        if !appleSilicon { return .naturalVoiceNeedsAppleSilicon }
        if !hasUV { return .naturalVoiceNeedsUV }
        return nil
    }

    /// 安装 uv 的命令（提醒里可以一键复制）。
    public static let uvInstallCommand = "curl -LsSf https://astral.sh/uv/install.sh | sh"
}
