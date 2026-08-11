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

## Current status (v0.7.3)

- **Windows (via WSL2) and native Linux:** full parity - Ollama, ComfyUI, Open WebUI,
  GPU-aware model tiering, optional SMB share with local-first sync and a reconnect
  heartbeat.
- **Day-to-day lifecycle:** `connect.ps1` / `disconnect.ps1` (plus `connect.sh` /
  `eject.sh`) bring the rig up and shut it down cleanly, with a WSL keep-alive and a
  logon task so it survives a reboot. The installer is a one-time step, not something
  you re-run to use the rig.
- **Optional at-rest encryption:** the drive can be built inside a LUKS2 container -
  format, unlock, mount, and lock-on-disconnect all verified on real hardware, not just
  a loopback device. Trade-off: no unattended restart, and no macOS support.
- **Chat, coding, image and video generation all work, end to end.** The upstream
  ComfyUI image this project used had been abandoned and crash-looped on `comfy_aimdo`;
  images are now pinned to the maintained line. Image generation needed two separate
  fixes before it actually worked (Open WebUI's config pointed nowhere near ComfyUI by
  default, and ComfyUI's own checkpoint discovery needed a generated config file) - both
  are now automatic, and a real render has been produced through the actual code path,
  not just a direct call to ComfyUI that would have missed both bugs. A "Generate Video
  (LTX)" Action installs automatically, binds to the models, and has produced an actual
  clip on real hardware.
- **Portability itself is still unverified.** The install/connect/disconnect cycle has
  been proven on a single machine; moving the drive to a different one - the entire point
  of the project - has not been tested yet.
- **The stylised SDXL checkpoint changed.** Pony Diffusion V6 XL is no longer offered -
  its license explicitly prohibits monetized inference. Animagine XL 3.1 replaces it,
  verified under plain CreativeML Open RAIL++-M with no such restriction. See
  [`NOTICE.md`](../NOTICE.md) for the full comparison and a standing note for anyone
  who already downloaded Pony under an earlier version.
- **A full security audit landed a real fix.** Open WebUI was published on `0.0.0.0:8080`
  by default - reachable from an entire local network, not just the host machine, which
  matters for a stack that runs uncensored models with no content filter and gets plugged
  into different machines. Now bound to `127.0.0.1:8080`, with LAN exposure available as
  a deliberate one-line opt-in. Also added: SHA256 verification of every downloaded model
  checkpoint against a hash pulled from the hosting platform's own metadata, an
  `/etc/fstab`-injection fix for SMB share names containing spaces, and GitHub Actions
  pinned to commit SHAs instead of mutable tags. See
  [`SECURITY.md`](../SECURITY.md) for the full writeup.
- **A real-hardware failure found and fixed a data-integrity bug.** The stale-mapping
  liveness check gave a false negative against a genuinely live, actively-mounted LUKS
  mapping, and the cleanup fallback then force-removed it - which silently swapped the
  live table for an error target and aborted the mounted filesystem's ext4 journal
  mid-session. Both `install.sh` and `connect.sh` now verify actual usage independently
  of the liveness probe and refuse to touch a mapping that's genuinely in use, rather
  than trusting a probe that has already been proven wrong once.
- **The repo's first outside contribution:** an external-drive-only picker for
  `install-macos-arm.sh` (an internal disk is now refused outright, matching the
  Windows/Linux picker), a path to format an external drive from scratch when it isn't
  already in a format macOS can write to, and `mac-eject.sh` - macOS previously had no
  scripted way to stop the stack before unplugging the drive at all.
- **macOS (Apple Silicon):** Ollama and Open WebUI work via Docker Desktop; the SMB
  share, Keychain-backed credentials, and launchd-based heartbeat/sync all work. Image
  generation now works too - ComfyUI runs natively on the host (Docker Desktop for Mac
  has no Metal GPU passthrough to containers, so a containerised ComfyUI would be
  CPU-only), reachable from Open WebUI's Docker container over
  `http://host.docker.internal:8188`. **Not yet verified on real Apple Silicon
  hardware** - tracked in
  [issue #3](https://github.com/soullessmonarc/portabrain/issues/3). Video generation
  (LTX-Video) remains out of scope on macOS - see [`mac-backlog.md`](../mac-backlog.md).
- **Weight downloads are now resumable.** Caught live during a real rebuild: three
  separate multi-GB downloads hit an HTTP/2 stream-reset error partway through, and
  every retry restarted from 0%. `curl -C -` now resumes from where a failed attempt
  left off (verified both real hosts actually support this - Hugging Face and CivitAI's
  real delivery URL both checked live, not assumed), and a prompt response has to
  actually look like a URL before it's handed to curl at all.
- **Windows-only convenience layer:** a scheduled-task toast watcher
  (`install-share-watcher.ps1`) surfaces network-share drop/reconnect events mid-session,
  since the underlying heartbeat runs headless there and can't pop its own notification.

## What's explicitly not done

- No integration/functional test suite - correctness has been verified through live,
  interactive test runs against real hardware, not a repeatable test harness, and there
  cannot usefully be one: this project's job is to reformat a physical disk and install
  Docker inside WSL2, which no hosted runner can reproduce. Static-analysis CI *does*
  exist (shellcheck, PSScriptAnalyzer, python syntax - see the badge in the main
  [README](../README.md)) but by design cannot exercise any of that. See
  [`PRODUCTION_READINESS.md`](PRODUCTION_READINESS.md) for the itemised list.
- No ComfyUI/image-video generation on macOS.
- No formal security audit of the credential-handling code - see
  [`../SECURITY.md`](../SECURITY.md) for what practices are actually in place today.
