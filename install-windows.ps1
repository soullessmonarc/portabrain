#Requires -RunAsAdministrator
<#
Portable AI rig - generic public installer, Windows launcher.

Run this from an elevated PowerShell. It lists the physical disks on this
machine, lets you pick which one to use, attaches it to WSL2, then hands off
to install.sh (in this same folder) to do everything else - including
asking you which drive/mount-point/network-share options you want, so
nothing here is tied to any specific disk or machine.

This script offers to install WSL itself (via `wsl --install`) and the
Ubuntu distro (with a non-interactive user setup) if either is missing, so
a fresh machine is normally just a couple of prompts away from working -
though enabling WSL for the first time can still require one reboot, which
this script detects and tells you about rather than silently continuing.
The one thing it still can't do for you:
  - The NVIDIA GPU driver on the Windows host, if this machine has an
    NVIDIA GPU (WSL2 GPU passthrough uses the host driver directly) -
    install that manually first.

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

Write-Host "== Checking WSL is installed =="
$wslCmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
$wslInstalled = $false
if ($wslCmd) {
    # A failing native command whose stderr is redirected (even to $null)
    # gets wrapped as a terminating NativeCommandError under
    # $ErrorActionPreference = "Stop" in PowerShell 5.1, even though the
    # exit code is meant to be handled gracefully via $LASTEXITCODE below -
    # confirmed live on the non-template copy of this repo: this exact
    # pattern aborted the whole script instead of falling through to the
    # "not installed" branch as intended. Guard it.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    wsl --status *> $null
    $wslInstalled = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prevEAP
}
if (-not $wslInstalled) {
    Write-Host "WSL is not installed on this machine."
    $installWsl = Read-Host "Install it now? [y/N]"
    if ($installWsl -notmatch '^[Yy]') {
        Write-Error "WSL is required to run this on Windows. Install it manually ('wsl --install') and re-run this script."
        exit 1
    }

    Write-Host "== Installing WSL =="
    # `wsl --install` (not `winget install Microsoft.WSL`) - on a machine
    # where the underlying Windows optional features
    # (VirtualMachinePlatform, WSL itself) were never enabled, only this
    # form actually enables them via DISM; the winget package alone can
    # leave a bare machine still non-functional. Confirmed live on the
    # non-template copy of this repo: this exact scenario happened on a
    # real machine and needed a reboot afterward.
    wsl --install
    if ($LASTEXITCODE -ne 0) {
        Write-Error "wsl --install failed. Install it manually and re-run this script."
        exit 1
    }

    # DISM-based feature enablement can report success while still leaving
    # WSL non-functional until a reboot - verify directly rather than
    # trusting the exit code alone.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    wsl --status *> $null
    $wslNowWorks = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prevEAP

    if (-not $wslNowWorks) {
        Write-Error "WSL was installed but isn't functional yet - this machine needs a reboot before it will work (the underlying Windows features were just enabled). Reboot, then re-run this script."
        exit 1
    }
}

Write-Host "== Checking WSL distro '$Distro' =="
$distros = wsl -l -q
if ($distros -notcontains $Distro) {
    Write-Host "WSL distro '$Distro' not found."
    $autoInstall = Read-Host "Install and set it up now? This registers the distro and creates a new Linux user account inside it. [y/N]"
    if ($autoInstall -notmatch '^[Yy]') {
        Write-Error "WSL distro '$Distro' not found. Install it first: wsl --install -d $Distro (one-time, interactive)."
        exit 1
    }

    Write-Host "== Installing WSL distro '$Distro' =="
    # --no-launch skips the automatic first launch, which is what normally
    # triggers Ubuntu's interactive username/password wizard - we do that
    # step ourselves below instead, non-interactively, via the always-
    # available root account.
    wsl --install -d $Distro --no-launch
    if ($LASTEXITCODE -ne 0) {
        Write-Error "wsl --install -d $Distro failed. If WSL2 itself isn't installed/updated yet, run 'wsl --install' and 'wsl --update' first (this can require a reboot the first time), then re-run this script."
        exit 1
    }

    $newUsername = Read-Host "Choose a username for the new Linux user"
    $newPasswordSecure = Read-Host "Choose a password for it" -AsSecureString
    $newPasswordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($newPasswordSecure))

    Write-Host "== Creating user '$newUsername' inside $Distro =="
    # Added to the sudo group for the human's own manual/interactive use
    # later - this script's own automated steps deliberately do NOT rely
    # on sudo at all (see below): a nested `wsl -d ... -- sudo ...` call
    # from a PowerShell script proved unreliable in practice on the non-
    # template copy of this repo, failing authentication consistently even
    # after granting passwordless sudo explicitly. Every automated
    # privileged step instead uses `wsl -u root` directly, which is
    # authenticated by this already-elevated Windows session rather than a
    # Linux password, so it can't hit the same failure mode.
    wsl -d $Distro -u root --cd ~ -- bash -c "useradd -m -s /bin/bash '$newUsername' && usermod -aG sudo '$newUsername'"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create Linux user '$newUsername' (see output above) - possibly an invalid username or a leftover account from a previous failed attempt. Fix the issue (e.g. pick a different username) and re-run."
        exit 1
    }
    # Piped via stdin (not embedded in the command line) so the password
    # never shows up in a process listing or gets echoed into this script's
    # own transcript log.
    "${newUsername}:${newPasswordPlain}" | wsl -d $Distro -u root --cd ~ -- chpasswd
    if ($LASTEXITCODE -ne 0) {
        $newPasswordPlain = $null
        Write-Error "Failed to set the password for '$newUsername' (see output above). The account exists but has no usable password - fix manually (wsl -d $Distro -u root -- passwd $newUsername) or re-run this script."
        exit 1
    }
    $newPasswordPlain = $null
    # Explicitly includes [boot] systemd=true, not just [user] - this file
    # is being created fresh here (truncating `>`), and a fresh Ubuntu WSL
    # image's own default already has systemd enabled, so overwriting with
    # *only* the [user] section would silently disable it. Confirmed live
    # on the non-template copy of this repo: this exact bug broke Docker
    # entirely on a freshly-bootstrapped machine ("System has not been
    # booted with systemd as init system").
    wsl -d $Distro -u root --cd ~ -- bash -c "printf '[boot]\nsystemd=true\n\n[user]\ndefault=$newUsername\n' > /etc/wsl.conf"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to write /etc/wsl.conf (see output above) - the distro exists but won't default to the right user/systemd config. Fix manually and re-run."
        exit 1
    }
    wsl --terminate $Distro
    Write-Host "Distro '$Distro' is set up with default user '$newUsername'."
}

