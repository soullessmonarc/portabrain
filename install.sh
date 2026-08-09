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

# Re-execute inside systemd's (PID 1's) mount namespace if we aren't already in
# it. A `wsl.exe` session can be given its own private mount namespace, and a
# mount made there is INVISIBLE to systemd-managed daemons - confirmed live,
# where it caused dockerd to build its entire data-root on WSL2's internal disk
# while the real drive sat mounted and ignored in another namespace. See the
# long note in connect.sh for the full sequence.
if [ -r /proc/1/ns/mnt ] && [ "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ]; then
  if command -v nsenter >/dev/null 2>&1; then
    echo "== Entering systemd's mount namespace =="
    exec nsenter --mount=/proc/1/ns/mnt --wd=/ -- bash "$0" "$@"
  else
    echo "ERROR: private mount namespace and no nsenter available - mounts made" >&2
    echo "here would be invisible to Docker. Install util-linux and re-run." >&2
    exit 1
  fi
fi

# WSL2's nvidia-smi shim lives outside root's secure_path, so plain `sudo
# nvidia-smi` (or this script running fully as root) can't find it even
# though it works fine for an unprivileged shell. Harmless no-op on native
# Linux, where nvidia-smi already lives on the standard PATH.
export PATH="$PATH:/usr/lib/wsl/lib"

# WSL2 appends the *entire Windows PATH* to the Linux PATH by default, so a
# bare `command -v <tool>` can be satisfied by a Windows .exe of the same
# name and wrongly report that a Linux package is installed. Confirmed live:
# `command -v docker` resolved to
# "/mnt/c/Program Files/Docker/Docker/resources/bin/docker" - Docker
# Desktop's *Windows* CLI - so this script concluded Docker Engine was
# already installed inside the distro, skipped installing it entirely, and
# then died configuring a containerd that had never been installed.
#
# Anything on /mnt/ is a Windows binary reached over the interop bridge, not
# a Linux install, so it doesn't count for these checks.
have_linux_cmd() {
  local resolved
  resolved="$(command -v "$1" 2>/dev/null)" || return 1
  case "$resolved" in
    /mnt/*) return 1 ;;
    *) return 0 ;;
  esac
}

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
# 0. Make sure the tools this script needs actually exist
# ---------------------------------------------------------------------------
# A fresh WSL2 Ubuntu image is far more minimal than a normal desktop install
# and genuinely does NOT ship parted. Confirmed live on a clean Ubuntu-24.04
# distro: this script ran all the way to the destructive step, had the user
# type YES to erase the drive, and only THEN died on "parted: command not
# found" - the worst possible moment to discover a missing package. So check
# every external tool up front, before anything irreversible is even offered.
declare -A REQUIRED_PKGS=(
  [parted]=parted
  [mkfs.ext4]=e2fsprogs
  [blkid]=util-linux
  [lsblk]=util-linux
  [python3]=python3
  [curl]=curl
)
MISSING_PKGS=""
for CMD in "${!REQUIRED_PKGS[@]}"; do
  # have_linux_cmd, not plain `command -v` - Windows ships its own curl.exe
  # (and often python), which would otherwise satisfy these checks over the
  # WSL interop bridge without the Linux package actually being present.
  if ! have_linux_cmd "$CMD"; then
    MISSING_PKGS="$MISSING_PKGS ${REQUIRED_PKGS[$CMD]}"
  fi
done
if [ -n "$MISSING_PKGS" ]; then
  # Several commands can map to the same package (blkid/lsblk -> util-linux).
  MISSING_PKGS="$(printf '%s' "$MISSING_PKGS" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/^ *//; s/ *$//')"
  echo "== Installing missing prerequisites: $MISSING_PKGS =="
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "ERROR: required tools are missing and this isn't a Debian/Ubuntu system," >&2
    echo "so they can't be installed automatically: $MISSING_PKGS" >&2
    echo "Install them with your distro's package manager, then re-run this script." >&2
    exit 1
  fi
  apt-get update -qq
  # Word-splitting is intended here: $MISSING_PKGS is a space-separated package
  # list that must become separate arguments.
  # shellcheck disable=SC2086
  if ! apt-get install -y -qq $MISSING_PKGS; then
    echo "ERROR: failed to install prerequisites: $MISSING_PKGS" >&2
    echo "Check this machine's network/DNS and apt sources, then re-run." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 1. Pick a drive
# ---------------------------------------------------------------------------
echo ""
echo "== Available drives =="
# TYPE is asked for as the *second* column, not the last, and MODEL is
# reassembled from every remaining field. The previous version used
# 'NAME,SIZE,MODEL,TYPE' filtered on $4=="disk", which quietly breaks the
# moment a model name contains a space: for "sda 356.9M Virtual Disk disk"
# field 4 is "Disk", not "disk". Confirmed live - that filter only appeared
# to work because the target enclosure reported a single-word model, while
# every WSL virtual disk was excluded by accident rather than by intent. Any
# real drive reporting e.g. "Samsung Portable SSD T7" would have been
# silently missing from this list.
mapfile -t DISK_LINES < <(lsblk -d -n -o NAME,TYPE,SIZE,MODEL | awk '$2=="disk" {
  name=$1; size=$3; model="";
  for (i = 4; i <= NF; i++) model = model (i > 4 ? " " : "") $i;
  if (model == "") model = "(no model reported)";
  printf "%s\t%s\t%s\n", name, size, model
}')
if [ "${#DISK_LINES[@]}" -eq 0 ]; then
  echo "ERROR: no disks found." >&2
  exit 1
fi

# Under WSL2 the "Virtual Disk" entries are WSL's own internal VHDs, including
# the ext4 disks backing the installed distros themselves. They are never a
# valid target - formatting one would destroy a WSL distro - so they're held
# back from the numbered choices entirely rather than listed and then refused.
# Listing them made for a genuinely silly picker: eight numbered options where
# only one could be chosen. They are still *counted* out loud, because
# silently dropping disks is the bug that hid real drives from this list in
# the first place.
IS_WSL=0
if grep -qi microsoft /proc/version 2>/dev/null; then IS_WSL=1; fi

SELECTABLE=()
HIDDEN_COUNT=0
for i in "${!DISK_LINES[@]}"; do
  D_MODEL="$(printf '%s' "${DISK_LINES[$i]}" | cut -f3)"
  if [ "$IS_WSL" -eq 1 ] && [ "$D_MODEL" = "Virtual Disk" ]; then
    HIDDEN_COUNT=$((HIDDEN_COUNT + 1))
    continue
  fi
  SELECTABLE+=("${DISK_LINES[$i]}")
done

for i in "${!SELECTABLE[@]}"; do
  D_NAME="$(printf '%s' "${SELECTABLE[$i]}" | cut -f1)"
  D_SIZE="$(printf '%s' "${SELECTABLE[$i]}" | cut -f2)"
  D_MODEL="$(printf '%s' "${SELECTABLE[$i]}" | cut -f3)"
  printf "  %s) %-6s %8s  %s\n" "$((i + 1))" "$D_NAME" "$D_SIZE" "$D_MODEL"
done
if [ "$HIDDEN_COUNT" -gt 0 ]; then
  echo "  ($HIDDEN_COUNT WSL internal disk(s) hidden - they can never be used for this)"
fi

if [ "${#SELECTABLE[@]}" -eq 0 ]; then
  echo "" >&2
  echo "ERROR: no usable drives found - only WSL's own internal disks are present." >&2
  echo "Attach the external drive to WSL2 first (install-windows.ps1 does this for you)." >&2
  exit 1
fi

# Validated in a loop: the previous version fed whatever was typed straight
# into an array index, so a stray or out-of-range answer produced an empty
# device name and a confusing failure much later on, with "/dev/" as the
# target.
DEVICE=""
while [ -z "$DEVICE" ]; do
  read -r -p "Select the drive to use [1-${#SELECTABLE[@]}]: " DISK_CHOICE
  if ! printf '%s' "$DISK_CHOICE" | grep -qE '^[0-9]+$'; then
    echo "Please enter a number between 1 and ${#SELECTABLE[@]}."
    continue
  fi
  if [ "$DISK_CHOICE" -lt 1 ] || [ "$DISK_CHOICE" -gt "${#SELECTABLE[@]}" ]; then
    echo "There's no option $DISK_CHOICE - pick between 1 and ${#SELECTABLE[@]}."
    continue
  fi
  DEVICE="/dev/$(printf '%s' "${SELECTABLE[$((DISK_CHOICE - 1))]}" | cut -f1)"
done
echo "Using $DEVICE"

echo ""
echo "Where should this drive appear inside Linux? This is a local folder path"
echo "on this machine, not a network location - the equivalent of giving the"
echo "drive a letter on Windows. Press Enter for the default."
read -r -p "Local path for this drive [$DEFAULT_MOUNT_POINT]: " MOUNT_POINT
MOUNT_POINT="${MOUNT_POINT:-$DEFAULT_MOUNT_POINT}"

# ---------------------------------------------------------------------------
# 2. Format if this drive isn't already set up, otherwise just use it
# ---------------------------------------------------------------------------
# Two shapes of drive are supported, and both are detected rather than assumed:
#
#   encrypted: partition is a LUKS2 container labelled PORTABLEAI-LUKS, whose
#              inner filesystem is ext4 labelled PORTABLEAI
#   plain:     partition is ext4 labelled PORTABLEAI directly
#
# Two labels rather than one because the inner label is invisible while the
# container is locked - there has to be something findable from the outside -
# and reusing the same name for both would make `blkid -L` ambiguous the moment
# the drive is unlocked. Plain drives stay supported so rigs built before
# encryption existed keep working untouched.
PARTITION="${DEVICE}1"
MAPPER_NAME="portableai"
FS_DEVICE=""
IS_ENCRYPTED=0

PART_TYPE="$(blkid -o value -s TYPE "$PARTITION" 2>/dev/null || true)"
PART_LABEL="$(blkid -o value -s LABEL "$PARTITION" 2>/dev/null || true)"

if [ "$PART_TYPE" = "crypto_LUKS" ]; then
  echo "$PARTITION is an encrypted (LUKS) rig drive - unlocking it."
  IS_ENCRYPTED=1
  # See connect.sh for the full reasoning. Short version: an existing mapping
  # can be a broken leftover that still reports State: ACTIVE and still names an
  # existing device path, so it must be checked both for pointing at THIS
  # partition and for actually being readable (iflag=direct, since a cached read
  # succeeds against a broken mapping).
  MAPPING_IS_LIVE=0
  if [ -e "/dev/mapper/$MAPPER_NAME" ]; then
    MAPPED_BACKING="$(cryptsetup status "$MAPPER_NAME" 2>/dev/null | awk '/^[[:space:]]*device:/ {print $2}')"
    if [ -n "$MAPPED_BACKING" ] && [ "$MAPPED_BACKING" = "$PARTITION" ] \
      && dd if="/dev/mapper/$MAPPER_NAME" of=/dev/null bs=4096 count=1 iflag=direct >/dev/null 2>&1; then
      MAPPING_IS_LIVE=1
    else
      echo "Found a stale '$MAPPER_NAME' mapping (backed by '${MAPPED_BACKING:-nothing}',"
      echo "but this drive is at $PARTITION) - clearing it before unlocking."
      cryptsetup luksClose "$MAPPER_NAME" 2>/dev/null \
        || dmsetup remove -f "$MAPPER_NAME" 2>/dev/null \
        || { echo "ERROR: could not clear the stale mapping '$MAPPER_NAME'." >&2; exit 1; }
    fi
  fi
  if [ "$MAPPING_IS_LIVE" -eq 1 ]; then
    echo "Already unlocked."
  else
    UNLOCKED=0
    for try in 1 2 3; do
      read -r -s -p "Passphrase for this drive: " DRIVE_PASS; echo ""
      if printf '%s' "$DRIVE_PASS" | cryptsetup luksOpen --key-file - "$PARTITION" "$MAPPER_NAME"; then
        UNLOCKED=1; DRIVE_PASS=""; break
      fi
      DRIVE_PASS=""
      echo "  Wrong passphrase (attempt $try of 3)."
    done
    [ "$UNLOCKED" -eq 1 ] || { echo "ERROR: could not unlock $PARTITION." >&2; exit 1; }
  fi
  FS_DEVICE="/dev/mapper/$MAPPER_NAME"

elif [ "$PART_LABEL" = "$LABEL" ]; then
  echo "$PARTITION is already labeled '$LABEL' (unencrypted), using it as-is."
  FS_DEVICE="$PARTITION"

else
  echo ""
  echo "!!! WARNING !!!"
  echo "$DEVICE does not look like it's set up for this rig yet."
  echo "Continuing will ERASE EVERYTHING on $DEVICE."
  read -r -p "Type YES (in capitals) to confirm and continue: " CONFIRM
  if [ "$CONFIRM" != "YES" ]; then
    echo "Aborted, nothing was changed."
    exit 1
  fi

  echo ""
  echo "== Encrypt this drive? =="
  echo "Everything on a portable drive - every chat and prompt in Open WebUI's"
  echo "database, and every generated image - is otherwise readable by anyone who"
  echo "plugs it into any machine. Encrypting means a passphrase is required each"
  echo "time you connect it."
  echo ""
  echo "Understand before choosing:"
  echo "  - Lose the passphrase and the data is gone. There is no recovery."
  echo "  - The rig can no longer start unattended after a reboot: something has"
  echo "    to type the passphrase."
  echo "  - macOS cannot open LUKS volumes, so an encrypted drive is Linux/WSL2"
  echo "    only."
  read -r -p "Encrypt this drive? [Y/n]: " WANT_CRYPT

  echo "== Partitioning $DEVICE =="
  parted -s "$DEVICE" mklabel gpt mkpart primary 0% 100%
  sleep 2

  if [[ ! "$WANT_CRYPT" =~ ^[Nn]$ ]]; then
    if ! have_linux_cmd cryptsetup; then
      echo "== Installing cryptsetup =="
      apt-get update -qq
      # cryptsetup-bin, not cryptsetup: the full package drags in
      # initramfs-tools, dracut and plymouth - a boot splash screen, inside a
      # WSL2 distro that has no boot process to splash. cryptsetup-bin is the
      # same binary without the boot-time integration this rig never uses.
      apt-get install -y -qq --no-install-recommends cryptsetup-bin || {
        echo "ERROR: couldn't install cryptsetup - can't encrypt the drive." >&2
        echo "Re-run and answer 'n' to set the drive up unencrypted instead." >&2
        exit 1
      }
    fi
    # dm-crypt has to actually exist in this kernel. WSL2's own kernel does
    # ship it (verified: 'dmsetup targets' reports crypt v1.28.0), but a
    # custom or cut-down kernel might not, and finding that out after
    # formatting would be a bad time.
    modprobe dm_crypt 2>/dev/null || true
    if ! dmsetup targets 2>/dev/null | grep -q '^crypt'; then
      echo "ERROR: this kernel has no dm-crypt support, so LUKS can't be used here." >&2
      echo "Re-run and answer 'n' to set the drive up unencrypted instead." >&2
      exit 1
    fi

    while :; do
      read -r -s -p "Choose a passphrase for this drive: " P1; echo ""
      read -r -s -p "Repeat it: " P2; echo ""
      if [ -z "$P1" ]; then echo "  Empty passphrase - try again."; continue; fi
      if [ "$P1" != "$P2" ]; then echo "  They don't match - try again."; continue; fi
      if [ "${#P1}" -lt 8 ]; then
        read -r -p "  That's under 8 characters. Use it anyway? [y/N]: " SHORT_OK
        [[ "$SHORT_OK" =~ ^[Yy]$ ]] || continue
      fi
      break
    done

    echo "== Creating the encrypted container on $PARTITION =="
    # Passphrase piped on stdin, never as an argument - arguments are visible
    # in the process list to every user on the machine. printf without a
    # trailing newline so the key material is exactly the passphrase, matching
    # what an interactive `cryptsetup luksOpen` would produce.
    if ! printf '%s' "$P1" | cryptsetup luksFormat --type luks2 --label "${LABEL}-LUKS" --batch-mode --key-file - "$PARTITION"; then
      P1=""; P2=""
      echo "ERROR: luksFormat failed." >&2
      exit 1
    fi
    if ! printf '%s' "$P1" | cryptsetup luksOpen --key-file - "$PARTITION" "$MAPPER_NAME"; then
      P1=""; P2=""
      echo "ERROR: could not open the container just created." >&2
      exit 1
    fi
    P1=""; P2=""
    IS_ENCRYPTED=1
    FS_DEVICE="/dev/mapper/$MAPPER_NAME"
    echo "Encrypted container created and unlocked."
  else
    echo "Setting the drive up WITHOUT encryption."
    FS_DEVICE="$PARTITION"
  fi

  echo "== Creating the ext4 filesystem =="
  mkfs.ext4 -L "$LABEL" "$FS_DEVICE"
fi

mkdir -p "$MOUNT_POINT"
if ! mountpoint -q "$MOUNT_POINT"; then
  echo "== Mounting $FS_DEVICE at $MOUNT_POINT =="
  mount "$FS_DEVICE" "$MOUNT_POINT"
else
  echo "Already mounted at $MOUNT_POINT"
fi

STACK_DIR="$MOUNT_POINT/stack"
mkdir -p "$STACK_DIR" "$MOUNT_POINT/models/llm" "$MOUNT_POINT/models/image" \
  "$MOUNT_POINT/workspace/output" "$MOUNT_POINT/workspace/projects"

# Recorded on the drive so connect.sh can mount it back at the same place on
# any machine. The absolute paths baked into docker-compose.yml below depend on
# this choice, so a later connect that guessed a different default would bring
# up a stack whose volumes all pointed at empty directories.
printf '%s\n' "$MOUNT_POINT" > "$STACK_DIR/.mount_point"

# ---------------------------------------------------------------------------
# 3. Optional network (SMB/CIFS) share for extra storage
# ---------------------------------------------------------------------------
echo ""
read -r -p "Mount a network (SMB/CIFS) share for extra storage too? [y/N]: " WANT_SMB
SMB_MOUNT=""
if [[ "$WANT_SMB" =~ ^[Yy]$ ]]; then
  # Both of these are normalised, because pasting a whole UNC path into the
  # server prompt is the obvious mistake and it used to produce a silently
  # broken result. Confirmed live: entering "\\192.0.2.10\MyShare" built
  # the device string "//\\192.0.2.10\MyShare/MyShare", which not
  # only failed to mount but - once written to /etc/fstab - made WSL's own
  # `mount -a` at distro start fail every time, so entering the distro at all
  # started erroring. `nofail` does not protect against a malformed device
  # string, so the input has to be cleaned up here instead.
  normalise_smb_part() {
    local v="$1"
    v="${v//\\//}"                      # backslashes -> forward slashes
    v="${v#"${v%%[!/]*}"}"              # strip every leading slash
    printf '%s' "${v%%/*}"              # keep the first segment only
  }

  echo "Just the server itself below - no leading backslashes, no share name."
  SMB_HOST=""
  while [ -z "$SMB_HOST" ]; do
    read -r -p "Server address (e.g. 192.168.1.10 or myserver.local): " SMB_HOST_RAW
    SMB_HOST="$(normalise_smb_part "$SMB_HOST_RAW")"
    [ -z "$SMB_HOST" ] && echo "Please enter a server address."
  done

  SMB_SHARE=""
  while [ -z "$SMB_SHARE" ]; do
    read -r -p "Share name (e.g. Media, Backups): " SMB_SHARE_RAW
    SMB_SHARE="$(normalise_smb_part "$SMB_SHARE_RAW")"
    [ -z "$SMB_SHARE" ] && echo "Please enter a share name."
  done
  read -r -p "Username: " SMB_USER
  read -r -s -p "Password: " SMB_PASS
  echo ""
  read -r -p "Local mount point [/mnt/portableai-share]: " SMB_MOUNT
  SMB_MOUNT="${SMB_MOUNT:-/mnt/portableai-share}"
  echo "Will use //${SMB_HOST}/${SMB_SHARE} -> ${SMB_MOUNT}"

  if ! have_linux_cmd mount.cifs; then
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
  SMB_OPTS="credentials=${CRED_FILE},uid=$(id -u "${SUDO_USER:-root}"),gid=$(id -g "${SUDO_USER:-root}"),vers=3.0,file_mode=0644,dir_mode=0755"

  echo "== Mounting network share =="
  # Test-mounted explicitly BEFORE anything goes into /etc/fstab. A bad fstab
  # entry isn't a harmless leftover: WSL runs `mount -a` when the distro
  # starts, so an entry that can't mount makes entering the distro itself
  # report an error every time. Only a mount that has actually worked gets
  # persisted for automatic remounting; a failed one is still recorded so the
  # heartbeat timer can retry it by path, but with `noauto` so `mount -a`
  # leaves it alone and startup stays clean.
  SMB_MOUNTED=0
  if mount -t cifs "//${SMB_HOST}/${SMB_SHARE}" "$SMB_MOUNT" -o "$SMB_OPTS"; then
    mountpoint -q "$SMB_MOUNT" && SMB_MOUNTED=1
  fi

  if [ "$SMB_MOUNTED" -eq 1 ]; then
    echo "Network share mounted at $SMB_MOUNT"
    mkdir -p "$SMB_MOUNT/comfyui-output"
    FSTAB_OPTS="${SMB_OPTS},_netdev,nofail,x-systemd.mount-timeout=10"
  else
    echo "WARNING: the network share did not mount. Check the server address, share name, and credentials." >&2
    echo "         Recording it with 'noauto' so it cannot break distro startup; the heartbeat timer will keep retrying." >&2
    FSTAB_OPTS="${SMB_OPTS},_netdev,nofail,noauto,x-systemd.mount-timeout=10"
  fi

  FSTAB_LINE="//${SMB_HOST}/${SMB_SHARE} ${SMB_MOUNT} cifs ${FSTAB_OPTS} 0 0"
  if ! grep -qF "//${SMB_HOST}/${SMB_SHARE} ${SMB_MOUNT} " /etc/fstab 2>/dev/null; then
    echo "$FSTAB_LINE" >> /etc/fstab
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
# Tests for `dockerd`, not `docker`. This script needs a real Docker *Engine*
# running inside this distro (it starts docker.service and containerd itself
# further down), and dockerd is the marker for that - whereas a `docker` CLI
# can easily be present without any local engine at all, which is exactly
# what Docker Desktop's Windows CLI on the interop PATH looks like.
if ! have_linux_cmd dockerd; then
  echo "Docker Engine not found in this distro, installing..."
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
  # `|| true` because the version banner is cosmetic - a weird exit code from
  # it must never abort the install under `set -e`.
  echo "Docker Engine already installed: $(dockerd --version 2>/dev/null || echo 'version unknown')"
fi

# Installing docker-ce via apt auto-enables docker.socket/docker.service/
# containerd.service to start at boot (Debian/Ubuntu package postinst
# default) - but WSL2 boots and systemd starts *before* the disk-attach +
# mount steps above ever run, since those come from this script, invoked
# separately from Windows. That means docker/containerd start (and
# containerd creates its own "shared propagation" self-bind-mount at their
# configured data-root path) while the drive's own /docker subdirectory is
# still just a plain directory on WSL's own internal disk - the real
# drive hasn't been mounted over it yet. The result: docker's data-root
# silently ends up living on WSL2's internal storage instead of the
# drive, invisibly, every boot. Confirmed live on the non-template copy
# of this repo: this caused `docker ps -a` to come back completely empty
# after a WSL2 restart, and eventually corrupted docker's own image/
# container storage. Disabling auto-start (idempotent, self-heals a
# machine already affected) means docker/containerd only ever start via
# the explicit `systemctl start` calls below, after the drive is mounted.
echo "== Disabling docker/containerd auto-start at boot (they start explicitly, below, after the drive is mounted) =="
systemctl disable docker.socket docker.service containerd.service 2>/dev/null || true

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
# Guarded on containerd actually existing, and /etc/containerd is created
# rather than assumed. Confirmed live: with Docker Engine skipped (see the
# have_linux_cmd note above), containerd was never installed, so this step
# died on "/etc/containerd/config.toml: No such file or directory" - the
# redirect can't create a missing parent directory. The package normally
# ships that directory, so this only ever bit a machine where the Docker
# install had been skipped, but an install script shouldn't assume a
# directory it never created.
if ! have_linux_cmd containerd; then
  echo "WARNING: containerd isn't installed, so its data root can't be pointed at the drive."
  echo "         Docker images may end up on WSL2's internal disk instead of the drive."
else
  CONTAINERD_ROOT="$MOUNT_POINT/docker/containerd"
  mkdir -p "$CONTAINERD_ROOT"
  mkdir -p /etc/containerd
  if [ ! -f /etc/containerd/config.toml ] || ! grep -q "^root = \"$CONTAINERD_ROOT\"" /etc/containerd/config.toml; then
    systemctl stop docker docker.socket containerd 2>/dev/null || true
    containerd config default > /etc/containerd/config.toml
    sed -i "s#^root = .*#root = \"$CONTAINERD_ROOT\"#" /etc/containerd/config.toml
  fi
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

# A previous disconnect masks these units (--runtime) so nothing can respawn
# dockerd via socket activation while the drive is being unmounted. Normally the
# disconnect lifts the mask itself once the unmount succeeds, but an interrupted
# or failed disconnect can leave it in place - and then this start fails with a
# bare "Unit docker.service is masked", which points nowhere near the cause.
# Unmasking unconditionally here is harmless when nothing is masked.
systemctl unmask --runtime docker.socket containerd.socket docker.service containerd.service >/dev/null 2>&1 || true

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
# ---------------------------------------------------------------------------
# Pinned container images
# ---------------------------------------------------------------------------
# Every image here is pinned to an immutable tag. Previously all three floated
# on mutable tags (:latest, :main, :cu124-slim), which quietly made this
# project's central promise - "build it once, move it between machines" -
# untrue: two installs a month apart got different software, and one of them
# could be broken on arrival.
#
# That is not hypothetical. Confirmed live: yanwk/comfyui-boot:cu124-slim was
# last rebuilt 2025-10-13, its variant has since been DELETED from the upstream
# repository, and a fresh install of it crash-loops on
# "ModuleNotFoundError: No module named 'comfy_aimdo'" because its bundled
# ComfyUI needs a module its own nine-month-old site-packages don't have.
# Meanwhile an existing rig kept working purely because it had cached the image
# back when it still worked.
#
# To update: change a tag here, re-run install.sh, and test before relying on
# it. Deliberately a manual, deliberate act rather than something that happens
# to you overnight.
OLLAMA_IMAGE="ollama/ollama:0.32.5"
# cu126-slim is the maintained successor to the abandoned cu124-slim line.
COMFYUI_IMAGE="yanwk/comfyui-boot:cu126-slim-20260727"
# v0.11.0 is the exact version verified working on real hardware for this repo.
OPENWEBUI_IMAGE="ghcr.io/open-webui/open-webui:v0.11.0"

# ComfyUI does not live in its image - the image carries a bundled copy which
# its entrypoint copies to /root/ComfyUI ONLY if nothing is there yet, and
# thereafter reports "Using existing ComfyUI in user storage". Since /root is
# bind-mounted from the drive, ComfyUI persists across image changes. That is
# usually what you want (custom nodes survive), but it means changing the
# COMFYUI_IMAGE above does NOT by itself replace a broken ComfyUI: the old copy
# on the drive keeps being used, with the new image's Python packages
# underneath it. Record which image installed the current copy so a mismatch
# can be reported rather than silently producing a confusing crash loop.
COMFYUI_IMAGE_MARKER="$STACK_DIR/.comfyui_image"
if [ -f "$COMFYUI_IMAGE_MARKER" ] && [ -f "$MOUNT_POINT/stack/comfyui-root/ComfyUI/main.py" ]; then
  PREV_COMFYUI_IMAGE="$(cat "$COMFYUI_IMAGE_MARKER" 2>/dev/null || true)"
  if [ "$PREV_COMFYUI_IMAGE" != "$COMFYUI_IMAGE" ]; then
    echo ""
    echo "== NOTE: the ComfyUI image has changed =="
    echo "  was: $PREV_COMFYUI_IMAGE"
    echo "  now: $COMFYUI_IMAGE"
    echo "ComfyUI itself lives on the drive, not in the image, so the existing copy"
    echo "will keep being used against the new image's Python environment. If ComfyUI"
    echo "fails to start (a 'ModuleNotFoundError' is the usual sign), reset it with:"
    echo "  rm -rf $MOUNT_POINT/stack/comfyui-root/ComfyUI"
    echo "then re-run this script. That discards custom nodes, so it is left to you"
    echo "rather than done automatically - your models and outputs are untouched."
    echo ""
  fi
fi
printf '%s\n' "$COMFYUI_IMAGE" > "$COMFYUI_IMAGE_MARKER"

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
    image: $OLLAMA_IMAGE
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
    image: $COMFYUI_IMAGE
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
    image: $OPENWEBUI_IMAGE
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
# Same reasoning as the assistant name below: remembered on the drive, so
# moving machines and pressing Enter can't silently switch an abliterated rig
# back to the standard models (which would pull a whole second pair rather
# than reuse the weights already sitting on the drive).
STORED_MODEL_CHOICE=""
if [ -f "$STACK_DIR/.model_choice" ]; then
  STORED_MODEL_CHOICE="$(cat "$STACK_DIR/.model_choice" 2>/dev/null || true)"
fi
case "$STORED_MODEL_CHOICE" in
  1|2) ;;
  *) STORED_MODEL_CHOICE="" ;;
