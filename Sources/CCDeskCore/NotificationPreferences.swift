import Foundation

/// 系统通知按事件开关（设置 › 通知）。两项默认都开，与加入设置之前的行为一致。
/// 只影响要不要弹系统通知；未读标记、角标照常更新。
public enum NotificationPreferences {
    public static let waitingKey = "notifyOnWaiting"
    public static let finishedKey = "notifyOnFinished"

    public static func key(for kind: StatusEvent.Kind) -> String {
        switch kind {
        case .needsInput: return waitingKey
        case .finished: return finishedKey
        }
    }

    public static func allows(_ kind: StatusEvent.Kind, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key(for: kind)) as? Bool ?? true
    }
}
