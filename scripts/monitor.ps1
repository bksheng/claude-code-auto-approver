<#
.SYNOPSIS
  Claude Code Auto Approver v4.2
  两级检测 + 断路器 + 轮询验证
#>
param(
    [switch]$DryRun   # Diagnose only: report what WOULD be approved, send nothing
)

$ErrorActionPreference = "Continue"

# NOTE: <claw-home> is a PLACEHOLDER for the runtime data directory name
# (differs per product, e.g. ~\.clawXXX form). Replace ALL <claw-home>
# occurrences below (reportPath/statePath/debugLog/w32Dll) before deploying.
$reportPath = "$env:USERPROFILE\<claw-home>\reports\claude-approvals.md"
$statePath  = "$env:USERPROFILE\<claw-home>\scripts\claude-approver-state.json"
$projectsDir = "$env:USERPROFILE\.claude\projects"
$debugLog  = "$env:USERPROFILE\<claw-home>\reports\claude-approver-debug.log"

# ── Configurable thresholds ──
$JSONL_IDLE_MIN_SEC    = 45    # JSONL must be idle at least this long
$FALLBACK_IDLE_MIN_SEC = 120   # Process idle before fallback kicks in
$MAX_FAILED_ATTEMPTS   = 3     # Circuit breaker: max consecutive fails per session
$BLOCK_MINUTES          = 10   # Block session after hitting max fails
$VERIFY_WAIT_SEC        = 20   # Max wait after Enter, polling for JSONL change
$REPORT_MAX_KB          = 2048 # Rotate approvals report above this size (2MB)

# ── Helpers ──
function Write-Dbg($msg) {
    try {
        $dir = Split-Path $debugLog -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
        Add-Content $debugLog "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" -Encoding UTF8
    } catch {}
}

# PS5.1-compatible JSON -> hashtable (ConvertFrom-Json -AsHashtable is PS6+ only)
function ConvertFrom-JsonToHashtable($jsonObj) {
    $h = @{}
    foreach ($p in $jsonObj.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

function Load-State {
    if (Test-Path $statePath) {
        try {
            $obj = Get-Content $statePath -Raw | ConvertFrom-Json
            if ($null -eq $obj) { return @{} }
            $h = @{}
            foreach ($p in $obj.PSObject.Properties) {
                $v = $p.Value
                if ($v -is [System.Management.Automation.PSCustomObject]) {
                    $h[$p.Name] = ConvertFrom-JsonToHashtable $v
                } else { $h[$p.Name] = $v }
            }
            return $h
        } catch { Write-Dbg "Load-State FAILED: $($_.Exception.Message)" }
    }
    return @{}
}
function Save-State($s) { $dir = Split-Path $statePath -Parent; if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }; $s | ConvertTo-Json -Depth 3 | Set-Content $statePath -Encoding UTF8 }

function Is-SessionBlocked($sessionId) {
    $s = Load-State
    if (-not $s.ContainsKey($sessionId)) { return $false }
    $entry = $s[$sessionId]
    if ($entry.blockedUntil -and (Get-Date) -lt [DateTime]$entry.blockedUntil) { return $true }
    return $false
}

function Get-SessionState($sessionId) {
    $s = Load-State
    if (-not $s.ContainsKey($sessionId)) {
        return @{ failedCount=0; blockedUntil=$null; lastAttemptTime=$null }
    }
    return $s[$sessionId]
}

function Update-SessionState($sessionId, $success) {
    $s = Load-State
    if (-not $s.ContainsKey($sessionId)) { $s[$sessionId] = @{} }
    $ss = $s[$sessionId]
    $ss.lastAttemptTime = (Get-Date).ToString("o")
    if ($success) {
        $ss.failedCount = 0
        $ss.blockedUntil = $null
    } else {
        $ss.failedCount = [int]$ss.failedCount + 1
        if ($ss.failedCount -ge $MAX_FAILED_ATTEMPTS) {
            $ss.blockedUntil = (Get-Date).AddMinutes($BLOCK_MINUTES).ToString("o")
        }
    }
    Save-State $s
}

# ── 1. Find Claude processes ──
$claudeProcs = @(Get-Process -Name "claude" -ErrorAction SilentlyContinue)
if ($claudeProcs.Count -eq 0) { exit 0 }

# ── 2. CPU idle check ──
$cpuBefore = @{}
foreach ($p in $claudeProcs) { $cpuBefore[$p.Id] = $p.TotalProcessorTime }
Start-Sleep -Seconds 2
$anyActive = $false
foreach ($p in $claudeProcs) {
    try { $p.Refresh(); if (($p.TotalProcessorTime - $cpuBefore[$p.Id]).TotalSeconds -gt 0.15) { $anyActive = $true } } catch {}
}
if ($anyActive) { exit 0 }

# ── 3. Find latest session ──
$latestSession = Get-ChildItem $projectsDir -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ChildItem $_.FullName -Filter "*.jsonl" -ErrorAction SilentlyContinue } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $latestSession) { exit 0 }

