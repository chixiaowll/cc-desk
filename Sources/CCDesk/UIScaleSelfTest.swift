import AppKit
import SwiftUI
import CCDeskCore

/// `CCDesk --ui-scale-selftest`：不启动界面，在屏幕外按每一档界面文字（小 / 标准 / 大 / 特大）渲染侧栏会话行、
/// 目录行、窗格标题条、状态胶囊和设置行，量出实际尺寸（设计 §25）：
/// - 固定高度的地方（行、标题条、胶囊）放得下同字号文字的自然高度，不会把字裁掉；
/// - 组件按给定宽度排版（长名字截断，不撑出可用宽度），尺寸不为 0，且随倍率单调变大；
/// - 设置里的系统控件跟着倍率变大；
/// - 终端字号快捷键交给菜单 / 按键监视，不会被终端视图认领（设计 §18）。
/// 不启动任何进程、不碰 ~/.cc-desk 与 tmux。
enum UIScaleSelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.dropFirst().contains("--ui-scale-selftest") else { return }
        exit(run() ? 0 : 1)
    }

    private static var failures = 0

    private static func check(_ ok: Bool, _ message: String) {
        print("\(ok ? "PASS" : "FAIL") \(message)")
        if !ok { failures += 1 }
    }

    static func run() -> Bool {
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared
        checkTextFitsFixedFrames()
        checkComponents()
        checkTerminalFontKeys()
        print(failures == 0 ? "ui scale selftest: all passed" : "ui scale selftest: \(failures) failure(s)")
        return failures == 0
    }

    /// 固定高度的文字行：(名称, 字号, 字重, 标准倍率下的高度, 最大倍率)。工具栏里的标题最多放大到「大」。
    private static let fixedLines: [(String, CGFloat, Font.Weight, CGFloat, CGFloat?)] = [
        ("row title", 12.5, .semibold, 17, nil),
        ("row status line", 11, .bold, 14, nil),
        ("row shortcut badge", 11, .semibold, 18, nil),
        ("group header", 13, .semibold, 28, nil),
        ("count chip", 10.5, .semibold, 16, nil),
        ("pane header", 12, .semibold, 30, nil),
        ("status pill", 11.5, .semibold, 22, nil),
        ("detached header", 12.5, .semibold, 36, nil),
        ("palette row", 13, .regular, 36, nil),
        ("history popover row", 12.5, .medium, 32, nil),
        ("voice bar button", 11.5, .medium, 24, nil),
        ("toolbar title", 13.5, .semibold, 18, UIScale.toolbarMaxFactor),
        ("toolbar subtitle", 11.5, .regular, 15, UIScale.toolbarMaxFactor),
    ]

    private static func checkTextFitsFixedFrames() {
        for preset in UIScalePreset.allCases {
            var tight: [String] = []
            for (name, size, weight, height, cap) in fixedLines {
                let factor = min(CGFloat(preset.factor), cap ?? .infinity)
                let scale = UIScale(factor: factor)
                let natural = measure(Text(verbatim: "Hgjy 中文 · 12:34").uiFont(size: size, weight: weight).fixedSize(),
                                      environment: scale, preset: preset).height
                let frame = scale.metric(height)
                if natural <= 0 || natural > frame + 0.5 { tight.append("\(name) \(natural) > \(frame)") }
            }
            check(tight.isEmpty, "\(preset.rawValue): text fits fixed-height frames\(tight.isEmpty ? "" : ": " + tight.joined(separator: ", "))")
        }
    }

    private static func checkComponents() {
        let theme = ThemeStore.shared.theme(for: .light)
        let longName = String(repeating: "很长的会话名字 long session name ", count: 4)
        let session = AgentSession(id: "selftest", kind: .claude, sessionID: "s", pid: nil, tty: nil, cwd: "/tmp/project",
                                   name: longName, nameIsDerived: false, host: .embedded(terminalID: UUID()),
                                   status: .waiting("Bash"), statusChangedAt: Date(), backgroundWork: false)
        let row = SidebarRow(session: session, displayName: longName, groupTitle: "project", subtitle: nil,
                             sourceLabel: nil, agentLabel: "Claude", tooltip: longName)
        let group = SessionGroup(id: "/tmp/project", title: String(repeating: "project-directory-", count: 4),
                                 rows: [row], branch: "feature/very-long-branch-name")
        var previous: [String: CGSize] = [:]
        for preset in UIScalePreset.allCases {
            let scale = UIScale(factor: CGFloat(preset.factor))
            // 侧栏最窄时一行的可用宽度：侧栏最小宽度 − 两侧 12pt − 会话行缩进 16pt。
            let sidebar = scale.metric(240)
            let probes: [(String, AnyView, CGFloat, CGFloat?)] = [
                ("session row", AnyView(SessionRowView(row: row, selected: true, now: Date(), appIcon: nil, theme: theme,
                                                       detached: true, shortcut: 3)), sidebar - 24 - 16, nil),
                ("group header", AnyView(GroupHeaderLabel(group: group, collapsed: true, theme: theme)),
                 sidebar - 24, scale.metric(28)),
                ("pane header", AnyView(PaneHeaderBar(row: row, title: longName, focused: true, zoomed: false, theme: theme)),
                 260, scale.metric(PaneGeometry.headerHeight)),
                ("status pill", AnyView(StatusPill(status: .working, label: nil, missing: false, theme: theme).fixedSize()),
                 400, scale.metric(22)),
                ("settings rows", AnyView(settingsRows), scale.metric(600) - 80, nil),
            ]
            for (name, view, width, expectedHeight) in probes {
                let size = layoutSize(of: view, width: width, preset: preset)
                var problems: [String] = []
                if !(size.width > 0 && size.height > 0) { problems.append("zero size \(size)") }
                if size.width > width + 0.5 { problems.append("width \(size.width) overflows \(width)") }
                if let expectedHeight, abs(size.height - expectedHeight) > 0.5 {
                    problems.append("height \(size.height) != \(expectedHeight)")
                }
                if let last = previous[name], size.height < last.height - 0.5 {
                    problems.append("height \(size.height) shrank from \(last.height)")
                }
                previous[name] = size
                check(problems.isEmpty, "\(preset.rawValue): \(name) \(Int(size.width))×\(Int(size.height))"
                      + (problems.isEmpty ? "" : ": " + problems.joined(separator: ", ")))
            }
        }
        let standard = layoutSize(of: AnyView(settingsRows), width: 520, preset: .standard).height
        let extraLarge = layoutSize(of: AnyView(settingsRows), width: 520, preset: .extraLarge).height
        check(extraLarge > standard * 1.1, "settings controls grow with the scale (\(Int(standard)) → \(Int(extraLarge)))")
    }

    /// 终端字号快捷键不会被终端吃掉：终端视图不认领 ⌘= / ⌘- / ⌥⌘0 的 key equivalent（交给菜单），
    /// 菜单之外的等价按键（⇧⌘=、小键盘 ⌘+ / ⌘-）由按键监视识别，⌘= / ⌘- 本身留给菜单。
    private static func checkTerminalFontKeys() {
        func key(_ chars: String, _ ignoring: String, _ flags: NSEvent.ModifierFlags, _ code: UInt16) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                             context: nil, characters: chars, charactersIgnoringModifiers: ignoring,
                             isARepeat: false, keyCode: code)
        }
        let terminal = DetectingTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = terminal
        window.makeFirstResponder(terminal)
        let menuKeys = [key("=", "=", .command, 24), key("-", "-", .command, 27), key("º", "0", [.command, .option], 29)]
        check(menuKeys.allSatisfy { $0.map { !terminal.performKeyEquivalent(with: $0) } ?? false },
              "terminal view leaves ⌘= / ⌘- / ⌥⌘0 to the menu")
        let cases: [(String, NSEvent?, Int?)] = [
            ("⌘=", key("=", "=", .command, 24), nil),
            ("⌘-", key("-", "-", .command, 27), nil),
            ("⇧⌘=", key("+", "+", [.command, .shift], 24), 1),
            ("⇧⌘= (ignoring shift)", key("+", "=", [.command, .shift], 24), 1),
            ("keypad ⌘+", key("+", "+", [.command, .numericPad], 69), 1),
            ("keypad ⌘-", key("-", "-", [.command, .numericPad], 78), -1),
            ("⌘A", key("a", "a", .command, 0), nil),
            ("⌃⌘=", key("=", "=", [.command, .control], 24), nil),
        ]
        let wrong = cases.filter { name, event, expected in
            guard let event else { return true }
            return TerminalFontShortcuts.alternateSteps(for: event) != expected
        }.map(\.0)
        check(wrong.isEmpty, "alternate font keys are recognised\(wrong.isEmpty ? "" : ": wrong for " + wrong.joined(separator: ", "))")
        window.contentView = nil
    }

    /// 设置页里的几种行：选择器、开关、带说明的行（与设置 › 通用同样的控件）。
    private static var settingsRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L("settings.general.uiScale"), selection: .constant(UIScalePreset.standard)) {
                ForEach(UIScalePreset.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Toggle(L("settings.general.showModelInSidebar"), isOn: .constant(true))
            Picker(L("settings.general.terminalFontSize"), selection: .constant(13.0)) {
                Text("13 pt").tag(13.0)
            }
            SettingsNote(text: L("settings.general.terminalFontNote"))
        }
    }

    /// 文字等不带宽度约束的视图的自然尺寸。
    private static func measure<V: View>(_ view: V, environment scale: UIScale, preset: UIScalePreset) -> CGSize {
        let hosting = NSHostingView(rootView: view.environment(\.uiScale, scale).uiScaleRoot(fixed: preset))
        return hosting.fittingSize
    }

    /// 在给定宽度里实际排版后的尺寸（屏幕外窗口，背景里的 GeometryReader 读出视图自己的大小）。
    private static func layoutSize(of view: AnyView, width: CGFloat, preset: UIScalePreset) -> CGSize {
        let sink = SizeSink()
        let probe = VStack(alignment: .leading, spacing: 0) {
            view.background(GeometryReader { proxy in
                let _ = sink.record(proxy.size)
                Color.clear
            })
            Spacer(minLength: 0)
        }
        .frame(width: width, height: 800, alignment: .topLeading)
        .uiScaleRoot(fixed: preset)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let hosting = NSHostingView(rootView: probe)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 800)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.contentView = nil
        return sink.size
    }
}

private final class SizeSink {
    private(set) var size: CGSize = .zero
    func record(_ size: CGSize) { self.size = size }
}
