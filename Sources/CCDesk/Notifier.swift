import Foundation
import AppKit
import UserNotifications
import CCDeskCore

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?
    /// 等批准通知上的按钮：(会话 key, 发通知时的等待原因, true = 批准 / false = 拒绝)，在主线程回调。
    var onApproval: ((String, String?, Bool) -> Void)?
    /// 内嵌会话等批准通知的类别（带「批准 / 拒绝」按钮）；外部终端的通知不设类别，没有按钮。
    static let approvalCategory = "approval"
    static let approveAction = "approve"
    static let denyAction = "deny"
    /// `swift run` 直接运行时没有 bundle，UNUserNotificationCenter 会崩溃，此时禁用通知。
    private let available = Bundle.main.bundleIdentifier != nil

    func setup() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // 按钮不带 .foreground：点击后不激活 App、不把窗口带到前台；拒绝用破坏性样式。
        let approve = UNNotificationAction(identifier: Self.approveAction, title: L("notify.action.approve"), options: [])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: L("notify.action.deny"), options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.approvalCategory, actions: [approve, deny], intentIdentifiers: [], options: [])
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            center.getNotificationSettings { st in
                let line = "auth=\(st.authorizationStatus.rawValue) alert=\(st.alertSetting.rawValue) badge=\(st.badgeSetting.rawValue) sound=\(st.soundSetting.rawValue)\n"
                let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cc-desk/notify-diag.txt")
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// 同时通过 NSDockTile 和 UserNotifications 设置角标（后者受系统「标记」设置控制）。
    func setBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        guard available else { return }
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
    }

    func post(_ event: StatusEvent) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = .default
        var info: [String: Any] = ["sessionKey": event.sessionKey]
        if event.kind == .needsInput, event.actionable {
            content.categoryIdentifier = Self.approvalCategory
            if let reason = event.reason { info["reason"] = reason }
        }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// 简短提示（如通知按钮未执行的原因）；sessionKey 非 nil 时点击打开对应会话。
    func postNotice(title: String, body: String, sessionKey: String?) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let sessionKey { content.userInfo = ["sessionKey": sessionKey] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// 移除某个会话已送达的等批准通知（已在通知上处理过，旧的那几条不再有意义）。
    func removeDelivered(sessionKey: String) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered.filter {
                $0.request.content.categoryIdentifier == Self.approvalCategory
                    && $0.request.content.userInfo["sessionKey"] as? String == sessionKey
            }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// Claude 用量提醒（无对应会话，点击只激活 App）。
    func post(_ alert: UsageAlert) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "usage-\(alert.limitID)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// 系统通知权限（设置 › 通知显示）。
    enum Authorization {
        case allowed, denied, notDetermined, unavailable
    }

    static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")

    /// 查询通知权限，在主线程回调。
    func authorization(completion: @escaping (Authorization) -> Void) {
        guard available else { return completion(.unavailable) }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let state: Authorization
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: state = .allowed
            case .denied: state = .denied
            case .notDetermined: state = .notDetermined
            @unknown default: state = .denied
            }
            DispatchQueue.main.async { completion(state) }
        }
    }

    /// 发一条测试通知；若通知权限被关闭，回调 false 以便提示用户去系统设置打开。
    func sendTest(completion: @escaping (Bool) -> Void) {
        guard available else { completion(false); return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            if allowed {
                let content = UNMutableNotificationContent()
                content.title = L("notify.test.title")
                content.body = L("notify.test.body")
                content.sound = .default
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
            DispatchQueue.main.async { completion(allowed) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        guard let key = info["sessionKey"] as? String else { return completionHandler() }
        let reason = info["reason"] as? String
        switch response.actionIdentifier {
        case Self.approveAction, Self.denyAction:
            let approve = response.actionIdentifier == Self.approveAction
            DispatchQueue.main.async { self.onApproval?(key, reason, approve) }
        case UNNotificationDefaultActionIdentifier:
            DispatchQueue.main.async { self.onOpen?(key) }
        default:
            break
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
