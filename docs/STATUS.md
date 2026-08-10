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

## Phase 6 - real-hardware LUKS encryption + disk-release reliability (2026-08-08 to 2026-08-09)

- LUKS encryption exercised on physical hardware for the first time (previously
  loopback-only): format, unlock, mount, and lock-on-disconnect all verified end to end.
- Found and fixed a stale dm-crypt mapping bug: a mapping whose backing device
  disappeared without a prior `luksClose` keeps reporting `State: ACTIVE` and a valid
  device name, so a name-only check reports "already unlocked" against a dead device.
  Fixed with a direct-IO read probe (`dd ... iflag=direct`) - a cached read succeeds
  against a mapping that is already broken, so the probe has to bypass the cache.
- Found and fixed `wsl --unmount \\.\PHYSICALDRIVEn` returning `ERROR_FILE_NOT_FOUND`
  for a disk Windows still shows attached and Offline - WSL's own record of what it
  holds bare-attached can drift out of step with reality across a session that juggles
  more than one physical disk. An untargeted `wsl --unmount`, tried only after the
  targeted call fails and the disk is still Offline (since it releases every WSL2
  bare-attached disk, not just the one in question), resolved it every time it was hit.
- Found and fixed `Get-Partition` returning nothing for a disk WSL2 currently holds
  bare-attached - the normal state at exactly the point `disconnect.ps1` needs to
  identify which disk to release, not an edge case. Added a fallback: an offline USB
  disk is unambiguous in this project, since only the connect scripts ever take a disk
  offline, and only for this purpose.
- Found and fixed `-Distro` silently defaulting to the wrong distro on a machine
  hosting more than one rig. It now reads the exact distro from the registered
  auto-connect task name when one exists, falls back to the only non-Docker-Desktop WSL
  distro if there is exactly one, and asks explicitly rather than guessing if there is
  real ambiguity.
- `share-watcher.ps1`'s alert-state file was a single path shared by every rig on the
  machine regardless of distro - one rig's "share is down" transition could get
  silently overwritten by another's very next run. Scoped by `$Distro`.

## Phase 7 - image generation, actually working (2026-08-09)

- Found image generation silently broken on a fresh install: Open WebUI's
  `image_generation.engine` was never configured, left on the out-of-the-box default
  (`openai`, no API key) - "Enable Image Generation" failed immediately with nothing in
  ComfyUI's logs, since the request never reached ComfyUI at all.
- Found a second, independent bug behind the first: even with the engine correctly
  pointed at ComfyUI, its checkpoint list was empty, because `extra_model_paths.yaml`
  is hand-placed and not something a rebuild recreates - rejecting every generation
  with `ckpt_name: '...' not in []` despite the weights being present and readable.
- `install.sh` now generates both automatically. The workflow/node mapping was verified
  against Open WebUI's own source (`utils/images/comfyui.py`) rather than guessed, then
  proven end to end by driving that exact code path with the stored config and getting
  a real 1024×1024 render back - not a direct call to ComfyUI bypassing Open WebUI's
  own config, which would have caught neither bug.
- SDXL checkpoint auto-download added to `install.sh` (Juggernaut XL v9 preferred as
  the photoreal general-purpose default, Pony Diffusion V6 XL offered as the stylised
  option - Pony ignored a plain scene prompt entirely and rendered anime character art
  in testing), reusing the same CivitAI same-version relocation logic already used for
  the LTX video weights.
- Image size fixed at SDXL's native 1024×1024 on both GPU tiers rather than 512×512 on
  the small one - measured on an 8GB card with a 7B chat model also resident:
  1024×1024 completed in 25 seconds with VRAM to spare, so the smaller size was buying
  nothing but lost detail.

## Phase 8 - docker-compose.yml self-healing (2026-08-09)

- The file the whole stack is defined by was assumed to already exist rather than
  generated - the one thing a from-scratch rebuild could not recreate if it were ever
  lost. `install.sh` now writes it if missing, and only overwrites an existing one if
  it actually differs, backing up the previous file first.
- Verified by generating it against a real, working drive's compose file and confirming
  byte-for-byte identical output before trusting that safety property, rather than
  assuming it correct from reading the generator alone.

## Phase 9 - Docker Desktop handling rewrite (2026-08-09)

- The long-standing assumption that Docker Desktop's WSL integration backs
  `/var/run/docker.sock` for this rig turned out to be wrong: the rig runs its own
  native Docker Engine inside the distro, confirmed by checking the actual binary, the
  systemd units, and `daemon.json`'s data-root directly.
