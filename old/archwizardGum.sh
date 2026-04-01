#!/usr/bin/env bash
# =============================================================================
#    █████╗ ██████╗  ██████╗██╗  ██╗    ██╗    ██╗██╗███████╗ █████╗ ██████╗ ██████╗
#   ██╔══██╗██╔══██╗██╔════╝██║  ██║    ██║    ██║██║╚══███╔╝██╔══██╗██╔══██╗██╔══██╗
#   ███████║██████╔╝██║     ███████║    ██║ █╗ ██║██║  ███╔╝ ███████║██████╔╝██║  ██║
#   ██╔══██║██╔══██╗██║     ██╔══██║    ██║███╗██║██║ ███╔╝  ██╔══██║██╔══██╗██║  ██║
#   ██║  ██║██║  ██║╚██████╗██║  ██║    ╚███╔███╔╝██║███████╗██║  ██║██║  ██║██████╔╝
#   ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝    ╚══╝╚══╝ ╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝
# =============================================================================
#  ArchWizard — gum edition
#  Version : 5.5.0-gum
#  License : MIT
#  Depends : gum (https://github.com/charmbracelet/gum)
#  Usage   : bash archwizard_gum.sh [--dry-run] [--verbose] [--load-config FILE]
#
#  Build status:
#    [x] Step 1 — Skeleton, sanity checks, keyboard layout
#    [ ] Step 2 — Disk discovery & selection
#    [ ] Step 3 — Partition wizard
#    [ ] Step 4 — System config (hostname, timezone, locale)
#    [ ] Step 5 — Users & passwords
#    [ ] Step 6 — Kernel & bootloader
#    [ ] Step 7 — Desktop environment
#    [ ] Step 8 — Optional extras
#    [ ] Phase 2 — Summary & confirmation
#    [ ] Phase 3-6 — Partitioning, install, chroot, cleanup
# =============================================================================

set -euo pipefail

# ── Error trap ────────────────────────────────────────────────────────────────
trap 'RC=$?; echo "CRASH line=$LINENO exit=$RC cmd=${BASH_COMMAND}" > /tmp/archwizard_crash.txt
      gum style --foreground 1 --bold "✗ Crashed at line $LINENO (exit $RC)"
      gum style --faint      "  cmd: ${BASH_COMMAND}"
      gum style --faint      "  Log: /tmp/archwizard.log"
      set +x' ERR

# =============================================================================
#  GLOBAL STATE — all user choices are stored here
#  (mirrors the original script exactly so later steps can rely on the same
#   variable names when they are added step by step)
# =============================================================================
DRY_RUN=false
VERBOSE=false
FIRMWARE_MODE="uefi"
CONFIG_FILE=""

# Hardware
CPU_VENDOR="unknown"
GPU_VENDOR="unknown"

# Disks & Partitions
DISK_ROOT=""
ROOT_FS="btrfs"
HOME_FS="btrfs"
DISK_HOME=""
EFI_PART=""
ROOT_PART=""
ROOT_PART_MAPPED=""
HOME_PART=""
SWAP_PART=""
EFI_SIZE_MB=512
ROOT_SIZE=""
SEP_HOME=false
HOME_SIZE=""
DUAL_BOOT=false
RESIZE_PART=""
RESIZE_NEW_GB=0
REPLACE_PART=""
REPLACE_PARTS_ALL=()
PROTECTED_PARTS=()
FREE_GB_AVAIL=0
EXISTING_WINDOWS=false
EXISTING_LINUX=false
EXISTING_SYSTEMS=()
REUSE_EFI=false

# Encryption & Swap
USE_LUKS=false
LUKS_PASSWORD=""
SWAP_TYPE="zram"
SWAP_SIZE="8"

# System identity
HOSTNAME=""
GRUB_ENTRY_NAME=""
USERNAME=""
USER_PASSWORD=""
ROOT_PASSWORD=""
TIMEZONE="UTC"
LOCALE="en_US.UTF-8"
KEYMAP="us"

# Software
KERNEL="linux"
BOOTLOADER=""
SECURE_BOOT=false
DESKTOPS=()
AUR_HELPER="none"
USE_REFLECTOR=false
REFLECTOR_COUNTRIES="France,Germany"
REFLECTOR_AGE=12
REFLECTOR_NUMBER=10
REFLECTOR_PROTOCOL="https"
USE_MULTILIB=false
USE_PIPEWIRE=false
USE_NVIDIA=false
USE_AMD_VULKAN=false
USE_BLUETOOTH=false
USE_CUPS=false
USE_SNAPPER=false
FIREWALL="none"

