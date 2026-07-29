#!/bin/bash
# Portable AI rig - generic public installer.
#
# Builds a self-contained Ollama + ComfyUI + Open WebUI stack on an external
# drive, so the whole thing can be unplugged and moved between machines. This
# is the Linux / Windows-WSL2 entry point; for Apple Silicon Macs see
# install-macos-arm.sh instead (this script will hand off to it if you pick
# that option below).
#
# On Windows, run install-windows.ps1 first (as Administrator) - it attaches
# your chosen physical disk to WSL2, then calls this script automatically.
# On native Linux, just run this script directly with sudo.
#
# Nothing in this script is tied to a specific machine, drive, or network -
# every choice (which drive, whether to use a network share, model sizes) is
# asked interactively or auto-detected from the hardware in front of it.
#
# Must be run with sudo/root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="PORTABLEAI"
DEFAULT_MOUNT_POINT="/mnt/portableai"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo bash install.sh" >&2
  exit 1
fi

# WSL2's nvidia-smi shim lives outside root's secure_path, so plain `sudo
# nvidia-smi` (or this script running fully as root) can't find it even
# though it works fine for an unprivileged shell. Harmless no-op on native
# Linux, where nvidia-smi already lives on the standard PATH.
export PATH="$PATH:/usr/lib/wsl/lib"

echo "===== Portable AI Rig Setup ====="
echo ""
echo "Which platform is this?"
echo "  1) Windows (via WSL2) or native Linux"
echo "  2) macOS - Apple Silicon (M-series)"
read -r -p "Select [1/2]: " PLATFORM_CHOICE

if [ "$PLATFORM_CHOICE" = "2" ]; then
  echo "Handing off to install-macos-arm.sh..."
  exec bash "$SCRIPT_DIR/install-macos-arm.sh"
fi

# ---------------------------------------------------------------------------
# 1. Pick a drive
# ---------------------------------------------------------------------------
echo ""
echo "== Available drives =="
mapfile -t DISK_LINES < <(lsblk -d -n -o NAME,SIZE,MODEL,TYPE | awk '$4=="disk"')
if [ "${#DISK_LINES[@]}" -eq 0 ]; then
  echo "ERROR: no disks found." >&2
  exit 1
fi
for i in "${!DISK_LINES[@]}"; do
  echo "  $((i + 1))) ${DISK_LINES[$i]}"
done
read -r -p "Select the drive to use [1-${#DISK_LINES[@]}]: " DISK_CHOICE
DISK_NAME="$(echo "${DISK_LINES[$((DISK_CHOICE - 1))]}" | awk '{print $1}')"
DEVICE="/dev/${DISK_NAME}"
echo "Using $DEVICE"

read -r -p "Mount point for this drive [$DEFAULT_MOUNT_POINT]: " MOUNT_POINT
MOUNT_POINT="${MOUNT_POINT:-$DEFAULT_MOUNT_POINT}"

# ---------------------------------------------------------------------------
# 2. Format if this drive isn't already set up, otherwise just use it
# ---------------------------------------------------------------------------
EXISTING="$(blkid -L "$LABEL" 2>/dev/null || true)"
if [ -n "$EXISTING" ] && [ "$EXISTING" != "${DEVICE}1" ]; then
  echo "Note: a different partition ($EXISTING) already has the label '$LABEL'."
fi

PARTITION="${DEVICE}1"
if ! blkid "$PARTITION" 2>/dev/null | grep -q "LABEL=\"$LABEL\""; then
  echo ""
  echo "!!! WARNING !!!"
  echo "$DEVICE does not look like it's set up for this rig yet."
  echo "Continuing will ERASE EVERYTHING on $DEVICE and create one ext4 partition."
  read -r -p "Type YES (in capitals) to confirm and continue: " CONFIRM
  if [ "$CONFIRM" != "YES" ]; then
    echo "Aborted, nothing was changed."
    exit 1
  fi
  echo "== Partitioning and formatting $DEVICE =="
  parted -s "$DEVICE" mklabel gpt mkpart primary ext4 0% 100%
  sleep 2
  mkfs.ext4 -L "$LABEL" "$PARTITION"
