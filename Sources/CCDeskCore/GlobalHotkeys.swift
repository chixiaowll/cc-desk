import Foundation

/// 全局快捷键（设计 §15）：CC Desk 不在最前时也能响应。按键组合集中定义在这里，以后做成可配置只需改这一处。
/// 修饰键用 Carbon `RegisterEventHotKey` 的掩码值（cmdKey / shiftKey / optionKey / controlKey），
/// 键码用 Carbon 虚拟键码（kVK_*），App 层直接传给 Carbon，不需要在 Core 里引入 Carbon。
public struct GlobalHotkey: Equatable, Sendable, Identifiable {
    public enum Action: String, CaseIterable, Sendable {
        /// 把主窗口拿到最前；已经在最前时隐藏 App。
        case toggleMainWindow
        /// 开关对话模式（免按键语音）。
        case toggleConversation

        /// 注册时用的数字 id（EventHotKeyID.id），从 1 开始且稳定。
        public var hotkeyID: UInt32 {
            switch self {
            case .toggleMainWindow: return 1
            case .toggleConversation: return 2
            }
        }

        public init?(hotkeyID: UInt32) {
            guard let action = Action.allCases.first(where: { $0.hotkeyID == hotkeyID }) else { return nil }
            self = action
        }
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        // 与 Carbon Events.h 中的值一致。
        public static let command = Modifiers(rawValue: 1 << 8)
        public static let shift = Modifiers(rawValue: 1 << 9)
        public static let option = Modifiers(rawValue: 1 << 11)
        public static let control = Modifiers(rawValue: 1 << 12)
    }

    public let action: Action
    /// Carbon 虚拟键码（kVK_ANSI_C = 8 …）。
    public let keyCode: UInt32
    public let modifiers: Modifiers
    /// 键帽上的字符（显示用，如 "C"、"Space"）。
    public let key: String

    public var id: String { action.rawValue }

    public init(action: Action, keyCode: UInt32, modifiers: Modifiers, key: String) {
        self.action = action
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// 传给 RegisterEventHotKey 的修饰键掩码。
    public var carbonModifiers: UInt32 { modifiers.rawValue }

    /// 按 macOS 惯例的顺序显示：⌃⌥⇧⌘ + 键，如 "⌃⌥C"。
    public var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key
    }

    /// 默认组合。选择理由（设计 §15）：
    /// - ⌃Space / ⌃⌥Space 是系统切换输入法（上一个 / 下一个输入源），⌘Space 是 Spotlight，⌥Space 是 Claude 桌面版
    ///   等常见 App 的快捷输入，⌃⌘Space 是表情与符号；所以不用 Space。
    /// - ⌃⌥C（CC Desk 的 C）与 ⌃⌥V（对应 App 内的 ⌥⌘V 对话模式）不是 macOS 默认快捷键，也不与输入法冲突。
    public static let defaults: [GlobalHotkey] = [
        GlobalHotkey(action: .toggleMainWindow, keyCode: 8, modifiers: [.control, .option], key: "C"),
        GlobalHotkey(action: .toggleConversation, keyCode: 9, modifiers: [.control, .option], key: "V"),
    ]

    public static func `default`(for action: Action) -> GlobalHotkey? {
        defaults.first { $0.action == action }
    }
}
