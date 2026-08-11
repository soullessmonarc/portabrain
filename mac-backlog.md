# macOS backlog

Suggested next improvements for the macOS (Apple Silicon) side of this project,
not yet implemented.

## Native ComfyUI image generation, alongside Ollama

**Implemented in `install-macos-arm.sh`, and confirmed working end-to-end on
real Apple Silicon hardware** - see
[issue #3](https://github.com/soullessmonarc/portabrain/issues/3): a real
image generated through Open WebUI's own endpoint, and genuine Metal/MPS
acceleration confirmed (`"device":"mps"`, the diffusion model loaded
directly to GPU), not a silent CPU fallback. That same real-hardware testing
found two bugs, both now fixed: Docker Desktop's own VM process blocking
`mac-eject.sh` regardless of container state, and a 2-minute cold-start
timeout measured too tight (now 5 minutes) - those two specific fixes are
still owed a real-hardware re-check of their own. The design sketch is kept
below as-built documentation, not as a plan still to be written.

`install-macos-arm.sh` previously only set up Ollama + Open WebUI via Docker
Desktop. Image generation (ComfyUI) was explicitly flagged in its own header
as future work, since the Linux/Windows ComfyUI container image
(`yanwk/comfyui-boot`) is CUDA-only and doesn't run on Apple Silicon at all.

**Why it has to run outside Docker.** Checked as of August 2026: no container
runtime on Apple Silicon can pass the GPU through to a container.

- Docker Desktop for Mac has no Metal GPU passthrough to containers - true
  across M1 through M5.
- Apple's own `container` tool (hit 1.0 in June 2026, lighter-weight than
  Docker Desktop) has GPU passthrough on its roadmap but not implemented -
  there's an open feature request from May 2026 asking for it. There's also
  a real architectural reason, not just "not built yet": Apple Silicon has no
  secondary GPU control interface, so full device passthrough the way it's
  done on some x86/Linux setups isn't currently possible there at all.

So ComfyUI would need to run natively on the host (outside Docker) to get
real GPU (Metal/MPS) acceleration, with Open WebUI - which stays in Docker,
it doesn't need the GPU - reaching it over the network via
`http://host.docker.internal:8188` (a Docker Desktop for Mac/Windows
built-in, no `extra_hosts` config needed).

**Design sketch, worked out but not yet built:**

- Layout on the drive, sibling to the existing `stack`, `models/llm`,
  `workspace/output` under `$MOUNT_POINT` (`$BASE_DIR/portable-ai`):
  `$MOUNT_POINT/comfyui/ComfyUI` (checkout + its own venv), models under
  `.../ComfyUI/models/checkpoints`. Output goes to the already-existing
  `$MOUNT_POINT/workspace/output` - the sync-to-SMB-share agent already
  anticipates this path (`comfyui-output` on the share side) even though
  nothing writes to it yet.
- Process management via a `launchd` agent, following the existing
  `com.portableai.*` convention already used for the sync/heartbeat agents,
  but `RunAtLoad` + `KeepAlive` (persistent service) instead of
  `StartInterval` (periodic timer). Binds to `127.0.0.1:8188` only, matching
  Open WebUI's own localhost-only security default.
- Checkpoint downloads: port `fetch_weight()` and `civitai_resolve_url()`
  from `install.sh` (~lines 1163-1273) almost verbatim, swapping
  `sha256sum` for `shasum -a 256` (macOS doesn't ship the former by
  default). Offer both checkpoints install.sh already offers - Juggernaut
  XL v9 (general-purpose) and Animagine XL 3.1 (anime) - reusing the exact
  URLs/hashes and the licensing already vetted in `NOTICE.md`.
- Wiring into Open WebUI reuses `setup_image_config.py` completely
  unchanged (it's already engine-agnostic) - only the invocation's
  `COMFYUI_BASE_URL` differs from the Linux/Windows
  `docker exec ... setup_image_config.py` call. `install-macos-arm.sh`
  doesn't currently define `SCRIPT_DIR` (install.sh:22 does) - needed so
  `docker cp` of that script works regardless of caller's cwd.
- Readiness: poll `curl -sf http://127.0.0.1:8188/system_stats` for up to
  ~2 minutes before wiring Open WebUI, rather than a blind `sleep`.
- Version pinning: `install.sh` pins its ComfyUI Docker image to an exact
  tag and tracks it via a marker file that warns (doesn't force-update) if
  the pinned version changes but the on-drive copy is older. Mirror this
  with `git clone --branch <TAG> --depth 1` to a specific ComfyUI release
  tag. The exact current tag and canonical repo URL need a live lookup at
  implementation time - a web search done while researching this returned
  stale/conflicting version data (an old `v0.3.10` tag, and some indication
  the project may have moved to the `Comfy-Org` GitHub org).
- `mac-eject.sh` needs a new step unloading the ComfyUI launchd job before
  the existing docker-compose-stop/`diskutil eject` sequence - its process
  holds open file handles into the drive that would otherwise block the
  eject.
- Docs to update once this lands: `docs/MASTER_SETUP.md:155-171` ("Known
  gap" line + steps), `docs/PRODUCTION_READINESS.md:101-103`,
  `docs/EXECUTIVE_SUMMARY.md:59-62,76`.

**Explicitly out of scope for this item:** video generation (LTX-Video) on
macOS - a separate, larger lift.

## Ollama-in-Docker on macOS is probably not actually Metal-accelerated

`install-macos-arm.sh`'s own header claims "Ollama runs great here
(Metal-accelerated)". Given Docker Desktop for Mac has no Metal GPU
passthrough to containers (see above), Ollama running inside the `ollama`
container on macOS is almost certainly running on CPU only today, not
Metal-accelerated as the comment claims. Worth verifying with a real
benchmark and either fixing the comment or moving Ollama to run natively
(outside Docker, like the ComfyUI item above) to get real acceleration -
these are two different fixes with different amounts of blast radius, so
worth deciding which before touching anything.
