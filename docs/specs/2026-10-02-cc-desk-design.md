# CC Desk 设计文档（v1）

- 日期：2026-10-02
- 状态：待评审
- 形态：macOS 原生窗口 App（Swift / SwiftUI）

## 1. 背景与目标

目前在多个 Terminal.app 窗口里分别启动 Claude Code 等编程 agent，问题是：

- 窗口多，找不到哪个 session 在哪；
- 不知道哪个在处理、哪个跑完、哪个卡在等批准；
- 同时还有 VS Code 里开的 session，分散在不同地方。

CC Desk 的目标：**一个窗口，左边列出所有 agent session 及其状态，右边是内嵌终端，直接在里面操作 agent；状态变化时发系统通知。**

### 成功标准

1. 本机所有正在运行的 Claude Code session（无论在哪启动）都出现在左边栏，3 秒内反映状态变化。
2. 在 CC Desk 内新建、切换、使用 agent session，体验与在 Terminal.app 中基本一致（中文输入、复制粘贴、滚动、agent 全屏 TUI 正常）。
3. session 进入「等批准」或「本轮完成」时收到系统通知，点击通知跳到该 session。
4. 外部 session 可以一键接管到 CC Desk 中继续（对话上下文不丢）。
5. 退出 App 后重新打开，上次的内嵌 session 自动恢复。

### 非目标（v1 不做）

- 后台守护进程（v1 初版关闭 App 后 session 不继续运行；后来改由 tmux 托管保持，见 §4.9）
- 右侧分屏 / 同时显示多个终端
- 手机端、远程机器
- 搜索、自定义分组、标签（按项目目录的自动分组在 v1 内）
- 在 App 内读写 agent 对话记录（除恢复所需的 session id 外）

## 2. 支持范围

**v1 只做 Claude Code**，Codex 与 pi 在 v1.1 加入。适配器抽象在 v1 就建好，v1.1 只需新增适配器、hook 和规则文件。

**v1 不安装任何 hook、不做屏幕检测。** 经核实（Claude Code 2.1.280），Claude 自己维护 `~/.claude/sessions/<pid>.json`，其 `status` 取值为 `busy` / `idle` / `waiting`，`waiting` 时 `waitingFor` 给出原因（如 `input needed`、`dialog open` 或权限对话框描述），Esc 中断等情况也由 Claude 自己更新。这已覆盖 v1 的全部状态需求，因此 §4.4 hook 与 §4.5 屏幕检测推迟到 v1.1（Codex / pi 需要）。该文件格式没有公开文档，读取须宽松（§6）。

| Agent | 启动 | 恢复 | 状态来源 |
|---|---|---|---|
| Claude Code | `claude` | `claude --resume <id>` | `~/.claude/sessions` 登记文件（Claude 自己写入 busy / idle / waiting + waitingFor） |
| Codex（v1.1） | `codex` | `codex resume <id>` | hook（`~/.codex/hooks.json` + `config.toml` 的 `[features] hooks = true`）+ 屏幕规则 |
| pi（v1.1） | `pi` | `pi --session <id>`（已验证，pi 0.73.1；需在原 cwd 下执行） | 扩展（`~/.pi/agent/extensions/`）+ 屏幕规则 |
| 其他命令 | 任意 shell 命令 | 不支持 | 仅「运行中 / 已退出」 |

新增 agent 只需新增一个适配器（§4.3），不改其他模块。

## 3. 界面

```
┌─ CC Desk ───────────────────────────────────────────────────────────┐
│ SESSIONS               [+] │ herdr-75 · ~/work/research/herdr          │
│ ▾ herdr                [+] │ ┌──────────────────────────────────────┐ │
│    ● herdr-75   处理中 now │ │                                      │ │
│    ○ 跑测试     空闲    1h │ │        内嵌终端（SwiftTerm）          │ │
│ ▾ 旅行攻略             [+] │ │                                      │ │
│    ▲ pipeline   等批准  2m │ │                                      │ │
│ ▾ shop-backend [+] │ │                                      │ │
│    ○ c7 [VS Code] 空闲  3h │ │                                      │ │
│ ▸ 读书笔记 (1)         [+] │ └──────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

### 3.1 左边栏

**按项目目录分组。** Claude Code 的会话、`CLAUDE.md`、`.claude/settings.json` 都与启动目录绑定，所以目录是一级组织单位。

- **分组键（项目根）**：对 session 的 cwd 执行 `git -C <cwd> rev-parse --path-format=absolute --git-common-dir`，取其父目录作为项目根，这样同一仓库的多个 worktree 归入同一组；非 git 目录以 cwd 本身为项目根。结果按 cwd 缓存。
- **组标题**：项目根的目录名 + 折叠箭头 + `[+]`；折叠时显示 session 数量，如 `读书笔记 (1)`，并在组标题上显示组内最高优先级的状态图标。折叠状态记在 UserDefaults。
- **组排序**：按组内最高优先级状态（等批准 > 处理中 > 空闲 > 未知），再按组内最近状态变化时间倒序。
- **组内每行**：状态图标、名称、来源标签（内嵌不显示；外部显示 `[Terminal]` / `[VS Code]` / `[外部]`）、状态文字、距上次状态变化的时间。cwd 不等于项目根时（子目录或 worktree），第二行显示相对路径，worktree 额外显示分支名。等批准时第二行改为通知原文（截断）。
- **状态图标**：`▲` 等批准（橙）、`●` 处理中（蓝）、`○` 空闲（灰）、`?` 未知（灰）。超过 24 小时未变化的行整体变灰。
- **名称**：优先用 agent 提供的名称；若是自动生成的无意义名称（如 `claude-88`、`herdr-75` 这类「目录名-编号」），在组内显示为 `#编号`，避免与组名重复。
- **组内排序**：等批准 > 处理中 > 空闲 > 未知，同类按最近变化时间倒序。
- **新建**：组标题上的 `[+]` 直接在该项目根目录新建 session；顶部 `[+]` 弹出目录选择（列出最近使用的目录 + 「选择其他目录…」），回车创建。

### 3.2 交互

| 操作 | 内嵌 session | 外部 session |
|---|---|---|
| 单击 | 右侧显示其终端并聚焦 | 跳到对应 Terminal 标签 / 打开 VS Code 项目 |
| 右键 → 在 Finder 中打开 | ✓ | ✓ |
| 右键 → 复制恢复命令 | ✓ | ✓ |
| 右键 → 在这里接管 | — | ✓（见 §5.3） |
| 右键 → 结束 | 关闭该终端（处理中时二次确认） | 发 SIGTERM（二次确认） |
| 快捷键 | ⌘1…⌘9 切换内嵌 session，⌘N 新建，⌘W 关闭当前 | — |

### 3.3 右侧终端

- 标题栏：名称 · agent 类型 · 路径。
- 每个内嵌 session 一个独立终端视图，切换时只切换显示，不重建、不清屏。
- ⌘C / ⌘V 为复制粘贴（有选区时 ⌘C 复制，否则不发送任何内容）；Ctrl+C 才是中断。