$idleSec = [math]::Round(((Get-Date) - $latestSession.LastWriteTime).TotalSeconds)

if ($idleSec -lt $JSONL_IDLE_MIN_SEC) { exit 0 }

# ── 4. Circuit breaker check ──
$sessionId = $latestSession.BaseName
if (Is-SessionBlocked $sessionId) {
    $ss = Get-SessionState $sessionId
    exit 0
}

# ── 5. PRIMARY: JSONL deep analysis ──
# CRITICAL: read as UTF-8! PS 5.1 Get-Content defaults to ANSI/GBK on Chinese
# Windows, which mangles UTF-8 JSONL and breaks ConvertFrom-Json parsing.
# @() forces array: with a single-line file, a bare pipeline result would be a
# SCALAR string and $lines[0] would index into characters (System.Char), which
# then fails to parse. This bit us in single-entry test sessions.
$lines = @([System.IO.File]::ReadAllLines($latestSession.FullName, [System.Text.Encoding]::UTF8) | Select-Object -Last 30)
$pendingToolName = ""
$detectionMethod = ""

# Tools that must NEVER be auto-approved: they ask the USER for a decision.
# AskUserQuestion = Claude is asking the user something -> auto-Enter would
# pick the default option on the USER's behalf. That's unacceptable.
$NEVER_APPROVE = @("AskUserQuestion")

# Walk backwards from latest entry to detect approval state
# Skip meta entries (system, mode, permission-mode, file-history-snapshot, last-prompt)
# Stop at first significant entry: user->alreadyResponded, end_turn->done, tool_use->pending
# $detectionConclusive: true when we positively saw "not waiting" (user msg or end_turn).
# The idle fallback may ONLY fire when detection is NOT conclusive — otherwise a
# finished turn (Claude idle at main prompt) would falsely trigger Enter.
$detectionConclusive = $false
for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    try {
        $obj = $lines[$i] | ConvertFrom-Json
        $t = $obj.type
        # Skip noise
        if ($t -eq "system" -or $t -eq "mode" -or $t -eq "permission-mode" -or
            $t -eq "file-history-snapshot" -or $t -eq "last-prompt") { continue }
        # User already responded -> not waiting
        if ($t -eq "user") { $detectionConclusive = $true; break }
        # Assistant message
        if ($t -eq "assistant") {
            $sr = $obj.message.stop_reason
            if ($sr -eq "end_turn") { $detectionConclusive = $true; break }
            if ($sr -eq "tool_use") {
                $tn = ""
                foreach ($c in $obj.message.content) { if ($c.type -eq "tool_use") { $tn = $c.name; break } }
                if ($tn) {
                    # Every tool_use is a conclusive state: either approvable,
                    # auto-approved by Claude (Edit/Write), or must be refused
                    # (AskUserQuestion). In all cases we KNOW it's not "done".
                    $detectionConclusive = $true
                }
                if ($tn -and $tn -ne "Edit" -and $tn -ne "Write" -and $NEVER_APPROVE -notcontains $tn) {
                    $pendingToolName = $tn
                    $detectionMethod = "JSONL exact (tool_use: $tn)"
                }
            }
            break
        }
    } catch {}
}

