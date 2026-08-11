#!/bin/bash
# Portable AI rig - clean eject (macOS side).
#
# Stops the stack gracefully so the external drive can be safely unplugged.
# Unlike eject.sh (Linux/WSL2), there's no systemd and no dockerd data-root
# living on the drive. There IS still a real VM in the way, though: Docker
# Desktop's own Virtualization.framework process holds a handle on the
# external volume independent of any specific container - confirmed on real
# hardware (issue #3): stopping or even fully removing this rig's containers
# does not release it, and `diskutil eject` fails with "Unmount was
# dissented by PID <pid> ... com.apple.Virtualization.VirtualMachine" until
# Docker Desktop itself is stopped. So this needs to: stop those containers,
# stop Docker Desktop, eject the volume in software, and if that still
# fails, say what's still using it.
#
# Run with: bash mac-eject.sh [/Volumes/YourDrive]
# The path is optional - every external volume is searched for the
# portable-ai/stack folder install-macos-arm.sh creates if it's omitted.
# No sudo needed, same as install-macos-arm.sh - nothing here touches the
# kernel directly.
#
# No mapfile/readarray: macOS ships bash 3.2 (GPLv3 avoidance), which doesn't
# have it.

set -euo pipefail

echo "===== Portable AI Rig Eject (macOS) ====="
echo ""

# ---------------------------------------------------------------------------
# 1. Find the rig
# ---------------------------------------------------------------------------
# Searched for rather than remembered, same reasoning as eject.sh on Linux:
# the drive is the one source of truth that can't drift from wherever
# install-macos-arm.sh actually put it, and this way the rig is still found
# correctly even if it's been moved here from a different Mac.
CANDIDATE="${1:-}"
MOUNT_POINT=""

if [ -n "$CANDIDATE" ]; then
  CANDIDATE="${CANDIDATE%/}"
  if [ -f "$CANDIDATE/portable-ai/stack/docker-compose.yml" ]; then
    MOUNT_POINT="$CANDIDATE"
  elif [ -f "$CANDIDATE/stack/docker-compose.yml" ]; then
    MOUNT_POINT="$(dirname "$CANDIDATE")"
  else
    echo "ERROR: no portable-ai stack found at '$CANDIDATE'." >&2
    exit 1
  fi
