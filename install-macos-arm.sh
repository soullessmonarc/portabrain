#!/bin/bash
# Portable AI rig - macOS (Apple Silicon) installer. This is a starting
# point, not full feature parity with the Windows/Linux version yet:
#
#   - Ollama runs via Docker Desktop, same as everything else here - and
#     Docker Desktop for Mac has no Metal GPU passthrough to containers at
#     all (true across M1 through M5, and still the case on Apple's own
#     `container` tool as of its 1.0 release). So this is almost certainly
#     running on CPU only, not Metal-accelerated - not verified against a
#     real benchmark, but the "runs great, Metal-accelerated" claim this
#     comment used to make had never been checked either. See mac-backlog.md
#     for the real fix (running Ollama natively, outside Docker).
#   - Open WebUI runs fine via Docker Desktop.
#   - ComfyUI (image generation) now runs, but natively on the host, not in
#     Docker - the same GPU passthrough gap above means a containerised
#     ComfyUI would be CPU-only, defeating the point. Open WebUI stays in
#     Docker (it doesn't need the GPU) and reaches native ComfyUI over
#     `http://host.docker.internal:8188`, a Docker Desktop for Mac/Windows
#     built-in. Confirmed working end-to-end on real Apple Silicon hardware
#     (issue #3): a real image generated through Open WebUI's own endpoint,
#     genuine Metal/MPS acceleration ("device":"mps", model loaded directly
#     to GPU), not a silent CPU fallback.
#   - Video generation (LTX-Video) is still not set up on macOS - explicitly
#     out of scope for the ComfyUI work above, see mac-backlog.md.
#
# Run with: bash install-macos-arm.sh (no sudo needed - Docker Desktop
# handles its own privilege escalation when it needs to).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "===== Portable AI Rig Setup (macOS / Apple Silicon) ====="
echo ""

if [ "$(uname -m)" != "arm64" ]; then
  echo "WARNING: this doesn't look like Apple Silicon (uname -m = $(uname -m)). Continuing anyway, but this script assumes arm64." >&2
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker Desktop not found. Install it first: https://www.docker.com/products/docker-desktop/"
  echo "(This script doesn't install Docker Desktop for you - it needs a signed .dmg installer, not a package manager script.)"
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker Desktop is installed but doesn't seem to be running. Start it, then re-run this script."
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Pick where this rig lives
# ---------------------------------------------------------------------------
# Two paths: use a folder on a drive that's already in a format macOS can
# write to (APFS, Mac OS Extended/HFS+, or ExFAT), or format an external disk
# from scratch - blank, or left over from Windows/Linux as NTFS (macOS mounts
# that read-only) or ext4 (macOS can't even read it).
#
# No mapfile/readarray below: macOS ships bash 3.2 (GPLv3 avoidance), which
# doesn't have it - unlike install.sh, which only ever runs on Linux/WSL2's
# much newer bash.
SUPPORTED_FS_REGEX='^(APFS|Mac OS Extended|ExFAT|MS-DOS)'

