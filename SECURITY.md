# Security

## Threat model

The realistic threat to a rig that lives on an external drive is not a remote
attacker - it is **the drive being lost, stolen, or plugged into someone else's
machine**. Everything below is aimed at that.

Worth being blunt about what is at stake, because it is more than it looks:
Open WebUI keeps every chat and prompt in a plain SQLite database at
`<drive>/stack/openwebui/webui.db`, and generated images and video sit in
`<drive>/workspace/output`. On an unencrypted drive all of it is readable by
anyone who plugs it in - no password, no account, nothing to bypass.

A password prompt in the connect script would **not** address this. Anyone can
mount the filesystem directly and never run the script at all. A passphrase is
only worth anything when it is the decryption key, which is why the option below
is real encryption rather than a gate.

## At-rest encryption (optional, offered at install)

`install.sh` offers to put the drive inside a **LUKS2 container**. If you accept:

- The passphrase is chosen at install and required every time you connect.
- The drive's partition is a LUKS2 container labelled `PORTABLEAI-LUKS`; the ext4
  filesystem inside it is labelled `PORTABLEAI` and is invisible until unlocked.
- `connect.sh` unlocks it (3 attempts), `disconnect.ps1` locks it again after
  unmounting - a LUKS container cannot be closed while its filesystem is mounted,
  so the ordering matters and is enforced.
- Passphrases are piped on stdin, never passed as command arguments, which would
  make them visible in the process list to every user on the machine.

Understand the trade-offs before choosing it:

| | Encrypted | Unencrypted |
|---|---|---|
| Drive lost or stolen | Data unreadable | Everything readable |
| Auto-connect after reboot | **Not possible** - something must type the passphrase | Works unattended |
| macOS support | **None** - macOS cannot open LUKS | Works |
| Forgotten passphrase | **Data is gone.** No recovery, no backdoor | n/a |

Models can be re-downloaded. Chats and generated output cannot. If you encrypt,
keep the passphrase somewhere you will still have it in a year.

Unencrypted drives remain fully supported, and rigs built before this option
existed keep working untouched - both shapes are detected rather than assumed.

## Credential handling

The installer optionally sets up a network (SMB/CIFS) share, which means it
handles a username and password. What actually happens to them:

- **Entry:** typed interactively (`read -s` / PowerShell `Read-Host -AsSecureString`),
  never passed as a script argument or hardcoded anywhere.
- **Storage (Linux/WSL2):** a dedicated credentials file at
  `/etc/portableai-credentials/smb-share`, `chmod 600`, owned by root, referenced from
  `/etc/fstab` via `credentials=` rather than embedding the password in the mount
  options themselves.
- **Storage (macOS):** the macOS Keychain (`security add-generic-password`), so the
  heartbeat's reconnect logic can retrieve it later without the password ever touching
  disk in plaintext.
- **No plaintext in logs:** `mount_smbfs`/`mount.cifs` error output is written to a
  freshly `mktemp`'d, `chmod 600` file rather than a predictable shared path, since some
  mount error messages can echo back the connection string.
- **Removed on eject:** `eject.sh` deletes `/etc/portableai-credentials` (via `shred`
  where available, since a plain `rm` on ext4 leaves the plaintext recoverable in freed
  blocks) and strips the matching `/etc/fstab` line. This matters because the
  credentials live inside the WSL distro on *that host*, not on the drive - so without
  this step every machine the drive has ever been plugged into would keep a readable
  copy of your share password indefinitely, long after the drive was gone. You are
  asked for the share details again on the next connect.

The password has to be stored in plaintext at all: `mount.cifs` accepts no hashed
or wrapped form. Mode 600, root-owned, and removed on eject is the best available
position, not an ideal one.

## What this installer does *not* do

- No telemetry, no phone-home. The only outbound network calls it makes are: pulling
  container images (Docker Hub), pulling LLM/checkpoint weights (Ollama's registry,
  Hugging Face/CivitAI mirrors depending on what you choose to add), and whatever
  network share you explicitly configure.
- No credentials are ever committed to this repo, embedded in `docker-compose.yml`, or
  logged in plaintext during a normal run.

## Reporting a problem

This is a private, single-maintainer repo. If you find a credential-handling or other
security issue, open an issue directly rather than a public disclosure.
