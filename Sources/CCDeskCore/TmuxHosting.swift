import Foundation

/// 内嵌终端托管在 CC Desk 专用的 tmux 服务器里（设计 §14）：会话命名、生成的配置、命令参数与输出解析。
/// 这里只有纯逻辑，不起子进程；执行在 App 层（TmuxHost）。
public enum TmuxNaming {
    /// 专用服务器的 socket 名（`tmux -L ccdesk`），从不使用用户默认的 tmux 服务器与配置。
    public static let defaultSocket = "ccdesk"
    /// 测试 / 隔离运行时可用该环境变量换一个 socket 名。
    public static let socketEnvironmentKey = "CCDESK_TMUX_SOCKET"
    public static let sessionPrefix = "ccdesk-"

    /// 环境变量里的 socket 名只接受字母、数字、`-`、`_`（会成为 /tmp 下的文件名）。
    public static func socket(environment: [String: String]) -> String {
        guard let name = environment[socketEnvironmentKey], !name.isEmpty, name.count <= 64,
              name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
        else { return defaultSocket }
        return name
    }

    public static func sessionName(for terminalID: UUID) -> String {
        sessionPrefix + terminalID.uuidString
    }

    /// 精确匹配的目标（`=` 前缀：tmux 不再做前缀 / 通配匹配）。
    public static func target(for terminalID: UUID) -> String {
        "=" + sessionName(for: terminalID)
    }

    /// `ccdesk-<UUID>` -> UUID；不是 CC Desk 的会话名时为 nil。
    public static func terminalID(fromSessionName name: String) -> UUID? {
        guard name.hasPrefix(sessionPrefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(sessionPrefix.count)))
    }
}

/// `tmux -V` 的版本号（如 "tmux 3.7c"、"tmux next-3.8"）；只比较主、次版本。
public struct TmuxVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// 生成的配置用到的特性（extended-keys-format、allow-passthrough、terminal-features 的下标写法）需要 3.3 以上。
    public static let minimumSupported = TmuxVersion(major: 3, minor: 3)

    public static func parse(_ output: String) -> TmuxVersion? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = text.range(of: #"[0-9]+\.[0-9]+"#, options: .regularExpression) else { return nil }
        let parts = text[range].split(separator: ".")
        guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        return TmuxVersion(major: major, minor: minor)
    }

    public static func < (a: TmuxVersion, b: TmuxVersion) -> Bool {
        (a.major, a.minor) < (b.major, b.minor)
    }

    public var description: String { "\(major).\(minor)" }
}

