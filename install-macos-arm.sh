#!/bin/bash
# Portable AI rig - macOS (Apple Silicon) installer. This is a starting
# point, not full feature parity with the Windows/Linux version yet:
#
#   - Ollama runs great here (Metal-accelerated).
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
  echo "WARNING: this doesn't look like Apple Silicon (uname -m = $(uname -m)). Continuing anyway, but Ollama's Metal acceleration assumes arm64." >&2
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
echo "== Available volumes =="
DEFAULT_VOL="/Volumes"
ls -1 "$DEFAULT_VOL" 2>/dev/null | sed 's/^/  - /'
echo ""
read -r -p "Path to an external drive/folder to use for this rig (e.g. /Volumes/MyDrive): " BASE_DIR
if [ -z "$BASE_DIR" ] || [ ! -d "$BASE_DIR" ]; then
  echo "ERROR: '$BASE_DIR' doesn't exist. Plug in the drive (or pick an existing folder) and re-run." >&2
  exit 1
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
