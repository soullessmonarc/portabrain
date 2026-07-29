<div align="center" markdown="1">

<img src="docs/logo.png" width="220" style="width:220px;height:auto;" alt="PortaBrain logo: a stylised brain rendered as glowing blue-to-violet circuit traces, its lower half merging into a USB drive plug, on a dark navy background">

# PortaBrain

**A portable brain you can plug into any machine.**

![Status: beta](https://img.shields.io/badge/status-beta-yellow)
![Bash 5](https://img.shields.io/badge/bash-5-4EAA25?logo=gnubash&logoColor=white)
![PowerShell 5.1+](https://img.shields.io/badge/powershell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![Docker](https://img.shields.io/badge/docker-required-2496ED?logo=docker&logoColor=white)
![Ollama](https://img.shields.io/badge/ollama-supported-000000?logo=ollama&logoColor=white)
![License: private](https://img.shields.io/badge/license-private-lightgrey)

</div>

There's no CI badge because there's no CI in this repo yet, and no license badge beyond
"private" because no public licence has been granted - see
[`docs/PRODUCTION_READINESS.md`](docs/PRODUCTION_READINESS.md) for what that actually
means in practice.

> [!IMPORTANT]
> This has been verified through live, interactive runs against real hardware, not an
> automated test suite - there is no CI in this repo. "Beta" here means the Linux/WSL2
> and Windows paths are complete and exercised; macOS Apple Silicon support is
> real but partial (no ComfyUI yet). See
> [`docs/PRODUCTION_READINESS.md`](docs/PRODUCTION_READINESS.md) for the full,
> itemised breakdown of what's verified versus what isn't.

A self-contained Ollama + ComfyUI + Open WebUI stack that lives entirely on one
external drive, so you can build it once and move it between machines. Nothing in here
is tied to a specific device, drive, or network - every choice is asked interactively
or auto-detected from the hardware in front of it.

- **New here?** → [`docs/EXECUTIVE_SUMMARY.md`](docs/EXECUTIVE_SUMMARY.md)
- **Setting it up?** → [`docs/MASTER_SETUP.md`](docs/MASTER_SETUP.md)
- **How close to production?** → [`docs/PRODUCTION_READINESS.md`](docs/PRODUCTION_READINESS.md)
- **Want the detailed engineering record?** → [`docs/STATUS.md`](docs/STATUS.md)
- **How does the network-share reliability work?** → [`docs/NETWORK_SHARE_RELIABILITY.md`](docs/NETWORK_SHARE_RELIABILITY.md)

## Components

| Path | What it is |
|------|-----------|
| `install.sh` | Linux/WSL2 installer: drive picker, format confirmation, optional SMB share, Docker + NVIDIA Container Toolkit install, GPU-tiered model selection. Also the platform picker - hands off to `install-macos-arm.sh` if you choose macOS. |
| `install-windows.ps1` | Windows entry point: elevated disk picker, offers to install WSL2 itself via `winget` if missing, attaches the chosen disk to WSL2, hands off to `install.sh`. |
| `install-macos-arm.sh` | macOS Apple Silicon entry point: Ollama + Open WebUI via Docker Desktop, SMB share via the macOS Keychain, launchd-based heartbeat/sync. |
| `share-watcher.ps1` | Windows-only: one-shot check that fires a native toast when the configured network share drops or reconnects mid-session. |
| `install-share-watcher.ps1` | Registers `share-watcher.ps1` as a Windows Scheduled Task (every 2 minutes, while logged in). |
| `docs/` | Setup guide, status record, production-readiness breakdown, and the network-share reliability design doc. |

## Quick start

```bash
# Windows (elevated PowerShell)
.\install-windows.ps1

# Native Linux
sudo bash install.sh
```

Open `http://localhost:8080` once the stack finishes starting. For macOS Apple Silicon,
or the full walkthrough for either path above, see
[`docs/MASTER_SETUP.md`](docs/MASTER_SETUP.md).

## A hard rule for this repo

**The installer can reformat whatever disk you choose.** It always asks you to pick a
drive by number and requires typing `YES` before anything destructive happens - read
that prompt carefully every time, especially on a machine with more than one disk
attached.

---

<sub><img src="docs/logo-icon.png" width="16" height="16" alt="PortaBrain icon" style="vertical-align:middle"> PortaBrain · soullessmonarcs · made with the help of AI</sub>
