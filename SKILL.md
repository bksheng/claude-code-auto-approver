---
name: claude-code-auto-approver
description: 在 PyCharm 终端中自动批准 Claude Code 的权限请求。适用于用户需要无人值守执行 Claude Code 的场景 —— 通过向 PyCharm 窗口发送 Enter 键自动批准 Bash/Browser/API 等工具请求。涵盖部署、定时监控任务创建、状态检查、停止与调优。触发词："auto approve Claude Code"、"无人值守 Claude Code"、"自动审批 Claude"、"Claude Code stuck on approval"、"claude code 卡审批"
---

# Claude Code 自动审批（v4.2）

通过在 PyCharm 终端中发送 `Enter` 键自动批准 Claude Code 的权限提示（选中推荐/默认选项）。

## 架构

```
┌─────────────┐     ┌──────────────────┐     ┌──────────────┐
│  Cron 任务   │ ──▶ │  monitor.ps1     │ ──▶ │  PyCharm     │
│  (30-60s)   │     │  检测→验证       │     │  终端        │
└─────────────┘     └──────────────────┘     └──────────────┘
                           │
                           ▼
                    ┌──────────────┐
                    │ Report .md   │
                    └──────────────┘
```

## 路径约定

本文中 `<claw-home>` 为 **claw 类运行时数据目录名的占位符**——实际目录名因产品而异（形如 `~\.clawXXX`），部署前请全文替换。路径前缀 `~\`（通用）、`$env:USERPROFILE\`（PowerShell）、`%USERPROFILE%\`（任务计划程序参数，系统自动展开）均表示当前用户主目录，不依赖具体用户名。

## 部署

### 1. 部署监控脚本

将 `scripts/monitor.ps1` 复制到 `~\<claw-home>\scripts\claude-auto-approve.ps1`：

```powershell
Copy-Item "scripts/monitor.ps1" "$env:USERPROFILE\<claw-home>\scripts\claude-auto-approve.ps1"
```

### 2. 创建定时任务

**方案 A（OpenClaw）：** 使用 OpenClaw 内置的 `cron` 工具：

```
cron add
  name: "Claude Code 自动审批"
  schedule: { kind: "every", everyMs: 30000 }
  sessionTarget: "isolated"
  payload: {
    kind: "agentTurn",
    message: "Run: powershell -ExecutionPolicy Bypass -File ~\<claw-home>\scripts\claude-auto-approve.ps1\nReport briefly if any approval was handled. Do NOT use message tool."
  }
  delivery: { mode: "none" }
```

**方案 B（Windows 任务计划程序 —— OpenClaw 未运行时的首选）：**
OpenClaw 未运行时用系统计划任务替代，独立于任何 agent 环境，更可靠：

```powershell
# 每 1 分钟运行一次，365 天循环（任务计划程序最小间隔为 1 分钟，无法用 30 秒）
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%USERPROFILE%\<claw-home>\scripts\claude-auto-approve.ps1"'
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 365)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -StartWhenAvailable
Register-ScheduledTask -TaskName "ClaudeCodeAutoApprover" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
```

⚠️ 坑点：
- `[TimeSpan]::MaxValue` 作 Duration 会报错 `0x80041318`，用 `(New-TimeSpan -Days 365)` 代替
- 任务必须以 **Interactive** 登录类型、当前用户身份运行（脚本要操作 UI/SendKeys），不能用 SYSTEM
- 停用：`Unregister-ScheduledTask -TaskName "ClaudeCodeAutoApprover" -Confirm:$false`
- 状态：`Get-ScheduledTaskInfo -TaskName "ClaudeCodeAutoApprover"`（LastTaskResult 0 = 成功，267009 = 刚启动尚未完成）

推荐间隔：30-60 秒（任务计划程序最低 1 分钟）。

### 3. 验证

手动运行一次确认工作正常：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\<claw-home>\scripts\claude-auto-approve.ps1"
```

### 4. 用 Dry-Run 诊断（无副作用）

