import AppKit
import CCDeskCore

/// `open_file`（设计 §17）：找会话里 agent 最近写的文档（可按名字筛选），用快速查看或默认 App 打开。
extension AssistantToolbox {
    func openFile(_ args: ToolArgs, _ done: @escaping Completion) {
        guard let model else { return done(Self.shuttingDown) }
        switch resolve(args.string("session")) {
        case .failure(let error): done(.failure(error))
        case .success(let target):
            show(L("assistant.activity.openFile", target.name))
            let query = args.string("query")
            let inApp = args.bool("app") ?? false
            model.touchedFiles.files(for: target.row) { files in
                guard let files else {
                    return done(Self.failure("No transcript found for \(target.info.shortID)"))
                }
                guard let file = TouchedFilesModel.latestFile(in: files, matching: query) else {
                    let what = query.map { "matching \"\($0)\" " } ?? ""
                    return done(Self.failure("\(target.info.shortID) has not written any existing file \(what)yet"))
                }
                if inApp {
                    FileActions.open(file.path)
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                    model.touchedFiles.quickLook(path: file.path, window: nil)
                }
                let relative = file.relativePath(root: model.projectRoot(forCwd: target.row.session.cwd))
                done(Self.text("opened \(relative) (\(file.isDocument ? "document" : "file"), \(file.action.rawValue)) " +
                               (inApp ? "in its default app" : "in Quick Look")))
            }
        }
    }
}