esac
DEFAULT_MODEL_CHOICE="${STORED_MODEL_CHOICE:-1}"
read -r -p "Select [1/2, default $DEFAULT_MODEL_CHOICE]: " MODEL_CHOICE
MODEL_CHOICE="${MODEL_CHOICE:-$DEFAULT_MODEL_CHOICE}"
printf '%s\n' "$MODEL_CHOICE" > "$STACK_DIR/.model_choice"

# Named out in full so the cleanup loop after the pulls knows every tag this
# installer is capable of choosing. Moving the drive to a machine with
# different VRAM re-tiers the rig, and without a list like this there is no
# way to tell "a model the user installed themselves" apart from "the pair
# this script pulled for the tier we've just moved away from".
SMALL_CHAT_STD="qwen2.5:7b-instruct-q4_K_M"
SMALL_CODER_STD="qwen2.5-coder:7b-instruct-q4_K_M"
SMALL_CHAT_ABL="huihui_ai/qwen2.5-abliterate:7b-instruct-q4_K_M"
SMALL_CODER_ABL="huihui_ai/qwen2.5-coder-abliterate:7b-instruct-q4_K_M"
MEDIUM_CHAT_STD="qwen2.5:14b-instruct-q4_K_M"
MEDIUM_CODER_STD="qwen2.5-coder:14b-instruct-q4_K_M"
MEDIUM_CHAT_ABL="huihui_ai/qwen3-abliterated:14b-q4_K_M"
MEDIUM_CODER_ABL="huihui_ai/qwen2.5-coder-abliterate:14b-instruct-q4_K_M"
ALL_KNOWN_MODELS="$SMALL_CHAT_STD $SMALL_CODER_STD $SMALL_CHAT_ABL $SMALL_CODER_ABL"
ALL_KNOWN_MODELS="$ALL_KNOWN_MODELS $MEDIUM_CHAT_STD $MEDIUM_CODER_STD $MEDIUM_CHAT_ABL $MEDIUM_CODER_ABL"

