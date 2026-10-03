import Foundation
import WhisperKit
import CCDeskCore

/// 模型准备阶段，供浮层显示。
enum TranscriberProgress: Sendable, Equatable {
    /// 首次使用下载模型，0...1。
    case downloading(Double)
    /// 加载 / 编译 CoreML 模型（首次加载可能需要几十秒）。
    case loading
}

protocol Transcriber: Sendable {
    /// 确保模型已下载并加载到内存；重复调用开销很小。
    func prepare(progress: @escaping @Sendable (TranscriberProgress) -> Void) async throws
    /// 16 kHz 单声道 Float32 采样 -> 清理后的文本。
    func transcribe(_ samples: [Float]) async throws -> String
}

/// 本机 Whisper（WhisperKit / CoreML）。模型首次使用时下载到
/// ~/Library/Application Support/CC Desk/models，加载后常驻内存。
actor WhisperTranscriber: Transcriber {
    static let shared = WhisperTranscriber()

    /// large-v3 turbo 的量化版（约 630MB）；完整版约 1.6GB。
    static let defaultModel = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let repo = "argmaxinc/whisperkit-coreml"
    static let initialPrompt = "以下是普通话，可能夹杂英文技术词汇。"
    private static let completeMarker = ".ccdesk-complete"

    let model: String
    let baseDir: URL
    private var kit: WhisperKit?
    private var preparing: Task<WhisperKit, Error>?

    init(model: String = WhisperTranscriber.defaultModel, baseDir: URL = WhisperTranscriber.defaultBaseDir) {
        self.model = model
        self.baseDir = baseDir
    }

    static var defaultBaseDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("CC Desk/models", isDirectory: true)
    }

    /// WhisperKit / HubApi 的本地布局：<base>/models/<repo>/<variant>
    var modelFolder: URL {
        baseDir.appendingPathComponent("models").appendingPathComponent(Self.repo).appendingPathComponent(model)
    }

    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent(Self.completeMarker).path)
    }

    var isLoaded: Bool { kit != nil }

    func prepare(progress: @escaping @Sendable (TranscriberProgress) -> Void) async throws {
        _ = try await loadedKit(progress: progress)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let kit = try await loadedKit(progress: { _ in })
        var options = DecodingOptions(
            task: .transcribe, language: "zh", temperature: 0, usePrefillPrompt: true, detectLanguage: false,
            skipSpecialTokens: true, withoutTimestamps: true, chunkingStrategy: .vad)
        if let tokenizer = kit.tokenizer {
            options.promptTokens = tokenizer.encode(text: " " + Self.initialPrompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        let raw = results.map(\.text).joined(separator: "\n")
        return TranscriptCleaner.clean(raw)
    }

    private func loadedKit(progress: @escaping @Sendable (TranscriberProgress) -> Void) async throws -> WhisperKit {
        if let kit { return kit }
        if let preparing { return try await preparing.value }
        let task = Task { [model, baseDir, modelFolder, isDownloaded] () throws -> WhisperKit in
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            var folder = modelFolder
            if !isDownloaded {
                progress(.downloading(0))
                folder = try await WhisperKit.download(variant: model, downloadBase: baseDir, from: Self.repo) { p in
                    progress(.downloading(p.fractionCompleted))
                }
                FileManager.default.createFile(atPath: folder.appendingPathComponent(Self.completeMarker).path,
                                               contents: Data())
            }
            progress(.loading)
            let config = WhisperKitConfig(
                model: model, downloadBase: baseDir, modelFolder: folder.path, tokenizerFolder: baseDir,
                verbose: false, logLevel: .error, prewarm: false, load: true, download: false)
            return try await WhisperKit(config)
        }
        preparing = task
        do {
            let kit = try await task.value
            self.kit = kit
            preparing = nil
            return kit
        } catch {
            preparing = nil
            throw error
        }
    }
}
