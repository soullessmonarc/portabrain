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

$TaskName = "PortableAI Share Watcher"

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WatcherPath`" -Distro `"$Distro`""

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew

# Toasts only render with an interactive desktop session, so this runs as
# the current interactive user rather than as a "whether logged on or not"
# service-style task.
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

Write-Host "Installed scheduled task '$TaskName' - checks every 2 minutes while you're logged in."
Write-Host "Run 'Unregister-ScheduledTask -TaskName `"$TaskName`" -Confirm:`$false' to remove it."
