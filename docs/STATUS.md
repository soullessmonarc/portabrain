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
- A second, separate history rewrite: three commit messages named a personal development
  rig and described its custom uncensored prompt in specific terms - not PII, but exactly
  the kind of operator-specific detail the public/personal split (`system_prompt.txt`
  being gitignored, etc.) was meant to keep out of the shared repo. Rewritten via a
  `git filter-repo --commit-callback` pass, technical substance kept intact. Cost two
  false starts to get right: the callback silently no-op'd the first time because
  `git-filter-repo` runs under a Windows-native Python that doesn't resolve `/c/...`-style
  paths, so a file-path argument got treated as literal (harmless, no-op) inline code
  instead of a file to read; the second attempt matched most commits but not the two
  target ones, traced to `git-filter-repo` textually splicing callback code into a
  generated function body - which corrupts multi-line string literals in the callback,
  since indentation added by the splice becomes literal string content. Fixed by moving
  the old/new message text to side-car files read at runtime instead of embedding them
  as literals, verified byte-for-byte against the real commit content before rerunning.

## Phase 13 - security audit (2026-08-10)

A full audit covering credential handling, injection surfaces, download integrity,
container hardening, network exposure, and CI supply-chain hygiene - not just the
PII/secrets sweep Phase 12 covered.

- **Open WebUI was published on `0.0.0.0:8080`** - Docker's default publishing
  behaviour for a bare `"8080:8080"`, reachable from every device on whatever network
  the host is connected to, not just the host itself. `ENABLE_SIGNUP` was also left at
  Open WebUI's own default (`true`; new accounts land in `pending` pending admin
  approval, verified against Open WebUI's own docs rather than assumed). Given this
  project runs uncensored models with no content filter and is meant to be plugged into
  different machines - some on networks you don't fully trust - this was a real gap,
  and `SECURITY.md`'s threat model didn't mention it at all; it only covered physical
  drive theft. Now bound to `127.0.0.1:8080` by default, with LAN exposure documented
  as a deliberate one-line opt-in in `SECURITY.md`.
- **Model weight downloads had no integrity verification** beyond bare HTTPS transport
  trust. `fetch_weight()` now checks a SHA256 pinned per file - pulled from Hugging
  Face's own LFS object-hash metadata and CivitAI's file-hash API directly, not
  computed locally or copied from a webpage - and discards/retries on mismatch. Only
  applied to the default URL for each file; a pasted custom URL skips the check, since
  a hash pinned to one specific file can't validate a deliberate substitute. Mitigating
  factor noted in `SECURITY.md`: every weight this project fetches is `.safetensors`,
  which carries no pickle-based code-execution risk even without the hash.
- **SMB share input could inject extra `/etc/fstab` fields.** A share name or host
  containing a literal space - a real, legal SMB share name, not an edge case - would
  split into extra whitespace-delimited fstab fields. Fixed by applying `fstab`(5)'s own
  octal escapes (`\040` for space, etc.) when building the fstab line, rather than
  rejecting otherwise-valid share names.
- **GitHub Actions pinned to commit SHAs** (`actions/checkout`, `actions/setup-python`)
  instead of mutable version tags, each with the resolved version as a trailing comment.
- Everything else in the audit held up: LUKS passphrase piped via stdin at every call
  site (never touches argv), containers run `cap_drop: ALL` plus a minimal explicit
  `cap_add` with `no-new-privileges:true` and no Docker socket mount, Ollama/ComfyUI
  are not published to the host at all (only Open WebUI was, which is what made the
  binding fix above the one finding that mattered), no `eval`/`curl | bash`/unsafe
  deserialization anywhere in the codebase, and the CI workflow already had correctly
  scoped `permissions: contents: read` with no secrets in use.

## Phase 14 - real-hardware failure, and the repo's first outside contribution (2026-08-10)

- **The stale-mapping cleanup logic corrupted a live rig.** During a routine re-run of
  `install.sh` against a drive that was already unlocked, mounted, and actively running
  a full stack, the direct-IO liveness probe gave a false negative against the genuinely
  live mapping - and the fallback then ran `dmsetup remove -f` against it. Against a
  busy device that doesn't fail cleanly: it silently swaps the live table for an error
  target, which reads as an ordinary command failure but turns every subsequent
  read/write on the real, mounted filesystem into an I/O error. Confirmed via `dmesg`:
  buffer I/O errors, the ext4 journal aborting, and the filesystem force-remounting
  read-only mid-session - Docker's data-root and Open WebUI's own database were both on
  it, so both broke. Recovered by stopping Docker, cleanly unmounting everything, and
  `luksClose`-ing the now-harmless error-target mapping; the underlying physical
  partition itself was never written to after the table swap, so nothing was lost - the
  drive was rebuilt fresh anyway since it held nothing worth preserving.
