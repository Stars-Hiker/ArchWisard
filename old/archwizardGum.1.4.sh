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
#  Version : 5.5.0-gum-1.4.0
#  License : MIT
#  Depends : gum (https://github.com/charmbracelet/gum)
#  Usage   : bash archwizard_gum.sh [--dry-run] [--verbose] [--load-config FILE]
#
#  Changes in 1.4.0:
#    [fix] ROOT CAUSE of silent crash — bare [[ ]] && returns exit 1 under set -e
#          All such patterns converted to if/then/fi throughout the file.
#    [new] Main menu — run all steps in sequence OR jump to any individual step.
#          Each menu entry shows a live summary of choices already made.
#          After each step the script returns to the menu automatically.
#    [new] Step 3 — partition_wizard fully rewritten: clean section flow,
#          strict GB validation, correct avail_gb accounting, no "rest" ambiguity.
#    [new] Step 6 — choose_kernel + choose_bootloader
#    [new] Step 7 — choose_desktop  (gum choose --no-limit multi-select)
#    [new] Step 8 — choose_extras   (reflector, multilib, audio, GPU, BT, CUPS,
#                                    snapper, firewall, AUR helper)
#
#  Build status:
#    [x] Step 1 — Sanity checks & keyboard layout
#    [x] Step 2 — Disk discovery & selection
#    [x] Step 3 — Partition wizard
#    [x] Step 4 — System identity (hostname, timezone, locale)
#    [x] Step 5 — Users & passwords
#    [x] Step 6 — Kernel & bootloader
#    [x] Step 7 — Desktop environment
#    [x] Step 8 — Optional extras
#    [ ] Phase 2 — Summary & confirmation
#    [ ] Phase 3-6 — Partitioning, install, chroot, cleanup
# =============================================================================

set -euo pipefail

# LOG_FILE must be defined before any trap that references it
LOG_FILE="/tmp/archwizard.log"
: > "$LOG_FILE"

# =============================================================================
#  GUM PRE-FLIGHT  — must run BEFORE any gum call, using plain bash only
#  FIX: without this check, the script exits silently if gum is missing
#       because the ERR trap itself calls gum → double crash → nothing visible
# =============================================================================
if ! command -v gum &>/dev/null; then
    printf '\n\033[1;31m[FATAL]\033[0m gum is not installed.\n'
    printf '        Install it with:  paru -S gum\n'
    printf '        Or on Arch ISO:   pacman -Sy gum\n\n'
    exit 1
fi

# ── Error trap ────────────────────────────────────────────────────────────────
# Plain bash only — gum must never be called inside a trap.
# If gum itself crashed, calling it again in the trap causes a silent double-fault.
trap 'RC=$?
      echo "CRASH line=$LINENO exit=$RC cmd=${BASH_COMMAND}" >> "$LOG_FILE"
      printf "\n\033[1;31m[FATAL]\033[0m Crashed at line %s (exit %s)\n" "$LINENO" "$RC" >&2
      printf "        cmd : %s\n" "${BASH_COMMAND}" >&2
      printf "        log : %s\n\n" "$LOG_FILE" >&2' ERR



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

# (LOG_FILE initialised at top of script, before any trap)

# =============================================================================
#  GUM THEME — central place to tweak all colours & widths
# =============================================================================
readonly GUM_C_TITLE="99"       # bright purple  — section headers
readonly GUM_C_OK="46"          # bright green   — success messages
readonly GUM_C_WARN="214"       # amber          — warnings
readonly GUM_C_ERR="196"        # bright red     — errors / fatal
readonly GUM_C_INFO="51"        # cyan           — info / hints
readonly GUM_C_DIM="242"        # grey           — secondary text
readonly GUM_C_ACCENT="141"     # lavender       — prompts / highlights

readonly GUM_WIDTH=70           # default content width for styled boxes

# ── _clr — inline ANSI 256-color, no gum required ────────────────────────────
# Usage: _clr COLOR_NUMBER "text"   →  outputs colored text + reset
# Used as argument to gum style to avoid nested $(gum style) subshells,
# which crash with set -e when stdout is piped or terminal is unavailable.
_clr() { printf '\033[38;5;%sm%s\033[0m' "$1" "$2"; }

# =============================================================================
#  GUM WRAPPER HELPERS
# =============================================================================

section() {
    echo ""
    gum style \
        --foreground "$GUM_C_TITLE" \
        --bold \
        --border-foreground "$GUM_C_TITLE" \
        --border normal \
        --padding "0 1" \
        --width "$GUM_WIDTH" \
        "  ◆  $*" || printf '\033[1;35m══  %s  ══\033[0m\n' "$*"
    echo ""
}

