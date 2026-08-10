# Master Setup

End-to-end instructions for going from a blank drive to a running stack, for each
supported platform.

## Setup time

**Realistic first-install total: 45 minutes to a bit over 2 hours**, almost entirely
download time, and dominated by your internet connection more than anything else about
your machine. Every number below is a **real measurement from actually running this
installer** on this project's own hardware, not a vendor estimate or a guess - taken
from two separate install runs on two different network conditions, which is also why
several rows show a range rather than one number.

| Step | Measured | Notes |
|---|---|---|
| Partition, format, (optional) LUKS encrypt | under a minute | Fast on any SSD; not the bottleneck |
| Docker Engine + NVIDIA Container Toolkit | not independently timed | Every test run this project has done reused a distro that already had these installed. Budget a few extra minutes on a genuinely fresh machine - `apt install` plus the toolkit setup, nothing exotic |
| Container images (Ollama + ComfyUI + Open WebUI), pulled in parallel | **~16 to ~28 minutes**, bottlenecked by the ComfyUI image | Measured twice: 16.3 min on one run, 28.4 min on another, same images, different network conditions. Individually: Open WebUI 5–19 min, Ollama 9–15 min, ComfyUI 16–28 min |
| Chat + coder LLM pull (2× 7B, ~9.4GB total) | not independently isolated in testing | Estimated 5–12 min at the throughput observed elsewhere in these tests; budget more on a slow connection |
| SDXL checkpoint(s) for image generation | **~6 minutes each**, measured | ~6.5GB apiece. One is enough to start; the installer offers a second for variety |
| LTX-Video weights (checkpoint + text encoder) | **~9 min + ~5–9 min**, measured | The larger of the two files failed partway through on one real run - a transient network error, not a bug - and the installer's retry logic recovered automatically on the second attempt, adding a few minutes |

Add it up and a **from-scratch install choosing every optional weight** (both SDXL
checkpoints, video generation, uncensored models) lands around an hour on decent home
broadband, stretching past two hours on a slow connection. Skipping the second SDXL
checkpoint or video generation shortens it accordingly - `install.sh` lets you type
`skip` on any weight prompt.

**Reconnecting is fast.** None of the above repeats on a later `connect.ps1` /
`connect.sh` run - everything already on the drive is reused, verified live: a
reconnect with 30.8GB of images and 8.9GB of weights already present needed no
network at all and came up in well under a minute once the passphrase (if encrypted)
was entered.

## Windows (via WSL2)

**Prerequisites** (one-time per machine):

- **Nothing but the GPU driver.** `install-windows.ps1` installs WSL2 itself (via
  `wsl --install`, not winget - on a machine where the underlying Windows optional
  features were never enabled, only that form actually enables them) and bootstraps an
  Ubuntu distro with a Linux user for you. Enabling WSL for the first time can still
  require one reboot; the script detects that and tells you rather than continuing.
- The **NVIDIA driver on the Windows host** (not inside WSL2), if the machine has an
  NVIDIA GPU. This is the one prerequisite that can't be scripted safely - install it
  from NVIDIA directly.

**Steps:**