else
  echo "$PARTITION is already labeled '$LABEL', using it as-is."
fi

mkdir -p "$MOUNT_POINT"
if ! mountpoint -q "$MOUNT_POINT"; then
  echo "== Mounting $PARTITION at $MOUNT_POINT =="
  mount "$PARTITION" "$MOUNT_POINT"
else
  echo "Already mounted at $MOUNT_POINT"
fi

STACK_DIR="$MOUNT_POINT/stack"
mkdir -p "$STACK_DIR" "$MOUNT_POINT/models/llm" "$MOUNT_POINT/models/image" \
  "$MOUNT_POINT/workspace/output" "$MOUNT_POINT/workspace/projects"

# ---------------------------------------------------------------------------
# 3. Optional network (SMB/CIFS) share for extra storage
# ---------------------------------------------------------------------------
echo ""
read -r -p "Mount a network (SMB/CIFS) share for extra storage too? [y/N]: " WANT_SMB
SMB_MOUNT=""
if [[ "$WANT_SMB" =~ ^[Yy]$ ]]; then
  read -r -p "Server address (e.g. 192.168.1.10 or myserver.local): " SMB_HOST
  read -r -p "Share name (e.g. Media, Backups): " SMB_SHARE
  read -r -p "Username: " SMB_USER
  read -r -s -p "Password: " SMB_PASS
  echo ""
  read -r -p "Local mount point [/mnt/portableai-share]: " SMB_MOUNT
  SMB_MOUNT="${SMB_MOUNT:-/mnt/portableai-share}"

  if ! command -v mount.cifs >/dev/null 2>&1; then
    echo "Installing cifs-utils..."
    apt-get update -qq && apt-get install -y -qq cifs-utils
  fi

  CRED_DIR=/etc/portableai-credentials
  CRED_FILE="$CRED_DIR/smb-share"
  mkdir -p "$CRED_DIR"
  chmod 700 "$CRED_DIR"
  printf 'username=%s\npassword=%s\n' "$SMB_USER" "$SMB_PASS" > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  unset SMB_PASS

  mkdir -p "$SMB_MOUNT"
  FSTAB_LINE="//${SMB_HOST}/${SMB_SHARE} ${SMB_MOUNT} cifs credentials=${CRED_FILE},uid=$(id -u ${SUDO_USER:-root}),gid=$(id -g ${SUDO_USER:-root}),vers=3.0,file_mode=0644,dir_mode=0755,_netdev,nofail,x-systemd.mount-timeout=10 0 0"
  if ! grep -qF "//${SMB_HOST}/${SMB_SHARE}" /etc/fstab 2>/dev/null; then
    echo "$FSTAB_LINE" >> /etc/fstab
  fi

  echo "== Mounting network share =="
  if mount -a 2>/dev/null && mountpoint -q "$SMB_MOUNT"; then
    echo "Network share mounted at $SMB_MOUNT"
    mkdir -p "$SMB_MOUNT/comfyui-output"
  else
    echo "WARNING: network share did not mount yet. Check the server address, share name, and credentials - the heartbeat timer set up below will keep retrying automatically." >&2
  fi

  # ComfyUI always writes to the drive (see the compose file below), never
  # straight to the network share - a CIFS mount going stale mid-generation
  # can silently fail a render (SaveImage/SaveWEBM erroring on the network
  # path) even though the share was reachable when generation started. Two
  # timers instead: one moves settled files from the drive to the share
  # whenever it's actually up, the other watches the share and reconnects it
  # if it drops, alerting you if it can't after repeated tries.
  echo "== Installing output-sync timer (drive -> network share, if reachable) =="
  cat > /usr/local/bin/portableai-sync-output.sh <<EOF
#!/bin/bash
set -euo pipefail
LOCAL_OUTPUT="$MOUNT_POINT/workspace/output"
SHARE_MOUNT="$SMB_MOUNT"
SHARE_OUTPUT="\$SHARE_MOUNT/comfyui-output"
if ! mountpoint -q "\$SHARE_MOUNT" 2>/dev/null; then
  exit 0
