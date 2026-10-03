import AppKit
import Carbon
import CCDeskCore

/// 全局快捷键（设计 §15）：用 Carbon `RegisterEventHotKey` 注册，CC Desk 不在最前时也能响应，不需要辅助功能权限。
/// 组合定义在 CCDeskCore 的 `GlobalHotkey.defaults`。被其他 App / 系统占用时注册失败，记在 `unavailable` 里供菜单提示。
/// 「按住右 ⌥ 说话」在 App 外需要事件监听（辅助功能 / 输入监控权限），这里不做；App 外用 ⌃⌥V 开关对话模式。
/// 只在主线程使用。
final class GlobalHotkeyCenter: ObservableObject {
    static let shared = GlobalHotkeyCenter()

    /// 注册失败（已被占用）的组合。
    @Published private(set) var unavailable: [GlobalHotkey] = []
    /// 当前已注册成功的组合。
    @Published private(set) var registered: [GlobalHotkey] = []

    var onAction: ((GlobalHotkey.Action) -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    /// EventHotKeyID.signature：'CCDk'。
    private static let signature: OSType = 0x4343_446B

    /// 按开关注册或注销全部快捷键；返回本次注册失败的组合。
    @discardableResult
    func apply(enabled: Bool, hotkeys: [GlobalHotkey] = GlobalHotkey.defaults) -> [GlobalHotkey] {
        unregisterAll()
        guard enabled else {
            unavailable = []
            registered = []
            return []
        }
        installHandlerIfNeeded()
        var failed: [GlobalHotkey] = []
        var ok: [GlobalHotkey] = []
        for hotkey in hotkeys {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: hotkey.action.hotkeyID)
            let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                ok.append(hotkey)
            } else {
                NSLog("CC Desk: global hotkey %@ unavailable (OSStatus %d)", hotkey.displayString, status)
                failed.append(hotkey)
            }
        }
        registered = ok
        unavailable = failed
        return failed
    }

    /// 某个动作当前生效的组合（已注册成功）；没有时为 nil。
    func activeHotkey(for action: GlobalHotkey.Action) -> GlobalHotkey? {
        registered.first { $0.action == action }
    }

    private func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard result == noErr, hotKeyID.signature == GlobalHotkeyCenter.signature,
                  let action = GlobalHotkey.Action(hotkeyID: hotKeyID.id) else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<GlobalHotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            // 处理器在主线程的事件分发里被调用；异步执行，避免在 Carbon 回调里弹窗 / 切换窗口。
            DispatchQueue.main.async { center.onAction?(action) }
            return noErr
        }, 1, &eventType, userData, &handlerRef)
        if status != noErr { NSLog("CC Desk: InstallEventHandler failed (OSStatus %d)", status) }
    }

    /// 注册失败时的提示（用户主动开启全局快捷键时调用）。
    func alertUnavailable(_ hotkeys: [GlobalHotkey]) {
        guard !hotkeys.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L("alert.hotkeyUnavailable.title")
        alert.informativeText = L("alert.hotkeyUnavailable.message",
                                  hotkeys.map(\.displayString).joined(separator: L("hotkey.listSeparator")))
        alert.runModal()
    }
}
