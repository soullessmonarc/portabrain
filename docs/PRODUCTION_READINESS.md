# Production Readiness

Honest breakdown of what's actually verified versus what isn't. This project has never
been called "production-ready" and nothing here should be read that way - it's a
personal/small-team installer, verified through live interactive runs, not a hardened
product.

## Done and verified

The install → connect → disconnect lifecycle was run end-to-end on a **blank SSD in a
fresh WSL distro**, which is the only test that means anything here. That round found
roughly twenty distinct bugs, several of which would have hit every user on their first
attempt: a missing `parted` discovered only *after* the user had confirmed erasing the
drive, a "Done - open localhost:8080" printed after a completely failed install, a disk
picker that offered the machine's own Windows system disk as the only choice, and no
keep-alive at all - so the rig died silently a few minutes after installing. All fixed
and re-verified.

- Linux/WSL2 install path: drive picker, format confirmation, prerequisite install,
  Docker + NVIDIA Container Toolkit install, GPU-tiered model pulls, and the generated
  `docker-compose.yml` stack - exercised live on a blank drive.
- Windows entry point (`install-windows.ps1`): disk attach to WSL2, hand-off to
  `install.sh`, verified end-to-end on a fresh distro.
- `connect.ps1` / `connect.sh`: verified that a reconnect **reuses** what is already on
  the drive - 30.8GB of container images and 8.9GB of model weights, no re-download, no
  network needed - and that the drive is found by label even though its device node
  moved between sessions (`sdh1` to `sde1`).
- `disconnect.ps1` / `eject.sh`: graceful stack stop, share unmount, daemon shutdown,
  filesystem unmount, raw-disk release back to Windows, keep-alive stop, and scheduled
  task removal. Confirmed from outside the script afterwards: disk `Offline`, task gone,
  no distro running, no orphaned processes.
- Restart survival (`autoconnect-task.ps1`): Task Scheduler entry registered on connect
  and removed on disconnect, with the correct principal (the user, `RunLevel Highest`,
  not SYSTEM - WSL distros are per-user) and a 45s logon delay for USB enumeration.
- Data-root safety guard: `connect.sh` refuses to start Docker unless the data-root
  provably resolves onto the drive's own device. This exists because the failure it
  prevents was observed twice - containerd starting against an unmounted path and
  silently writing gigabytes to WSL2's internal disk, invisible once the drive is later
  mounted over the top.
- LUKS encryption path: validated against a loopback container - format, discovery by
  container label *while locked*, unlock, wrong-passphrase rejection, mkfs/mount inside,
  re-unlock with data intact, and confirmation that `luksClose` refuses while mounted.
- Static analysis: `shellcheck --severity=warning` clean across all shell scripts; CI
  workflow added (and green, after its own first run found three real defects).
- Mount-namespace fix: verified on hardware. `connect.ps1` now re-execs into systemd's
  namespace, the data-root guard passes, and the stack comes up from the drive's existing
  images with **no re-pull** - which is the observable proof that dockerd is looking at
  the drive and not at WSL2's internal disk.
- ComfyUI: verified running on the pinned `cu126-slim` image, serving HTTP 200, with a
  clean startup log. Image generation is no longer blocked.
- Video-generation Action: verified installing, activating, surviving a re-run
  idempotently, and binding to both registered models via `actionIds`. Its weights are
  fetched from overridable URLs, both of which were confirmed live.
- Optional SMB share: credential prompts, `chmod 600` credentials file, local-first
  sync timer, and the reconnect heartbeat (including its 10-failure alert firing
  exactly once per outage) - all verified live, including a simulated 10-failed-attempt
  run.
- Windows toast watcher (`share-watcher.ps1`): verified it correctly detects a
  transition and fires a real Windows toast.
- WSL2 mirrored-networking fix: root-caused via live routing-table inspection
  (`Get-NetRoute`) and confirmed the fix restores LAN reachability while a VPN is
  active.
