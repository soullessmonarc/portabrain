#Requires -RunAsAdministrator
<#
Portable AI rig - generic public installer, Windows launcher.

Run this from an elevated PowerShell. It lists the physical disks on this
machine, lets you pick which one to use, attaches it to WSL2, then hands off
to install.sh (in this same folder) to do everything else - including
asking you which drive/mount-point/network-share options you want, so
nothing here is tied to any specific disk or machine.

Prerequisites this script does NOT install for you:
  - WSL2 itself (run `wsl --install` once per machine if missing)
  - An Ubuntu distro under WSL2 (`wsl --install -d Ubuntu` - this is an
    interactive first-run that creates a Linux user, so it's left to you)
  - The NVIDIA GPU driver on the Windows host, if this machine has an
    NVIDIA GPU (WSL2 GPU passthrough uses the host driver directly)

Usage:
  .\install-windows.ps1
  .\install-windows.ps1 -Distro Ubuntu-22.04
#>
param(
    [string]$Distro = "Ubuntu"
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot

Write-Host ""
Write-Host "===== Portable AI Rig Setup (Windows) ====="
Write-Host ""

Write-Host "== Checking WSL distro '$Distro' =="
$distros = wsl -l -q
if ($distros -notcontains $Distro) {
    Write-Error "WSL distro '$Distro' not found. Install it first: wsl --install -d $Distro (one-time, interactive)."
    exit 1
}

Write-Host "== Checking WSL2 networking mode =="
# WSL2's default (NAT) networking can silently block access to LAN devices
# (e.g. a network share) when a VPN is active on this machine, because its
# NAT layer doesn't replicate the host's own "bypass VPN for local subnets"
# routing decision. "Mirrored" mode fixes this by sharing the host's real
# network stack with WSL2 instead of a separate NAT'd one. Needs Windows 11
# 22H2+ (or a recent enough Windows 10 WSL package) - older WSL versions
# just ignore the unrecognized config key rather than failing.
$wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
$wslConfigText = if (Test-Path $wslConfigPath) { Get-Content $wslConfigPath -Raw } else { "" }
if ($wslConfigText -notmatch '(?im)^\s*networkingMode\s*=\s*mirrored\s*$') {
    Write-Host "WSL2's default networking can block LAN/network-share access while a VPN is active on this machine (a known WSL2 limitation)."
    Write-Warning "Enabling 'mirrored' mode changes a machine-wide WSL2 setting (affects every WSL distro, not just this rig) and needs Windows 11 22H2+ or a recent Windows 10 WSL update. Skip if unsure - you can remove the line from $wslConfigPath later either way."
    $enableMirrored = Read-Host "Enable WSL2 mirrored networking mode now? [y/N]"
    if ($enableMirrored -match '^[Yy]') {
        if ($wslConfigText -match '(?im)^\[wsl2\]\s*$') {
            $updated = $wslConfigText -replace '(?im)(^\[wsl2\]\s*$)', "`$1`nnetworkingMode=mirrored"
        } else {
            $updated = $wslConfigText.TrimEnd() + "`n`n[wsl2]`nnetworkingMode=mirrored`n"
        }
        Set-Content -Path $wslConfigPath -Value $updated
        Write-Host "Set networkingMode=mirrored in $wslConfigPath - restarting WSL2 for it to take effect..."
        wsl --shutdown
        Start-Sleep -Seconds 3
    }
}

Write-Host "== Available disks =="
$disks = Get-Disk | Sort-Object Number
$disks | ForEach-Object {
    Write-Host ("  {0}) Disk {0} - {1} ({2:N0} GB) - {3}" -f $_.Number, $_.FriendlyName, ($_.Size / 1GB), $_.OperationalStatus)
}
Write-Host ""
Write-Warning "Pick carefully - the installer can reformat whatever disk you choose."
$diskNumber = Read-Host "Enter the disk number to use"

$disk = Get-Disk -Number $diskNumber
Write-Host "Using disk $diskNumber ($($disk.FriendlyName), $([math]::Round($disk.Size/1GB))GB)"

if (-not $disk.IsOffline) {
    Write-Host "== Taking disk $diskNumber offline =="
    Set-Disk -Number $diskNumber -IsOffline $true
}

Write-Host "== Attaching disk to WSL2 =="
wsl --mount "\\.\PHYSICALDRIVE$diskNumber" --bare 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "wsl --mount reported an issue (commonly just 'already attached' from a previous run) -- continuing; install.sh will fail clearly below if the disk truly isn't reachable."
}

Write-Host "== Handing off to install.sh inside WSL2 ($Distro) =="
$linuxScriptPath = "/mnt/" + $ScriptDir.Substring(0, 1).ToLower() + "/" + $ScriptDir.Substring(3).Replace('\', '/')
wsl -d $Distro -- bash -c "sleep 2; sudo bash '$linuxScriptPath/install.sh'"

Write-Host ""
$installWatcher = Read-Host "Install a lightweight scheduled task that pops a toast if the network share (if you set one up) goes down or reconnects mid-session? [Y/n]"
if ($installWatcher -notmatch '^[Nn]') {
    & (Join-Path $ScriptDir "install-share-watcher.ps1") -Distro $Distro
}

Write-Host ""
Write-Host "Done (or see errors above). Open WebUI should be at http://localhost:8080 once the stack finishes starting."
