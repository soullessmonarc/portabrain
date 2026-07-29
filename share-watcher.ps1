#Requires -Version 5.1
<#
Share Watcher - lightweight mid-session toast for the network-share heartbeat.

install.sh sets up a heartbeat that watches the network share and retries
reconnecting, but on Windows/WSL2 that heartbeat runs headless (no desktop
session), so its own alert (wall/logger) never actually reaches you. This
script is meant to be run on a short repeating schedule (see
install-share-watcher.ps1) so a drop (and recovery) shows up as a toast
within a couple of minutes instead.

One-shot by design: each run checks current state against the last-seen
state (in $env:LOCALAPPDATA\PortableAI\share-watch-state.json) and only
toasts on a transition (healthy -> down, or down -> healthy), so a
long-standing outage doesn't spam a toast every couple of minutes.

Usage:
  .\share-watcher.ps1
  .\share-watcher.ps1 -Distro Ubuntu-22.04
#>
param(
    [string]$Distro = "Ubuntu"
)

$ErrorActionPreference = "Stop"

$StateDir = Join-Path $env:LOCALAPPDATA "PortableAI"
$StateFile = Join-Path $StateDir "share-watch-state.json"
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

function Show-Toast([string]$Title, [string]$Message) {
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

        $xmlText = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>$Title</text>
      <text>$Message</text>
    </binding>
  </visual>
</toast>
"@
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($xmlText)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml

        # Well-known AUMID that lets a plain (unregistered) PowerShell script
        # raise a toast - shows up attributed to "Windows PowerShell" since
        # this rig has no installed app identity of its own.
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    } catch {
        # Toast delivery needs an interactive desktop session - if this runs
        # with nobody logged on, just skip it silently rather than error out
        # the scheduled task every cycle.
    }
}

$wasDown = $false
if (Test-Path $StateFile) {
    try { $wasDown = [bool](Get-Content $StateFile -Raw | ConvertFrom-Json).down } catch { $wasDown = $false }
}

$isDown = $false
try {
    wsl -d $Distro -- test -f /var/lib/portableai/share-alerted
    $isDown = ($LASTEXITCODE -eq 0)
} catch {
    # WSL not reachable (distro stopped, disk not attached, etc.) - nothing
    # to report either way, leave state as-is.
    exit 0
}

if ($isDown -and -not $wasDown) {
    Show-Toast "Portable AI Rig - Network Share Down" `
        "The network share is unreachable and couldn't auto-reconnect. Generated files are queued safely on the SSD and will sync over once it's back."
} elseif (-not $isDown -and $wasDown) {
    Show-Toast "Portable AI Rig - Network Share Reconnected" `
        "The network share is back. Queued files will sync over on the next cycle."
}

@{ down = $isDown } | ConvertTo-Json | Set-Content -Path $StateFile
