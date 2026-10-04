import AppKit
import AVFoundation
import CCDeskCore

/// 识别：音频块进 VAD（audioQueue），切出的一句话排队交给 Whisper，识别结果交给状态机。
extension ConversationMode {
    func feed(_ chunk: [Float], generation current: Int) {
        guard !paused else { return }
        let level = chunk.withUnsafeBufferPointer(MicrophoneTap.level(of:))
        levelLock.lock()
        currentLevel = currentLevel * 0.4 + level * 0.6
        levelLock.unlock()
        for event in vad.process(chunk) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isOn, self.generation == current else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: VoiceActivityDetector.Event) {
        switch event {
        case .speechStarted:
            capturing = true
            session.noteSpeech(now: ProcessInfo.processInfo.systemUptime)
        case .discarded:
            capturing = false
        case .utterance(let samples):
            capturing = false
            let now = ProcessInfo.processInfo.systemUptime
            session.noteSpeech(now: now)
            let startedAt = now - Double(samples.count) / Double(MicrophoneTap.sampleRate)
            // 助手常驻：没选中内嵌会话时也照常识别（列会话 / 切换 / 新建不需要目标终端）。
            queue.append((samples, selectedTerminalID(), startedAt))
            transcribeNext()
        }
    }

    func transcribeNext() {
        // 等助手时先不处理后面的话，保证插入顺序；助手在等语音确认时例外。
        guard !transcribing, !thinking || pendingConfirmation != nil, !queue.isEmpty else { return }
        let (samples, target, startedAt) = queue.removeFirst()
        let duration = Double(samples.count) / Double(MicrophoneTap.sampleRate)
        let policy = session.transcriptionPolicy(duration: duration)
        let matcher = session.matcher
        let hint = transcriptionHint
        let current = generation
        transcribing = true
        Task { @MainActor [weak self, transcriber] in
            var text: String?
            do {
                if case .prefixThenFull(let seconds) = policy {
                    // 待命时的长片段：先只识别开头检查唤醒词，没有就不必识别整段。
                    let prefix = Array(samples.prefix(Int(seconds * Double(MicrophoneTap.sampleRate))))
                    let head = try await transcriber.transcribe(prefix, hint: hint)
                    if matcher.match(head) != nil { text = try await transcriber.transcribe(samples, hint: hint) }
                } else {
                    text = try await transcriber.transcribe(samples, hint: hint)
                }
            } catch {
                text = nil
            }
            guard let self, self.isOn, self.generation == current else { return }
            self.transcribing = false
            if let text, !text.isEmpty { self.apply(text, target: target, startedAt: startedAt) }
            self.transcribeNext()
        }
    }

    private func apply(_ text: String, target: UUID?, startedAt: TimeInterval) {
        if pendingConfirmation != nil {
            // 问题播报完之前就开始说的话（已在排队 / 识别中）不能当作回答。
            guard startedAt >= confirmationListenAfter else {
                AssistantDiag.log("ignored \"\(text)\" (spoken before the confirmation question finished)")
                return
            }
            return answerConfirmation(text)
        }
        let now = ProcessInfo.processInfo.systemUptime
        utteranceStartedAt = startedAt
        let waiting = target.flatMap(statusOf)?.isWaiting ?? false
        // 选中的会话没在等批准、但刚播报过某个后台会话要批准：「批准 / 拒绝」作用于那个会话。
        // 播报之前就开始说的话不算对它的回答。
        let announced = waiting ? nil : announcedApproval.flatMap { $0.isFresh(now: now) && startedAt >= $0.at ? $0 : nil }
        session.persistent = Self.persistentEnabled
        let before = session.state
        let actions = session.handle(transcript: text, waiting: waiting || announced != nil, now: now)
        AssistantDiag.log("heard \"\(text)\" state=\(before) assistant=\(session.routesToAssistant) -> \(actions)" +
                          (announced.map { " announced=\($0.rowID)" } ?? ""))
        for action in actions {
            if let announced, action == .approve || action == .deny {
                respondAnnounced(announced, approve: action == .approve)
                continue
            }
            perform(action, target: target)
        }
        // 播报后的下一句话不是批准 / 拒绝（说了别的事）：不再把之后的「好的」「可以」当作对那条请求的回答。
        if announced != nil, !actions.isEmpty, !actions.contains(.approve), !actions.contains(.deny) {
            announcedApproval = nil
        }
        state = session.state
    }
}
