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
        # Toast delivery needs an interactive desktop session, so this genuinely
        # should not fail the run - if nobody is logged on there is no desktop to
        # notify and erroring out would just mark the scheduled task failed every
        # couple of minutes forever.
        #
        # Written to the verbose stream rather than left as a bare empty block:
        # silently discarding the reason makes "why did I never get a toast?"
        # undiagnosable. Run this script by hand with -Verbose to see it.
        Write-Verbose "Toast not delivered: $($_.Exception.Message)"
    }
}

$wasDown = $false
if (Test-Path $StateFile) {
    try { $wasDown = [bool](Get-Content $StateFile -Raw | ConvertFrom-Json).down } catch { $wasDown = $false }
}

# Only ever probe a distro that is ALREADY running. A bare
# `wsl -d <distro> -- <cmd>` against a stopped distro doesn't just fail - it
# BOOTS THE ENTIRE WSL2 VM to run the command. On a 2-minute schedule that
# means this watcher would silently start WSL2 over and over, forever,
# including right after a clean eject whose entire purpose was to leave it
# shut down.
#
# This also fixes the detection logic it replaces: a native command
# returning a nonzero exit code doesn't throw, so the try/catch here could
# never actually catch "WSL unreachable" the way it intended - a stopped
# distro read as $isDown = $false, i.e. indistinguishable from a healthy
# share, which could fire a bogus "Share Reconnected" toast for a rig that
# wasn't even running.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$runningRaw = wsl.exe -l --running -q 2>$null
$ErrorActionPreference = $prevEAP
# wsl.exe emits UTF-16, which PowerShell 5.1 decodes a byte at a time and
# leaves interleaved NULs in - strip them before matching.
$running = (($runningRaw -join "`n") -replace "`0", "")
if ($running -notmatch [regex]::Escape($Distro)) {
    # Rig isn't running. Nothing to report, and deliberately no state write,
    # so the last real state is still there when it comes back up.
    exit 0
}

wsl -d $Distro --cd ~ -- test -f /var/lib/portableai/share-alerted
$isDown = ($LASTEXITCODE -eq 0)

if ($isDown -and -not $wasDown) {
    Show-Toast "Portable AI Rig - Network Share Down" `
        "The network share is unreachable and couldn't auto-reconnect. Generated files are queued safely on the SSD and will sync over once it's back."
} elseif (-not $isDown -and $wasDown) {
    Show-Toast "Portable AI Rig - Network Share Reconnected" `
        "The network share is back. Queued files will sync over on the next cycle."
}

@{ down = $isDown } | ConvertTo-Json | Set-Content -Path $StateFile
