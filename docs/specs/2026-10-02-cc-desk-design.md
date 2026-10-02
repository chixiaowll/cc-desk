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

1. 本机所有正在运行的 Claude Code / Codex / pi session（无论在哪启动）都出现在左边栏，3 秒内反映状态变化。
2. 在 CC Desk 内新建、切换、使用 agent session，体验与在 Terminal.app 中基本一致（中文输入、复制粘贴、滚动、agent 全屏 TUI 正常）。
3. session 进入「等批准」或「本轮完成」时收到系统通知，点击通知跳到该 session。
4. 外部 session 可以一键接管到 CC Desk 中继续（对话上下文不丢）。
5. 退出 App 后重新打开，上次的内嵌 session 自动恢复。

### 非目标（v1 不做）

- 后台守护进程（关闭 App 后 session 不继续运行）
- 右侧分屏 / 同时显示多个终端
- 手机端、远程机器
- 搜索、分组、标签
- 在 App 内读写 agent 对话记录（除恢复所需的 session id 外）

## 2. 支持范围

| Agent | 启动 | 恢复 | 状态来源 |
|---|---|---|---|
| Claude Code | `claude` | `claude --resume <id>` | hook + `~/.claude/sessions` 登记文件 + 屏幕规则 |
| Codex | `codex` | `codex resume <id>` | hook（`~/.codex/hooks.json`）+ 屏幕规则 |
| pi | `pi` | 实现前验证（见 §9） | 扩展（`~/.pi/agent/extensions/`）+ 屏幕规则 |
| 其他命令 | 任意 shell 命令 | 不支持 | 仅「运行中 / 已退出」 |

新增 agent 只需新增一个适配器（§4.3），不改其他模块。

## 3. 界面

```
┌─ CC Desk ───────────────────────────────────────────────────────────┐
│ SESSIONS            [+] │ 旅行攻略 · Claude · ~/work/project/旅行攻略  │
│ ▲ 旅行攻略    等批准  2m │ ┌─────────────────────────────────────────┐ │
│ ● herdr       处理中 now │ │                                         │ │
│ ● api [Codex] 处理中  5m │ │           内嵌终端（SwiftTerm）          │ │
│ ○ tmp         空闲    1h │ │                                         │ │
│ ── 外部 ──────────────── │ │                                         │ │
│ ○ 读书笔记 [Terminal] 7d │ │                                         │ │
│ ○ algo-rec…  [VS Code] 3h│ └─────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

### 3.1 左边栏

- 分两组：**内嵌**（CC Desk 自己运行的）在上，**外部**（Terminal.app / VS Code / 其他）在下。
- 每行：状态图标、名称、agent 类型（Claude 以外才显示）、状态文字、距上次状态变化的时间；第二行为项目路径（`~` 缩写）。等批准时第二行改为通知原文（截断）。
- 状态图标：`▲` 等批准（橙）、`●` 处理中（蓝）、`○` 空闲（灰）、`?` 未知（灰）。超过 24 小时未变化的行整体变灰。
- 名称：优先用 agent 提供的名称；若是自动生成的无意义名称（如 `claude-88`），改用目录名。
- 组内排序：等批准 > 处理中 > 空闲 > 未知，同类按最近变化时间倒序。
- `[+]`：弹出新建面板，选择目录（默认最近使用的目录）和 agent 类型，回车创建。

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
hook/扩展 ─▶ HookStateReader   ~/.cc-desk/state/*.json   │
登记文件  ─▶ RegistryReader    ~/.claude/sessions/*.json │──▶ SessionStore ──▶ SidebarView
进程表    ─▶ ProcessScanner    ps（agent 进程 + tty）     │        │           Notifier
屏幕      ─▶ ScreenDetector    内嵌终端底部缓冲区          │        │           DockBadge
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

各来源独立产出 `(tty/pid, status, timestamp)`，`SessionStore` 按优先级合并：

1. **hook / 扩展**（最准确）：agent 主动上报。
2. **屏幕规则**（仅内嵌）：读内嵌终端底部若干行匹配规则。
3. **登记文件**（仅 Claude）：`~/.claude/sessions/<pid>.json` 的 `status`（busy / idle）。
4. **进程扫描**：只能得出 `unknown`（存在）或消失。

合并规则：取**时间戳最新**的高优先级来源；若高优先级来源超过 10 分钟没有更新而低优先级来源有更新，使用低优先级来源（防止 hook 漏报导致状态卡住）。

session 的**存在性**由进程决定：进程不在了就从列表移除，无论其他来源说什么。

**更新机制**：
- `~/.cc-desk/state/` 和 `~/.claude/sessions/` 用 FSEvents 监听，变化即刷新。
- 进程扫描每 3 秒一次（`ps -axo pid,ppid,tty,comm,args`），用于发现新 session、确认存活。
- 屏幕检测在内嵌终端有输出时节流触发（同一终端最多每 500ms 一次），只读底部缓冲区，不读用户滚动位置。

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

v1 实现 `ClaudeAdapter`、`CodexAdapter`、`PiAdapter`、`GenericAdapter`。

### 4.4 Hook / 扩展

所有 hook 写同一种状态文件 `~/.cc-desk/state/<tty>.json`：

```json
{ "agent": "codex", "session_id": "…", "tty": "ttys007", "pid": 12345,
  "cwd": "/…", "status": "waiting", "message": "allow command?", "ts": 1790922468588 }
