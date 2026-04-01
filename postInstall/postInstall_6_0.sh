#!/bin/bash
# ==============================================================================
# Arch Linux Post-Installation Script — v6.0 (gum edition)
# Stack: Bash 5+ + gum                           (per CLAUDE.md)
# Run as a regular user with sudo privileges, NOT as root.
# ==============================================================================
set -euo pipefail
# set -e  : exit on any non-zero return
# set -u  : treat unset variables as errors
# set -o pipefail : pipe fails if ANY stage fails


# ==============================================================================
# CLI FLAGS  — parsed before readonly declarations
# ==============================================================================

NO_GUM=false
DRY_RUN=false
VERBOSE=false

for _arg in "$@"; do
    case "$_arg" in
        --no-gum)  NO_GUM=true  ;;
        --dry-run) DRY_RUN=true ;;
        --verbose) VERBOSE=true ;;
        --help)
            echo "Usage: bash postInstall_6_0.sh [--no-gum] [--dry-run] [--verbose]"
            exit 0
            ;;
    esac
done

if [[ "$VERBOSE" == true ]]; then
    set -x
fi


# ==============================================================================
# CONFIGURATION
# MACHINE_TYPE and DOTFILES_REPO are NOT readonly — the config wizard
# (ui_configure) lets the user change them before the run begins.
# ==============================================================================

readonly SCRIPT_NAME="postInstall"
readonly SCRIPT_VERSION="6.0"
readonly LOG_FILE="/tmp/${SCRIPT_NAME}.log"
readonly AUR_DIR="$HOME/AUR"
readonly REFLECTOR_COUNTRY="France"
readonly ENABLE_SNAPPER="auto"    # "auto" | "1" | "0"

# Configurable at runtime via ui_configure()
MACHINE_TYPE="laptop"             # "laptop" | "desktop"
DOTFILES_REPO="https://github.com/Stars-Hiker/dotfiles"
DOTFILES_DIR="$HOME/.dotfiles"


# ==============================================================================
# GUM THEME CONSTANTS  (per CLAUDE.md — never hardcode colour numbers)
# ==============================================================================

readonly GUM_C_TITLE=99
readonly GUM_C_OK=46
readonly GUM_C_WARN=214
readonly GUM_C_ERR=196
readonly GUM_C_INFO=51
readonly GUM_C_DIM=242
readonly GUM_C_ACCENT=141
readonly GUM_WIDTH=70


# ==============================================================================
# GUM UI PRIMITIVES
# Rule: NEVER call gum inside logic functions.  All gum lives here.
# Rule: NEVER nest $(gum style) in --title/--header — use _clr() instead.
# Rule: NEVER pass empty string to --selected.
# ==============================================================================

function _clr() {
    # inputs: colour_num, text / outputs: ANSI-coloured string on stdout
    printf '\033[38;5;%sm%s\033[0m' "$1" "$2"
}

function ok() {
    # inputs: message / side-effects: prints green OK line to terminal + log
    local _msg; _msg="$(_clr "$GUM_C_OK" "  ✓  $1")"
    echo -e "$_msg" | tee -a "$LOG_FILE"
}

function warn() {
    # inputs: message / side-effects: prints yellow WARN line to terminal + log
    local _msg; _msg="$(_clr "$GUM_C_WARN" "  ⚠  $1")"
    echo -e "$_msg" | tee -a "$LOG_FILE"
}

function info() {
    # inputs: message / side-effects: prints cyan INFO line to terminal + log
    local _msg; _msg="$(_clr "$GUM_C_INFO" "  →  $1")"
    echo -e "$_msg" | tee -a "$LOG_FILE"
}

function log() {
    # inputs: message / side-effects: prints dim detail line to terminal + log
    local _msg; _msg="$(_clr "$GUM_C_DIM" "     $1")"
    echo -e "$_msg" | tee -a "$LOG_FILE"
}

function die() {
    # inputs: message / side-effects: prints fatal error box, exits 1
    if [[ "$NO_GUM" == true ]]; then
        echo -e "\033[1;31m  ✗ FATAL: $1\033[0m" >&2
    else
        gum style \
            --border double \
            --border-foreground "$GUM_C_ERR" \
            --padding "1 2" \
            --width "$GUM_WIDTH" \
            "$(_clr "$GUM_C_ERR" "✗  FATAL:") $1" >&2
    fi
    echo -e "  See $LOG_FILE for the full run log." >&2
    exit 1
}

function section() {
    # inputs: title / side-effects: prints styled section header to terminal + log
    echo "" | tee -a "$LOG_FILE"
    if [[ "$NO_GUM" == true ]]; then
        echo -e "\033[1;34m====  $1  ====\033[0m" | tee -a "$LOG_FILE"
    else
        gum style \
            --border normal \
            --border-foreground "$GUM_C_ACCENT" \
            --padding "0 2" \
            --width "$GUM_WIDTH" \
            "$(_clr "$GUM_C_TITLE" "  $1")" | tee -a "$LOG_FILE"
    fi
    echo "" | tee -a "$LOG_FILE"
}

function confirm_gum() {
    # inputs: message / outputs: 0 (yes) or 1 (no)
    if [[ "$NO_GUM" == true ]]; then
        read -r -p "  $1 [y/N]: " _reply
        [[ "$_reply" =~ ^[Yy]$ ]]
    else
        gum confirm "$1"
    fi
}

function choose_one() {
    # inputs: default, items... / outputs: selected item on stdout
    local _default="$1"; shift
    if [[ "$NO_GUM" == true ]]; then
        local _i=1
        for _item in "$@"; do echo "  $_i) $_item"; ((_i++)); done
        read -r -p "  Choice [1]: " _idx
        echo "${@:${_idx:-1}:1}"
    else
        # Guard: never pass empty string to --selected (CLAUDE.md rule #15)
        if [[ -n "$_default" ]]; then
            gum choose --selected="$_default" "$@"
        else
            gum choose "$@"
        fi
    fi
}

