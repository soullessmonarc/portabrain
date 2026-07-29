# Master Setup

End-to-end instructions for going from a blank drive to a running stack, for each
supported platform.

## Windows (via WSL2)

**Prerequisites** (one-time per machine):

- WSL2 itself. If missing, `install-windows.ps1` will offer to install it via
  `winget install Microsoft.WSL` - decline and it errors out with the manual command
  instead of guessing.
- An Ubuntu distro under WSL2. If missing, the personal-rig fork of this installer
  (`Connect AI.ps1`, not part of this generic template) can bootstrap one
  non-interactively; on a fresh machine running this template directly, install one
  yourself first: `wsl --install -d Ubuntu`.
- The NVIDIA driver on the Windows host itself (not inside WSL2), if the machine has an
  NVIDIA GPU. This is the one prerequisite that can't be scripted safely - install it
  from NVIDIA directly.

**Steps:**

1. Open an elevated PowerShell (`Terminal (Admin)`).
2. Run:
   ```powershell
   .\install-windows.ps1
   ```
3. Pick the physical disk to use when listed - **this can reformat whatever disk you
   choose**, so double-check the number.
4. It attaches the disk to WSL2 and hands off to `install.sh` automatically, which asks
   the remaining questions (mount point, optional network share, model tier).
5. Optionally, when it offers to install `install-share-watcher.ps1`'s scheduled task,
   say yes if you configured a network share - it's what surfaces a toast if that share
   drops mid-session.
6. Open WebUI is at `http://localhost:8080` once the stack finishes starting.

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
   if no GPU is present), writes the compose stack, and pulls models sized to the VRAM
   it finds.
6. Open WebUI is at `http://localhost:8080` once it finishes.

## macOS (Apple Silicon)

**Prerequisites:** Docker Desktop for Mac installed and running.

**Steps:**

1. ```bash
   bash install-macos-arm.sh
   ```
   (or run `install.sh` and choose option `2` when asked - it hands off automatically.)
2. Pick an external drive/folder to use.
3. Optionally set up a network share - the password is stored in the macOS Keychain,
   not in a file.
4. Ollama and Open WebUI come up via Docker Desktop.

**Known gap:** ComfyUI (image/video generation) is not part of this path yet - see
[`EXECUTIVE_SUMMARY.md`](EXECUTIVE_SUMMARY.md).

## Ending a session

There's no unmount/eject step built into this generic template today (the personal-rig
fork has `Disconnect AI.ps1`/`eject.sh` for that, since it needs to coordinate with
Docker Desktop's WSL integration to release the disk cleanly). For this template,
stopping the stack is a plain `docker compose down` from the stack directory before
physically removing the drive.
