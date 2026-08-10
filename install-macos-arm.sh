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
#   - ComfyUI's image/video generation is NOT set up by this script - the
#     Linux/Windows version uses a CUDA-only image (yanwk/comfyui-boot),
#     which doesn't run on Apple Silicon at all. A Metal/MPS-based ComfyUI
#     setup is future work; for now this gets you a working chat+coder rig.
#
# Run with: bash install-macos-arm.sh (no sudo needed - Docker Desktop
# handles its own privilege escalation when it needs to).

set -euo pipefail

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

echo ""
echo "Done. Open WebUI: http://localhost:8080"
echo ""
echo "Not set up yet on macOS (see the note at the top of this script):"
echo "  - ComfyUI image/video generation (needs a Metal/MPS-based setup, not the CUDA image used on Linux/Windows)"
docker compose ps