fi
mkdir -p "\$SHARE_OUTPUT"
find "\$LOCAL_OUTPUT" -maxdepth 1 -type f -mmin +1 -print0 |
  while IFS= read -r -d '' file; do
    if mv -n "\$file" "\$SHARE_OUTPUT/" 2>/dev/null; then
      echo "moved \$(basename "\$file") -> \$SHARE_OUTPUT/"
    fi
  done
EOF
  chmod +x /usr/local/bin/portableai-sync-output.sh

  cat > /etc/systemd/system/portableai-sync.service <<'EOF'
[Unit]
Description=Move settled ComfyUI output from the drive to the network share

[Service]
Type=oneshot
ExecStart=/usr/local/bin/portableai-sync-output.sh
EOF

  cat > /etc/systemd/system/portableai-sync.timer <<'EOF'
[Unit]
Description=Run portableai-sync.service every 2 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF

  echo "== Installing network-share heartbeat timer (auto-reconnect + alert after 10 failed attempts) =="
  cat > /usr/local/bin/portableai-share-heartbeat.sh <<EOF
#!/bin/bash
set -euo pipefail
SHARE_MOUNT="$SMB_MOUNT"
STATE_DIR=/var/lib/portableai
FAIL_COUNT_FILE="\$STATE_DIR/share-fail-count"
ALERTED_FILE="\$STATE_DIR/share-alerted"
MAX_ATTEMPTS=10
mkdir -p "\$STATE_DIR"
if mountpoint -q "\$SHARE_MOUNT" 2>/dev/null; then
  rm -f "\$FAIL_COUNT_FILE" "\$ALERTED_FILE"
  exit 0
fi
mount -a 2>/dev/null || true
if mountpoint -q "\$SHARE_MOUNT" 2>/dev/null; then
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
  MSG="Portable AI rig: the network share has been unreachable for \$COUNT consecutive checks and could not be reconnected automatically. Check that the share's server is powered on and reachable on this network, and that the stored credentials are still correct ($CRED_FILE). Nothing is lost in the meantime - generated files are queued on the drive and will sync over automatically once the share comes back."
  echo "\$MSG" | wall 2>/dev/null || true
  logger -p daemon.crit -t portableai-share "\$MSG" 2>/dev/null || true
  echo "ALERT: \$MSG" >&2
fi
EOF
  chmod +x /usr/local/bin/portableai-share-heartbeat.sh

  cat > /etc/systemd/system/portableai-share-heartbeat.service <<'EOF'
[Unit]
Description=Check the network share and try to reconnect it if it dropped

[Service]
Type=oneshot
ExecStart=/usr/local/bin/portableai-share-heartbeat.sh
EOF

  cat > /etc/systemd/system/portableai-share-heartbeat.timer <<'EOF'
[Unit]
Description=Run portableai-share-heartbeat.service every 30 seconds

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now portableai-sync.timer portableai-share-heartbeat.timer >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# 4. Docker Engine + NVIDIA Container Toolkit
# ---------------------------------------------------------------------------
echo ""
echo "== Checking Docker Engine =="
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not found, installing..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  . /etc/os-release
  CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
  ARCH="$(dpkg --print-architecture)"
  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin
else
  echo "Docker already installed: $(docker --version)"
fi

echo "== Checking NVIDIA Container Toolkit =="
HAS_GPU=false
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
  HAS_GPU=true
  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    echo "nvidia-container-toolkit not found, installing..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /etc/apt/keyrings/nvidia-container-toolkit.gpg
    ARCH="$(dpkg --print-architecture)"
    echo "deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/${ARCH} /" \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -qq
    apt-get install -y -qq nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
  else
    echo "nvidia-container-toolkit already installed"
  fi
else
  echo "No NVIDIA GPU detected - continuing without GPU acceleration (image/video generation will be very slow, or you can skip installing ComfyUI's checkpoints and use chat-only)."
fi

