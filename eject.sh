#!/bin/bash
# Portable AI rig - clean eject (Linux/WSL2 side).
#
# Stops the stack and releases everything holding the drive, so it can be
# safely unplugged. On Windows, run disconnect.ps1 instead - it calls this
# script at the right points and does the final unmount and raw-disk release
# itself.
#
# Deliberately does NOT unmount the drive itself: this script's own file
# normally lives on the drive, so bash holds an open file descriptor on it
# (and therefore on the mount) for as long as this process runs - it would
# always find its own mount "busy" no matter what else was cleaned up. The
# caller does the actual `umount` as a separate command after this script has
# fully exited and released that handle.
#
# Takes an optional phase argument, because disconnect.ps1 needs to stop
# Docker Desktop *between* the two phases: if Docker Desktop's WSL integration
# is backing /var/run/docker.sock, the graceful `docker compose stop` needs it
# up - but leaving it up through the teardown lets it respawn dockerd via
# socket activation the moment `systemctl stop docker.socket` runs, which is
# exactly what stopping Docker Desktop is meant to prevent.
#   stop-stack  - graceful `docker compose stop` only
#   teardown    - stop daemons, unmount nested mounts, sync
#   all         - both, in order (default; for running this by hand)
#
# Must be run as root.

set -euo pipefail

PHASE="${1:-all}"
LABEL="PORTABLEAI"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo bash eject.sh" >&2
  exit 1
fi

