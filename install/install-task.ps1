<#
.SYNOPSIS
    Install/uninstall the Claude warmup schedule via Windows Task Scheduler.

.DESCRIPTION
    On first run, prompts for an anchor hour (0-23), persists it, and reuses
    it on later runs. Registers a scheduled task bound to the PowerShell
    warmup script that runs:
      - at system startup, and
      - daily at the anchor hour, repeating every N hours (default 2) for 24h.

    The task runs with highest privileges and starts when available (so runs
    missed while the machine was off/asleep fire on resume). Re-running
    replaces the existing task (idempotent).

.PARAMETER IntervalHours
    Hours between warmup runs (default 2). Persisted and reused on later runs.

.PARAMETER Reconfigure
    Re-prompt for the anchor hour even if one is already saved.

.PARAMETER Uninstall
    Remove the scheduled task.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-task.ps1
    powershell -ExecutionPolicy Bypass -File .\install-task.ps1 -IntervalHours 2
    powershell -ExecutionPolicy Bypass -File .\install-task.ps1 -Reconfigure
    powershell -ExecutionPolicy Bypass -File .\install-task.ps1 -Uninstall

.NOTES
    Run from an elevated (Administrator) PowerShell for highest privileges.
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 24)]
    [int]$IntervalHours = 0,   # 0 = use persisted value, else default 2
    [switch]$Reconfigure,
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskName    = 'ClaudeWarmup'
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$WarmupPs1   = Join-Path (Split-Path -Parent $ScriptDir) 'bin\claude-warmup.ps1'
$WarmupPs1   = (Resolve-Path $WarmupPs1).Path
$ConfigDir   = Join-Path $env:APPDATA 'claude-warmup'
$ConfigFile  = Join-Path $ConfigDir 'config'

function Get-SavedAnchor {
    if (Test-Path $ConfigFile) {
        $line = Get-Content $ConfigFile | Where-Object { $_ -match '^\s*ANCHOR_HOUR\s*=' } | Select-Object -First 1
        if ($line) {
            $value = ($line -split '=', 2)[1].Trim()
            $parsed = 0
            if ([int]::TryParse($value, [ref]$parsed) -and $parsed -ge 0 -and $parsed -le 23) {
                return $parsed
            }
        }
    }
    return $null
}

function Read-Anchor {
    $default = (Get-Date).Hour
    while ($true) {
        $input = Read-Host "Enter the anchor hour for the warmup (0-23) [$default]"
        if ([string]::IsNullOrWhiteSpace($input)) { return $default }
        $parsed = 0
        if ([int]::TryParse($input, [ref]$parsed) -and $parsed -ge 0 -and $parsed -le 23) {
            return $parsed
        }
        Write-Host "Invalid hour '$input'. Please enter an integer between 0 and 23." -ForegroundColor Yellow
    }
}

function Get-SavedInterval {
    if (Test-Path $ConfigFile) {
        $line = Get-Content $ConfigFile | Where-Object { $_ -match '^\s*INTERVAL_HOURS\s*=' } | Select-Object -First 1
        if ($line) {
            $value = ($line -split '=', 2)[1].Trim()
            $parsed = 0
            if ([int]::TryParse($value, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 24) {
                return $parsed
            }
        }
    }
    return $null
}

function Save-Config {
    param([int]$Hour, [int]$Interval)
    if (-not (Test-Path $ConfigDir)) {
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    }
    Set-Content -Path $ConfigFile -Value @("ANCHOR_HOUR=$Hour", "INTERVAL_HOURS=$Interval") -Encoding UTF8
}

function Uninstall-Task {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'."
    } else {
        Write-Host "No scheduled task named '$TaskName' found."
    }
}

function Install-Task {
    param([int]$Anchor, [int]$Interval)

    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WarmupPs1`""

    # Trigger 1: at startup.
    $startupTrigger = New-ScheduledTaskTrigger -AtStartup

    # Trigger 2: daily at the anchor hour, repeating every N hours for a day.
    $at = (Get-Date -Hour $Anchor -Minute 0 -Second 0)
    $dailyTrigger = New-ScheduledTaskTrigger -Daily -At $at
    $dailyTrigger.Repetition = (New-ScheduledTaskTrigger -Once -At $at `
        -RepetitionInterval (New-TimeSpan -Hours $Interval) `
        -RepetitionDuration (New-TimeSpan -Hours 24)).Repetition

    $principal = New-ScheduledTaskPrincipal `
        -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType S4U `
        -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -WakeToRun `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger @($startupTrigger, $dailyTrigger) `
        -Principal $principal `
        -Settings $settings `
        -Description 'Keeps the Claude CLI floating quota window warm.' `
        -Force | Out-Null

    Write-Host "Installed scheduled task '$TaskName' (anchor hour $Anchor, every ${Interval}h + at startup)."
    Write-Host "Verify with: Get-ScheduledTask -TaskName $TaskName"
}

# --- Main ------------------------------------------------------------------
if ($Uninstall) {
    Uninstall-Task
    return
}

$anchor = Get-SavedAnchor
if ($Reconfigure -or ($null -eq $anchor)) {
    $anchor = Read-Anchor
} else {
    Write-Host "Using existing anchor hour $anchor (from $ConfigFile)."
}

# Interval precedence: explicit -IntervalHours > persisted > default (2).
if ($IntervalHours -gt 0) {
    $interval = $IntervalHours
} else {
    $saved = Get-SavedInterval
    $interval = if ($null -ne $saved) { $saved } else { 2 }
}

Save-Config -Hour $anchor -Interval $interval
Write-Host "Schedule: anchor hour $anchor, every ${interval}h (saved to $ConfigFile)."

Install-Task -Anchor $anchor -Interval $interval
