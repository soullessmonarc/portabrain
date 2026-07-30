#Requires -RunAsAdministrator
<#
Portable AI rig - connect (Windows launcher).

Run this from an elevated PowerShell to bring the rig up: after a reboot, after
a clean disconnect, or when plugging the drive into a machine that has already
been through install-windows.ps1 once.

This is NOT the installer. It asks nothing, installs nothing, downloads nothing
and rewrites no config - it attaches the drive to WSL2, mounts it, starts the
daemons in the right order, brings the stack up, and holds the WSL2 instance
open. Re-running the installer works too, but re-asks every question and
regenerates docker-compose.yml for no reason.

Usage:
  .\connect.ps1
  .\connect.ps1 -DiskNumber 2          # if auto-detect finds more than one
  .\connect.ps1 -Distro Ubuntu-24.04
  .\connect.ps1 -IfPresent             # exit quietly if the drive isn't plugged in
#>
param(
    [int]$DiskNumber = -1,
    [string]$Distro = "Ubuntu",
    # For unattended/scheduled runs: if the drive isn't attached, or WSL isn't
    # ready yet, exit 0 silently instead of erroring. A logon-triggered task
    # fires on every boot whether or not the drive happens to be plugged in,
    # and a failure notification every time you start the machine without it
    # would train you to ignore the one that actually matters.
    [switch]$IfPresent
)

$ErrorActionPreference = "Stop"
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
$KeepAlivePidFile = Join-Path $ScriptDir ".keepalive.pid"

Write-Host ""
Write-Host "===== Portable AI Rig - Connect ====="
Write-Host ""

# wsl.exe missing entirely throws a terminating "not recognized" error under
# $ErrorActionPreference = "Stop" the first time anything calls it, so check up
# front and fail with something that actually explains itself.
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    if ($IfPresent) { exit 0 }
    Write-Error "wsl.exe isn't available on this machine. Run install-windows.ps1 first - it can install WSL2 for you."
    exit 1
}

Write-Host "== Checking WSL distro '$Distro' =="
# A failing native command whose stderr is redirected (even to $null) gets
# wrapped as a terminating NativeCommandError under EAP=Stop in PowerShell 5.1,
# even though the exit code is meant to be handled via $LASTEXITCODE. Guard it.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$distros = (wsl -l -q) -replace "`0", ""
$ErrorActionPreference = $prevEAP
if (($distros -join "`n") -notmatch [regex]::Escape($Distro)) {
    if ($IfPresent) { exit 0 }
    Write-Error "WSL distro '$Distro' not found. Run install-windows.ps1 first, or pass -Distro with the right name."
    exit 1
}

# systemd is required: the rig's daemons are systemd units. A distro whose
# /etc/wsl.conf lost its [boot] section can't start them at all, and the error
# it produces ("System has not been booted with systemd as init system") is
# opaque enough to be worth pre-empting.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
wsl -d $Distro -u root --cd ~ -- grep -q '^systemd=true' /etc/wsl.conf 2>$null
$systemdOk = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = $prevEAP
if (-not $systemdOk) {
    Write-Error "systemd isn't enabled in '$Distro' (/etc/wsl.conf has no 'systemd=true'). Run install-windows.ps1, which sets this up and self-heals it."
    exit 1
}

Write-Host "== Locating the rig drive =="
$linuxGuid = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"  # GPT partition type: Linux filesystem data
if ($DiskNumber -lt 0) {
    $candidates = Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.GptType -eq "{$linuxGuid}" } | Select-Object -ExpandProperty DiskNumber -Unique
    if (-not $candidates) {
        # The common, expected case for a scheduled run: machine booted without
        # the drive attached. Not an error worth reporting.
        if ($IfPresent) { exit 0 }
        Write-Error "No disk with a Linux (ext4) partition found. Plug the drive in, or pass -DiskNumber explicitly (see 'Get-Disk')."
        exit 1
    }
    if (@($candidates).Count -gt 1) {
        Write-Host "More than one candidate disk found:"
        Get-Disk | Where-Object { $_.Number -in $candidates } | Format-Table Number, FriendlyName, @{n='GB';e={[math]::Round($_.Size/1GB)}}, BusType
        Write-Error "Re-run with -DiskNumber <N> to pick one."
        exit 1
    }
    $DiskNumber = @($candidates)[0]
}

$disk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
if (-not $disk) {
    Write-Error "There's no disk $DiskNumber on this machine."
    exit 1
}
Write-Host "Using disk $DiskNumber ($($disk.FriendlyName), $([math]::Round($disk.Size/1GB))GB, bus $($disk.BusType))"