# =============================================================================
#  LOGGING
# =============================================================================
LOG_FILE="/tmp/archwizard.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# =============================================================================
#  GUM THEME — central place to tweak all colours & widths
# =============================================================================
#  Gum uses Lip Gloss colour codes (256 / truecolour ANSI).
#  Override any of these at the top of the file to reskin the whole wizard.

# Accent colours (256-colour index for broadest terminal compat)
readonly GUM_C_TITLE="99"       # bright purple  — section headers
readonly GUM_C_OK="46"          # bright green   — success messages
readonly GUM_C_WARN="214"       # amber          — warnings
readonly GUM_C_ERR="196"        # bright red     — errors / fatal
readonly GUM_C_INFO="51"        # cyan           — info / hints
readonly GUM_C_DIM="242"        # grey           — secondary text
readonly GUM_C_ACCENT="141"     # lavender       — prompts / highlights

# Layout
readonly GUM_WIDTH=70           # default content width for styled boxes

# =============================================================================
#  GUM WRAPPER HELPERS
#  Drop-in replacements for the original ok/warn/error/section/info/ask/run
# =============================================================================

# ── section ───────────────────────────────────────────────────────────────────
# Prints a coloured banner to mark the start of each wizard section.
# Usage: section "Keyboard Layout"
section() {
    echo ""
    gum style \
        --foreground "$GUM_C_TITLE" \
        --bold \
        --border-foreground "$GUM_C_TITLE" \
        --border normal \
        --padding "0 1" \
        --width "$GUM_WIDTH" \
        "  ◆  $*"
    echo ""
}

# ── ok ────────────────────────────────────────────────────────────────────────
ok() {
    gum style --foreground "$GUM_C_OK" " ✔  $*"
}

# ── warn ──────────────────────────────────────────────────────────────────────
warn() {
    gum style --foreground "$GUM_C_WARN" " ⚠  $*"
}

# ── error ─────────────────────────────────────────────────────────────────────
# Writes to stderr like the original.
error() {
    gum style --foreground "$GUM_C_ERR" " ✗  $*" >&2
}

# ── info ──────────────────────────────────────────────────────────────────────
info() {
    gum style --foreground "$GUM_C_INFO" " ℹ  $*"
}

# ── log ───────────────────────────────────────────────────────────────────────
# Timestamped low-profile log line (goes to stdout / logfile, not gum styled
# to keep the log file clean and grep-friendly).
log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

# ── blank ─────────────────────────────────────────────────────────────────────
blank() { echo ""; }

# ── die ───────────────────────────────────────────────────────────────────────
# Fatal error: show a red bordered box then exit.
# Usage: die "Cannot continue because …"
die() {
    echo ""
    gum style \
        --foreground "$GUM_C_ERR" \
        --border-foreground "$GUM_C_ERR" \
        --border thick \
        --padding "0 2" \
        --width "$GUM_WIDTH" \
        "FATAL ERROR" \
        "" \
        "$*" \
        "" \
        "Log: $LOG_FILE"
    echo ""
    exit 1
}

# ── run ───────────────────────────────────────────────────────────────────────
# Central command executor — identical semantics to the original.
# In --dry-run mode it only prints; otherwise it logs and runs via eval.
run() {
    if [[ "$DRY_RUN" == true ]]; then
        gum style --faint " [dry-run] $*"
    else
        log "CMD: $*"
        eval "$@"
    fi
}

# ── run_spin ──────────────────────────────────────────────────────────────────
# Like run() but wraps the command in a gum spinner so the user knows
# something is happening during long operations (pacstrap, mkfs, …).
# Usage: run_spin "Formatting root partition…" "mkfs.btrfs -f /dev/sda2"
run_spin() {
    local title="$1"; shift
    if [[ "$DRY_RUN" == true ]]; then
        gum style --faint " [dry-run] $*"
    else
        log "CMD: $*"
        gum spin \
            --spinner dot \
            --title "$(gum style --foreground "$GUM_C_ACCENT" "$title")" \
            -- bash -c "$*"
    fi
}

# ── confirm_gum ───────────────────────────────────────────────────────────────
# Boolean yes/no prompt using gum confirm.
# Returns 0 for Yes, 1 for No — safe in `if` statements.
# Usage: if confirm_gum "Enable LUKS encryption?"; then …
confirm_gum() {
    gum confirm \
        --prompt.foreground "$GUM_C_ACCENT" \
        --selected.background "$GUM_C_TITLE" \
        --unselected.foreground "$GUM_C_DIM" \
        "$@"
}