if [ "$TOTAL_VRAM_MB" -ge 10000 ]; then
  TIER="medium"
  NUM_CTX=24576
  if [ "$MODEL_CHOICE" = "2" ]; then
    CHAT_MODEL="$MEDIUM_CHAT_ABL"
    CODER_MODEL="$MEDIUM_CODER_ABL"
  else
    CHAT_MODEL="$MEDIUM_CHAT_STD"
    CODER_MODEL="$MEDIUM_CODER_STD"
  fi
else
  TIER="small"
  NUM_CTX=16384
  if [ "$MODEL_CHOICE" = "2" ]; then
    CHAT_MODEL="$SMALL_CHAT_ABL"
    CODER_MODEL="$SMALL_CODER_ABL"
  else
    CHAT_MODEL="$SMALL_CHAT_STD"
    CODER_MODEL="$SMALL_CODER_STD"
  fi
fi

# Image size stays at SDXL's native 1024x1024 on BOTH tiers. Dropping the
# small tier to 512 looks like the safe choice and is actually the wrong one:
# SDXL is trained at 1024, and rendering below that costs real quality
# (mangled anatomy, incoherent composition) rather than just detail. It also
# turned out not to buy anything - measured on an 8GB RTX card with a 7B chat
# model also resident, 1024x1024 SDXL completed in 25 seconds and never came
# close to exhausting VRAM, because ComfyUI unloads the LLM's neighbours as
# needed. Only the step count is reduced on the small tier, which trades a
# little refinement for speed without breaking the composition.
IMAGE_SIZE="1024x1024"
if [ "$MAX_VRAM_MB" -ge 10000 ]; then
  IMAGE_STEPS=40
  VIDEO_WIDTH=768
  VIDEO_HEIGHT=480
  VIDEO_LENGTH=49
  VIDEO_STEPS=10
