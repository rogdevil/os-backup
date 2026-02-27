#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Ubuntu Developer Machine Backup Script
# Captures dev environment into an encrypted .tar.gz.gpg file
# =============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TIMESTAMP="$(date +%Y-%m-%d-%H%M%S)"
readonly BACKUP_NAME="os-backup-${TIMESTAMP}"
readonly STAGING_DIR="$(mktemp -d "/tmp/${BACKUP_NAME}.XXXXXX")"
readonly BACKUP_DIR="${STAGING_DIR}/${BACKUP_NAME}"
readonly LOG_FILE="${STAGING_DIR}/backup.log"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Cleanup on exit
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Backup failed (exit code: $exit_code). Check log: $LOG_FILE"
        # Don't remove staging dir on failure so user can inspect
    else
        rm -rf "$STAGING_DIR"
    fi
}
trap cleanup EXIT

# Logging
log_info()    { echo -e "${GREEN}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; }
log_section() { echo -e "\n${BLUE}=== $* ===${NC}" | tee -a "$LOG_FILE"; }

# ---------------------------------------------------------------------------
# Backup functions
# ---------------------------------------------------------------------------

backup_ssh() {
    log_section "SSH Keys & Config"
    if [[ -d "$HOME/.ssh" ]]; then
        mkdir -p "$BACKUP_DIR/ssh"
        # Copy all files preserving permissions
        cp -a "$HOME/.ssh/"* "$BACKUP_DIR/ssh/" 2>/dev/null || true
        # Remove transient files
        rm -f "$BACKUP_DIR/ssh/known_hosts.old" 2>/dev/null
        local count
        count=$(ls -1 "$BACKUP_DIR/ssh/" 2>/dev/null | wc -l)
        log_info "Backed up $count SSH files"
    else
        log_warn "No ~/.ssh directory found"
    fi
}

backup_dotfiles() {
    log_section "Dotfiles"
    mkdir -p "$BACKUP_DIR/dotfiles"
    local backed=0
    for f in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_aliases" "$HOME/.bash_logout"; do
        if [[ -f "$f" ]]; then
            cp -a "$f" "$BACKUP_DIR/dotfiles/"
            log_info "Backed up $(basename "$f")"
            backed=$((backed + 1))
        fi
    done
    log_info "Backed up $backed dotfiles"
}

backup_ohmybash() {
    log_section "Oh-My-Bash"
    if [[ -d "$HOME/.oh-my-bash" ]]; then
        mkdir -p "$BACKUP_DIR/oh-my-bash"
        rsync -a --exclude='.git/' "$HOME/.oh-my-bash/" "$BACKUP_DIR/oh-my-bash/"
        local size
        size=$(du -sh "$BACKUP_DIR/oh-my-bash" | cut -f1)
        log_info "Backed up Oh-My-Bash ($size)"
    else
        log_warn "Oh-My-Bash not found at ~/.oh-my-bash"
    fi
}

backup_config() {
    log_section "Config Directories"
    mkdir -p "$BACKUP_DIR/config"
    local dirs=(git go gopls opencode astro)
    local backed=0
    for dir in "${dirs[@]}"; do
        if [[ -d "$HOME/.config/$dir" ]]; then
            cp -a "$HOME/.config/$dir" "$BACKUP_DIR/config/"
            log_info "Backed up ~/.config/$dir"
            backed=$((backed + 1))
        fi
    done
    log_info "Backed up $backed config directories"
}

backup_apt() {
    log_section "APT Packages & Sources"
    mkdir -p "$BACKUP_DIR/apt"

    # Save manually installed package list
    apt-mark showmanual | sort > "$BACKUP_DIR/apt/packages.list"
    local pkg_count
    pkg_count=$(wc -l < "$BACKUP_DIR/apt/packages.list")
    log_info "Saved $pkg_count manually installed packages"

    # Save custom APT sources (exclude default ubuntu.sources)
    if [[ -d /etc/apt/sources.list.d ]]; then
        mkdir -p "$BACKUP_DIR/apt/sources.list.d"
        local source_count=0
        for f in /etc/apt/sources.list.d/*; do
            [[ -f "$f" ]] || continue
            local basename
            basename=$(basename "$f")
            # Skip default Ubuntu sources
            if [[ "$basename" == "ubuntu.sources" ]]; then
                continue
            fi
            cp -a "$f" "$BACKUP_DIR/apt/sources.list.d/"
            log_info "Backed up APT source: $basename"
            source_count=$((source_count + 1))
        done
        log_info "Saved $source_count custom APT source files"
    fi

    # Save keyrings from /etc/apt/keyrings/
    if [[ -d /etc/apt/keyrings ]] && [[ -n "$(ls -A /etc/apt/keyrings 2>/dev/null)" ]]; then
        mkdir -p "$BACKUP_DIR/apt/keyrings"
        cp -a /etc/apt/keyrings/* "$BACKUP_DIR/apt/keyrings/"
        log_info "Backed up /etc/apt/keyrings/"
    fi

    # Save GPG keys from trusted.gpg.d/
    if [[ -d /etc/apt/trusted.gpg.d ]] && [[ -n "$(ls -A /etc/apt/trusted.gpg.d 2>/dev/null)" ]]; then
        mkdir -p "$BACKUP_DIR/apt/trusted.gpg.d"
        cp -a /etc/apt/trusted.gpg.d/* "$BACKUP_DIR/apt/trusted.gpg.d/"
        log_info "Backed up /etc/apt/trusted.gpg.d/"
    fi

    # Save legacy trusted.gpg keyring (used by repos without [signed-by=])
    if [[ -f /etc/apt/trusted.gpg ]]; then
        cp -a /etc/apt/trusted.gpg "$BACKUP_DIR/apt/trusted.gpg"
        log_info "Backed up /etc/apt/trusted.gpg"
    fi

    # Save keyrings from /usr/share/keyrings/ (non-Ubuntu ones only)
    if [[ -d /usr/share/keyrings ]]; then
        mkdir -p "$BACKUP_DIR/apt/share-keyrings"
        local kr_count=0
        for f in /usr/share/keyrings/*; do
            [[ -f "$f" ]] || continue
            local name
            name=$(basename "$f")
            # Skip Ubuntu/Debian default keyrings
            if [[ "$name" == ubuntu-* ]] || [[ "$name" == debian-* ]]; then
                continue
            fi
            cp -a "$f" "$BACKUP_DIR/apt/share-keyrings/"
            log_info "Backed up /usr/share/keyrings/$name"
            kr_count=$((kr_count + 1))
        done
        if [[ $kr_count -gt 0 ]]; then
            log_info "Saved $kr_count custom keyrings from /usr/share/keyrings/"
        fi
    fi
}

backup_pip() {
    log_section "Pip Packages"
    if command -v pip &>/dev/null; then
        pip list --format=freeze > "$BACKUP_DIR/pip-packages.txt" 2>/dev/null || true
        local count
        count=$(wc -l < "$BACKUP_DIR/pip-packages.txt")
        log_info "Saved $count pip packages (reference only, not auto-restored)"
    else
        log_warn "pip not found, skipping"
    fi
}

backup_snap() {
    log_section "Snap Packages"
    if command -v snap &>/dev/null; then
        mkdir -p "$BACKUP_DIR/snap"
        # Save list of explicitly installed snaps (skip base snaps and snapd itself)
        snap list 2>/dev/null | awk 'NR>1 && $1!="bare" && $1!="core"&& $1!="core18" && $1!="core20" && $1!="core22" && $1!="core24" && $1!="snapd" && $1!="gnome-" {print $1, $4}' \
            > "$BACKUP_DIR/snap/packages.list"
        local count
        count=$(wc -l < "$BACKUP_DIR/snap/packages.list")
        log_info "Saved $count snap packages"
    else
        log_warn "snap not found, skipping"
    fi
}

backup_brew() {
    log_section "Homebrew Packages"
    if command -v brew &>/dev/null; then
        mkdir -p "$BACKUP_DIR/brew"
        brew leaves > "$BACKUP_DIR/brew/formulae.list" 2>/dev/null || true
        brew list --cask > "$BACKUP_DIR/brew/casks.list" 2>/dev/null || true
        local formula_count cask_count
        formula_count=$(wc -l < "$BACKUP_DIR/brew/formulae.list")
        cask_count=$(wc -l < "$BACKUP_DIR/brew/casks.list")
        log_info "Saved $formula_count formulae, $cask_count casks"
    else
        log_warn "Homebrew not found, skipping"
    fi
}

backup_npm() {
    log_section "NPM Global Packages"
    if command -v npm &>/dev/null; then
        mkdir -p "$BACKUP_DIR/npm"
        # Save package names only (exclude npm itself)
        npm list -g --depth=0 --json 2>/dev/null | \
            python3 -c "
import sys, json
data = json.load(sys.stdin)
deps = data.get('dependencies', {})
for pkg in sorted(deps.keys()):
    if pkg not in ('npm', 'corepack'):
        print(pkg)
" > "$BACKUP_DIR/npm/global-packages.list" 2>/dev/null || true
        local count
        count=$(wc -l < "$BACKUP_DIR/npm/global-packages.list")
        log_info "Saved $count global npm packages"
    else
        log_warn "npm not found, skipping"
    fi
}

backup_local_bin() {
    log_section "Local Binaries (~/.local/bin)"
    if [[ -d "$HOME/.local/bin" ]]; then
        mkdir -p "$BACKUP_DIR/local-bin/files"

        # Record symlinks separately
        local symlink_count=0
        local file_count=0
        while IFS= read -r -d '' entry; do
            local name
            name=$(basename "$entry")
            if [[ -L "$entry" ]]; then
                local target
                target=$(readlink -f "$entry")
                echo "$name -> $target" >> "$BACKUP_DIR/local-bin/symlinks.txt"
                symlink_count=$((symlink_count + 1))
            elif [[ -f "$entry" ]]; then
                cp -a "$entry" "$BACKUP_DIR/local-bin/files/"
                file_count=$((file_count + 1))
            fi
        done < <(find "$HOME/.local/bin" -maxdepth 1 -not -name '.' -print0)

        log_info "Backed up $file_count files, recorded $symlink_count symlinks"
    else
        log_warn "~/.local/bin not found"
    fi
}

backup_go_bin() {
    log_section "Go Binaries (~/go/bin)"
    if [[ -d "$HOME/go/bin" ]]; then
        mkdir -p "$BACKUP_DIR/go-bin"
        local count=0
        for f in "$HOME/go/bin/"*; do
            [[ -f "$f" ]] || continue
            cp -a "$f" "$BACKUP_DIR/go-bin/"
            log_info "Backed up ~/go/bin/$(basename "$f")"
            count=$((count + 1))
        done
        log_info "Backed up $count Go binaries"
    else
        log_warn "~/go/bin not found"
    fi
}

backup_usr_local_bin() {
    log_section "System Binaries (/usr/local/bin)"
    if [[ -d /usr/local/bin ]]; then
        mkdir -p "$BACKUP_DIR/usr-local-bin/files"
        local file_count=0
        local symlink_count=0
        for entry in /usr/local/bin/*; do
            [[ -e "$entry" ]] || continue
            local name
            name=$(basename "$entry")
            if [[ -L "$entry" ]]; then
                # Record symlinks (e.g. Docker Desktop managed) but don't copy
                local target
                target=$(readlink "$entry")
                echo "$name -> $target" >> "$BACKUP_DIR/usr-local-bin/symlinks.txt"
                symlink_count=$((symlink_count + 1))
            elif [[ -f "$entry" ]]; then
                cp -a "$entry" "$BACKUP_DIR/usr-local-bin/files/"
                log_info "Backed up /usr/local/bin/$name"
                file_count=$((file_count + 1))
            fi
        done
        log_info "Backed up $file_count files, recorded $symlink_count symlinks"
    else
        log_warn "/usr/local/bin not found"
    fi
}

backup_tools() {
    log_section "Tool Configs"

    # Fly.io config
    if [[ -d "$HOME/.fly" ]]; then
        mkdir -p "$BACKUP_DIR/tools/fly"
        for f in config.yml state.yml; do
            if [[ -f "$HOME/.fly/$f" ]]; then
                cp -a "$HOME/.fly/$f" "$BACKUP_DIR/tools/fly/"
                log_info "Backed up ~/.fly/$f"
            fi
        done
    fi

    # OpenCode config
    if [[ -d "$HOME/.opencode" ]]; then
        mkdir -p "$BACKUP_DIR/tools/opencode"
        for f in package.json bun.lock; do
            if [[ -f "$HOME/.opencode/$f" ]]; then
                cp -a "$HOME/.opencode/$f" "$BACKUP_DIR/tools/opencode/"
                log_info "Backed up ~/.opencode/$f"
            fi
        done
    fi
}

backup_versions() {
    log_section "Tool Versions"
    local versions_file="$BACKUP_DIR/versions.env"

    {
        echo "# Tool versions captured on $(date -Iseconds)"
        echo "# Used by restore.sh to install matching versions"

        if command -v node &>/dev/null; then
            echo "NODE_VERSION=$(node --version | sed 's/^v//')"
        fi
        if command -v go &>/dev/null; then
            echo "GO_VERSION=$(go version | grep -oP 'go\K[0-9]+\.[0-9]+(\.[0-9]+)?')"
        fi
        if command -v docker &>/dev/null; then
            echo "DOCKER_VERSION=$(docker --version | grep -oP '[0-9]+\.[0-9]+\.[0-9]+')"
        fi
        if command -v claude &>/dev/null; then
            echo "CLAUDE_VERSION=$(claude --version 2>/dev/null | grep -oP '^[0-9]+\.[0-9]+\.[0-9]+' || echo 'latest')"
        fi
        if command -v fly &>/dev/null; then
            echo "FLY_VERSION=$(fly version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo 'latest')"
        fi
        if command -v temporal &>/dev/null; then
            echo "TEMPORAL_VERSION=$(temporal --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo 'latest')"
        fi
        if command -v doppler &>/dev/null; then
            echo "DOPPLER_VERSION=$(doppler --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' || echo 'latest')"
        fi
        if command -v pnpm &>/dev/null; then
            echo "PNPM_VERSION=$(pnpm --version 2>/dev/null || echo 'latest')"
        fi
    } > "$versions_file"

    log_info "Saved tool versions to versions.env"
}

generate_manifest() {
    log_section "Manifest"
    python3 -c "
import json, datetime, platform, os

manifest = {
    'backup_date': '$(date -Iseconds)',
    'hostname': '$(hostname)',
    'username': '$(whoami)',
    'ubuntu_version': platform.freedesktop_os_release().get('VERSION_ID', 'unknown'),
    'ubuntu_codename': platform.freedesktop_os_release().get('VERSION_CODENAME', 'unknown'),
    'backup_name': '$BACKUP_NAME',
    'contents': sorted(os.listdir('$BACKUP_DIR'))
}
print(json.dumps(manifest, indent=2))
" > "$BACKUP_DIR/manifest.json"
    log_info "Generated manifest.json"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    local output_dir="${1:-.}"

    # Resolve output directory
    output_dir="$(realpath "$output_dir")"
    if [[ ! -d "$output_dir" ]]; then
        mkdir -p "$output_dir"
    fi

    local output_file="${output_dir}/${BACKUP_NAME}.tar.gz.gpg"

    echo -e "${BLUE}"
    echo "============================================="
    echo "  Ubuntu Dev Machine Backup"
    echo "  $(date)"
    echo "============================================="
    echo -e "${NC}"

    # Get passphrase
    local passphrase="${BACKUP_PASSPHRASE:-}"
    if [[ -z "$passphrase" ]]; then
        echo -n "Enter backup passphrase: "
        read -rs passphrase
        echo
        echo -n "Confirm passphrase: "
        read -rs passphrase_confirm
        echo
        if [[ "$passphrase" != "$passphrase_confirm" ]]; then
            log_error "Passphrases do not match"
            exit 1
        fi
    fi

    if [[ -z "$passphrase" ]]; then
        log_error "Passphrase cannot be empty"
        exit 1
    fi

    mkdir -p "$BACKUP_DIR"
    log_info "Staging directory: $BACKUP_DIR"

    # Run all backup functions
    backup_ssh
    backup_dotfiles
    backup_ohmybash
    backup_config
    backup_apt
    backup_snap
    backup_brew
    backup_pip
    backup_npm
    backup_local_bin
    backup_go_bin
    backup_usr_local_bin
    backup_tools
    backup_versions

    # Generate manifest
    generate_manifest

    # Embed restore.sh
    if [[ -f "$SCRIPT_DIR/restore.sh" ]]; then
        cp "$SCRIPT_DIR/restore.sh" "$BACKUP_DIR/restore.sh"
        chmod +x "$BACKUP_DIR/restore.sh"
        log_info "Embedded restore.sh into backup"
    else
        log_warn "restore.sh not found in $SCRIPT_DIR — backup will not be self-contained"
    fi

    # Show backup size before compression
    local staging_size
    staging_size=$(du -sh "$BACKUP_DIR" | cut -f1)
    log_section "Creating Encrypted Archive"
    log_info "Staging size: $staging_size"

    # Create tarball and encrypt
    tar czf "${STAGING_DIR}/${BACKUP_NAME}.tar.gz" -C "$STAGING_DIR" "$BACKUP_NAME"

    echo "$passphrase" | gpg --batch --yes --passphrase-fd 0 \
        --symmetric --cipher-algo AES256 \
        -o "$output_file" \
        "${STAGING_DIR}/${BACKUP_NAME}.tar.gz"

    local final_size
    final_size=$(du -sh "$output_file" | cut -f1)

    echo -e "\n${GREEN}"
    echo "============================================="
    echo "  Backup Complete!"
    echo "  File: $output_file"
    echo "  Size: $final_size"
    echo "============================================="
    echo -e "${NC}"
}

main "$@"
