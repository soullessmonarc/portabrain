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
$mirroredEnabled = $wslConfigText -match '(?im)^\s*networkingMode\s*=\s*mirrored\s*$'
$needsWslRestart = $false
if (-not $mirroredEnabled) {
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
        $needsWslRestart = $true
        $mirroredEnabled = $true
    }
}

# Second half of the mirrored-mode fix, and the one that actually made
# localhost:8080 work: networkingMode=mirrored ALONE is not enough for
# reliable Windows -> WSL2 localhost forwarding. Without this key, a TCP
# handshake to localhost:8080 succeeds (Test-NetConnection reports
# TcpTestSucceeded) but the HTTP request then hangs with no data ever coming
# back - confirmed live, and a genuinely confusing symptom to debug because
# a port check "passes" while nothing actually works.
if ($mirroredEnabled -and $wslConfigText -notmatch '(?im)^\s*hostAddressLoopback\s*=\s*true\s*$') {
    Write-Host "Mirrored networking needs 'hostAddressLoopback=true' for localhost:8080 to reach Open WebUI - adding it."
    $wslConfigText = if (Test-Path $wslConfigPath) { Get-Content $wslConfigPath -Raw } else { "" }
    if ($wslConfigText -match '(?im)^\[experimental\]\s*$') {
        $updated = $wslConfigText -replace '(?im)(^\[experimental\]\s*$)', "`$1`nhostAddressLoopback=true"
    } else {
        $updated = $wslConfigText.TrimEnd() + "`n`n[experimental]`nhostAddressLoopback=true`n"
    }
    Set-Content -Path $wslConfigPath -Value $updated
    $needsWslRestart = $true
}

# .wslconfig changes only take effect on the next WSL2 VM start, so restart
# once here if either of the two blocks above changed something. Docker gets
# stopped gracefully first: abruptly killing a possibly-mid-write docker
# daemon is what corrupted the original rig's overlay2/containerd storage
# during this project's development, and it costs nothing to be careful.
if ($needsWslRestart) {
    $prevEAP3 = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    wsl -d $Distro -u root --cd ~ -- systemctl stop docker.socket docker.service containerd.service 2>$null
    $ErrorActionPreference = $prevEAP3
    Write-Host "== Restarting WSL2 to apply the .wslconfig change(s) =="
    wsl --shutdown
    Start-Sleep -Seconds 3
}

# Mirrored mode's tradeoff, confirmed live: NAT mode's "localhost
# forwarding" is a special loopback proxy that bypasses Windows Firewall
# entirely, but mirrored mode exposes WSL2's ports on this host's real
# interfaces instead - if those interfaces are on the (default,
# restrictive) Public firewall profile, Windows Firewall then blocks what
# would otherwise be ordinary localhost:8080 access to Open WebUI. This is
# a self-heal (checked every run, not just when mirrored mode is *just*
# enabled above) since a machine can already have mirrored mode on from
# before this check existed, exactly as happened live on the non-template
# copy of this repo.
if ($mirroredEnabled -and -not (Get-NetFirewallRule -DisplayName "WSL2 Mirrored - Open WebUI (loopback only)" -ErrorAction SilentlyContinue)) {
    $addFirewallRule = Read-Host "WSL2 mirrored networking is on, which can block 'localhost:8080' (Open WebUI) under Windows Firewall's Public profile. Add a firewall rule scoped to this machine only (not the wider network) to fix it? [Y/n]"
    if ($addFirewallRule -notmatch '^[Nn]') {
        $selfIps = @("127.0.0.1") + (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "127.0.0.1" } | Select-Object -ExpandProperty IPAddress -Unique)
        New-NetFirewallRule -DisplayName "WSL2 Mirrored - Open WebUI (loopback only)" -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow -RemoteAddress $selfIps -Profile Any | Out-Null
        Write-Host "Firewall rule added (allows port 8080 only from this machine's own IPs, not the wider network)."
    }
}

# The list is rebuilt on every pass, and the answer is validated against a
# FRESH read rather than the list as printed. Two reasons, both seen live:
#   - An external/USB drive plugged in moments earlier can still be settling
#     when the list is built and be missing from it entirely. Confirmed live:
#     the target disk never appeared in this list at all, yet
#     'Get-Disk -Number 2' resolved it perfectly a few seconds later once the
#     user had finished typing. The old code listed once and accepted any
#     number, so it silently accepted a disk it had never shown.
#   - The reverse is just as bad: accepting a number from a stale list for a
#     drive that has since been unplugged.
# Also labels the Windows system disk explicitly and refuses it outright -
# previously the only disks offered on this machine were the user's own system
# and data drives, so "pick carefully" was advice with no safe answer.
$systemDiskNumber = $null
try {
    $systemDiskNumber = (Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction SilentlyContinue).DiskNumber
} catch { }

