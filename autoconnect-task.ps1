#Requires -RunAsAdministrator
<#
Portable AI rig - restart survival.

Registers (or removes) a Windows Scheduled Task that runs connect.ps1 at logon,
so the rig comes back up by itself after a reboot instead of needing connect.ps1
run by hand every time.

This exists because the keep-alive cannot survive a restart: WSL2 tears down the
distro's whole VM instance when the last attached wsl.exe process exits, taking
dockerd, every container, and the bare-attached physical disk with it. Nothing
inside WSL2 or on the drive can prevent that - only something on the Windows side
re-running the attach can bring it back.

Lifecycle, so the task never outlives its purpose:
  install-windows.ps1  -> registers it (rig is now set up on this machine)
  connect.ps1          -> re-registers it (reconnecting restores auto-start)
  disconnect.ps1       -> removes it (you're taking the drive away)

Kept as one script called by all three, rather than the same 30 lines copied
into each, so the task definition can only ever drift in one place.

The task runs elevated with no UAC prompt, so it never points at the repo
checkout: that is normally a folder the everyday, unelevated user can write to,
and anything running as that user could edit connect.ps1 there and get
Administrator at the next logon. Registering copies connect.ps1, connect.sh and
this script into a per-distro folder under Program Files (writable only by
Administrators) and points the task at that copy. Re-running connect.ps1 or the
installer from the checkout refreshes the copy; unregistering deletes it.

Usage (normally called by the other scripts, not directly):
  .\autoconnect-task.ps1 -Action register -Distro Ubuntu-24.04
  .\autoconnect-task.ps1 -Action unregister -Distro Ubuntu-24.04
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("register", "unregister")]
    [string]$Action,

    [string]$Distro = "Ubuntu",

    # Where connect.ps1 keeps its keep-alive PID file. Defaults to this script's
    # folder (the checkout), which is where disconnect.ps1 looks for it; passed
    # through explicitly when the protected copy re-registers itself, so the
    # task's connect.ps1 still writes the PID where disconnect.ps1 will find it.
    [string]$StateDir = "",

    # Suppress the informational output, for callers that already print their
    # own progress. Failures are still reported.
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }

# Scoped to the distro. Register-ScheduledTask below uses -Force, so a single
# fixed name would mean setting up a second rig in a different WSL distro
# silently replaced the first one's task instead of adding its own - exactly the
# bug the share-watcher task had.
$TaskName = "PortableAI Auto-Connect ($Distro)"

# Program Files rather than ProgramData: any user can create folders in
# ProgramData, so an unelevated process could pre-create this one and keep write
# access to it as its owner. Program Files only lets Administrators create
# anything, and what it inherits (Users read/execute, Administrators and SYSTEM
# full control) is exactly the ACL wanted here, so nothing needs re-locking.
$safeDistro = $Distro -replace '[^A-Za-z0-9._-]', '_'
$InstallDir = Join-Path $env:ProgramFiles "PortaBrain\autoconnect\$safeDistro"

# Read into a script-scoped flag here rather than referencing $Quiet from inside
# the function. It works either way at runtime - PowerShell's scoping means a
# nested function can see the caller's variables - but relying on that makes the
# dependency invisible, and PSScriptAnalyzer rightly reported $Quiet as unused
# because nothing in this scope touched it.
$script:ShowInfo = -not $Quiet

function Write-Info([string]$Message) {
    if ($script:ShowInfo) { Write-Host $Message }
}

if ($Action -eq "unregister") {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Info "Removed scheduled task '$TaskName' - the rig will no longer auto-connect at logon."
    } else {
        Write-Info "No scheduled task '$TaskName' registered - nothing to remove."
    }
    if (Test-Path $InstallDir) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
        Write-Info "Removed the task's protected script copy at '$InstallDir'."
    }
    exit 0
}

if (-not $StateDir) { $StateDir = $ScriptDir }

# Every file the elevated task runs: connect.ps1, the connect.sh it runs as root
# inside WSL2, and this script, which connect.ps1 calls to re-register.
$taskFiles = @("connect.ps1", "connect.sh", "autoconnect-task.ps1")
foreach ($f in $taskFiles) {
    if (-not (Test-Path (Join-Path $ScriptDir $f))) {
        Write-Error "$f not found next to this script in '$ScriptDir' - can't register a task that points at nothing."
        exit 1
    }
}

# When connect.ps1 runs from the protected copy it calls this script from there
# too, and then the copy is already the source - nothing to refresh.
$sourceFull = [System.IO.Path]::GetFullPath($ScriptDir).TrimEnd('\')
$installFull = [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
if ($sourceFull -ne $installFull) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    foreach ($f in $taskFiles) {
        Copy-Item -LiteralPath (Join-Path $ScriptDir $f) -Destination (Join-Path $InstallDir $f) -Force
    }
}
$connectScript = Join-Path $InstallDir "connect.ps1"

$psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$conhostExe = Join-Path $env:SystemRoot "System32\conhost.exe"

# -ExecutionPolicy Bypass is required, not optional: Windows desktop editions
# default to a Restricted policy that blocks running any .ps1 at all, so without
# it this task fails silently on a stock machine. -IfPresent makes a boot without
# the drive attached a quiet no-op rather than a failed task.
$psArgs = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$connectScript`" -Distro `"$Distro`" -StateDir `"$StateDir`" -IfPresent"

# Launched via 'conhost.exe --headless' so no console window is ever created.
# powershell.exe's own -WindowStyle Hidden is applied only after the process has
# started, by which point the console host has already painted a window - which
# means a visible flash on every logon.
# Deliberately NOT called $action: PowerShell variable names are
# case-insensitive, so assigning to $action clobbers this script's own $Action
# parameter, and the [ValidateSet] on it then rejects the MSFT_TaskExecAction
# object with a thoroughly baffling error. Confirmed live.
if (Test-Path $conhostExe) {
    $taskAction = New-ScheduledTaskAction -Execute $conhostExe -Argument "--headless `"$psExe`" $psArgs"
} else {
    $taskAction = New-ScheduledTaskAction -Execute $psExe -Argument $psArgs
}

# At logon rather than at startup, and as this specific user rather than SYSTEM:
# WSL2 distros are per-user, so a task running as SYSTEM would look for a distro
# that doesn't exist in that context, and any keep-alive it started would belong
# to the wrong session.
$currentUser = "$env:USERDOMAIN\$env:USERNAME"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser

# A 45-second delay because at logon there is a genuine race: an external USB
# drive may not be enumerated yet, and WSL2 itself may not be ready. connect.ps1
# retries blkid internally once it gets going, but it can't retry a disk Windows
# hasn't noticed at all - and with -IfPresent it would just exit quietly, leaving
# the rig down until you noticed.
$trigger.Delay = "PT45S"

# RunLevel Highest because connect.ps1 requires elevation (wsl --mount and
# Set-Disk both need it).
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

Write-Info "Registered scheduled task '$TaskName' (runs the protected copy in '$InstallDir')."
Write-Info "  The rig will attach and start itself ~45s after you log on, if the drive is plugged in."
Write-Info "  'disconnect.ps1' removes it again. To remove it by hand:"
Write-Info "    Unregister-ScheduledTask -TaskName `"$TaskName`" -Confirm:`$false"