- Fixed in `install.sh` and `connect.sh`: before attempting any teardown, actual usage
  (mounted, or a nonzero `dmsetup` open count) is now checked independently of the
  liveness probe, and the mapping is left alone entirely - loud error, not a silent
  guess - if either says it's genuinely in use. The final `dmsetup remove` fallback also
  dropped `-f`, since by that point usage has already been ruled out.
- **The repo's first pull request from someone else** (CMDRPhaedra, `#1`,
  `macos-external-drive-only`): `install-macos-arm.sh`'s drive picker only ever listed
  every `/Volumes` entry, including the internal boot disk, and only checked
  `Device Location=External` - a drive plugged in from Windows/Linux (NTFS, ext4) would
  pass that check and then silently fail to write. Now filters to external volumes only,
  refuses an internal disk outright (matching the Windows/Linux picker's own refusal),
  checks the filesystem is actually writable (APFS/HFS+/ExFAT/FAT), and offers a second
  path to format an external physical disk from scratch - typed `YES` confirmation,
  mirroring `install.sh`'s own pattern. Correctly avoids `mapfile`/`readarray` throughout
  (macOS ships bash 3.2, not bash 4+).
- Same PR added **`mac-eject.sh`** - macOS had no scripted way to stop the stack before
  unplugging the drive at all. Finds the rig by searching external volumes for the
  `portable-ai/stack` folder (same reasoning as `eject.sh`'s label lookup on Linux - ask
  the drive, not the host), stops only the containers this rig's own
  `docker-compose.yml` defines - read via `docker compose config --services`, passed to
  `stop` by name - so it can never touch other Docker Compose projects or standalone
  containers a user has running, then ejects. Reviewed in full before merging: syntax
  clean, CI green on the PR branch and after merge, and the logic holds up against a
  careful read - no shortcuts taken just because it came from outside.

## Phase 15 - native ComfyUI on macOS, implemented from CMDRPhaedra's design (2026-08-10)

- CMDRPhaedra's second PR added `mac-backlog.md`, a design sketch for running ComfyUI
  natively on macOS (Docker Desktop for Mac has no Metal GPU passthrough to containers,
  confirmed still true as of Apple's own `container` tool hitting 1.0 in June 2026 - GPU
  passthrough remains an open, uncommitted roadmap item there too). Implemented
  faithfully in `install-macos-arm.sh`: clones `Comfy-Org/ComfyUI` (the project's actual
  current home - verified live via the GitHub API, since a web search while researching
  turned up stale/conflicting version data) at `v0.31.0`, sets up its own venv, offers
  the same two checkpoints as `install.sh` with the same URLs and SHA256 hashes, runs it
  as a `launchd` service bound to `127.0.0.1:8188` (matching Open WebUI's own
  localhost-only default), and wires it into Open WebUI via the existing
  `setup_image_config.py` completely unchanged - it was already engine-agnostic - over
  `http://host.docker.internal:8188`.
- `mac-eject.sh` now unloads the ComfyUI `launchd` job before its existing stop/eject
  sequence, since its open file handles into the drive would otherwise block ejecting.
- Also fixed the Ollama-in-Docker header comment mac-backlog.md flagged in passing: it
  claimed "Metal-accelerated" without ever having checked, and Ollama runs the same
  containerised path with the same GPU-passthrough gap - corrected to say what's
  actually known rather than repeat an unverified claim.
- **Explicitly not verified on real Apple Silicon hardware** - this project's own drives
  have all been built and tested on Linux/Windows. Every script here passes `bash -n`
  and `shellcheck --severity=warning` cleanly (verified locally against the exact CI
  command, not assumed), which proves the code parses and is free of known bad
  patterns - not that the venv setup succeeds, that the `launchd` service actually
  starts, that `host.docker.internal` is reachable from inside the `openwebui`
  container, or that ComfyUI is genuinely Metal-accelerated rather than silently falling
  back to CPU. Tracked openly in
  [issue #3](https://github.com/soullessmonarc/portabrain/issues/3) rather than claimed
  as done - consistent with this project's own rule about not calling something
  "verified" without real hardware behind it.

## Phase 16 - resumable downloads and input hardening in fetch_weight (2026-08-10)

- **Real-hardware failure, caught live.** During a Megatron rebuild, three separate
  multi-GB downloads (Animagine, LTX, T5) all hit `curl: (92) HTTP/2 stream 1 was not
  closed cleanly: CANCEL (err 8)` partway through, at 43%, 83%, and 94% respectively -
  a genuine, reproducible pattern of HTTP/2 stream resets on large transfers, not user
  error. `fetch_weight()`'s retry loop restarted every download from 0% on each retry,
  so a failure at 94% meant re-downloading the whole multi-GB file from scratch.
- Also caught in the same run: a stray character (most likely a terminal/redraw glitch
  from the interrupted progress meter, not a real user paste) landed in the URL prompt
  after a failed attempt, producing `curl: (3) URL rejected: No host part in the URL`
  and burning the remaining retries on garbage input instead of a real retry - silently
  turning "one transient network blip" into "this download is skipped."
- **Fixed: resumable downloads.** `curl -C -` now auto-resumes from `$dest.part`'s
  existing size rather than starting over, tracked against which URL that partial
  belongs to (a URL change - a pasted alternate, or a CivitAI relocation - correctly
  wipes it first, since resuming across different URLs would splice two different
  responses into one corrupt file). Verified both real hosts actually support this
  before relying on it: Hugging Face confirms `accept-ranges: bytes`; CivitAI's actual
  Cloudflare R2-backed delivery URL returns a genuine `206 Partial Content` with a
  correct `Content-Range` on a live range request - checked directly, not assumed from
  either host's general reputation for supporting it.
- **Fixed: resume failure doesn't get stuck.** `curl -C -` hard-fails with exit 33 if a
  server ever doesn't support ranges (confirmed live against a plain Python
  `http.server` in a standalone test - it does NOT silently fall back to a full
  download the way an untested assumption might suggest). Exit 33 is now detected
  specifically and drops back to a full download instead of repeating the identical
  failure on every remaining attempt.
- **Fixed: input validation.** A prompt response has to start with `http://` or
  `https://` to be accepted at all now; anything else is rejected with a clear message
  and doesn't consume a real attempt or reach curl as a malformed URL.
- Giving up after 3 attempts (or an explicit `skip`) no longer discards a partial
  download - it's left in place with a note that re-running the script will resume
  from there, consistent with this project's broader "safe to re-run" philosophy.
- All four copies of `fetch_weight()` (`install.sh`, the macOS port in
  `install-macos-arm.sh`, and the two Megatron-side copies) updated in parity, each
  independently checked for control-character/CRLF corruption before editing - one of
  the four was the exact live script a real install run had been executing minutes
  earlier, confirmed finished and no longer running before it was touched.
- Verified with an isolated test harness (a real local HTTP server, not just `bash -n`):
  resume-after-interruption produces byte-correct output, a garbage prompt response is
  rejected without reaching curl, and a mid-retry URL change wipes stale partial data
  rather than corrupting the result via a mismatched resume - each scenario checked
  against actual behavior, not just read for plausibility.
- **Follow-up, same day:** the Animagine download hit the identical HTTP/2 stream-reset
  error on a second, separate install run - the resumable-download fix worked correctly
  (progress carried forward instead of restarting each time), but the underlying cause
  kept recurring. Every observed failure across both runs was specifically an HTTP/2
  stream reset, not a plain connection failure, so `fetch_weight()` now forces
  `--http1.1`: a single persistent connection per download has nothing for either side
  to reset the way an HTTP/2 stream can be. Verified live, not assumed, that both hosts
  still serve correct `206 Partial Content` range responses under forced HTTP/1.1, so
  the resume behavior above is unaffected.

## Phase 17 - a literal DEL byte broke the SMB share heartbeat for 20+ minutes (2026-08-11)

- **Real-hardware failure, caught live.** The network-share heartbeat timer (runs every
  30 seconds, `mount -a`-based reconnect) had been failing continuously - 40+
  consecutive attempts, well past its own 10-attempt alert threshold - and the share was
  not mounted. Root cause: `/etc/fstab`'s device string for the share was
  `//<0x7F DEL byte>/media` (rendered by a terminal as `///media`, which looks like a
  plain triple-slash typo rather than what it actually is). Both bash's own parsing and
  fstab's parser accept this as syntactically valid, so nothing failed until the actual
  mount attempt - and `mount -a` doesn't surface *why* a line failed, so the heartbeat
  just logged "not reachable" every 30 seconds indefinitely with no diagnostic value.
- The DEL byte's origin: a stray Backspace keystroke, typed at the "Server address" or
  "Share name" prompt during a real interactive install run, appears to have leaked
  through as a literal DEL byte instead of being consumed by normal terminal
  line-editing - observed through this project's PowerShell -> `wsl.exe` -> `bash`
  hand-off specifically, the same class of terminal-bridging quirk that produced a
  stray `#` in a download-URL prompt earlier the same night (Phase 16). Neither
  incident's exact trigger was pinned down with certainty, but both point at the same
  bridge, and both are now defended against at the point where untrusted input enters a
  script, rather than by trying to fix the bridge itself.
- **Immediate fix (this specific drive):** confirmed the stored SMB credentials were
  correct all along - a direct test mount with them succeeded immediately - so the
  only actual problem was the corrupted fstab line. Rewrote `/etc/fstab` byte-aware
  (Python, not a text-based `grep -v`, since the corrupted line's real content
  disagreed with what it visually rendered as) with the correct device string, backed
  up the original first, and verified `mount -a` succeeds cleanly with it.
- **Root-cause fix (so this can't recur):** `normalise_smb_part()` (`install.sh`, and
  the identical copy in the Megatron-side install script) now strips all ASCII control
  characters (0x00-0x1F, 0x7F) before doing anything else with SMB host/share input.
  `install-macos-arm.sh` had no normalisation function for this at all - added
  equivalent stripping there too, since its `mount_smbfs` command is built from the
  same kind of unsanitised input. Verified against the exact real corruption case
  (a DEL byte in the same position that broke this drive) plus both existing passing
  cases (plain host, a pasted UNC path) to confirm no regression.

## Phase 18 - native ComfyUI on macOS, confirmed working on real Apple Silicon (2026-08-11)

- **CMDRPhaedra tested issue #3 end-to-end on real hardware** (M-series Mac, macOS
  26.6.1, Docker Desktop 29.4.0): checkpoint downloads and checksum verification, the
  `launchd` service, and Open WebUI wiring all worked. Critically, **Metal/MPS
  acceleration is confirmed genuine, not a silent CPU fallback** - `/system_stats`
  reports `"device":"mps"`, the ComfyUI log shows the diffusion model loaded directly
  to GPU, and SDXL sampling ran at a steady ~2.0 it/s. Ollama-in-Docker was separately
  confirmed CPU-only as this project's own comments predicted (~19 tok/s on a 7B q4
  model, no Metal passthrough into Docker Desktop's VM) - both halves of the design
  tradeoff this feature was built around, now verified rather than assumed.