echo "== Available external volumes =="
SUPPORTED_VOLS=()
UNSUPPORTED_COUNT=0
for v in /Volumes/*/; do
  [ -d "$v" ] || continue
  name="$(basename "$v")"
  info="$(diskutil info "$v" 2>/dev/null)" || continue
  loc="$(printf '%s' "$info" | awk -F': *' '/Device Location/{print $2}')"
  [ "$loc" = "External" ] || continue
  fs="$(printf '%s' "$info" | awk -F': *' '/File System Personality/{print $2}')"
  ro="$(printf '%s' "$info" | awk -F': *' '/Volume Read-Only/{print $2}')"
  if [ "$ro" = "No" ] && printf '%s' "$fs" | grep -qE "$SUPPORTED_FS_REGEX"; then
    echo "  - $name ($fs)"
    SUPPORTED_VOLS+=("$name")
  else
    UNSUPPORTED_COUNT=$((UNSUPPORTED_COUNT + 1))
  fi
done
if [ "${#SUPPORTED_VOLS[@]}" -eq 0 ]; then
  echo "  (none found - a drive plugged in but not listed here may need formatting; see option 2 below)"
fi
if [ "$UNSUPPORTED_COUNT" -gt 0 ]; then
  echo "  ($UNSUPPORTED_COUNT external drive(s) hidden - not in a format macOS can write to; use option 2 to format one)"
fi

echo ""
echo "How should this rig get its storage?"
echo "  1) Use a folder on one of the drives listed above"
echo "  2) Format an external drive now (ERASES EVERYTHING on it)"
read -r -p "Select [1/2, default 1]: " STORAGE_CHOICE
STORAGE_CHOICE="${STORAGE_CHOICE:-1}"

if [ "$STORAGE_CHOICE" = "2" ]; then
  echo ""
  echo "== External disks available to format =="
  DISK_LINES=()
  while IFS= read -r d; do
    [ -n "$d" ] && DISK_LINES+=("$d")
  done < <(diskutil list external physical 2>/dev/null | grep -E '^/dev/disk[0-9]+ \(external, physical\):' | awk '{print $1}' | xargs -n1 basename)

  if [ "${#DISK_LINES[@]}" -eq 0 ]; then
    echo "ERROR: no external physical disks found. Plug one in and re-run." >&2
    exit 1
  fi

  for i in "${!DISK_LINES[@]}"; do
    d="${DISK_LINES[$i]}"
    dinfo="$(diskutil info "$d" 2>/dev/null)"
    dname="$(printf '%s' "$dinfo" | awk -F': *' '/Device.*Media Name/{print $2}')"
    dsize="$(printf '%s' "$dinfo" | awk -F': *' '/Disk Size/{print $2}' | sed -E 's/ \(.*//')"
    printf "  %s) %-8s %10s  %s\n" "$((i + 1))" "$d" "$dsize" "${dname:-(unknown model)}"
  done

  DISK_ID=""
  while [ -z "$DISK_ID" ]; do
    read -r -p "Select the drive to format [1-${#DISK_LINES[@]}]: " DISK_CHOICE
    if ! printf '%s' "$DISK_CHOICE" | grep -qE '^[0-9]+$' || [ "$DISK_CHOICE" -lt 1 ] || [ "$DISK_CHOICE" -gt "${#DISK_LINES[@]}" ]; then
      echo "Please enter a number between 1 and ${#DISK_LINES[@]}."
      continue
    fi
    DISK_ID="${DISK_LINES[$((DISK_CHOICE - 1))]}"
  done

  echo ""
  echo "!!! WARNING !!!"
  echo "This will ERASE EVERYTHING on /dev/$DISK_ID and reformat it as APFS."
  read -r -p "Type YES (in capitals) to confirm and continue: " CONFIRM
  if [ "$CONFIRM" != "YES" ]; then
    echo "Aborted, nothing was changed."
    exit 1
  fi

  VOLNAME=""
  while [ -z "$VOLNAME" ]; do
    read -r -p "Name for the new volume [PortableAI]: " VOLNAME
    VOLNAME="${VOLNAME:-PortableAI}"
    if ! printf '%s' "$VOLNAME" | grep -qE '^[A-Za-z0-9 _-]+$'; then
      echo "  Use only letters, numbers, spaces, - and _."
      VOLNAME=""
    fi
  done

  echo "== Formatting /dev/$DISK_ID as APFS ($VOLNAME) =="
  diskutil eraseDisk APFS "$VOLNAME" GPT "/dev/$DISK_ID"

  BASE_DIR="/Volumes/$VOLNAME"
  for _ in $(seq 1 10); do
    [ -d "$BASE_DIR" ] && break
    sleep 1
  done
  if [ ! -d "$BASE_DIR" ]; then
    echo "ERROR: formatted the drive but $BASE_DIR never appeared." >&2
    exit 1
  fi
else
  echo ""
  read -r -p "Path to an external drive/folder to use for this rig (e.g. /Volumes/MyDrive): " BASE_DIR
  if [ -z "$BASE_DIR" ] || [ ! -d "$BASE_DIR" ]; then
    echo "ERROR: '$BASE_DIR' doesn't exist. Plug in the drive (or pick an existing folder) and re-run." >&2
    exit 1
  fi

  BASE_MOUNT="$(df -P "$BASE_DIR" | tail -1 | awk '{print $NF}')"
  BASE_INFO="$(diskutil info "$BASE_MOUNT" 2>/dev/null)"
  BASE_LOC="$(printf '%s' "$BASE_INFO" | awk -F': *' '/Device Location/{print $2}')"
  if [ "$BASE_LOC" != "External" ]; then
    echo "ERROR: '$BASE_DIR' is on an internal drive (diskutil reports: ${BASE_LOC:-unknown}). This rig is meant to live on an external drive you can move between machines - plug one in and pick it from the list above." >&2
    exit 1
  fi

  BASE_RO="$(printf '%s' "$BASE_INFO" | awk -F': *' '/Volume Read-Only/{print $2}')"
  BASE_FS="$(printf '%s' "$BASE_INFO" | awk -F': *' '/File System Personality/{print $2}')"
  if [ "$BASE_RO" != "No" ] || ! printf '%s' "$BASE_FS" | grep -qE "$SUPPORTED_FS_REGEX"; then
    echo "ERROR: '$BASE_DIR' is formatted as ${BASE_FS:-unknown}, which macOS can't write to. Re-run and choose option 2 to format it, or pick a different drive." >&2
    exit 1
  fi
