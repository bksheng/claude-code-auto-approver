# Claude Code 自动审批（claude-code-auto-approver）

在 PyCharm 终端中自动批准 Claude Code 的权限请求——通过向终端窗口发送 `Enter` 键，自动确认 Bash/Browser/API 等工具调用，实现无人值守执行。

- **版本**：v4.2 ｜ **平台**：Windows（PyCharm / pycharm64）
- 适用于需要 Claude Code 长时间无人值守运行的场景

> **路径约定**：`<claw-home>` 为 claw 类运行时数据目录名的占位符（形如 `~\.clawXXX`，实际名称因产品而异），部署前请替换；`~\`、`$env:USERPROFILE\`、`%USERPROFILE%\` 均为当前用户主目录（按上下文选用）。

## 特性

- **JSONL 主检测**：UTF-8 读取 Claude Code 会话日志，仅在检测到最后一条消息为待批准的 `tool_use` 时发送 Enter（Edit/Write 走 Claude Code 默认 `acceptEdits` 自动批准，跳过）
- **进程空闲兜底**：JSONL 停滞 + 所有 `claude.exe` 进程空闲时，作为一次性保险触发
- **断路器**：连续 3 次 Enter 无效（20s 内 JSONL 未变化）即阻断该会话 10 分钟，防止对挂起/崩溃的 Claude 无限重试
- **安全护栏**：`AskUserQuestion` 绝不自动批准——Claude 在向**用户**征询决策时，自动 Enter 会在用户不知情时替用户选中默认选项
- **Dry-Run 模式**：`-DryRun` 只报告"会发生什么"，不发送任何按键，用于无副作用诊断
- **审批留痕**：每次自动批准写入 `~\<claw-home>\reports\claude-approvals.md`（超限自动轮转归档）
- 循环检测由 **OpenClaw cron**（30s）或 **Windows 任务计划程序**（最低 1 分钟）驱动

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

## 目录结构

| 路径 | 用途 |
|------|------|
| `SKILL.md` | 技能主文档：部署（OpenClaw cron / 计划任务）、验证、状态检查、参数调优、故障排查 |
| `scripts/monitor.ps1` | 核心检测 + 审批脚本（UTF-8 读取、PS5.1 安全状态、DLL 加载、轮询验证） |
| `scripts/W32.cs` | Win32 P/Invoke 封装源码（编译一次 → W32.dll，规避任务计划程序下 csc.exe 环境块失败） |
| `references/detection-strategy.md` | 完整检测逻辑说明（JSONL 分析、兜底、断路器设计） |

## 快速开始

完整步骤见 `SKILL.md` 的「部署」节，核心三步：

1. 将 `scripts/monitor.ps1` 复制为 `~\<claw-home>\scripts\claude-auto-approve.ps1`
2. 创建循环定时任务（OpenClaw cron 或 Windows 计划任务 `ClaudeCodeAutoApprover`）
3. 手动运行一次 + `-DryRun` 验证检测逻辑

## 安全设计

- 仅在检测**确认为待批准的工具请求**时发送 Enter；`AskUserQuestion` 在主检测与兜底检测中均被硬性排除
- 会话级断路器（3 次无效 → 阻断 10 分钟）防止误操作无限循环
- 空闲兜底每会话至多触发一次，并需先验证 `end_turn`/`user` 消息未被误读
- Windows 专用：依赖 WinAPI（`SendKeys`/`SetForegroundWindow`/`SetCursorPos`），macOS/Linux 不支持

## 已知坑点（v4.2 已全部修复）

PS 5.1 `ConvertFrom-Json -AsHashtable` 兼容、任务计划程序下 `Add-Type` 源码编译的环境块问题、中文 Windows 下 `Get-Content` 按 GBK 误读 UTF-8 JSONL、PyCharm 终端焦点切换、单行 JSONL 管道退化为标量、回合结束后空闲兜底误触发、固定等待改为轮询验证——细节与修复见 `SKILL.md`「已知坑点」节。