### 3.4 通知与 Dock

- 状态变为「等批准」：标题「<名称> 需要批准」，内容为提示原文。
- 状态由「处理中」变为「空闲」：标题「<名称> 已完成」。
- 不通知的情况：App 在前台且该 session 正在右侧显示；App 刚启动的首次状态加载。
- 点击通知：激活 App 并选中该 session（外部 session 则跳转）。
- Dock 角标：等批准的 session 数（0 时不显示）。
- 通知上的「批准 / 拒绝」（内嵌 session 的等批准通知）：通知类别带两个按钮，「拒绝」为破坏性样式；正文为等待原因压成一行、超过 160 字截断。按钮不激活 App、不切换选中行，只对通知所属 session 的终端发键（回车批准 / Esc 拒绝，与对话模式、`respond_approval` 共用 `EmbeddedTerminal.respondToPermission`）。点击时按 `ApprovalNotification.decide` 复核：session 仍在、是内嵌终端、仍在等批准、且等待原因与发通知时一致才发键；否则不发键，改发一条「<名称>：未执行」提示（请求已变化 / 已不在等批准 / 会话已不在）。执行后清除该 session 的未读与已送达的等批准通知并立即刷新角标。动作记入 `~/.cc-desk/assistant-diag.txt`。外部终端的等批准通知不带按钮（无法输入）。

## 4. 架构

```
           ┌──────────────── 状态采集 ────────────────┐
登记文件  ─▶ RegistryReader    ~/.claude/sessions/*.json │──▶ SessionStore ──▶ SidebarView
进程表    ─▶ ProcessScanner    ps（pid / ppid / tty）     │        │           Notifier
（v1.1）hook ─▶ HookStateReader，屏幕 ─▶ ScreenDetector    │        │           DockBadge
           └───────────────────────────────────────────┘        ▼
                                                        TerminalPool ──▶ TerminalView（右侧）
                                                        Jumper（外部跳转）
                                                        Restorer（退出保存 / 启动恢复）
```

### 4.1 核心数据模型

```swift
enum AgentKind { case claude, codex, pi, other }
enum AgentStatus { case working, waiting(message: String?), idle, unknown }

enum SessionHost {
    case embedded(terminalID: UUID)   // CC Desk 自己的终端
    case terminalApp(tty: String)     // Terminal.app
    case vscode(cwd: URL)             // VS Code 集成终端/插件
    case other(tty: String?)          // 其他终端程序
}

struct AgentSession: Identifiable {
    let id: String            // 优先 agent 的 sessionId，否则 "pid:<pid>"
    var kind: AgentKind
    var pid: Int32
    var tty: String?          // 如 "ttys007"
    var cwd: URL
    var name: String
    var host: SessionHost
    var status: AgentStatus
    var statusChangedAt: Date
    var statusSource: StatusSource   // .hook / .screen / .registry / .process
}
```

**统一键是 tty。** 内嵌终端的伪终端设备名就是其中 agent 进程的 tty，因此内嵌与外部 session 走同一套匹配逻辑：所有来源的数据都按 tty（无 tty 时按 pid）归并到同一个 `AgentSession`。

### 4.2 状态采集与合并

v1 只有登记文件 + 进程两个来源：登记文件给出 session 列表与状态，进程表确认存活并给出 tty 和宿主。下面的多来源合并规则在 v1.1 引入 hook / 屏幕来源时启用，v1 的 `SessionStore` 先按此接口设计：

各来源独立产出 `(tty/pid, status, timestamp)`，`SessionStore` 按优先级合并：

1. **hook / 扩展**（最准确）：agent 主动上报。
2. **屏幕规则**（仅内嵌）：读内嵌终端底部若干行匹配规则。
3. **登记文件**（仅 Claude）：`~/.claude/sessions/<pid>.json` 的 `status`（busy / idle）。
4. **进程扫描**：只能得出 `unknown`（存在）或消失。

合并规则：取**时间戳最新**的高优先级来源；若高优先级来源超过 10 分钟没有更新而低优先级来源有更新，使用低优先级来源（防止 hook 漏报导致状态卡住）。

session 的**存在性**由进程决定：进程不在了就从列表移除，无论其他来源说什么。

**更新机制**：
- v1 每 1 秒轮询一次：读 `~/.claude/sessions/*.json`（文件数等于 session 数，开销可忽略）+ 执行 `ps -axo pid=,ppid=,tty=,comm=`。比 FSEvents 简单，且满足 3 秒内反映变化的目标。
- 过滤：只保留 `kind == "interactive"` 且 `spare != true` 且进程存活的条目。
- （v1.1）屏幕检测在内嵌终端有输出时节流触发（同一终端最多每 500ms 一次），只读底部缓冲区，不读用户滚动位置。

### 4.3 Agent 适配器

```swift
protocol AgentAdapter {
    var kind: AgentKind { get }
    func matches(process: ProcessInfo) -> Bool        // 识别进程，如 comm == "claude"
    func launchCommand(cwd: URL) -> String
    func resumeCommand(sessionID: String) -> String?
    func sessionID(for process: ProcessInfo) -> String?  // 从登记文件/hook 状态取
    var hookInstaller: HookInstaller? { get }
    var screenRules: DetectionManifest? { get }
}
```

v1 实现 `ClaudeAdapter`、`GenericAdapter`；v1.1 增加 `CodexAdapter`、`PiAdapter`。

### 4.4 Hook / 扩展（v1.1）

所有 hook 写同一种状态文件 `~/.cc-desk/state/<tty>.json`：

```json
{ "agent": "claude", "session_id": "…", "tty": "ttys007", "pid": 12345,
  "cwd": "/…", "status": "waiting", "message": "allow command?", "ts": 1790922468588 }
```

- 文件以 tty 命名，同一终端换了 agent 会自然覆盖。
- 写入方式：先写临时文件再 rename，避免读到半截内容。
- hook 脚本自身失败一律静默退出（exit 0），绝不影响 agent 运行。
- tty 取法：hook 进程的父进程链上第一个有 tty 的进程（`ps -o tty= -p $PPID` 起逐级向上）。

| Agent | 安装位置 | 事件 → 状态 |
|---|---|---|
| Claude Code | `~/.claude/settings.json` 的 `hooks`（追加，不改动已有的 rtk hook） | `UserPromptSubmit` → working；`Notification` → waiting（带 message）；`Stop` → idle |
| Codex（v1.1） | `~/.codex/hooks.json`（脚本 `~/.cc-desk/hooks/codex-state.sh`）+ `config.toml` 的 `[features] hooks = true` | `SessionStart` → idle；`UserPromptSubmit` / `PostToolUse` → working；`PermissionRequest` → waiting（message 为工具名）；`Stop` / `Interrupt` → idle |
| pi（v1.1） | `~/.pi/agent/extensions/cc-desk-state.ts` | `session_start` → idle（带 session id）；`agent_start` → working；`agent_end` → idle（pi 0.73.1 没有需要确认的事件） |