# ── 6. SECONDARY: Process idle fallback (with constraints) ──
# Only when primary detection was NOT conclusive (e.g. parse failures) AND
# the process has been idle long enough AND no prior failures on this session.
# Also refuses AskUserQuestion. This prevents false Enters when Claude simply
# finished a turn and is sitting at the main prompt.
if (-not $pendingToolName -and -not $detectionConclusive -and $idleSec -ge $FALLBACK_IDLE_MIN_SEC) {
    $lastIsQuestion = $false
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        try {
            $qObj = $lines[$i] | ConvertFrom-Json
            $qt = $qObj.type
            if ($qt -eq "system" -or $qt -eq "mode" -or $qt -eq "permission-mode" -or
                $qt -eq "file-history-snapshot" -or $qt -eq "last-prompt") { continue }
            if ($qt -eq "user") { break }
            if ($qt -eq "assistant") {
                foreach ($c in $qObj.message.content) {
                    if ($c.type -eq "tool_use" -and $NEVER_APPROVE -contains $c.name) { $lastIsQuestion = $true; break }
                }
                break
            }
        } catch {}
    }
    if (-not $lastIsQuestion) {
        $ss = Get-SessionState $sessionId
        if ($ss.failedCount -eq 0) {
            $pendingToolName = "unknown (idle fallback)"
            $detectionMethod = "idle fallback (JSONL stale ${idleSec}s)"
        }
    }
}

# ── 6.5 Dry-run mode: report verdict, send nothing ──
if ($DryRun) {
    $verdict = if ($pendingToolName) { "WOULD-APPROVE ($pendingToolName)" } else { "NO-ACTION" }
    Write-Output "DryRun verdict: $verdict | idle=${idleSec}s | conclusive=$detectionConclusive"
    if ($pendingToolName) { Write-Output "Method: $detectionMethod" }
    exit 0
}

if (-not $pendingToolName) { exit 0 }

# ── 7. Send Enter to PyCharm ──
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$jsonlBefore = $latestSession.LastWriteTime

Add-Type -AssemblyName System.Windows.Forms
# Load precompiled W32.dll (compiled once with csc.exe) instead of Add-Type source compile.
# Add-Type source compile spawns csc.exe which inherits the huge environment block
# (over 65535 bytes on this machine) and fails with InvalidOperationException.
$w32Dll = "$env:USERPROFILE\<claw-home>\scripts\W32.dll"
try {
    Add-Type -Path $w32Dll -ErrorAction Stop
    Write-Dbg "W32.dll loaded OK"
} catch {
    Write-Dbg "W32.dll load FAILED: $($_.Exception.Message) - falling back to source compile"
    Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class W32 {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder buf, int max);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWinProc lp, IntPtr l);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
    public delegate bool EnumWinProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
}

$curWnd = [W32]::GetForegroundWindow()
$pc = Get-Process -Name "pycharm64" -ErrorAction SilentlyContinue
if (-not $pc) { $pc = Get-Process -Name "pycharm" -ErrorAction SilentlyContinue }
$hwnd = [IntPtr]::Zero
if ($pc) {
    $hwnd = $pc.MainWindowHandle
    if ($hwnd -eq [IntPtr]::Zero) {
        $pid = $pc.Id
        [W32]::EnumWindows({
            param($h,$l); $p=0; [W32]::GetWindowThreadProcessId($h,[ref]$p)
            if ($p -eq $pid) {
                $sb=New-Object Text.StringBuilder(256); [W32]::GetWindowText($h,$sb,256)
                if ($sb.ToString() -match "PyCharm") { $script:hwnd=$h; return $false }
            }; return $true
        }, [IntPtr]::Zero)
    }
}

if ($hwnd -eq [IntPtr]::Zero) {
    Write-Output "[$timestamp] ERROR: PyCharm not found"
    Update-SessionState $sessionId $false
    exit 1
}

if ([W32]::IsIconic($hwnd)) { [W32]::ShowWindow($hwnd, 9); Start-Sleep -Milliseconds 200 }
[W32]::BringWindowToTop($hwnd); Start-Sleep -Milliseconds 100
[W32]::SetForegroundWindow($hwnd); Start-Sleep -Milliseconds 300

