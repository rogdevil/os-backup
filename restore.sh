#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Ubuntu Developer Machine Restore Script
# Decrypts a backup archive and restores the full dev environment
#
# Usage:
#   ./restore.sh --backup file.tar.gz.gpg --passphrase "PASS"
#   ./restore.sh   (from inside an already-extracted backup directory)
# =============================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/tmp/os-restore-$(date +%Y%m%d-%H%M%S).log"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Logging
log_info()    { echo -e "${GREEN}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; }
log_section() { echo -e "\n${BLUE}=== $* ===${NC}" | tee -a "$LOG_FILE"; }
log_skip()    { echo -e "${CYAN}[SKIP]${NC}  $*" | tee -a "$LOG_FILE"; }

# ---------------------------------------------------------------------------
# Argument parsing & backup directory detection
# ---------------------------------------------------------------------------

BACKUP_FILE=""
PASSPHRASE=""
BACKUP_DIR=""
EXTRACT_DIR=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --backup)
                BACKUP_FILE="$2"
                shift 2
                ;;
            --passphrase)
                PASSPHRASE="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $SCRIPT_NAME [--backup FILE.tar.gz.gpg] [--passphrase PASS]"
                echo ""
                echo "Options:"
                echo "  --backup FILE      Encrypted backup file to restore from"
                echo "  --passphrase PASS  Passphrase for decryption"
                echo ""
                echo "If no --backup is given, the script looks for manifest.json in"
                echo "the current directory (assumes you're inside an extracted backup)."
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

detect_backup_dir() {
    if [[ -n "$BACKUP_FILE" ]]; then
        # Decrypt and extract
        BACKUP_FILE="$(realpath "$BACKUP_FILE")"
        if [[ ! -f "$BACKUP_FILE" ]]; then
            log_error "Backup file not found: $BACKUP_FILE"
            exit 1
        fi

        if [[ -z "$PASSPHRASE" ]]; then
            echo -n "Enter backup passphrase: "
            read -rs PASSPHRASE
            echo
        fi

        EXTRACT_DIR="$(mktemp -d /tmp/os-restore.XXXXXX)"
        log_info "Decrypting backup..."
        echo "$PASSPHRASE" | gpg --batch --yes --passphrase-fd 0 \
            -d "$BACKUP_FILE" | tar xzf - -C "$EXTRACT_DIR"

        # Find the backup directory (should be the only subdirectory)
        BACKUP_DIR="$(find "$EXTRACT_DIR" -maxdepth 1 -mindepth 1 -type d | head -1)"
        if [[ -z "$BACKUP_DIR" ]] || [[ ! -f "$BACKUP_DIR/manifest.json" ]]; then
            log_error "Invalid backup archive — manifest.json not found"
            exit 1
        fi
        log_info "Extracted to: $BACKUP_DIR"

    elif [[ -f "./manifest.json" ]]; then
        # Running from inside an extracted backup
        BACKUP_DIR="$(pwd)"
        log_info "Using current directory as backup: $BACKUP_DIR"

    else
        log_error "No backup specified and no manifest.json in current directory"
        echo "Usage: $SCRIPT_NAME --backup FILE.tar.gz.gpg --passphrase PASS"
        exit 1
    fi
}

