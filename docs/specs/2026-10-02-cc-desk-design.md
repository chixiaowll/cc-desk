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

- 后台守护进程（关闭 App 后 session 不继续运行）
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

**声音**：自动选择系统中音质最好的中文声音（Premium > Enhanced > 默认），设置里可换；缺少高质量声音时提示到「系统设置 → 辅助功能 → 朗读内容」下载。

**额度**：意图解析 / 问答 / 摘要都通过本机 `claude` 调用，占用 Claude 订阅额度（5 小时 / 7 天窗口），不额外计费；每次约 3.4k 输入 token（摘要 / 问答约 5.5k）、几十个输出 token。可在菜单关闭「回复摘要」减少占用。