1. Open an **elevated** PowerShell (`Terminal (Admin)`).
2. `cd` to the folder you cloned this repo into.
3. Run:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-windows.ps1
   ```
   The `-ExecutionPolicy Bypass` is **required, not optional**: Windows desktop editions
   ship with a `Restricted` policy that refuses to run any `.ps1`, so `.\install-windows.ps1`
   on its own fails with *"running scripts is disabled on this system"*. Invoking it this
   way affects only that one process and changes nothing on your system.
4. Pick the physical disk when listed. **This can reformat whatever disk you choose.**
   The picker labels your Windows system disk and refuses it, and hides WSL's own internal
   virtual disks, but it cannot know which of your *other* drives you care about. You must
   type `YES` in capitals before anything is erased.
5. Choose whether to **encrypt** the drive (see below).
6. It attaches the disk to WSL2 and hands off to `install.sh`, which asks the rest: local
   mount path, optional network share, standard or uncensored models, and a name for your
   assistant.
7. It then downloads an SDXL checkpoint for image generation and, separately, the
   LTX-Video weights - each with its own prompt, a sensible default URL, and `skip` as an
   option if you don't want it yet. Both wire themselves into Open WebUI automatically;
   nothing further to configure.
8. Say yes to the share-watcher scheduled task if you configured a network share - that's
   what raises a toast if the share drops mid-session.
9. Open WebUI is at `http://localhost:8080` once the stack finishes starting. See
   [Setup time](#setup-time) above for how long that actually takes.

### Day-to-day, after that first install

You do **not** re-run the installer to use the rig. From the repo folder, elevated:

```powershell
# bring it up (after a reboot, or on another machine)
powershell -NoProfile -ExecutionPolicy Bypass -File .\connect.ps1

# ALWAYS run this before unplugging the drive
powershell -NoProfile -ExecutionPolicy Bypass -File .\disconnect.ps1
```

`connect.ps1` attaches and mounts the drive, starts Docker and the stack, holds the WSL
instance open, and registers a logon task so the rig comes back ~45s after you log in. It
reuses everything already on the drive - no re-downloading.

`disconnect.ps1` is not optional politeness. The drive holds a mounted ext4 filesystem
**and Docker's live data-root**; pulling it while that is running risks corrupting the
image store. The script stops the stack, stops the daemons, unmounts, locks the drive
again if encrypted, releases the disk back to Windows, removes the logon task, and wipes
this machine's copy of any share credentials. It refuses to release the disk if the
unmount fails.

Add `-Distro <name>` to any of these if you are not using the default distro name.
`disconnect.ps1` resolves it for you when possible - it reads the exact distro from the
registered auto-connect task, or falls back to the only non-Docker-Desktop WSL distro if
there's exactly one. It only asks you to specify one explicitly on a machine hosting more
than one rig, rather than guessing which one you meant.

### Encryption

The installer offers to put the drive inside a LUKS2 container, with a passphrase you
choose then and enter on every connect. Without it, everything on the drive - including
every chat and prompt in Open WebUI's plain SQLite database - is readable by anyone who
plugs it in.

Three things to understand before saying yes:

- **The rig can no longer return unattended after a reboot.** Something has to type the
  passphrase, so the logon task can't do it for you.
- **macOS support is lost.** macOS cannot open LUKS volumes.
- **There is no recovery.** Lose the passphrase and the data is gone. Models can be
  re-downloaded; your chats and generated output cannot.

Unencrypted drives are fully supported, and both shapes are detected automatically.

### If you have a drive built by an older version

`docker-compose.yml` is generated by the installer and lives **on the drive**, so
`connect.ps1` never rewrites it. A drive built before images were pinned keeps using
floating tags - including an abandoned ComfyUI image that crash-loops. A drive built
before Open WebUI's port binding changed to loopback-only also keeps publishing on
`0.0.0.0:8080` - reachable from your whole network, not just the host machine - see
[`SECURITY.md`](../SECURITY.md#network-exposure). Re-run `install-windows.ps1` on that
drive (it will detect the existing filesystem and **not** reformat it) to regenerate
the compose file with both fixes.

## Native Linux

**Prerequisites:** none beyond a normal Ubuntu/Debian-family system with `sudo`.

**Steps:**

1. ```bash
   sudo bash install.sh
   ```
2. Answer `1` when asked which platform (Windows/Linux vs macOS).
3. Pick a drive, confirm the format warning if it needs one, pick a mount point.
4. Optionally set up a network share (server address, share name, username, password).
5. It installs Docker + the NVIDIA Container Toolkit (GPU-detected, skipped gracefully
   if no GPU is present), writes the compose stack, and pulls chat/coder models sized
   to the VRAM it finds.
6. Downloads an SDXL checkpoint and the LTX-Video weights (each skippable), and wires
   both into Open WebUI's image/video generation automatically.
7. Open WebUI is at `http://localhost:8080` once it finishes. See
   [Setup time](#setup-time) above for how long that actually takes.

## macOS (Apple Silicon)

**Prerequisites:** Docker Desktop for Mac installed and running.

**Steps:**

1. ```bash
   bash install-macos-arm.sh
   ```
   (or run `install.sh` and choose option `2` when asked - it hands off automatically.)
2. Pick where the rig lives. Only external drives are ever listed or accepted - an
   internal disk is refused outright, the same as the Windows/Linux picker. Two paths:
   - **Use an already-external, already-writable drive** - APFS, HFS+, ExFAT, or FAT
     only; a drive plugged in from Windows/Linux (NTFS, ext4) is filtered out here
     rather than silently failing to write to it later.
   - **Format an external drive from scratch** - option 2 at the prompt, erasing it as
     APFS. Requires typing `YES` in capitals first, the same confirmation pattern as
     `install.sh`'s own disk wipe.
3. Optionally set up a network share - the password is stored in the macOS Keychain,
   not in a file.
4. Ollama and Open WebUI come up via Docker Desktop.
5. Optionally set up image generation - ComfyUI, but running **natively on the host**,
   not in Docker. Docker Desktop for Mac has no Metal GPU passthrough to containers, so
   a containerised ComfyUI would be CPU-only; running it natively is the only way to get
   real GPU acceleration. Open WebUI (still in Docker) reaches it over
   `http://host.docker.internal:8188`. This step clones ComfyUI, sets up its own Python
   venv, and offers the same two checkpoints (and the same checksums) as the
   Linux/Windows installer.

> [!WARNING]
> **The native ComfyUI setup above is implemented but not yet verified on real Apple
> Silicon hardware** - this project's own drives were all built and tested on
> Linux/Windows. If you try it, please report back (working or not) on
> [issue #3](https://github.com/soullessmonarc/portabrain/issues/3).

**Known gap:** video generation (LTX-Video) is not part of the macOS path yet - see
[`mac-backlog.md`](../mac-backlog.md) and [`EXECUTIVE_SUMMARY.md`](EXECUTIVE_SUMMARY.md).

## Ending a session

Run `disconnect.ps1` (Windows), `eject.sh` (native Linux), or `bash mac-eject.sh`
(macOS) before physically removing the drive - see
[Quick start](../README.md#quick-start) above. It stops the stack, stops the daemons
whose data-root lives on the drive, unmounts, locks the drive again if it's encrypted,
and releases the raw disk back to Windows. It refuses to release the disk if any of
that fails, rather than reporting success and leaving the filesystem mounted underneath
a physically-removed drive.

`mac-eject.sh` works differently, because macOS has no raw disk to release and no
daemon data-root living on the drive - Docker Desktop's own Linux VM runs elsewhere and
only bind-mounts paths from the drive into containers. It searches every external
volume for the `portable-ai/stack` folder rather than needing a path typed in (same
reasoning as `eject.sh`'s label lookup - ask the drive, not the host), stops only the
containers this rig's own `docker-compose.yml` defines by reading its service names
directly rather than guessing, then calls `diskutil eject`. If eject fails, it lists
what's still holding the volume open via `lsof` rather than failing silently.

Docker Desktop, if present on the machine, does not need to be stopped for this to
work: the rig runs its own Docker Engine inside the WSL distro, and `eject.sh` blocks
systemd socket activation for the duration of the unmount so Docker Desktop's own WSL
probing can't interfere, whether or not it happens to be running.
