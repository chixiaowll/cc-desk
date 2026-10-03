import AppKit
import Combine
import CCDeskCore

/// 菜单栏状态项（设计 §15）：单色 `>_` 模板图标 + 需要处理的数量（与 Dock 角标一致，等批准数加粗突出）。
/// 点开是一个菜单：按项目分组的会话（菜单里按紧急程度排序；侧栏本身仍是固定顺序）与常用动作。
/// 保持轻量：按钮只在计数变化时（去抖后）更新，菜单内容在每次打开时（menuNeedsUpdate）才生成。只在主线程使用。
final class StatusBarController: NSObject, NSMenuDelegate {
    struct Actions {
        var showMainWindow: () -> Void
        var newSession: () -> Void
        var toggleConversation: () -> Void
    }

    private let model: AppModel
    private let actions: Actions
    private let preferences: DesktopPreferences
    private let hotkeys: GlobalHotkeyCenter
    private let loginItem: LoginItemController
    private var item: NSStatusItem?
    private var badge = StatusMenu.Badge(waiting: 0, unread: 0)
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel, actions: Actions, preferences: DesktopPreferences = .shared,
         hotkeys: GlobalHotkeyCenter = .shared, loginItem: LoginItemController = .shared) {
        self.model = model
        self.actions = actions
        self.preferences = preferences
        self.hotkeys = hotkeys
        self.loginItem = loginItem
        super.init()
    }

    func start() {
        preferences.$menuBarIconShown
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shown in self?.setVisible(shown) }
            .store(in: &cancellables)
        model.$groups
            .map { StatusMenu.Badge(groups: $0) }
            .removeDuplicates()
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] badge in
                self?.badge = badge
                self?.updateButton()
            }
            .store(in: &cancellables)
    }

    // MARK: 按钮

    private func setVisible(_ shown: Bool) {
        if shown {
            guard item == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "dev.local.ccdesk.status"
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            item.menu = menu
            self.item = item
            updateButton()
        } else if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    private func updateButton() {
        guard let button = item?.button else { return }
        let symbol = badge.waiting > 0 ? "apple.terminal.fill" : "apple.terminal"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "CC Desk")
            ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: "CC Desk")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = badge.isEmpty ? .imageOnly : .imageLeading
        button.attributedTitle = badgeTitle()
        button.toolTip = badge.tooltip
        button.setAccessibilityLabel(badge.tooltip)
    }

    /// 等批准数用粗体，已完成·未读数用常规字重；颜色跟随菜单栏（不着色，保持单色风格）。
    private func badgeTitle() -> NSAttributedString {
        let title = NSMutableAttributedString()
        let size = NSFont.systemFontSize(for: .small) + 1
        if let waiting = badge.emphasizedText {
            title.append(NSAttributedString(string: waiting, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)]))
        }
        if let unread = badge.secondaryText {
            title.append(NSAttributedString(string: unread, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)]))
        }
        return title
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.refresh()
        menu.removeAllItems()
        let sections = StatusMenu.sections(model.groups)
        if sections.isEmpty {
            let empty = NSMenuItem(title: L("statusMenu.noSessions"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for section in sections {
            let header = section.branch.map { "\(section.title)  ·  \($0)" } ?? section.title
            menu.addItem(NSMenuItem.sectionHeader(title: header))
            for entry in section.entries { menu.addItem(sessionItem(entry)) }
        }
        menu.addItem(.separator())
        menu.addItem(actionItem(L("statusMenu.showMainWindow"), #selector(showMainWindow),
                                hotkey: hotkeys.activeHotkey(for: .toggleMainWindow)))
        menu.addItem(actionItem(L("statusMenu.newSession"), #selector(newSession)))
        let conversation = actionItem(L("menu.conversationMode"), #selector(toggleConversation),
                                      hotkey: hotkeys.activeHotkey(for: .toggleConversation))
        conversation.state = model.conversation.isOn ? .on : .off
        menu.addItem(conversation)
        menu.addItem(.separator())
        let login = actionItem(loginItem.state.needsApprovalHint ? L("menu.launchAtLogin.needsApproval") : L("menu.launchAtLogin"),
                               #selector(toggleLaunchAtLogin))
        login.state = loginItem.state.isOn ? .on : .off
        menu.addItem(login)
        let hotkeyToggle = actionItem(L("menu.globalHotkeys"), #selector(toggleGlobalHotkeys))
        hotkeyToggle.state = preferences.globalHotkeysEnabled ? .on : .off
        menu.addItem(hotkeyToggle)
        for hotkey in hotkeys.unavailable {
            let hint = NSMenuItem(title: L("hotkey.unavailable", hotkey.displayString), action: nil, keyEquivalent: "")
            hint.isEnabled = false
            hint.indentationLevel = 1
            menu.addItem(hint)
        }
        let icon = actionItem(L("menu.showMenuBarIcon"), #selector(hideMenuBarIcon))
        icon.state = .on
        icon.toolTip = L("statusMenu.hideIconHint")
        menu.addItem(icon)
        menu.addItem(.separator())
        menu.addItem(actionItem(L("statusMenu.quit"), #selector(quit), key: "q", modifiers: .command))
    }

    private func sessionItem(_ entry: StatusMenu.Entry) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: #selector(selectSession(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = entry.id
        let title = NSMutableAttributedString(string: entry.title, attributes: [
            .font: NSFont.menuFont(ofSize: 0)])
        title.append(NSAttributedString(string: "   " + entry.detail, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: entry.tone == .waiting ? Self.color(for: .waiting) : NSColor.secondaryLabelColor]))
        item.attributedTitle = title
        item.image = Self.dot(entry.tone)
        item.toolTip = entry.row.tooltip
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, hotkey: GlobalHotkey? = nil,
                            key: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        // 全局快捷键只在菜单里显示（菜单打开时按下也会触发同一动作）。
        if let hotkey, let equivalent = hotkey.menuKeyEquivalent {
            item.keyEquivalent = equivalent
            item.keyEquivalentModifierMask = Self.flags(hotkey.modifiers)
        }
        return item
    }

    private static func flags(_ modifiers: GlobalHotkey.Modifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return flags
    }

    // MARK: 状态点（颜色取自 Theme 的状态色，随浅色 / 深色菜单切换）

    private static func color(for tone: StatusMenu.Tone) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            switch tone {
            case .waiting: return NSColor(hex: dark ? 0xE2875F : 0xC4552B)
            case .working: return NSColor(hex: dark ? 0x82A8CF : 0x4A7BAD)
            case .unread: return NSColor(hex: dark ? 0x8DB79A : 0x5E8B6A)
            case .idle: return NSColor(hex: dark ? 0x837E76 : 0x8A857D)
            case .inactive: return NSColor(hex: dark ? 0x837E76 : 0x8A857D).withAlphaComponent(0.45)
            }
        }
    }

    private static func dot(_ tone: StatusMenu.Tone) -> NSImage {
        let color = color(for: tone)
        let hollow = tone == .inactive
        return NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            if hollow {
                color.setStroke()
                circle.lineWidth = 1
                circle.stroke()
            } else {
                color.setFill()
                circle.fill()
            }
            return true
        }
    }

    // MARK: 动作

    @objc private func selectSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let group = model.groups.first(where: { $0.rows.contains { $0.id == id } }),
              let row = group.rows.first(where: { $0.id == id }) else { return }
        switch row.session.host {
        case .terminalApp, .vscode, .other:
            // 外部会话与点侧栏一样直接跳到它所在的 App。
            model.activate(row)
        case .embedded, .missing:
            if model.collapsed.contains(group.id) { model.collapsed.remove(group.id) }
            actions.showMainWindow()
            model.activate(row)
        }
    }

    @objc private func showMainWindow() { actions.showMainWindow() }
    @objc private func newSession() { actions.newSession() }
    @objc private func toggleConversation() { actions.toggleConversation() }
    @objc private func toggleLaunchAtLogin() { loginItem.toggle() }

    @objc private func toggleGlobalHotkeys() {
        preferences.globalHotkeysEnabled.toggle()
    }

    @objc private func hideMenuBarIcon() {
        preferences.menuBarIconShown = false
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