v1.1 实测补充（codex-cli 0.160.0 / pi 0.73.1，详见 `docs/notes/2026-10-03-codex-pi-smoke.md`）：

- Codex 在共享的 app-server 守护进程（无 tty）里执行 hook，父进程链上找不到终端。此时状态文件改名为 `codex-<session_id>.json`、`tty` 为空，App 先把进程与会话文件配对（cwd + 启动时间，或命令行 `codex resume <id>`），再按会话 id 取 hook 状态。
- Codex 第一次加载新的 hook 会提示「Hooks need review」，用户选择 Trust 后才运行（信任记录由 Codex 写入 `config.toml` 的 `[hooks.state]`）。
- `PermissionRequest` hook 只上报、不输出决定，Codex 照常显示批准对话框。
- Codex 的 `SessionStart` hook 在交互式 TUI 里直到第一轮才触发；在此之前外部 Codex 会话没有 hook 状态，显示为「未知」（内嵌的由屏幕规则补上）。
- 状态文件超过 7 天未更新的由 App 清理。

**安装流程**：首次启动时在设置页列出可安装的 hook，用户逐个点「安装」。安装前备份原配置文件（`*.cc-desk.bak`），修改用结构化 JSON 合并而非字符串拼接；提供「卸载」按钮，只移除 CC Desk 自己添加的条目。hook 脚本放在 `~/.cc-desk/hooks/`，配置中通过绝对路径引用。

### 4.5 屏幕检测（v1.1）

- 复用 herdr（Apache-2.0）的 `src/detect/manifests/claude.toml`（v1.1 加 codex、pi），随 App 打包，在 `NOTICE` 中注明来源与许可。
- v1 用 Swift 实现规则引擎的子集：区域 `bottom_non_empty_lines(N)`、`whole_recent`、`after_last_prompt_marker`、`osc_title`；匹配 `contains`、`regex`、`line_regex`、`any`、`all`；按 `priority` 取最高命中规则。不支持的区域或字段：跳过该规则并记录日志，不报错。
  - v1.1 实现（`Sources/CCDeskCore/ScreenRules.swift` + 最小 TOML 解析 `MiniTOML.swift`）另支持区域 `bottom_lines(N)`、`top_non_empty_lines(N)`、`before_current_prompt_marker`、`whole_recent_without_current_prompt_marker`，匹配 `not`、`skip_state_update`；没有规则命中时视为空闲（与 herdr 一致）。打包的 codex.toml / pi.toml 全部规则均可解析。
  - 输入为内嵌终端活动缓冲区底部一屏（每行去掉行尾空白）与 OSC 标题；有输出时同一终端最多每 0.5 秒检测一次，截取在主线程、匹配在后台队列。
- 引擎有单元测试，用合成的最小规则和字符串测试解析、区域、AND/OR、优先级；不针对具体 agent 的真实屏幕写断言（agent 界面会变，交给 §8 的实测）。

### 4.6 内嵌终端（TerminalPool）

- 终端组件：[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)（SPM 引入，使用其 `LocalProcessTerminalView`）。
- 每个内嵌 session = 一个伪终端 + 用户的登录 shell（`$SHELL -l -i`），启动后自动输入 agent 的启动或恢复命令。这样 PATH、别名、rtk 等环境与平时一致；agent 退出后 shell 保留，用户可再次输入命令。
- 环境变量额外注入 `CC_DESK=1`、`CC_DESK_TERMINAL_ID=<uuid>`，供 hook 识别（tty 仍是主键）。
- 屏幕检测通过 SwiftTerm 的缓冲区接口读取底部行，只在主线程之外做匹配。
- 对外提供统一的写入接口，v1 只用于自动输入启动 / 恢复命令，为后续语音输入等功能预留：

```swift
protocol TerminalInputSink {
    /// 按终端当前的 bracketed paste 模式写入文本；submit 为 true 时随后发送回车。
    func send(text: String, submit: Bool, to terminalID: UUID)
}
```

### 4.7 外部跳转（Jumper）

- **Terminal.app**：AppleScript 遍历 `windows → tabs`，找到 `tty is "/dev/ttysNNN"` 的标签，设为 selected 并把窗口置前。首次使用时 macOS 会请求「自动化」权限；被拒绝时在界面提示如何到系统设置开启。
- **VS Code**：`open -a "Visual Studio Code" <cwd>`（无法精确定位到具体面板）。
- **其他终端**：激活该终端 App（由进程链上的 `.app` 判断），不做精确定位。

### 4.8 退出与恢复（Restorer）

- ⌘Q 时若有内嵌 session 处于 working / waiting，弹窗列出它们并确认。
- 退出前写 `~/.cc-desk/workspace.json`：内嵌 session 的 `{kind, sessionID, cwd, name, 顺序}`。
- 启动时读取该文件，按顺序为每项新建终端并执行恢复命令；没有 sessionID 的项（如 `other`）只在原目录打开 shell。
- **cwd 必须与原 session 一致**：Claude 按目录保存会话（`~/.claude/projects/<编码路径>/`），恢复命令一律在原 cwd 下执行。若原目录已不存在，不启动该项，而在左边栏显示为「目录缺失」占位行，右键可选「在其他目录打开」或「移除」。
- 有 tmux 时，上面的「新建并恢复」只用于 tmux 会话已不存在的项；会话还在的项直接附着，见 §4.9。
- **单实例**：界面实例启动时 `flock(LOCK_EX|LOCK_NB)` 锁住 `~/.cc-desk/instance.lock`（fd 带 `O_CLOEXEC`，内嵌终端 / tmux 服务器不会继承），运行期间一直持有，进程退出 / 崩溃时由内核释放。拿不到锁说明已有实例：激活它然后退出——否则两个实例会各自用自己的终端池覆盖 workspace.json、争抢控制接口与 tmux 会话。`--mcp`、`--tts-test`、`--tmux-selftest`（以及本地化探针）不拿锁。`CCDESK_INSTANCE_LOCK` 可换路径（隔离运行用）。
- **切换语言重启**：确认退出后先存 workspace、停掉轮询（之后不再写 workspace）与控制接口、交出锁，再以 `--relaunched` 启动新实例；新实例最多等 15 秒拿锁，控制接口绑定失败（socket 仍被正在退出的旧实例占着）时每 0.5 秒重试、最多 10 秒。新实例启动失败时旧实例拿回锁并恢复轮询与控制接口。

### 4.9 会话保持（tmux 托管）

目标：退出 / 重启 / 崩溃 CC Desk 不再中断内嵌 session 里正在进行的工作。

**结构**

