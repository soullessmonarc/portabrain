#Requires -RunAsAdministrator
<#
Portable AI rig - disconnect (Windows launcher).

Run this from an elevated PowerShell before physically unplugging the drive. It
stops the stack cleanly inside WSL2, unmounts the filesystem, releases the raw
disk from WSL2, and stops the keep-alive that connect.ps1 started.

Pulling the drive without this risks corrupting it: the ext4 filesystem is
mounted and Docker's data-root lives on it, so there are live writes to a
filesystem that would simply vanish.

If Docker Desktop is running on this machine it actively probes WSL2 distros
over their docker.sock, and any connection attempt triggers systemd socket
activation and respawns dockerd inside the distro - which keeps the drive's
filesystem busy and makes the unmount fail. This script stops Docker Desktop
for just the duration of the eject and relaunches it afterwards (even if the
eject fails partway), so an existing Docker Desktop setup is left as it was.

Usage:
  .\disconnect.ps1
  .\disconnect.ps1 -DiskNumber 2
  .\disconnect.ps1 -Distro Ubuntu-24.04
#>
param(
    [int]$DiskNumber = -1,
    [string]$Distro = "Ubuntu"
)

$ErrorActionPreference = "Stop"
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
$KeepAlivePidFile = Join-Path $ScriptDir ".keepalive.pid"

Write-Host ""
Write-Host "===== Portable AI Rig - Disconnect ====="
Write-Host ""

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Write-Error "wsl.exe isn't available on this machine - nothing to disconnect."
    exit 1
}

