# PortaBrain

![PortaBrain logo](logo.png)

*A portable brain you can plug into any machine.*

A self-contained Ollama + ComfyUI + Open WebUI stack that lives entirely on
one external drive, so you can build it once and move it between machines.
Nothing in here is tied to a specific device, drive, or network - every
choice is asked interactively or auto-detected from the hardware in front
of it.

## Quick start

**Windows** (needs an elevated PowerShell):
```powershell
.\install-windows.ps1
```
This attaches your chosen physical disk to WSL2 and hands off to
`install.sh` automatically.

**Native Linux**:
```bash
sudo bash install.sh
```

**macOS (Apple Silicon)**:
```bash
bash install-macos-arm.sh
```
See the note at the top of that file - it's a starting point (Ollama +
Open WebUI work well; ComfyUI image/video generation isn't wired up yet,
since the Linux/Windows setup uses a CUDA-only image that doesn't run on
Apple Silicon).

`install.sh` itself asks up front whether you're on Windows/Linux or macOS,
and hands off to `install-macos-arm.sh` if you pick the latter - so on
Linux/Windows you only ever need to run one of the two entry points above.

## What it sets up

- **Ollama** for chat/coder LLMs, with GPU-aware sizing (checks your VRAM
  and picks appropriately-sized models)
- **ComfyUI** for image generation (Linux/Windows only for now)
- **Open WebUI** as the single web frontend for everything, at
  `http://localhost:8080`
- Optionally, a network (SMB/CIFS) share for extra storage, mounted
  alongside the drive

## Reliability: local-first output, network share is best-effort

If you opt into a network share, generated output is **never written
directly to it**. Everything renders to the drive first (which never
depends on network health), and a background timer moves finished files
over to the share whenever it's reachable. A second timer watches the
share, retries reconnecting it if it drops, and tells you clearly if it
can't get back after 10 tries - nothing is ever lost in the meantime, files
just queue up locally until the share comes back.

On native Linux and macOS that alert reaches you directly (`notify-send` /
a real desktop notification), since the heartbeat runs in a normal desktop
session there. On Windows/WSL2 the heartbeat runs headless and can't pop a
GUI notification itself, so `install-windows.ps1` offers to install
`install-share-watcher.ps1` - a small scheduled task (runs every 2 minutes
while you're logged in) that shows a Windows toast the moment the share
goes down or comes back, without needing to re-run the installer to see it.

If a VPN is active on the Windows host, WSL2's default networking can also
silently block reaching a LAN device (like the share's server) even though
the share server itself is fine - `install-windows.ps1` offers to switch
WSL2 to "mirrored" networking mode to fix this (needs Windows 11 22H2+ or a
recent Windows 10 WSL update; applies machine-wide, so it's opt-in).

## What you'll be asked

- Which drive to use (lists what it finds, you pick by number)
- Whether that drive needs to be formatted (only if it isn't already set up
  for this rig - confirmed explicitly before anything destructive happens)
- A mount point
- Whether to set up a network share, and if so: server address, share
  name, username, password
- Standard or uncensored/abliterated model variants
- (GPU permitting) whether to size up to bigger models

## Customizing the system prompt

The installer registers models with a neutral default system prompt. To
customize it for your own project, look at how `setup_register_models.py`
is used in the main (non-template) copy of this repo for a full worked
example - it registers a system prompt, capabilities, and a custom video
generation action against Open WebUI's own API.