- CC Desk 使用专用的 tmux 服务器：`tmux -L ccdesk -f ~/.cc-desk/tmux.conf -u …`。从不连接用户默认的 tmux 服务器，也不读 `~/.tmux.conf`。`CCDESK_TMUX_SOCKET` 可换 socket 名（隔离测试用）。
- 每个内嵌终端 = 一个 tmux 会话 `ccdesk-<终端 UUID>`（一个窗口、一个窗格）。新建时先 `new-session -d -P -F '#{session_name}\t#{pane_pid}\t#{pane_tty}' -s … -c <cwd> -x <cols> -y <rows> -e CC_DESK=1 -e CC_DESK_TERMINAL_ID=<uuid> -- <窗格命令>`，再让 SwiftTerm 运行 `tmux attach-session -t =ccdesk-<uuid>`。SwiftTerm 里只是 tmux 客户端。
- 窗格命令：`/usr/bin/env -u TMUX -u TMUX_PANE COLORTERM=truecolor $SHELL -l -i [-c "<命令>\nexec $SHELL -l -i"]`，与直连时相同的登录交互 shell。去掉 `TMUX`，这样窗格里的 `tmux` 命令不会连到（或误杀）CC Desk 的服务器，用户自己的 tmux 也不会拒绝「嵌套」启动。保留 tmux 写入的 `TERM_PROGRAM=tmux`：实测 Claude Code 只在 `TERM_PROGRAM=tmux` 时请求 modifyOtherKeys（`pane_key_mode` 为 `Ext 2`）；设成 `CCDesk` 时它改问 kitty 键盘协议，tmux 不回应，`pane_key_mode` 停在 `VT10x`，Shift+Enter 就退化成回车。
- 环境：tmux 客户端的环境（同 `LaunchSpec.sanitizedEnvironment`，去掉会话级 Claude / Codex 变量与宿主终端变量，`TERM=xterm-256color`、`COLORTERM=truecolor`、缺省时补 UTF-8 的 `LANG`）会成为服务器的全局环境，所以不含 `CC_DESK_TERMINAL_ID`；终端 id 用 `-e` 只写进对应会话。窗格内 `TERM=tmux-256color`（macOS 14 自带该 terminfo）。
- tty 映射：agent 的 tty 是**窗格**的 tty。新建 / 附着时就拿到窗格 shell 的 pid（`pane_pid`），之后每秒的轮询照旧用 `ps` 的进程表求 `tty(of: pane_pid)`，不再为轮询起 tmux 子进程。hook 状态、Codex / pi 的 tty 匹配、「已结束」判断都沿用 tty。

**生成的配置（让 tmux 隐形）**

- `status off`、`prefix None` / `prefix2 None`、`unbind -q -a -T prefix`：没有前缀键，所有键盘按键交给 agent；`escape-time 0`。
- `set-titles on` + `set-titles-string '#{pane_title}'`：程序的 OSC 0/2 标题原样转给 SwiftTerm（屏幕规则的 `osc_title` 依赖）。
- 真彩色：`terminal-features[90] 'xterm*:RGB:extkeys:clipboard:title:focus:ccolour:cstyle:sync'`（固定下标，重复加载不累积）。`focus-events on`、`allow-passthrough on`、`set-clipboard on`（复制经 OSC 52 到 SwiftTerm，再写入系统剪贴板）。
- 修饰键：`extended-keys always` + `extended-keys-format csi-u`。SwiftTerm 不支持 modifyOtherKeys，tmux 也不发 kitty 键盘协议请求，所以 SwiftTerm 把 Shift+Enter 发成 `\r`。CC Desk 因此在 tmux 托管的终端里拦截 Return + Shift / Ctrl，改发 `ESC[13;2u` / `ESC[13;5u`，tmux 会解析。实测各 agent 的 `pane_key_mode`：Claude Code（在 `TERM_PROGRAM=tmux` 时）与 pi 自己请求 `Ext 2`；Codex 不请求（`VT10x`），但能解析 CSI u。`always` 让没有传统编码的组合键（Shift+Enter、Ctrl+Enter…）对所有程序都以 CSI u 报告，于是 Codex 里 Shift+Enter 是换行而不是提交（实测输入 `abc`、Shift+Enter、`def` 得到两行、未提交）。普通键与 Ctrl+字母不受影响。Shift+Tab 本来就是 `ESC[Z`，tmux 会转换。
- 鼠标：`mouse on`。不选 `mouse off` 的原因是：tmux 客户端用备用屏幕，SwiftTerm 里没有回滚区，`mouse off` 时滚轮会被 SwiftTerm 转成方向键（发给 Claude Code 就成了翻输入历史）。`mouse on` 时滚轮进入 tmux 复制模式，每格滚一行，翻看 20000 行的 `history-limit` 历史；滚回底部自动退出（`copy-mode -e`）。窗格程序自己请求鼠标时原样转发。拖选在复制模式里进行，松开即复制（OSC 52）并回到底部；按住 Shift 拖选是 SwiftTerm 自己的选择（只限当前屏幕，⌘C 复制）。右键菜单解除绑定。
- 复制模式里键盘会被 tmux 吞掉，所以 CC Desk 记下「用户向上滚过」，下一次输入（键盘、语音、助手 `type_text` / `send_keys`）前先执行 `if -F '#{pane_in_mode}' 'send -X cancel'`（一次几毫秒）。这段时间屏幕上是历史，屏幕检测先用 `display -p '#{pane_in_mode}'` 确认已回到底部再做。
- 其他：`exit-empty on`（没有会话时服务器退出）、`destroy-unattached off`、`remain-on-exit off`、`aggressive-resize on`、`window-size latest`、`automatic-rename off`、`mode-keys emacs`。服务器已在运行时（上一版 App 启动的），启动时 `source-file` 重新加载配置。

**生命周期**

- 启动：一次 `list-panes -a`。workspace 里每项：会话还在 → 附着，不发恢复命令，并预先记为「观测到 agent」，这样 App 关闭期间已退出的 agent 首轮就显示「已结束」可原地恢复；会话不在 → 照旧新建并执行恢复命令；目录缺失且会话不在 → 「目录缺失」行（会话还在则不管目录照样附着）。纯逻辑在 `TerminalRestorePlanner`。
- 没有记录的会话：服务器里 `ccdesk-<uuid>` 会话没有 workspace 记录的（workspace 文件缺失 / 损坏、或单实例之前另一个实例写掉了记录），**收养**为内嵌终端：附着它，目录取窗格当前目录（`#{pane_current_path}`，取不到或已删除时用主目录），不记 agent 种类与 sessionId，由之后的轮询从进程表认出，并立即写回 workspace。启动时从不结束任何会话——里面多半是用户还在跑的 agent；不想要的由用户自己关闭。`ccdesk-` 前缀但不是合法 UUID 的会话不认识，原样不动。
- 退出 / 崩溃：只是客户端断开，会话继续运行；⌘Q 只在有**直连 PTY** 的活跃 session 时确认。
- 关闭 session（⌘W / 右键关闭 / 助手 `close_session`）：先用 `ps -t <窗格 tty>` 找出窗格 tty 上的所有进程组（含独立进程组的前台作业，如 claude）发 SIGHUP，再 `kill-session`（tmux 关闭 pty）；2 秒后仍存活的进程组与窗格 shell 一律 SIGKILL。与直连 PTY 的关闭方式一致。
- 客户端退出后在后台 `has-session`，区分「会话在」「会话不在（服务器在）」「服务器不在」「超时」（`TmuxSessionState`），再按 `TmuxReattachPolicy`：会话在或超时（不知道）→ 重新附着，短时间内最多 3 次，稳定附着 30 秒后清零；超过次数则保留终端（workspace 记录不丢，下次启动附着）并在终端里说明。会话不在 → 照旧移除终端（用户 `exit` 了 shell）。服务器不在时看客户端退出码：0（`[exited]`，最后一个会话正常结束后服务器因 `exit-empty` 随之退出）→ 移除；非 0（`[server exited]` / `[lost server]`，服务器被结束或崩溃）→ 有可恢复的会话时在同一位置换上新 shell，显示为「已结束」可原地恢复，而不是丢掉。
- 主线程不等 tmux：查会话状态、助手 `read_screen` 要的行数超过一屏时的 `capture-pane -p -J -S -<n>` 都在后台队列；新建会话仍在主线程同步执行（平时几毫秒），超时 1.5 秒后回退直连。