else
  IMAGE_STEPS=25
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

# The image/video sizes chosen from this machine's VRAM further up are actually
# applied here. Until this step existed they were computed and silently thrown
# away - shellcheck flagged IMAGE_SIZE, IMAGE_STEPS and the four VIDEO_*
# variables as assigned-but-never-read, and it was right: the GPU tiering looked
# implemented but only ever affected which models got pulled, never the
# generation defaults. An 8GB card was left asking for 1024x1024 at 40 steps,
# which is an out-of-memory error rather than an image.
echo "== Applying image/video defaults for this GPU (max single GPU: ${MAX_VRAM_MB}MB) =="
if docker cp "$SCRIPT_DIR/setup_tune_config.py" openwebui:/app/backend/setup_tune_config.py; then
  docker exec -w /app/backend \
    -e IMAGE_SIZE="$IMAGE_SIZE" -e IMAGE_STEPS="$IMAGE_STEPS" \
    -e VIDEO_WIDTH="$VIDEO_WIDTH" -e VIDEO_HEIGHT="$VIDEO_HEIGHT" \
    -e VIDEO_LENGTH="$VIDEO_LENGTH" -e VIDEO_STEPS="$VIDEO_STEPS" \
    openwebui python3 setup_tune_config.py \
    || echo "warning: couldn't apply image/video defaults - set them by hand in Admin Settings -> Images." >&2
