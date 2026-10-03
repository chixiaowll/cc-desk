import Foundation

/// 设置里唤醒词输入框的校验：去掉首尾空白后 2–8 个字符（中文一字算一个）。
/// 通过时返回要保存的文字；保存在 `ConversationSession.wakeWordDefaultsKey`，下次开启对话模式时生效。
public enum WakeWordRule {
    public static let minLength = 2
    public static let maxLength = 8

    public enum Problem: Error, Equatable, Sendable {
        case empty
        case tooShort
        case tooLong

        public var message: String {
            switch self {
            case .empty: return L("wakeWord.error.empty")
            case .tooShort: return L("wakeWord.error.tooShort", WakeWordRule.minLength)
            case .tooLong: return L("wakeWord.error.tooLong", WakeWordRule.maxLength)
            }
        }
    }

    public static func validate(_ input: String) -> Result<String, Problem> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.empty) }
        if trimmed.count < minLength { return .failure(.tooShort) }
        if trimmed.count > maxLength { return .failure(.tooLong) }
        return .success(trimmed)
    }
}
