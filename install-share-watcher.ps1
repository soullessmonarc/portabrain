#Requires -Version 5.1
<#
Installs a Windows Scheduled Task that runs share-watcher.ps1 every 2
minutes while you're logged on, so a share drop/recovery shows up as a
toast notification without needing to re-run Connect AI.ps1.

Run once per machine (re-running just replaces the existing task).

Usage:
  .\install-share-watcher.ps1
  .\install-share-watcher.ps1 -Distro Ubuntu-22.04
#>
param(
    [string]$Distro = "Ubuntu"
)

$ErrorActionPreference = "Stop"
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
$WatcherPath = Join-Path $ScriptDir "share-watcher.ps1"

if (-not (Test-Path $WatcherPath)) {
    Write-Error "share-watcher.ps1 not found next to this script at '$WatcherPath'."
    exit 1
}

# Scoped to the distro, because Register-ScheduledTask below uses -Force: with
# a single fixed name, installing a second rig in a different WSL distro
# silently replaced the first rig's task instead of adding its own. Confirmed
# live - a template install into Ubuntu-24.04 repointed an existing rig's
# watcher at the wrong distro, leaving the original with no watcher at all.
$TaskName = "PortableAI Share Watcher ($Distro)"

# powershell.exe's own -WindowStyle Hidden is applied only AFTER the process
# has started, by which point the console host has already created and
# painted a window - so a scheduled task on a short repeating interval
# produces a console window that visibly flashes onto the desktop every
# single cycle (confirmed live: a System32 PowerShell window opening every 2
# minutes). Launching via 'conhost.exe --headless' means no console window is
# ever created in the first place, while still running in the interactive
# session that toast notifications require. Falls back to plain
# powershell.exe if conhost isn't present for any reason.
$psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$conhostExe = Join-Path $env:SystemRoot "System32\conhost.exe"
$psArgs = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WatcherPath`" -Distro `"$Distro`""
if (Test-Path $conhostExe) {
    $action = New-ScheduledTaskAction -Execute $conhostExe -Argument "--headless `"$psExe`" $psArgs"
} else {
    $action = New-ScheduledTaskAction -Execute $psExe -Argument $psArgs
}

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew

# Toasts only render with an interactive desktop session, so this runs as
# the current interactive user rather than as a "whether logged on or not"
# service-style task.
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

Write-Host "Installed scheduled task '$TaskName' - checks every 2 minutes while you're logged in."
Write-Host "Run 'Unregister-ScheduledTask -TaskName `"$TaskName`" -Confirm:`$false' to remove it."