# ── input_gum ─────────────────────────────────────────────────────────────────
# Single-line text input with an optional placeholder / default.
# Prints the entered value to stdout — capture with $().
# Usage: HOSTNAME=$(input_gum "Hostname" "archlinux")
input_gum() {
    local prompt="$1"
    local placeholder="${2:-}"
    gum input \
        --prompt "$(gum style --foreground "$GUM_C_ACCENT" " › ") " \
        --prompt.foreground "$GUM_C_ACCENT" \
        --placeholder "$placeholder" \
        --header "$(gum style --foreground "$GUM_C_INFO" "$prompt")" \
        --width "$GUM_WIDTH"
}

# ── password_gum ──────────────────────────────────────────────────────────────
# Password input (hidden). Confirms twice; loops until they match.
# Prints the password to stdout.
# Usage: USER_PASSWORD=$(password_gum "User password")
password_gum() {
    local prompt="$1"
    local pass1 pass2
    while true; do
        pass1=$(gum input \
            --password \
            --prompt "$(gum style --foreground "$GUM_C_ACCENT" " › ") " \
            --header "$(gum style --foreground "$GUM_C_INFO" "$prompt")" \
            --width "$GUM_WIDTH")
        pass2=$(gum input \
            --password \
            --prompt "$(gum style --foreground "$GUM_C_ACCENT" " › ") " \
            --header "$(gum style --foreground "$GUM_C_INFO" "Confirm: $prompt")" \
            --width "$GUM_WIDTH")
        if [[ "$pass1" == "$pass2" && -n "$pass1" ]]; then
            echo "$pass1"
            return
        fi
        warn "Passwords don't match or are empty — try again."
    done
}

# ── choose_one ────────────────────────────────────────────────────────────────
# Single-select list using gum choose.
# Prints the selected item to stdout.
# Usage: KERNEL=$(choose_one "linux" "linux" "linux-lts" "linux-zen" "linux-hardened")
#   arg1 = default (pre-selected item)
#   arg2+ = options
choose_one() {
    local default="$1"; shift
    gum choose \
        --selected "$default" \
        --selected.foreground "$GUM_C_TITLE" \
        --cursor.foreground "$GUM_C_ACCENT" \
        --height 10 \
        "$@"
}

# ── choose_many ───────────────────────────────────────────────────────────────
# Multi-select list using gum choose --no-limit.
# Prints one selected item per line.
# Usage: mapfile -t DESKTOPS < <(choose_many "kde" "kde" "gnome" "hyprland" …)
#   arg1 = default pre-selected item(s), comma-separated
#   arg2+ = options
choose_many() {
    local defaults="$1"; shift
    gum choose \
        --no-limit \
        --selected "$defaults" \
        --selected.foreground "$GUM_C_TITLE" \
        --cursor.foreground "$GUM_C_ACCENT" \
        --height 12 \
        "$@"
}

