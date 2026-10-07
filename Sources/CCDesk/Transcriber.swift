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
    /// 16 kHz 单声道 Float32 采样 -> 清理后的文本。hint：追加到 Whisper 提示词里的词汇（如唤醒词），提高识别率。
    func transcribe(_ samples: [Float], hint: String?) async throws -> String
    /// 对话模式开着时传 true：模型常驻，不做空闲卸载。
    func setKeepLoaded(_ keep: Bool) async
}

extension Transcriber {
    func transcribe(_ samples: [Float]) async throws -> String {
        try await transcribe(samples, hint: nil)
    }

    func setKeepLoaded(_ keep: Bool) async {}
}

extension Notification.Name {
    /// 语音模型因空闲被卸载（主线程发出）；下次使用需要重新加载。
    static let transcriberDidUnload = Notification.Name("CCDeskTranscriberDidUnload")
}

/// 本机 Whisper（WhisperKit / CoreML）。模型首次使用时下载到
/// ~/Library/Application Support/CC Desk/models；加载后在使用期间常驻内存，
/// 不用语音约 10 分钟后卸载（对话模式开着时不卸载，`ModelIdlePolicy`，设计 §26.4），下次使用时重新加载。
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
    /// 对话模式开着：不卸载。
    private var keepLoaded = false
    /// 最近一次使用（单调时钟）。
    private var lastUsed = ProcessInfo.processInfo.systemUptime
    /// 正在进行的识别数。
    private var busy = 0
    private var idleTask: Task<Void, Never>?

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
    nonisolated var modelFolder: URL {
        baseDir.appendingPathComponent("models").appendingPathComponent(Self.repo).appendingPathComponent(model)
    }

    nonisolated var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent(Self.completeMarker).path)
    }

    var isLoaded: Bool { kit != nil }

    func prepare(progress: @escaping @Sendable (TranscriberProgress) -> Void) async throws {
        touch()
        _ = try await loadedKit(progress: progress)
        touch()
    }

    func setKeepLoaded(_ keep: Bool) {
        keepLoaded = keep
        touch()
    }

    func transcribe(_ samples: [Float], hint: String?) async throws -> String {
        busy += 1
        touch()
        defer {
            busy -= 1
            touch()
        }
        let kit = try await loadedKit(progress: { _ in })
        var options = DecodingOptions(
            task: .transcribe, language: "zh", temperature: 0, usePrefillPrompt: true, detectLanguage: false,
            skipSpecialTokens: true, withoutTimestamps: true, chunkingStrategy: .vad)
        if let tokenizer = kit.tokenizer {
            options.promptTokens = tokenizer.encode(text: " " + Self.initialPrompt + (hint ?? ""))
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
                // 先选下载源（官方连不上时用镜像），都连不上就直接说明，不下到一半才报错。
                let endpoint: String
                switch ModelHubProbe.resolve() {
                case .success(let value): endpoint = value
                case .failure(let problem): throw VoiceSupportError(problem: problem)
                }
                // 分词器在加载时由 WhisperKit 另行下载，它只认环境变量 HF_ENDPOINT。
                setenv("HF_ENDPOINT", endpoint, 1)
                folder = try await WhisperKit.download(variant: model, downloadBase: baseDir, from: Self.repo,
                                                       endpoint: endpoint) { p in
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

    // MARK: 空闲卸载

    private func touch() {
        lastUsed = ProcessInfo.processInfo.systemUptime
        if idleTask == nil, kit != nil || preparing != nil {
            idleTask = Task { [weak self] in await self?.idleLoop() }
        }
    }

    /// 模型在内存里时每到空闲满 10 分钟检查一次（一次唤醒 / 10 分钟）；满足条件就卸载并结束。
    private func idleLoop() async {
        while kit != nil || preparing != nil {
            let idle = ProcessInfo.processInfo.systemUptime - lastUsed
            if ModelIdlePolicy.shouldUnload(idleFor: idle, keepLoaded: keepLoaded, busy: busy > 0 || preparing != nil) {
                await unload()
                break
            }
            let wait = ModelIdlePolicy.nextCheck(idleFor: idle)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        idleTask = nil
    }

    /// 卸载模型，释放内存；之后的 prepare / transcribe 会重新加载。
    func unload() async {
        guard let loaded = kit else { return }
        kit = nil
        await loaded.unloadModels()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .transcriberDidUnload, object: nil) }
    }
}