# ── Focus the Terminal panel by CLICKING it (critical) ──
# PyCharm's terminal is an embedded bottom panel, NOT a separate window.
# SetForegroundWindow alone leaves keyboard focus wherever it was
# (editor, project tree...), so SendKeys Enter gets swallowed.
# DO NOT use Alt+F12 here: it is a TOGGLE — if the terminal is already
# focused it CLOSES the panel (per JetBrains docs), so Enter never lands.
# A real mouse click on the bottom tab/panel area reliably focuses it.
$rect = New-Object W32+RECT
[W32]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
$clickX = [int](($rect.Left + $rect.Right) / 2)
# Bottom edge strip: terminal tab bar / panel. Click 30px above bottom edge.
$clickY = [int]($rect.Bottom - 30)
$curPos = [System.Windows.Forms.Cursor]::Position
[W32]::SetCursorPos($clickX, $clickY) | Out-Null
Start-Sleep -Milliseconds 150
[W32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)  # LEFTDOWN
Start-Sleep -Milliseconds 80
[W32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)  # LEFTUP
Start-Sleep -Milliseconds 500
[System.Windows.Forms.Cursor]::Position = $curPos  # restore cursor
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
Write-Dbg "Click($clickX,$clickY) + Enter sent. fg=$(($pc.ProcessName)) hwnd=$hwnd"
Start-Sleep -Milliseconds 200
if ($curWnd -ne [IntPtr]::Zero -and $curWnd -ne $hwnd) {
    [W32]::SetForegroundWindow($curWnd)
}

# ── 8. Verify: POLL for JSONL change (up to VERIFY_WAIT_SEC) ──
# Polling instead of a fixed sleep: if Enter worked fast (Claude replied in 2s),
# we detect success immediately; only genuinely slow/failed approvals wait the
# full window. This reduces false INEFFECTIVE verdicts for long-running tools.
$wasEffective = $false
$verifyDeadline = (Get-Date).AddSeconds($VERIFY_WAIT_SEC)
while ((Get-Date) -lt $verifyDeadline) {
    Start-Sleep -Seconds 2
    $latestSession.Refresh()
    if ($latestSession.LastWriteTime -gt $jsonlBefore) { $wasEffective = $true; break }
}

$ss = Get-SessionState $sessionId
$failCount = if ($wasEffective) { Update-SessionState $sessionId $true; 0 } else { Update-SessionState $sessionId $false; [int]$ss.failedCount + 1 }
$maxFails = $MAX_FAILED_ATTEMPTS

if ($wasEffective) {
    Write-Output "[$timestamp] APPROVED (verified: JSONL updated)"
} else {
    Write-Output "[$timestamp] WARNING: Enter sent but JSONL unchanged (fail ${failCount}/${maxFails})"
}

# ── 9. Log to report ──
$projectName = $latestSession.Directory.Name -replace 'C--', '' -replace '--', '/' -replace '-', ' '
if ($projectName -match '^/(.+)$') { $projectName = $Matches[1] }

$reportDir = Split-Path $reportPath -Parent
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory $reportDir -Force | Out-Null }

# Rotate report if it grew too large (keeps file bounded over months)
if (Test-Path $reportPath) {
    try {
        $sizeKB = [math]::Round((Get-Item $reportPath).Length / 1KB)
        if ($sizeKB -gt $REPORT_MAX_KB) {
            $archivePath = "$reportPath.$((Get-Date).ToString('yyyyMMdd-HHmmss')).bak"
            Move-Item $reportPath $archivePath -Force
            Write-Dbg "Report rotated ($sizeKB KB) -> $archivePath"
        }
    } catch {}
}

if (-not (Test-Path $reportPath)) {
    "# Claude Code Auto Approver v4`r`n`r`n> Detection: JSONL primary + idle fallback | Circuit breaker: 3 fails = 10min block`r`n`r`n---`r`n" | Out-File $reportPath -Encoding UTF8
}

$statusStr = if ($wasEffective) { "EFFECTIVE" } else { "INEFFECTIVE (fail ${failCount}/${maxFails})" }
$entry = "`r`n### ${statusStr} - $timestamp`r`n`r`n| Item | Detail |`r`n|------|--------|`r`n| **Tool** | $pendingToolName |`r`n| **Method** | $detectionMethod |`r`n| **Project** | $projectName |`r`n| **Session** | $sessionId |`r`n| **Action** | Send Enter |`r`n"
Add-Content $reportPath $entry -Encoding UTF8

Write-Output "Report: $reportPath"