**tmux 的来源与回退**

- 解析顺序：`CCDESK_TMUX` 环境变量 → App 内置 `Contents/Helpers/tmux` → `/opt/homebrew/bin/tmux` → `/usr/local/bin/tmux` → 登录 shell 的 `command -v tmux`。要求 `tmux -V` ≥ 3.3。
- 都没有：回退为原来的直连 PTY（没有会话保持），首次启动时提示一次。单个会话创建失败时，该终端也回退为直连。

**DMG 内置 tmux**

- `scripts/build-tmux.sh` 从源码编译 tmux 3.6a（arm64 + x86_64 分别编译后 `lipo`），静态链接 libevent 2.1.12 与 utf8proc 2.12.0，只动态链接系统 `libncurses` / `libSystem` / `libresolv`，部署目标 macOS 14。版本与 SHA-256 固定（与 Homebrew 记录一致）。结果缓存在 `build/tmux/`，并校验 `lipo -verify_arch`、`otool -L`（无 Homebrew 路径）、两种架构能运行。
- 不用 3.7：3.7 系列在 macOS 上需要 jemalloc 才能避开进入复制模式时的断言崩溃（tmux issue 5385），而滚轮翻看历史正靠复制模式。
- `scripts/dmg.sh` 总是内置（`Contents/Helpers/tmux`，先签 helper 再签 App）。`scripts/bundle.sh` 只在 `CCDESK_BUNDLE_TMUX=1` 时内置，本地开发默认用 Homebrew 的 tmux。许可证文本放在 `Contents/Resources/ThirdPartyNotices/tmux.txt`，`NOTICE` 中列出。

**验证**：`CCDesk --tmux-selftest` 不启动界面，在隔离的 `ccdesk-selftest-<pid>` 服务器和临时目录里，用无界面 SwiftTerm `Terminal` 经 pty 运行真正的 `tmux attach`，检查：tty 映射、窗格环境、标题、中文双宽、真彩色、断开后会话存活、重新附着、历史、滚轮进入 / 退出复制模式、Shift+Enter / Shift+Tab、恢复计划与收养没有记录的会话（workspace 缺失时全部收养、一个不杀）、关闭会话、8 个终端时轮询不起 tmux。

**限制**

- 升级前（直连 PTY）的 session 没有 tmux 会话：更新后第一次启动照旧用 `--resume` 恢复（正在进行的一轮会中断，这是最后一次），之后都由 tmux 保持。
- SwiftTerm 自己没有回滚区，历史只在 tmux 复制模式里看；复制模式里的拖选会回到底部；不按 Shift 时选不到 SwiftTerm 原生的多屏选择。
- 内置的 3.6a 与 Homebrew 的版本可能不同。tmux 协议版本多年未变，但若两者不兼容，`list-panes` 会报错，此时新会话回退为直连。
- tmux 服务器自身崩溃或被 `kill-server` 时，所有会话一起结束；有 agent 会话的终端显示为「已结束」可原地恢复（重启 App 后不再保留这条信息，需从历史恢复），其余终端移除。
- socket 位于 `/private/tmp/tmux-<uid>/ccdesk`；若被系统清理，可向服务器发 `SIGUSR1` 重建（tmux 的标准做法）。
- 窗格里看不到 `TMUX` 变量（`TERM_PROGRAM` 仍是 `tmux`）；只认 `TMUX` 的程序不会以为自己在 tmux 里。
- 在普通 shell 提示符下按 Shift+Enter 会收到 `ESC[13;2u`（直连时是回车），zsh 可能显示一段乱码。

## 5. 关键流程

### 5.1 新建 session

`[+]` → 选目录和 agent → TerminalPool 创建伪终端并启动 shell，输入启动命令 → 进程扫描发现 agent 进程（tty 匹配）→ 左边栏出现，状态由 hook / 屏幕规则驱动。

### 5.2 状态变化通知

hook 写 `state/ttys007.json`（waiting）→ FSEvents → SessionStore 合并，状态从 working 变为 waiting → Notifier 判断不在前台显示中 → 发通知 → 点击通知 → 选中该 session。

### 5.3 接管外部 session

右键「在这里接管」→ 若状态为 working / waiting，弹窗确认 → 对外部进程发 SIGTERM，轮询最多 5 秒等其退出（仍在则提示用户手动处理，不发 SIGKILL）→ 在原 cwd 新建内嵌终端，执行 `resumeCommand(sessionID)` → 左边栏该项从「外部」移到「内嵌」。没有 sessionID 或 agent 不支持恢复时，菜单项置灰并说明原因。

## 6. 错误处理

| 情况 | 处理 |
|---|---|
| 登记文件 / 状态文件格式异常或缺字段 | 跳过该文件，记日志；不崩溃 |
| agent 升级导致屏幕规则失效 | 状态回退到下一优先级来源；规则文件可在 `~/.cc-desk/manifests/` 覆盖，无需重新打包 |
| 自动化权限被拒 | 外部跳转失败时显示提示条，附打开系统设置的按钮 |
| 恢复 / 接管时原 cwd 不存在 | 不启动，显示「目录缺失」占位行（见 §4.8） |
| 恢复命令执行失败（session 已不存在） | 终端里会显示 agent 的报错，保留 shell；左边栏标记为普通终端 |
| App 崩溃 | 依赖周期性（每 30 秒及每次增删 session 时）写入的 `workspace.json` 恢复 |

## 7. 项目结构

SwiftPM 包，两个 target：`CCDeskCore`（纯逻辑，无 UI，XCTest 覆盖）与 `CCDesk`（SwiftUI + AppKit 应用，依赖 SwiftTerm v1.20.0）。`scripts/bundle.sh` 把可执行文件打包为 `build/CCDesk.app`（Info.plist + ad-hoc 签名），通知与自动化权限需要 App bundle。逐文件结构见实现计划 `docs/plans/2026-10-02-cc-desk-v1.md`。v1.1 增加 hook、屏幕规则时再加 `Resources/`。

## 8. 测试与验证