fi

MOUNT_POINT="$BASE_DIR/portable-ai"
STACK_DIR="$MOUNT_POINT/stack"
mkdir -p "$STACK_DIR" "$MOUNT_POINT/models/llm" "$MOUNT_POINT/workspace/output"
echo "Using $MOUNT_POINT"

# ---------------------------------------------------------------------------
# 2. Optional network (SMB) share for extra storage
# ---------------------------------------------------------------------------
echo ""
read -r -p "Mount a network (SMB) share for extra storage too? [y/N]: " WANT_SMB
SHARE_MOUNT=""
if [[ "$WANT_SMB" =~ ^[Yy]$ ]]; then
  read -r -p "Server address (e.g. 192.168.1.10 or myserver.local): " SMB_HOST
  read -r -p "Share name (e.g. Media, Backups): " SMB_SHARE
  # Strips control characters (0x00-0x1F, 0x7F). Confirmed live on the
  # Linux/Windows side: a stray Backspace keystroke leaked through as a
  # literal DEL byte instead of being consumed by line-editing, through a
  # PowerShell -> wsl.exe -> bash terminal bridge at this same kind of
  # prompt - corrupting the mount command built from it in a way that's
  # silently accepted as valid syntax and only fails at mount time. Applied
  # here too since the mount_smbfs command below is built from these
  # variables the same way.
  SMB_HOST="$(printf '%s' "$SMB_HOST" | tr -d '\000-\037\177')"
  SMB_SHARE="$(printf '%s' "$SMB_SHARE" | tr -d '\000-\037\177')"
  read -r -p "Username: " SMB_USER
  read -r -s -p "Password: " SMB_PASS
  echo ""
  read -r -p "Local mount point [/Volumes/PortableAIShare]: " SHARE_MOUNT
  SHARE_MOUNT="${SHARE_MOUNT:-/Volumes/PortableAIShare}"

  # Store the password in the macOS Keychain rather than any script file on
  # disk, so the heartbeat agent below can retrieve it later to reconnect
  # without ever having it embedded in plaintext anywhere.
  KEYCHAIN_SERVICE="portableai-smb-${SMB_HOST}"
  security add-generic-password -a "$SMB_USER" -s "$KEYCHAIN_SERVICE" -w "$SMB_PASS" -U 2>/dev/null || true

  mkdir -p "$SHARE_MOUNT" 2>/dev/null || true
  echo "== Mounting network share =="
  # Use a private, freshly-created log file rather than a predictable shared
  # path under /tmp - mount_smbfs error output can echo back the server URL,
  # and a world-readable /tmp/smb-mount.log would leak that to any other
  # local user on a multi-user Mac.
  SMB_LOG="$(mktemp /tmp/smb-mount.XXXXXX.log)"
  chmod 600 "$SMB_LOG"
  if /sbin/mount_smbfs "//${SMB_USER}:${SMB_PASS}@${SMB_HOST}/${SMB_SHARE}" "$SHARE_MOUNT" 2>"$SMB_LOG"; then
    echo "Network share mounted at $SHARE_MOUNT"
    mkdir -p "$SHARE_MOUNT/comfyui-output"
    rm -f "$SMB_LOG"
  else
    echo "WARNING: network share did not mount (see $SMB_LOG). Check the server address, share name, and credentials - the heartbeat below will keep retrying." >&2
  fi
  unset SMB_PASS

  # ComfyUI isn't wired up on macOS yet (see the note at the top of this
  # script), but Open WebUI's own uploads and any future generated output
  # should still follow the same "write locally, sync over on a timer"
  # pattern as the Linux/Windows version, since a dropped SMB mount mid-write
  # is exactly as disruptive here.
  echo "== Installing output-sync agent (drive -> network share, if reachable) =="
  cat > /usr/local/bin/portableai-sync-output.sh <<EOF