v4.2+ 支持 dry-run 模式：只报告"会发生什么"，不实际发送任何按键。用于对照当前会话检查检测逻辑是否正确：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\<claw-home>\scripts\claude-auto-approve.ps1" -DryRun
# 输出: DryRun verdict: NO-ACTION | idle=2176s | conclusive=True
#        DryRun verdict: WOULD-APPROVE (Bash) | idle=45s | conclusive=True
```

- `NO-ACTION` + `conclusive=True` → 会话已完成（end_turn/user），正确空闲
- `WOULD-APPROVE (X)` → 检测到待批准的 tool 请求，正常情况下会发送 Enter
- `conclusive=False` → 检测不明确（如解析失败）；只有这种情形下 idle 兜底检测才可能触发

## 检测策略

完整细节见 [references/detection-strategy.md](references/detection-strategy.md)。

**两级检测：**

| 级别 | 方法 | 触发条件 |
|------|--------|---------|
| **主检测** | JSONL 分析（UTF-8 读取）—— 检查最后一条 assistant 消息的 `stop_reason: "tool_use"`，且工具不在跳过列表中（Edit/Write 由 Claude 自动批准；AskUserQuestion 绝不自动批准） | JSONL 空闲 ≥45s |
| **兜底检测** | 进程空闲兜底 —— 所有 claude.exe 进程空闲 + JSONL 停滞 ≥120s | 仅当本会话无先前失败记录时触发；若最后一条是 AskUserQuestion 则拒绝触发 |

**断路器：** 连续 3 次发送 Enter 无效（20s 内 JSONL 未变化），该会话将被阻断 10 分钟不再尝试。防止 Claude 挂起/崩溃与"确实在等审批"两种情况被无限循环误操作。

**安全护栏（关键）：** `$NEVER_APPROVE` 中的工具绝不自动批准 —— 目前为 `AskUserQuestion`。Claude Code 用它向**用户**征询决策；自动 Enter 会在用户不知情的情况下替用户选中默认选项（例如确认破坏性操作）。主检测与兜底检测都会检查该列表。

## 状态检查

### 审批记录

```powershell
Get-Content "$env:USERPROFILE\<claw-home>\reports\claude-approvals.md"
```

### 会话阻断状态

```powershell
Get-Content "$env:USERPROFILE\<claw-home>\scripts\claude-approver-state.json" | ConvertFrom-Json
```

### 解除被阻断的会话

```powershell
# PS 5.1 兼容写法：-AsHashtable 仅 PS6+ 支持，用这个代替
$state = Get-Content "$env:USERPROFILE\<claw-home>\scripts\claude-approver-state.json" -Raw | ConvertFrom-Json
$h = @{}
foreach ($p in $state.PSObject.Properties) { $h[$p.Name] = $p.Value }
$h.Remove("session-id-here")
$h | ConvertTo-Json -Depth 3 | Set-Content "$env:USERPROFILE\<claw-home>\scripts\claude-approver-state.json"

