import Foundation
import UserNotifications
import CCDeskCore

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?
    /// `swift run` 直接运行时没有 bundle，UNUserNotificationCenter 会崩溃，此时禁用通知。
    private let available = Bundle.main.bundleIdentifier != nil

    func setup() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(_ event: StatusEvent) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = .default
        content.userInfo = ["sessionKey": event.sessionKey]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// 发一条测试通知；若通知权限被关闭，回调 false 以便提示用户去系统设置打开。
    func sendTest(completion: @escaping (Bool) -> Void) {
        guard available else { completion(false); return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            if allowed {
                let content = UNMutableNotificationContent()
                content.title = "CC Desk 通知测试"
                content.body = "会话需要批准或本轮完成时，会像这样提醒你。"
                content.sound = .default
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
            DispatchQueue.main.async { completion(allowed) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let key = response.notification.request.content.userInfo["sessionKey"] as? String {
            DispatchQueue.main.async { self.onOpen?(key) }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