#!/bin/bash
set -euo pipefail
LOCAL_OUTPUT="$MOUNT_POINT/workspace/output"
SHARE_OUTPUT="$SHARE_MOUNT/comfyui-output"
if ! mount | grep -q " $SHARE_MOUNT "; then
  exit 0
fi
mkdir -p "\$SHARE_OUTPUT"
find "\$LOCAL_OUTPUT" -maxdepth 1 -type f -mtime +0s 2>/dev/null | while IFS= read -r file; do
  if mv -n "\$file" "\$SHARE_OUTPUT/" 2>/dev/null; then
    echo "moved \$(basename "\$file") -> \$SHARE_OUTPUT/"
  fi
done
EOF
  chmod +x /usr/local/bin/portableai-sync-output.sh

  cat > "$HOME/Library/LaunchAgents/com.portableai.sync.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.portableai.sync</string>
  <key>ProgramArguments</key>
  <array><string>/usr/local/bin/portableai-sync-output.sh</string></array>
  <key>StartInterval</key><integer>120</integer>
  <key>StandardOutPath</key><string>/tmp/portableai-sync.log</string>
  <key>StandardErrorPath</key><string>/tmp/portableai-sync.log</string>
</dict>
</plist>
EOF
  launchctl unload "$HOME/Library/LaunchAgents/com.portableai.sync.plist" 2>/dev/null || true
  launchctl load "$HOME/Library/LaunchAgents/com.portableai.sync.plist"

  echo "== Installing network-share heartbeat agent (auto-reconnect + alert after 10 failed attempts) =="
  cat > /usr/local/bin/portableai-share-heartbeat.sh <<EOF
#!/bin/bash
set -euo pipefail
SHARE_MOUNT="$SHARE_MOUNT"
SMB_USER="$SMB_USER"
SMB_HOST="$SMB_HOST"
SMB_SHARE="$SMB_SHARE"
KEYCHAIN_SERVICE="$KEYCHAIN_SERVICE"
STATE_DIR="\$HOME/Library/Application Support/PortableAI"
FAIL_COUNT_FILE="\$STATE_DIR/share-fail-count"
ALERTED_FILE="\$STATE_DIR/share-alerted"
MAX_ATTEMPTS=10
mkdir -p "\$STATE_DIR"

if mount | grep -q " \$SHARE_MOUNT "; then
  rm -f "\$FAIL_COUNT_FILE" "\$ALERTED_FILE"
  exit 0
fi

mkdir -p "\$SHARE_MOUNT" 2>/dev/null || true
SMB_PASS="\$(security find-generic-password -a "\$SMB_USER" -s "\$KEYCHAIN_SERVICE" -w 2>/dev/null || echo '')"
if [ -n "\$SMB_PASS" ]; then
  /sbin/mount_smbfs "//\${SMB_USER}:\${SMB_PASS}@\${SMB_HOST}/\${SMB_SHARE}" "\$SHARE_MOUNT" >/dev/null 2>&1 || true
fi
unset SMB_PASS

if mount | grep -q " \$SHARE_MOUNT "; then
  echo "Network share reconnected."
  rm -f "\$FAIL_COUNT_FILE" "\$ALERTED_FILE"
  exit 0
fi

COUNT=0
[ -f "\$FAIL_COUNT_FILE" ] && COUNT="\$(cat "\$FAIL_COUNT_FILE")"
COUNT=\$((COUNT + 1))
echo "\$COUNT" > "\$FAIL_COUNT_FILE"
echo "Network share not reachable (attempt \$COUNT/\$MAX_ATTEMPTS)."

if [ "\$COUNT" -ge "\$MAX_ATTEMPTS" ] && [ ! -f "\$ALERTED_FILE" ]; then
  touch "\$ALERTED_FILE"
  MSG="The network share has been unreachable for \$COUNT consecutive checks and could not reconnect automatically. Check the share server is on and reachable, and the saved credentials are still correct. Nothing is lost - generated files are queued locally and will sync once it's back."
  osascript -e "display notification \"\$MSG\" with title \"Portable AI Rig\" subtitle \"Network Share Down\"" 2>/dev/null || true
  echo "ALERT: \$MSG" >&2
fi
EOF
  chmod +x /usr/local/bin/portableai-share-heartbeat.sh

  cat > "$HOME/Library/LaunchAgents/com.portableai.share-heartbeat.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.portableai.share-heartbeat</string>
  <key>ProgramArguments</key>
  <array><string>/usr/local/bin/portableai-share-heartbeat.sh</string></array>
  <key>StartInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>/tmp/portableai-share-heartbeat.log</string>
  <key>StandardErrorPath</key><string>/tmp/portableai-share-heartbeat.log</string>