echo "== Pointing containerd's data root at the drive (so images live there too) =="
CONTAINERD_ROOT="$MOUNT_POINT/docker/containerd"
mkdir -p "$CONTAINERD_ROOT"
if [ ! -f /etc/containerd/config.toml ] || ! grep -q "^root = \"$CONTAINERD_ROOT\"" /etc/containerd/config.toml; then
  systemctl stop docker docker.socket containerd 2>/dev/null || true
  containerd config default > /etc/containerd/config.toml
  sed -i "s#^root = .*#root = \"$CONTAINERD_ROOT\"#" /etc/containerd/config.toml
fi

echo "== Pointing Docker's own data-root at the drive =="
mkdir -p "$MOUNT_POINT/docker"
DAEMON_JSON=/etc/docker/daemon.json
python3 - "$DAEMON_JSON" "$MOUNT_POINT/docker" "$HAS_GPU" <<'PYEOF'
import json, os, sys
path, data_root, has_gpu = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
cfg = {}
if os.path.exists(path):
    with open(path) as f:
        content = f.read().strip()
        if content:
            cfg = json.loads(content)
cfg["data-root"] = data_root
if has_gpu:
    cfg.setdefault("runtimes", {}).setdefault("nvidia", {"path": "nvidia-container-runtime", "args": []})
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF

echo "== Starting Docker =="
systemctl start containerd
sleep 1
systemctl start docker.socket docker
sleep 2

if [ "$HAS_GPU" = true ]; then
  echo "== Verifying GPU passthrough =="
  if docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi > /tmp/gpu-check.log 2>&1; then
    echo "GPU OK"
  else
    echo "WARNING: GPU passthrough check failed, see /tmp/gpu-check.log" >&2
  fi
fi

# ---------------------------------------------------------------------------
# 5. Write the compose stack and support files
# ---------------------------------------------------------------------------
echo ""
echo "== Writing stack files to $STACK_DIR =="
GPU_DEPLOY_BLOCK=""
if [ "$HAS_GPU" = true ]; then
  GPU_DEPLOY_BLOCK='
    deploy:
      resources:
        reservations:
          devices: [{ driver: nvidia, count: all, capabilities: [gpu] }]'
fi

cat > "$STACK_DIR/docker-compose.yml" <<EOF
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    environment:
      - OLLAMA_MODELS=/models/llm
      - OLLAMA_KEEP_ALIVE=30m
      - OLLAMA_FLASH_ATTENTION=1
      - OLLAMA_KV_CACHE_TYPE=q8_0
    volumes:
      - $MOUNT_POINT/models/llm:/models/llm
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID$GPU_DEPLOY_BLOCK
    networks: [ai]

  comfyui:
    image: yanwk/comfyui-boot:cu124-slim
    container_name: comfyui
    restart: unless-stopped
    environment:
      - CLI_ARGS=--output-directory /ssd-output --user-directory /ssd-user
    volumes:
      - $STACK_DIR/comfyui-root:/root
      - $MOUNT_POINT/models/image:/ssd-models:ro
      - $MOUNT_POINT/workspace/output:/ssd-output
      - $MOUNT_POINT/workspace/projects:/ssd-user
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
      - DAC_OVERRIDE$GPU_DEPLOY_BLOCK
    tmpfs:
      - /tmp
    networks: [ai]

  openwebui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: openwebui
    restart: unless-stopped
    ports: ["8080:8080"]
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
      - ENABLE_IMAGE_GENERATION=true
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
    depends_on: [ollama, comfyui]
    networks: [ai]

networks:
  ai:
    driver: bridge
EOF

echo "== Bringing up the stack =="
cd "$STACK_DIR"
docker compose up -d
sleep 5