else
  echo "warning: setup_tune_config.py not found next to install.sh - skipping image/video defaults." >&2
fi

# Plugging the drive into a machine with different VRAM re-tiers the rig and
# pulls the pair that machine can actually run - but nothing used to remove
# the pair it moved away from, so every hop between a big and a small machine
# left another ~9-18GB of unusable weights behind on the drive, forever. Only
# tags this installer itself can choose are ever considered, so anything
# pulled by hand is left alone.
for OLD_MODEL in $ALL_KNOWN_MODELS; do
  if [ "$OLD_MODEL" != "$CHAT_MODEL" ] && [ "$OLD_MODEL" != "$CODER_MODEL" ]; then
    if docker exec ollama ollama list 2>/dev/null | grep -qF "$OLD_MODEL"; then
      echo "== Removing $OLD_MODEL (not needed for the $TIER tier on this machine) =="
      docker exec ollama ollama rm "$OLD_MODEL" || true
    fi
  fi
done

echo "$TIER" > "$STACK_DIR/.gpu_tier"

echo ""
# Defaults to the name already stored on the drive, falling back to PortaBrain
# only for a drive that has never been named. This script runs again on every
# machine the drive is plugged into, so a hardcoded default meant that pressing
# Enter on a second machine silently *renamed* an assistant that already had a
# name - the drive is meant to carry its own identity between machines, not be
# re-christened by whoever plugs it in. That ordering is the important part: the
# stored name always wins over the fallback below.
STORED_AGENT_NAME=""
if [ -f "$STACK_DIR/.agent_name" ]; then
  STORED_AGENT_NAME="$(cat "$STACK_DIR/.agent_name" 2>/dev/null || true)"
