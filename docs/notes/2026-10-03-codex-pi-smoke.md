# Codex / pi 实测记录（v1.1）

- 日期：2026-10-03
- 机器：macOS 14（Darwin 23.6），Apple Silicon
- CLI：codex-cli 0.160.0（Homebrew npm 包 `@openai/codex`），pi 0.73.1（`@mariozechner/pi-coding-agent`），均在 `/opt/homebrew/bin`
- 模型：两者都配置为 OpenRouter 免费模型，提示词只用 "say hi" 一类；模型调用全部成功
- 方法：在 scratchpad 里用 Python `pty` + `pyte` 写的小工具交互启动 `codex` / `pi`（120×40），读取渲染后的屏幕与 OSC 标题，按时间截取。没有启动 CC Desk 本体：发现流程用 `LivePipelineTests`（与 App 轮询相同的核心逻辑，设 `CCDESK_LIVE_PIPELINE=1` 时运行）验证；屏幕规则用 `LiveScreenProbeTests` 验证，并把 pty 原始输出喂给无界面的 SwiftTerm `Terminal`，经与 App 相同的 `bottomText(of:)` 取底部一屏后再匹配。

## 1. 进程识别

`ps -axo pid=,ppid=,tty=,comm=` 与 `ps -axo pid=,args=` 分别执行、按 pid 合并（comm 路径可能含空格，必须在行尾）。

| agent | 实际进程 | 结论 |
|---|---|---|
| codex | `node /opt/homebrew/bin/codex`（包装）→ 子进程 `…/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex`（有 tty，comm 为完整路径）；另有无 tty 的 `~/.codex/packages/app-server-daemon/…/codex app-server --listen unix:// --managed-daemon` 与 `… daemon pid-update-loop` | 会话进程 = 带 tty、comm 末段为 `codex`、子命令不是 exec / app-server 等的原生进程；包装 node 进程不计 |
| pi | node 程序把 process.title 设为 `pi`，comm 与 args 都只显示 `pi` | comm 为 `pi` 即识别；`node …/pi` 形式也支持。命令行参数（如 `--session`）看不到 |

实测：两个内嵌风格的 pty 会话、一个 `codex -a on-request -s read-only`、以及用户自己在 Terminal.app 里运行的 codex 都被识别，Terminal 那个的宿主正确判为 Terminal（可跳转）。

进程 cwd 与启动时间用 libproc（`proc_pidinfo` 的 `PROC_PIDVNODEPATHINFO` / `PROC_PIDTBSDINFO`）读取，不起子进程，按 (pid, 启动时间) 缓存；与 `lsof -a -p <pid> -d cwd` 结果一致。

## 2. 会话文件与标题

- Codex：会话文件在**第一条消息提交后**才出现（文件名时间为进程启动时间）：`~/.codex/sessions/YYYY/MM/DD/rollout-<本地时间>-<uuid>.jsonl`。首行 `session_meta` 含 `session_id` / `id`、`cwd`、`timestamp`；交互式会话的 `source` 竟为 `"vscode"`、`originator` 为 `"codex-tui"`，exec 会话为 `"exec"` / `"codex_exec"`，所以不靠 source 过滤。用户消息是 `response_item` / `message` / `role: user`，其中以 `<` 开头的（`<environment_context>` 等）是注入块。会话文件由守护进程持有打开，TUI 进程本身不打开它，所以只能按 cwd + 启动时间配对（或命令行 `codex resume <id>`）。
- pi：`~/.pi/agent/sessions/--<cwd 把 / 换成 ->--/<ISO 时间>_<uuid>.jsonl`，同样在第一条消息后才写出。首行 `{"type":"session","id","timestamp","cwd"}`；`/name` 写 `session_info`。pi 扩展在 `session_start` 时就拿得到 session id，所以装了扩展后会话一启动就有 id。
- 标题：Codex 取第一条用户消息（Codex 的 OSC 标题里有它自动起的线程名，如 "Say hi"，存在 sqlite 里，未使用）；pi 取会话名，否则第一条用户消息。
- 实测配对结果：4 个运行中的会话全部配上正确的会话文件与标题；历史列表列出 codex 6 条、pi 3 条（含之前 `codex exec` 的会话）。
- 恢复：`codex resume <id>`、`pi --session <id>`（在原 cwd 下）均能载入原对话；恢复后的 codex 通过命令行参数、pi 通过扩展上报的 id 立即对应到原会话。