</dict>
</plist>
EOF
  launchctl unload "$HOME/Library/LaunchAgents/com.portableai.share-heartbeat.plist" 2>/dev/null || true
  launchctl load "$HOME/Library/LaunchAgents/com.portableai.share-heartbeat.plist"
fi

# ---------------------------------------------------------------------------
# 3. Compose stack (Ollama + Open WebUI only - see the ComfyUI note above)
# ---------------------------------------------------------------------------
echo ""
echo "== Writing stack files to $STACK_DIR =="
cat > "$STACK_DIR/docker-compose.yml" <<EOF
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    environment:
      - OLLAMA_MODELS=/models/llm
      - OLLAMA_KEEP_ALIVE=30m
    volumes:
      - $MOUNT_POINT/models/llm:/models/llm
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
    networks: [ai]

  openwebui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: openwebui
    restart: unless-stopped
    ports: ["8080:8080"]
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
      - WEBUI_AUTH=true
    volumes:
      - $STACK_DIR/openwebui:/app/backend/data
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
    tmpfs:
      - /tmp
    depends_on: [ollama]
    networks: [ai]

networks:
  ai:
    driver: bridge
EOF

echo "== Bringing up the stack =="
cd "$STACK_DIR"
docker compose up -d
sleep 5

echo ""
echo "Pick a chat/coder model pair to install:"
echo "  1) Standard instruction-tuned models (Qwen2.5 7B, safe defaults)"
echo "  2) Uncensored/abliterated variants (no content filter - your responsibility)"
read -r -p "Select [1/2, default 1]: " MODEL_CHOICE
MODEL_CHOICE="${MODEL_CHOICE:-1}"

if [ "$MODEL_CHOICE" = "2" ]; then
  CHAT_MODEL="huihui_ai/qwen2.5-abliterate:7b-instruct-q4_K_M"
  CODER_MODEL="huihui_ai/qwen2.5-coder-abliterate:7b-instruct-q4_K_M"
else
  CHAT_MODEL="qwen2.5:7b-instruct-q4_K_M"
  CODER_MODEL="qwen2.5-coder:7b-instruct-q4_K_M"
fi

echo "== Pulling $CHAT_MODEL =="
docker exec ollama ollama pull "$CHAT_MODEL"
echo "== Pulling $CODER_MODEL =="
docker exec ollama ollama pull "$CODER_MODEL"