**单元测试**（`swift test`）：
- SessionStore 合并：来源优先级、过期回退、进程消失移除、tty 归并。
- 规则引擎：解析、区域截取、AND/OR、优先级、未知字段跳过。
- HookInstaller：在临时 HOME 下对已有配置（含 rtk hook）安装、重复安装幂等、卸载只移除自己的条目、备份生成。
- 登记文件 / 状态文件解析：缺字段、坏 JSON。

**实测清单**（每个 agent 记录版本号和结果）：
- Claude Code 在内嵌终端中：启动、处理中、等批准、空闲、退出、恢复。
- 在 Terminal.app 中启动的同类 session：出现在外部组、状态正确、跳转、接管。
- 终端体验：中文输入法、⌘C/⌘V、滚动回看、agent 全屏界面、窗口缩放。
- 通知：前台不通知、后台通知、点击跳转、刚启动不误报。
- 退出确认与重启恢复。

## 9. 实现前需验证的事项

按实现顺序排在最前面，任一项不成立需回到设计调整：

1. **SwiftTerm 跑 agent 的体验**：在最小 Demo 中运行 `claude`，确认显示、中文输入、快捷键正常。这是整个方案的前提。
2. **Terminal.app AppleScript 按 tty 定位**：在当前 macOS 版本验证。
3. **登记文件的 waiting 状态**：在真实权限确认、AskUserQuestion、Esc 中断场景下，确认 `status` / `waitingFor` 按预期变化。

v1.1 前再验证：Codex hook 的事件名与载荷（`~/.codex/hooks.json`，参考 herdr `src/integration/assets/codex/`）、pi 的恢复命令与扩展 API（参考 herdr `src/integration/assets/pi/`），并在本机安装 codex 和 pi。

## 10. 后续方向（不在 v1）

- 后台守护进程持有终端，关闭窗口 session 继续运行（届时 App 拆为服务 + 界面）。
- 右侧分屏、多终端同屏。
- 只读对话预览（读 agent 的 jsonl 记录）。
- 语音输入：按住快捷键说话，松开后把识别文字通过 `TerminalInputSink` 写入当前 session（先填入不回车，确认后再发送）。识别引擎可选系统 Speech 框架（支持中文、可离线）或本地 Whisper；只需新增一个输入模块，不改终端和状态逻辑。
- 手机端：在守护进程上加网络接口 + 手机网页。
- 接入 herdr 全部 22 份屏幕规则，扩展支持更多 agent。
- 搜索、自定义分组。

## 11. 多 agent 的展示（v1.1，已确认）

- **分组不变**：仍按项目目录分组，Claude / Codex / pi 的会话混排在同一目录下，按状态排序。
- **会话行第二行加 agent 名**：`处理中 · Codex`、`等批准 · 权限确认 · pi`。仅当本机同时出现两种及以上 agent 时显示；只用一种时不显示，保持现在的样子。
- **图标块含义不变**：仍表示「在哪里运行」（内嵌暖灰终端块 / 外部宿主 App 图标 + ↗）。
- **详情标题栏**：`<标题> · Codex · ~/路径`（现已按 kind 显示 Claude）。
- **新建会话**：⌘N 面板和目录行的 `+` 增加 agent 选择（Claude / Codex / pi，只列出本机已安装的），默认上次使用的；目录行 `+` 悬停可选，直接点击用默认。
- **历史会话**：弹出层与全局搜索面板混排各 agent 的历史，每条右侧标 agent 名；搜索面板可按 agent 过滤。恢复时按各自命令：`claude --resume <id>` / `codex resume <id>` / `pi --session <id>`。
- **悬停提示**：加一行「Agent：Codex」。

## 12. 语音助手（v1.2，已确认）

在对话模式（唤醒词「嬴政同学」→ 对话中）之上加一层「助手」：

**能力**
1. **听懂自然说法**：不必背固定指令，「帮我发了吧」「刚才那句不要了」「让它继续」「同意吧」都能理解。
2. **语音管理会话**：「切到 poems 那个会话」「哪些在等我」「在 herdr 里新开一个 Codex」「把旅行攻略那个恢复一下」「关掉这个会话」。
3. **播报回复摘要**：agent 一轮结束后，用一两句话说它做了什么、结果如何、是否需要你处理（替代只说「已完成」）。
4. **问答当前状态**：「它在干嘛」「刚才改了哪些文件」「测试过了吗」——读会话记录后口头回答。

**意图路由**（每句话，对话中状态）
- 先走**本地快速规则**（发送 / 取消 / 退出 / 等批准时的同意·拒绝），命中即执行，零延迟。
- 未命中 → 交给**意图模型**：`claude -p --model haiku --no-session-persistence --tools "" --strict-mcp-config --output-format json --system-prompt <助手提示词>`，工作目录 `~/.cc-desk/assistant`（不产生会话记录、不出现在侧栏/历史）。输入：这句话 + 上下文（会话列表：id/标题/目录/agent/状态；当前选中会话；本轮已口述未发送的内容；最近一轮摘要）。输出 JSON：`{"action": insert|send|cancel|approve|deny|switch|new|resume|close|query|stop|none, "args": {...}, "speak": "简短口语回复"}`。
- **口述内容 vs 指令**：说给 agent 的任务内容 → `insert`（填入输入框，不发送）；控制 CC Desk 的话 → 对应 action。模糊时偏向 `insert`，并在 VoiceBar 显示识别出的动作，便于发现误判。
- 实测延迟约 3.5–4 秒（haiku，含进程启动；`MAX_THINKING_TOKENS=0` 关闭扩展思考，否则 6–14 秒）：调用期间立即播一声短提示并在 VoiceBar 显示「思考中…」，避免冷场；本地规则覆盖最常用指令，「哪些在等我」直接按侧栏状态本地回答，都不调用模型。
- `claude` 路径用登录 shell 解析一次后缓存、直接 exec；去掉会话级 Claude Code 环境变量。模型输出严格校验：未知 action / 不存在的会话 id / 非等批准时的同意·拒绝 → 退回为插入原话并播报「没听懂，已填入」。
- 语音关闭正在处理 / 等批准的会话：先问「确认关闭吗？」，15 秒内说「确认」才关闭。

**摘要与问答**
- 读选中会话的会话记录尾部（Claude / Codex / pi 各自的 jsonl，只读尾部），抽取最后一轮的助手文字、工具调用（改动的文件、执行的命令、测试结果），交给同一模型生成 1–2 句口语摘要 / 回答；代码块与长路径不读出。
- 摘要只在对话模式开启、且该会话为当前选中时播报；其他会话完成时只发系统通知。

