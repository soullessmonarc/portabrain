#!/bin/bash
# Portable AI rig - connect / bring the stack up (Linux/WSL2 side).
#
# The counterpart to eject.sh, and the thing to run after any reboot or when
# moving the drive to a machine that has already been through install.sh once.
# On Windows, run connect.ps1 instead - it attaches the physical disk to WSL2
# and then calls this.
#
# Deliberately does NOT re-run any of the installer's setup: no prompts, no
# package installs, no config rewriting, and no network access. It only finds
# the drive, mounts it, starts the daemons in the right order, and brings the
# compose stack up. Re-running install.sh for this works but re-asks every
# question and regenerates docker-compose.yml for no reason.
#
# Must be run as root.

set -euo pipefail

LABEL="PORTABLEAI"
DEFAULT_MOUNT_POINT="/mnt/portableai"
PROBE_DIR="/mnt/.portableai-probe"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo bash connect.sh" >&2
  exit 1
fi

# Re-execute inside systemd's (PID 1's) mount namespace if we aren't already in
# it. This is not defensive tidiness - it is the fix for the single worst bug
# this project has had, and it took three separate incidents to find.
#
# A `wsl.exe` session can be given its OWN mount namespace, separate from PID 1.
# Confirmed live: this script's namespace was mnt:[4026532246] while systemd sat
# in mnt:[4026532224]. Everything then goes wrong in a way that reports success
# at every step:
#
#   1. this script mounts the drive - in its own private namespace
#   2. its own data-root check verifies the mount and passes, honestly, because
#      in THIS namespace the drive really is mounted where it should be
#   3. `systemctl start docker` starts dockerd in PID 1's namespace, where
#      /mnt/<drive> is still just an empty directory on WSL2's internal disk
#   4. dockerd and containerd create their whole data-root tree there and pull
#      tens of gigabytes onto the internal VHD
#   5. nothing errors, and the drive's real contents sit untouched and ignored
#
# Observed exactly that: 19 minutes of image pulls, 34GB written to the wrong
# device, while the drive's own 30.8GB of identical images went unused. The same
# script run from a session that happened to share PID 1's namespace worked
# perfectly, which is what made it so confusing.
#
# Entering PID 1's namespace first means every mount below is made where the
# daemons will actually look for it.
if [ -r /proc/1/ns/mnt ] && [ "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ]; then
  if command -v nsenter >/dev/null 2>&1; then
    echo "== Entering systemd's mount namespace (so Docker sees the drive) =="
    exec nsenter --mount=/proc/1/ns/mnt --wd=/ -- bash "$0" "$@"
  else
    echo "ERROR: this session has a private mount namespace and nsenter is not" >&2
    echo "available, so any mount made here would be invisible to Docker - which" >&2
    echo "would silently store data on this machine's internal disk instead of the" >&2
    echo "drive. Install util-linux and re-run." >&2
    exit 1
  fi
fi

# Duplicated from install.sh on purpose: each of these scripts has to stand on
# its own, since they get run independently (and straight off the drive) rather
# than sourcing a shared library that may not be present.
#
# WSL2 appends the entire Windows PATH to the Linux PATH, so a bare
# `command -v <tool>` can be satisfied by a Windows .exe of the same name and
# wrongly report that a Linux package is installed. Anything under /mnt/ is a
# Windows binary reached over the interop bridge, not a Linux install.
have_linux_cmd() {
  local resolved
  resolved="$(command -v "$1" 2>/dev/null)" || return 1
  case "$resolved" in
    /mnt/*) return 1 ;;
    *) return 0 ;;
  esac
}

# If this script starts the daemons and then fails, they must not be left
# running. Confirmed live, and it is a genuinely nasty trap: a connect that got
# as far as starting containerd and then died on a network timeout left
# containerd alive with a self-bind-mount at the data-root path. When the VM
# later lost the drive, that bind-mount survived pointing at internal storage -
# so the NEXT connect was guaranteed to write Docker's data to the wrong disk,
# invisibly. A failed connect must leave nothing running.
STARTED_DAEMONS=0
cleanup_on_failure() {
  status=$?
  if [ "$status" -ne 0 ] && [ "$STARTED_DAEMONS" -eq 1 ]; then
    echo "" >&2
    echo "== Connect failed - stopping the daemons this script started ==" >&2
    echo "   (leaving them running would let them hold a mount at the data-root" >&2
    echo "    path and corrupt the next connect attempt)" >&2
    systemctl stop docker.socket containerd.socket docker.service containerd.service 2>/dev/null || true
    for _ in $(seq 1 10); do
      pgrep -x dockerd >/dev/null || pgrep -x containerd >/dev/null || break
      sleep 1
    done
    # Drop any mount they created under the data-root path, so it can't shadow
    # the real drive next time.
    if mountpoint -q "${DATA_ROOT:-/nonexistent}" 2>/dev/null; then
      umount "${DATA_ROOT}" 2>/dev/null || true
    fi
  fi
  exit $status
}
trap cleanup_on_failure EXIT

echo "== Looking for the rig drive =="
# Two labels are searched for, because an encrypted drive presents a different
# one from the outside: the LUKS container is labelled PORTABLEAI-LUKS and the
# ext4 filesystem inside it is labelled PORTABLEAI, invisible until unlocked.
# An unencrypted drive (any rig built before encryption was an option) has the
# ext4 label directly on the partition.
#
# Retried: a raw disk attached to WSL2 moments ago can take a few seconds to be
# probed, and blkid returning empty is the difference between "mount the drive"
# and a confusing failure further down.
PARTITION=""
CRYPT_PARTITION=""
for _ in $(seq 1 15); do
  CRYPT_PARTITION="$(blkid -L "${LABEL}-LUKS" 2>/dev/null || true)"
  PARTITION="$(blkid -L "$LABEL" 2>/dev/null || true)"
  # Written as an explicit if rather than `[ ] || [ ] && break` - that form
  # parses as "(A || B) && break" by precedence, which happens to be right
  # here, but it reads as though it might not be and shellcheck flags it.
  if [ -n "$CRYPT_PARTITION" ] || [ -n "$PARTITION" ]; then
    break
  fi
  sleep 1
done

MAPPER_NAME="portableai"
IS_ENCRYPTED=0
if [ -n "$CRYPT_PARTITION" ]; then
  IS_ENCRYPTED=1
  echo "Found encrypted rig drive at $CRYPT_PARTITION"
  if ! have_linux_cmd cryptsetup; then
    echo "== Installing cryptsetup (needed to unlock this drive) =="
    apt-get update -qq
    # cryptsetup-bin, not cryptsetup - the full package pulls in
    # initramfs-tools/dracut/plymouth (a boot splash screen) which a WSL2 distro
    # has no use for. Confirmed live: the full package installed 17 extra
    # packages here.
    apt-get install -y -qq --no-install-recommends cryptsetup-bin || {
      echo "ERROR: cryptsetup isn't available, so this drive can't be unlocked." >&2
      exit 1
    }
  fi
  modprobe dm_crypt 2>/dev/null || true
  if [ -e "/dev/mapper/$MAPPER_NAME" ]; then
    echo "Already unlocked."
  else
    # Interactive by necessity. This is the point the unattended auto-connect
    # task cannot get past on an encrypted drive - by design, since a
    # passphrase that a scheduled task could supply on its own would not be
    # protecting anything.
    if [ ! -t 0 ]; then
      echo "ERROR: this drive is encrypted and needs a passphrase, but nothing is" >&2
      echo "attached to read one from (running unattended?)." >&2
      echo "Run connect.ps1 (or this script) from a terminal you can type into." >&2
      exit 1
    fi
    UNLOCKED=0
    for try in 1 2 3; do
      read -r -s -p "Passphrase for the rig drive: " DRIVE_PASS; echo ""
      if printf '%s' "$DRIVE_PASS" | cryptsetup luksOpen --key-file - "$CRYPT_PARTITION" "$MAPPER_NAME"; then
        UNLOCKED=1; DRIVE_PASS=""; break
      fi
      DRIVE_PASS=""
      echo "  Wrong passphrase (attempt $try of 3)."
    done
    if [ "$UNLOCKED" -ne 1 ]; then
      echo "ERROR: could not unlock the drive. Nothing has been mounted or started." >&2
      exit 1
    fi
  fi
  PARTITION="/dev/mapper/$MAPPER_NAME"
  echo "Unlocked as $PARTITION"
elif [ -n "$PARTITION" ]; then
  echo "Found $PARTITION (unencrypted)"
else
  echo "ERROR: no rig drive found after 15s - looked for a LUKS container" >&2
  echo "labelled '${LABEL}-LUKS' and an ext4 filesystem labelled '$LABEL'." >&2
  echo "Is the drive attached to WSL2? On Windows, connect.ps1 does that for you." >&2
  echo "--- block devices seen from here ---" >&2
  lsblk -f >&2 || true
  exit 1
fi

# Clear any leftover mount sitting at the data-root path before touching the
# drive. This is the fingerprint of a previous run that started the daemons
# while the drive wasn't mounted: containerd bind-mounts its own root, so a
# stale entry here comes from WSL2's internal disk. Mounting the drive over the
# top would not remove it - it would just hide it, while the daemons carried on
# using the wrong storage. Checked for every mount point this rig might use,
# not just the one about to be chosen, because the stale entry is what stops
# that choice being read cleanly in the first place.
# De-duplicated: the drive's recorded mount point is usually the default one, so
# without this the same path gets checked twice and every message prints twice.
CHECKED_MPS=""
for CANDIDATE_MP in "$DEFAULT_MOUNT_POINT" "$(findmnt -n -o TARGET --source "$PARTITION" 2>/dev/null | head -1)"; do
  [ -z "$CANDIDATE_MP" ] && continue
  case " $CHECKED_MPS " in *" $CANDIDATE_MP "*) continue ;; esac
  CHECKED_MPS="$CHECKED_MPS $CANDIDATE_MP"
  STALE="$CANDIDATE_MP/docker"
  if mountpoint -q "$STALE" 2>/dev/null; then
    STALE_SRC="$(findmnt -n -o SOURCE --target "$STALE" 2>/dev/null || true)"
    # containerd bind-mounts its own root as a matter of course, so a mount here
    # is only a problem when it comes from a DIFFERENT device than the drive.
    # findmnt reports a bind-mounted subtree as "/dev/sde1[/docker]", so compare
    # only the device part. Confirmed live: without this, the drive's own
    # perfectly healthy self-bind-mount was treated as corruption and the
    # daemons were stopped and restarted on every single connect.
    STALE_DEV="${STALE_SRC%%[*}"
    if [ "$STALE_DEV" = "$PARTITION" ]; then
      echo "Data-root bind-mount present and correctly backed by $PARTITION - leaving it alone."
      continue
    fi
    echo "== Found a FOREIGN mount at $STALE (source: ${STALE_SRC:-unknown}) =="
    echo "   This is not the drive - it is what silently sends Docker's storage to"
    echo "   the wrong disk. Stopping the daemons and clearing it."
    systemctl stop docker.socket containerd.socket docker.service containerd.service 2>/dev/null || true
    for _ in $(seq 1 10); do
      pgrep -x dockerd >/dev/null || pgrep -x containerd >/dev/null || break
      sleep 1
    done
    cleared=false
    for _ in $(seq 1 10); do
      if ! mountpoint -q "$STALE" 2>/dev/null; then cleared=true; break; fi
      umount "$STALE" 2>/dev/null || sleep 1
    done
    if [ "$cleared" != true ]; then
      echo "ERROR: couldn't clear the stale mount at $STALE." >&2
      echo "Something is still holding it. Investigate with:" >&2
      echo "  findmnt --target $STALE ; fuser -vm $STALE" >&2
      exit 1
    fi
    echo "   Cleared."
  fi
done

# Where should it be mounted? The installer lets the user choose, and the
# absolute paths baked into docker-compose.yml depend on that answer - mounting
# somewhere else would produce a stack whose volumes all point at nothing. The
# choice is recorded on the drive itself, so read it from there rather than
# assuming. Chicken-and-egg is resolved with a throwaway read-only probe mount.
MOUNT_POINT=""
if ALREADY="$(findmnt -n -o TARGET --source "$PARTITION" 2>/dev/null | head -1)" && [ -n "$ALREADY" ]; then
  MOUNT_POINT="$ALREADY"
  echo "Already mounted at $MOUNT_POINT"
else
  mkdir -p "$PROBE_DIR"
  if mount -o ro "$PARTITION" "$PROBE_DIR" 2>/dev/null; then
    MOUNT_POINT="$(cat "$PROBE_DIR/stack/.mount_point" 2>/dev/null || true)"
    umount "$PROBE_DIR" || true
  fi
  rmdir "$PROBE_DIR" 2>/dev/null || true
  if [ -z "$MOUNT_POINT" ]; then
    MOUNT_POINT="$DEFAULT_MOUNT_POINT"
    echo "No recorded mount point on the drive - falling back to $MOUNT_POINT"
  else
    echo "Drive records its mount point as $MOUNT_POINT"
  fi
  mkdir -p "$MOUNT_POINT"
  echo "== Mounting $PARTITION at $MOUNT_POINT =="
  if ! mount "$PARTITION" "$MOUNT_POINT"; then
    echo "ERROR: failed to mount $PARTITION at $MOUNT_POINT." >&2
    exit 1
  fi
  # Verified, not assumed. `mount` returning 0 is not by itself proof that the
  # drive ended up where it was asked to go, and every later safety check is
  # built on this being true - so confirm the mount point really is backed by
  # this partition before going any further.
  ACTUAL_SRC="$(findmnt -n -o SOURCE --target "$MOUNT_POINT" 2>/dev/null || true)"
  if [ "$ACTUAL_SRC" != "$PARTITION" ]; then
    echo "ERROR: $MOUNT_POINT is backed by '${ACTUAL_SRC:-nothing}', not $PARTITION." >&2
    echo "Refusing to continue - starting Docker now could write to the wrong disk." >&2
    exit 1
  fi
  echo "Mount verified: $PARTITION -> $MOUNT_POINT"
fi

STACK_DIR="$MOUNT_POINT/stack"
if [ ! -f "$STACK_DIR/docker-compose.yml" ]; then
  echo "ERROR: $STACK_DIR/docker-compose.yml not found." >&2
  echo "This drive is mounted but doesn't look set up yet - run install.sh first." >&2
  exit 1
fi

# The single most damaging failure mode in this project, guarded directly rather
# than inferred. Docker's and containerd's data-root both live under the drive's
# mount point, so if the daemons ever start while the drive is NOT mounted there,
# they create the whole directory tree on WSL2's internal disk instead and
# silently store gigabytes of image data in the wrong place - invisible, because
# a later mount just shadows it. That is what corrupted this project's own
# development rig, and evidence of it has been found on a fresh install too:
# 2.6GB of containerd content blobs sitting on the internal disk at exactly this
# path. Verify the data-root really resolves onto the drive's device before
# starting anything, and refuse to continue otherwise.
DATA_ROOT="$MOUNT_POINT/docker"
if ! mountpoint -q "$MOUNT_POINT"; then
  echo "ERROR: $MOUNT_POINT is not a mount point - refusing to start Docker." >&2
  echo "Starting it now would write Docker's storage to this machine's internal disk." >&2
  exit 1
fi
MP_DEV_RAW="$(findmnt -n -o SOURCE --target "$MOUNT_POINT" 2>/dev/null || true)"
mkdir -p "$DATA_ROOT"
DR_DEV_RAW="$(findmnt -n -o SOURCE --target "$DATA_ROOT" 2>/dev/null || true)"
# Compare DEVICES, not findmnt's raw strings. containerd bind-mounts its own
# root as a matter of course, and findmnt reports a bind-mounted subtree as
# "/dev/sde1[/docker]" while the parent mount is plain "/dev/sde1" - the same
# device, but different text. Confirmed live: comparing the raw strings made
# this guard refuse to start Docker on a perfectly healthy rig, because
# containerd had done exactly what it always does. Failing safe was the right
# instinct, but a check that cries wolf on the normal case gets disabled by
# whoever hits it, so it has to be correct rather than merely cautious.
MP_DEV="${MP_DEV_RAW%%[*}"
DR_DEV="${DR_DEV_RAW%%[*}"
if [ -z "$MP_DEV" ] || [ "$MP_DEV" != "$DR_DEV" ]; then
  echo "ERROR: Docker's data-root is not on the drive - refusing to start Docker." >&2
  echo "  $MOUNT_POINT resolves to device: ${MP_DEV_RAW:-unknown}" >&2
  echo "  $DATA_ROOT resolves to device: ${DR_DEV_RAW:-unknown}" >&2
  echo "These must be the same device. If they aren't, something is mounted over" >&2
  echo "or under the data-root path, or a stale directory is shadowing it." >&2
  exit 1
fi
echo "Data-root verified on the drive ($MP_DEV)."

# Order matters, and it's the whole reason this script exists: the drive must
# be mounted BEFORE the daemons start, because their data-root lives on it.
# install.sh deliberately disables docker/containerd from starting at boot for
# this exact reason - if they come up first, containerd creates its own mount
# at the data-root path on WSL2's internal disk and Docker's storage silently
# ends up somewhere other than the drive.
echo "== Starting containerd and Docker (drive is mounted first, deliberately) =="
STARTED_DAEMONS=1
systemctl start containerd
systemctl start docker
for _ in $(seq 1 30); do
  if docker info >/dev/null 2>&1; then break; fi
  sleep 1
done
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker didn't become ready. Recent log:" >&2
  journalctl -u docker --no-pager -n 20 >&2 2>&1 || true
  exit 1
fi

# Any CIFS share configured at install time lives in this machine's /etc/fstab,
# so it only exists on machines that have been set up. Non-fatal either way:
# the rig itself doesn't depend on the share, and the heartbeat timer retries.
while IFS= read -r cifs_mp; do
  [ -z "$cifs_mp" ] && continue
  if ! mountpoint -q "$cifs_mp"; then
    echo "== Mounting network share $cifs_mp =="
    mount "$cifs_mp" 2>/dev/null || echo "warning: network share $cifs_mp didn't mount (non-fatal)." >&2
  fi
done < <(awk '$3 == "cifs" {print $2}' /etc/fstab 2>/dev/null || true)

# docker-compose.yml is generated by install.sh and lives on the drive, so a
# drive built by an older installer keeps using whatever image tags that version
# wrote - this script never regenerates it. That made the move to pinned images
# completely inert on existing drives: confirmed live, where a connect happily
# re-pulled `ollama:latest`, `open-webui:main` and the abandoned, known-broken
# `comfyui-boot:cu124-slim` because those were still the tags on the drive.
# Silently using them is the wrong default - say so instead.
if grep -qE '^\s*image:.*(:latest|:main|cu124-slim)\s*$' "$STACK_DIR/docker-compose.yml" 2>/dev/null; then
  echo ""
  echo "== NOTE: this drive's docker-compose.yml uses floating image tags =="
  grep -nE '^\s*image:' "$STACK_DIR/docker-compose.yml" | sed 's/^/     /'
  echo "  It was generated by an installer that did not pin images, so the stack"
  echo "  below may pull different (or broken) versions than the ones this release"
  echo "  was tested against - cu124-slim in particular is abandoned upstream and"
  echo "  crash-loops."
  echo "  Re-run install.sh on this drive to regenerate it with pinned tags."
  echo ""
fi

echo "== Bringing the stack up =="
docker compose -f "$STACK_DIR/docker-compose.yml" up -d

echo ""
echo "== Stack status =="
docker compose -f "$STACK_DIR/docker-compose.yml" ps

echo ""
echo "Connected. Open WebUI should be at http://localhost:8080"
if [ "$IS_ENCRYPTED" -eq 1 ]; then
  echo "This drive is encrypted - it is unlocked now and will lock again on eject."
  echo "Note: the auto-connect-at-logon task cannot unlock it, so after a reboot"
  echo "you need to run connect.ps1 yourself and enter the passphrase."
fi
if [ -f "$STACK_DIR/.gpu_tier" ]; then
  echo "GPU tier recorded on this drive: $(cat "$STACK_DIR/.gpu_tier")"
  echo "(If this machine's GPU differs, re-run install.sh to re-tier the models.)"
fi