# 或全部重置：
Remove-Item "$env:USERPROFILE\<claw-home>\scripts\claude-approver-state.json"
```

## 停止

删除定时任务：

```
cron remove <jobId>
```

Windows 计划任务方式：`Unregister-ScheduledTask -TaskName "ClaudeCodeAutoApprover" -Confirm:$false`

## 参数调优

编辑 `monitor.ps1` 顶部的阈值：

| 变量 | 默认值 | 用途 |
|------|--------|------|
| `JSONL_IDLE_MIN_SEC` | 45 | 开始分析前 JSONL 最小空闲时间 |
| `FALLBACK_IDLE_MIN_SEC` | 120 | 兜底检测的最小进程空闲时间（仅在检测不明确时） |
| `MAX_FAILED_ATTEMPTS` | 3 | 阻断会话前的连续失败次数 |
| `BLOCK_MINUTES` | 10 | 达到最大失败次数后阻断时长 |
| `VERIFY_WAIT_SEC` | 20 | Enter 后轮询等待 JSONL 变化的最大时间（响应快时提前判定成功） |
| `REPORT_MAX_KB` | 2048 | 审批报告超过该大小自动轮转（归档为 .bak） |

## 已知坑点（v4.2 全部修复）

1. **PS 5.1 与 `ConvertFrom-Json -AsHashtable`**：任务计划程序运行 Windows PowerShell 5.1，不支持 `-AsHashtable`（PS6+ 才有）。它在 catch 块中静默失败 → 状态文件读取永远返回空 → 断路器永不触发、failedCount 永不累加。请改用 PS5.1 兼容的 JSON→hashtable 转换（见 monitor.ps1 的 `Load-State`）。

2. **任务计划程序下 Add-Type 源码编译失败**：`Add-Type` 带 C# 源码时会启动 csc.exe，其继承当前环境块。在环境块超大（>65535 字节，SDK/路径工具多时常见）的机器上会抛出 `InvalidOperationException`，所有 P/Invoke 类型缺失 → 点击/Enter 静默无效。**修复**：先用 `csc.exe` 把 `W32.cs` 编译成 `W32.dll`，再用 `Add-Type -Path` 加载（不启动编译器，无环境块问题）。修改 W32.cs 后需重新编译 W32.dll。

3. **UTF-8 JSONL 被 PS 5.1 默认 ANSI/GBK 读取（关键）**：中文 Windows 上 `Get-Content` 默认按 ANSI/GBK 读取，会破坏 UTF-8 会话 JSONL → 含中文的每一行 `ConvertFrom-Json` 都失败 → 回走循环跳过 `end_turn` 条目，把过期的 `tool_use` 误判为待审批 → 在终端提示符处乱发 Enter。**修复**：始终用 `[System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)` 读取会话 JSONL。

4. **PyCharm 终端焦点**：Alt+F12 是开关切换（按 JetBrains 文档，终端已聚焦时按下会**关闭**面板）。单独 SendKeys Enter 会落到当前焦点面板（编辑器、项目树……）。**修复**：用 SetCursorPos + mouse_event 点击 PyCharm 窗口底部边缘（终端标签栏区域）强制聚焦终端，再 SendKeys Enter。之后会恢复光标位置。

5. **单行 JSONL 管道结果是标量而非数组（v4.2）**：当文件只有**一行**时，`ReadAllLines(...) | Select-Object -Last 30` 返回的是*标量字符串*。此时 `$lines[0]` 索引到的是**字符**（`System.Char`），`ConvertFrom-Json` 解析单个 `{` 必然失败，检测静默失效。停在单条 AskUserQuestion/tool_use 之后的会话会踩中此坑。**修复**：用 `@(...)` 强制数组化：`$lines = @([IO.File]::ReadAllLines(...) | Select -Last 30)`。

6. **空闲兜底在回合结束触发（v4.2）**：旧兜底逻辑只要 JSONL 停滞 >120s 且 failedCount 为 0 就触发 —— 包括 Claude 只是**完成了回合**（end_turn）停在主提示符的情形 → 在空提示符处误发 Enter。**修复**：引入 `$detectionConclusive` —— 遇 user 消息、end_turn 或任意 tool_use（可批准、跳过或拒绝）均置 True。兜底现在只在检测**不明确**时触发（如解析失败），已完成会话永不触发。

7. **基于轮询的验证（v4.2）**：旧验证固定 sleep `VERIFY_WAIT_SEC` 后只检查一次。快速审批（2s 内 JSONL 已更新）白等 18s；慢工具又有误判 INEFFECTIVE 的风险。**修复**：每 2s 轮询一次直到 JSONL mtime 变化或超时 —— 快速响应立即成功，慢工具获得完整等待窗口。

## 故障排查

**Claude Code 卡住但未自动批准：**
- 检查 `claude.exe` 进程是否在运行（`Get-Process claude`）
- 检查会话是否被阻断（见上方状态文件）
- 检查能否找到 PyCharm 窗口 —— 脚本目标进程为 `pycharm64` 或 `pycharm`
- 检查调试日志 `~\<claw-home>\reports\claude-approver-debug.log` —— 记录 W32.dll 加载状态、点击坐标和每次 Enter 发送。若看到 "W32.dll load FAILED"，需重新编译 DLL（环境块过大导致 csc.exe 无法启动）
- **检查 JSONL 编码修复**：若审批静默失败，用 `ConvertFrom-Json` 验证最新条目能否解析 —— 中文 Windows 上 `Get-Content` 会破坏 UTF-8，除非用 `[System.IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)`。症状：无尽的 `INEFFECTIVE fail 1/3` 记录且永不累加到 3

**Claude 提问（AskUserQuestion）但期望自动批准：**
- 这是有意设计。AskUserQuestion 需要**你**做决定；脚本拒绝自动 Enter（见上方安全护栏）。请在终端中自行回答

**误批准过多（Claude 空闲在主提示符时也发 Enter）：**
- 调大 `FALLBACK_IDLE_MIN_SEC`（例如 300 = 5 分钟）
- 或设 `MAX_FAILED_ATTEMPTS = 1` 首次失败即阻断
- 兜底每个会话最多触发一次（要求 failedCount 为 0），本身已限流
- 检查 `end_turn` 是否被误读为 `tool_use` —— 这是 JSONL 行解析失败导致的（编码问题）。v4 的 UTF-8 修复已解决

**已发送批准但 Claude 无响应：**
- Claude 进程可能挂起 —— 检查 `Get-Process claude` 的 CPU 活动
- 3 次无效尝试后会话会自动阻断
- 重启 PyCharm 中的 Claude Code 以恢复

## 文件清单

| 文件 | 用途 |
|------|------|
| `scripts/monitor.ps1` | 核心检测 + 审批脚本（v4：UTF-8 读取、PS5.1 安全状态、DLL 加载） |
| `scripts/W32.cs` | 预编译 Win32 P/Invoke 封装的 C# 源码（编译一次 → W32.dll） |
| `~\<claw-home>\scripts\W32.dll` | 通过 `Add-Type -Path` 加载的预编译程序集（规避 csc.exe 环境块失败） |
| `~\<claw-home>\reports\claude-approvals.md` | 审批历史记录 |
| `~\<claw-home>\reports\claude-approver-debug.log` | 调试日志（DLL 加载、点击坐标、Enter 发送） |
| `~\<claw-home>\scripts\claude-approver-state.json` | 会话阻断状态 |
| `references/detection-strategy.md` | 完整检测逻辑说明 |

### 修改 W32.cs 后重新编译 W32.dll

```powershell
& "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe" /target:library /out:"$env:USERPROFILE\<claw-home>\scripts\W32.dll" "C:\path\to\W32.cs"
```
