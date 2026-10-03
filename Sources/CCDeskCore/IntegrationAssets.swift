import Foundation

// Codex hook 脚本与 pi 扩展的内容。事件映射参考 herdr（Apache-2.0）的
// src/integration/assets/codex/herdr-agent-state.sh 与 src/integration/assets/pi/herdr-agent-state.ts，
// 但改为写 CC Desk 的状态文件 `~/.cc-desk/state/<tty>.json`（设计 §4.4），不含 herdr 的 socket 通信。

public enum IntegrationAssets {
    /// 安装文件里的标记行，用于识别 CC Desk 写入的文件 / 条目。
    public static let marker = "CC_DESK_INTEGRATION"
    public static let version = 1

    /// Codex hook：`codex-state.sh <session|working|waiting|idle>`，stdin 为 Codex 的 hook JSON。
    /// 纯 POSIX sh（不依赖 python / jq），任何错误都静默 exit 0。
    public static let codexHookScript = #"""
#!/bin/sh
# CC Desk: Codex status hook. Installed and managed by CC Desk; reinstalling overwrites this file.
# CC_DESK_INTEGRATION=codex
# CC_DESK_INTEGRATION_VERSION=1
# Usage: codex-state.sh <session|working|waiting|idle>  (Codex hook JSON on stdin)
# Writes ~/.cc-desk/state/<tty>.json atomically. Always exits 0 silently.

action="${1:-}"
input="$(cat 2>/dev/null)" || input=""

main() {
  case "$action" in session|working|waiting|idle) ;; *) return 0 ;; esac

  flat="$(printf '%s' "$input" | tr '\n\r' '  ')"
  # Value of a top-level string field, still JSON-escaped (safe to embed in JSON as-is).
  field() {
    printf '%s' "$flat" | sed -nE "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*/\1/p" | head -n 1
  }
  esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'; }

  event="$(field hook_event_name)"
  case "$action:$event" in
    session:SessionStart|session:) status=idle ;;
    working:UserPromptSubmit|working:PostToolUse|working:) status=working ;;
    waiting:PermissionRequest|waiting:) status=waiting ;;
    idle:Stop|idle:Interrupt|idle:) status=idle ;;
    *) return 0 ;;
  esac

  sid="$(field session_id)"
  cwd="$(field cwd)"
  [ -n "$cwd" ] || cwd="$(esc "$PWD")"
  message=""
  if [ "$status" = waiting ]; then
    tool="$(field tool_name)"
    message="$tool"
  fi

  # Walk up the parent chain: first process with a tty, and the codex process itself.
  tty=""
  agent_pid=""
  pid="$PPID"
  n=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$n" -lt 25 ]; do
    line="$(ps -o ppid= -o tty= -o comm= -p "$pid" 2>/dev/null)" || break
    [ -n "$line" ] || break
    set -- $line
    ppid="$1"
    t="${2:-}"
    shift 2 2>/dev/null || break
    comm="$*"
    if [ -z "$tty" ] && [ -n "$t" ] && [ "$t" != "??" ] && [ "$t" != "?" ]; then tty="$t"; fi
    if [ -z "$agent_pid" ]; then
      case "$comm" in codex|*/codex) agent_pid="$pid" ;; esac
    fi
    if [ -n "$tty" ] && [ -n "$agent_pid" ]; then break; fi
    pid="$ppid"
    n=$((n + 1))
  done
  [ -n "$tty" ] || return 0
  [ -n "$agent_pid" ] || agent_pid="$PPID"

  ts="$(perl -MTime::HiRes=time -e 'printf("%d", time()*1000)' 2>/dev/null)"
  [ -n "$ts" ] || ts="$(( $(date +%s) * 1000 ))"

  dir="$HOME/.cc-desk/state"
  mkdir -p "$dir" 2>/dev/null || return 0
  tmp="$dir/.$tty.$$.tmp"
  printf '{"agent":"codex","session_id":"%s","tty":"%s","pid":%s,"cwd":"%s","status":"%s","message":"%s","ts":%s}\n' \
    "$sid" "$tty" "$agent_pid" "$cwd" "$status" "$message" "$ts" >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  mv -f "$tmp" "$dir/$tty.json" 2>/dev/null || rm -f "$tmp"
}

main >/dev/null 2>&1
exit 0
"""#

    /// pi 扩展：监听 session_start / agent_start / agent_end，写状态文件。只在交互式 TUI（hasUI）中启用。
    public static let piExtension = #"""
// CC Desk: pi status extension. Installed and managed by CC Desk; reinstalling overwrites this file.
// CC_DESK_INTEGRATION=pi
// CC_DESK_INTEGRATION_VERSION=1
// Writes ~/.cc-desk/state/<tty>.json atomically. Never throws.
// @ts-nocheck

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

const stateDir = path.join(os.homedir(), ".cc-desk", "state");
let cachedTTY: string | null | undefined;

function findTTY(): string | null {
  if (cachedTTY !== undefined) return cachedTTY;
  cachedTTY = null;
  try {
    let pid = process.pid;
    for (let i = 0; i < 25 && pid > 1; i++) {
      const out = execFileSync("/bin/ps", ["-o", "ppid=", "-o", "tty=", "-p", String(pid)], {
        encoding: "utf8",
        timeout: 1000,
      }).trim();
      const [ppid, tty] = out.split(/\s+/);
      if (tty && tty !== "??" && tty !== "?") {
        cachedTTY = tty;
        break;
      }
      pid = Number(ppid);
      if (!Number.isFinite(pid)) break;
    }
  } catch {}
  return cachedTTY;
}

function writeState(fields: Record<string, unknown>): void {
  try {
    const tty = findTTY();
    if (!tty) return;
    fs.mkdirSync(stateDir, { recursive: true });
    const body = JSON.stringify({ agent: "pi", tty, pid: process.pid, ts: Date.now(), ...fields }) + "\n";
    const tmp = path.join(stateDir, `.${tty}.${process.pid}.tmp`);
    fs.writeFileSync(tmp, body);
    fs.renameSync(tmp, path.join(stateDir, `${tty}.json`));
  } catch {}
}

export default function (pi) {
  let enabled = false;
  let sessionId: string | undefined;
  let cwd: string | undefined;

  function refresh(ctx: any): void {
    try {
      const id = ctx?.sessionManager?.getSessionId?.();
      if (typeof id === "string" && id.length > 0) sessionId = id;
    } catch {}
    try {
      if (typeof ctx?.cwd === "string") cwd = ctx.cwd;
    } catch {}
  }

  function report(status: "working" | "waiting" | "idle", message?: string): void {
    if (!enabled) return;
    writeState({ session_id: sessionId ?? "", cwd: cwd ?? process.cwd(), status, message: message ?? "" });
  }

  try {
    pi.on("session_start", async (_event, ctx) => {
      try {
        // print / json / rpc 模式没有可显示的终端（rpc 也可能报告 hasUI，故再看 stdout 是否为 tty）。
        if (ctx?.hasUI === false || !process.stdout.isTTY) return;
        enabled = true;
        refresh(ctx);
        report(ctx?.isIdle?.() === false ? "working" : "idle");
      } catch {}
    });

    pi.on("agent_start", (_event, ctx) => {
      try {
        refresh(ctx);
        report("working");
      } catch {}
    });

    pi.on("agent_end", (_event, ctx) => {
      try {
        refresh(ctx);
        report("idle");
      } catch {}
    });
  } catch {}
}
"""#
}