$diskNumber = $null
$disk = $null
while ($null -eq $diskNumber) {
    Write-Host ""
    Write-Host "== Available disks =="
    foreach ($d in (Get-Disk | Sort-Object Number)) {
        $notes = @()
        if ($null -ne $systemDiskNumber -and $d.Number -eq $systemDiskNumber) { $notes += "WINDOWS SYSTEM DISK - cannot be used" }
        if ($d.BusType -eq "USB") { $notes += "USB / removable" }
        $suffix = if ($notes.Count -gt 0) { "  <-- " + ($notes -join "; ") } else { "" }
        Write-Host ("  {0}) Disk {0} - {1} ({2:N0} GB) - {3}{4}" -f $d.Number, $d.FriendlyName, ($d.Size / 1GB), $d.OperationalStatus, $suffix)
    }
    Write-Host ""
    Write-Warning "Pick carefully - the installer can reformat whatever disk you choose."
    $answer = Read-Host "Enter the disk number to use, or 'r' to rescan"

    if ($answer -match '^\s*[Rr]\s*$') { continue }

    $parsed = 0
    if (-not [int]::TryParse(($answer -replace '\s', ''), [ref]$parsed)) {
        Write-Warning "'$answer' isn't a disk number. Try again."
        continue
    }

    $candidate = Get-Disk -Number $parsed -ErrorAction SilentlyContinue
    if (-not $candidate) {
        Write-Warning "There is no disk $parsed on this machine right now. Try again, or 'r' to rescan."
        continue
    }
    if ($null -ne $systemDiskNumber -and $parsed -eq $systemDiskNumber) {
        Write-Warning "Disk $parsed is this machine's Windows system disk ($env:SystemDrive). Refusing to use it - pick a different disk."
        continue
    }

    Write-Host ""
    Write-Host "  Selected: Disk $parsed - $($candidate.FriendlyName), $([math]::Round($candidate.Size/1GB))GB, bus $($candidate.BusType)"
    Write-Host "  Everything on this disk will be erased."
    $confirmDisk = Read-Host "Is that the correct drive? [y/N]"
    if ($confirmDisk -match '^[Yy]') {
        $diskNumber = $parsed
        $disk = $candidate
    }
}

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
# install.sh runs under `set -euo pipefail`, so it aborts with a nonzero exit
# on any failure - but nothing here used to look at that, so a completely
# failed install carried straight on to register the share watcher and print
# "Done ... Open WebUI should be at http://localhost:8080". Confirmed live: a
# run that died on a missing `parted` still reported success. Reporting a
# working stack that doesn't exist is worse than the original failure, so
# stop here instead.
if ($LASTEXITCODE -ne 0) {
    Write-Error "install.sh failed inside WSL2 (exit code $LASTEXITCODE) - see its output above for the actual error. Stopping here: the stack is NOT set up, so there is nothing for the share watcher to watch and http://localhost:8080 will not work. Fix the reported problem and re-run this script."
    exit 1
}

Write-Host "== Starting WSL keep-alive =="
# WSL2 stops a distro's entire VM instance within seconds of the last attached
# wsl.exe process exiting - even with systemd and an enabled docker.service
# inside it. When that instance goes down it takes dockerd, every container,
# AND the bare-attached physical disk with it, so the drive's mount point
# simply ceases to exist. Confirmed live: mid-install the drive was mounted
# with 1.5GB of pulled images, and minutes later /mnt/<drive>/stack did not
# exist at all and docker.sock was gone, because nothing was holding the
# instance open. A trivial always-attached process is what actually keeps the
# rig running between commands.
$keepAlivePidFile = Join-Path $ScriptDir ".keepalive.pid"
if (Test-Path $keepAlivePidFile) {
    $oldPid = Get-Content $keepAlivePidFile -ErrorAction SilentlyContinue
    if ($oldPid) { Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue }
}
$keepAlive = Start-Process -FilePath "wsl.exe" -ArgumentList "-d", $Distro, "--cd", "~", "--", "sleep", "infinity" -WindowStyle Hidden -PassThru
Set-Content -Path $keepAlivePidFile -Value $keepAlive.Id
Write-Host "Keep-alive running (PID $($keepAlive.Id)). Without this the stack stops as soon as this script exits."

# The keep-alive cannot survive a restart - WSL2 tears down the whole VM
# instance, taking the containers and the drive's attachment with it - so
# restart survival has to come from the Windows side. Registered here as part of
# the install, removed again by disconnect.ps1.
Write-Host "== Setting up restart survival =="
$autoConnectScript = Join-Path $ScriptDir "autoconnect-task.ps1"
if (Test-Path $autoConnectScript) {
    & $autoConnectScript -Action register -Distro $Distro
} else {
    Write-Warning "autoconnect-task.ps1 not found next to this script - the rig will not come back up by itself after a reboot. Run connect.ps1 manually, or restore that file."
}

Write-Host ""
Write-Host "Day-to-day from here on:"
Write-Host "  .\connect.ps1      - bring the rig up (after a reboot, or on another machine)"
Write-Host "  .\disconnect.ps1   - ALWAYS run this before unplugging the drive"

Write-Host ""
$installWatcher = Read-Host "Install a lightweight scheduled task that pops a toast if the network share (if you set one up) goes down or reconnects mid-session? [Y/n]"
if ($installWatcher -notmatch '^[Nn]') {
    & (Join-Path $ScriptDir "install-share-watcher.ps1") -Distro $Distro
}

Write-Host ""
Write-Host "Done (or see errors above). Open WebUI should be at http://localhost:8080 once the stack finishes starting."
