# Executive Summary

## What this is

PortaBrain is a set of installer scripts that build a self-contained Ollama + ComfyUI +
Open WebUI stack on a single external drive. Plug the drive into any machine that's
already had the one-time OS-level prerequisites set up, run one script, and the whole
local AI stack (chat/coder LLMs, image and video generation, and the Open WebUI
frontend) comes up pointed at that drive - move the drive to a different machine and
it works the same way there.

## Why it exists

Running a local LLM/image-gen stack usually means re-deriving the same setup - drive
partitioning, Docker/NVIDIA toolkit install, model selection sized to the GPU actually
present, and (optionally) a network share for extra storage - on every machine you use
it from. PortaBrain packages that setup as a repeatable, interactive installer instead
of a one-off manual process, so the actual data and model weights live on the drive and
the machine is just a host.

## Current status (v0.3.0)

- **Windows (via WSL2) and native Linux:** full parity - Ollama, ComfyUI, Open WebUI,
  GPU-aware model tiering, optional SMB share with local-first sync and a reconnect
  heartbeat.
- **Day-to-day lifecycle:** `connect.ps1` / `disconnect.ps1` (plus `connect.sh` /
  `eject.sh`) bring the rig up and shut it down cleanly, with a WSL keep-alive and a
  logon task so it survives a reboot. The installer is a one-time step, not something
  you re-run to use the rig.
- **Optional at-rest encryption:** the drive can be built inside a LUKS2 container.
  Trade-off: no unattended restart, and no macOS support.
- **Chat, coding and image generation work.** The upstream ComfyUI image this project
  used had been abandoned and crash-looped on `comfy_aimdo`; images are now pinned to the
  maintained line and ComfyUI has been verified running on real hardware.
- **Video generation is wired up but not yet proven.** A "Generate Video (LTX)" Action is
  installed automatically and verified bound to the models; its weights are downloaded at
  install time from URLs you can override. The generation pipeline itself has not been
  run end-to-end.
- **Portability itself is still unverified.** The install/connect/disconnect cycle has
  been proven on a single machine; moving the drive to a different one - the entire point
  of the project - has not been tested yet.
- **macOS (Apple Silicon):** Ollama and Open WebUI work via Docker Desktop; the SMB
  share, Keychain-backed credentials, and launchd-based heartbeat/sync all work. ComfyUI
  (image/video generation) is **not yet wired up** - the Linux/Windows setup uses a
  CUDA-only image that doesn't run on Apple Silicon.
- **Windows-only convenience layer:** a scheduled-task toast watcher
  (`install-share-watcher.ps1`) surfaces network-share drop/reconnect events mid-session,
  since the underlying heartbeat runs headless there and can't pop its own notification.

## What's explicitly not done

- No automated test suite or CI - correctness has been verified through live,
  interactive test runs against real hardware, not a repeatable test harness. See
  [`PRODUCTION_READINESS.md`](PRODUCTION_READINESS.md) for the itemised list.
- No ComfyUI/image-video generation on macOS.
- No formal security audit of the credential-handling code - see
  [`../SECURITY.md`](../SECURITY.md) for what practices are actually in place today.