- A real image was generated through Open WebUI's actual `/api/v1/images/generations`
  endpoint - a correct, coherent 512x512 PNG, not noise or an error placeholder.
- **Two real bugs found, both fixed:**
  - `mac-eject.sh`'s own header comment assumed Docker Desktop never needed stopping
    for eject to work, since nothing here uses its data-root. Wrong in practice:
    Docker Desktop's own Virtualization.framework VM process holds a handle on the
    external volume independent of any specific container - reproduced reliably, and
    stopping or even fully removing this rig's containers did not release it. Only
    quitting Docker Desktop did. Fixed: `mac-eject.sh` now runs `docker desktop stop`
    (the same graceful CLI the Windows side already uses) after stopping containers
    and before ejecting, and the failure diagnostics now specifically recognise a
    Virtualization.framework dissent reason and tell the user to quit Docker Desktop
    entirely rather than defaulting to a generic `lsof` dump.
  - The 2-minute ComfyUI readiness timeout was measured too tight for a genuine cold
    start - importing torch alone took 30-60s on real hardware, on top of
    ComfyUI-Manager's own startup registry fetch and reading a multi-GB checkpoint off
    an external drive. Not a hard failure (a re-run picks up cleanly and wires things
    up once ComfyUI is actually up), but avoidable. Extended to 5 minutes, and the
    warning message now says plainly that a timeout here isn't necessarily a real
    failure.
- Both fixes address CMDRPhaedra's exact findings but have not themselves been
  re-verified on real hardware yet - the underlying implementation *is* now confirmed
  working end-to-end, but these two specific changes are still owed a real-hardware
  check.
