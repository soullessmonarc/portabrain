# Production Readiness

Honest breakdown of what's actually verified versus what isn't. This project has never
been called "production-ready" and nothing here should be read that way - it's a
personal/small-team installer, verified through live interactive runs, not a hardened
product.

## Done and verified

- Linux/WSL2 install path: drive picker, format confirmation, Docker + NVIDIA Container
  Toolkit install, GPU-tiered model pulls, and the generated `docker-compose.yml` stack
  - all exercised live against real hardware during development.
- Windows entry point (`install-windows.ps1`): disk attach to WSL2, hand-off to
  `install.sh`, verified end-to-end.
- Optional SMB share: credential prompts, `chmod 600` credentials file, local-first
  sync timer, and the reconnect heartbeat (including its 10-failure alert firing
  exactly once per outage) - all verified live, including a simulated 10-failed-attempt
  run.
- Windows toast watcher (`share-watcher.ps1`): verified it correctly detects a
  transition and fires a real Windows toast.
- WSL2 mirrored-networking fix: root-caused via live routing-table inspection
  (`Get-NetRoute`) and confirmed the fix restores LAN reachability while a VPN is
  active.

## Remaining / not yet done

- **No automated test suite.** Every verification claim above came from a live,
  interactive run, not a repeatable script. There's no CI in this repo.
- **macOS ComfyUI support.** Not started - would need an ARM-compatible image/runtime
  path distinct from the CUDA-only one used on Linux/Windows.
- **No `Disconnect`/eject flow in this generic template.** The personal-rig fork has one
  (`Disconnect AI.ps1`/`eject.sh`), coordinating with Docker Desktop's WSL integration
  to release the disk cleanly; that logic hasn't been generalised into this template
  yet, since it's specific to the WSL2 + Docker Desktop combination and needs more
  testing across different Docker Desktop configurations before it's safe to generalise.
- **Multi-GPU model splitting is summed, not validated per-model.** VRAM sizing sums
  across all GPUs for LLM tiering; it hasn't been tested on an actual multi-GPU rig,
  only reasoned through from Ollama's own documented layer-splitting behaviour.

## Needs external verification

- **Security review of the credential-handling code** (see [`../SECURITY.md`](../SECURITY.md))
  has not been done by anyone other than the person who wrote it.
- **Cross-machine portability claim** (move the drive, run the installer, it just
  works) has been verified across a small number of machines during development, not a
  wide hardware/OS matrix.