function choose_many() {
    # inputs: defaults (comma-sep, may be empty), items... / outputs: selections newline-sep
    local _defaults="$1"; shift
    if [[ "$NO_GUM" == true ]]; then
        # In NO_GUM mode, default to all items selected
        for _item in "$@"; do echo "$_item"; done
    else
        local _sel_args=()
        IFS=',' read -ra _def_arr <<< "$_defaults"
        for _d in "${_def_arr[@]+"${_def_arr[@]}"}"; do
            # Guard: skip empty strings (CLAUDE.md rule #15)
            if [[ -n "$_d" ]]; then
                _sel_args+=("--selected=$_d")
            fi
        done
        gum choose --no-limit "${_sel_args[@]+"${_sel_args[@]}"}" "$@"
    fi
}

function input_gum() {
    # inputs: prompt, placeholder / outputs: user input on stdout
    local _prompt="$1"
    local _placeholder="${2:-}"
    if [[ "$NO_GUM" == true ]]; then
        read -r -p "  $_prompt: " _inp
        echo "$_inp"
    else
        if [[ -n "$_placeholder" ]]; then
            gum input --prompt "  $_prompt: " --placeholder "$_placeholder"
        else
            gum input --prompt "  $_prompt: "
        fi
    fi
}

function run_spin() {
    # inputs: label, cmd... / side-effects: runs cmd with spinner; appends output to log
    # CLAUDE.md: DRY_RUN=true → print, no exec. Never $(gum style) in --title.
    local _label="$1"; shift
    if [[ "$DRY_RUN" == true ]]; then
        info "DRY-RUN: $*"
        return 0
    fi
    if [[ "$NO_GUM" == true ]]; then
        info "$_label"
        "$@" >> "$LOG_FILE" 2>&1
    else
        # Pass log path via env var — avoids positional-arg conflicts in bash -c
        SPIN_LOG="$LOG_FILE" gum spin \
            --spinner dot \
            --title "$_label" \
            -- bash -c '"$@" >> "$SPIN_LOG" 2>&1' _ "$@"
    fi
}


# ==============================================================================
# IDEMPOTENCY HELPERS
# Every step must be safe to re-run on an already-configured system.
# ==============================================================================

function dir_exists()  {
    # inputs: path / outputs: 0 if directory exists
    [[ -d "$1" ]]
}

function file_exists() {
    # inputs: path / outputs: 0 if file exists
    [[ -f "$1" ]]
}

function cmd_exists()  {
    # inputs: command name / outputs: 0 if found in PATH
    command -v "$1" >/dev/null 2>&1
}

function pkg_installed() {
    # inputs: package name / outputs: 0 if installed per pacman local DB
    pacman -Qi "$1" &>/dev/null
}

function service_enabled() {
    # inputs: unit name / outputs: 0 if systemd unit is enabled
    systemctl is-enabled --quiet "$1" 2>/dev/null
}


# ==============================================================================
# PRE-FLIGHT CHECKS  — pure logic, no gum
# ==============================================================================

function check_not_root() {
    # inputs: EUID / outputs: none / side-effects: exits if running as root
    if [[ "$EUID" -eq 0 ]]; then
        die "Do not run as root. Use a regular user with sudo."
    fi
    ok "Running as user '$USER'."
}

function check_sudo_access() {
    # inputs: none / side-effects: caches sudo credentials, spawns keepalive
    sudo -v || die "sudo access is required but could not be obtained."
    # Keep the sudo timestamp alive for the duration of the script.
    ( while true; do sudo -n true; sleep 50; done ) &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT
    ok "sudo credentials cached."
}

function check_internet() {
    # inputs: none / side-effects: exits if no internet
    info "Checking internet connectivity..."
    if ! curl -s --max-time 5 https://archlinux.org > /dev/null; then
        die "No internet access. Check your connection before running this script."
    fi
    ok "Internet is reachable."
}