ok()    { gum style --foreground "$GUM_C_OK"   " ✔  $*" || printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*"; }
warn()  { gum style --foreground "$GUM_C_WARN" " ⚠  $*" || printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
error() { gum style --foreground "$GUM_C_ERR"  " ✗  $*" >&2 || printf '\033[0;31m[ERR ]\033[0m  %s\n' "$*" >&2; }
info()  { gum style --foreground "$GUM_C_INFO" " ℹ  $*" || printf '\033[0;36m[INFO]\033[0m  %s\n' "$*"; }
log()   { local m="[$(date '+%H:%M:%S')] $*"; echo "$m"; echo "$m" >> "$LOG_FILE"; }
blank() { echo ""; }

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
        "Log: $LOG_FILE" || \
    printf '\033[1;31m[FATAL]\033[0m %s\n        Log: %s\n' "$*" "$LOG_FILE" >&2
    echo ""
    exit 1
}

run() {
    if [[ "$DRY_RUN" == true ]]; then
        gum style --faint " [dry-run] $*" || printf '[dry-run] %s\n' "$*"
    else
        log "CMD: $*"
        eval "$@" 2>&1 | tee -a "$LOG_FILE"
    fi
}

run_spin() {
    local title="$1"; shift
    if [[ "$DRY_RUN" == true ]]; then
        gum style --faint " [dry-run] $*"
    else
        log "CMD: $*"
        # NOTE: --title must be a plain string — never $(gum style ...) here.
        # Nested gum subshells crash with set -e when stdout is piped (no TTY).
        # LOG_FILE uses double-quote expansion inside the bash -c string.
        gum spin \
            --spinner dot \
            --title " $title" \
            -- bash -c "$* 2>&1 | tee -a \"$LOG_FILE\""
    fi
}

confirm_gum() {
    gum confirm \
        --prompt.foreground "$GUM_C_ACCENT" \
        --selected.background "$GUM_C_TITLE" \
        --unselected.foreground "$GUM_C_DIM" \
        "$@"
}

input_gum() {
    local prompt="$1"
    local placeholder="${2:-}"
    gum input \
        --prompt " › " \
        --prompt.foreground "$GUM_C_ACCENT" \
        --placeholder "$placeholder" \
        --header "$prompt" \
        --header.foreground "$GUM_C_INFO" \
        --width "$GUM_WIDTH"
}

password_gum() {
    local prompt="$1"
    local pass1 pass2
    while true; do
        pass1=$(gum input \
            --password \
            --prompt " › " \
            --prompt.foreground "$GUM_C_ACCENT" \
            --header "$prompt" \
            --header.foreground "$GUM_C_INFO" \
            --width "$GUM_WIDTH")
        pass2=$(gum input \
            --password \
            --prompt " › " \
            --prompt.foreground "$GUM_C_ACCENT" \
            --header "Confirm: $prompt" \
            --header.foreground "$GUM_C_INFO" \
            --width "$GUM_WIDTH")
        if [[ "$pass1" == "$pass2" && -n "$pass1" ]]; then
            echo "$pass1"
            return
        fi
        warn "Passwords don't match or are empty — try again."
    done
}

choose_one() {
    # $1 = preferred default (must exactly match one of the remaining args)
    # $2..N = items to display
    # If default doesn't match any item, gum choose --selected exits 1 with set -e.
    # We only pass --selected when we can confirm an exact match.
    local default="$1"; shift
    local match=false
    for item in "$@"; do
        [[ "$item" == "$default" ]] && match=true && break
    done
    if [[ "$match" == true ]]; then
        gum choose \
            --selected "$default" \
            --selected.foreground "$GUM_C_TITLE" \
            --cursor.foreground "$GUM_C_ACCENT" \
            --height 10 \
            "$@"
    else
        gum choose \
            --selected.foreground "$GUM_C_TITLE" \
            --cursor.foreground "$GUM_C_ACCENT" \
            --height 10 \
            "$@"
    fi
}

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
#  HELPER — part_name
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
#  HELPER — _is_protected (identical to original)
# =============================================================================
_is_protected() {
    local p="$1"
    for pp in "${PROTECTED_PARTS[@]+${PROTECTED_PARTS[@]}}"; do
        [[ "$pp" == "$p" ]] && return 0
    done
    return 1
}

# =============================================================================
#  HELPER — probe_os_from_part (identical to original)
# =============================================================================
PROBE_OS_RESULT=""
probe_os_from_part() {
    local p="$1"
    PROBE_OS_RESULT=""

    local fstype
    fstype=$(blkid -s TYPE -o value "$p" 2>/dev/null || echo "")

    [[ "$fstype" == "crypto_LUKS" ]] && { PROBE_OS_RESULT="[LUKS encrypted]"; return; }

    local mnt="/tmp/_aw_probe_$$"
    mkdir -p "$mnt"

    # A. Plain mount attempt
    if mount -o ro,noexec,nosuid,nodev "$p" "$mnt" &>/dev/null; then
        _probe_read_os "$mnt"
        umount "$mnt" 2>/dev/null || true
        rmdir "$mnt" 2>/dev/null || true
        [[ -n "$PROBE_OS_RESULT" ]] && return
    fi

    # B. btrfs subvolume fallback
    if [[ "$fstype" == "btrfs" ]]; then
        for sv in @ @root root arch debian ubuntu fedora opensuse; do
            if mount -o "ro,subvol=${sv}" "$p" "$mnt" &>/dev/null; then
                _probe_read_os "$mnt"
                umount "$mnt" 2>/dev/null || true
                [[ -n "$PROBE_OS_RESULT" ]] && { rmdir "$mnt" 2>/dev/null || true; return; }
            fi
        done
    fi

    rmdir "$mnt" 2>/dev/null || true

    # C. Label / fstype fallback
    local lbl
    lbl=$(blkid -s LABEL -o value "$p" 2>/dev/null || echo "")
    [[ -n "$lbl" ]] && { PROBE_OS_RESULT="[$lbl]"; return; }
    [[ -n "$fstype" ]] && { PROBE_OS_RESULT="[$fstype]"; return; }
}

_probe_read_os() {
    local mnt="$1"
    if [[ -f "$mnt/etc/os-release" ]]; then
        PROBE_OS_RESULT=$(awk -F= '/^PRETTY_NAME/{gsub(/"/, "", $2); print $2}' \
                          "$mnt/etc/os-release" 2>/dev/null || echo "")
    fi
}

# =============================================================================
#  BANNER
# =============================================================================
show_banner() {
    printf '\n\033[1;35m[ ArchWizard gum edition — starting ]\033[0m\n\n' >&2

    gum style \
        --foreground "$GUM_C_TITLE" \
        --bold \
        --border double \
        --border-foreground "$GUM_C_TITLE" \
        --padding "1 4" \
        --width "$GUM_WIDTH" \
        "ARCH WIZARD" \
        "v5.5.0-gum-1.2.4" \
        "" \
        "The most wonderful Arch Linux installer ever crafted" \
        "" \
        "log: $LOG_FILE" || \
    printf '\033[1;35m  ARCH WIZARD  v5.5.0-gum-1.2.4\033[0m\n  log: %s\n\n' "$LOG_FILE"
    echo ""
}

# =============================================================================
#  SECTION 1 — PRE-FLIGHT SANITY CHECKS
# =============================================================================
sanity_checks() {
    section "Pre-flight Checks"

    gum spin --spinner dot --title " Checking root privileges…" -- sleep 0.3 || true
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root.\nBoot from the official Arch ISO and run it with: bash archwizard_gum.sh"
    fi
    ok "Running as root"

    gum spin --spinner dot --title " Detecting firmware mode…" -- sleep 0.3 || true
    if [[ -d /sys/firmware/efi/efivars ]]; then
        FIRMWARE_MODE="uefi"
        ok "Firmware: UEFI — full feature support (GRUB, systemd-boot, Secure Boot)"
    else
        FIRMWARE_MODE="bios"
        warn "Firmware: BIOS/Legacy — GRUB with MBR will be used."
        warn "systemd-boot and Secure Boot are NOT available in BIOS mode."
        warn "Dual-boot with UEFI systems on the same disk is NOT supported in BIOS mode."
    fi

    # Test connectivity directly (never inside gum spin — piped stdout breaks gum)
    local net_ok=false
    if ping -c 1 -W 3 8.8.8.8 &>/dev/null || ping -c 1 -W 3 1.1.1.1 &>/dev/null; then
        net_ok=true
    fi

    if [[ "$net_ok" == false ]]; then
        warn "No internet connection detected."
        blank

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
                "$(_clr "$GUM_C_INFO" "Quick iwctl guide")" \
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

    local missing=() tools=(sgdisk mkfs.fat mkfs.btrfs arch-chroot pacstrap genfstab blkid lsblk)
    gum spin --spinner dot --title " Checking required tools…" -- sleep 0.3 || true

    missing=()
    for t in "${tools[@]}"; do
        command -v "$t" &>/dev/null || missing+=("$t")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required tools: ${missing[*]}\nBoot from the official Arch ISO."
    fi
    ok "All required tools present"

    if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
        CPU_VENDOR="intel"
    elif grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
        CPU_VENDOR="amd"
    fi
    ok "CPU vendor: ${CPU_VENDOR}"

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
        KEYMAP=$(input_gum \
            "Enter keymap name (e.g. fr-latin1, pl2, jp106)" \
            "fr-latin1")
    else
        KEYMAP=$(echo "$selection" | awk '{print $1}')
    fi

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
#  SECTION 3 — DISK DISCOVERY
# =============================================================================

# ── _disk_table ───────────────────────────────────────────────────────────────
# Renders a gum-styled table of all block devices with enriched metadata.
# Colour legend: NVMe/SSD → accent, HDD → warn, USB → dim.
_disk_table() {
    local rows=()
    while IFS= read -r dev; do
        local name size rota tran pttype model media
        name=$(lsblk   -dno NAME    "/dev/${dev}" 2>/dev/null)
        size=$(lsblk   -dno SIZE    "/dev/${dev}" 2>/dev/null)
        rota=$(lsblk   -dno ROTA    "/dev/${dev}" 2>/dev/null)
        tran=$(lsblk   -dno TRAN    "/dev/${dev}" 2>/dev/null)
        pttype=$(lsblk -dno PTTYPE  "/dev/${dev}" 2>/dev/null)
        model=$(lsblk  -dno MODEL   "/dev/${dev}" 2>/dev/null | cut -c1-22)
        if   [[ "$tran" == "nvme" ]]; then media="NVMe"
        elif [[ "$rota" == "0"   ]]; then media="SSD"
        elif [[ "$tran" == "usb" ]]; then media="USB"
        else                              media="HDD"; fi
        rows+=("$(printf '%-14s  %-7s  %-5s  %-6s  %-5s  %-22s' \
            "/dev/${name}" "${size}" "${media}" \
            "${tran:---}" "${pttype:---}" "${model:-Unknown}")")
    done < <(lsblk -d -n -o NAME 2>/dev/null | grep -v "^loop\|^sr")

    gum style \
        --border rounded \
        --border-foreground "$GUM_C_TITLE" \
        --padding "0 1" \
        --width "$GUM_WIDTH" \
        "$(_clr "$GUM_C_ACCENT" "$(printf '%-14s  %-7s  %-5s  %-6s  %-5s  %-22s' DEVICE SIZE TYPE TRAN TABLE MODEL)")" \
        "$(_clr "$GUM_C_DIM"    "$(printf '%-14s  %-7s  %-5s  %-6s  %-5s  %-22s' '──────────────' '───────' '─────' '──────' '─────' '──────────────────────')")" \
        "${rows[@]}" || true
}

# ── _disk_partitions ──────────────────────────────────────────────────────────
# Renders per-disk partition info (lsblk tree) for all non-loop block devices.
_disk_partitions() {
    while IFS= read -r dev; do
        local has_parts
        has_parts=$(lsblk -n -o NAME "/dev/${dev}" 2>/dev/null | tail -n +2)
        [[ -z "$has_parts" ]] && continue

        gum style --foreground "$GUM_C_INFO" --bold "  /dev/${dev}"
        lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "/dev/${dev}" 2>/dev/null \
            | tail -n +2 \
            | while IFS= read -r line; do
                gum style --foreground "$GUM_C_DIM" "    $line"
              done
        blank
    done < <(lsblk -d -n -o NAME 2>/dev/null | grep -v "^loop\|^sr")
}

# ── discover_disks ────────────────────────────────────────────────────────────
discover_disks() {
    section "Disk Discovery"

    gum spin --spinner dot --title " Scanning block devices…" -- sleep 0.5 || true

    _disk_table
    blank

    info "Existing partitions:"
    blank
    _disk_partitions

    # ── OS detection ──────────────────────────────────────────────────────
    gum spin --spinner dot --title " Probing for existing operating systems…" -- sleep 0.3 || true

    local _mounted_devs
    _mounted_devs=$(awk '{print $1}' /proc/mounts 2>/dev/null | sort -u)

    local _candidates=()
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        echo "$_mounted_devs" | grep -qxF "$p" && continue
        [[ "$p" == /dev/loop* || "$p" == /dev/sr* ]] && continue
        local _pb
        _pb=$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)
        (( _pb < 1073741824 )) && continue
        _candidates+=("$p")
    done < <({ blkid -t TYPE="ext4"        -o device 2>/dev/null
               blkid -t TYPE="btrfs"       -o device 2>/dev/null
               blkid -t TYPE="xfs"         -o device 2>/dev/null
               blkid -t TYPE="f2fs"        -o device 2>/dev/null
               blkid -t TYPE="crypto_LUKS" -o device 2>/dev/null; } | sort -u)

    local _found_names=() _found_parts=()
    for p in "${_candidates[@]}"; do
        probe_os_from_part "$p" || true
        if [[ -n "$PROBE_OS_RESULT" ]]; then
            _found_names+=("$PROBE_OS_RESULT")
            _found_parts+=("$p")
        fi
    done

    # UEFI NVRAM supplement
    local _bl="BootManager|BootApp|EFI Default|SortOrder"
    _bl+="|^Windows|ArchWizard"
    _bl+="|^UEFI[[:space:]]|^UEFI:|Firmware|Setup|Admin"
    _bl+="|^Shell|^EFI Shell"
    _bl+="|PXE|iPXE|Network|LAN|WAN"
    _bl+="|Diagnostic|MemTest|Memory Test|Memory Check"
    _bl+="|USB|CD-ROM|DVD|Optical|SD Card|Card Reader"
    _bl+="|Recovery|Maintenance|Internal|Application|Menu|Manager"
    if command -v efibootmgr &>/dev/null; then
        while IFS= read -r line; do
            local _lbl
            _lbl=$(echo "$line" \
                   | sed 's/Boot[0-9A-Fa-f]*\*[[:space:]]*//' \
                   | sed 's/[[:space:]]*[A-Z][A-Z](.*$//'     \
                   | sed 's/[[:space:]]*$//')
            [[ -z "$_lbl" || ${#_lbl} -lt 2 ]] && continue
            echo "$_lbl" | grep -q '[a-zA-Z]' || continue
            echo "$_lbl" | grep -qiE "$_bl"   && continue
            echo "$_lbl" | grep -qi "windows"  && continue
            local _seen=false
            for n in "${_found_names[@]}"; do
                echo "$n" | grep -qi "$_lbl" && _seen=true && break
            done
            if [[ "$_seen" == false ]]; then
                _found_names+=("$_lbl")
                _found_parts+=("")
            fi
        done < <(efibootmgr 2>/dev/null | grep -E '^Boot[0-9A-Fa-f]{4}' || true)
    fi

    # Windows / NTFS
    local _win_parts=()
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        _win_parts+=("$p")
    done < <(blkid -t TYPE="ntfs" -o device 2>/dev/null || true)
    for p in "${_win_parts[@]}"; do
        _found_names+=("Windows")
        _found_parts+=("$p")
    done

    # ── Existing OS display + dual-boot prompt ────────────────────────────
    if [[ ${#_found_names[@]} -gt 0 ]]; then
        blank
        warn "Existing OS(es) detected on this machine:"
        blank

        local os_lines=()
        for i in "${!_found_names[@]}"; do
            local _pinfo=""
            if [[ -n "${_found_parts[$i]}" ]]; then
                local _psize
                _psize=$(lsblk -dno SIZE "${_found_parts[$i]}" 2>/dev/null || echo "?")
                _pinfo="  (${_found_parts[$i]}, ${_psize})"
            fi
            os_lines+=("  →  ${_found_names[$i]}${_pinfo}")
        done

        gum style \
            --border normal \
            --border-foreground "$GUM_C_WARN" \
            --padding "0 2" \
            --width "$GUM_WIDTH" \
            "${os_lines[@]}"
        blank

        if confirm_gum "Install Arch Linux alongside these system(s)?"; then
            DUAL_BOOT=true
            for n in "${_found_names[@]}"; do
                echo "$n" | grep -qi "windows" && EXISTING_WINDOWS=true
                echo "$n" | grep -qi "windows" || EXISTING_LINUX=true
                EXISTING_SYSTEMS+=("$n")
            done
            ok "Multi-boot mode enabled — existing partitions will be preserved"
            blank
            gum style \
                --foreground "$GUM_C_INFO" \
                --border normal \
                --border-foreground "$GUM_C_INFO" \
                --padding "0 2" \
                --width "$GUM_WIDTH" \
                "  GRUB + os-prober will be strongly recommended as bootloader."
            blank
        fi
    fi

    # ── EFI partition detection (dual-boot mode) ──────────────────────────
    if [[ "$DUAL_BOOT" == true ]]; then
        local efi_list=()
        while IFS= read -r p; do
            local pttype_p size_mb
            pttype_p=$(lsblk -no PARTTYPE "$p" 2>/dev/null || echo "")
            size_mb=$(( $(blockdev --getsize64 "$p" 2>/dev/null || echo 0) / 1048576 ))
            if [[ "$pttype_p" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] \
               || (( size_mb <= 1024 )); then
                efi_list+=("$p")
            fi
        done < <(blkid -t TYPE="vfat" -o device 2>/dev/null || true)

        if [[ ${#efi_list[@]} -gt 0 ]]; then
            info "Detected EFI System Partition(s):"
            blank
            for p in "${efi_list[@]}"; do
                local _esize _elabel
                _esize=$(lsblk -dno SIZE "$p" 2>/dev/null || echo "?")
                _elabel=$(blkid -s LABEL -o value "$p" 2>/dev/null || echo "")
                gum style --foreground "$GUM_C_INFO" \
                    "  →  $p  (${_esize})${_elabel:+  label: $_elabel}"
            done
            blank

            if [[ ${#efi_list[@]} -eq 1 ]]; then
                EFI_PART="${efi_list[0]}"
                REUSE_EFI=true
                ok "Using existing EFI partition: ${EFI_PART} — shared between OSes"
            else
                if confirm_gum "Reuse the existing EFI partition? (Strongly recommended for multi-boot)"; then
                    REUSE_EFI=true
                    info "Select which EFI partition to use:"
                    blank
                    EFI_PART=$(choose_one "${efi_list[0]}" "${efi_list[@]}")
                    local _efsz
                    _efsz=$(lsblk -dno SIZE "$EFI_PART" 2>/dev/null || echo "?")
                    ok "Will reuse EFI: ${EFI_PART}  (${_efsz})"
                fi
            fi
        fi
    fi
}

# =============================================================================
#  SECTION 4 — DISK SELECTION
# =============================================================================

# ── _check_and_plan_space ─────────────────────────────────────────────────────
# Analyses free space on $DISK_ROOT. If insufficient, offers to:
#   A) switch to a different disk
#   B) delete a partition entirely
#   C) shrink an existing partition
# Sets FREE_GB_AVAIL, and optionally REPLACE_PART / RESIZE_PART / RESIZE_NEW_GB.
_check_and_plan_space() {
    local disk="$1"
    local NEEDED_GB=7

    # ── Measure unallocated space ─────────────────────────────────────────
    local total_free_bytes=0
    while IFS= read -r line; do
        local fb
        fb=$(echo "$line" | awk '{print $3}' | tr -d 'B')
        total_free_bytes=$(( total_free_bytes + ${fb:-0} ))
    done < <(parted -s "$disk" unit B print free 2>/dev/null | grep "Free Space" || true)
    local free_gb=$(( total_free_bytes / 1073741824 ))

    # ── Count reclaimable (disposable) partitions ─────────────────────────
    local disposable_parts=()
    local disposable_gb=0
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        local _pt _pb _pb_gb
        _pt=$(lsblk -no PARTTYPE "$p" 2>/dev/null || echo "")
        _pb=$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)
        _pb_gb=$(( _pb / 1073741824 ))
        [[ "$_pt" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] && continue
        [[ "$_pt" == "0657fd6d-a4ab-43c4-84e5-0933c84b4f4f" ]] && continue
        (( _pb_gb < 1 )) && continue
        _is_protected "$p" && continue
        disposable_parts+=("$p")
        disposable_gb=$(( disposable_gb + _pb_gb ))
    done < <(lsblk -ln -o PATH "$disk" 2>/dev/null | tail -n +2)

    local total_avail_gb=$(( free_gb + disposable_gb ))
    FREE_GB_AVAIL=$total_avail_gb

    # ── Space analysis panel ──────────────────────────────────────────────
    section "Space Analysis — ${disk}"

    local info_lines=(
        "$(_clr "$GUM_C_INFO" "  Unallocated space:        ${free_gb} GB")"
        "$(_clr "$GUM_C_INFO" "  Minimum needed:           ${NEEDED_GB} GB")"
    )
    if [[ ${#disposable_parts[@]} -gt 0 ]]; then
        info_lines+=(
            "$(_clr "$GUM_C_WARN" "  Reclaimable (unneeded):   ${disposable_gb} GB  (${disposable_parts[*]})")"
            "$(_clr "$GUM_C_OK"   "  Total available for Arch: ${total_avail_gb} GB")"
        )
    fi
    gum style \
        --border rounded \
        --border-foreground "$GUM_C_DIM" \
        --padding "0 1" \
        --width "$GUM_WIDTH" \
        "${info_lines[@]}"
    blank

    # ── Case A: already enough free space ────────────────────────────────
    if (( free_gb >= NEEDED_GB )); then
        ok "Sufficient unallocated space (${free_gb} GB ≥ ${NEEDED_GB} GB)."
        ok "Arch Linux partitions will be created in that unallocated space."
        blank
        return
    fi

    # ── Case B: enough if we delete disposable partitions ────────────────
    if (( total_avail_gb >= NEEDED_GB && ${#disposable_parts[@]} > 0 )); then
        ok "Enough space by deleting unneeded partitions."
        blank
        for p in "${disposable_parts[@]}"; do
            local _n _s
            probe_os_from_part "$p" || true
            _n="${PROBE_OS_RESULT:-partition}"
            _s=$(lsblk -dno SIZE "$p" 2>/dev/null || echo "?")
            warn "  Will DELETE: ${p}  (${_s})  — ${_n}"
        done
        blank
        REPLACE_PART="${disposable_parts[0]}"
        REPLACE_PARTS_ALL=("${disposable_parts[@]}")
        FREE_GB_AVAIL=$total_avail_gb
        warn "Deletions will happen after you confirm the installation summary."
        blank
        return
    fi

    # ── Not enough space — need user action ───────────────────────────────
    gum style \
        --foreground "$GUM_C_WARN" \
        --border thick \
        --border-foreground "$GUM_C_WARN" \
        --padding "0 2" \
        --width "$GUM_WIDTH" \
        "Not enough space even after reclaiming unneeded partitions." \
        "(${total_avail_gb} GB available < ${NEEDED_GB} GB needed)"
    blank

    # Build candidate list (path|fstype|size_gb|os_name)
    local candidates=()
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        local pt ft pb pb_gb
        pt=$(lsblk  -no PARTTYPE "$p" 2>/dev/null || echo "")
        ft=$(blkid  -s TYPE -o value "$p" 2>/dev/null || echo "")
        pb=$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)
        pb_gb=$(( pb / 1073741824 ))
        [[ "$pt" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] && continue
        _is_protected "$p" && continue
        (( pb_gb < 1 )) && continue
        probe_os_from_part "$p" || true
        local os_n="${PROBE_OS_RESULT:-}"
        if [[ "$ft" == "swap" ]]; then os_n="[swap]"; fi
        candidates+=("$p|$ft|$pb_gb|${os_n}")
    done < <(lsblk -ln -o PATH "$disk" 2>/dev/null | tail -n +2)

    # If all partitions are protected, add them as shrink-only candidates
    if [[ ${#candidates[@]} -eq 0 ]]; then
        warn "All partitions on ${disk} are marked as 'keep'."
        warn "To install Arch you must SHRINK one of them."
        blank
        for _pp in "${PROTECTED_PARTS[@]+${PROTECTED_PARTS[@]}}"; do
            local _ft _pb_gb
            _ft=$(blkid -s TYPE -o value "$_pp" 2>/dev/null || echo "?")
            _pb_gb=$(( $(blockdev --getsize64 "$_pp" 2>/dev/null || echo 0) / 1073741824 ))
            candidates+=("$_pp|$_ft|$_pb_gb|[kept OS — shrink to make space]")
        done
    fi

    if [[ ${#candidates[@]} -eq 0 ]]; then
        warn "No suitable partitions found on ${disk}."
        warn "Tip: use GParted live to free space, then re-run ArchWizard."
        FREE_GB_AVAIL=0
        return 0
    fi

    # Collect other disks large enough to host Arch
    local other_disks=()
    while IFS= read -r dev; do
        [[ "/dev/$dev" == "$disk" ]] && continue
        local ob
        ob=$(blockdev --getsize64 "/dev/$dev" 2>/dev/null || echo 0)
        if [[ $(( ob / 1073741824 )) -ge $NEEDED_GB ]]; then
            other_disks+=("/dev/$dev")
        fi
    done < <(lsblk -d -n -o NAME 2>/dev/null | grep -v "^loop\|^sr")

    # ── Space option menu ─────────────────────────────────────────────────
    info "How do you want to make space for Arch Linux?"
    blank
    local space_opts=()
    if [[ ${#other_disks[@]} -gt 0 ]]; then
        space_opts+=("Use a different disk entirely")
    fi

    local _has_unprotected=false
    for _c in "${candidates[@]}"; do
        local _cp="${_c%%|*}"
        if ! _is_protected "$_cp"; then
            _has_unprotected=true
            break
        fi
    done
    if [[ "$_has_unprotected" == true ]]; then
        space_opts+=("Replace a partition (delete it — ALL DATA LOST)")
    fi
    space_opts+=("Shrink a partition  (keep data, reduce size)")

    local space_choice
    space_choice=$(choose_one "${space_opts[0]}" "${space_opts[@]}")

    # ── Option A: different disk ──────────────────────────────────────────
    if [[ "$space_choice" == "Use a different disk entirely" ]]; then
        local alt_labels=()
        for d in "${other_disks[@]}"; do
            local dsz dm
            dsz=$(lsblk -dno SIZE  "$d" 2>/dev/null || echo "?")
            dm=$(lsblk  -dno MODEL "$d" 2>/dev/null | cut -c1-28 || echo "")
            alt_labels+=("$(printf '%-14s  %-7s  %s' "$d" "$dsz" "$dm")")
        done
        info "Select disk for Arch Linux root (/):"
        blank
        local sel_disk
        sel_disk=$(choose_one "${alt_labels[0]}" "${alt_labels[@]}")
        DISK_ROOT=$(echo "$sel_disk" | awk '{print $1}')
        local new_free
        new_free=$(( $(blockdev --getsize64 "$DISK_ROOT" 2>/dev/null || echo 0) / 1073741824 ))
        FREE_GB_AVAIL=$new_free
        ok "Arch will be installed on ${DISK_ROOT} (${new_free} GB available)"
        return
    fi

    # Build gum-friendly labels for partition candidates
    local cand_labels=()
    for c in "${candidates[@]}"; do
        local cp="${c%%|*}" rest="${c#*|}"
        local cf="${rest%%|*}" rest2="${rest#*|}"
        local csz="${rest2%%|*}" con="${rest2##*|}"
        local lbl
        lbl="$(printf '%-14s  [%-10s]  %3s GB' "$cp" "$cf" "$csz")"
        if [[ -n "$con" ]]; then lbl+="  — ${con}"; fi
        cand_labels+=("$lbl")
    done

    # ── Option B: replace (delete) ────────────────────────────────────────
    if [[ "$space_choice" == Replace* ]]; then
        blank
        warn "ALL DATA on the selected partition will be permanently lost."
        blank
        info "Select the partition to DELETE:"
        blank

        local rep_choice
        rep_choice=$(choose_one "${cand_labels[0]}" "${cand_labels[@]}")
        REPLACE_PART=$(echo "$rep_choice" | awk '{print $1}')

        local rep_gb
        rep_gb=$(( $(blockdev --getsize64 "$REPLACE_PART" 2>/dev/null || echo 0) / 1073741824 ))
        FREE_GB_AVAIL=$(( free_gb + rep_gb ))

        blank
        gum style \
            --foreground "$GUM_C_ERR" \
            --border thick \
            --border-foreground "$GUM_C_ERR" \
            --padding "0 2" \
            --width "$GUM_WIDTH" \
            "PLAN: DELETE ${REPLACE_PART}  (${rep_gb} GB)" \
            "" \
            "ALL DATA ON THIS PARTITION WILL BE PERMANENTLY LOST." \
            "This will free ${rep_gb} GB → total available: ${FREE_GB_AVAIL} GB"
        blank
        warn "The deletion will happen after you confirm the installation summary."
        blank
        return
    fi

    # ── Option C: shrink ──────────────────────────────────────────────────
    blank
    info "Select the partition to SHRINK:"
    blank

    local shrink_labels=()
    local shrink_map=()
    local idx=0
    for c in "${candidates[@]}"; do
        local cp="${c%%|*}" rest="${c#*|}"
        local cf="${rest%%|*}" rest2="${rest#*|}"
        local csz="${rest2%%|*}" con="${rest2##*|}"
        idx=$(( idx + 1 ))
        if [[ "$cf" == "xfs" ]]; then
            gum style --foreground "$GUM_C_WARN" \
                "  ⚠  ${cp}  [xfs]  ${csz} GB  (XFS cannot be shrunk — skipped)"
            continue
        fi
        if [[ "$cf" == "crypto_LUKS" ]]; then
            gum style --foreground "$GUM_C_WARN" \
                "  ⚠  ${cp}  [LUKS]  ${csz} GB  (encrypted — cannot shrink)"
            continue
        fi
        [[ "$cf" == "swap" ]] && continue
        (( csz < 5 )) && continue
        local lbl
        lbl="$(printf '%-14s  [%-10s]  %3s GB' "$cp" "$cf" "$csz")"
        if [[ -n "$con" ]]; then lbl+="  — ${con}"; fi
        shrink_labels+=("$lbl")
        shrink_map+=("$cp|$cf|$csz")
    done

    if [[ ${#shrink_labels[@]} -eq 0 ]]; then
        warn "No shrinkable partitions available (XFS/LUKS/too small)."
        warn "Try the 'Replace' option or use GParted live."
        FREE_GB_AVAIL=0
        return 0
    fi

    local shrink_choice
    shrink_choice=$(choose_one "${shrink_labels[0]}" "${shrink_labels[@]}")

    # Map selection back to the candidate data
    local sel_idx=0
    for item in "${shrink_labels[@]}"; do
        [[ "$item" == "$shrink_choice" ]] && break
        sel_idx=$(( sel_idx + 1 ))
    done
    local sel="${shrink_map[$sel_idx]}"
    RESIZE_PART="${sel%%|*}"
    local rft="${sel#*|}"; rft="${rft%%|*}"
    local rsize_gb="${sel##*|}"

    # Measure safe minimum size
    local min_safe_gb=2
    case "$rft" in
        ntfs)
            local ntfs_min_mb
            ntfs_min_mb=$(ntfsresize --no-action --size 1M "$RESIZE_PART" 2>&1 \
                           | grep -i "minimum size" | grep -oE '[0-9]+' | head -1 || echo 0)
            min_safe_gb=$(( (ntfs_min_mb * 12 / 10) / 1024 + 1 ))
            ;;
        ext4)
            e2fsck -fn "$RESIZE_PART" &>/dev/null || true
            local bsz ucnt
            bsz=$(tune2fs -l "$RESIZE_PART" 2>/dev/null | awk '/^Block size/{print $3}')
            ucnt=$(tune2fs -l "$RESIZE_PART" 2>/dev/null | awk '/^Block count/{print $3}')
            local used_mb=$(( (${bsz:-4096} * ${ucnt:-0}) / 1048576 ))
            min_safe_gb=$(( (used_mb * 12 / 10) / 1024 + 1 ))
            ;;
        btrfs)
            local used_b
            used_b=$(btrfs filesystem usage -b "$RESIZE_PART" 2>/dev/null \
                     | awk '/Used:/{print $2}' | head -1 || echo 0)
            min_safe_gb=$(( (${used_b:-0} * 12 / 10) / 1073741824 + 2 ))
            ;;
    esac

    gum style \
        --border rounded \
        --border-foreground "$GUM_C_DIM" \
        --padding "0 2" \
        --width "$GUM_WIDTH" \
        "$(_clr "$GUM_C_INFO" "  Partition:  ${RESIZE_PART}  [${rft}]  current: ${rsize_gb} GB")" \
        "$(_clr "$GUM_C_WARN" "  Min safe size (data + 20% margin): ${min_safe_gb} GB")"
    blank

    local new_gb
    while true; do
        new_gb=$(input_gum \
            "New size for ${RESIZE_PART} in GB  [min: ${min_safe_gb}  max: $(( rsize_gb - 1 ))]" \
            "$(( (min_safe_gb + rsize_gb) / 2 ))")
        if [[ "$new_gb" =~ ^[0-9]+$ ]] \
           && (( new_gb >= min_safe_gb )) \
           && (( new_gb < rsize_gb )); then
            break
        fi
        warn "Enter a number between ${min_safe_gb} and $(( rsize_gb - 1 ))."
    done

    RESIZE_NEW_GB=$new_gb
    local freed=$(( rsize_gb - new_gb ))
    FREE_GB_AVAIL=$(( free_gb + freed ))

    blank
    ok "Plan: shrink ${RESIZE_PART}  ${rsize_gb} GB → ${new_gb} GB  (frees ${freed} GB)"
    ok "Total space available for Arch: ${FREE_GB_AVAIL} GB"
    warn "The resize will happen after you confirm the installation summary."
    blank
}

# ── select_disks ──────────────────────────────────────────────────────────────
select_disks() {
    section "Select Disks"

    # Default: home lives on the same disk as root (may be overridden below)
    DISK_HOME="$DISK_ROOT"

    # Build enriched disk list for gum choose
    local disk_list=()
    while IFS= read -r dev; do
        local size rota tran model media
        size=$(lsblk  -dno SIZE  "/dev/${dev}" 2>/dev/null || echo "?")
        rota=$(lsblk  -dno ROTA  "/dev/${dev}" 2>/dev/null || echo "")
        tran=$(lsblk  -dno TRAN  "/dev/${dev}" 2>/dev/null || echo "")
        model=$(lsblk -dno MODEL "/dev/${dev}" 2>/dev/null | cut -c1-28 || echo "")
        if   [[ "$tran" == "nvme" ]]; then media="NVMe"
        elif [[ "$rota" == "0"   ]]; then media="SSD"
        elif [[ "$tran" == "usb" ]]; then media="USB"
        else                              media="HDD"; fi
        disk_list+=("$(printf '/dev/%-10s  %-7s  %-5s  %s' "$dev" "$size" "$media" "$model")")
    done < <(lsblk -d -n -o NAME 2>/dev/null | grep -v "^loop\|^sr")

    if [[ ${#disk_list[@]} -eq 0 ]]; then
        die "No disks found! Something is very wrong."
    fi

    # ── Root disk ─────────────────────────────────────────────────────────
    info "Select disk for ROOT (/):"
    info "This disk will contain the Arch Linux system partition."
    blank
    local root_choice
    root_choice=$(choose_one "${disk_list[0]}" "${disk_list[@]}")
    DISK_ROOT=$(echo "$root_choice" | awk '{print $1}')
    ok "Root disk: ${DISK_ROOT}"

    # Size guard
    local root_bytes root_gb
    root_bytes=$(blockdev --getsize64 "$DISK_ROOT" 2>/dev/null || echo 0)
    root_gb=$(( root_bytes / 1073741824 ))
    if (( root_gb < 15 )); then
        blank
        gum style \
            --foreground "$GUM_C_WARN" \
            --border normal \
            --border-foreground "$GUM_C_WARN" \
            --padding "0 2" \
            --width "$GUM_WIDTH" \
            "Disk ${DISK_ROOT} is only ${root_gb} GB." \
            "Minimum recommended: 20 GB."
        blank
        if ! confirm_gum "Continue anyway?"; then
            info "Aborted."; exit 0
        fi
    fi

    # ── OS guard + late multi-boot offer ─────────────────────────────────
    # Only runs if discover_disks() did NOT already enable dual-boot,
    # i.e. the chosen disk has an OS the user hasn't been warned about yet.
    if [[ "$DUAL_BOOT" == false ]]; then
        local _disk_parts=()
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            local _pb
            _pb=$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)
            (( _pb < 1073741824 )) && continue
            _disk_parts+=("$p")
        done < <(lsblk -ln -o PATH "$DISK_ROOT" 2>/dev/null | tail -n +2)

        local _late_found_names=() _late_found_parts=()
        for p in "${_disk_parts[@]}"; do
            probe_os_from_part "$p" || true
            if [[ -n "$PROBE_OS_RESULT" ]]; then
                _late_found_names+=("$PROBE_OS_RESULT")
                _late_found_parts+=("$p")
            fi
        done
        # Windows NTFS on this disk
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            echo "${_disk_parts[@]}" | grep -qF "$p" || continue
            _late_found_names+=("Windows")
            _late_found_parts+=("$p")
        done < <(blkid -t TYPE="ntfs" -o device 2>/dev/null || true)

        if [[ ${#_late_found_names[@]} -gt 0 ]]; then
            blank
            warn "The selected disk contains existing OS(es):"
            blank
            for i in "${!_late_found_names[@]}"; do
                local _ps
                _ps=$(lsblk -dno SIZE "${_late_found_parts[$i]}" 2>/dev/null || echo "?")
                gum style --foreground "$GUM_C_WARN" \
                    "    →  ${_late_found_names[$i]}  (${_late_found_parts[$i]}, ${_ps})"
            done
            blank

            if confirm_gum "Keep these systems and install Arch alongside them?"; then
                DUAL_BOOT=true
                for n in "${_late_found_names[@]}"; do
                    echo "$n" | grep -qi "windows" && EXISTING_WINDOWS=true
                    echo "$n" | grep -qi "windows" || EXISTING_LINUX=true
                    EXISTING_SYSTEMS+=("$n")
                done
                ok "Multi-boot mode enabled — existing partitions will be preserved"
            else
                blank
                gum style \
                    --foreground "$GUM_C_ERR" \
                    --border thick \
                    --border-foreground "$GUM_C_ERR" \
                    --padding "0 2" \
                    --width "$GUM_WIDTH" \
                    "DANGER — DISK WILL BE WIPED" \
                    "" \
                    "ALL data on ${DISK_ROOT} will be permanently destroyed." \
                    "This includes: ${_late_found_names[*]}"
                blank
                if ! confirm_gum "I understand — erase ${DISK_ROOT} and install Arch"; then
                    info "Aborted — disk untouched."; exit 0
                fi
            fi
        fi
    fi

    # ── Space analysis (multi-boot / tight disks) ─────────────────────────
    if [[ "$DUAL_BOOT" == true ]]; then
        blank
        _check_and_plan_space "$DISK_ROOT"
    fi

    # ── Optional: separate /home disk ─────────────────────────────────────
    blank
    if confirm_gum "Use a separate disk for /home?"; then
        local home_candidates=()
        for item in "${disk_list[@]}"; do
            local d
            d=$(echo "$item" | awk '{print $1}')
            [[ "$d" == "$DISK_ROOT" ]] && continue
            home_candidates+=("$item")
        done

        if [[ ${#home_candidates[@]} -eq 0 ]]; then
            warn "No other disk available for /home — using ${DISK_ROOT}."
        else
            blank
            info "Select disk for /home:"
            blank
            local home_choice
            home_choice=$(choose_one "${home_candidates[0]}" "${home_candidates[@]}")
            DISK_HOME=$(echo "$home_choice" | awk '{print $1}')
            SEP_HOME=true
            ok "Home disk: ${DISK_HOME}"
        fi
    fi

    # ── Danger banner — list every disk that will be touched ──────────────
    blank
    local affected_disks=("$DISK_ROOT")
    if [[ "$DISK_HOME" != "$DISK_ROOT" ]]; then
        affected_disks+=("$DISK_HOME")
    fi

    local banner_lines=("  The following disk(s) WILL be modified:" "")
    for d in "${affected_disks[@]}"; do
        local ds
        ds=$(lsblk -dno SIZE "$d" 2>/dev/null || echo "?")
        banner_lines+=("  →  ${d}  (${ds})")
    done
    if [[ "$DUAL_BOOT" == false ]]; then
        banner_lines+=("" "  All existing data on the root disk will be ERASED.")
    fi

    gum style \
        --foreground "$GUM_C_WARN" \
        --border double \
        --border-foreground "$GUM_C_WARN" \
        --padding "0 1" \
        --width "$GUM_WIDTH" \
        "${banner_lines[@]}"
    blank

    if ! confirm_gum "Confirm disk selection?"; then
        info "Aborted — no changes made."; exit 0
    fi
    ok "Disk selection confirmed."
}

# =============================================================================
#  SECTION 5 — PARTITION WIZARD  (rewritten)
# =============================================================================

GB_RESULT=""
_get_gb_gum() {
    local prompt="$1" default="$2" max="$3" min="${4:-1}" val
    while true; do
        val=$(input_gum "$prompt  [${min}–${max} GB]" "$default")
        if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= min && val <= max )); then
            GB_RESULT="$val"; return
        fi
        warn "Enter a whole number between ${min} and ${max}."
    done
}

_layout_preview() {
    local lines=()
    if [[ "$REUSE_EFI" == true ]]; then
        lines+=("$(_clr "$GUM_C_INFO"   "  EFI       reused  (${EFI_PART})")")
    elif [[ "$FIRMWARE_MODE" == "uefi" ]]; then
        lines+=("$(_clr "$GUM_C_INFO"   "  EFI       ${EFI_SIZE_MB} MB   FAT32")")
    fi
    if [[ "$SWAP_TYPE" == "partition" ]]; then
        lines+=("$(_clr "$GUM_C_WARN"   "  swap      ${SWAP_SIZE} GB    linux-swap")")
    fi
    local root_disp="${ROOT_SIZE} GB"
    if [[ "$ROOT_SIZE" == "rest" ]]; then root_disp="remaining space"; fi
    local luks_tag=""; if [[ "$USE_LUKS" == true ]]; then luks_tag="  [LUKS2]"; fi
    lines+=("$(_clr "$GUM_C_OK"         "  root (/)  ${root_disp}   ${ROOT_FS}${luks_tag}")")
    if [[ "$SEP_HOME" == true && "$DISK_HOME" == "$DISK_ROOT" ]]; then
        local home_disp="${HOME_SIZE} GB"
        if [[ "$HOME_SIZE" == "rest" ]]; then home_disp="remaining space"; fi
        lines+=("$(_clr "$GUM_C_ACCENT" "  /home     ${home_disp}   ${HOME_FS}${luks_tag}")")
    fi
    gum style \
        --border rounded --border-foreground "$GUM_C_TITLE" \
        --padding "0 2" --width "$GUM_WIDTH" \
        "$(_clr "$GUM_C_TITLE" "  Planned layout — ${DISK_ROOT}")" \
        "" "${lines[@]}"
    if [[ "$SEP_HOME" == true && "$DISK_HOME" != "$DISK_ROOT" ]]; then
        blank
        local home_disp2="${HOME_SIZE} GB"
        if [[ "$HOME_SIZE" == "rest" ]]; then home_disp2="full disk"; fi
        gum style \
            --border rounded --border-foreground "$GUM_C_ACCENT" \
            --padding "0 2" --width "$GUM_WIDTH" \
            "$(_clr "$GUM_C_ACCENT" "  /home layout — ${DISK_HOME}")" \
            "" "$(_clr "$GUM_C_ACCENT" "  /home     ${home_disp2}   ${HOME_FS}")"
    fi
}

partition_wizard() {
    local disk_bytes disk_gb avail_gb
    disk_bytes=$(blockdev --getsize64 "$DISK_ROOT" 2>/dev/null || echo 0)
    disk_gb=$(( disk_bytes / 1073741824 ))
    if [[ "$DUAL_BOOT" == true ]]; then
        if [[ "$FREE_GB_AVAIL" -gt 0 ]]; then
            avail_gb=$FREE_GB_AVAIL
        else
            avail_gb=$(( disk_gb / 2 ))
            warn "Space budget unknown — using conservative estimate: ${avail_gb} GB"
        fi
    else
        avail_gb=$disk_gb
    fi

    # ── EFI ──────────────────────────────────────────────────────────────────
    section "EFI Partition"
    if [[ "$FIRMWARE_MODE" == "bios" ]]; then
        info "BIOS mode — no EFI partition needed."
    elif [[ "$DUAL_BOOT" == true ]]; then
        if [[ "$REUSE_EFI" == false || -z "$EFI_PART" ]]; then
            info "Searching for existing EFI System Partition…"
            local _esp_found=""
            while IFS= read -r p; do
                [[ -z "$p" ]] && continue
                local _ept _esz
                _ept=$(lsblk -no PARTTYPE "$p" 2>/dev/null || echo "")
                _esz=$(( $(blockdev --getsize64 "$p" 2>/dev/null || echo 0) / 1048576 ))
                if [[ "$_ept" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] \
                   || [[ "$(blkid -s TYPE -o value "$p" 2>/dev/null)" == "vfat" \
                         && $_esz -le 1024 ]]; then
                    _esp_found="$p"; break
                fi
            done < <(lsblk -ln -o PATH "$DISK_ROOT" 2>/dev/null | tail -n +2)
            if [[ -n "$_esp_found" ]]; then
                EFI_PART="$_esp_found"; REUSE_EFI=true
                ok "Found ESP: ${EFI_PART} — will be reused"
            else
                warn "No ESP found — a new 512 MB EFI partition will be created."
                EFI_SIZE_MB=512; REUSE_EFI=false
            fi
        else
            local _efsz; _efsz=$(lsblk -dno SIZE "$EFI_PART" 2>/dev/null || echo "?")
            ok "Reusing existing EFI: ${EFI_PART}  (${_efsz})"
        fi
    else
        local efi_input
        efi_input=$(input_gum "EFI partition size in MB  (256–2048, recommended: 512)" "512")
        if [[ "$efi_input" =~ ^[0-9]+$ ]] && (( efi_input >= 256 && efi_input <= 2048 )); then
            EFI_SIZE_MB=$efi_input
        else
            warn "Invalid value — using 512 MB."; EFI_SIZE_MB=512
        fi
        ok "EFI: ${EFI_SIZE_MB} MB"
        avail_gb=$(( avail_gb - 1 ))
    fi
    blank

    # ── Layout ────────────────────────────────────────────────────────────────
    section "Partition Layout"
    gum style --border rounded --border-foreground "$GUM_C_DIM" \
        --padding "0 2" --width "$GUM_WIDTH" \
        "$(_clr "$GUM_C_INFO" "  Disk:               ${DISK_ROOT}  (${disk_gb} GB)")" \
        "$(_clr "$GUM_C_OK"   "  Available for Arch: ${avail_gb} GB")"
    blank

    local layout_choice
    if [[ "$DISK_HOME" != "$DISK_ROOT" ]]; then
        SEP_HOME=true; layout_choice="split_disk"
        info "Separate home disk: ${DISK_HOME}"
    else
        local layout_sel
        layout_sel=$(choose_one \
            "/ + /home  — separate home partition  (recommended)" \
            "/           — root uses all space  (simple, small disks)" \
            "/ + /home  — separate home partition  (recommended)" \
            "/ + /home + swap  — explicit swap partition")
        case "$layout_sel" in
            "/ + /home + "*)  layout_choice="root_home_swap" ;;
            "/ + /home"*)     layout_choice="root_home"      ;;
            *)                layout_choice="root_only"      ;;
        esac
    fi
    blank

    local root_max=$(( avail_gb - 1 ))
    if (( root_max < 1 )); then root_max=1; fi

    case "$layout_choice" in
        root_only)
            if confirm_gum "Use all ${avail_gb} GB for / ?"; then
                ROOT_SIZE="rest"
            else
                _get_gb_gum "Root (/) size in GB" "$avail_gb" "$root_max" 1
                ROOT_SIZE="$GB_RESULT"
            fi
            ;;
        root_home|root_home_swap)
            local suggested=40
            if   (( avail_gb > 100 )); then suggested=60
            elif (( avail_gb < 60  )); then suggested=25
            elif (( avail_gb < 30  )); then suggested=15
            elif (( avail_gb < 15  )); then suggested=$(( avail_gb * 6 / 10 )); fi
            local home_preview=$(( avail_gb - suggested ))
            gum style --border rounded --border-foreground "$GUM_C_DIM" \
                --padding "0 2" --width "$GUM_WIDTH" \
                "$(_clr "$GUM_C_INFO" "  Available:       ${avail_gb} GB")" \
                "$(_clr "$GUM_C_INFO" "  Suggested root:  ${suggested} GB")" \
                "$(_clr "$GUM_C_DIM"  "  Remaining → /home: ~${home_preview} GB")"
            blank
            local home_budget=$(( avail_gb - 4 ))
            if (( home_budget < 1 )); then home_budget=1; fi
            _get_gb_gum "Root (/) size in GB" "$suggested" "$home_budget" 5
            ROOT_SIZE="$GB_RESULT"
            local remaining=$(( avail_gb - ROOT_SIZE ))
            blank; ok "Root: ${ROOT_SIZE} GB  ·  Remaining for /home: ${remaining} GB"; blank
            SEP_HOME=true
            if confirm_gum "Give all remaining ${remaining} GB to /home?"; then
                HOME_SIZE="rest"
            else
                _get_gb_gum "Home (/home) size in GB" "$remaining" "$remaining" 1
                HOME_SIZE="$GB_RESULT"
            fi
            ;;
        split_disk)
            local root_default=60
            if (( avail_gb < 80 )); then root_default=40; fi
            if (( avail_gb < 40 )); then root_default=20; fi
            _get_gb_gum "Root (/) size in GB  [on ${DISK_ROOT}]" "$root_default" "$root_max" 5
            ROOT_SIZE="$GB_RESULT"
            local home_bytes home_gb
            home_bytes=$(blockdev --getsize64 "$DISK_HOME" 2>/dev/null || echo 0)
            home_gb=$(( home_bytes / 1073741824 ))
            blank; info "Home disk ${DISK_HOME}: ${home_gb} GB available"
            if confirm_gum "Give all ${home_gb} GB to /home?"; then
                HOME_SIZE="rest"
            else
                _get_gb_gum "Home (/home) size in GB  [on ${DISK_HOME}]" "$home_gb" "$home_gb" 1
                HOME_SIZE="$GB_RESULT"
            fi
            ;;
    esac
    blank; ok "Sizes: root=${ROOT_SIZE} GB${SEP_HOME:+  |  home=${HOME_SIZE} GB}"

    # ── Filesystem ────────────────────────────────────────────────────────────
    section "Filesystem"
    blank
    local fs_sel
    fs_sel=$(choose_one \
        "btrfs  — snapshots, compression, CoW  (recommended)" \
        "btrfs  — snapshots, compression, CoW  (recommended)" \
        "ext4   — rock-solid, most compatible" \
        "xfs    — high performance, large files  (cannot shrink)" \
        "f2fs   — Flash-Friendly FS, optimised for NVMe/SSD")
    case "${fs_sel%% *}" in
        ext4) ROOT_FS="ext4" ;; xfs) ROOT_FS="xfs" ;;
        f2fs) ROOT_FS="f2fs" ;; *)   ROOT_FS="btrfs" ;;
    esac
    ok "Root filesystem: ${ROOT_FS}"
    if [[ "$ROOT_FS" != "btrfs" ]]; then
        info "Note: Snapper requires btrfs — will be disabled if selected later."
    fi
    HOME_FS="$ROOT_FS"
    if [[ "$SEP_HOME" == true ]]; then
        blank; info "Home filesystem (default: same as root — ${ROOT_FS}):"; blank
        local hfs_sel
        hfs_sel=$(choose_one \
            "same as root  (${ROOT_FS})" \
            "same as root  (${ROOT_FS})" \
            "btrfs" "ext4" "xfs" "f2fs")
        case "${hfs_sel%% *}" in
            btrfs) HOME_FS="btrfs" ;; ext4) HOME_FS="ext4" ;;
            xfs)   HOME_FS="xfs"   ;; f2fs) HOME_FS="f2fs" ;;
            *)     HOME_FS="$ROOT_FS" ;;
        esac
        ok "Home filesystem: ${HOME_FS}"
    fi

    # ── Swap ──────────────────────────────────────────────────────────────────
    section "Swap"
    local ram_kb ram_gb rec_swap
    ram_kb=$(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    ram_gb=$(( ram_kb / 1048576 ))
    if   (( ram_gb >= 32 )); then rec_swap=0
    elif (( ram_gb >= 16 )); then rec_swap=4
    elif (( ram_gb >= 8  )); then rec_swap=8
    else                          rec_swap=$(( ram_gb * 2 )); fi
    gum style --border rounded --border-foreground "$GUM_C_DIM" \
        --padding "0 2" --width "$GUM_WIDTH" \
        "$(_clr "$GUM_C_INFO" "  Detected RAM:      ${ram_gb} GB")" \
        "$(_clr "$GUM_C_INFO" "  Recommended swap:  ${rec_swap} GB")"
    blank
    local swap_sel
    swap_sel=$(choose_one \
        "zram           — compressed RAM swap, fastest  (recommended)" \
        "zram           — compressed RAM swap, fastest  (recommended)" \
        "Swap file      — file on disk, supports hibernation" \
        "Swap partition — dedicated partition, most compatible" \
        "None           — no swap  (safe only with 32 GB+ RAM)")
    local sw_default="${rec_swap:-8}"; if (( sw_default < 1 )); then sw_default=4; fi
    case "${swap_sel%% *}" in
        "Swap file"*)
            SWAP_TYPE="file"
            local sf_max=$(( disk_gb / 4 )); if (( sf_max < 1 )); then sf_max=1; fi
            _get_gb_gum "Swap file size in GB" "$sw_default" "$sf_max" 1
            SWAP_SIZE="$GB_RESULT" ;;
        "Swap partition"*)
            SWAP_TYPE="partition"
            local sp_max=$(( disk_gb / 4 )); if (( sp_max < 1 )); then sp_max=1; fi
            _get_gb_gum "Swap partition size in GB" "$sw_default" "$sp_max" 1
            SWAP_SIZE="$GB_RESULT" ;;
        None*)
            SWAP_TYPE="none"; SWAP_SIZE="" ;;
        *)
            SWAP_TYPE="zram"
            local zp; zp=$(input_gum "zram size as % of RAM  (1–200, e.g. 100)" "100")
            if [[ "$zp" =~ ^[0-9]+$ ]] && (( zp > 0 && zp <= 200 )); then
                SWAP_SIZE="${zp}%"
            else
                SWAP_SIZE="100%"
            fi ;;
    esac
    ok "Swap: ${SWAP_TYPE}${SWAP_SIZE:+  (${SWAP_SIZE})}"

    # ── LUKS ──────────────────────────────────────────────────────────────────
    section "Disk Encryption"
    blank
    gum style --border rounded --border-foreground "$GUM_C_DIM" \
        --padding "0 2" --width "$GUM_WIDTH" \
        "$(_clr "$GUM_C_INFO" "  LUKS2 encrypts root (and /home) at the block level.")" \
        "$(_clr "$GUM_C_WARN" "  Passphrase required at EVERY boot — do not lose it.")" \
        "$(_clr "$GUM_C_DIM"  "  Cipher: AES-256-XTS  •  KDF: argon2id")"
    blank
    if confirm_gum "Enable LUKS2 full-disk encryption?"; then
        USE_LUKS=true
        LUKS_PASSWORD=$(password_gum "LUKS passphrase")
        ok "LUKS2 encryption enabled"
    else
        USE_LUKS=false; ok "No encryption"
    fi
    blank; _layout_preview; blank
}

# =============================================================================
#  SECTION 6 — SYSTEM IDENTITY
# =============================================================================
configure_system() {
    section "System Identity"
    while true; do
        HOSTNAME=$(input_gum "Hostname" "archlinux")
        if [[ "$HOSTNAME" =~ ^[a-zA-Z][a-zA-Z0-9-]{0,62}$ ]]; then break; fi
        warn "Invalid hostname — letters/digits/hyphens, start with a letter, max 63 chars."
    done
    blank
    info "GRUB entry name — the label shown when selecting this OS at boot."; blank
    GRUB_ENTRY_NAME=$(input_gum "GRUB boot menu name" "Arch Linux (${HOSTNAME})")
    blank

    local tz_common=("Europe/Paris" "Europe/London" "Europe/Berlin" "Europe/Rome"
        "Europe/Madrid" "Europe/Amsterdam" "Europe/Brussels" "UTC"
        "America/New_York" "America/Chicago" "America/Los_Angeles" "America/Sao_Paulo"
        "Asia/Tokyo" "Asia/Shanghai" "Asia/Kolkata" "Australia/Sydney"
        "Other… — type manually")
    info "Select your timezone:"; blank
    local tz_sel; tz_sel=$(choose_one "Europe/Paris" "${tz_common[@]}")
    if [[ "$tz_sel" == "Other…"* ]]; then
        while true; do
            TIMEZONE=$(input_gum "Timezone  (e.g. Europe/Paris)" "UTC")
            if [[ -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then break; fi
            warn "Not found — browse: ls /usr/share/zoneinfo/"
        done
    else
        TIMEZONE="$tz_sel"
        if [[ ! -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
            warn "Timezone file missing on this ISO — will be set during install."
        fi
    fi
    ok "Timezone: ${TIMEZONE}"; blank

    local locale_common=("en_US.UTF-8" "en_GB.UTF-8" "fr_FR.UTF-8" "de_DE.UTF-8"
        "es_ES.UTF-8" "it_IT.UTF-8" "nl_NL.UTF-8" "pt_PT.UTF-8"
        "pt_BR.UTF-8" "ru_RU.UTF-8" "ja_JP.UTF-8" "zh_CN.UTF-8"
        "Other… — type manually")
    info "Select your system locale:"; blank
    local locale_sel; locale_sel=$(choose_one "fr_FR.UTF-8" "${locale_common[@]}")
    if [[ "$locale_sel" == "Other…"* ]]; then
        while true; do
            LOCALE=$(input_gum "Locale  (e.g. en_US.UTF-8)" "en_US.UTF-8")
            if grep -q "^#\?${LOCALE} " /etc/locale.gen 2>/dev/null \
               || find /usr/share/i18n/locales -name "${LOCALE%%.*}" 2>/dev/null | grep -q .; then
                break
            fi
            warn "Locale '${LOCALE}' not found — format: en_US.UTF-8"
        done
    else
        LOCALE="$locale_sel"
    fi
    ok "Locale: ${LOCALE}"; blank
    gum style --border rounded --border-foreground "$GUM_C_OK" \
        --padding "0 2" --width "$GUM_WIDTH" \
        "$(_clr "$GUM_C_OK" "  Hostname  : ${HOSTNAME}")" \
        "$(_clr "$GUM_C_OK" "  GRUB name : ${GRUB_ENTRY_NAME}")" \
        "$(_clr "$GUM_C_OK" "  Timezone  : ${TIMEZONE}")" \
        "$(_clr "$GUM_C_OK" "  Locale    : ${LOCALE}")"
    blank
}

# =============================================================================
#  SECTION 7 — USER ACCOUNTS
# =============================================================================
configure_users() {
    section "User Accounts"
    info "Username: lowercase letters, digits, underscores, hyphens. Start with letter/underscore."
    blank
    while true; do
        USERNAME=$(input_gum "New username" "archuser")
        if [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then break; fi
        warn "Invalid username — see rules above."
    done
    ok "Username: ${USERNAME}  (wheel/sudo group)"; blank
    USER_PASSWORD=$(password_gum "Password for '${USERNAME}'")
    ok "User password set."; blank
    info "Root password — for emergency console access."; blank
    ROOT_PASSWORD=$(password_gum "Root password")
    ok "Root password set."; blank
    gum style --border rounded --border-foreground "$GUM_C_OK" \
        --padding "0 2" --width "$GUM_WIDTH" \
        "$(_clr "$GUM_C_OK"  "  User   : ${USERNAME}")" \
        "$(_clr "$GUM_C_DIM" "  Groups : wheel, audio, video, storage, optical")" \
        "$(_clr "$GUM_C_OK"  "  Root   : password set")"
    blank
}

# =============================================================================
#  SECTION 8 — KERNEL & BOOTLOADER
# =============================================================================
choose_kernel_bootloader() {
    section "Kernel"
    blank
    local k_sel
    k_sel=$(choose_one \
        "linux          — latest stable  (recommended for most users)" \
        "linux          — latest stable  (recommended for most users)" \
        "linux-lts      — long-term support, rock-solid, slower updates" \
        "linux-zen      — optimised for desktop responsiveness" \
        "linux-hardened — security-hardened, extra kernel mitigations")
    KERNEL="${k_sel%% *}"
    ok "Kernel: ${KERNEL}"

    section "Bootloader"
    blank
    if [[ "$DUAL_BOOT" == true ]]; then
        info "Multi-boot active — detected systems:"
        for sys in "${EXISTING_SYSTEMS[@]}"; do
            gum style --foreground "$GUM_C_INFO" "    →  ${sys}"
        done
        gum style --foreground "$GUM_C_INFO" "    →  Arch Linux  (this install)"
        blank
        warn "GRUB is strongly recommended for multi-boot (os-prober auto-detects all OSes)."
        blank
    fi

    if [[ "$FIRMWARE_MODE" == "bios" ]]; then
        BOOTLOADER="grub"
        ok "Bootloader: GRUB  (only option in BIOS/Legacy mode)"
        info "GRUB will be installed to the MBR of ${DISK_ROOT}."
    else
        local bl_opt1="GRUB           — recommended, auto-detects all OSes via os-prober"
        local bl_opt2
        if [[ "$DUAL_BOOT" == true ]]; then
            bl_opt2="systemd-boot   — NOT recommended in multi-boot (no os-prober)"
        else
            bl_opt2="systemd-boot   — minimal and fast, ideal for single-OS installs"
        fi
        local bl_sel
        bl_sel=$(choose_one "$bl_opt1" "$bl_opt1" "$bl_opt2")
        case "${bl_sel%% *}" in
            systemd-boot)
                BOOTLOADER="systemd-boot"
                if [[ "$DUAL_BOOT" == true ]]; then
                    blank
                    warn "Other OSes will NOT appear in the boot menu automatically."
                    blank
                    if ! confirm_gum "Proceed with systemd-boot anyway?"; then
                        BOOTLOADER="grub"; ok "Switched to GRUB."
                    fi
                fi ;;
            *) BOOTLOADER="grub" ;;
        esac
        ok "Bootloader: ${BOOTLOADER}"
        blank
        if confirm_gum "Enable Secure Boot? (requires sbctl key enrollment after first boot)"; then
            SECURE_BOOT=true
            warn "After first boot: sbctl enroll-keys --microsoft && sbctl sign-all"
        else
            SECURE_BOOT=false
        fi
    fi
    blank
}

# =============================================================================
#  SECTION 9 — DESKTOP ENVIRONMENT
# =============================================================================
choose_desktop() {
    section "Desktop Environment"
    info "Space to toggle, Enter to confirm. Multiple selections allowed."; blank

    local de_options=(
        "KDE Plasma    — feature-rich, fully Wayland-ready"
        "GNOME         — polished Wayland, excellent touchpad/HiDPI"
        "Hyprland      — dynamic tiling Wayland compositor"
        "Sway          — i3-compatible tiling WM, battle-tested Wayland"
        "COSMIC        — new Rust-based DE by System76  (alpha)"
        "XFCE          — lightweight GTK, classic and reliable"
        "None / TTY    — minimal install, configure WM manually later"
    )
    local selected_lines
    mapfile -t selected_lines < <(choose_many "" "${de_options[@]}")

    DESKTOPS=()
    if [[ ${#selected_lines[@]} -eq 0 ]]; then
        warn "No desktop selected — defaulting to TTY."; DESKTOPS=("none")
    else
        for line in "${selected_lines[@]}"; do
            case "${line%% *}" in
                KDE)      DESKTOPS+=("kde")      ;;
                GNOME)    DESKTOPS+=("gnome")    ;;
                Hyprland) DESKTOPS+=("hyprland") ;;
                Sway)     DESKTOPS+=("sway")     ;;
                COSMIC)   DESKTOPS+=("cosmic")   ;;
                XFCE)     DESKTOPS+=("xfce")     ;;
                None*)    DESKTOPS=("none"); break ;;
            esac
        done
        if [[ ${#DESKTOPS[@]} -eq 0 ]]; then DESKTOPS=("none"); fi
    fi
    ok "Desktop(s): ${DESKTOPS[*]}"; blank
}

# =============================================================================
#  SECTION 10 — OPTIONAL EXTRAS
# =============================================================================
choose_extras() {
    section "Optional Extras"

    blank; gum style --foreground "$GUM_C_ACCENT" --bold "  Mirrors"; blank
    if confirm_gum "Enable reflector? (auto-optimise pacman mirrors on boot)"; then
        USE_REFLECTOR=true
        REFLECTOR_COUNTRIES=$(input_gum "Countries (comma-separated)" "France,Germany")
        REFLECTOR_NUMBER=$(input_gum "Number of mirrors to keep" "10")
        REFLECTOR_AGE=$(input_gum "Max mirror age in hours" "12")
        ok "Reflector: ${REFLECTOR_NUMBER} mirrors | ${REFLECTOR_COUNTRIES} | ≤${REFLECTOR_AGE}h"
    else
        USE_REFLECTOR=false
    fi
    blank
    if confirm_gum "Enable multilib repo? (32-bit — Steam, Wine, Proton)"; then
        USE_MULTILIB=true; ok "Multilib: enabled"
    else
        USE_MULTILIB=false
    fi

    blank; gum style --foreground "$GUM_C_ACCENT" --bold "  Audio"; blank
    if confirm_gum "Install PipeWire? (modern audio — replaces PulseAudio)"; then
        USE_PIPEWIRE=true; ok "PipeWire: enabled"
    else
        USE_PIPEWIRE=false
    fi

    blank; gum style --foreground "$GUM_C_ACCENT" --bold "  GPU Drivers"; blank
    if [[ "$GPU_VENDOR" == "nvidia" ]]; then
        if confirm_gum "Install NVIDIA proprietary drivers? (auto-detected NVIDIA GPU)"; then
            USE_NVIDIA=true; ok "NVIDIA drivers: enabled"
        else
            USE_NVIDIA=false
        fi
    elif [[ "$GPU_VENDOR" == "amd" ]]; then
        info "AMD GPU — mesa always included."
        if confirm_gum "Install AMD Vulkan + video acceleration? (vulkan-radeon, libva-mesa-driver)"; then
            USE_AMD_VULKAN=true; ok "AMD Vulkan: enabled"
        else
            USE_AMD_VULKAN=false
        fi
    elif [[ "$GPU_VENDOR" == "intel" ]]; then
        info "Intel GPU — mesa + backlight drivers included in kernel."
    else
        info "GPU not identified — mesa included in base."
    fi

    blank; gum style --foreground "$GUM_C_ACCENT" --bold "  Peripherals"; blank
    if confirm_gum "Install Bluetooth support? (bluez + bluez-utils)"; then
        USE_BLUETOOTH=true; ok "Bluetooth: enabled"
    else
        USE_BLUETOOTH=false
    fi
    if confirm_gum "Install CUPS printing support?"; then
        USE_CUPS=true; ok "CUPS: enabled"
    else
        USE_CUPS=false
    fi

    blank; gum style --foreground "$GUM_C_ACCENT" --bold "  btrfs Snapshots"; blank
    if [[ "$ROOT_FS" == "btrfs" ]]; then
        if confirm_gum "Set up Snapper for automatic btrfs snapshots?"; then
            USE_SNAPPER=true; ok "Snapper: enabled"
        else
            USE_SNAPPER=false
        fi
    else
        info "Snapper requires btrfs — skipped (root is ${ROOT_FS})."; USE_SNAPPER=false
    fi

    blank; gum style --foreground "$GUM_C_ACCENT" --bold "  Firewall"; blank
    local fw_sel
    fw_sel=$(choose_one \
        "nftables  — Linux-native, minimal stateful ruleset  (recommended)" \
        "nftables  — Linux-native, minimal stateful ruleset  (recommended)" \
        "ufw       — Uncomplicated Firewall, simpler CLI" \
        "None      — no firewall  (not recommended)")
    case "${fw_sel%% *}" in
        ufw)  FIREWALL="ufw"      ;;
        None) FIREWALL="none"     ;;
        *)    FIREWALL="nftables" ;;
    esac
    ok "Firewall: ${FIREWALL}"

    blank; gum style --foreground "$GUM_C_ACCENT" --bold "  AUR Helper"; blank
    local aur_sel
    aur_sel=$(choose_one \
        "paru-bin  — pre-built binary, installs in seconds  (recommended)" \
        "paru-bin  — pre-built binary, installs in seconds  (recommended)" \
        "paru      — compiled from source (slow on VM)" \
        "yay       — Go-based, most popular" \
        "None      — no AUR helper")
    case "${aur_sel%% *}" in
        paru-bin) AUR_HELPER="paru-bin" ;;
        paru)     AUR_HELPER="paru"     ;;
        yay)      AUR_HELPER="yay"      ;;
        *)        AUR_HELPER="none"     ;;
    esac
    ok "AUR helper: ${AUR_HELPER}"; blank
}

# =============================================================================
#  MAIN MENU
# =============================================================================

_step_done() {
    case "$1" in
        1) [[ "$CPU_VENDOR" != "unknown" ]]           ;;
        2) [[ -n "$DISK_ROOT" ]]                      ;;
        3) [[ -n "$ROOT_SIZE" ]]                      ;;
        4) [[ -n "$HOSTNAME" ]]                       ;;
        5) [[ -n "$USERNAME" ]]                       ;;
        6) [[ -n "$KERNEL" && -n "$BOOTLOADER" ]]     ;;
        7) [[ ${#DESKTOPS[@]} -gt 0 ]]                ;;
        8) [[ -n "$FIREWALL" ]]                       ;;
        *) return 1 ;;
    esac
}

_step_summary() {
    case "$1" in
        1) if _step_done 1; then
               printf 'cpu:%s  gpu:%s  kbd:%s  fw:%s' \
                   "$CPU_VENDOR" "$GPU_VENDOR" "$KEYMAP" "$FIRMWARE_MODE"
           else printf 'not done'; fi ;;
        2) if _step_done 2; then
               local s="$DISK_ROOT"
               if [[ "$DISK_HOME" != "$DISK_ROOT" ]]; then s+="  home:${DISK_HOME}"; fi
               if [[ "$DUAL_BOOT" == true ]]; then s+="  [multi-boot]"; fi
               printf '%s' "$s"
           else printf 'not done'; fi ;;
        3) if _step_done 3; then
               local s="root=${ROOT_SIZE}GB [${ROOT_FS}]"
               if [[ "$SEP_HOME" == true ]]; then s+="  home=${HOME_SIZE}GB [${HOME_FS}]"; fi
               s+="  swap=${SWAP_TYPE}"
               if [[ "$USE_LUKS" == true ]]; then s+="  LUKS2"; fi
               printf '%s' "$s"
           else printf 'not done'; fi ;;
        4) if _step_done 4; then printf '%s  tz:%s  %s' "$HOSTNAME" "$TIMEZONE" "$LOCALE"
           else printf 'not done'; fi ;;
        5) if _step_done 5; then printf 'user:%s' "$USERNAME"
           else printf 'not done'; fi ;;
        6) if _step_done 6; then
               local s="${KERNEL}  boot:${BOOTLOADER}"
               if [[ "$SECURE_BOOT" == true ]]; then s+="  SecureBoot"; fi
               printf '%s' "$s"
           else printf 'not done'; fi ;;
        7) if _step_done 7; then printf '%s' "${DESKTOPS[*]:-none}"
           else printf 'not done'; fi ;;
        8) if _step_done 8; then
               local s="fw:${FIREWALL}  aur:${AUR_HELPER}"
               if [[ "$USE_PIPEWIRE" == true ]];  then s+="  pipewire"; fi
               if [[ "$USE_REFLECTOR" == true ]]; then s+="  reflector"; fi
               printf '%s' "$s"
           else printf 'not done'; fi ;;
    esac
}