# =============================================================================
#  HELPER — part_name  (identical to original, no UI involved)
# =============================================================================
part_name() {
    local disk="$1" num="$2"
    if [[ "$disk" == *"nvme"* || "$disk" == *"mmcblk"* ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

# =============================================================================
#  BANNER
# =============================================================================
show_banner() {
    clear
    gum style \
        --foreground "$GUM_C_TITLE" \
        --bold \
        --border double \
        --border-foreground "$GUM_C_TITLE" \
        --padding "1 4" \
        --width "$GUM_WIDTH" \
        "$(printf '%s\n' \
            '█████╗ ██████╗  ██████╗██╗  ██╗' \
            '██╔══██╗██╔══██╗██╔════╝██║  ██║' \
            '███████║██████╔╝██║     ███████║' \
            '██╔══██║██╔══██╗██║     ██╔══██║' \
            '██║  ██║██║  ██║╚██████╗██║  ██║' \
            '╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝')" \
        "" \
        "$(gum style --foreground "$GUM_C_ACCENT" '✨  The most wonderful Arch Linux installer ever crafted  ✨')" \
        "" \
        "$(gum style --foreground "$GUM_C_DIM" "v5.5.0-gum  •  log: $LOG_FILE")"
    echo ""
}

# =============================================================================
#  SECTION 1 — PRE-FLIGHT SANITY CHECKS
# =============================================================================
sanity_checks() {
    section "Pre-flight Checks"

    # ── Root ─────────────────────────────────────────────────────────────────
    gum spin --spinner dot \
        --title "$(gum style --foreground "$GUM_C_ACCENT" "Checking root privileges…")" \
        -- sleep 0.3   # tiny pause so the spinner is visible
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root.\nBoot from the official Arch ISO and run it with: bash archwizard_gum.sh"
    fi
    ok "Running as root"

    # ── Firmware mode ────────────────────────────────────────────────────────
    gum spin --spinner dot \
        --title "$(gum style --foreground "$GUM_C_ACCENT" "Detecting firmware mode…")" \
        -- sleep 0.3
    if [[ -d /sys/firmware/efi/efivars ]]; then
        FIRMWARE_MODE="uefi"
        ok "Firmware: UEFI — full feature support (GRUB, systemd-boot, Secure Boot)"
    else
        FIRMWARE_MODE="bios"
        warn "Firmware: BIOS/Legacy — GRUB with MBR will be used."
        warn "systemd-boot and Secure Boot are NOT available in BIOS mode."
        warn "Dual-boot with UEFI systems on the same disk is NOT supported in BIOS mode."
    fi

    # ── Internet ─────────────────────────────────────────────────────────────
    local net_ok=false
    gum spin --spinner dot \
        --title "$(gum style --foreground "$GUM_C_ACCENT" "Testing internet connectivity…")" \
        -- bash -c '
            ping -c 1 -W 3 8.8.8.8 &>/dev/null || ping -c 1 -W 3 1.1.1.1 &>/dev/null
        ' && net_ok=true || true

    if [[ "$net_ok" == false ]]; then
        warn "No internet connection detected."
        blank

        # ── WiFi assistant ────────────────────────────────────────────────
        local wifi_ifaces=()
        while IFS= read -r iface; do
            [[ -z "$iface" ]] && continue
            wifi_ifaces+=("$iface")
        done < <(iw dev 2>/dev/null | awk '/Interface/{print $2}' || true)

        if [[ ${#wifi_ifaces[@]} -gt 0 ]]; then
            info "WiFi interface(s) detected: ${wifi_ifaces[*]}"
            blank
            gum style \
                --border normal \
                --border-foreground "$GUM_C_DIM" \
                --padding "0 2" \
                --width "$GUM_WIDTH" \
                "$(gum style --foreground "$GUM_C_INFO" --bold "Quick iwctl guide")" \
                "" \
                "  device list" \
                "  station ${wifi_ifaces[0]} scan" \
                "  station ${wifi_ifaces[0]} get-networks" \
                "  station ${wifi_ifaces[0]} connect \"YourSSID\"" \
                "  exit"
            blank

            if confirm_gum "Open iwctl now to connect to WiFi?"; then
                iwctl </dev/tty >/dev/tty 2>/dev/tty || true
                blank
                info "Checking connectivity after WiFi setup…"
                sleep 3
                if ping -c 1 -W 5 8.8.8.8 &>/dev/null || ping -c 1 -W 5 1.1.1.1 &>/dev/null; then
                    ok "Internet connection established via WiFi"
                    net_ok=true
                fi
            fi
        fi

        if [[ "$net_ok" == false ]]; then
            die "No internet connection.\nCheck your Ethernet cable or use: iwctl / nmtui / dhcpcd <iface>"
        fi
    else
        ok "Internet connection OK"
    fi

    # ── Required tools ───────────────────────────────────────────────────────
    local missing=() tools=(sgdisk mkfs.fat mkfs.btrfs arch-chroot pacstrap genfstab blkid lsblk)
    gum spin --spinner dot \
        --title "$(gum style --foreground "$GUM_C_ACCENT" "Checking required tools…")" \
        -- bash -c '
            for t in sgdisk mkfs.fat mkfs.btrfs arch-chroot pacstrap genfstab blkid lsblk; do
                command -v "$t" &>/dev/null || echo "$t"
            done
        ' | mapfile -t missing || true

    # Re-check synchronously so we capture the array in the current shell
    missing=()
    for t in "${tools[@]}"; do
        command -v "$t" &>/dev/null || missing+=("$t")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required tools: ${missing[*]}\nBoot from the official Arch ISO."
    fi
    ok "All required tools present"

    # ── CPU microcode detection ───────────────────────────────────────────────
    if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
        CPU_VENDOR="intel"
    elif grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
        CPU_VENDOR="amd"
    fi
    ok "CPU vendor: ${CPU_VENDOR}"

    # ── GPU detection ────────────────────────────────────────────────────────
    if lspci 2>/dev/null | grep -qi "nvidia"; then
        GPU_VENDOR="nvidia"
        ok "GPU detected: NVIDIA (proprietary drivers available)"
    elif lspci 2>/dev/null | grep -qi "amd.*vga\|vga.*amd\|radeon"; then
        GPU_VENDOR="amd"
        ok "GPU detected: AMD Radeon"
    elif lspci 2>/dev/null | grep -qi "intel.*vga\|vga.*intel"; then
        GPU_VENDOR="intel"
        ok "GPU detected: Intel"
    else
        warn "GPU vendor could not be determined"
    fi

    # ── NTP ──────────────────────────────────────────────────────────────────
    # Fire and forget — timedatectl can block 10–30s on the live ISO
    timedatectl set-ntp true &>/dev/null & disown
    ok "NTP sync requested (background)"
}

# =============================================================================
#  SECTION 2 — KEYBOARD LAYOUT
# =============================================================================
choose_keyboard() {
    section "Keyboard Layout"

    info "Choose your console keymap. Common choices are listed below."
    info "French users: use 'fr-latin1', not 'fr'."
    blank

    # Curated list of the most common keymaps offered as a quick-pick.
    # The user can also type any keymap name manually at the bottom of the list.
    local common_keymaps=(
        "us          — US QWERTY (default)"
        "fr-latin1   — French AZERTY"
        "de-latin1   — German QWERTZ"
        "uk          — British QWERTY"
        "es          — Spanish"
        "it          — Italian"
        "be-latin1   — Belgian AZERTY"
        "ru          — Russian"
        "dvorak      — Dvorak"
        "colemak     — Colemak"
        "Other…      — type manually"
    )

    local selection
    selection=$(choose_one "fr-latin1   — French AZERTY" "${common_keymaps[@]}")

    if [[ "$selection" == "Other…"* ]]; then
        # Manual entry with live validation hint
        KEYMAP=$(input_gum \
            "Enter keymap name (e.g. fr-latin1, pl2, jp106)" \
            "fr-latin1")
    else
        # Extract the keymap token (everything before the first space)
        KEYMAP=$(echo "$selection" | awk '{print $1}')
    fi

    # Validate against the real keymap file tree (no D-Bus needed)
    if find /usr/share/kbd/keymaps \
            -name "${KEYMAP}.map.gz" \
            -o -name "${KEYMAP}.map" \
            2>/dev/null | grep -q .; then
        run "loadkeys $KEYMAP"
        ok "Keyboard layout set to: ${KEYMAP}"
    else
        warn "Layout '${KEYMAP}' not found — falling back to 'us'."
        warn "Tip: fr-latin1 for French, de-latin1 for German, uk for British."
        KEYMAP="us"
        run "loadkeys us"
    fi
}

# =============================================================================
#  ARGUMENT PARSING
# =============================================================================
parse_args() {
    local _prev=""
    for arg in "$@"; do
        case "$arg" in
            --dry-run)       DRY_RUN=true ;;
            --verbose)       VERBOSE=true ;;
            --load-config)   : ;;
            --help|-h)
                gum style \
                    --border normal \
                    --border-foreground "$GUM_C_TITLE" \
                    --padding "0 2" \
                    --width "$GUM_WIDTH" \
                    "Usage: bash archwizard_gum.sh [OPTIONS]" \
                    "" \
                    "  --dry-run           Show commands without executing" \
                    "  --verbose           Print every command (set -x)" \
                    "  --load-config FILE  Load saved config, skip Phase 1" \
                    "  --help              This message"
                exit 0 ;;
            *)
                [[ "$_prev" == "--load-config" ]] && CONFIG_FILE="$arg"
                ;;
        esac
        _prev="$arg"
    done
    [[ "$VERBOSE" == true ]] && set -x
}

# =============================================================================
#  MAIN
# =============================================================================
main() {
    parse_args "$@"

    show_banner

    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN mode: no changes will be written to disk."
    [[ "$VERBOSE" == true ]] && warn "VERBOSE mode: every command will be printed."

    # ── PHASE 1: Gather information ───────────────────────────────────────────
    sanity_checks
    choose_keyboard

    # ── Placeholder: next steps will be added here ────────────────────────────
    blank
    gum style \
        --foreground "$GUM_C_DIM" \
        --border normal \
        --border-foreground "$GUM_C_DIM" \
        --padding "0 2" \
        --width "$GUM_WIDTH" \
        "Step 1 complete — sanity checks & keyboard done." \
        "" \
        "Next: Step 2 (disk discovery & selection) not yet implemented." \
        "Run this script again after each new step is added."
    blank
}

main "$@"
