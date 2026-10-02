# 验证门：SwiftTerm 中运行 Claude Code（Task 2）

- 日期：2026-10-02
- 环境：macOS 14（Darwin 23.6）、Swift 6.0.3、SwiftTerm 1.20.0、Claude Code 2.1.280
- 结论：**通过**，继续实现。

| # | 项目 | 结果 |
|---|---|---|
| 1 | 运行 `claude`，界面、颜色、输入框 | 通过 |
| 2 | 中文输入法输入并提交 | 通过 |
| 3 | 权限对话框显示与方向键 / 回车选择 | 通过（需先 Shift+Tab 关闭 auto mode 才会出现） |
| 4 | ⌘C / ⌘V 复制粘贴 | 通过 |
| 5 | 滚轮回看历史（出现 "Jump to bottom"） | 通过 |
| 6 | 窗口缩放后重新排版 | 通过 |
| 7 | 登记文件状态变化 | 通过，见下 |

## 登记文件观测（pid 6865，`~/.claude/sessions/6865.json`，0.3s 轮询）

```
15:12:32 busy
15:12:40 idle
15:13:13 busy
15:13:17 waiting  waitingFor="permission prompt"   # 权限确认
15:13:33 busy
15:13:35 idle
15:13:50 busy
15:13:54 waiting  waitingFor="input needed"        # AskUserQuestion
15:14:13 busy
15:14:22 idle
```

- 状态变化在 1 秒内写入，满足「3 秒内反映」的目标。
- 内嵌 session 的 tty 为 `ttys012`，进程链：claude → zsh → CCDesk，验证了按 tty 识别内嵌 session 的设计。
- 窗口标题随 Claude 状态变化（✳ 前缀），v1 不使用，可作为 v1.1 的辅助信号。