# ---------------------------------------------------------------------------
# 4. ComfyUI (image generation) - runs natively on the host, not in Docker
# ---------------------------------------------------------------------------
# See the header comment at the top of this file for why: Docker Desktop for
# Mac has no Metal GPU passthrough to containers, so a containerised ComfyUI
# would be CPU-only. Open WebUI stays in Docker (it doesn't need the GPU) and
# reaches this over host.docker.internal, a Docker Desktop for Mac/Windows
# built-in that resolves to the host's own loopback from inside a container -
# which is also why ComfyUI is bound to 127.0.0.1 below rather than 0.0.0.0,
# matching Open WebUI's own localhost-only security default (see
# SECURITY.md#network-exposure) without needing a wider bind to be reachable
# from Docker Desktop's side.
echo ""
read -r -p "Set up image generation (ComfyUI, runs natively for real GPU access)? [Y/n]: " WANT_COMFYUI
COMFYUI_READY=0
if [[ ! "$WANT_COMFYUI" =~ ^[Nn]$ ]]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "WARNING: python3 not found - ComfyUI needs it and can't be set up. Install" >&2
    echo "         Python 3 (e.g. via Xcode Command Line Tools: xcode-select --install," >&2
    echo "         or python.org) and re-run this script to add it later." >&2
  else
    COMFYUI_DIR="$MOUNT_POINT/comfyui/ComfyUI"
    COMFYUI_TAG="v0.31.0"
    COMFYUI_REPO="https://github.com/Comfy-Org/ComfyUI.git"

    if [ -d "$COMFYUI_DIR/.git" ]; then
      echo "== ComfyUI checkout already present at $COMFYUI_DIR - leaving it as-is =="
      echo "   (to move to a different version, remove that folder and re-run)"
    else
      echo "== Cloning ComfyUI $COMFYUI_TAG =="
      mkdir -p "$(dirname "$COMFYUI_DIR")"
      git clone --branch "$COMFYUI_TAG" --depth 1 "$COMFYUI_REPO" "$COMFYUI_DIR"
    fi

    echo "== Setting up ComfyUI's Python environment (this can take a few minutes) =="
    if [ ! -d "$COMFYUI_DIR/venv" ]; then
      python3 -m venv "$COMFYUI_DIR/venv"
    fi
    # shellcheck disable=SC1091
    source "$COMFYUI_DIR/venv/bin/activate"
    pip install --quiet --upgrade pip
    # No separate --index-url for a Metal/MPS build: the standard macOS arm64
    # PyPI wheels for torch already include MPS support, unlike the CUDA
    # builds Linux/Windows need a special index for.
    pip install --quiet -r "$COMFYUI_DIR/requirements.txt"
    deactivate

    echo ""
    echo "Two checkpoints are offered. Juggernaut is the general-purpose one and"
    echo "becomes the default; Animagine is stylised/anime-focused. Either can be"
    echo "skipped with 'skip' - one is enough to start. Same checkpoints, URLs, and"
    echo "hashes as the Linux/Windows installer - see NOTICE.md for licensing."
    COMFYUI_CKPT_DIR="$COMFYUI_DIR/models/checkpoints"
    JUGGERNAUT_CKPT_NAME="juggernautXL_v9.safetensors"
    JUGGERNAUT_CKPT_URL_DEFAULT="https://civitai.com/api/download/models/348913?fileId=277777"
    JUGGERNAUT_CKPT_SHA256="c9e3e68f89b8e38689e1097d4be4573cf308de4e3fd044c64ca697bdb4aa8bca"
    ANIMAGINE_CKPT_NAME="animagine-xl-3.1.safetensors"
    ANIMAGINE_CKPT_URL_DEFAULT="https://huggingface.co/cagliostrolab/animagine-xl-3.1/resolve/main/${ANIMAGINE_CKPT_NAME}"
    ANIMAGINE_CKPT_SHA256="e3c47aedb06418c6c331443cd89f2b3b3b34b7ed2102a3d4c4408a8d35aad6b0"

    # Ported from install.sh (Linux/Windows) almost verbatim - same reasoning
    # throughout, just shasum -a 256 instead of sha256sum, which macOS
    # doesn't ship by default.
    civitai_resolve_url() {
      local model_id="$1" version_name="$2"
      python3 - "$model_id" "$version_name" <<'PYEOF'
import json, sys, urllib.request
model_id, version_name = sys.argv[1], sys.argv[2]
req = urllib.request.Request(
    f"https://civitai.com/api/v1/models/{model_id}",
    headers={"User-Agent": "curl/8.0"},
)
try:
    with urllib.request.urlopen(req, timeout=20) as resp:
        data = json.load(resp)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
for v in data.get("modelVersions", []):
    if v.get("name") == version_name:
        for f in v.get("files", []):
            if f.get("type") == "Model":
                print(f"https://civitai.com/api/download/models/{v['id']}?fileId={f['id']}")
                sys.exit(0)
print(f"NOTFOUND: '{version_name}' is not among this model's current versions", file=sys.stderr)
sys.exit(2)
PYEOF
    }

    fetch_weight() {
      local dest_dir="$1" filename="$2" default_url="$3" label="$4"
      local civitai_model_id="${5:-}" civitai_version_name="${6:-}" expected_sha256="${7:-}"
      local dest="$dest_dir/$filename"

      if [ -s "$dest" ]; then
        echo "  $label already present - skipping."
        return 0
      fi

      mkdir -p "$dest_dir"
      local url="$default_url"
      # Tracks which URL the current $dest.part (if any) was downloaded
      # from, so a retry can tell "same URL, safe to resume" from "URL
      # changed, this partial file is for something else". Seeded to
      # default_url rather than empty: a .part file already on disk from an
      # earlier run is assumed to belong to the default URL (the common
      # case), so the first attempt can resume it instead of discarding real
      # progress on multi-GB files. Pasting a different URL on that first
      # attempt is exactly the signal that invalidates that assumption.
      local last_url="$default_url"
      local healed=0
      local user_supplied_url=0
      local attempt
      for attempt in 1 2 3; do
        echo ""
        echo "  $label"
        echo "  Default: $url"
        read -r -p "  URL (Enter to accept, or paste another; 'skip' to skip): " REPLY_URL
        case "$REPLY_URL" in
          skip|SKIP) echo "  Skipped - this file will not be present until added manually."; return 1 ;;
          "") : ;;
          http://*|https://*) url="$REPLY_URL"; user_supplied_url=1 ;;
          *)
            echo "  '$REPLY_URL' doesn't look like a URL (must start with http:// or https://) -" >&2
            echo "  not attempting a download with it." >&2
            echo "  (attempt $attempt of 3)" >&2
            continue
            ;;
        esac

        # curl's -C - auto-detects the resume offset from $dest.part's size -
        # which would splice bytes from two different URLs' responses
        # together if the URL changed since the file was last written. Only
        # safe when retrying the exact same URL as before.
        if [ "$url" != "$last_url" ]; then
          rm -f "$dest.part"
        fi
        last_url="$url"

        echo "  Downloading..."
        local curl_status=0
        # --http1.1: every observed failure against these hosts has been an
        # HTTP/2 stream reset partway through a large transfer, not a plain
        # connection failure. HTTP/1.1 uses one plain persistent connection
        # per download instead of a multiplexed stream, so there is nothing
        # to reset that way. Verified live that both hosts still serve
        # correct range responses under forced HTTP/1.1.
        curl -fL --http1.1 -C - --retry 3 --retry-delay 2 -o "$dest.part" "$url" || curl_status=$?
        if [ "$curl_status" -eq 0 ]; then
          if [ -s "$dest.part" ]; then
            if [ -n "$expected_sha256" ] && [ "$user_supplied_url" -eq 0 ]; then
              echo "  Verifying checksum..."
              local actual_sha256
              actual_sha256="$(shasum -a 256 "$dest.part" | awk '{print tolower($1)}')"
              if [ "$actual_sha256" != "$(printf '%s' "$expected_sha256" | tr 'A-Z' 'a-z')" ]; then
                echo "  Checksum mismatch - not trusting this download." >&2
                rm -f "$dest.part"
                echo "  (attempt $attempt of 3)" >&2
                continue
              fi
              echo "  Checksum OK."
            fi
            mv "$dest.part" "$dest"
            echo "  Saved to $dest"
            return 0
          fi
          echo "  Download produced an empty file." >&2
          rm -f "$dest.part"
        elif [ "$curl_status" -eq 33 ]; then
          # curl's own code for "server doesn't support resuming this
          # download" - retrying with -C - again would just fail the same
          # way forever, so drop back to a full download instead.
          echo "  Server doesn't support resuming this download - trying a full download instead." >&2
          rm -f "$dest.part"
        else
          echo "  Download failed - $(du -h "$dest.part" 2>/dev/null | cut -f1) downloaded so far, will" >&2
          echo "  resume from there on the next attempt rather than starting over." >&2
        fi

        if [ -n "$civitai_model_id" ] && [ "$healed" -eq 0 ] && [ "$url" = "$default_url" ]; then
          healed=1
          echo "  Checking CivitAI for this exact version under a new URL (not a substitute)..."
          local resolved
          if resolved="$(civitai_resolve_url "$civitai_model_id" "$civitai_version_name")"; then
            echo "  Found: $resolved"
            url="$resolved"
            default_url="$resolved"
          fi
        fi
        echo "  (attempt $attempt of 3)" >&2
      done
      echo "  Giving up on $label for now." >&2
      if [ -s "$dest.part" ]; then
        echo "  $(du -h "$dest.part" 2>/dev/null | cut -f1) is already downloaded and left in place -" >&2
        echo "  re-running this script will resume from there rather than starting over." >&2
      fi
      return 1
    }

    fetch_weight "$COMFYUI_CKPT_DIR" "$JUGGERNAUT_CKPT_NAME" "$JUGGERNAUT_CKPT_URL_DEFAULT" \
      "Juggernaut XL v9 checkpoint, photoreal (~6.6GB)" "133005" "V9 + RunDiffusionPhoto 2" "$JUGGERNAUT_CKPT_SHA256" || true
    fetch_weight "$COMFYUI_CKPT_DIR" "$ANIMAGINE_CKPT_NAME" "$ANIMAGINE_CKPT_URL_DEFAULT" \
      "Animagine XL 3.1 checkpoint, stylised/anime (~6.9GB)" "" "" "$ANIMAGINE_CKPT_SHA256" || true

    IMAGE_CHECKPOINT=""
    if [ -s "$COMFYUI_CKPT_DIR/$JUGGERNAUT_CKPT_NAME" ]; then
      IMAGE_CHECKPOINT="$JUGGERNAUT_CKPT_NAME"
    elif [ -s "$COMFYUI_CKPT_DIR/$ANIMAGINE_CKPT_NAME" ]; then
      IMAGE_CHECKPOINT="$ANIMAGINE_CKPT_NAME"
    fi

    if [ -n "$IMAGE_CHECKPOINT" ]; then
      echo ""
      echo "== Installing the ComfyUI launchd service =="
      mkdir -p "$MOUNT_POINT/workspace/output" "$COMFYUI_DIR/user"
      cat > "$HOME/Library/LaunchAgents/com.portableai.comfyui.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.portableai.comfyui</string>
  <key>ProgramArguments</key>
  <array>
    <string>$COMFYUI_DIR/venv/bin/python3</string>
    <string>$COMFYUI_DIR/main.py</string>
    <string>--listen</string><string>127.0.0.1</string>
    <string>--port</string><string>8188</string>
    <string>--output-directory</string><string>$MOUNT_POINT/workspace/output</string>
    <string>--user-directory</string><string>$COMFYUI_DIR/user</string>
  </array>
  <key>WorkingDirectory</key><string>$COMFYUI_DIR</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/portableai-comfyui.log</string>
  <key>StandardErrorPath</key><string>/tmp/portableai-comfyui.log</string>
