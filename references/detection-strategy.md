# Detection Strategy Details

## How JSONL Analysis Works

Claude Code writes session logs to `~\.claude\projects\<workspace>\<uuid>.jsonl`. Each line is a JSON object.

### Key message types

| type | Meaning |
|------|---------|
| `assistant` | Claude's response, contains `stop_reason` and `content` array |
| `user` | User input or tool result |
| `system` | System-level message (API errors, interrupts) |
| `mode` | Mode change events |
| `permission-mode` | Permission mode change |

### stop_reason values

| stop_reason | Meaning |
|-------------|---------|
| `end_turn` | Normal completion, Claude is waiting for user |
| `tool_use` | Claude wants to use a tool, waiting for approval |
| `stop_sequence` | Hit a stop sequence or API error |

### Never-approve list (safety)

| Tool | Why skipped |
|------|-------------|
| `Edit`, `Write` | Auto-approved by Claude Code's default `acceptEdits` mode |
| `AskUserQuestion` | Claude is asking the **user** for a decision — auto-Enter silently picks the default option on the user's behalf. Skipped in BOTH primary detection and idle fallback. |

### Detection walkthrough

The script reads the last 30 lines of the latest JSONL file and walks backwards:

1. Skip noise: `system`, `mode`, `permission-mode`, `file-history-snapshot`, `last-prompt`
2. If we hit `user` → Claude already got a response (tool result or user message), not waiting
3. If we hit `assistant` with `stop_reason: "end_turn"` → normal end, nothing to approve
4. If we hit `assistant` with `stop_reason: "tool_use"` → check tool name:
   - `Edit`, `Write` → auto-approved by Claude Code's default `acceptEdits` mode, skip
   - `Bash`, `WebSearch`, `WebFetch`, `BashOutput`, `Read`, `Glob`, `Grep`, etc. → needs approval!

### Why tool_use might not appear

Some scenarios where JSONL doesn't show tool_use:
- Claude generated a system message (API error) instead of tool_use
- Claude Code's terminal prompt is shown but session wasn't saved yet
- Claude is in plan mode, approval is shown before tool execution

## Process Idle Fallback

### How it works

1. Check if any `claude.exe` process has CPU delta > 0.15s over 2 seconds
2. If all idle + JSONL stale > 120s → possible approval prompt
3. **Constraint**: Only fires if session has 0 prior failures (first attempt only)
4. After Enter sent: wait 12s, verify JSONL was updated

### Why it's rate-limited

Without constraints, idle Claude at main prompt would trigger Enter every cycle → infinite false approvals. The "only fire once" rule makes it a one-shot safety net.

## Circuit Breaker

```
Session state tracking (per JSONL session ID):

failedCount=0  → fallback available
failedCount=1  → only JSONL detection works
failedCount=2  → only JSONL detection works
failedCount=3  → SESSION BLOCKED for 10 minutes
                → any detection (JSONL or fallback) is skipped
```

After 3 consecutive `Enter` sends where JSONL didn't update within 12s, the session is blocked. This means:
- Claude is hung/crashed → Enter won't help → block is correct
- PyCharm window not found → block is correct (will need manual intervention)
- Claude at main prompt, not approval → Enter does nothing → block prevents spamming

### Unblocking

Remove the session from state file or delete the entire state file to reset all blockers.

## Platform-specific

**Windows only**: Uses WinAPI `SendKeys.SendWait` + `SetForegroundWindow`. Targets `pycharm64` or `pycharm` process by name.

**macOS/Linux**: Not supported. Would need `osascript`/`xdotool` equivalents.
