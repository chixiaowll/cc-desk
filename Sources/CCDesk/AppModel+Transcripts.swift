import AppKit
import CCDeskCore

/// 会话记录：读尾部摘录、定位记录文件、项目根目录。
extension AppModel {
    /// 在后台读某个会话记录的尾部（≤256KB），抽取紧凑的上下文；completion 在主线程（找不到记录时为 nil）。
    /// turns > 0 时只取最近几轮。
    func transcriptDigest(for row: SidebarRow, turns: Int = 0, completion: @escaping (AssistantDigest?) -> Void) {
        guard let sid = row.session.sessionID, row.session.kind.isAgent else { return completion(nil) }
        let kind = row.session.kind
        let title = row.displayName
        let status = row.session.status
        queue.async { [weak self] in
            let url = self?.transcriptURL(kind: kind, sessionID: sid)
            let digest = url.map { url -> String in
                let tail = TranscriptReader.readTail(url, bytes: TurnDigest.tailBytes)
                return turns > 0 ? TurnDigest.digest(kind: kind, tail: tail, turns: turns) : TurnDigest.digest(kind: kind, tail: tail)
            }
            DispatchQueue.main.async {
                completion(digest.map { AssistantDigest(title: title, status: status, digest: $0) })
            }
        }
    }

    /// 会话记录文件：Claude 查 TranscriptIndex，Codex / pi 查 AgentSessionIndex；只在 `queue` 上调用。
    private func transcriptURL(kind: AgentKind, sessionID: String) -> URL? {
        kind == .claude
            ? transcripts.path(forSession: sessionID)
            : agentIndex.locate(kind: kind, sessionID: sessionID).map { URL(fileURLWithPath: $0) }
    }

    /// 在后台定位会话记录文件（找不到时为 nil）；completion 在主线程。
    func locateTranscript(kind: AgentKind, sessionID: String, completion: @escaping (URL?) -> Void) {
        queue.async { [weak self] in
            let url = self?.transcriptURL(kind: kind, sessionID: sessionID)
            DispatchQueue.main.async { completion(url) }
        }
    }

    /// 某个 cwd 所属项目的根目录（最近一次轮询的解析结果；未解析过时为 nil）。
    func projectRoot(forCwd cwd: String) -> String? {
        lastProjects[cwd]?.root
    }
}