- The real reason to touch Docker Desktop at all was narrower than assumed - it probes
  WSL2 distros, and a probe could trip systemd socket activation and respawn `dockerd`
  mid-unmount. `eject.sh` now runtime-masks the relevant units before stopping them,
  which makes activation impossible rather than merely unlikely, closing a real race: a
  connection arriving in the instant before the socket unit goes down still triggers
  activation, and the old approach of just stopping the units left that instant open.
- With that race closed, Docker Desktop is left alone entirely unless it genuinely has
  WSL integration with the rig's distro - detected from its own settings rather than
  assumed.
- When Docker Desktop does need stopping, it is now done through its own
  `docker desktop stop`/`start` CLI rather than `Stop-Process -Force`. The latter was
  the actual cause of a "Docker Desktop - an unexpected error occurred / Reset to
  factory defaults" prompt on next launch - not a Docker bug, this script's doing.
  Measured: graceful stop ~12s, graceful start ~77s to a genuinely reachable engine, no
  recovery prompt either way.

## Phase 10 - video generation confirmed end-to-end (2026-08-09)

- Previously only the Action, its activation, and its binding to the models were
  verified. An actual clip has now been produced and confirmed on the drive, closing
  the last of this project's "verified but not observed" gaps around media generation.

## Phase 11 - public-readiness pass (2026-08-09 to 2026-08-10)

- Added `LICENSE` (plain, unmodified MIT - no field-of-use restriction, since that
  would stop this being open source in any real sense) and `NOTICE.md`, documenting the
  actual license of everything this installer downloads at a user's direction rather
  than bundles - including that Open WebUI's own license carries a non-standard
  branding clause, and that one of the two SDXL checkpoints this project can download
  (Pony Diffusion V6 XL) carries a real legal restriction on monetized inference,
  independent of anything this project itself says.
- Added a real setup-time estimate (`docs/MASTER_SETUP.md`), built from actual measured
  install runs rather than a guess - container image pulls and model weight downloads,
  each broken out and labelled honestly where a figure was not independently measured.
- Corrected claims across `README.md`, `PRODUCTION_READINESS.md`, and
  `EXECUTIVE_SUMMARY.md` that were true when written and are no longer: "LUKS
  encryption has never run on a real drive" and "video generation has not been run
  end-to-end" both predate Phases 6 and 10 above. Also corrected a flatly false claim
  ("no automated test suite or CI") that contradicted this repo's own CI badge, and a
  stale claim in `MASTER_SETUP.md` that no disconnect/eject script existed for this
  template at all.
- Full repo sweep before treating any of this as ready for a stranger to clone: CI's
  exact lint gates re-run locally across every tracked file, not just what changed;
  every markdown link across every doc resolved; the Components table in `README.md`
  was found to be missing two files entirely (`setup_image_config.py`, added this same
  session, and `setup_register_models.py`) and citing a resolution/step-count default
  that no longer matches Phase 7 above; and a real private IP address, embedded in a
  debugging comment as a "confirmed live" example, was found and redacted before it
  could ship.

## Phase 12 - drop Pony Diffusion V6 XL, replace with Animagine XL 3.1 (2026-08-10)

- After the repo went public, a real personal email address was found embedded in
  every commit's author metadata (separate from the file-content leak in Phase 11) -
  rewritten across all 32 commits and both remote branches/tags via `git filter-repo`
  with a mailmap, verified clean via a fresh clone from GitHub itself. A proper GitHub
  Release was also created for `v0.4.0`, which had only ever been tagged, not released.
- Pony Diffusion V6 XL was replaced as the stylised/anime SDXL checkpoint. Its license
  (Fair AI Public License 1.0-SD) explicitly prohibits monetized inference - a real
  restriction, not an advisory one, and one this project's own `NOTICE.md` had already
  flagged as "the one most likely to matter and easiest to miss." Rather than continue
  offering it, it was dropped.
- **Animagine XL 3.1** was verified and added in its place - CreativeML Open RAIL++-M,
  confirmed directly against the model's own license text and model card (not a search
  summary, which for at least one earlier query returned an incorrect "no restriction on
  generated images" characterisation of a similarly-named license family). Its model
  card explicitly notes this license supersedes an earlier, more restrictive community
  license tag (FAIPL - the same family Pony uses) carried by prior versions of the same
  repository, which is itself the exact failure mode this swap exists to avoid: a
  checkpoint's name or lineage is not its license, and both have to be checked directly
  every time, not assumed from a prior version or a similar-sounding sibling model.
- `NOTICE.md` and the main `README.md` warning callout keep an explicit, standing note
  about Pony's restriction rather than silently deleting the reference: if this
  installer was ever run before this change and a drive already has
  `ponyDiffusionV6XL.safetensors` on it, that restriction still applies to it regardless
  of what this project currently offers.