# Duplicated in each of these scripts on purpose - they run independently,
# straight off the drive, so none can rely on sourcing a shared library.
# WSL2 appends the whole Windows PATH to the Linux PATH, so a bare
# `command -v <tool>` can be answered by a Windows .exe of the same name;
# anything under /mnt/ is interop, not a Linux install.
have_linux_cmd() {
  local resolved
  resolved="$(command -v "$1" 2>/dev/null)" || return 1
  case "$resolved" in
    /mnt/*) return 1 ;;
    *) return 0 ;;
  esac
}

# The mount point isn't hardcoded - it's whatever the drive is currently
# mounted at, which is the one source of truth that can't drift from reality.
# install.sh lets the user choose it, so assuming a default here would silently
# do nothing on any rig that picked something else.
PARTITION="$(blkid -L "$LABEL" 2>/dev/null || true)"
MOUNT_POINT=""
if [ -n "$PARTITION" ]; then
  MOUNT_POINT="$(findmnt -n -o TARGET --source "$PARTITION" 2>/dev/null | head -1 || true)"
fi

if [ -z "$MOUNT_POINT" ]; then
  echo "No mounted drive labelled '$LABEL' found - nothing to stop."
  echo "(If it's attached but not mounted, there's nothing holding it and it's already safe to release.)"
  exit 0
fi

STACK_DIR="$MOUNT_POINT/stack"
echo "== Drive '$LABEL' is mounted at $MOUNT_POINT =="

dump_diagnostics() {
  echo "===== DIAGNOSTICS ($1) =====" >&2
  echo "--- mounts under $MOUNT_POINT ---" >&2
  mount | grep -F "$MOUNT_POINT" >&2 || true
  echo "--- unit states ---" >&2
  systemctl is-active docker.socket docker.service containerd.service containerd.socket >&2 2>&1 || true
  echo "--- dockerd/containerd/shim processes ---" >&2
  ps aux 2>&1 | grep -iE 'dockerd|containerd|shim' | grep -v grep >&2 || true
  echo "--- fuser -vm $MOUNT_POINT ---" >&2
  fuser -vm "$MOUNT_POINT" >&2 2>&1 || true
  echo "--- lsof +D $MOUNT_POINT (first 50) ---" >&2
  lsof +D "$MOUNT_POINT" 2>&1 | head -50 >&2 || true
  echo "===== END DIAGNOSTICS =====" >&2
}

if [ "$PHASE" = "stop-stack" ] || [ "$PHASE" = "all" ]; then
  if [ -f "$STACK_DIR/docker-compose.yml" ]; then
    echo "== Stopping the stack =="
    docker compose -f "$STACK_DIR/docker-compose.yml" stop || \
      echo "warning: graceful 'docker compose stop' failed (non-fatal - containers get stopped with docker.service below instead)" >&2
  fi
fi

if [ "$PHASE" = "stop-stack" ]; then
  echo "Stack stopped."
  exit 0
fi

# Any CIFS share is released first: ComfyUI's output sync can point at it, and
# taking it out of the picture early rules it out as a reason the drive's own
# unmount later reports "busy".
while IFS= read -r cifs_mp; do
  [ -z "$cifs_mp" ] && continue
  echo "== Unmounting network share $cifs_mp =="
  umount "$cifs_mp" || echo "warning: network share unmount failed (non-fatal, unrelated to the drive)" >&2
done < <(findmnt -n -o TARGET -t cifs 2>/dev/null || true)

# The share password is stored in plaintext because mount.cifs requires it in
# that form - there is no hashed or wrapped variant it will accept. That file
# lives inside the WSL distro on THIS machine, not on the drive, so without
# this step every host the drive has ever been plugged into keeps a readable
# copy of the share credentials indefinitely, long after the drive is gone.
# Removed on eject, and install.sh/connect.sh ask again next time. The fstab
# entry goes too: it references credentials that no longer exist, and leaving a
# CIFS line behind whose credentials file is missing is what makes WSL's own
# `mount -a` at distro start report failures.
CRED_DIR=/etc/portableai-credentials
if [ -d "$CRED_DIR" ] || grep -q "credentials=$CRED_DIR" /etc/fstab 2>/dev/null; then
  echo "== Removing this machine's copy of the network-share credentials =="
  if [ -d "$CRED_DIR" ]; then
    # Overwritten before unlinking where shred exists: on ext4 a plain rm
    # leaves the plaintext recoverable in freed blocks.
    if have_linux_cmd shred; then
      find "$CRED_DIR" -type f -exec shred -u {} \; 2>/dev/null || true
    fi
    rm -rf "$CRED_DIR"
  fi
  if grep -q "credentials=$CRED_DIR" /etc/fstab 2>/dev/null; then
    cp /etc/fstab /etc/fstab.portableai-bak 2>/dev/null || true
    grep -v "credentials=$CRED_DIR" /etc/fstab > /etc/fstab.tmp && mv /etc/fstab.tmp /etc/fstab
  fi
  echo "   Removed. You'll be asked for the share details again next time."
fi

# install.sh points both Docker's and containerd's data-root at the drive, so
# the daemons themselves - not just the containers - hold it open. Stopping
# docker.service alone isn't enough: docker.socket stays active and respawns
# dockerd via socket activation the instant anything touches the socket, so the
# socket units go down too, before/with the services.
echo "== Stopping Docker/containerd (their data-root lives on the drive) =="
systemctl stop docker.socket containerd.socket docker.service containerd.service 2>/dev/null || \
  systemctl stop docker.service containerd.service 2>/dev/null || true

# Confirm the processes are actually gone before attempting the unmount - a
# respawn race here is exactly the kind of thing that silently corrupts an
# overlay2 store.
for _ in $(seq 1 10); do
  if ! pgrep -x dockerd >/dev/null && ! pgrep -x containerd >/dev/null; then
    break
  fi
  sleep 1
done
if pgrep -x dockerd >/dev/null || pgrep -x containerd >/dev/null; then
  echo "ERROR: dockerd/containerd still running after stopping their services." >&2
  dump_diagnostics "dockerd/containerd still alive"
  exit 1
fi

echo "== Syncing filesystem =="
sync

# A parent mount can never unmount while a *true* child mount still exists
# underneath it. Note that's about mount hierarchy, not pathname: a stale
# bind-mount can share a path prefix with the drive while actually being a
# *sibling* (its parent mount ID matching the drive's own parent rather than
# the drive), left over from before the drive was mounted over that path.
# Matching on path prefix produces false positives for exactly that case, so
# use /proc/self/mountinfo's parent-ID field, which only matches real children.
echo "== Checking for nested mounts under $MOUNT_POINT =="
MP_MOUNT_ID="$(awk -v mp="$MOUNT_POINT" '$5 == mp {print $1; exit}' /proc/self/mountinfo)"
NESTED=""
if [ -n "$MP_MOUNT_ID" ]; then
  NESTED="$(awk -v pid="$MP_MOUNT_ID" '$2 == pid {print $5}' /proc/self/mountinfo | sort -r)"
fi
if [ -n "$NESTED" ]; then
  while IFS= read -r nested_mp; do
    [ -z "$nested_mp" ] && continue
    echo "  unmounting nested mount $nested_mp"
    # Straight after the daemons stop this can spuriously fail with "not
    # mounted" for a moment even though mountinfo still lists it - some async
    # cleanup on containerd's side hasn't settled. Retry before calling it.
    unmounted=false
    for _ in $(seq 1 10); do
      if umount "$nested_mp" 2>/dev/null; then
        unmounted=true
        break
      fi
      sleep 1
    done
    if [ "$unmounted" != true ]; then
      echo "ERROR: failed to unmount nested mount $nested_mp after retrying" >&2
      dump_diagnostics "nested unmount of $nested_mp failed"
      exit 1
    fi
  done <<< "$NESTED"
fi

echo ""
echo "Done. Stack stopped, nothing else holding $MOUNT_POINT."
echo "The caller unmounts $MOUNT_POINT next, then releases the raw disk."
