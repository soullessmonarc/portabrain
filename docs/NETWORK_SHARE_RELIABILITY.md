# Network Share Reliability

If you opt into a network (SMB/CIFS) share during install, three independent
mechanisms keep generation decoupled from that share's availability.

## 1. Local-first output

Generated files always write to the drive first - ComfyUI's output volume, Ollama's
model store, and Open WebUI's own data all live under the drive's mount point
regardless of whether a network share is configured at all. Generation never blocks on,
or depends on, the network share being reachable.

## 2. Sync timer

A systemd timer (`portableai-sync.timer`, macOS: a launchd agent) runs every 2 minutes
and moves finished output files from the drive to the network share, but only if
`mountpoint -q` confirms the share is actually mounted at that moment. If it isn't,
files simply queue on the drive until the next run finds it reachable - nothing is
lost, nothing blocks.

## 3. Reconnect heartbeat

A second timer (`portableai-share-heartbeat.timer`, every 30 seconds) checks the share
and, if it's dropped, tries to bring it back. Two things worth knowing about how this
is implemented:

- **It targets the share's own mount point specifically** (`mount "$SHARE_MOUNT"`), not
  a blanket `mount -a`. A blanket `mount -a` would also re-mount *every other* fstab
  entry that isn't currently mounted - on a machine with other fstab entries you
  deliberately want to stay unmounted (an external drive you're in the middle of safely
  ejecting, for instance), that's a real footgun, not just an inefficiency.
- **The alert fires once per outage**, not once per check. After 10 consecutive failed
  reconnect attempts it writes an alert (journal, `wall`, `logger`, and `notify-send` on
  platforms where a desktop session is reachable), then stays quiet until the share
  either recovers or the outage crosses another 10-failure threshold after a brief
  recovery. Verified live, including a simulated 10-failed-attempt run that confirmed
  the alert fires exactly once.

## Windows-specific gap: headless alerts can't reach you

On Windows/WSL2, the heartbeat above runs inside a headless WSL2 systemd service - it
has no desktop session, so `notify-send`/GUI popups silently do nothing from there
(confirmed via live A/B testing: the identical code works fine from an attached
interactive terminal, and does nothing from the background service). Two things
compensate for this:

- Every mount point can be checked directly (`mountpoint -q <path>` / the alert marker
  file), so nothing is actually hidden - it just isn't *pushed* to you automatically
  from inside WSL2.
- `install-share-watcher.ps1` installs a genuinely separate mechanism: a **Windows**
  Scheduled Task (not WSL2-side) that polls the same alert marker every 2 minutes and
  fires a native Windows toast on a state transition (down → up or up → down), so a mid
  -session drop or recovery surfaces without needing to reconnect/re-run anything.

Native Linux and macOS don't need this extra layer - their heartbeats already run in a
normal desktop session and can reach `notify-send`/`osascript` directly.
