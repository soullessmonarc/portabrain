# Code review — 2026-08-31

Focused review of `install-macos-arm.sh`, the newest and least-scrutinised script in
the repo (merged 2026-08-28 via [issue #3](https://github.com/soullessmonarc/portabrain/issues/3)'s
follow-up PR, three days before this review), plus a full-repo syntax and
consistency pass. Done as part of standardising this repo's `code-review/` folder,
which didn't exist yet even though a prior repo-wide review had already happened
(see "Prior review" below).

## Findings

### 1. SMB password containing `@`, `:`, `/`, or `;` will silently break `mount_smbfs` — not fixed

**File:** `install-macos-arm.sh`, lines 250 and 322

Both the initial mount and the heartbeat's reconnect logic build the `mount_smbfs`
target as an unencoded URL:

```sh
/sbin/mount_smbfs "//${SMB_USER}:${SMB_PASS}@${SMB_HOST}/${SMB_SHARE}" "$SHARE_MOUNT"
```

`mount_smbfs` parses this as `smb://[domain;]user[:password]@server/share` URL
syntax, where `@`, `:`, `/`, and `;` are all syntactically meaningful. A password
containing any of them — not a rare case; `@` and `/` show up in plenty of
real-world passwords — gets misparsed instead of rejected outright, so the mount
fails (or worse, connects with the wrong credentials/host) with no message pointing
at the actual cause. The heartbeat agent (line 322) rebuilds the exact same
unencoded URL from the Keychain-stored password on every retry, so this isn't a
one-time failure at setup — it's a permanent, silent inability to ever reconnect for
any affected password, indistinguishable from a genuinely offline share.

This is the same *class* of bug the repo has already found and fixed twice on the
Linux/Windows side (control characters leaking into the SMB host/share fields,
fixed 2026-07-29; the fstab-space-escaping fix documented in `SECURITY.md`) — but
it's new here: the Linux/Windows path uses `mount.cifs` with a `credentials=` file
(`install.sh` line 510, `printf 'username=%s\npassword=%s\n'`), which has no such
restriction on password characters. `mount_smbfs` has no credentials-file
equivalent for the password, so the fix has to be percent-encoding the user/password
before they go into the URL (`printf '%s' "$SMB_PASS" | jq -sRr @uri` or an
equivalent shell-only encoder, since `jq` isn't a stated dependency here).

**Not fixed in this pass.** This review is scoped to `docs/`, `README.md`, and
metadata per the batch task that produced it — application code (including this
script) was explicitly out of bounds. Flagged here, and separately, rather than
folded into a docs-only commit.

## Verified clean

- `bash -n` passes on all five `.sh` files (`connect.sh`, `eject.sh`,
  `install-macos-arm.sh`, `install.sh`, `mac-eject.sh`) — matches what CI's
  `shellcheck`/syntax job already checks, no drift found.
- The SHA256 hashes and CivitAI resolution parameters for the two SDXL checkpoints
  (`JUGGERNAUT_CKPT_SHA256`, `ANIMAGINE_CKPT_SHA256`) are byte-identical between
  `install.sh` (Linux/Windows) and `install-macos-arm.sh` — the macOS port didn't
  introduce a transcription error in a value that would otherwise fail every
  checksum silently.
- `NOTICE.md`'s software table matches what the scripts actually reference
  (`Comfy-Org/ComfyUI`, not the stale `comfyanonymous/ComfyUI` fixed in the prior
  review below) and `SECURITY.md`'s credential-handling section accurately
  describes both the Linux (`credentials=` file) and macOS (Keychain) storage
  paths as implemented.
- No `.env` file convention exists in this repo to warrant an `.env.example` — the
  four Python scripts that read `os.environ` (`setup_image_config.py` and similar)
  receive their values via `docker exec -e` from the installer itself, not from a
  user-edited file.

## Prior review

A full-repo review already happened once, on 2026-08-12 (commit `0c9612b`, "Full
repo code review: fix a quoting bug and a stale doc link"), before this
`code-review/` folder existed to record it: a broken quote-escaping sequence in
`mac-eject.sh`'s recovery message (rendered literal backslash-quotes instead of
valid shell syntax) and the stale `comfyanonymous/ComfyUI` link in `NOTICE.md`
(the project moved to `Comfy-Org/ComfyUI`) were both found and fixed. Noted here
for continuity rather than re-litigated — see the commit itself for the full
before/after.

---

<sub><img src="../docs/logo-icon.png" width="16" height="16" alt="PortaBrain icon" style="vertical-align:middle"> PortaBrain · soullessmonarcs · made with the help of AI</sub>