if (-not $disk.IsOffline) {
    Write-Host "== Taking disk $DiskNumber offline (so WSL2 can claim it) =="
    Set-Disk -Number $DiskNumber -IsOffline $true
}

Write-Host "== Attaching disk to WSL2 =="
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
wsl --mount "\\.\PHYSICALDRIVE$DiskNumber" --bare 2>&1 | Out-Null
$attachExit = $LASTEXITCODE
$ErrorActionPreference = $prevEAP
if ($attachExit -ne 0) {
    Write-Host "wsl --mount reported an issue (commonly just 'already attached' from a previous run) -- continuing; connect.sh below fails clearly if the drive really isn't reachable."
}

Write-Host "== Mounting and starting the stack inside WSL2 ($Distro) =="
# Written to a real file and run from there, rather than passed inline as a
# long quote-heavy `bash -c "..."` argument: that shape of command gets mangled
# by PowerShell's native-argument reconstruction, which cost real debugging time
# elsewhere in this project. Runs as `-u root` rather than `sudo` - a nested
# `wsl -d ... -- sudo ...` call from a PowerShell script proved unreliable in
# practice, while `-u root` is authenticated by this already-elevated Windows
# session instead of a Linux password. `--cd ~` avoids WSL trying (and failing)
# to translate this script's working directory, which matters when it's run
# from a UNC network path that WSL can't map at all.
$scriptWsl = "/mnt/" + $ScriptDir.Substring(0, 1).ToLower() + "/" + $ScriptDir.Substring(3).Replace('\', '/')
$helperWin = Join-Path $env:TEMP "portableai-connect-helper.sh"
$helperLines = @(
    "set -e"
    "bash '$scriptWsl/connect.sh'"
)
$helperContent = ($helperLines -join "`n") + "`n"
[System.IO.File]::WriteAllText($helperWin, $helperContent, (New-Object System.Text.UTF8Encoding $false))
$helperWsl = "/mnt/" + $helperWin.Substring(0, 1).ToLower() + "/" + $helperWin.Substring(3).Replace('\', '/')

wsl -d $Distro -u root --cd ~ -- bash $helperWsl
$connectExit = $LASTEXITCODE
Remove-Item $helperWin -ErrorAction SilentlyContinue

if ($connectExit -ne 0) {
    Write-Error "connect.sh failed inside WSL2 (exit code $connectExit) - see its output above. The stack is not up. NOT starting the keep-alive, and NOT releasing the disk: fix the reported problem and re-run. If you want to unplug the drive, run disconnect.ps1 first."
    exit 1
}

Write-Host "== Starting WSL keep-alive =="
# WSL2 stops a distro's entire VM instance within seconds of the last attached
# wsl.exe process exiting - even with systemd and an enabled docker.service
# inside it. When that instance goes down it takes dockerd, every container AND
# the bare-attached physical disk with it, so the drive's mount point simply
# ceases to exist. A trivial always-attached process is what actually keeps the
# rig running between commands.
if (Test-Path $KeepAlivePidFile) {
    $oldPid = Get-Content $KeepAlivePidFile -ErrorAction SilentlyContinue
    if ($oldPid) { Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue }
}
$keepAlive = Start-Process -FilePath "wsl.exe" -ArgumentList "-d", $Distro, "--cd", "~", "--", "sleep", "infinity" -WindowStyle Hidden -PassThru
Set-Content -Path $KeepAlivePidFile -Value $keepAlive.Id
Write-Host "Keep-alive running (PID $($keepAlive.Id))."

# Re-registered here, not just at install time: disconnect.ps1 removes this task
# (you're taking the drive away), so without restoring it here a
# disconnect/reconnect cycle would silently leave you with no restart survival -
# and you'd only find out after the next reboot.
$autoConnectScript = Join-Path $ScriptDir "autoconnect-task.ps1"
if (Test-Path $autoConnectScript) {
    & $autoConnectScript -Action register -Distro $Distro -Quiet
    Write-Host "Auto-connect at logon is registered (removed again by disconnect.ps1)."
}

Write-Host ""
Write-Host "Connected. Open WebUI: http://localhost:8080"
Write-Host ""
Write-Host "Notes:"
Write-Host "  - The keep-alive itself does not survive a reboot or logout, but the"
Write-Host "    auto-connect task above brings the rig back ~45s after you log in."
Write-Host "    If it hasn't come back, run this script again."
Write-Host "  - Before unplugging the drive, run '.\disconnect.ps1' - pulling it while the"
Write-Host "    filesystem is mounted and Docker's data-root is live risks corrupting it."
