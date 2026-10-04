import XCTest
@testable import CCDeskCore

final class DesktopPresenceTests: XCTestCase {
    private func signals(args: [String] = ["/app/CCDesk"], event: Bool = false, enabled: Bool = false,
                         age: TimeInterval? = nil) -> LoginLaunch.Signals {
        LoginLaunch.Signals(arguments: args, appleEventSaysLoginItem: event, loginItemEnabled: enabled,
                            secondsSinceSessionStart: age)
    }

    func testExplicitArgumentAndAppleEventMeanLoginLaunch() {
        XCTAssertTrue(LoginLaunch.isLoginLaunch(signals(args: ["/app/CCDesk", LoginLaunch.argument])))
        XCTAssertTrue(LoginLaunch.isLoginLaunch(signals(event: true)))
        // argv[0] 不算参数。
        XCTAssertFalse(LoginLaunch.isLoginLaunch(signals(args: [LoginLaunch.argument])))
    }

    func testSessionAgeFallbackRequiresEnabledLoginItem() {
        XCTAssertTrue(LoginLaunch.isLoginLaunch(signals(enabled: true, age: 15)))
        XCTAssertTrue(LoginLaunch.isLoginLaunch(signals(enabled: true, age: LoginLaunch.sessionWindow)))
        XCTAssertFalse(LoginLaunch.isLoginLaunch(signals(enabled: true, age: LoginLaunch.sessionWindow + 1)))
        XCTAssertFalse(LoginLaunch.isLoginLaunch(signals(enabled: false, age: 15)))
        XCTAssertFalse(LoginLaunch.isLoginLaunch(signals(enabled: true, age: nil)))
        XCTAssertFalse(LoginLaunch.isLoginLaunch(signals(enabled: true, age: -5)))
        XCTAssertFalse(LoginLaunch.isLoginLaunch(signals()))
    }

    func testLoginItemStateToggle() {
        XCTAssertTrue(LoginItemState.enabled.isOn)
        XCTAssertTrue(LoginItemState.requiresApproval.isOn)
        XCTAssertFalse(LoginItemState.disabled.isOn)
        XCTAssertFalse(LoginItemState.notFound.isOn)
        XCTAssertEqual(LoginItemState.enabled.toggleAction, .unregister)
        XCTAssertEqual(LoginItemState.requiresApproval.toggleAction, .unregister)
        XCTAssertEqual(LoginItemState.disabled.toggleAction, .register)
        XCTAssertEqual(LoginItemState.notFound.toggleAction, .register)
        XCTAssertTrue(LoginItemState.requiresApproval.needsApprovalHint)
        XCTAssertFalse(LoginItemState.enabled.needsApprovalHint)
    }

    func testSettingsDefaults() throws {
        let suite = "ccdesk.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(DesktopSettings.menuBarIconShown(defaults))
        XCTAssertTrue(DesktopSettings.globalHotkeysEnabled(defaults))
        defaults.set(false, forKey: DesktopSettings.menuBarIconShownKey)
        defaults.set(false, forKey: DesktopSettings.globalHotkeysEnabledKey)
        XCTAssertFalse(DesktopSettings.menuBarIconShown(defaults))
        XCTAssertFalse(DesktopSettings.globalHotkeysEnabled(defaults))
        XCTAssertTrue(DesktopSettings.bool("x", default: true))
    }

    func testDefaultHotkeys() {
        XCTAssertEqual(GlobalHotkey.defaults.map(\.action), GlobalHotkey.Action.allCases)
        XCTAssertEqual(GlobalHotkey.default(for: .toggleMainWindow)?.displayString, "⌃⌥C")
        XCTAssertEqual(GlobalHotkey.default(for: .toggleConversation)?.displayString, "⌃⌥V")
        // Carbon：controlKey = 0x1000，optionKey = 0x0800。
        XCTAssertEqual(GlobalHotkey.default(for: .toggleMainWindow)?.carbonModifiers, 0x1800)
        XCTAssertEqual(GlobalHotkey.default(for: .toggleMainWindow)?.keyCode, 8)
        XCTAssertEqual(GlobalHotkey.default(for: .toggleConversation)?.keyCode, 9)
        // 默认组合互不重复，id 唯一。
        let combos = GlobalHotkey.defaults.map { "\($0.keyCode)-\($0.carbonModifiers)" }
        XCTAssertEqual(Set(combos).count, combos.count)
        XCTAssertEqual(Set(GlobalHotkey.Action.allCases.map(\.hotkeyID)).count, GlobalHotkey.Action.allCases.count)
    }

    func testHotkeyDisplayOrderAndActionLookup() {
        let all = GlobalHotkey(action: .toggleMainWindow, keyCode: 49,
                               modifiers: [.command, .shift, .option, .control], key: "Space")
        XCTAssertEqual(all.displayString, "⌃⌥⇧⌘Space")
        XCTAssertEqual(GlobalHotkey.Action(hotkeyID: 2), .toggleConversation)
        XCTAssertNil(GlobalHotkey.Action(hotkeyID: 99))
    }
}
