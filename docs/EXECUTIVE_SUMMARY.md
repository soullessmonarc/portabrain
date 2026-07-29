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

## Current status (v0.1.0)

- **Windows (via WSL2) and native Linux:** full parity - Ollama, ComfyUI, Open WebUI,
  GPU-aware model tiering, optional SMB share with local-first sync and a reconnect
  heartbeat.
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