/// CC Desk 生成的 tmux 配置：让 tmux 尽量「隐形」，所有按键交给 App 里的 agent。
public enum TmuxConfig {
    public static func text() -> String {
        """
        # 由 CC Desk 生成，每次启动时覆盖；只用于 CC Desk 专用的 tmux 服务器（tmux -L ccdesk）。
        # 不读取、也不影响用户自己的 ~/.tmux.conf 与默认 tmux 服务器。

        # 服务器：没有会话时退出；Esc 不等待；复制经 OSC 52 交给 App 的剪贴板。
        set -s exit-empty on
        set -s exit-unattached off
        set -s escape-time 0
        set -s set-clipboard on
        set -s focus-events on
        # 修饰键（Shift+Enter 等）：程序请求时用 CSI u 报告；Claude Code 会请求。
        set -s extended-keys on
        set -s extended-keys-format csi-u
        # 外层终端是 SwiftTerm（TERM=xterm-256color）：真彩色、扩展按键、剪贴板、标题、焦点、光标样式。
        set -s terminal-features[90] 'xterm*:RGB:extkeys:clipboard:title:focus:ccolour:cstyle:sync'

        # 窗格内：macOS 14 自带 tmux-256color 的 terminfo。
        set -g default-terminal tmux-256color
        set -g history-limit 20000
        set -g status off
        set -g destroy-unattached off
        set -g detach-on-destroy on
        set -g visual-bell off
        set -g visual-activity off
        set -g allow-passthrough on
        set -g automatic-rename off
        set -g allow-rename off
        set -g mode-keys emacs
        # 窗格标题（程序用 OSC 0/2 设置）原样转发给外层终端：屏幕规则的 osc_title 依赖它。
        set -g set-titles on
        set -g set-titles-string '#{pane_title}'
        set -wg remain-on-exit off
        set -wg aggressive-resize on
        set -wg window-size latest

        # 没有前缀键，也不拦截任何键盘按键。
        set -g prefix None
        set -g prefix2 None
        unbind -a -T prefix

        # 鼠标：滚轮进入 tmux 的复制模式翻看历史（滚回底部自动退出）；程序自己要鼠标时原样转发。
        # 拖选在复制模式里选择，松开即复制到系统剪贴板；按住 Shift 拖选则是 SwiftTerm 自己的选择。
        set -g mouse on
        unbind -n MouseDown3Pane
        unbind -n M-MouseDown3Pane
        bind -n WheelUpPane if -F '#{||:#{pane_in_mode},#{mouse_any_flag}}' { send -M } { copy-mode -e }
        bind -T copy-mode WheelUpPane send -N 1 -X scroll-up
        bind -T copy-mode WheelDownPane send -N 1 -X scroll-down
        bind -T copy-mode MouseDragEnd1Pane send -X copy-pipe-and-cancel

        """
    }
}

/// `list-panes` 的一行：会话名、窗格 shell pid 与窗格 tty。
public struct TmuxPane: Equatable, Sendable {
    public let sessionName: String
    public let panePID: Int32
    public let paneTTY: String

    public init(sessionName: String, panePID: Int32, paneTTY: String) {
        self.sessionName = sessionName
        self.panePID = panePID
        self.paneTTY = paneTTY
    }

    public var terminalID: UUID? { TmuxNaming.terminalID(fromSessionName: sessionName) }
}

public enum TmuxListing {
    public static let paneFormat = "#{session_name}\t#{pane_pid}\t#{pane_tty}"

    /// 解析 `paneFormat` 输出；格式不对的行跳过。tty 与 ps 的写法一致（去掉 "/dev/"）。
    public static func parsePanes(_ output: String) -> [TmuxPane] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, !fields[0].isEmpty, let pid = Int32(fields[1]), pid > 0 else { return nil }
            var tty = String(fields[2])
            if tty.hasPrefix("/dev/") { tty.removeFirst("/dev/".count) }
            return TmuxPane(sessionName: String(fields[0]), panePID: pid, paneTTY: tty)
        }
    }

    /// 终端 id -> 窗格；CC Desk 的会话只有一个窗格，同名多行时取第一行。
    public static func panesByTerminal(_ panes: [TmuxPane]) -> [UUID: TmuxPane] {
        var result: [UUID: TmuxPane] = [:]
        for pane in panes {
            if let id = pane.terminalID, result[id] == nil { result[id] = pane }
        }
        return result
    }

    /// 没有服务器在运行（socket 不存在 / 连不上）时 tmux 的报错：视为「没有会话」，不算失败。
    public static func isNoServer(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        return text.contains("no server running") || text.contains("error connecting to")
            || text.contains("no such file or directory")
    }
}

/// 拼 tmux 命令行参数；所有命令都带 `-L <socket> -f <配置>`，`-u` 让客户端按 UTF-8 处理。
public struct TmuxCommand: Equatable, Sendable {
    public let socket: String
    public let configPath: String

    public init(socket: String, configPath: String) {
        self.socket = socket
        self.configPath = configPath
    }

    public var base: [String] { ["-L", socket, "-f", configPath, "-u"] }

