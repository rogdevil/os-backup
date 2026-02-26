# Architecture Reference — os-backup

## Overview

Two-script system that captures an Ubuntu dev environment into a single encrypted file and restores it on a fresh machine.

```
backup.sh  →  os-backup-YYYY-MM-DD-HHMMSS.tar.gz.gpg  →  restore.sh
```

## Files

| File | Lines | Purpose |
|---|---|---|
| `backup.sh` | ~387 | Captures everything into an encrypted `.tar.gz.gpg` |
| `restore.sh` | ~648 | Decrypts + restores everything (also embedded inside the tarball) |

## Tarball Structure

When decrypted and extracted, the archive contains:

```
os-backup-YYYY-MM-DD-HHMMSS/
├── manifest.json              # Backup metadata (date, hostname, ubuntu version, contents list)
├── restore.sh                 # Embedded copy — makes the archive self-contained
├── versions.env               # KEY=VALUE tool versions (NODE_VERSION, GO_VERSION, etc.)
├── pip-packages.txt           # pip freeze output (reference only, not auto-restored)
├── ssh/                       # ~/.ssh/* (keys, config, known_hosts)
├── dotfiles/                  # .bashrc, .profile, .bash_aliases, .bash_logout
├── oh-my-bash/                # ~/.oh-my-bash/ minus .git/
├── config/                    # ~/.config/{git,go,gopls,opencode,astro}
├── apt/
│   ├── packages.list          # apt-mark showmanual (manual installs only, ~106 pkgs)
│   ├── sources.list.d/        # Custom APT sources (e.g. doppler-cli.list)
│   ├── keyrings/              # /etc/apt/keyrings/*
│   └── trusted.gpg.d/         # /etc/apt/trusted.gpg.d/*
├── npm/
│   └── global-packages.list   # Global npm package names (excluding npm/corepack)
├── local-bin/
│   ├── files/                 # Real files from ~/.local/bin/
│   └── symlinks.txt           # "name -> target" for symlinks (logged, not auto-restored)
└── tools/
    ├── fly/                   # ~/.fly/{config.yml, state.yml}
    └── opencode/              # ~/.opencode/{package.json, bun.lock}
```

## backup.sh Internals

### Flow

```
main(output_dir)
  ├── get passphrase (BACKUP_PASSPHRASE env var or interactive prompt + confirmation)
  ├── create staging dir in /tmp/
  ├── run backup_* functions sequentially
  ├── generate_manifest()          # python3 — writes manifest.json
  ├── embed restore.sh into staging dir
  ├── tar czf staging → .tar.gz
  ├── gpg --symmetric --cipher-algo AES256 → .tar.gz.gpg
  └── cleanup (trap EXIT removes staging on success, keeps on failure)
```

### Backup Functions

Each function is independent and writes to `$BACKUP_DIR/<subdirectory>`:

| Function | Staging subdir | Source | Notes |
|---|---|---|---|
| `backup_ssh` | `ssh/` | `~/.ssh/*` | `cp -a`, removes `known_hosts.old` |
| `backup_dotfiles` | `dotfiles/` | `~/.bashrc`, `~/.profile`, `~/.bash_aliases`, `~/.bash_logout` | Only copies files that exist |
| `backup_ohmybash` | `oh-my-bash/` | `~/.oh-my-bash/` | `rsync -a --exclude='.git/'` |
| `backup_config` | `config/` | `~/.config/{git,go,gopls,opencode,astro}` | `cp -a` per dir |
| `backup_apt` | `apt/` | `apt-mark showmanual`, `/etc/apt/sources.list.d/*`, keyrings | Skips `ubuntu.sources` |
| `backup_pip` | `pip-packages.txt` | `pip list --format=freeze` | Reference only |
| `backup_npm` | `npm/` | `npm list -g --depth=0 --json` | Parsed with python3, excludes npm/corepack |
| `backup_local_bin` | `local-bin/` | `~/.local/bin/*` | Real files copied; symlinks recorded in `symlinks.txt` |
| `backup_tools` | `tools/` | `~/.fly/{config,state}.yml`, `~/.opencode/{package.json,bun.lock}` | Config files only, no binaries |
| `backup_versions` | `versions.env` | Various `--version` commands | `KEY=VALUE` format, 8 tools |

### Adding a New Backup Category

1. Create a `backup_newcategory()` function following the pattern
2. Write files to `$BACKUP_DIR/newcategory/`
3. Add the function call in `main()` between the other `backup_*` calls (line ~337-346)
4. Add the matching `restore_newcategory()` in `restore.sh`

## restore.sh Internals

### Two Invocation Modes

```bash
# Mode 1: From encrypted file (decrypts + extracts to /tmp, then restores)
./restore.sh --backup os-backup-2026-02-26.tar.gz.gpg --passphrase "secret"

# Mode 2: From inside an already-extracted backup dir (detects manifest.json in cwd)
cd /path/to/os-backup-2026-02-26/
./restore.sh
```

### Flow