_menu_entry() {
    local n="$1" label="$2"
    local summary; summary=$(_step_summary "$n")
    local tick
    if _step_done "$n"; then tick=$(_clr "$GUM_C_OK"  "✔")
    else                      tick=$(_clr "$GUM_C_DIM" "·"); fi
    local sum_col
    if _step_done "$n"; then sum_col=$(_clr "$GUM_C_DIM" "$summary")
    else                     sum_col=$(_clr "$GUM_C_ERR" "not done"); fi
    printf ' %s  Step %s — %-30s%s' "$tick" "$n" "$label" "$sum_col"
}

main_menu() {
    while true; do
        clear; show_banner

        local e1 e2 e3 e4 e5 e6 e7 e8
        e1=$(_menu_entry 1 "Sanity checks & keyboard")
        e2=$(_menu_entry 2 "Disk discovery & selection")
        e3=$(_menu_entry 3 "Partition wizard")
        e4=$(_menu_entry 4 "System identity")
        e5=$(_menu_entry 5 "Users & passwords")
        e6=$(_menu_entry 6 "Kernel & bootloader")
        e7=$(_menu_entry 7 "Desktop environment")
        e8=$(_menu_entry 8 "Optional extras")

        local choice
        choice=$(gum choose \
            --selected.foreground "$GUM_C_TITLE" \
            --cursor.foreground   "$GUM_C_ACCENT" \
            --height 14 \
            "$e1" "$e2" "$e3" "$e4" "$e5" "$e6" "$e7" "$e8" \
            "──────────────────────────────────────────────────────────" \
            "  ▶  Run all remaining steps in sequence" \
            "  ✗  Quit")

        case "$choice" in
            *"Step 1"*)  sanity_checks; choose_keyboard ;;
            *"Step 2"*)  discover_disks; select_disks ;;
            *"Step 3"*)
                if ! _step_done 2; then
                    warn "Complete Step 2 (disk selection) first."; sleep 2; continue
                fi
                partition_wizard ;;
            *"Step 4"*)  configure_system ;;
            *"Step 5"*)  configure_users ;;
            *"Step 6"*)  choose_kernel_bootloader ;;
            *"Step 7"*)  choose_desktop ;;
            *"Step 8"*)  choose_extras ;;
            *"Run all"*) _run_all_steps; break ;;
            *"Quit"*|"─"*) blank; info "Quit — no changes made."; exit 0 ;;
        esac

        blank
        gum confirm \
            --affirmative "Back to menu" \
            --negative "" \
            --prompt.foreground "$GUM_C_DIM" \
            "  Press Enter to return to menu" || true
    done
}

