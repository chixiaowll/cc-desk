import AVFoundation
import CCDeskCore

/// 持续录音：AVAudioEngine 输入 -> 16 kHz 单声道块，交给回调（音频线程），不在内存里累积。
/// start / stop 在专用串行队列上执行，不阻塞主线程。
/// 输入设备变化（插拔 AirPods、换默认麦克风）时 AVAudioEngine 会停下并发出 configuration change：
/// 这时按新设备的格式重建引擎和 tap；重试几次仍失败就调用 onLost（对话模式随之关闭并提示）。
final class ContinuousRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cc-desk.conversation.audio")
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var onSamples: (([Float]) -> Void)?
    private var onLost: (() -> Void)?
    /// 每次 start / stop 加一；迟到的重建据此丢弃。
    private var epoch = 0

    /// completion(false)：没有可用的输入设备或无法启动。onLost：运行中设备变化后无法恢复。
    func start(onSamples: @escaping ([Float]) -> Void, onLost: @escaping () -> Void, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            stopEngine()
            epoch += 1
            self.onSamples = onSamples
            self.onLost = onLost
            completion(startEngine())
        }
    }

    func stop() {
        queue.async { [self] in
            epoch += 1
            stopEngine()
            onSamples = nil
            onLost = nil
        }
    }

    // MARK: 只在 queue 上调用

    private func startEngine() -> Bool {
        guard let onSamples else { return false }
        let engine = AVAudioEngine()
        guard MicrophoneTap.install(on: engine, handler: { chunk in onSamples(Array(chunk)) }) else { return false }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            return false
        }
        self.engine = engine
        let current = epoch
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { [weak self] _ in
            self?.queue.async { self?.rebuild(epoch: current, attempt: 0) }
        }
        return true
    }

    private func rebuild(epoch current: Int, attempt: Int) {
        guard current == epoch, onSamples != nil else { return }
        AssistantDiag.log("conversation: audio configuration changed, rebuilding the input engine (attempt \(attempt + 1))")
        stopEngine()
        if startEngine() { return }
        // 换设备的瞬间输入格式可能是 0 Hz：稍等再试。
        guard attempt < 4 else {
            AssistantDiag.log("conversation: no usable input after the configuration change")
            onLost?()
            return
        }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.rebuild(epoch: current, attempt: attempt + 1) }
    }

    private func stopEngine() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }
}