function check_dependencies() {
    # inputs: none / side-effects: exits if required tools missing
    local _missing=()
    for _dep in git curl sudo pacman; do
        if ! cmd_exists "$_dep"; then
            _missing+=("$_dep")
        fi
    done
    if [[ ${#_missing[@]} -gt 0 ]]; then
        die "Missing required tools: ${_missing[*]}"
    fi
    ok "All pre-flight dependencies found."
}

function check_gum() {
    # inputs: NO_GUM / side-effects: installs gum if missing, sets NO_GUM fallback
    if [[ "$NO_GUM" == true ]]; then
        return 0
    fi
    if ! cmd_exists gum; then
        echo "  gum not found — attempting install via pacman..."
        if sudo pacman -S --needed --noconfirm gum 2>/dev/null; then
            ok "gum installed."
        else
            warn "Could not install gum. Falling back to --no-gum mode."
            NO_GUM=true
        fi
    fi
}


# ==============================================================================
# CONFIG WIZARD  — UI wrapper; sets MACHINE_TYPE and DOTFILES_REPO
# ==============================================================================

function ui_configure() {
    # inputs: none / side-effects: sets MACHINE_TYPE, DOTFILES_REPO, DOTFILES_DIR

    section "Configuration"
    info "Current settings — press Enter to keep, or change below."
    echo ""

    # Machine type
    local _mt
    _mt=$(choose_one "$MACHINE_TYPE" "laptop" "desktop")
    MACHINE_TYPE="$_mt"
    log "Machine type: $MACHINE_TYPE"

    # Dotfiles repo
    local _repo
    _repo=$(input_gum "Dotfiles repo URL" "$DOTFILES_REPO")
    if [[ -n "$_repo" ]]; then
        DOTFILES_REPO="$_repo"
    fi
    DOTFILES_DIR="$HOME/.dotfiles"
    log "Dotfiles repo: $DOTFILES_REPO"
    echo ""
}


# ==============================================================================
# STEP SELECTION MENU  — UI wrapper
# ==============================================================================

# Parallel arrays: labels shown in menu ↔ space-separated function names to call.
# CLAUDE.md rule: arrays must use the empty-guard pattern when iterated.
STEP_LABELS=(
    "01 — Pacman config + hooks"
    "02 — Mirrors + reflector timer"
    "03 — AUR helper (paru)"
    "04 — Essential packages"
    "05 — Fonts"
    "06 — Custom tools"
    "07 — QEMU / KVM"
    "08 — ZSH setup"
    "09 — Firewall + SSH hardening"
    "10 — Power management"
    "11 — Btrfs snapshots (snapper)"
    "12 — Neovim config"
    "13 — Hyprland + Wayland"
    "14 — Dotfiles"
)

STEP_FUNCS=(
    "configure_pacman setup_pacman_hooks"
    "setup_mirrors setup_mirror_timer"
    "install_paru configure_paru"
    "install_essentials"
    "install_fonts"
    "install_custom_tools"
    "install_qemu_kvm"
    "install_zsh_plugins configure_zsh set_default_shell_zsh"
    "setup_firewall harden_ssh"
    "install_power_management"
    "setup_snapper"
    "configure_neovim"
    "install_hyprland"
    "deploy_dotfiles"
)

# Bitmask array: 1 = selected, 0 = skipped (set by ui_select_steps)
declare -a STEP_SELECTED=()

function ui_select_steps() {
    # inputs: STEP_LABELS / side-effects: populates STEP_SELECTED[]
    section "Step Selection"
    info "Space = toggle · Enter = confirm · All steps pre-selected."
    echo ""

    # Build comma-separated default string — all labels pre-selected
    local _defaults
    _defaults=$(IFS=','; echo "${STEP_LABELS[*]}")

    local _chosen
    _chosen=$(choose_many "$_defaults" "${STEP_LABELS[@]+"${STEP_LABELS[@]}"}")

    # Mark each step as selected or skipped
    local _i
    for (( _i=0; _i<${#STEP_LABELS[@]}; _i++ )); do
        if echo "$_chosen" | grep -qxF "${STEP_LABELS[$_i]}"; then
            STEP_SELECTED[$_i]=1
        else
            STEP_SELECTED[$_i]=0
        fi
    done
}


# ==============================================================================
# PACMAN CONFIGURATION
# ==============================================================================

function configure_pacman() {
    # inputs: /etc/pacman.conf / side-effects: enables Color, VerbosePkgLists,
    #         ParallelDownloads=5, multilib repo; refreshes pacman DB
    section "Hardening pacman.conf"

    local _conf="/etc/pacman.conf"

    run_spin "Enabling Color output" \
        sudo sed -i 's/^#Color/Color/' "$_conf"

    run_spin "Enabling VerbosePkgLists" \
        sudo sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' "$_conf"

    run_spin "Setting ParallelDownloads = 5" \
        sudo sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' "$_conf"

    # Enable multilib — sed: match [multilib] header, advance one line, uncomment Include
    if grep -q "^\[multilib\]" "$_conf"; then
        run_spin "Enabling [multilib] repository" \
            sudo sed -i '/^\[multilib\]/{n;s/^#Include/Include/}' "$_conf"
        log "multilib repository enabled."
    else
        warn "[multilib] section not found in pacman.conf — skipping."
    fi

    run_spin "Refreshing pacman DB" sudo pacman -Syy
    ok "pacman.conf configured."
}

function setup_pacman_hooks() {
    # inputs: none / side-effects: writes orphan-check hook to /etc/pacman.d/hooks/
    section "Installing pacman hooks"

    sudo mkdir -p /etc/pacman.d/hooks

    sudo tee /etc/pacman.d/hooks/orphans.hook > /dev/null <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Checking for orphaned packages...
When = PostTransaction
Exec = /bin/bash -c 'orphans=$(pacman -Qdtq 2>/dev/null); [ -n "$orphans" ] && echo "WARNING: Orphaned packages found: $orphans" || true'
EOF

    ok "pacman hooks installed."
}


# ==============================================================================
# MIRRORS
# ==============================================================================

function setup_mirrors() {
    # inputs: REFLECTOR_COUNTRY / side-effects: installs reflector, updates mirrorlist
    section "Configuring pacman mirrors"

    if ! pkg_installed reflector; then
        # Only full system upgrade in the script — all other installs use -S.
        run_spin "Installing reflector (+ full system upgrade)" \
            sudo pacman -Syu --needed --noconfirm reflector \
            || die "Failed to install reflector."
    fi

    local _backup="/etc/pacman.d/mirrorlist.backup"
    if ! file_exists "$_backup"; then
        sudo cp /etc/pacman.d/mirrorlist "$_backup"
        log "Original mirrorlist backed up to $_backup"
    fi

    run_spin "Fetching fastest mirrors ($REFLECTOR_COUNTRY)" \
        sudo reflector \
            --country "$REFLECTOR_COUNTRY" \
            --age 12 \
            --protocol https \
            --sort rate \
            --fastest 10 \
            --save /etc/pacman.d/mirrorlist \
        || die "Reflector failed to fetch mirrors."

    run_spin "Refreshing pacman DB after mirror update" sudo pacman -Syy \
        || die "pacman DB refresh failed."
    ok "Mirrors configured."
}

function setup_mirror_timer() {
    # inputs: REFLECTOR_COUNTRY / side-effects: writes reflector systemd units, enables timer
    section "Setting up reflector systemd timer"

    # Unquoted EOF — REFLECTOR_COUNTRY must expand at write-time.
    sudo tee /etc/systemd/system/reflector.service > /dev/null <<EOF
[Unit]
Description=Update Arch Linux Mirrorlist
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/reflector --country ${REFLECTOR_COUNTRY} --age 12 --protocol https --sort rate --fastest 10 --save /etc/pacman.d/mirrorlist
EOF

    # Quoted 'EOF' — no variables to expand in the timer unit.
    sudo tee /etc/systemd/system/reflector.timer > /dev/null <<'EOF'
[Unit]
Description=Run Reflector Weekly

[Timer]
OnCalendar=weekly
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload

    if ! service_enabled reflector.timer; then
        sudo systemctl enable --now reflector.timer \
            || die "Failed to enable reflector timer."
    fi
    ok "reflector.timer enabled."
}


# ==============================================================================
# AUR HELPER — paru
# ==============================================================================

function install_paru() {
    # inputs: AUR_DIR / side-effects: clones paru-bin, builds with makepkg
    section "Installing paru (AUR helper)"

    if cmd_exists paru; then
        log "paru is already installed — skipping."
        return 0
    fi

    mkdir -p "$AUR_DIR"
    local _paru_dir="${AUR_DIR}/paru-bin"

    # Subshell: isolates cd so parent CWD is unchanged.
    (
        if ! dir_exists "$_paru_dir"; then
            info "Cloning paru-bin from AUR..."
            git clone https://aur.archlinux.org/paru-bin.git "$_paru_dir" \
                || die "Failed to clone paru-bin."
        fi
        cd "$_paru_dir"
        # makepkg is intentionally run directly (visible output) — it can ask
        # about optional dependencies and signature verification.
        info "Building paru (makepkg output visible below)..."
        makepkg -si --noconfirm || die "makepkg failed for paru."
    )
    ok "paru installed."
}

function configure_paru() {
    # inputs: none / side-effects: writes ~/.config/paru/paru.conf
    section "Configuring paru"

    local _conf="$HOME/.config/paru/paru.conf"
    mkdir -p "$(dirname "$_conf")"

    if file_exists "$_conf"; then
        log "paru.conf already exists — skipping."
        return 0
    fi

    cat > "$_conf" <<'EOF'
[options]
BottomUp          # show AUR results below official packages in search output
SudoLoop          # keep sudo alive during long AUR builds
CombinedUpgrade   # upgrade official + AUR packages in a single paru -Syu
CleanAfter        # remove build dirs after install to reclaim disk space
EOF

    ok "paru.conf written to $_conf"
}


# ==============================================================================
# PACKAGE INSTALLATION
# ==============================================================================

function install_essentials() {
    # inputs: none / side-effects: installs core CLI tools via pacman
    section "Installing essential packages"

    local _pkgs=(
        git wget curl stow
        neovim vim
        zsh
        btrfs-progs dosfstools exfatprogs e2fsprogs ntfs-3g xfsprogs udftools
    )

    run_spin "Installing essentials (${#_pkgs[@]} packages)" \
        sudo pacman -S --needed --noconfirm "${_pkgs[@]}" \
        || die "Failed to install essential packages."
    ok "Essentials installed."
}

function install_custom_tools() {
    # inputs: none / side-effects: installs custom tooling via pacman
    section "Installing custom tools"

    local _pkgs=(
        htop btop
        fastfetch
        firefox
        unzip zip bzip3 xz p7zip unrar unarchiver
        wl-clipboard
        deluge deluge-gtk
        eza yazi bat fd ripgrep
        gcc gdb
        nmap wireshark-qt aircrack-ng nikto john sqlmap
        whois inetutils openbsd-netcat tcpdump traceroute
        gparted gpart xorg-xhost
    )

    run_spin "Installing custom tools (${#_pkgs[@]} packages)" \
        sudo pacman -S --needed --noconfirm "${_pkgs[@]}" \
        || die "Failed to install custom tools."
    ok "Custom tools installed."
}

function install_qemu_kvm() {
    # inputs: none / side-effects: installs QEMU/KVM stack, enables libvirtd,
    #         adds user to libvirt+kvm groups, starts default NAT network
    section "Installing QEMU/KVM virtualisation stack"

    local _pkgs=(
        qemu-full libvirt virt-install virt-manager virt-viewer
        edk2-ovmf swtpm guestfs-tools libosinfo dnsmasq openbsd-netcat
    )

    run_spin "Installing QEMU/KVM packages (${#_pkgs[@]} packages)" \
        sudo pacman -S --needed --noconfirm "${_pkgs[@]}" \
        || die "Failed to install QEMU/KVM packages."

    if ! service_enabled libvirtd.service; then
        run_spin "Enabling libvirtd" \
            sudo systemctl enable --now libvirtd.service \
            || die "Failed to enable libvirtd."
    fi

    for _grp in libvirt kvm; do
        if ! id -nG "$USER" | grep -qw "$_grp"; then
            sudo usermod -aG "$_grp" "$USER" \
                || die "Failed to add $USER to group $_grp."
            log "Added '$USER' to group '$_grp'."
        else
            log "User '$USER' already in group '$_grp'."
        fi
    done

    if sudo virsh net-info default &>/dev/null; then
        sudo virsh net-autostart default 2>/dev/null || true
        sudo virsh net-start    default 2>/dev/null || true
        log "libvirt 'default' NAT network enabled."
    fi

    log "KVM host validation:"
    sudo virt-host-validate qemu 2>&1 | tee -a "$LOG_FILE" \
        || warn "Some KVM checks failed — review $LOG_FILE."

    ok "QEMU/KVM stack installed."
}


# ==============================================================================
# ZSH
# ==============================================================================

function install_zsh_plugins() {
    # inputs: AUR_DIR / side-effects: clones or updates three zsh-users plugins
    section "Installing ZSH plugins"

    local _plugins=(
        "zsh-autosuggestions|https://github.com/zsh-users/zsh-autosuggestions"
        "zsh-syntax-highlighting|https://github.com/zsh-users/zsh-syntax-highlighting"
        "zsh-history-substring-search|https://github.com/zsh-users/zsh-history-substring-search"
    )

    for _entry in "${_plugins[@]+"${_plugins[@]}"}"; do
        local _name="${_entry%%|*}"
        local _url="${_entry##*|}"
        local _dest="${AUR_DIR}/${_name}"

        if dir_exists "$_dest"; then
            info "Updating plugin '$_name'..."
            git -C "$_dest" pull --ff-only >> "$LOG_FILE" 2>&1 \
                || warn "Could not update '$_name' — skipping."
        else
            run_spin "Cloning $_name" git clone "$_url" "$_dest" \
                || die "Failed to clone '$_name'."
        fi
    done
    ok "ZSH plugins ready."
}

function configure_zsh() {
    # inputs: AUR_DIR / side-effects: appends managed block to ~/.zshrc
    section "Configuring .zshrc"

    local _zshrc="$HOME/.zshrc"
    local _marker="# managed by ${SCRIPT_NAME}"

    if grep -q "$_marker" "$_zshrc" 2>/dev/null; then
        log ".zshrc already contains the managed block — skipping."
        return 0
    fi

    echo "$_marker" >> "$_zshrc"

    # Quoted 'ZSHEOF' — no variable expansion inside; $SHELL vars are literal zsh.
    cat >> "$_zshrc" <<'ZSHEOF'

# ── Wayland environment ───────────────────────────────────────────────────────
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

# ── Aliases ───────────────────────────────────────────────────────────────────
alias ll='eza -la --icons --git'
alias lt='eza --tree --icons --level=2'
alias cat='bat --paging=never'
alias grep='grep --color=auto'
alias pac='sudo pacman -S --needed'
alias update='sudo pacman -Syu'
alias szsh='source ~/.zshrc'
alias nzsh='nvim ~/.zshrc'

# ── Auto ls after cd ──────────────────────────────────────────────────────────
cd() { builtin cd "$@" && eza -la --icons --git; }

# ── History ───────────────────────────────────────────────────────────────────
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE
setopt SHARE_HISTORY

# ── Key bindings (history substring search) ───────────────────────────────────
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down

# ── Plugins ───────────────────────────────────────────────────────────────────
[[ -f "${HOME}/AUR/zsh-autosuggestions/zsh-autosuggestions.zsh" ]] \
    && source "${HOME}/AUR/zsh-autosuggestions/zsh-autosuggestions.zsh"

[[ -f "${HOME}/AUR/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]] \
    && source "${HOME}/AUR/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"

[[ -f "${HOME}/AUR/zsh-history-substring-search/zsh-history-substring-search.zsh" ]] \
    && source "${HOME}/AUR/zsh-history-substring-search/zsh-history-substring-search.zsh"
ZSHEOF

    log ".zshrc updated. Run 'source ~/.zshrc' after switching to ZSH."
    ok ".zshrc configured."
}

function set_default_shell_zsh() {
    # inputs: none / side-effects: changes login shell to zsh via chsh
    section "Setting ZSH as default shell"

    local _zsh_path
    _zsh_path=$(command -v zsh) || die "zsh not found in PATH."

    if [[ "$SHELL" == "$_zsh_path" ]]; then
        log "ZSH is already the default shell."
        return 0
    fi

    if ! grep -qxF "$_zsh_path" /etc/shells; then
        echo "$_zsh_path" | sudo tee -a /etc/shells > /dev/null
    fi

    chsh -s "$_zsh_path" || die "Failed to set ZSH as default shell."
    ok "Default shell set to ZSH. Re-login to apply."
}


# ==============================================================================
# FONTS
# ==============================================================================

function install_fonts() {
    # inputs: none / side-effects: installs Nerd Fonts + Noto, rebuilds font cache
    section "Installing fonts"

    local _pkgs=(
        ttf-dejavu ttf-roboto
        noto-fonts noto-fonts-emoji
        otf-droid-nerd otf-firamono-nerd otf-monaspace-nerd
        ttf-jetbrains-mono-nerd ttf-ubuntu-mono-nerd ttf-proggyclean-nerd
        otf-font-awesome
    )

    run_spin "Installing fonts (${#_pkgs[@]} packages)" \
        sudo pacman -S --needed --noconfirm "${_pkgs[@]}" \
        || die "Failed to install fonts."

    run_spin "Rebuilding font cache" fc-cache -fv
    ok "Fonts installed and cache rebuilt."
}


# ==============================================================================
# FIREWALL (UFW)
# ==============================================================================

function setup_firewall() {
    # inputs: none / side-effects: installs ufw, applies baseline ruleset, enables service
    section "Configuring UFW firewall"

    if ! pkg_installed ufw; then
        run_spin "Installing ufw" \
            sudo pacman -S --needed --noconfirm ufw \
            || die "Failed to install UFW."
    fi

    # Only reset if UFW has never been activated — avoids destroying manually added rules.
    if ! sudo ufw status | grep -q "Status: active"; then
        sudo ufw --force reset
        log "UFW reset to a clean state."
    fi

    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw default deny forward

    sudo ufw allow from 192.168.0.0/24 comment "LAN"
    sudo ufw limit ssh                  comment "SSH rate-limit"
    sudo ufw allow 6881/tcp             comment "Deluge TCP"
    sudo ufw allow 6881/udp             comment "Deluge UDP"

    if ! service_enabled ufw; then
        sudo systemctl enable ufw || die "Failed to enable UFW service."
    fi

    sudo ufw --force enable || die "Failed to activate UFW."
    sudo ufw status verbose | tee -a "$LOG_FILE"
    ok "Firewall configured."
}

function harden_ssh() {
    # inputs: none / side-effects: writes sshd hardening drop-in, restarts sshd if running
    section "Hardening SSH daemon"

    local _cfg="/etc/ssh/sshd_config.d/99-hardening.conf"

    if file_exists "$_cfg"; then
        log "SSH hardening config already exists — skipping."
        return 0
    fi

    sudo mkdir -p /etc/ssh/sshd_config.d
    sudo tee "$_cfg" > /dev/null <<'EOF'
# Generated by postInstall — edit manually as needed.
PermitRootLogin no
X11Forwarding no
MaxAuthTries 3

# NOTE: PasswordAuthentication is left ON intentionally.
# Disabling it before key-based auth is confirmed working will lock you out.
# Once SSH keys are configured, set this to "no" manually.
PasswordAuthentication yes
EOF

    if service_enabled sshd; then
        sudo systemctl restart sshd \
            || warn "sshd restart failed — review manually."
    else
        log "sshd is not enabled — config written but daemon not restarted."
    fi

    ok "SSH hardening config written to $_cfg"
}


# ==============================================================================
# POWER MANAGEMENT
# All power-management logic lives here — never split between other functions.
# tuned and TLP fight over CPU governor; one must be masked before the other starts.
# ==============================================================================

function install_power_management() {
    # inputs: MACHINE_TYPE / side-effects: installs+enables TLP (laptop) or tuned (desktop)
    section "Configuring power management (MACHINE_TYPE=${MACHINE_TYPE})"

    if [[ "$MACHINE_TYPE" == "laptop" ]]; then
        # Mask tuned unconditionally before TLP — "mask" is stronger than disable
        # and prevents any future accidental start (systemd presets, pacman hooks).
        warn "Ensuring tuned is stopped and masked before enabling TLP..."
        sudo systemctl stop    tuned.service 2>/dev/null || true
        sudo systemctl disable tuned.service 2>/dev/null || true
        sudo systemctl mask    tuned.service 2>/dev/null || true
        log "tuned masked — will not interfere with TLP."

        if ! pkg_installed tlp; then
            run_spin "Installing TLP" \
                sudo pacman -S --needed --noconfirm tlp tlp-rdw \
                || die "Failed to install TLP."
        fi

        # Mask rfkill units — TLP manages radio kill switches directly.
        sudo systemctl mask systemd-rfkill.service systemd-rfkill.socket

        if ! service_enabled tlp.service; then
            run_spin "Enabling TLP" \
                sudo systemctl enable --now tlp.service \
                || die "Failed to enable TLP."
        fi
        ok "TLP enabled for laptop power management."

    else
        # Desktop: install and enable tuned with the "balanced" profile.
        # tuned is installed HERE (not in install_qemu_kvm) — keeps laptop safe.
        if ! pkg_installed tuned; then
            run_spin "Installing tuned" \
                sudo pacman -S --needed --noconfirm tuned \
                || die "Failed to install tuned."
        fi

        if ! service_enabled tuned.service; then
            run_spin "Enabling tuned" \
                sudo systemctl enable --now tuned.service \
                || die "Failed to enable tuned."
        fi

        if cmd_exists tuned-adm; then
            sudo tuned-adm profile balanced \
                || warn "Could not set tuned profile — run 'tuned-adm profile' manually."
            log "tuned profile set to 'balanced'."
        fi
        ok "tuned enabled for desktop power management."
    fi
}


# ==============================================================================
# BTRFS SNAPSHOTS (snapper)
# ==============================================================================

function setup_snapper() {
    # inputs: ENABLE_SNAPPER / side-effects: installs snapper, creates root config,
    #         enables timeline + cleanup timers
    section "Setting up Btrfs snapshots (snapper)"

    local _root_fs
    _root_fs=$(findmnt -n -o FSTYPE /)

    if [[ "$ENABLE_SNAPPER" == "0" ]]; then
        log "Snapper disabled by configuration — skipping."
        return 0
    fi

    if [[ "$ENABLE_SNAPPER" == "auto" && "$_root_fs" != "btrfs" ]]; then
        log "Root filesystem is '$_root_fs', not Btrfs — skipping snapper."
        return 0
    fi

    run_spin "Installing snapper + snap-pac" \
        sudo pacman -S --needed --noconfirm snapper snap-pac \
        || die "Failed to install snapper."

    if ! sudo snapper list-configs | grep -q "^root "; then
        sudo snapper -c root create-config / \
            || die "Failed to create snapper root config."
        log "Snapper root config created."
    else
        log "Snapper root config already exists — skipping create-config."
    fi

    if ! service_enabled snapper-timeline.timer; then
        sudo systemctl enable --now snapper-timeline.timer
    fi
    if ! service_enabled snapper-cleanup.timer; then
        sudo systemctl enable --now snapper-cleanup.timer
    fi

    ok "Snapper configured. Automatic snapshots active."
}


# ==============================================================================
# NEOVIM
# ==============================================================================

function configure_neovim() {
    # inputs: none / side-effects: writes ~/.config/nvim/init.lua
    section "Configuring Neovim"

    local _nvim_dir="$HOME/.config/nvim"
    local _nvim_file="$_nvim_dir/init.lua"

    mkdir -p "$_nvim_dir"

    if file_exists "$_nvim_file"; then
        log "init.lua already exists — skipping."
        return 0
    fi

    # Quoted 'EOF' — literal Lua code; no variable expansion.
    cat > "$_nvim_file" <<'EOF'
-- ===========================================================================
-- Neovim base configuration — generated by postInstall
-- ===========================================================================

-- ── Editor behaviour ─────────────────────────────────────────────────────────
vim.opt.number         = true
vim.opt.cursorline     = true
vim.opt.scrolloff      = 8
vim.opt.signcolumn     = "yes"
vim.opt.wrap           = false

-- ── Indentation ──────────────────────────────────────────────────────────────
vim.opt.expandtab      = true
vim.opt.shiftwidth     = 4
vim.opt.tabstop        = 4
vim.opt.softtabstop    = 4
vim.opt.smartindent    = true

-- ── Search ───────────────────────────────────────────────────────────────────
vim.opt.ignorecase     = true
vim.opt.smartcase      = true
vim.opt.hlsearch       = false

-- ── Appearance ───────────────────────────────────────────────────────────────
vim.opt.termguicolors  = true

-- ── Clipboard — requires wl-clipboard (Wayland) ───────────────────────────────
vim.opt.clipboard      = "unnamedplus"

-- ── Splits ───────────────────────────────────────────────────────────────────
vim.opt.splitright     = true
vim.opt.splitbelow     = true

-- ── Leader key ───────────────────────────────────────────────────────────────
vim.g.mapleader        = " "

-- ── Key mappings ─────────────────────────────────────────────────────────────
vim.keymap.set("n", "<leader>/", "<cmd>nohlsearch<CR>",  { desc = "Clear search highlights" })
vim.keymap.set("v", "J",         ":m '>+1<CR>gv=gv",    { desc = "Move selection down" })
vim.keymap.set("v", "K",         ":m '<-2<CR>gv=gv",    { desc = "Move selection up" })
vim.keymap.set("n", "<C-d>",     "<C-d>zz",             { desc = "Scroll down (centred)" })
vim.keymap.set("n", "<C-u>",     "<C-u>zz",             { desc = "Scroll up (centred)" })
vim.keymap.set("n", "<C-s>",     "<cmd>w<CR>",          { desc = "Save file" })
vim.keymap.set("i", "<C-s>",     "<Esc><cmd>w<CR>",     { desc = "Save file" })

-- ── Next steps ───────────────────────────────────────────────────────────────
-- Install lazy.nvim: https://github.com/folke/lazy.nvim
-- Recommended plugins: telescope, nvim-treesitter, nvim-lspconfig,
-- conform.nvim, catppuccin or tokyonight.
EOF

    ok "Neovim init.lua written to $_nvim_file"
}


# ==============================================================================
# HYPRLAND — Wayland compositor + full ecosystem
# paru used throughout; firefox, yazi, wl-clipboard, ttf-jetbrains-mono-nerd
# already installed in earlier steps — --needed silently skips them.
# paru is run directly (not in run_spin) — it may need interactive AUR review.
# ==============================================================================

function install_hyprland() {
    # inputs: none / side-effects: installs Hyprland ecosystem via paru,
    #         enables hyprexpo plugin, enables PipeWire user services
    section "Installing Hyprland & Wayland ecosystem"

    if ! cmd_exists paru; then
        die "paru is required for this step but was not found. Run install_paru first."
    fi

    local _pkgs_core=(
        hyprland hyprlock hypridle hyprsunset
        hyprpolkitagent hyprshot xdg-desktop-portal-hyprland
    )
    local _pkgs_ui=(
        waybar rofi papirus-icon-theme swaync
    )
    local _pkgs_env=(
        kitty swww cliphist
    )
    local _pkgs_audio=(
        pipewire wireplumber pipewire-pulse
    )
    local _pkgs_hw=(
        brightnessctl playerctl
    )
    local _pkgs_optional=(
        nwg-look qt6ct qt6-wayland hyprcursor wallust
        grim slurp libnotify
    )

    local _all_pkgs=(
        "${_pkgs_core[@]}"
        "${_pkgs_ui[@]}"
        "${_pkgs_env[@]}"
        "${_pkgs_audio[@]}"
        "${_pkgs_hw[@]}"
        "${_pkgs_optional[@]}"
    )

    info "Installing ${#_all_pkgs[@]} Hyprland packages via paru (output visible below)..."
    # Intentionally NOT run_spin — paru may prompt for AUR PKGBUILD review.
    paru -S --needed --noconfirm "${_all_pkgs[@]}" \
        || die "paru failed to install Hyprland packages."

    ok "Hyprland ecosystem installed."

    # hyprexpo plugin via hyprpm
    if cmd_exists hyprpm; then
        info "Installing hyprexpo plugin via hyprpm..."
        hyprpm add https://github.com/hyprwm/hyprland-plugins 2>/dev/null || true
        if hyprpm enable hyprexpo 2>/dev/null; then
            ok "hyprexpo plugin enabled."
        else
            warn "hyprexpo could not be enabled — run 'hyprpm enable hyprexpo' after first Hyprland boot."
        fi
    else
        warn "hyprpm not found — install hyprexpo manually after first boot:"
        warn "  hyprpm add https://github.com/hyprwm/hyprland-plugins"
        warn "  hyprpm enable hyprexpo"
    fi

    # PipeWire user services
    info "Enabling PipeWire user services..."
    if systemctl --user enable --now pipewire.service 2>/dev/null; then
        ok "pipewire.service enabled."
    else
        warn "pipewire.service: already active or needs a reboot to start."
    fi
    if systemctl --user enable --now wireplumber.service 2>/dev/null; then
        ok "wireplumber.service enabled."
    else
        warn "wireplumber.service: already active or needs a reboot to start."
    fi
}


# ==============================================================================
# DOTFILES — deploy via GitHub + GNU Stow
# ==============================================================================

function deploy_dotfiles() {
    # inputs: DOTFILES_REPO, DOTFILES_DIR / side-effects: clones or pulls repo,
    #         runs install.sh (stow-based), falls back to USB copy if offline
    section "Deploying dotfiles (Hyprland config)"

    local _missing_deps=()
    if ! cmd_exists git;  then _missing_deps+=(git);  fi
    if ! cmd_exists stow; then _missing_deps+=(stow); fi

    if [[ ${#_missing_deps[@]} -gt 0 ]]; then
        run_spin "Installing missing dotfile deps: ${_missing_deps[*]}" \
            sudo pacman -S --needed --noconfirm "${_missing_deps[@]}" \
            || die "Failed to install: ${_missing_deps[*]}"
    fi

    if dir_exists "$DOTFILES_DIR"; then
        info "Dotfiles repo already at $DOTFILES_DIR — pulling latest..."
        git -C "$DOTFILES_DIR" pull --ff-only \
            || warn "git pull failed — continuing with existing version."
    else
        if curl -s --max-time 5 https://github.com > /dev/null 2>&1; then
            run_spin "Cloning dotfiles from GitHub" \
                git clone "$DOTFILES_REPO" "$DOTFILES_DIR" \
                || die "git clone failed."
            ok "Dotfiles cloned from GitHub."
        else
            warn "GitHub unreachable — looking for offline copy on USB..."
            local _usb_src
            _usb_src=$(find /run/media /mnt -maxdepth 3 \
                       -name "dotfiles-offline" -type d 2>/dev/null | head -1)

            if [[ -n "$_usb_src" ]]; then
                cp -r "$_usb_src" "$DOTFILES_DIR"
                ok "Dotfiles copied from USB: $_usb_src"
            else
                warn "No offline dotfiles found. Mount your USB key and run:"
                warn "  bash $DOTFILES_DIR/install.sh"
                warn "Skipping dotfiles deployment."
                return 0
            fi
        fi
    fi

    local _installer="$DOTFILES_DIR/install.sh"

    if file_exists "$_installer"; then
        info "Running dotfiles installer..."
        bash "$_installer" \
            || warn "install.sh returned an error — check output above."
        ok "Dotfiles deployed via stow."
    else
        warn "install.sh not found in $DOTFILES_DIR — stow not run."
        warn "Run manually: cd $DOTFILES_DIR && stow zsh hypr rofi waybar kitty"
    fi
}


# ==============================================================================
# STEP RUNNER
# ==============================================================================

function run_selected_steps() {
    # inputs: STEP_SELECTED[], STEP_LABELS[], STEP_FUNCS[] / side-effects: runs chosen steps
    local _i
    for (( _i=0; _i<${#STEP_LABELS[@]}; _i++ )); do
        if [[ "${STEP_SELECTED[$_i]:-0}" -eq 1 ]]; then
            log "Running: ${STEP_LABELS[$_i]}"
            # Split space-separated function names and call each in order
            local _fn
            for _fn in ${STEP_FUNCS[$_i]}; do
                "$_fn"
            done
        else
            log "Skipped: ${STEP_LABELS[$_i]}"
        fi
    done
}


# ==============================================================================
# SUMMARY REPORT
# ==============================================================================

function print_summary() {
    # inputs: MACHINE_TYPE, LOG_FILE, DOTFILES_DIR / side-effects: prints final report
    echo ""
    if [[ "$NO_GUM" == true ]]; then
        echo -e "\033[1;32m============================================\033[0m"
        echo -e "\033[1;32m  Post-installation v${SCRIPT_VERSION} complete!\033[0m"
        echo -e "\033[1;32m============================================\033[0m"
    else
        gum style \
            --border double \
            --border-foreground "$GUM_C_OK" \
            --padding "1 3" \
            --width "$GUM_WIDTH" \
            "$(_clr "$GUM_C_OK"    "  ✓  Post-installation v${SCRIPT_VERSION} complete!")
$(_clr "$GUM_C_DIM"   "  Log         : ${LOG_FILE}")
$(_clr "$GUM_C_DIM"   "  Machine     : ${MACHINE_TYPE}")
$(_clr "$GUM_C_DIM"   "  Dotfiles    : ${DOTFILES_DIR}")"
    fi

    echo ""
    echo -e "$(_clr "$GUM_C_WARN" "  Actions required after reboot:")"
    echo -e "  1. Reboot — group membership (libvirt, kvm) and ZSH shell take effect."
    echo -e "  2. Open virt-manager — VMs should work without sudo."
    echo -e "  3. $(_clr "$GUM_C_INFO" "ufw status verbose") — review firewall rules."
    echo -e "  4. Once SSH keys are set, edit $(_clr "$GUM_C_INFO" "/etc/ssh/sshd_config.d/99-hardening.conf")"
    echo -e "     and set $(_clr "$GUM_C_INFO" "PasswordAuthentication no")."
    echo -e "  5. Run $(_clr "$GUM_C_INFO" "nvim") — see init.lua comments for lazy.nvim setup."
    echo ""
    echo -e "$(_clr "$GUM_C_DIM" "  Useful commands:")"
    echo -e "    paru -Syu             — upgrade official + AUR packages"
    echo -e "    pacman -Qdtq          — list orphaned packages"
    echo -e "    snapper list          — list Btrfs snapshots (if Btrfs)"
    echo -e "    tlp-stat              — battery status (laptop)"
    echo -e "    tuned-adm profile     — active profile (desktop)"
    echo -e "    cd ~/.dotfiles && git pull && stow --restow hypr zsh rofi waybar kitty"
    echo ""
}


# ==============================================================================
# WELCOME BANNER  — UI only
# ==============================================================================

function ui_welcome() {
    # inputs: SCRIPT_VERSION / side-effects: clears terminal, shows banner
    clear
    if [[ "$NO_GUM" == true ]]; then
        echo -e "\033[1;34m"
        echo "  ╔══════════════════════════════════════════════╗"
        echo "  ║   Arch Linux Post-Installation  v${SCRIPT_VERSION}      ║"
        echo "  ║   Bash 5+ + gum                              ║"
        echo "  ╚══════════════════════════════════════════════╝"
        echo -e "\033[0m"
    else
        gum style \
            --border double \
            --border-foreground "$GUM_C_ACCENT" \
            --padding "1 4" \
            --width "$GUM_WIDTH" \
            "$(_clr "$GUM_C_TITLE"  "  Arch Linux Post-Installation")
$(_clr "$GUM_C_ACCENT" "  v${SCRIPT_VERSION} — Bash 5+ + gum")
$(_clr "$GUM_C_DIM"    "  Run as regular user with sudo")
$(_clr "$GUM_C_DIM"    "  Log → ${LOG_FILE}")"
        echo ""
    fi
}


# ==============================================================================
# MAIN
# ==============================================================================

function main() {
    # inputs: CLI flags / side-effects: full post-installation run

    # Truncate / create the log file for this run.
    : > "$LOG_FILE"
    log "Starting ${SCRIPT_NAME} v${SCRIPT_VERSION} — $(date)"

    # Gum availability check — must come before any gum calls.
    check_gum

    ui_welcome

    # Pre-flight (pure logic — no gum inside these functions)
    section "Pre-flight checks"
    check_not_root
    check_sudo_access
    check_internet
    check_dependencies

    # Interactive config (machine type, dotfiles repo)
    ui_configure

    # Step selection
    ui_select_steps

    # Confirm before doing anything
    echo ""
    if ! confirm_gum "Run selected steps now?"; then
        warn "Aborted by user."
        exit 0
    fi
    echo ""

    log "Run started — $(date)"

    # Execute
    run_selected_steps

    print_summary
}

main "$@"