fi
DEFAULT_AGENT_NAME="${STORED_AGENT_NAME:-PortaBrain}"
read -r -p "What would you like to name your AI assistant? [$DEFAULT_AGENT_NAME]: " AGENT_NAME
AGENT_NAME="${AGENT_NAME:-$DEFAULT_AGENT_NAME}"
printf '%s\n' "$AGENT_NAME" > "$STACK_DIR/.agent_name"

# An optional system_prompt.txt lets a rig carry its own personality without
# forking setup_register_models.py - a fork would drift and quietly miss every
# later fix made there. Checked on the drive first so the prompt travels with it
# between machines, then next to these scripts.
#
# Use {AGENT_NAME} in the file wherever the assistant's name should appear.
AGENT_SYSTEM_PROMPT=""
for _promptfile in "$STACK_DIR/system_prompt.txt" "$SCRIPT_DIR/system_prompt.txt"; do
  if [ -s "$_promptfile" ]; then
    AGENT_SYSTEM_PROMPT="$(cat "$_promptfile")"
    echo "Using the custom system prompt from $_promptfile"
    # Copy onto the drive so it follows the rig to the next machine.
    if [ "$_promptfile" != "$STACK_DIR/system_prompt.txt" ]; then
      cp "$_promptfile" "$STACK_DIR/system_prompt.txt"
    fi
    break
  fi