```

- 文件以 tty 命名，同一终端换了 agent 会自然覆盖。
- 写入方式：先写临时文件再 rename，避免读到半截内容。
- hook 脚本自身失败一律静默退出（exit 0），绝不影响 agent 运行。
- tty 取法：hook 进程的父进程链上第一个有 tty 的进程（`ps -o tty= -p $PPID` 起逐级向上）。

| Agent | 安装位置 | 事件 → 状态 |
|---|---|---|
| Claude Code | `~/.claude/settings.json` 的 `hooks`（追加，不改动已有的 rtk hook） | `UserPromptSubmit` → working；`Notification` → waiting（带 message）；`Stop` → idle |
| Codex | `~/.codex/hooks.json` | `UserPromptSubmit` → working；`Stop` / `Interrupt` → idle；等批准靠屏幕规则 |
| pi | `~/.pi/agent/extensions/cc-desk-state.ts` | 扩展内监听 agent 开始 / 结束 / 需要确认事件 |

**安装流程**：首次启动时在设置页列出可安装的 hook，用户逐个点「安装」。安装前备份原配置文件（`*.cc-desk.bak`），修改用结构化 JSON 合并而非字符串拼接；提供「卸载」按钮，只移除 CC Desk 自己添加的条目。hook 脚本放在 `~/.cc-desk/hooks/`，配置中通过绝对路径引用。

### 4.5 屏幕检测

- 复用 herdr（Apache-2.0）的 `src/detect/manifests/{claude,codex,pi}.toml`，随 App 打包，在 `NOTICE` 中注明来源与许可。
- v1 用 Swift 实现规则引擎的子集：区域 `bottom_non_empty_lines(N)`、`whole_recent`、`after_last_prompt_marker`、`osc_title`；匹配 `contains`、`regex`、`line_regex`、`any`、`all`；按 `priority` 取最高命中规则。不支持的区域或字段：跳过该规则并记录日志，不报错。
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
| hook 未安装 | 左边栏仍能显示（登记文件 / 屏幕 / 进程），设置页提示「安装 hook 可识别等批准状态」 |
| 自动化权限被拒 | 外部跳转失败时显示提示条，附打开系统设置的按钮 |
| 恢复命令执行失败（session 已不存在） | 终端里会显示 agent 的报错，保留 shell；左边栏标记为普通终端 |
| App 崩溃 | 依赖周期性（每 30 秒及每次增删 session 时）写入的 `workspace.json` 恢复 |

## 7. 项目结构

```
cc-desk/
├── CCDesk.xcodeproj    # 通知、自动化权限需要 App bundle，用 Xcode 工程；SwiftTerm 经 SPM 引入
├── Sources/CCDesk/
│   ├── App/            # 入口、窗口、菜单、设置页
│   ├── Model/          # AgentSession、AgentStatus、SessionHost
│   ├── Store/          # SessionStore（合并逻辑）
│   ├── Sources/        # HookStateReader、RegistryReader、ProcessScanner
│   ├── Detect/         # 规则引擎 + manifest 解析
│   ├── Agents/         # ClaudeAdapter、CodexAdapter、PiAdapter、GenericAdapter
│   ├── Terminal/       # TerminalPool、TerminalView 封装
│   ├── Integration/    # HookInstaller、Jumper、Notifier、Restorer
│   └── UI/             # SidebarView、行视图、新建面板
├── Resources/
│   ├── hooks/          # cc-desk-hook.sh、pi 扩展 .ts
│   └── manifests/      # 来自 herdr 的 toml 规则
├── Tests/CCDeskTests/  # 合并逻辑、规则引擎、适配器、HookInstaller 的单元测试
└── NOTICE
```

`SessionStore`、规则引擎、适配器、HookInstaller 不依赖 UI，可以单独测试。

## 8. 测试与验证

**单元测试**（`swift test`）：
- SessionStore 合并：来源优先级、过期回退、进程消失移除、tty 归并。
- 规则引擎：解析、区域截取、AND/OR、优先级、未知字段跳过。
- HookInstaller：在临时 HOME 下对已有配置（含 rtk hook）安装、重复安装幂等、卸载只移除自己的条目、备份生成。
- 登记文件 / 状态文件解析：缺字段、坏 JSON。

**实测清单**（每个 agent 记录版本号和结果）：
- Claude Code / Codex / pi 分别在内嵌终端中：启动、处理中、等批准、空闲、退出、恢复。
- 在 Terminal.app 中启动的同类 session：出现在外部组、状态正确、跳转、接管。
- 终端体验：中文输入法、⌘C/⌘V、滚动回看、agent 全屏界面、窗口缩放。
- 通知：前台不通知、后台通知、点击跳转、刚启动不误报。
- 退出确认与重启恢复。

## 9. 实现前需验证的事项

按实现顺序排在最前面，任一项不成立需回到设计调整：

1. **SwiftTerm 跑 agent 的体验**：在最小 Demo 中运行 `claude`、`codex`、`pi`，确认显示、中文输入、快捷键正常。这是整个方案的前提。
2. **Codex hook 的事件名与载荷**：以当前 Codex 版本实际验证 `~/.codex/hooks.json` 格式及 `UserPromptSubmit` / `Stop` 事件（参考 herdr `src/integration/assets/codex/`）。
3. **pi 的恢复命令与扩展事件**：确认 pi 恢复指定会话的方式和扩展 API（参考 herdr `src/integration/assets/pi/herdr-agent-state.ts`）。若无法按 id 恢复，pi 的接管 / 重启恢复改为「在原目录重新启动 pi」。
4. **Terminal.app AppleScript 按 tty 定位**：在当前 macOS 版本验证。
5. 本机需先安装 codex 和 pi。

## 10. 后续方向（不在 v1）

- 后台守护进程持有终端，关闭窗口 session 继续运行（届时 App 拆为服务 + 界面）。
- 右侧分屏、多终端同屏。
- 只读对话预览（读 agent 的 jsonl 记录）。
- 语音输入：按住快捷键说话，松开后把识别文字通过 `TerminalInputSink` 写入当前 session（先填入不回车，确认后再发送）。识别引擎可选系统 Speech 框架（支持中文、可离线）或本地 Whisper；只需新增一个输入模块，不改终端和状态逻辑。
- 手机端：在守护进程上加网络接口 + 手机网页。
- 接入 herdr 全部 22 份屏幕规则，扩展支持更多 agent。
- 搜索、分组、按项目归类。