    /// 在后台新建会话（不附着），打印窗格 pid / tty。`environment` 只写进该会话（如 CC_DESK_TERMINAL_ID）。
    public func newSession(terminalID: UUID, cwd: String, cols: Int, rows: Int,
                           environment: [String: String], command: [String]) -> [String] {
        var args = base + ["new-session", "-d", "-P", "-F", TmuxListing.paneFormat,
                           "-s", TmuxNaming.sessionName(for: terminalID), "-c", cwd,
                           "-x", String(max(cols, 2)), "-y", String(max(rows, 2))]
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            args += ["-e", "\(key)=\(value)"]
        }
        return args + ["--"] + command
    }

    public func attach(terminalID: UUID) -> [String] {
        base + ["attach-session", "-t", TmuxNaming.target(for: terminalID)]
    }

    public func listPanes() -> [String] {
        base + ["list-panes", "-a", "-F", TmuxListing.paneFormat]
    }

    public func pane(terminalID: UUID) -> [String] {
        base + ["list-panes", "-t", TmuxNaming.target(for: terminalID), "-F", TmuxListing.paneFormat]
    }

    public func hasSession(terminalID: UUID) -> [String] {
        base + ["has-session", "-t", TmuxNaming.target(for: terminalID)]
    }

    public func killSession(name: String) -> [String] {
        base + ["kill-session", "-t", "=" + name]
    }

    public func killSession(terminalID: UUID) -> [String] {
        killSession(name: TmuxNaming.sessionName(for: terminalID))
    }

    /// 服务器已在运行（如上一版 App 启动的）时，重新加载 CC Desk 的配置。
    public func sourceConfig() -> [String] {
        base + ["source-file", configPath]
    }

    /// 窗格底部 `lines` 行纯文本（含历史），软换行拼回一行。
    public func capture(terminalID: UUID, lines: Int) -> [String] {
        base + ["capture-pane", "-p", "-J", "-t", TmuxNaming.target(for: terminalID), "-S", "-\(max(lines, 1))"]
    }

    /// 窗格在复制模式（滚轮翻看历史）时退出复制模式，否则什么都不做（不在状态行报错）。
    public func cancelCopyMode(terminalID: UUID) -> [String] {
        let target = TmuxNaming.target(for: terminalID)
        return base + ["if-shell", "-F", "-t", target, "#{pane_in_mode}", "send-keys -X -t '\(target)' cancel"]
    }

    /// 窗格里实际运行的命令：去掉 tmux 写入的 TMUX / TMUX_PANE（窗格里的 tmux 命令不应连到 CC Desk 的服务器，
    /// 用户自己的 tmux 也不会因「嵌套」拒绝启动），并恢复 CC Desk 的终端身份；随后是与直连 PTY 相同的登录交互 shell。
    public static func paneCommand(shell: String, command: String?) -> [String] {
        ["/usr/bin/env", "-u", "TMUX", "-u", "TMUX_PANE", "-u", "TERM_PROGRAM_VERSION",
         "TERM_PROGRAM=CCDesk", "COLORTERM=truecolor", shell] + LaunchSpec.shellArgs(command: command)
    }
}

/// tmux 可执行文件的候选路径（按优先级）：环境变量指定 > App 内置 > Homebrew（Apple 芯片 / Intel）。
/// 都没有时 App 层再用登录 shell 的 `command -v tmux` 兜底。
public enum TmuxBinary {
    public static let environmentKey = "CCDESK_TMUX"
    public static let homebrewPaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]

    public static func candidates(environment: [String: String], bundledPath: String?) -> [String] {
        var paths: [String] = []
        if let override = environment[environmentKey], !override.isEmpty { paths.append(override) }
        if let bundledPath { paths.append(bundledPath) }
        paths += homebrewPaths
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    /// 登录 shell 里查找 tmux 的脚本（GUI App 的 PATH 不含用户目录）。
    public static let probeScript = "command -v tmux 2>/dev/null; true"

    /// 取 `command -v` 输出里第一条绝对路径（忽略 alias / 函数等）。
    public static func parseProbe(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("/") }
    }
}