_run_all_steps() {
    if ! _step_done 1; then sanity_checks; choose_keyboard; fi
    if ! _step_done 2; then discover_disks; select_disks; fi
    if ! _step_done 3; then partition_wizard; fi
    if ! _step_done 4; then configure_system; fi
    if ! _step_done 5; then configure_users; fi
    if ! _step_done 6; then choose_kernel_bootloader; fi
    if ! _step_done 7; then choose_desktop; fi
    if ! _step_done 8; then choose_extras; fi
    blank
    gum style \
        --foreground "$GUM_C_OK" \
        --border double --border-foreground "$GUM_C_OK" \
        --padding "0 2" --width "$GUM_WIDTH" \
        "  All configuration steps complete  ✔" "" \
        "  DISK   : ${DISK_ROOT}  [${ROOT_FS}]  root=${ROOT_SIZE}GB" \
        "  SYSTEM : ${HOSTNAME}  tz:${TIMEZONE}" \
        "  USER   : ${USERNAME}  kernel:${KERNEL}  boot:${BOOTLOADER}" \
        "  DE     : ${DESKTOPS[*]:-none}  fw:${FIREWALL}  aur:${AUR_HELPER}" "" \
        "  Next: Phase 2 — Summary & confirmation  (not yet implemented)"
    blank
}