# ---------------------------------------------------------------------------
# 6. GPU-aware model sizing
#
# LLM sizing uses TOTAL VRAM summed across all GPUs (Ollama can split one
# model's layers across multiple GPUs). Image/video generation sizing uses
# the LARGEST SINGLE GPU instead (ComfyUI runs one generation on one GPU;
# it doesn't split across cards).
# ---------------------------------------------------------------------------
echo ""
echo "== Detecting GPU(s) =="
TOTAL_VRAM_MB=0
MAX_VRAM_MB=0
if command -v nvidia-smi >/dev/null 2>&1; then
  while read -r mem; do
    mem="${mem//[^0-9]/}"
    if [ -n "$mem" ]; then
      TOTAL_VRAM_MB=$((TOTAL_VRAM_MB + mem))
      if [ "$mem" -gt "$MAX_VRAM_MB" ]; then
        MAX_VRAM_MB=$mem
      fi
    fi
  done < <(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null)
fi
GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)
echo "Detected $GPU_COUNT GPU(s): total ${TOTAL_VRAM_MB}MB VRAM, largest single GPU ${MAX_VRAM_MB}MB"

echo ""
echo "Pick a chat/coder model pair to install:"
echo "  1) Standard instruction-tuned models (Qwen2.5 7B, safe defaults)"
echo "  2) Uncensored/abliterated variants (no content filter - your responsibility)"
read -r -p "Select [1/2, default 1]: " MODEL_CHOICE
MODEL_CHOICE="${MODEL_CHOICE:-1}"

if [ "$TOTAL_VRAM_MB" -ge 10000 ]; then
  TIER="medium"
  NUM_CTX=24576
  if [ "$MODEL_CHOICE" = "2" ]; then
    CHAT_MODEL="huihui_ai/qwen3-abliterated:14b-q4_K_M"
    CODER_MODEL="huihui_ai/qwen2.5-coder-abliterate:14b-instruct-q4_K_M"
  else
    CHAT_MODEL="qwen2.5:14b-instruct-q4_K_M"
    CODER_MODEL="qwen2.5-coder:14b-instruct-q4_K_M"
  fi
else
  TIER="small"
  NUM_CTX=16384
  if [ "$MODEL_CHOICE" = "2" ]; then
    CHAT_MODEL="huihui_ai/qwen2.5-abliterate:7b-instruct-q4_K_M"
    CODER_MODEL="huihui_ai/qwen2.5-coder-abliterate:7b-instruct-q4_K_M"
  else
    CHAT_MODEL="qwen2.5:7b-instruct-q4_K_M"
    CODER_MODEL="qwen2.5-coder:7b-instruct-q4_K_M"
  fi
fi

if [ "$MAX_VRAM_MB" -ge 10000 ]; then
  IMAGE_SIZE="1024x1024"
  IMAGE_STEPS=40
  VIDEO_WIDTH=768
  VIDEO_HEIGHT=480
  VIDEO_LENGTH=49
  VIDEO_STEPS=10
else
  IMAGE_SIZE="512x512"
  IMAGE_STEPS=20
  VIDEO_WIDTH=512
  VIDEO_HEIGHT=320
  VIDEO_LENGTH=33
  VIDEO_STEPS=8
fi

echo "== Pulling $CHAT_MODEL =="
docker exec ollama ollama pull "$CHAT_MODEL"
echo "== Pulling $CODER_MODEL =="
docker exec ollama ollama pull "$CODER_MODEL"

echo "== Capping context window (num_ctx=$NUM_CTX) =="
for MODEL in "$CHAT_MODEL" "$CODER_MODEL"; do
  printf 'FROM %s\nPARAMETER num_ctx %s\n' "$MODEL" "$NUM_CTX" | docker exec -i ollama sh -c "cat > /tmp/Modelfile"
  docker exec ollama ollama create "$MODEL" -f /tmp/Modelfile
done

echo "$TIER" > "$STACK_DIR/.gpu_tier"

echo ""
echo "Done. Open WebUI: http://localhost:8080"
echo "GPU tier: $TIER (chat: $CHAT_MODEL, coder: $CODER_MODEL)"
echo ""
echo "Next steps:"
echo "  - Create your admin account at http://localhost:8080 on first visit."
echo "  - Image generation (ComfyUI): download SDXL checkpoint(s) of your choice"
echo "    into $MOUNT_POINT/models/image, then configure Admin Settings -> Images."
echo "  - Customize the model system prompt: see setup_register_models.py.template"
echo "    in this folder for a starting point."
docker compose ps