## 3. 屏幕规则（herdr codex.toml / pi.toml，原样打包）

| 场景 | 命中规则 | 结果 |
|---|---|---|
| codex 空闲 | `osc_title_idle`（标题 "Say hi \| codex"） | idle |
| codex 处理中 | `osc_title_working`（标题前缀 braille 转圈字符） | working |
| codex 等批准（命令批准对话框） | `osc_title_blocked`（标题 "[ . ] Action Required \| …"）；去掉标题后 `live_strong_blocker`（"press enter to confirm or esc to cancel"） | blocked → 等批准 |
| pi 空闲 | 无规则命中 → 空闲 | idle |
| pi 处理中 | `working_literal`（" ⠇ Working..."） | working |

SwiftTerm 的 `translateToString(trimRight: true)` 不会去掉程序显式写入的空格，导致行尾带空格；已在取屏时去掉行尾空白（规则里的 `$` / `\z` 依赖这一点）。

未覆盖：Codex 首次加载新 hook 时的「Hooks need review」对话框、目录信任对话框没有对应的等批准规则（herdr 清单里也没有），这两种情况屏幕上显示为空闲。

## 4. hook / 扩展（安装到真实的 ~/.codex 与 ~/.pi）

安装（`CodexIntegration` / `PiIntegration`，与「设置 → 集成」相同的代码）：

- `~/.codex/config.toml` 先备份为 `config.toml.cc-desk.bak`，只在末尾追加 `[features]` / `hooks = true`；文件权限保持 0600（发现并修复了原子写会把权限放宽为 0644 的问题）。
- `~/.codex/hooks.json` 原本不存在，由 CC Desk 新建，含 6 个事件条目，命令为 `/bin/sh '~/.cc-desk/hooks/codex-state.sh' <动作>`。
- `~/.pi/agent/extensions/cc-desk-state.ts` 新建。

观察到的信号：

- Codex 第一次启动时提示「Hooks need review：6 hooks are new or changed」，选 "Trust all and continue" 后 Codex 在 config.toml 里写入 `[hooks.state."…hooks.json:<event>:0:0"]` 信任记录，此后不再提示。
- **Codex 的 hook 在共享的 app-server 守护进程里执行**（父进程为 launchd 下的 daemon，无 tty，环境变量也来自守护进程）。最初按 tty 命名状态文件的方案因此失效；改为没有 tty 时写 `~/.cc-desk/state/codex-<session_id>.json`，App 按配对出的会话 id 取状态。stdin 里有 `session_id`、`transcript_path`、`cwd`、`hook_event_name`、`turn_id`。
- 一轮对话：`UserPromptSubmit` → working（约 0.5 秒内写出），`Stop` → idle。
- 批准：`PermissionRequest` → waiting，message 为 `Bash`；Codex 照常显示批准对话框（hook 不输出决定）。按 y 批准后 `PostToolUse` → working，结束时 `Stop` → idle，文件确实被写入。
- `SessionStart` 在交互式 TUI 里直到第一轮都没有触发，所以刚启动、还没发消息的外部 Codex 会话没有 hook 状态。
- pi：启动即写 `ttys0NN.json`（idle + session id，此时会话文件还不存在）；发送消息后 working，回复结束后 idle。恢复会话（新进程、新 tty）后按新 tty 写入，旧 tty 的文件因 pid / 时间不匹配被忽略。
- hook 脚本出错时静默 exit 0（单元测试覆盖无 tty、坏 JSON、未知动作）；没有观察到对 Codex / pi 运行的影响。

结论：两者的 hook 都工作正常，**保留安装**。备份 `~/.codex/config.toml.cc-desk.bak` 保留在原处。

## 5. 已知限制

- 外部 Codex 会话在第一轮之前、以及安装 hook 之前就已启动的外部会话：状态为「未知」（内嵌的由屏幕规则补上）。
- 同一目录同时开多个 Codex 会话、又都没有命令行会话 id 时，会话配对按启动时间推断，可能张冠李戴；内嵌 / 恢复的会话不受影响。
- Codex 恢复旧会话时，若恢复后还没有写入新内容，会话文件可能在 7 天以前的日期目录里；此时只能靠命令行里的 id（CC Desk 自己发出的恢复命令总是带 id）。
- pi 0.73.1 没有「需要确认」类事件，pi 不会出现「等批准」。