Write-Host "== Checking systemd is enabled for '$Distro' =="
# Self-healing, runs every time regardless of whether the distro was just
# bootstrapped above or already existed - covers a distro whose
# /etc/wsl.conf was already left systemd-less by an earlier run of this
# script (see the fix note above) before this check existed. Everything
# from Docker onward depends on systemd actually being PID 1, so this has
# to be caught and fixed *before* install.sh runs, not after it fails
# partway through.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
wsl -d $Distro -u root --cd ~ -- grep -q '^systemd=true' /etc/wsl.conf 2>$null
$systemdEnabled = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = $prevEAP

if (-not $systemdEnabled) {
    Write-Host "systemd isn't enabled for '$Distro' yet - fixing /etc/wsl.conf and restarting WSL2 to apply it (stops anything currently running inside it)..."
    $currentUser = (wsl -d $Distro --cd ~ -- whoami 2>$null).Trim()
    $wslConfWin = Join-Path $env:TEMP "portableai-wslconf-helper.conf"
    $wslConfLines = @("[boot]", "systemd=true", "")
    if ($currentUser -and $currentUser -ne "root") {
        $wslConfLines += @("[user]", "default=$currentUser", "")
    }
    $wslConfContent = ($wslConfLines -join "`n")
    [System.IO.File]::WriteAllText($wslConfWin, $wslConfContent, (New-Object System.Text.UTF8Encoding $false))
    $wslConfWsl = "/mnt/" + $wslConfWin.Substring(0, 1).ToLower() + "/" + $wslConfWin.Substring(3).Replace('\', '/')
    wsl -d $Distro -u root --cd ~ -- cp $wslConfWsl /etc/wsl.conf
    Remove-Item $wslConfWin -ErrorAction SilentlyContinue
    # `wsl --terminate` is an abrupt VM shutdown, not a graceful `systemctl
    # stop` - if docker/containerd happen to already be running here (a
    # machine that hasn't yet had install.sh's auto-start-disable fix
    # applied will have them auto-started at this distro's last boot),
    # terminating while they're mid-write is exactly the kind of event that
    # corrupts overlay2/containerd storage. Stop them cleanly first if
    # they're up; harmless no-op if they aren't.
    $prevEAP2 = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    wsl -d $Distro -u root --cd ~ -- systemctl stop docker.socket docker.service containerd.service 2>$null
    $ErrorActionPreference = $prevEAP2
    wsl --terminate $Distro
    Write-Host "systemd enabled for '$Distro'."
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
# `-u root` (not `sudo`) - see the note above the user-creation step for
# why: a nested `wsl -d ... -- sudo ...` call proved unreliable in
# practice on the non-template copy of this repo, while `-u root` is
# authenticated by this already-elevated Windows session and can't hit
# that failure mode. `--cd ~` avoids WSL trying and failing to translate
# this script's own working directory (e.g. a UNC network-share path,
# which WSL can't map to a Linux path at all) into the new session's
# starting directory.
wsl -d $Distro -u root --cd ~ -- bash -c "sleep 2; bash '$linuxScriptPath/install.sh'"

Write-Host ""
$installWatcher = Read-Host "Install a lightweight scheduled task that pops a toast if the network share (if you set one up) goes down or reconnects mid-session? [Y/n]"
if ($installWatcher -notmatch '^[Nn]') {
    & (Join-Path $ScriptDir "install-share-watcher.ps1") -Distro $Distro
}

Write-Host ""
Write-Host "Done (or see errors above). Open WebUI should be at http://localhost:8080 once the stack finishes starting."