# =============================================================================
#  ARGUMENT PARSING
# =============================================================================
parse_args() {
    local _prev=""
    for arg in "$@"; do
        case "$arg" in
            --dry-run)     DRY_RUN=true ;;
            --verbose)     VERBOSE=true ;;
            --load-config) : ;;
            --help|-h)
                gum style --border normal --border-foreground "$GUM_C_TITLE" \
                    --padding "0 2" --width "$GUM_WIDTH" \
                    "Usage: bash archwizard_gum.sh [OPTIONS]" "" \
                    "  --dry-run           Show commands without executing" \
                    "  --verbose           Print every command (set -x)" \
                    "  --load-config FILE  Load saved config, skip Phase 1" \
                    "  --help              This message"
                exit 0 ;;
            *)
                if [[ "$_prev" == "--load-config" ]]; then CONFIG_FILE="$arg"; fi ;;
        esac
        _prev="$arg"
    done
    if [[ "$VERBOSE" == true ]]; then set -x; fi
}

# =============================================================================
#  MAIN
# =============================================================================
main() {
    parse_args "$@"
    if [[ "$DRY_RUN" == true ]]; then warn "DRY-RUN mode: no changes will be written to disk."; fi
    if [[ "$VERBOSE" == true ]]; then warn "VERBOSE mode: every command will be printed."; fi
    main_menu
}

main "$@"