- **LUKS encryption on real hardware** (previously loopback-only): format, unlock,
  mount, and lock-on-disconnect all verified on an actual physical drive, including a
  real transient failure and recovery. Also found and fixed live: a stale dm-crypt
  mapping surviving its backing device disappearing (name-based checks alone are not
  enough - a mapping can report `State: ACTIVE` and a valid device name while the
  target underneath is dead; fixed with a direct-IO read probe), and `wsl --unmount`
  itself returning `ERROR_FILE_NOT_FOUND` for a disk Windows still shows attached, with
  an untargeted `wsl --unmount` fallback that resolved it every time it was hit.
- **Video generation end-to-end.** Previously only the Action and its wiring were
  verified; an actual clip has now been produced and confirmed on the drive.
- **Image generation end-to-end**, driven through the real Open WebUI → ComfyUI code
  path (not a direct API call to ComfyUI bypassing Open WebUI's own config) - and a
  second, separate bug behind it found live: even with image generation correctly
  configured, ComfyUI's checkpoint list was empty because `extra_model_paths.yaml`
  is hand-placed and not something a rebuild recreates. Both are now generated
  automatically.
- **`docker-compose.yml` self-healing.** The file the whole stack is defined by is
  generated by the installer rather than assumed to already exist, and only overwrites
  an existing one if it actually differs (backing up the old one first) - verified by
  generating it against a real working drive and confirming byte-for-byte identical
  output before trusting that safety property.
- **Docker Desktop handling**, rewritten after two rounds of live testing: stopped
  through its own `docker desktop stop`/`start` CLI rather than `Stop-Process -Force`
  (which was the actual cause of a "reset to factory defaults" prompt on next launch,
  not a Docker bug), and left alone entirely on a machine where it has no WSL
  integration with the rig's distro - detected from its own settings, not assumed.
- **macOS ComfyUI, confirmed on real Apple Silicon** (M-series Mac, macOS 26.6.1,
  [issue #3](https://github.com/soullessmonarc/portabrain/issues/3)): runs natively on
  the host rather than in Docker (Docker Desktop for Mac has no Metal GPU passthrough
  to containers), reachable from Open WebUI's own Docker container over
  `http://host.docker.internal:8188`. Metal/MPS acceleration confirmed genuine, not a
  silent CPU fallback - `/system_stats` reports `"device":"mps"`, the diffusion model
  loads directly to GPU, SDXL sampling ran at ~2.0 it/s - and a real image was produced
  through Open WebUI's own generation endpoint, not just a config check. Two real bugs
  the same testing found are fixed (Docker Desktop's own VM process blocking eject
  regardless of container state; a too-tight 2-minute cold-start timeout), though those
  two specific fixes still owe a real-hardware re-check of their own.

## Remaining / not yet done

- **Portability itself is UNVERIFIED.** This is the biggest gap, and it is the project's
  central claim. Everything above was proven on *one* machine: install, disconnect,
  reconnect, same host. Moving the drive to a genuinely different machine - which is the
  entire point - has not been tested. That means the GPU re-tiering, the old-tier model
  cleanup, and the from-scratch `wsl --install` path are all still theory.
- **No integration test, and there cannot usefully be one.** CI does static analysis
  only (shellcheck, PSScriptAnalyzer, python syntax). Attaching a physical disk to WSL2
  and reformatting it is not reproducible on a hosted runner, and a green tick that
  didn't exercise any of that would be worse than no tick.
- **Video generation (LTX-Video) on macOS remains out of scope** - see `mac-backlog.md`.
  Note also that choosing encryption rules macOS out entirely, since it cannot open
  LUKS volumes.
- **Windows 10 is untested.** Mirrored networking needs Windows 11 22H2+, so a Win10
  host falls back to NAT mode. That should be *better* for `localhost` access (NAT mode's
  loopback forwarding bypasses the firewall entirely), but it has not been confirmed, and
  the LAN/VPN share behaviour that motivated mirrored mode will differ.
- **Multi-GPU model splitting is summed, not validated per-model.** VRAM sizing sums
  across all GPUs for LLM tiering; it hasn't been tested on an actual multi-GPU rig,
  only reasoned through from Ollama's own documented layer-splitting behaviour.

## Needs external verification

- **Security review of the credential-handling code** (see [`../SECURITY.md`](../SECURITY.md))
  has not been done by anyone other than the person who wrote it.
- **Cross-machine portability claim** (move the drive, run the installer, it just
  works) has been verified across a small number of machines during development, not a
  wide hardware/OS matrix.