else
  MATCHES=()
  for v in /Volumes/*/; do
    [ -d "$v" ] || continue
    loc="$(diskutil info "$v" 2>/dev/null | awk -F': *' '/Device Location/{print $2}')"
    [ "$loc" = "External" ] || continue
    if [ -f "${v}portable-ai/stack/docker-compose.yml" ]; then
      MATCHES+=("${v%/}")
    fi
  done

  if [ "${#MATCHES[@]}" -eq 0 ]; then
    echo "No portable-ai rig found on any external drive - nothing to stop."
    echo "(If a drive is attached but not mounted, there's nothing holding it and it's already safe to unplug.)"
    exit 0
  elif [ "${#MATCHES[@]}" -eq 1 ]; then
    MOUNT_POINT="${MATCHES[0]}"
  else
    echo "Found more than one rig:"
    for i in "${!MATCHES[@]}"; do
      echo "  $((i + 1))) ${MATCHES[$i]}"
    done
    SEL=""
    while [ -z "$SEL" ]; do
      read -r -p "Which one to eject [1-${#MATCHES[@]}]: " CHOICE
      if printf '%s' "$CHOICE" | grep -qE '^[0-9]+$' && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#MATCHES[@]}" ]; then
        SEL="${MATCHES[$((CHOICE - 1))]}"
      else
        echo "Please enter a number between 1 and ${#MATCHES[@]}."
      fi
    done
    MOUNT_POINT="$SEL"
  fi
fi

STACK_DIR="$MOUNT_POINT/portable-ai/stack"
echo "== Rig found at $MOUNT_POINT =="

# ---------------------------------------------------------------------------
# 2. Stop the stack gracefully
# ---------------------------------------------------------------------------
# A user's Mac may well have other, unrelated containers running - stopping
# "whatever this compose file happens to define" isn't good enough on its
# own. The service names are read from this exact file (`config --services`,
# not a hardcoded guess) and passed to `stop` explicitly by name, so this can
# only ever touch the containers this rig's docker-compose.yml itself defines
# (ollama, openwebui) - never anything else on the machine, docker-compose or
# standalone.
if [ -f "$STACK_DIR/docker-compose.yml" ]; then
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    SERVICES=()
    while IFS= read -r s; do
      [ -n "$s" ] && SERVICES+=("$s")
    done < <(docker compose -f "$STACK_DIR/docker-compose.yml" config --services 2>/dev/null)

    if [ "${#SERVICES[@]}" -gt 0 ]; then
      echo "== Stopping this rig's containers (${SERVICES[*]}) =="
      docker compose -f "$STACK_DIR/docker-compose.yml" stop "${SERVICES[@]}" || \
        echo "warning: 'docker compose stop' failed - the eject below will fail too if containers still hold the drive open." >&2
    else
      echo "warning: couldn't read service names from $STACK_DIR/docker-compose.yml - skipping stop." >&2
    fi
  else
    echo "Docker Desktop isn't running, so nothing has containers holding the drive open."
  fi
fi

# The output-sync/network-share-heartbeat LaunchAgents (if installed) stay
# running and just no-op on their next timer tick once the drive is gone -
# they already check the share is mounted before touching it, same as when
# the SMB share itself drops. Nothing to stop here.

# ---------------------------------------------------------------------------
# 2b. Stop ComfyUI, if it's set up
# ---------------------------------------------------------------------------
# Unlike the sync/heartbeat agents above, this one actually needs stopping:
# it's a KeepAlive service (launchd restarts it if it dies) with its working
# directory and venv living on the drive itself, so it holds open file
# handles into paths on the drive - the eject below would fail with those
# still open, the same class of problem `docker compose stop` addresses for
# the containers.
COMFYUI_PLIST="$HOME/Library/LaunchAgents/com.portableai.comfyui.plist"
if [ -f "$COMFYUI_PLIST" ]; then
  echo "== Stopping ComfyUI =="
  launchctl unload "$COMFYUI_PLIST" 2>/dev/null || \
    echo "warning: couldn't unload the ComfyUI service - the eject below will fail too if it's still holding the drive open." >&2
fi

# ---------------------------------------------------------------------------
# 2c. Stop Docker Desktop itself
# ---------------------------------------------------------------------------
# Not optional, confirmed on real hardware (issue #3): Docker Desktop's own
# Virtualization.framework VM process holds a handle on the external volume
# regardless of container state - stopping (even removing) this rig's
# containers above does not release it. `docker desktop stop` is Docker's
# own graceful CLI for this (same one the Windows side already uses instead
# of force-killing the process), so this only pauses Docker Desktop rather
# than quitting the app outright, and `docker desktop start` brings it back.
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  echo "== Stopping Docker Desktop (holds a handle on the volume independent of any container) =="
  if ! docker desktop stop 2>/dev/null; then
    echo "warning: 'docker desktop stop' didn't succeed - if the eject below fails with" >&2
    echo "\"Unmount was dissented by\" a Virtualization.framework PID, quit Docker Desktop" >&2
    echo "by hand and re-run." >&2
  fi
fi

# ---------------------------------------------------------------------------
# 3. Eject
# ---------------------------------------------------------------------------
echo "== Ejecting $MOUNT_POINT =="
EJECT_ERROR="$(diskutil eject "$MOUNT_POINT" 2>&1)" && {
  echo "$EJECT_ERROR"
  echo ""
  echo "Done. Safe to unplug."
  exit 0
}

echo "" >&2
echo "ERROR: diskutil couldn't eject $MOUNT_POINT." >&2
if printf '%s' "$EJECT_ERROR" | grep -qi "Virtualization"; then
  echo "This is Docker Desktop's own VM process still holding the volume - quitting" >&2
  echo "Docker Desktop entirely (not just 'docker desktop stop') has resolved this on" >&2
  echo "real hardware when the graceful stop above wasn't enough. Quit it from the menu" >&2
  echo "bar or 'osascript -e '\''quit app \"Docker\"'\''', then re-run." >&2
else
  echo "== What's still using it (diagnostics) ==" >&2
  lsof +D "$MOUNT_POINT" 2>/dev/null | awk 'NR==1 || $0!=""' >&2 || true
  echo "Close those files/apps (or quit them) and re-run." >&2
fi
exit 1