</dict>
</plist>
EOF
      launchctl unload "$HOME/Library/LaunchAgents/com.portableai.comfyui.plist" 2>/dev/null || true
      launchctl load "$HOME/Library/LaunchAgents/com.portableai.comfyui.plist"

      # 5 minutes, not 2: measured on real hardware (issue #3) that a genuine
      # cold start - importing torch, ComfyUI-Manager's own startup registry
      # fetch, reading a multi-GB checkpoint's venv/site-packages off the
      # external drive - can take 30-60s just for the torch import alone,
      # and 2 minutes end-to-end was observed cutting it close to a real
      # timeout. A timeout here isn't a failure needing intervention: the
      # ComfyUI process itself is still starting in the background and
      # re-running this script picks the wiring step up cleanly once it is.
      echo "== Waiting for ComfyUI to come up (up to 5 minutes on a cold start - importing"
      echo "   torch and reading a multi-GB checkpoint off an external drive takes a while) =="
      COMFYUI_UP=0
      for _ in $(seq 1 60); do
        if curl -sf --max-time 5 http://127.0.0.1:8188/system_stats >/dev/null 2>&1; then
          COMFYUI_UP=1
          break
        fi
        sleep 5
      done

      if [ "$COMFYUI_UP" -eq 1 ]; then
        echo "ComfyUI is up. See /tmp/portableai-comfyui.log if generation ever fails later."
        echo "== Wiring Open WebUI's image generation to ComfyUI =="
        docker cp "$SCRIPT_DIR/setup_image_config.py" openwebui:/app/backend/setup_image_config.py
        docker exec -w /app/backend -e CHECKPOINT_NAME="$IMAGE_CHECKPOINT" \
          -e COMFYUI_BASE_URL="http://host.docker.internal:8188" \
          openwebui python3 setup_image_config.py \
          || echo "warning: image generation could not be configured - see the message above." >&2
        COMFYUI_READY=1
      else
        echo "WARNING: ComfyUI didn't come up within 5 minutes. This is not necessarily a" >&2
        echo "         real failure - it may still be starting. Check /tmp/portableai-comfyui.log;" >&2
        echo "         if it's still initialising there, just wait and re-run this script once" >&2
        echo "         it's done - image generation will get wired up then. Image generation was" >&2
        echo "         not configured on this run." >&2
      fi
    else
      echo ""
      echo "NOTE: no image checkpoint was downloaded, so image generation will not be"
      echo "      configured. Put one in $COMFYUI_CKPT_DIR and re-run this script to add it later."
    fi
  fi
fi

echo ""
echo "Done. Open WebUI: http://localhost:8080"
echo ""
if [ "$COMFYUI_READY" -eq 1 ]; then
  echo "Image generation: ready (ComfyUI running natively at http://127.0.0.1:8188)."
else
  echo "Image generation: not set up this run - re-run this script to add it."
fi
echo ""
echo "Not set up yet on macOS (see the note at the top of this script):"
echo "  - Video generation (LTX-Video) - explicitly out of scope for the ComfyUI work above, see mac-backlog.md"
docker compose ps
