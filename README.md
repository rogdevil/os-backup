# Ubuntu Dev Machine Backup & Restore

Two scripts that capture your entire dev environment into a single encrypted file and restore it on a fresh machine with one command.

## What Gets Backed Up

- **SSH keys & config** — `~/.ssh/*` with permissions preserved
- **Dotfiles** — `.bashrc`, `.profile`, `.bash_aliases`, `.bash_logout`
- **Oh-My-Bash** — `~/.oh-my-bash/` (excluding `.git/`)
- **Config dirs** — `~/.config/{git,go,gopls,opencode,astro}`
- **APT packages** — manually installed package list (~106 pkgs)
- **APT sources** — custom repos + keyrings (e.g. Doppler)
- **NPM global packages** — package name list
- **Pip packages** — freeze file (reference only, not auto-restored)
- **Local binaries** — `~/.local/bin/` files + symlink records
- **Tool configs** — Fly.io, OpenCode config files
- **Tool versions** — exact versions of Node, Go, Docker, Claude, Fly, Temporal, Doppler, pnpm

## Prerequisites

**For backup:** `gpg`, `rsync`, `python3`

**For restore (fresh machine):** `gpg`, `curl`

## Backup

```bash
# With environment variable (non-interactive)
BACKUP_PASSPHRASE="your-secret" ./backup.sh ~/backups/

# Interactive (prompts for passphrase with confirmation)
./backup.sh ~/backups/
```

Output: `~/backups/os-backup-YYYY-MM-DD-HHMMSS.tar.gz.gpg` (~7MB)

## Restore

```bash
# From encrypted file
./restore.sh --backup os-backup-2026-02-26-132453.tar.gz.gpg --passphrase "your-secret"

# Interactive passphrase
./restore.sh --backup os-backup-2026-02-26-132453.tar.gz.gpg

# From inside an already-extracted backup directory
cd /path/to/os-backup-2026-02-26-132453/
./restore.sh
```

The restore script is also embedded inside every backup archive, so you don't need this repo on the new machine.

## Restore Order

1. **Files** (offline) — SSH keys, dotfiles, Oh-My-Bash, config dirs
2. **APT** — custom sources, keyrings, package install
3. **Dev tools** — NVM + Node.js, npm globals, pnpm, Go, Docker
4. **CLIs** — Claude, Doppler, Fly, Temporal, OpenCode
5. **Remaining** — `~/.local/bin` binaries, pip package reference

Every step is idempotent — safe to run multiple times. Already-installed tools are skipped.

## Post-Restore Checklist

1. Log out and back in (for Docker group + shell changes)
2. `ssh -T git@github.com` to verify SSH
3. `doppler login` to authenticate Doppler
4. `fly auth login` to authenticate Fly.io
5. Review pip packages if needed (logged during restore)

## Inspecting a Backup

```bash
# Decrypt and list contents
gpg -d os-backup-2026-02-26-132453.tar.gz.gpg | tar tzf -

# Extract without restoring
mkdir inspect && gpg -d os-backup-2026-02-26-132453.tar.gz.gpg | tar xzf - -C inspect/
```

## Architecture

See [arch.md](arch.md) for internal design, function maps, and how to add new backup categories.
