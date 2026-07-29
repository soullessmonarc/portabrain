# Security

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