**声音**：默认用本机**自然语音**——千问 Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit（mlx-audio 0.5.7，说话人 serena，temperature 0.7、按文本固定随机种子），系统声音（AVSpeechSynthesizer，自动选音质最好的中文声音 Premium > Enhanced > 默认）作为自动后备。
- 安装在 `~/Library/Application Support/CC Desk/tts/`（`venv/` 约 370 MB + 模型 `hf/` 约 1.9 GB，`installed.json` 为完成标记）。菜单「朗读声音 → 自然语音（千问 serena）」没装时询问后安装：登录 shell 里找 `uv` → `uv venv -p 3.12` + `uv pip install mlx-audio==0.5.7 mlx==0.32.3` → 打包的 `tts_server.py --download` 拉模型，提示条显示进度；失败保持系统声音并提示原因。装好且没选过声音时默认选它（偏好 `voiceSpeechVoice = natural:qwen3-serena`）。
- `tts_server.py`（App 资源）是常驻 stdio 进程：加载并预热后发 ready 帧；stdin 一行一个 JSON（`{"id","text","voice","lang"}` / `{"cancel": id|"*"}`），stdout 回长度前缀二进制帧（audio：float32 24 kHz 单声道 PCM / end / error），坏输入不退出，日志写 `tts/server.log`。对话模式打开或第一次朗读时懒启动；对话模式期间常驻，崩溃 1 秒后重启（一分钟最多 3 次）；关闭后空闲 10 分钟卸载。
- 朗读前整理文字（CCDeskCore `SpeechText`）：去 markdown / 代码块，网址留域名、路径留文件名，`cc-desk` → 「C C desk」、`rm -rf` → 「R M 杠 R F」，数字不拆；按句切分后一次全部发给服务端排队合成，音频按到达顺序进 AVAudioPlayerNode 流式播放。新的一句打断旧的（服务端取消 + 清空播放队列）；播报期间照旧暂停采集。
- 后备：没装、模型还在加载（启动后约 2 秒内）、服务出错 / 被杀、或 2.5 秒内没有音频 → 改用系统声音，不会沉默。
- 实测（M3 / 24 GB，热盘）：服务启动到 ready 约 2.0 秒（加载 1.4 秒 + 预热 0.6 秒；复制模型后的第一次冷盘约 16 秒）；首个音频约 0.25 秒（服务端）/ 0.28–0.31 秒（App 内到出声，短句与长句相同）；RTF 约 0.5（合成比播放快一倍，句间无停顿）；打断后服务端约 0.12 秒停下；服务被杀后约 1.5 秒自动恢复；服务进程常驻内存约 2.0 GB（RSS）。

**额度**：意图解析 / 问答 / 摘要都通过本机 `claude` 调用，占用 Claude 订阅额度（5 小时 / 7 天窗口），不额外计费；每次约 3.4k 输入 token（摘要 / 问答约 5.5k）、几十个输出 token。可在菜单关闭「回复摘要」减少占用。

**v1.2.1 调整（已实现）**：助手改为**常驻会话**——一个长期运行的 `claude -p --input-format stream-json --output-format stream-json` haiku 进程，会话 id 存 `~/.cc-desk/assistant/session.json`，下次启动 `--resume` 接回，有上下文（「刚才那句」「搞错了」）。后续每句约 1 秒。本地已执行的操作作为 Events 告诉它；侧栏上下文只在变化时重发。上下文超过 60k token 自动换新会话，菜单可「重置助手对话」。对话模式默认常驻（说「休息一下」回待命）、启动即开；切到 Terminal 里的会话时语音确认后接管；「问他一下 X / 跟它说 X / 在终端里输入 X」本地直接填入 X。助手自己的 claude 进程与会话记录不出现在侧栏和历史。

## 13. 助手工具化（v1.3，已确认）

**目标**：助手从「从 12 个固定动作里选一个」变成「会用工具的 agent」——一句话可做多件事，能操作任意会话（不必先切过去），能看终端屏幕。

**结构**
- **控制接口**：CC Desk 在 `~/.cc-desk/control.sock`（Unix socket，权限 0600，目录 0700）提供 JSON 行协议，只接受本用户连接。请求 `{"id","method","params"}` → 响应 `{"id","result"|"error"}`。所有方法在主线程执行，复用 AppModel 现有动作。
- **工具服务**：同一可执行文件加 `--mcp` 模式（`CCDesk.app/Contents/MacOS/CCDesk --mcp`），作为 stdio MCP 服务器（JSON-RPC 2.0：initialize / tools/list / tools/call），把工具调用转发到 control.sock。不启动界面。
- **助手会话**：常驻 haiku 会话加 `--mcp-config <ccdesk.json> --strict-mcp-config --tools "" --allowedTools "mcp__ccdesk__*"`（内置工具全部关闭，只能用 CC Desk 的工具，MCP 工具调用不弹权限）。模型最后的文字回复即播报内容，不再解析 JSON 动作。
- **本地快速规则保留**：发送 / 取消 / 休息 / 退出 / 「有哪些会话」「哪些在等我」/ 转述填入，不调用模型。

**工具**（会话用短 id 或标题/目录指代；工具内部解析，歧义时返回候选让模型追问）

| 工具 | 作用 | 确认 |
|---|---|---|
| `list_sessions` | 侧栏会话：id、标题、目录、agent、状态、等批准原因、是否选中、是否在 CC Desk 内 | — |
| `read_screen(session, lines?)` | 读内嵌终端当前屏幕（底部 N 行，默认 40）的纯文本 | — |
| `read_transcript(session, turns?)` | 会话记录尾部摘录（复用 TurnDigest） | — |
| `list_history(query?)` / `list_projects` | 历史会话 / 可新建的项目目录 | — |
| `git_status(project)` | 项目的分支、改动文件、最近 5 条提交（只读 git 命令，超时 5 秒） | — |
| `switch_to(session)` | 切到该会话（外部会话 → 走接管确认） | 外部需确认 |
| `type_text(session, text, submit?)` | 往任意内嵌会话的输入框打字，可选回车 | — |
| `press_key(session, key)` | enter / escape / ctrl-c / up / down / tab | ctrl-c 需确认 |
| `respond_approval(session, approve)` | 回应等批准（仅该会话确在等批准时） | — |
| `new_session(project, agent, prompt?)` | 新建会话，可带第一句话（自动发送） | — |
| `resume_session(history_id)` | 恢复历史会话 | — |
| `close_session(session)` / `take_over(session)` | 关闭 / 接管 | 需确认 |

