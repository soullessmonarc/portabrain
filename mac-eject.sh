#!/bin/bash
# Portable AI rig - clean eject (macOS side).
#
# Stops the stack gracefully so the external drive can be safely unplugged.
# Unlike eject.sh (Linux/WSL2), there's no systemd, no dockerd data-root
# living on the drive, and no raw disk to release from a VM - Docker Desktop
# runs its own Linux VM elsewhere and only bind-mounts paths on the drive into
# containers. So this only needs to: stop those containers, eject the volume
# in software, and if that fails, say what's still using it.
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
# 3. Eject
# ---------------------------------------------------------------------------
echo "== Ejecting $MOUNT_POINT =="
if diskutil eject "$MOUNT_POINT"; then
  echo ""
  echo "Done. Safe to unplug."
  exit 0
fi

echo "" >&2
echo "ERROR: diskutil couldn't eject $MOUNT_POINT." >&2
echo "== What's still using it (diagnostics) ==" >&2
lsof +D "$MOUNT_POINT" 2>/dev/null | awk 'NR==1 || $0!=""' >&2 || true
echo "Close those files/apps (or quit them) and re-run." >&2
exit 1