done

echo "== Registering models in Open WebUI as '$AGENT_NAME' (system prompt + image-generation support) =="
docker cp "$SCRIPT_DIR/setup_register_models.py" openwebui:/app/backend/setup_register_models.py
docker exec -w /app/backend -e AGENT_NAME="$AGENT_NAME" -e CHAT_MODEL="$CHAT_MODEL" -e CODER_MODEL="$CODER_MODEL" \
  -e AGENT_SYSTEM_PROMPT="$AGENT_SYSTEM_PROMPT" \
  openwebui python3 setup_register_models.py

# ---------------------------------------------------------------------------
# Model weights (image + video) - fetched automatically, then wired into
# Open WebUI so "Enable Image Generation" and "Generate Video (LTX)" work
# without a manual trip to Admin Settings.
# ---------------------------------------------------------------------------
# Every URL below is a *default you can override*, not a hardcoded constant.
# Pinning a download URL into an installer is the same class of fragility as
# pinning a mutable image tag: it works right up until the host reorganises,
# and then every new install breaks with no way out except editing the script.
# Offering the default and accepting an override means a rotted URL costs the
# user one paste instead of blocking them entirely.
#
# This matters more for the two CivitAI checkpoints below than for the
# HuggingFace-hosted LTX weights: CivitAI reassigns version/file IDs far more
# often than HuggingFace moves files.
#
# Weights live on the drive, so they follow it between machines and are only
# ever downloaded once.
COMFY_MODELS="$MOUNT_POINT/stack/comfyui-root/ComfyUI/models"
LTX_CKPT_NAME="ltxv-2b-0.9.8-distilled-fp8.safetensors"
LTX_CLIP_NAME="t5xxl_fp8_e4m3fn.safetensors"
LTX_CKPT_URL_DEFAULT="https://huggingface.co/Lightricks/LTX-Video/resolve/main/${LTX_CKPT_NAME}"
LTX_CLIP_URL_DEFAULT="https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/${LTX_CLIP_NAME}"
PONY_CKPT_NAME="ponyDiffusionV6XL.safetensors"
JUGGERNAUT_CKPT_NAME="juggernautXL_v9.safetensors"
# Resolved and verified live (HTTP 206, correct filename) via civitai.com's
# direct download API - civitai.com/models/257749 and civitai.com/models/133005.
PONY_CKPT_URL_DEFAULT="https://civitai.com/api/download/models/290640?fileId=228616"
JUGGERNAUT_CKPT_URL_DEFAULT="https://civitai.com/api/download/models/348913?fileId=277777"

# Re-locates a SPECIFIC named CivitAI checkpoint version if its URL has moved
# (CivitAI can reassign version/file IDs), by querying the model's own public
# version list and matching on the exact version name. Deliberately does NOT
# fall back to "pick another version" if that exact name is gone - CivitAI's
# nsfwLevel field describes the rating of a version's PREVIEW IMAGES, not a
# guarantee the checkpoint itself is still uncensored, and a "cleaned up"
# replacement could be uploaded under policy pressure with no reliable API
# signal distinguishing it from the original. That decision is left to a
# human rather than guessed by this script.
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

# Downloads to a .part file and only moves it into place on success, so an
# interrupted or failed download can never leave a truncated file that looks
# installed and then fails cryptically at generation time.
#
# civitai_model_id/civitai_version_name are optional (blank for the plain
# HuggingFace-hosted LTX weights, which don't need this): when set, a failed
# download against the unmodified default URL triggers exactly one
# same-version relocation lookup before falling through to the manual prompt.
fetch_weight() {
  local dest_dir="$1" filename="$2" default_url="$3" label="$4"
  local civitai_model_id="${5:-}" civitai_version_name="${6:-}"
  local dest="$dest_dir/$filename"

  if [ -s "$dest" ]; then
    echo "  $label already present ($(du -h "$dest" 2>/dev/null | cut -f1)) - skipping."
    return 0
  fi

  mkdir -p "$dest_dir"
  local url="$default_url"
  local healed=0
  local attempt
  for attempt in 1 2 3; do
    echo ""
    echo "  $label"
    echo "  Default: $url"
    read -r -p "  URL (Enter to accept, or paste another; 'skip' to skip): " REPLY_URL
    case "$REPLY_URL" in
      skip|SKIP) echo "  Skipped - this file will not be present until added manually."; return 1 ;;
      "") : ;;
      *) url="$REPLY_URL" ;;
    esac

    echo "  Downloading..."
    if curl -fL --retry 3 --retry-delay 2 -o "$dest.part" "$url"; then
      if [ -s "$dest.part" ]; then
        mv "$dest.part" "$dest"
        echo "  Saved to $dest ($(du -h "$dest" 2>/dev/null | cut -f1))"
        return 0
      fi
      echo "  Download produced an empty file." >&2
    fi
    rm -f "$dest.part"
    echo "  Download failed." >&2

    if [ -n "$civitai_model_id" ] && [ "$healed" -eq 0 ] && [ "$url" = "$default_url" ]; then
      healed=1
      echo "  Checking CivitAI for this exact version under a new URL (not a substitute)..."
      local resolved
      if resolved="$(civitai_resolve_url "$civitai_model_id" "$civitai_version_name")"; then
        echo "  Found: $resolved"
        url="$resolved"
        default_url="$resolved"
      else
        echo "  '$civitai_version_name' is gone from CivitAI entirely, not just relocated - not" >&2
        echo "  guessing a substitute version. Find and paste a current URL for this SAME" >&2
        echo "  checkpoint yourself, if one still exists elsewhere." >&2
      fi
    fi
    echo "  (attempt $attempt of 3)" >&2
  done
  echo "  Giving up on $label - it will not be present until added manually." >&2
  return 1
}