- **需确认的工具**：调用时 CC Desk 播报确认问题并显示提示条，阻塞等待最多 15 秒的语音「确认」，再把结果（done / cancelled）返回给模型。
- **反馈**：VoiceBar 显示「听到：…」和正在执行的工具（「→ 往 poems 输入：跑一下测试」）。
- **撤销**：说「撤销」撤回上一个可撤销动作（新建 → 关闭它；打字未发送 → 清除；切换 → 切回）。
- **安全**：控制接口只在本机、只限本用户；type_text / press_key 只作用于 CC Desk 内嵌终端；外部终端只能读状态、接管。
- **口令**：只限本用户还不够——内嵌终端里的 agent 也是本用户，能连上 control.sock，自己批准自己的权限请求或往别的会话里打字。所以 App 每次启动在内存里随机生成 32 字节口令（`ControlToken`），每条请求必须带 `"token"`，缺少或不对时返回 `unauthorized`（-32003）。口令不写进任何文件：常驻助手的 `claude` 进程环境里带 `CCDESK_CONTROL_TOKEN`，claude 把自己的环境传给 MCP 子进程（2.1.280 实测，`mcp.json` 的 `env` 只合并在上面），`CCDesk --mcp` 从环境读出并随请求发送。`LaunchSpec.sanitizedEnvironment` 去掉这个变量，所以内嵌终端（直连 PTY 与 tmux 服务器的全局环境）里都没有它。`~/.cc-desk/assistant` 目录 0700、`mcp.json` 0600（里面只有可执行文件与 socket 路径）。
- **限制**：同一用户的进程原则上仍能读到助手进程的环境（`ps eww`）——口令挡住的是「顺手连上 socket」，不是有意针对 CC Desk 的本用户恶意程序。CC Desk 的 tmux socket（`/private/tmp/tmux-<uid>/ccdesk`，目录 0700）同样只限本用户：本用户进程可以直接 `tmux -L ccdesk send-keys` 往会话里输入，这与用户自己的 tmux 服务器一样，不在防护范围内。
- **请求 id**：每次请求用新的 UUID 作 id，客户端只接受 id 相同的响应；服务端按连接对象投递回复，连接断开后迟到的回复被丢弃，不会写给复用了同一 fd 的新连接。

**v1.3 实现记录（已实现）**
- **CLI 参数（claude 2.1.280 实测）**：`--mcp-config ~/.cc-desk/assistant/mcp.json --strict-mcp-config --tools "" --allowedTools "mcp__ccdesk__*"`。init 事件里的工具只有 15 个 `mcp__ccdesk__*`，没有任何内置工具（让它「用 bash 跑 ls」时只能往会话里打字）；不加 `--allowedTools` 时 -p 模式下 MCP 调用被拒绝（`permission_denials` 里能看到），加上后不弹权限。`mcp.json` 每次启动会话时重写：`command` = 当前可执行文件，`args` = `["--mcp"]`，`env.CCDESK_CONTROL_SOCKET` = 控制接口路径。
- **MCP**：协议版本按客户端请求协商（支持 2025-11-25 / 2025-06-18 / 2025-03-26 / 2024-11-05，claude 发的是 2025-06-18）；`--mcp` 在 `main()` 最开头判断，不创建 NSApplication；每个工具调用新建一次 socket 连接，最多等 45 秒（含 15 秒语音确认）。CC Desk 没运行时工具返回 isError「CC Desk is not running」。
- **控制接口**：`CCDESK_CONTROL_SOCKET` 可覆盖路径（测试用）；启动时若已有活着的实例在监听就不启动（单实例），残留的 socket 文件删除重建；用 `getpeereid` 拒绝其他用户。
- **会话短 id 稳定**：s1、s2… 在 App 运行期间固定对应一个会话、不复用（侧栏按状态重排不变），上下文与 list_sessions 用同一套 id；历史为 h1、h2…。
- **每句话仍附带侧栏上下文**（变化时；会话 + 项目名 + 未发送内容），模型多数情况下不必先调 list_sessions，省一次往返。历史会话改为 list_history 工具取。
- **偏离工具表**：新增 `clear_input(session)`（删掉 CC Desk 输入、还没发送的文字，对应「刚才那句不要了」）；`close_session` 一律确认（不再只在忙碌时）；`read_transcript(turns)` 按最近 N 条用户消息截取（默认 1，最多 5）。
- **[QUESTION] 去掉**：问答由模型自己调 read_transcript / read_screen 再回答；[SUMMARIZE] 保留。只调用了 type_text(submit=false) 的一轮（逐句口述）不朗读回复，只显示在提示条；朗读的是最后一次工具调用之后的文字（haiku 偶尔在调用前先说「我来看看」）。
- **会话轮换**：session.json 记录提示词版本（现为 2），版本不同就换新会话；上下文超限按最后一次模型调用的输入计算（多次调用工具时合计会虚高）。
- **撤销 / 取消**：CC Desk 往各终端输入的未发送文字统一记账（本地口述与 type_text 共用），「取消」「撤销」都能删掉任一方输入的内容；记录 10 分钟内有效、最多 10 条。
- **实测（haiku，假控制接口 + 真实 `CCDesk --mcp` + 真实 `claude -p`，MAX_THINKING_TOKENS=0）**：不调工具的一句约 0.8–1.5 秒；调一次工具约 2.0–2.5 秒（两次模型调用）；首句含启动约 3.5–4.5 秒；「新开一个 codex 在 herdr，让它看下 README」→ `new_session(project=herdr, agent=codex, prompt="看下 README")` 一步完成；需确认的工具阻塞 16 秒后正常返回（claude 不超时）。额度：工具定义约 3.5k token，每次模型调用约 7k 输入（约 95% 命中缓存），调一次工具的一句约 13–14k 输入、约 100 输出。

## 14. 顾问、派活与专业 agent（v1.4，已确认）

**三层**：前台接线员（haiku 常驻，快）→ 顾问（更强模型，只读，异步）→ 干活的会话（侧栏里可见的真实 agent 会话）。原则：**改代码的事放在你看得见的会话里做，后台只做只读的思考和查看**。

- **顾问 `consult(question, level, project?)`**：后台 `claude -p --model sonnet|opus`，只给 Read / Grep / Glob 和只读 git（`--allowedTools` 限定），工作目录为相关项目，`--no-session-persistence`。默认 Sonnet；用户明确说「用 Opus」才用 Opus。异步：接线员先说「我让高级助手看一下」，完成后播报 1–2 句结论，完整回答显示在「助手结果」面板（可复制）。超时 5 分钟。
- **派活 `delegate(project, task, agent?, profile?)`**：在项目里新开会话（Claude Code / Codex / pi，或某个专业 agent 配置），任务作为第一句话发送，出现在侧栏；接线员记住这是它派出的任务。
- **主动提醒**：派出的任务（以及对话模式开启时任意会话）转为等批准 / 一轮完成时，作为事件发给接线员；接线员决定是否播报（例如「poems 想执行 rm -rf build，要批准吗？」），用户说「批准」即回应该会话，不必切过去。为免打扰，非选中会话的「完成」只在派出的任务上播报。
- **专业 agent 配置**：`~/.cc-desk/agents/*.md`，格式同 Claude Code subagent（frontmatter：name / description / model / tools；正文为提示词）。delegate 用 `claude --agents <json>` / `--agent <name>` 启动；consult 也可指定只读的配置。内置两个：**审查员**（opus，只读，审查某项目未提交改动或最近提交）、**测试员**（sonnet，跑测试并汇报失败原因，作为可见会话运行）。用户可自行添加；`list_agents` 工具让接线员知道有哪些。
- **额度**：顾问与专业 agent 走同一订阅，Sonnet / Opus 占用明显更多；结果面板显示本次 token 数。

**实现顺序**：§13（工具化 + 读屏 + 确认 + 撤销）→ §14 顾问 + 派活 + 主动提醒 → 专业 agent 配置。
