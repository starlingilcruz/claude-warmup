<#
.SYNOPSIS
    Keep the Claude CLI floating quota window warm (Windows).

.DESCRIPTION
    Makes a single ultra-lightweight, silent call to the Claude CLI with a
    prompt that forces a one-character answer (so both input and output tokens
    stay minimal), appends a timestamped result to
    %USERPROFILE%\claude_warmup.log, and shows a native Windows
    Toast/Balloon notification if the call fails.

    Designed to be run NON-INTERACTIVELY by Task Scheduler (at startup and
    every 5 hours), so it explicitly bootstraps PATH to locate the `claude`
    executable.

.NOTES
    Exit codes:
      0  warmup succeeded
      1  warmup failed (claude returned non-zero or was not found)

    Logs to: $HOME\claude_warmup.log
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LogFile = Join-Path $HOME 'claude_warmup.log'

# Minimal-token warmup prompt: constrains the model to a single-digit reply so
# the output token count stays at ~1.
$WarmupPrompt = 'Reply with only the digit 1 and nothing else.'

function Get-Timestamp {
    return (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
}

function Write-LogLine {
    param([string]$Line)
    Add-Content -Path $LogFile -Value $Line -Encoding UTF8
}

function Show-FailureNotification {
    param([string]$Message)

    $title = 'Claude warmup failed'

    # Preferred: modern Toast via WinRT. Fall back to a tray BalloonTip.
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $texts = $template.GetElementsByTagName('text')
        $texts.Item(0).AppendChild($template.CreateTextNode($title)) | Out-Null
        $texts.Item(1).AppendChild($template.CreateTextNode($Message)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Claude Warmup')
        $notifier.Show($toast)
        return
    } catch {
        # Fall through to balloon tip.
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms
        $balloon = New-Object System.Windows.Forms.NotifyIcon
        $balloon.Icon = [System.Drawing.SystemIcons]::Warning
        $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Error
        $balloon.BalloonTipTitle = $title
        $balloon.BalloonTipText = $Message
        $balloon.Visible = $true
        $balloon.ShowBalloonTip(10000)
        Start-Sleep -Seconds 10
        $balloon.Dispose()
    } catch {
        # Notification is best-effort; the failure is already logged.
    }
}

# --- Environment bootstrap -------------------------------------------------
# Task Scheduler launches us with a minimal environment, so rebuild PATH
# from the persisted Machine + User values and add the npm global prefix.

$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
$npmPrefix   = Join-Path $env:APPDATA 'npm'

$env:Path = (@($machinePath, $userPath, $npmPrefix) | Where-Object { $_ }) -join ';'

# --- Resolve the claude executable -----------------------------------------
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claudeCmd) {
    $msg = "claude executable not found on PATH (PATH=$env:Path)"
    Write-LogLine "[$(Get-Timestamp)] FAILURE exit=127 :: $msg"
    Show-FailureNotification "claude not found on PATH. See $LogFile."
    exit 1
}

# --- Warmup call -----------------------------------------------------------
try {
    $output = & $claudeCmd.Source -p $WarmupPrompt 2>&1 | Out-String
    $status = $LASTEXITCODE
} catch {
    $output = $_.Exception.Message
    $status = 1
}

if ($status -eq 0) {
    Write-LogLine "[$(Get-Timestamp)] SUCCESS exit=0"
    exit 0
} else {
    $clean = ($output -replace '\r?\n', ' ').Trim()
    Write-LogLine "[$(Get-Timestamp)] FAILURE exit=$status :: $clean"
    $short = if ($clean.Length -gt 200) { $clean.Substring(0, 200) } else { $clean }
    Show-FailureNotification "exit=$status: $short (see $LogFile)"
    exit 1
}