```
main()
  ├── parse_args()              # --backup, --passphrase, --help
  ├── detect_backup_dir()       # Decrypt+extract OR detect manifest.json in cwd
  ├── load_versions()           # Parse versions.env into VERSIONS associative array
  │
  ├── Phase 1: Files (no network)
  │   ├── restore_ssh()         # mkdir ~/.ssh, cp files, chmod 600/644
  │   ├── restore_dotfiles()    # cp to ~/.$name
  │   ├── restore_ohmybash()    # rsync to ~/.oh-my-bash/
  │   └── restore_config()      # cp -a to ~/.config/$name
  │
  ├── Phase 2: APT
  │   ├── restore_apt_sources() # Restore keyrings + custom source lists
  │   └── restore_apt_packages()# apt-get update, then install missing packages
  │
  ├── Phase 3: Dev tools
  │   ├── install_nvm_node()    # NVM via curl script, then nvm install $version
  │   ├── install_npm_globals() # npm install -g for each package in list
  │   ├── install_pnpm()        # corepack enable + prepare, fallback npm install
  │   ├── install_go()          # Download tarball from go.dev, extract to /usr/local
  │   └── install_docker()      # get.docker.com script, usermod -aG docker
  │
  ├── Phase 4: CLIs
  │   ├── install_claude()      # npm install -g @anthropic-ai/claude-code
  │   ├── install_doppler()     # apt install or fallback cli.doppler.com/install.sh
  │   ├── install_fly()         # fly.io/install.sh
  │   ├── install_temporal()    # temporal.download/cli.sh
  │   └── install_opencode()    # opencode.ai/install
  │
  ├── Phase 5: Remaining
  │   ├── restore_local_bin()   # cp files, skip claude (npm-managed), log symlinks
  │   ├── restore_tool_configs()# Restore fly + opencode config files
  │   └── show_pip_reference()  # Log pip package count, print manual install command
  │
  └── show_summary()            # Post-restore checklist
```

### Idempotency

Every function checks before acting:

| Check pattern | Used by |
|---|---|
| `command -v tool &>/dev/null` | All `install_*` functions |
| `[[ -d "$NVM_DIR" ]]` | `install_nvm_node` |
| `[[ "$(node --version)" == "v${ver}" ]]` | `install_nvm_node` (exact version match) |
| `[[ "$current" == "$go_ver" ]]` | `install_go` (exact version match) |
| `dpkg -l "$pkg" \| grep -q "^ii"` | `restore_apt_packages` (per-package) |
| `npm list -g "$pkg" &>/dev/null` | `install_npm_globals` (per-package) |
| `[[ -f "/etc/apt/sources.list.d/$name" ]]` | `restore_apt_sources` |
| `[[ -f "$HOME/.local/bin/$name" ]]` | `restore_local_bin` |

### Version Handling

`versions.env` is loaded into a bash associative array (`declare -A VERSIONS`). The `get_version KEY DEFAULT` helper returns the stored version or a fallback.

```bash
# versions.env format:
NODE_VERSION=24.12.0
GO_VERSION=1.25.5
DOCKER_VERSION=29.1.3
CLAUDE_VERSION=2.1.59
FLY_VERSION=0.4.14
TEMPORAL_VERSION=1.5.1
DOPPLER_VERSION=3.75.2
PNPM_VERSION=10.29.2
```

## Shared Patterns

### Logging

Both scripts use identical color-coded log functions:

```bash
log_info()    # GREEN  [INFO]  — normal progress
log_warn()    # YELLOW [WARN]  — non-fatal issues
log_error()   # RED    [ERROR] — fatal errors
log_section() # BLUE   === Section Name ===
log_skip()    # CYAN   [SKIP]  — already exists (restore.sh only)
```

All output goes to both stdout and a log file via `tee -a`.

### Error Handling

- `set -euo pipefail` at the top of both scripts
- `trap cleanup EXIT` for temp dir removal
- backup.sh: keeps staging dir on failure for inspection, removes on success
- restore.sh: always removes extracted temp dir on exit

### Arithmetic Increment

Use `var=$((var + 1))` instead of `((var++))`. The latter returns exit code 1 when the variable is 0 (pre-increment evaluates to 0 = falsy), which triggers `set -e`.

## Design Decisions

| Decision | Rationale |
|---|---|
| Tool binaries excluded from tarball | Fly/Temporal/OpenCode/Claude total ~700MB; re-downloading keeps backup ~7MB |
| `apt-mark showmanual` not `dpkg --get-selections` | Captures only explicit installs (~106), not all ~886 including auto deps |
| Pip NOT auto-restored | Ubuntu 24.04 enforces PEP 668; list saved for manual reference |
| Chrome skipped | User preference |
| GPG symmetric encryption | No key pair needed, just a passphrase |
| restore.sh embedded in tarball | Archive is self-contained; can restore without the repo |
| 5-phase restore order | Files first (offline), APT second (needs network), tools after (need node/apt) |

## Common Modifications

### Add a new dotfile to backup

Edit `backup_dotfiles()` in `backup.sh` — add to the `for` loop list (line 65):

```bash
for f in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_aliases" "$HOME/.bash_logout" "$HOME/.newfile"; do
```

No restore.sh change needed — it restores all files in the `dotfiles/` directory.

### Add a new ~/.config directory

Edit `backup_config()` in `backup.sh` — add to the `dirs` array (line 91):

```bash
local dirs=(git go gopls opencode astro newdir)
```

No restore.sh change needed — it restores all directories in the `config/` directory.

### Add a new CLI tool

1. In `backup.sh` `backup_versions()` — add a version capture block (~line 243-266)
2. In `restore.sh` — add an `install_newtool()` function following the pattern
3. In `restore.sh` `main()` — add the call in the appropriate phase

### Add a new tool config

Edit `backup_tools()` in `backup.sh` and `restore_tool_configs()` in `restore.sh`.

## Usage

```bash
# Backup (on current machine)
BACKUP_PASSPHRASE="secret" ./backup.sh ~/backups/
# or interactive:
./backup.sh ~/backups/

# Restore (on fresh machine)
./restore.sh --backup os-backup-2026-02-26-132453.tar.gz.gpg --passphrase "secret"
# or interactive passphrase:
./restore.sh --backup os-backup-2026-02-26-132453.tar.gz.gpg
```
