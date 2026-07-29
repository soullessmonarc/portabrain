# Status

Itemised engineering record, phase by phase. Dates reflect when each phase actually
landed.

## Phase 1 - Linux/WSL2 + Windows installer (2026-07-29)

- Generic drive picker (`lsblk`-driven), explicit `type YES` confirmation before any
  destructive format.
- Platform picker (`install.sh`) routing to `install-macos-arm.sh` for Apple Silicon.
- Optional SMB/CIFS share: host/share/username/password prompts, credentials file at
  `/etc/portableai-credentials`, `chmod 600`.
- Docker Engine + NVIDIA Container Toolkit install, GPU-detected (skips NVIDIA toolkit
  gracefully with no GPU present).
- `docker-compose.yml` generated via heredoc at install time - no hardcoded personal
  paths, since the mount point is chosen interactively.
- GPU-aware model tiering: total VRAM (summed across GPUs) sizes the chat/coder LLM
  pair; largest single GPU sizes image/video generation resolution and step count,
  since ComfyUI runs one generation on one card rather than splitting across GPUs.
- Standard vs. uncensored/abliterated model variant choice.
- `install-windows.ps1`: elevated disk picker, hands off into WSL2.

## Phase 2 - reliability: local-first output + network-share heartbeat (2026-07-29)

- Generated output writes to the drive first, always - a background timer
  (`portableai-sync.timer`, every 2 minutes) moves finished files to the network share
  only when it's actually reachable, so generation never depends on network health.
- A separate heartbeat (`portableai-share-heartbeat.timer`, every 30 seconds) retries
  reconnecting the share and alerts once per outage after 10 consecutive failures.
- Ported the same local-first + heartbeat pattern to macOS (launchd agents,
  Keychain-backed credentials) and native Linux, not just Windows/WSL2.

## Phase 3 - Windows mid-session visibility (2026-07-29)

- Root-caused (via live A/B testing) that a headless WSL2 systemd service cannot pop a
  Windows GUI notification, even though the same code works from an attached
  interactive terminal.
- Added `share-watcher.ps1` + `install-share-watcher.ps1`: a Windows Scheduled Task,
  independent of the WSL2-side heartbeat, that polls the same alert marker and fires a
  native toast on state transitions (down/reconnected) - only on Windows, since native
  Linux and macOS already reach a real desktop session directly from their own
  heartbeats.
- Fixed a WSL2 + active-VPN interaction where WSL2's default NAT networking silently
  blocked reaching LAN devices (like the share's own server) even though the Windows
  host itself could reach them fine - `install-windows.ps1` now offers to switch WSL2 to
  mirrored networking mode as an opt-in fix.

## Phase 4 - credential-logging hardening (2026-07-29)

- The macOS SMB mount step wrote failure diagnostics to a predictable, shared
  `/tmp/smb-mount.log` - some mount error output can echo back the connection string,
  so a world-readable path there could leak it to another local user on a multi-user
  Mac. Changed to a freshly `mktemp`'d, `chmod 600` file, deleted on success.

## Phase 5 - house layout standardisation (2026-07-29)

- Brought the repo's presentation layer in line with the shared `soullessmonarc` house
  layout (README skeleton, `docs/` tree, `SECURITY.md`, `.gitattributes`).
- No application code changed in this phase - documentation and metadata only.