echo ""
echo "== Image generation (SDXL) =="
echo "Two checkpoints are offered. Juggernaut is the general-purpose one and"
echo "becomes the default; Pony is stylised/character-focused. Either can be"
echo "skipped with 'skip' - one is enough to start."
# Juggernaut is fetched first and preferred below because it is the photoreal,
# general-purpose model. Pony V6 is strongly character/anime-biased and expects
# its own score_* tag vocabulary: given a plain scene prompt it will happily
# ignore it and render a character instead. Measured, not assumed - "the moon
# over a ruined city at night" came back from Pony as anime character art.
# Pony is still worth having for stylised character work, just not as the
# default an unfamiliar user gets first.
fetch_weight "$COMFY_MODELS/checkpoints" "$JUGGERNAUT_CKPT_NAME" "$JUGGERNAUT_CKPT_URL_DEFAULT" \
  "Juggernaut XL v9 checkpoint, photoreal (~6.6GB)" "133005" "V9 + RunDiffusionPhoto 2" || true
fetch_weight "$COMFY_MODELS/checkpoints" "$PONY_CKPT_NAME" "$PONY_CKPT_URL_DEFAULT" \
  "Pony Diffusion V6 XL checkpoint, stylised/character (~6.5GB)" "257749" "V6 (start with this one)" || true

# Readiness is decided by which file is actually on disk afterwards, NOT by
# either fetch_weight's exit status. Skipping the first checkpoint but taking
# the second is a perfectly good outcome, and an earlier version of this block
# tracked the first download's result in a flag that the second could never
# clear - so choosing "skip" on Pony and downloading Juggernaut left image
# generation unconfigured despite a usable checkpoint sitting right there.
IMAGE_CHECKPOINT=""
if [ -s "$COMFY_MODELS/checkpoints/$JUGGERNAUT_CKPT_NAME" ]; then
  IMAGE_CHECKPOINT="$JUGGERNAUT_CKPT_NAME"
elif [ -s "$COMFY_MODELS/checkpoints/$PONY_CKPT_NAME" ]; then
  IMAGE_CHECKPOINT="$PONY_CKPT_NAME"
fi

if [ -n "$IMAGE_CHECKPOINT" ]; then
  echo ""
  echo "== Wiring Open WebUI's image generation to ComfyUI =="
  docker cp "$SCRIPT_DIR/setup_image_config.py" openwebui:/app/backend/setup_image_config.py
  docker exec -w /app/backend -e CHECKPOINT_NAME="$IMAGE_CHECKPOINT" -e COMFYUI_BASE_URL="http://comfyui:8188" \
    openwebui python3 setup_image_config.py \
    || echo "warning: image generation could not be configured - see the message above." >&2
else
  echo ""
  echo "NOTE: no image checkpoint was downloaded, so 'Enable Image Generation' will"
  echo "      fail until you put one in $COMFY_MODELS/checkpoints/ and run"
  echo "      setup_image_config.py yourself (see the comment at the bottom of that"
  echo "      file for the environment variables it expects)."
fi

echo ""
echo "== Video generation (LTX) =="
echo "Two model files are needed. They are stored on the drive, so this is a"
echo "one-time download that travels with it."
VIDEO_READY=1
fetch_weight "$COMFY_MODELS/checkpoints" "$LTX_CKPT_NAME" "$LTX_CKPT_URL_DEFAULT" "LTX-Video checkpoint (~4GB)" || VIDEO_READY=0
fetch_weight "$COMFY_MODELS/clip" "$LTX_CLIP_NAME" "$LTX_CLIP_URL_DEFAULT" "T5-XXL text encoder (~5GB)" || VIDEO_READY=0

echo ""
echo "== Installing the 'Generate Video (LTX)' action in Open WebUI =="
docker cp "$SCRIPT_DIR/video_gen_action.py" openwebui:/app/backend/video_gen_action.py
docker cp "$SCRIPT_DIR/setup_video_action.py" openwebui:/app/backend/setup_video_action.py
docker exec -w /app/backend -e ACTION_SOURCE=/app/backend/video_gen_action.py \
  openwebui python3 setup_video_action.py \
  || echo "warning: the video action could not be installed - see the message above." >&2

if [ "$VIDEO_READY" -eq 0 ]; then
  echo ""
  echo "NOTE: the video action is installed but its model files are missing, so the"
  echo "      button will fail until you put them in:"
  echo "        $COMFY_MODELS/checkpoints/$LTX_CKPT_NAME"
  echo "        $COMFY_MODELS/clip/$LTX_CLIP_NAME"
fi

echo ""
echo "Done. Open WebUI: http://localhost:8080"
echo "GPU tier: $TIER (chat: $CHAT_MODEL, coder: $CODER_MODEL)"
if [ "$IS_ENCRYPTED" -eq 1 ]; then
  echo ""
  echo "*** This drive is ENCRYPTED ***"
  echo "  - The passphrase is required every time you connect it. There is no"
  echo "    recovery if you lose it: the models can be re-downloaded, but your"
  echo "    chats and generated output cannot."
  echo "  - The auto-connect-at-logon task cannot unlock it, so after a reboot you"
  echo "    need to run connect.ps1 yourself."
  echo "  - macOS cannot open LUKS volumes, so this drive is Linux/WSL2 only."
fi
echo ""
echo "Next steps:"
echo "  - Create your admin account at http://localhost:8080 on first visit."
echo "  - Customize the model system prompt further: edit setup_register_models.py"
echo "    in this folder and re-run it (see the comment at the bottom of that file"
echo "    for the environment variables it expects), or the docker exec command above."
docker compose ps