# Cleanup extracted dir on exit if we created one
cleanup() {
    if [[ -n "$EXTRACT_DIR" ]] && [[ -d "$EXTRACT_DIR" ]]; then
        rm -rf "$EXTRACT_DIR"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Load versions.env
# ---------------------------------------------------------------------------

declare -A VERSIONS=()

load_versions() {
    local versions_file="$BACKUP_DIR/versions.env"
    if [[ -f "$versions_file" ]]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^#.*$ ]] && continue
            [[ -z "$key" ]] && continue
            VERSIONS["$key"]="$value"
        done < "$versions_file"
        log_info "Loaded tool versions from versions.env"
    else
        log_warn "versions.env not found — will install latest versions"
    fi
}

get_version() {
    local key="$1"
    local default="${2:-latest}"
    echo "${VERSIONS[$key]:-$default}"
}

# ---------------------------------------------------------------------------
# Phase 1: Restore files (no network needed)
# ---------------------------------------------------------------------------

restore_ssh() {
    log_section "SSH Keys & Config"
    if [[ -d "$BACKUP_DIR/ssh" ]]; then
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"

        local count=0
        for f in "$BACKUP_DIR/ssh/"*; do
            [[ -f "$f" ]] || continue
            local name
            name=$(basename "$f")
            cp -a "$f" "$HOME/.ssh/$name"

            # Set correct permissions
            if [[ "$name" == *.pub ]] || [[ "$name" == "known_hosts" ]] || [[ "$name" == "authorized_keys" ]]; then
                chmod 644 "$HOME/.ssh/$name"
            else
                chmod 600 "$HOME/.ssh/$name"
            fi
            count=$((count + 1))
        done
        log_info "Restored $count SSH files with correct permissions"
    else
        log_skip "No SSH backup found"
    fi
}

restore_dotfiles() {
    log_section "Dotfiles"
    if [[ -d "$BACKUP_DIR/dotfiles" ]]; then
        local count=0
        for f in "$BACKUP_DIR/dotfiles/"*; do
            [[ -f "$f" ]] || continue
            local name
            name=$(basename "$f")
            cp -a "$f" "$HOME/.$name"
            log_info "Restored ~/.$name"
            count=$((count + 1))
        done
        log_info "Restored $count dotfiles"
    else
        log_skip "No dotfiles backup found"
    fi
}

restore_ohmybash() {
    log_section "Oh-My-Bash"
    if [[ -d "$BACKUP_DIR/oh-my-bash" ]]; then
        if [[ -d "$HOME/.oh-my-bash" ]]; then
            log_skip "Oh-My-Bash already installed at ~/.oh-my-bash"
            log_info "Syncing config updates..."
        fi
        mkdir -p "$HOME/.oh-my-bash"
        rsync -a "$BACKUP_DIR/oh-my-bash/" "$HOME/.oh-my-bash/"
        log_info "Restored Oh-My-Bash"
    else
        log_skip "No Oh-My-Bash backup found"
    fi
}

restore_config() {
    log_section "Config Directories"
    if [[ -d "$BACKUP_DIR/config" ]]; then
        mkdir -p "$HOME/.config"
        local count=0
        for dir in "$BACKUP_DIR/config/"*/; do
            [[ -d "$dir" ]] || continue
            local name
            name=$(basename "$dir")
            cp -a "$dir" "$HOME/.config/$name"
            log_info "Restored ~/.config/$name"
            count=$((count + 1))
        done
        log_info "Restored $count config directories"
    else
        log_skip "No config backup found"
    fi
}

# ---------------------------------------------------------------------------
# Phase 2: APT packages
# ---------------------------------------------------------------------------

restore_apt_sources() {
    log_section "APT Sources & Keyrings"

    # Restore /etc/apt/keyrings/
    if [[ -d "$BACKUP_DIR/apt/keyrings" ]]; then
        sudo mkdir -p /etc/apt/keyrings
        sudo cp -a "$BACKUP_DIR/apt/keyrings/"* /etc/apt/keyrings/ 2>/dev/null || true
        log_info "Restored /etc/apt/keyrings/"
    fi

    # Restore /etc/apt/trusted.gpg.d/
    if [[ -d "$BACKUP_DIR/apt/trusted.gpg.d" ]]; then
        sudo cp -a "$BACKUP_DIR/apt/trusted.gpg.d/"* /etc/apt/trusted.gpg.d/ 2>/dev/null || true
        log_info "Restored /etc/apt/trusted.gpg.d/"
    fi

    # Restore legacy /etc/apt/trusted.gpg
    if [[ -f "$BACKUP_DIR/apt/trusted.gpg" ]]; then
        sudo cp -a "$BACKUP_DIR/apt/trusted.gpg" /etc/apt/trusted.gpg
        log_info "Restored /etc/apt/trusted.gpg"
    fi

    # Restore /usr/share/keyrings/ (custom keyrings like doppler-archive-keyring.gpg)
    if [[ -d "$BACKUP_DIR/apt/share-keyrings" ]]; then
        sudo mkdir -p /usr/share/keyrings
        sudo cp -a "$BACKUP_DIR/apt/share-keyrings/"* /usr/share/keyrings/ 2>/dev/null || true
        log_info "Restored custom keyrings to /usr/share/keyrings/"
    fi

    # Restore custom source lists
    if [[ -d "$BACKUP_DIR/apt/sources.list.d" ]]; then
        local count=0
        for f in "$BACKUP_DIR/apt/sources.list.d/"*; do
            [[ -f "$f" ]] || continue
            local name
            name=$(basename "$f")
            if [[ -f "/etc/apt/sources.list.d/$name" ]]; then
                log_skip "APT source already exists: $name"
            else
                sudo cp -a "$f" "/etc/apt/sources.list.d/$name"
                log_info "Restored APT source: $name"
            fi
            count=$((count + 1))
        done
    fi
}

restore_apt_packages() {
    log_section "APT Packages"
    if [[ ! -f "$BACKUP_DIR/apt/packages.list" ]]; then
        log_skip "No APT package list found"
        return
    fi

    log_info "Updating APT package index..."
    sudo apt-get update -qq

    # Filter out already-installed packages
    local to_install=()
    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            to_install+=("$pkg")
        fi
    done < "$BACKUP_DIR/apt/packages.list"

    if [[ ${#to_install[@]} -eq 0 ]]; then
        log_skip "All APT packages already installed"
        return
    fi

    log_info "Installing ${#to_install[@]} packages..."
    sudo apt-get install -y --no-install-recommends "${to_install[@]}" || {
        log_warn "Some packages failed to install — this is normal if sources have changed"
        log_warn "Retrying with --fix-missing..."
        sudo apt-get install -y --fix-missing --no-install-recommends "${to_install[@]}" || true
    }
}

restore_snap_packages() {
    log_section "Snap Packages"
    if [[ ! -f "$BACKUP_DIR/snap/packages.list" ]]; then
        log_skip "No snap package list found"
        return
    fi

    if ! command -v snap &>/dev/null; then
        log_warn "snap not found — installing snapd"
        sudo apt-get install -y snapd || {
            log_error "Failed to install snapd, skipping snap packages"
            return
        }
    fi

    while IFS=' ' read -r pkg channel; do
        [[ -z "$pkg" ]] && continue
        if snap list "$pkg" &>/dev/null; then
            log_skip "snap: $pkg already installed"
        else
            log_info "Installing snap: $pkg"
            # Try classic confinement first (common for dev tools), fall back to strict
            sudo snap install "$pkg" --classic 2>/dev/null || \
                sudo snap install "$pkg" 2>/dev/null || \
                log_warn "Failed to install snap: $pkg"
        fi
    done < "$BACKUP_DIR/snap/packages.list"
}

restore_brew_packages() {
    log_section "Homebrew Packages"
    local has_formulae=false
    local has_casks=false
    [[ -f "$BACKUP_DIR/brew/formulae.list" ]] && [[ -s "$BACKUP_DIR/brew/formulae.list" ]] && has_formulae=true
    [[ -f "$BACKUP_DIR/brew/casks.list" ]] && [[ -s "$BACKUP_DIR/brew/casks.list" ]] && has_casks=true

    if [[ "$has_formulae" == false ]] && [[ "$has_casks" == false ]]; then
        log_skip "No Homebrew package lists found"
        return
    fi

    if ! command -v brew &>/dev/null; then
        log_info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
            log_error "Failed to install Homebrew, skipping brew packages"
            return
        }
        # Add brew to PATH for this session
        eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv 2>/dev/null || true)"
    fi

    if [[ "$has_formulae" == true ]]; then
        while IFS= read -r pkg; do
            [[ -z "$pkg" ]] && continue
            if brew list "$pkg" &>/dev/null; then
                log_skip "brew: $pkg already installed"
            else
                log_info "Installing brew formula: $pkg"
                brew install "$pkg" || log_warn "Failed to install $pkg"
            fi
        done < "$BACKUP_DIR/brew/formulae.list"
    fi

    if [[ "$has_casks" == true ]]; then
        while IFS= read -r pkg; do
            [[ -z "$pkg" ]] && continue
            if brew list --cask "$pkg" &>/dev/null; then
                log_skip "brew cask: $pkg already installed"
            else
                log_info "Installing brew cask: $pkg"
                brew install --cask "$pkg" || log_warn "Failed to install cask $pkg"
            fi
        done < "$BACKUP_DIR/brew/casks.list"
    fi
}

# ---------------------------------------------------------------------------
# Phase 3: Dev tools
# ---------------------------------------------------------------------------

install_nvm_node() {
    log_section "NVM & Node.js"
    local node_ver
    node_ver=$(get_version NODE_VERSION "24.12.0")

    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

    if [[ ! -d "$NVM_DIR" ]]; then
        log_info "Installing NVM..."
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
    else
        log_skip "NVM already installed"
    fi

    # Source NVM
    # shellcheck disable=SC1091
    [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"

    if command -v node &>/dev/null && [[ "$(node --version)" == "v${node_ver}" ]]; then
        log_skip "Node.js v${node_ver} already installed"
    else
        log_info "Installing Node.js v${node_ver}..."
        nvm install "$node_ver"
        nvm use "$node_ver"
        nvm alias default "$node_ver"
    fi
    log_info "Node.js $(node --version), npm $(npm --version)"
}

install_npm_globals() {
    log_section "NPM Global Packages"
    if [[ ! -f "$BACKUP_DIR/npm/global-packages.list" ]]; then
        log_skip "No npm global package list found"
        return
    fi

    # Source NVM in case it's not loaded
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    # shellcheck disable=SC1091
    [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"

    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        if npm list -g "$pkg" &>/dev/null; then
            log_skip "npm global: $pkg already installed"
        else
            log_info "Installing npm global: $pkg"
            npm install -g "$pkg" || log_warn "Failed to install $pkg"
        fi
    done < "$BACKUP_DIR/npm/global-packages.list"
}

install_pnpm() {
    log_section "pnpm"

    # Source NVM
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    # shellcheck disable=SC1091
    [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"

    if command -v pnpm &>/dev/null; then
        log_skip "pnpm already installed ($(pnpm --version))"
        return
    fi

    log_info "Enabling pnpm via corepack..."
    corepack enable
    corepack prepare pnpm@latest --activate || {
        log_warn "corepack failed, falling back to npm install"
        npm install -g pnpm
    }
    log_info "pnpm installed"
}

install_go() {
    log_section "Go"
    local go_ver
    go_ver=$(get_version GO_VERSION "1.25.5")

    if command -v go &>/dev/null; then
        local current
        current=$(go version | grep -oP 'go\K[0-9]+\.[0-9]+(\.[0-9]+)?')
        if [[ "$current" == "$go_ver" ]]; then
            log_skip "Go $go_ver already installed"
            return
        fi
        log_info "Upgrading Go from $current to $go_ver"
    fi

    log_info "Downloading Go $go_ver..."
    local tarball="go${go_ver}.linux-amd64.tar.gz"
    curl -fsSL "https://go.dev/dl/${tarball}" -o "/tmp/${tarball}"
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "/tmp/${tarball}"
    rm -f "/tmp/${tarball}"

    # Ensure Go is on PATH
    if ! grep -q '/usr/local/go/bin' "$HOME/.profile" 2>/dev/null; then
        echo 'export PATH=$PATH:/usr/local/go/bin' >> "$HOME/.profile"
    fi
    export PATH="$PATH:/usr/local/go/bin"
    log_info "Go $(go version) installed"
}

install_docker() {
    log_section "Docker"
    if command -v docker &>/dev/null; then
        log_skip "Docker already installed ($(docker --version))"
        return
    fi

    log_info "Installing Docker via get.docker.com..."
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker "$USER" || true
    log_info "Docker installed. You may need to log out and back in for group membership."
}

# ---------------------------------------------------------------------------
# Phase 4: CLIs
# ---------------------------------------------------------------------------

install_claude() {
    log_section "Claude CLI"
    if command -v claude &>/dev/null; then
        log_skip "Claude CLI already installed"
        return
    fi

    # Source NVM
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    # shellcheck disable=SC1091
    [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"

    log_info "Installing Claude CLI via npm..."
    npm install -g @anthropic-ai/claude-code || log_warn "Failed to install Claude CLI"
}

install_doppler() {
    log_section "Doppler CLI"
    if command -v doppler &>/dev/null; then
        log_skip "Doppler already installed ($(doppler --version 2>/dev/null | head -1))"
        return
    fi

    log_info "Installing Doppler CLI..."
    # Try apt first (source may have been restored already)
    if sudo apt-get install -y doppler 2>/dev/null; then
        log_info "Doppler installed via apt"
    else
        # Fallback: official install script
        curl -fsSL https://cli.doppler.com/install.sh | sudo sh
        log_info "Doppler installed via install script"
    fi
}

install_fly() {
    log_section "Fly.io CLI"
    if command -v fly &>/dev/null; then
        log_skip "Fly CLI already installed ($(fly version 2>/dev/null | head -1))"
        return
    fi

    log_info "Installing Fly CLI..."
    curl -fsSL https://fly.io/install.sh | sh
    log_info "Fly CLI installed"
}

install_temporal() {
    log_section "Temporal CLI"
    if command -v temporal &>/dev/null; then
        log_skip "Temporal CLI already installed"
        return
    fi

    log_info "Installing Temporal CLI..."
    curl -fsSL https://temporal.download/cli.sh | sh
    log_info "Temporal CLI installed"
}

install_opencode() {
    log_section "OpenCode"
    if [[ -x "$HOME/.opencode/bin/opencode" ]]; then
        log_skip "OpenCode already installed"
        return
    fi

    log_info "Installing OpenCode..."
    curl -fsSL https://opencode.ai/install | bash || log_warn "OpenCode install failed"
}

install_brave() {
    log_section "Brave Browser"
    if command -v brave-browser &>/dev/null; then
        log_skip "Brave already installed"
        return
    fi

    log_info "Installing Brave Browser..."
    curl -fsSL https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
        | sudo tee /usr/share/keyrings/brave-browser-archive-keyring.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" \
        | sudo tee /etc/apt/sources.list.d/brave-browser-release.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y brave-browser || log_warn "Failed to install Brave Browser"
}

# ---------------------------------------------------------------------------
# Phase 5: Remaining
# ---------------------------------------------------------------------------

restore_local_bin() {
    log_section "Local Binaries (~/.local/bin)"
    if [[ -d "$BACKUP_DIR/local-bin/files" ]]; then
        mkdir -p "$HOME/.local/bin"
        local count=0
        for f in "$BACKUP_DIR/local-bin/files/"*; do
            [[ -f "$f" ]] || continue
            local name
            name=$(basename "$f")
            # Skip binaries that are managed by tool installers
            if [[ "$name" == "claude" ]]; then
                log_skip "$name — managed by npm, skipping"
                continue
            fi
            if [[ -f "$HOME/.local/bin/$name" ]]; then
                log_skip "$name already exists in ~/.local/bin"
            else
                cp -a "$f" "$HOME/.local/bin/$name"
                chmod +x "$HOME/.local/bin/$name"
                log_info "Restored ~/.local/bin/$name"
            fi
            count=$((count + 1))
        done
    fi

    if [[ -f "$BACKUP_DIR/local-bin/symlinks.txt" ]]; then
        log_info "Symlinks from backup (may need manual recreation):"
        while IFS= read -r line; do
            log_info "  $line"
        done < "$BACKUP_DIR/local-bin/symlinks.txt"
    fi
}

restore_go_bin() {
    log_section "Go Binaries (~/go/bin)"
    if [[ -d "$BACKUP_DIR/go-bin" ]]; then
        mkdir -p "$HOME/go/bin"
        local count=0
        for f in "$BACKUP_DIR/go-bin/"*; do
            [[ -f "$f" ]] || continue
            local name
            name=$(basename "$f")
            if [[ -f "$HOME/go/bin/$name" ]]; then
                log_skip "$name already exists in ~/go/bin"
            else
                cp -a "$f" "$HOME/go/bin/$name"
                chmod +x "$HOME/go/bin/$name"
                log_info "Restored ~/go/bin/$name"
            fi
            count=$((count + 1))
        done
        log_info "Processed $count Go binaries"
    else
        log_skip "No Go binaries backup found"
    fi
}

restore_usr_local_bin() {
    log_section "System Binaries (/usr/local/bin)"
    if [[ -d "$BACKUP_DIR/usr-local-bin/files" ]]; then
        local count=0
        for f in "$BACKUP_DIR/usr-local-bin/files/"*; do
            [[ -f "$f" ]] || continue
            local name
            name=$(basename "$f")
            if [[ -f "/usr/local/bin/$name" ]]; then
                log_skip "$name already exists in /usr/local/bin"
            else
                sudo cp -a "$f" "/usr/local/bin/$name"
                sudo chmod +x "/usr/local/bin/$name"
                log_info "Restored /usr/local/bin/$name"
            fi
            count=$((count + 1))
        done
        log_info "Processed $count binaries"
    else
        log_skip "No /usr/local/bin backup found"
    fi

    if [[ -f "$BACKUP_DIR/usr-local-bin/symlinks.txt" ]]; then
        log_info "Symlinks from backup (may need manual recreation):"
        while IFS= read -r line; do
            log_info "  $line"
        done < "$BACKUP_DIR/usr-local-bin/symlinks.txt"
    fi
}

restore_tool_configs() {
    log_section "Tool Configs"

    # Fly.io config
    if [[ -d "$BACKUP_DIR/tools/fly" ]]; then
        mkdir -p "$HOME/.fly"
        for f in "$BACKUP_DIR/tools/fly/"*; do
            [[ -f "$f" ]] || continue
            local name
            name=$(basename "$f")
            cp -a "$f" "$HOME/.fly/$name"
            log_info "Restored ~/.fly/$name"
        done
    fi

    # OpenCode config
    if [[ -d "$BACKUP_DIR/tools/opencode" ]]; then
        mkdir -p "$HOME/.opencode"
        for f in "$BACKUP_DIR/tools/opencode/"*; do
            [[ -f "$f" ]] || continue
            local name
            name=$(basename "$f")
            cp -a "$f" "$HOME/.opencode/$name"
            log_info "Restored ~/.opencode/$name"
        done
    fi
}

show_pip_reference() {
    log_section "Pip Packages (Reference)"
    if [[ -f "$BACKUP_DIR/pip-packages.txt" ]]; then
        local count
        count=$(wc -l < "$BACKUP_DIR/pip-packages.txt")
        log_info "Found $count pip packages in backup (NOT auto-installed due to PEP 668)"
        log_info "To review: cat $BACKUP_DIR/pip-packages.txt"
        log_info "To install manually: pip install --break-system-packages -r $BACKUP_DIR/pip-packages.txt"
    fi
}

show_summary() {
    echo -e "\n${GREEN}"
    echo "============================================="
    echo "  Restore Complete!"
    echo "  Log file: $LOG_FILE"
    echo "============================================="
    echo -e "${NC}"
    echo ""
    echo "Post-restore checklist:"
    echo "  1. Log out and back in (for Docker group + shell changes)"
    echo "  2. Run 'ssh -T git@github.com' to verify SSH"
    echo "  3. Review pip packages if needed (see log above)"
    echo "  4. Run 'doppler login' to authenticate Doppler"
    echo "  5. Run 'fly auth login' to authenticate Fly.io"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"

    echo -e "${BLUE}"
    echo "============================================="
    echo "  Ubuntu Dev Machine Restore"
    echo "  $(date)"
    echo "============================================="
    echo -e "${NC}"

    detect_backup_dir
    load_versions

    # Show manifest info
    if [[ -f "$BACKUP_DIR/manifest.json" ]]; then
        log_info "Backup info:"
        python3 -c "
import json
with open('$BACKUP_DIR/manifest.json') as f:
    m = json.load(f)
print(f\"  Date:     {m['backup_date']}\")
print(f\"  Host:     {m['hostname']}\")
print(f\"  User:     {m['username']}\")
print(f\"  Ubuntu:   {m.get('ubuntu_version', '?')} ({m.get('ubuntu_codename', '?')})\")
print(f\"  Contents: {', '.join(m['contents'])}\")
" 2>/dev/null || true
    fi

    # Phase 1: Files (no network)
    restore_ssh
    restore_dotfiles
    restore_ohmybash
    restore_config

    # Phase 2: Package managers
    restore_apt_sources
    restore_apt_packages
    restore_snap_packages
    restore_brew_packages

    # Phase 3: Dev tools
    install_nvm_node
    install_npm_globals
    install_pnpm
    install_go
    install_docker

    # Phase 4: CLIs
    install_claude
    install_doppler
    install_fly
    install_temporal
    install_opencode
    install_brave

    # Phase 5: Remaining
    restore_local_bin
    restore_go_bin
    restore_usr_local_bin
    restore_tool_configs
    show_pip_reference

    show_summary
}

main "$@"