# Checked up front, because getting this wrong is easy and the consequence is
# nasty: with a name that doesn't exist, every step below fails, the script
# refuses to release the disk (correctly - it can't verify the filesystem was
# unmounted), and the actual cause shows up only as a raw
# "Wsl/Service/WSL_E_DISTRO_NOT_FOUND" from deep inside eject.sh. Confirmed
# live from a single mistyped character. A wrong distro name here is also the
# one case where a user might reasonably conclude "the eject failed, I'll just
# unplug it" - which is exactly how a drive gets corrupted.
Write-Host "== Checking WSL distro '$Distro' =="
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$distros = wsl -l -q 2>$null
$ErrorActionPreference = $prevEAP
$distroList = (($distros -join "`n") -replace "`0", "")
if ($distroList -notmatch [regex]::Escape($Distro)) {
    Write-Error "WSL distro '$Distro' doesn't exist on this machine. Nothing has been changed and the disk has NOT been released - do not unplug the drive yet. Distros found: $((($distroList -split "`n") | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }) -join ', '). Re-run with the right -Distro name."
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms

$dockerDesktopProcNames = "Docker Desktop", "com.docker.backend", "com.docker.build", "com.docker.dev-envs", "com.docker.proxy"
$dockerDesktopWasRunning = $false
$dockerDesktopExePath = $null

function Stop-DockerDesktop {
    $procs = Get-Process -Name $dockerDesktopProcNames -ErrorAction SilentlyContinue
    if (-not $procs) {
        Write-Host "Docker Desktop isn't running -- nothing to stop."
        return
    }

    $mainProc = $procs | Where-Object { $_.Name -eq "Docker Desktop" -and $_.Path } | Select-Object -First 1
    $script:dockerDesktopExePath = if ($mainProc) { $mainProc.Path } else { "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe" }

    $consent = [System.Windows.Forms.MessageBox]::Show(
        "Docker Desktop needs to be stopped to unmount the rig drive safely. It will be relaunched automatically afterwards. Continue?",
        "Portable AI Rig - Disconnect",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($consent -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-Error "Declined to stop Docker Desktop -- the drive can't be safely unmounted while it's running. Aborting."
        exit 1
    }

    $script:dockerDesktopWasRunning = $true
    Write-Host "== Stopping Docker Desktop (it respawns dockerd inside WSL2 via socket activation, which blocks the unmount) =="
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}

function Start-DockerDesktopIfNeeded {
    if (-not $dockerDesktopWasRunning) { return }
    Write-Host "== Relaunching Docker Desktop =="
    if (-not ($dockerDesktopExePath -and (Test-Path $dockerDesktopExePath))) {
        Write-Warning "Docker Desktop was running before but its executable path couldn't be confirmed ($dockerDesktopExePath) -- please relaunch it manually."
        return
    }
    Start-Process -FilePath $dockerDesktopExePath
}

try {
    # Docker Desktop's WSL integration can be what actually backs
    # /var/run/docker.sock, so the graceful `docker compose stop` needs it still
    # running - but leaving it up through the later teardown lets it respawn
    # dockerd the instant that touches docker.socket, which is exactly what
    # stopping it is meant to prevent. So: stop the stack, THEN stop Docker
    # Desktop, THEN do the rest of the teardown.
    $scriptWsl = "/mnt/" + $ScriptDir.Substring(0, 1).ToLower() + "/" + $ScriptDir.Substring(3).Replace('\', '/')

    Write-Host "== Stopping the stack (while Docker's still reachable) =="
    wsl -d $Distro -u root --cd ~ -- bash "$scriptWsl/eject.sh" stop-stack
    if ($LASTEXITCODE -ne 0) {
        Write-Error "eject.sh stop-stack failed inside WSL2 (see output above). NOT releasing the disk, since the filesystem may still be mounted and live. Fix the issue and re-run."
        exit 1
    }

    Stop-DockerDesktop

    Write-Host "== Tearing down (daemons, nested mounts, sync) =="
    wsl -d $Distro -u root --cd ~ -- bash "$scriptWsl/eject.sh" teardown
    if ($LASTEXITCODE -ne 0) {
        Write-Error "eject.sh teardown failed inside WSL2 (see output above). NOT releasing the disk, since the filesystem may still be mounted. Fix the issue and re-run."
        exit 1
    }

    # eject.sh can't unmount the drive itself: its own script file may live on
    # that mount, so bash holds a file descriptor on it for as long as the
    # script runs. Do it here, as a separate bare command, now that eject.sh
    # has fully exited and released that handle.
    Write-Host "== Unmounting the drive =="
    $helperWin = Join-Path $env:TEMP "portableai-unmount-helper.sh"
    $helperLines = @(
        '# Enter systemd''s mount namespace before looking at anything. Unlike'
        '# connect.sh and eject.sh, this helper is standalone bash with no script'
        '# to delegate to, so it was left checking a private namespace - where the'
        '# drive is never mounted. Confirmed live, and the consequence is exactly'
        '# what this script exists to prevent: it reported "not mounted - nothing'
        '# to unmount", skipped the unmount, and the raw disk was then released'
        '# while the filesystem was still mounted in systemd''s namespace. The'
        '# kernel log recorded the result - "Aborting journal", "lost sync page'
        '# write", "I/O error when updating journal superblock" - and the drive'
        '# needed journal recovery on its next mount. Every disconnect had been'
        '# doing this.'
        'if [ -r /proc/1/ns/mnt ] && [ "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ]; then'
        '  if command -v nsenter >/dev/null 2>&1; then'
        '    exec nsenter --mount=/proc/1/ns/mnt --wd=/ -- bash "$0" "$@"'
        '  fi'
        '  echo "ERROR: private mount namespace and no nsenter - cannot verify the" >&2'
        '  echo "filesystem is unmounted, so the disk will NOT be released." >&2'
        '  exit 1'
        'fi'
        'LABEL=PORTABLEAI'
        'PART="$(blkid -L "$LABEL" 2>/dev/null || true)"'
        '# Deliberately no early exit when the drive is unmounted: on an'
        '# encrypted rig the container can be unlocked WITHOUT being mounted, and'
        '# an early return here would skip the luksClose below and hand the disk'
        '# back to Windows with the mapping still open.'
        'if [ -z "$PART" ]; then'
        '  echo "No filesystem labelled $LABEL mounted or unlocked."'
        'else'
        '  MP="$(findmnt -n -o TARGET --source "$PART" 2>/dev/null | head -1 || true)"'
        '  if [ -z "$MP" ]; then'
        '    echo "$PART is not mounted - nothing to unmount."'
        '  else'
        '    echo "Unmounting $MP"'
        '    if ! umount "$MP"; then'
        '      echo "ERROR: umount $MP failed. What is holding it:" >&2'
        '      fuser -vm "$MP" >&2 2>&1 || true'
        '      lsof +D "$MP" 2>&1 | head -30 >&2 || true'
        '      exit 1'
        '    fi'
        '  fi'
        'fi'
        'sync'
        '# Lock an encrypted drive again once its filesystem is unmounted. This'
        '# has to happen here rather than in eject.sh: eject.sh deliberately'
        '# leaves the unmount to its caller, and a LUKS container cannot be'
        '# closed while the filesystem inside it is still mounted. Releasing the'
        '# raw disk to Windows with the mapping still open would leave a stale'
        '# /dev/mapper entry pointing at hardware that has gone.'
        'if [ -e /dev/mapper/portableai ]; then'
        '  echo "Locking the encrypted container"'
        '  if ! cryptsetup luksClose portableai; then'
        '    echo "ERROR: luksClose failed - something still has the mapping open." >&2'
        '    dmsetup info portableai >&2 2>&1 || true'
        '    exit 1'
        '  fi'
        '  echo "Locked."'
        'fi'
    )
    $helperContent = ($helperLines -join "`n") + "`n"
    [System.IO.File]::WriteAllText($helperWin, $helperContent, (New-Object System.Text.UTF8Encoding $false))
    $helperWsl = "/mnt/" + $helperWin.Substring(0, 1).ToLower() + "/" + $helperWin.Substring(3).Replace('\', '/')
    wsl -d $Distro -u root --cd ~ -- bash $helperWsl
    $umountExit = $LASTEXITCODE
    Remove-Item $helperWin -ErrorAction SilentlyContinue
    if ($umountExit -ne 0) {
        Write-Error "Unmount failed (see diagnostics above). NOT releasing the disk from WSL2, since the filesystem is still mounted. Fix the issue and re-run."
        exit 1
    }

    Write-Host "== Releasing the disk from WSL2 =="
    $linuxGuid = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"  # GPT partition type: Linux filesystem data
    if ($DiskNumber -lt 0) {
        $candidates = Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.GptType -eq "{$linuxGuid}" } | Select-Object -ExpandProperty DiskNumber -Unique
        if (-not $candidates) {
            Write-Warning "No disk with a Linux (ext4) partition found -- it may already be released. Skipping wsl --unmount."
            $DiskNumber = -1
        } elseif (@($candidates).Count -gt 1) {
            Write-Host "More than one candidate disk found:"
            Get-Disk | Where-Object { $_.Number -in $candidates } | Format-Table Number, FriendlyName, @{n='GB';e={[math]::Round($_.Size/1GB)}}, BusType
            Write-Error "Re-run with -DiskNumber <N> to pick one."
            exit 1
        } else {
            $DiskNumber = @($candidates)[0]
        }
    }

    if ($DiskNumber -ge 0) {
        wsl --unmount "\\.\PHYSICALDRIVE$DiskNumber"
        if ($LASTEXITCODE -ne 0) {
            Write-Error "wsl --unmount failed. Do not unplug the drive yet."
            exit 1
        }
        # connect.ps1 and install-windows.ps1 both take the disk Offline in
        # Windows before handing it to WSL2, and nothing here ever put it back.
        # `wsl --unmount` releases the disk from WSL but does NOT clear the
        # offline flag, so the drive stayed Offline in Disk Management forever
        # after the first disconnect: invisible in Explorer, and confusing on any
        # other machine, which sees a healthy partition it refuses to mount.
        # Reversing our own change is this script's job, since it is the one
        # undoing what connect.ps1 did.
        $disk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
        if ($disk -and $disk.IsOffline) {
            Write-Host "== Bringing disk $DiskNumber back online in Windows =="
            Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction SilentlyContinue
            if ($?) {
                Write-Host "Online."
            } else {
                Write-Warning "Could not bring disk $DiskNumber back online automatically. It is safe to unplug; if you keep it attached, set it Online in Disk Management (or: Set-Disk -Number $DiskNumber -IsOffline `$false)."
            }
        }
    }

    Write-Host "== Stopping the WSL keep-alive =="
    if (Test-Path $KeepAlivePidFile) {
        $oldPid = Get-Content $KeepAlivePidFile -ErrorAction SilentlyContinue
        if ($oldPid) { Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue }
        Remove-Item $KeepAlivePidFile -ErrorAction SilentlyContinue
        Write-Host "Stopped."
    } else {
        Write-Host "No keep-alive recorded."
    }

    # Removed on the way out: running this script means the drive is being taken
    # away, so a task that tries to attach it at every logon has no purpose. It
    # would exit quietly thanks to -IfPresent, but leaving a scheduled task
    # behind that reaches for hardware the user has deliberately removed is the
    # kind of leftover that gets found months later and isn't recognised.
    # connect.ps1 registers it again next time the drive comes back.
    Write-Host "== Removing the auto-connect scheduled task =="
    $autoConnectScript = Join-Path $ScriptDir "autoconnect-task.ps1"
    if (Test-Path $autoConnectScript) {
        & $autoConnectScript -Action unregister -Distro $Distro
    } else {
        Write-Warning "autoconnect-task.ps1 not found next to this script - if an auto-connect task was registered, remove it with: Unregister-ScheduledTask -TaskName `"PortableAI Auto-Connect ($Distro)`" -Confirm:`$false"
    }

    Write-Host ""
    Write-Host "Done. Safe to physically remove the drive now."
}
finally {
    # Always put Docker Desktop back, even if the eject failed partway through -
    # a failed eject shouldn't also leave the user's normal Docker Desktop
    # setup stopped.
    Start-DockerDesktopIfNeeded
}
