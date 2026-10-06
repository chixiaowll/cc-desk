import AppKit
import CCDeskCore

/// 控制接口（助手工具，设计 §13）与切换语言重启时的交接。
extension AppModel {
    /// 启动控制接口。socket 仍被别的进程占着（多半是切换语言重启时还没退出的旧实例）时，每 0.5 秒重试，最多 10 秒。
    func startControlServer(attempt: Int = 0) {
        guard controlServer == nil, !relaunchSuspended else { return }
        let toolbox = self.toolbox
        let server = ControlServer(path: ControlProtocol.socketPath(), token: ControlAuth.token,
                                   log: { AssistantDiag.log($0) }) { request, reply in
            DispatchQueue.main.async { toolbox.handle(request, reply: reply) }
        }
        if server.start() {
            controlServer = server
        } else if attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.startControlServer(attempt: attempt + 1) }
        }
    }

    func stopControlServer() {
        controlServer?.stop()
        controlServer = nil
    }

    /// 切换语言重启前：存好 workspace，停掉轮询（之后不再写 workspace）与控制接口，让新实例接手。
    func suspendForRelaunch() {
        saveWorkspace()
        relaunchSuspended = true
        pacer.stop()
        stopControlServer()
    }

    /// 新实例没能启动：恢复轮询与控制接口。
    func resumeAfterFailedRelaunch() {
        relaunchSuspended = false
        startControlServer()
        pacer.start()
    }
}
