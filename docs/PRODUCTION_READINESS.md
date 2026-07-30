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
  workflow added.
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

- **Portability itself is UNVERIFIED.** This is the biggest gap, and it is the project's
  central claim. Everything above was proven on *one* machine: install, disconnect,
  reconnect, same host. Moving the drive to a genuinely different machine - which is the
  entire point - has not been tested. That means the GPU re-tiering, the old-tier model
  cleanup, and the from-scratch `wsl --install` path are all still theory.
- **ComfyUI is currently broken upstream.** `yanwk/comfyui-boot:cu124-slim` was
  abandoned (last rebuilt 2025-10-13, variant since deleted from the upstream repo) and
  crash-loops on `ModuleNotFoundError: No module named 'comfy_aimdo'`. Images are now
  pinned to the maintained `cu126-slim` line, but **that fix has not been tested** - it
  needs a run on a drive whose ComfyUI copy predates the change. Until then, treat image
  and video generation as unproven; chat and coding work.
- **No integration test, and there cannot usefully be one.** CI does static analysis
  only (shellcheck, PSScriptAnalyzer, python syntax). Attaching a physical disk to WSL2
  and reformatting it is not reproducible on a hosted runner, and a green tick that
  didn't exercise any of that would be worse than no tick.
- **The PowerShell CI job is itself unverified** - PSScriptAnalyzer could not be
  installed in the environment where the workflow was written, so its first real run
  will be on GitHub.
- **macOS ComfyUI support.** Not started - would need an ARM-compatible image/runtime
  path distinct from the CUDA-only one used on Linux/Windows. Note also that choosing
  encryption rules macOS out entirely, since it cannot open LUKS volumes.
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
