import Foundation

// 以下两份屏幕规则清单原样取自 herdr（https://github.com/herdrdev/herdr，Apache License 2.0），
// 文件 src/detect/manifests/codex.toml 与 src/detect/manifests/pi.toml（herdr commit 07e3840b，2026-10-01）。
// 版权与许可见仓库根目录 NOTICE。更新时请整体替换并保留此说明。

public enum BundledManifests {
    public static let codexSource = #"""
id = "codex"
version = "2026.10.01.1"
min_engine_version = 3
updated_at = "2026-10-01T00:00:00Z"

[[rules]]
id = "osc_title_blocked"
state = "blocked"
priority = 1100
region = "osc_title"
visible_blocker = true
contains = ["Action Required"]

[[rules]]
id = "osc_title_working"
state = "working"
priority = 1050
region = "osc_title"
visible_working = true
regex = ['(?:^| )[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏](?: |$)']

[[rules]]
id = "transcript_viewer"
state = "unknown"
priority = 1000
region = "after_last_prompt_marker"
skip_state_update = true
contains = ["↑/↓ to scroll", "pgup/pgdn to", "home/end to jump", "q to quit"]
any = [
  { contains = ["esc to edit prev"] },
  { contains = ["esc/← to edit prev"] },
]

[[rules]]
id = "trust_directory"
state = "blocked"
priority = 950
region = "top_non_empty_lines(20)"
visible_blocker = true
all = [
  { any = [
    { regex = ['\A> You are in [^\r\n]+(?:\r?\n|$)'] },
    { contains = ["Folder access"] },
  ] },
  { any = [
    { regex = ['(?s)Do\s+you\s+trust\s+the\s+contents\s+of\s+this\s+directory\?'] },
    { all = [
      { contains = ["Trust this folder?", "Codex can read, edit, and run files here"] },
      { any = [
        { contains = ["Trust and continue"] },
        { contains = ["enter continue"] },
      ] },
    ] },
  ] },
]

[[rules]]
id = "startup_update"
state = "blocked"
priority = 950
region = "bottom_non_empty_lines(20)"
visible_blocker = true
contains = ["Update available!", "Update now"]
regex = ['Skip\s+until\s+next\s+version', 'Press enter to continue\s*\z']

[[rules]]
id = "live_strong_blocker"
state = "blocked"
priority = 900
region = "after_last_prompt_marker"
visible_blocker = true
any = [
  { contains = ["press enter to confirm or esc to cancel"] },
  { contains = ["enter to submit answer"] },
  { contains = ["enter to submit all"] },
  { contains = ["allow command?"] },
  { contains = ["All Results", "Filesystem Only", "Plugins"] },
]

[[rules]]
id = "weak_blocker"
state = "blocked"
priority = 600
region = "whole_recent_without_current_prompt_marker"
# Sparkles can replace the space after ›. A later response marker makes that prompt stale.
not = [{ regex = ['(?m)^›[⠁⠂⠄⠈⠐⠠⡀⢀][^\n]*(?:\n(?:[^•■✗✓\n][^\n]*)?)*\z'] }]
any = [
  { contains = ["[y/n]"] },
  { contains = ["yes (y)"] },
  { contains = ["do you want to"], any = [{ contains = ["yes"] }, { contains = ["❯"] }] },
  { contains = ["would you like to"], any = [{ contains = ["yes"] }, { contains = ["❯"] }] },
]

[[rules]]
id = "screen_working_fallback"
state = "working"
priority = 500
region = "before_current_prompt_marker"
visible_working = true
# Support animated and reduced-motion status, including dynamic activity labels.
# The interrupt hint can be remapped, unbound, or hidden, and queued inputs can
# sit below the status. Require the live timer suffix with no later response.
any = [{ contains = [" to interrupt)"] }, { contains = ["s)"] }]
regex = ['(?m)^(?:[•◦][ \t]+)?[^\s›•◦■✗✓─][^\r\n]* \((?:[0-9]+[hm] )*[0-9]+s(?: • [^\r\n]+? to interrupt)?\)(?: · [^\r\n]*)?(?:\r?\n(?:[^•◦›■✗✓─\r\n][^\r\n]*|•[ \t]+(?:Queued\s+follow-up\s+inputs|Messages\s+to\s+be\s+submitted\s+after\s+next\s+tool\s+call(?:\s+\(press\s+[^\r\n]+?\s+to\s+interrupt\s+and\s+send\s+immediately\))?|Messages\s+to\s+be\s+submitted\s+at\s+end\s+of\s+turn)|›[⠁⠂⠄⠈⠐⠠⡀⢀][^\r\n]*)?)*\s*\z']
# A failed reconnect keeps its final elapsed timer but is no longer working.
not = [{ line_regex = ['^(?:[•◦][ \t]+)?Reconnect failed — check the endpoint, then relaunch \([0-9hms ]+\)$'] }]

[[rules]]
id = "osc_title_idle"
state = "idle"
priority = 100
region = "osc_title"
visible_idle = true
regex = ['\S']
not = [
  { regex = ['(?:^| )[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏](?: |$)'] },
  { contains = ["Action Required"] },
]
"""#

    public static let piSource = #"""
id = "pi"
version = "2026.10.01.1"
min_engine_version = 1
updated_at = "2026-10-01T00:00:00Z"
aliases = ["herdr:pi"]

[[rules]]
id = "working_literal"
state = "working"
priority = 100
region = "whole_recent"
visible_working = true
any = [
  { contains = ["Working..."] },
  { line_regex = ['^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] Working$'] },
]

[[rules]]
id = "working_border"
state = "working"
priority = 100
region = "bottom_non_empty_lines(12)"
visible_working = true
any = [
  { line_regex = ['^── [⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] Working ─+$'] },
  { line_regex = ['^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] Working$'] },
]
"""#

    /// OpenCode：取自 herdr 的 opencode.toml（实测 opencode 1.18.35：处理中底栏是进度条 `⬝⬝⬝■■` 与「esc interrupt」，
    /// 等批准是「△ Permission required」+「Allow once / Allow always / Reject」，空闲时都没有）。
    public static let openCodeSource = #"""
id = "opencode"
version = "2026.06.10.1"
min_engine_version = 1
updated_at = "2026-06-10T00:00:00Z"
aliases = ["open-code", "herdr:opencode"]

[[rules]]
id = "permission_required"
state = "blocked"
priority = 300
region = "whole_recent"
visible_blocker = true
any = [
  { contains = ["△ Permission required"] },
  { contains = ["esc dismiss"], any = [{ contains = ["enter confirm"] }, { contains = ["enter submit"] }, { contains = ["enter toggle"] }], all = [{ any = [{ contains = ["↑↓ select"] }, { contains = ["⇆ tab"] }] }] },
]

[[rules]]
id = "interrupt_hint_working"
state = "working"
priority = 110
region = "whole_recent"
visible_working = true
any = [
  { contains = ["esc to interrupt"] },
  { contains = ["esc interrupt"] },
  { contains = ["ctrl+c to interrupt"] },
  { contains = ["press esc to interrupt"] },
  { line_regex = ['(?i).*opencode.*esc (again to )?interrupt'] },
]

[[rules]]
id = "progress_bar_working"
state = "working"
priority = 100
region = "whole_recent"
visible_working = true
regex = ['(■|⬝){4,}']
"""#

    /// 解析后的清单；解析失败时为 nil（屏幕检测随之关闭，不影响其他状态来源）。
    public static let codex: DetectionManifest? = try? DetectionManifest.parse(codexSource)
    public static let pi: DetectionManifest? = try? DetectionManifest.parse(piSource)
    public static let openCode: DetectionManifest? = try? DetectionManifest.parse(openCodeSource)

    public static func manifest(for kind: AgentKind) -> DetectionManifest? {
        switch kind {
        case .codex: return codex
        case .pi: return pi
        case .opencode: return openCode
        case .claude, .other: return nil
        }
    }
}
