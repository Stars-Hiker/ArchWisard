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
#  Version : 5.5.0-gum-2.0.0
#  License : MIT
#  Depends : gum (https://github.com/charmbracelet/gum)
#  Usage   : bash archwizardGum_2_0.sh [--dry-run] [--verbose] [--load-config FILE]
#
#  Changes in 2.0.0 vs 1.4.0:
#    [fix] DISK_HOME now correctly initialised after DISK_ROOT is set
#    [fix] _is_protected quoting (was dropping elements from PROTECTED_PARTS)
#    [fix] choose_many skips --selected flag when defaults is empty
#    [fix] run_spin pipes stdout+stderr to LOG_FILE correctly
#    [new] run_interactive  — for parted's interactive resize prompt
#    [new] _refresh_partitions — robust partprobe with retry
#    [new] Phase 2  — show_summary + final confirmation gate
#    [new] Phase 3  — replace_partition, resize_partitions, create_partitions
#    [new] Phase 3  — setup_luks, format_filesystems, create_subvolumes,
#                     mount_filesystems
#    [new] Phase 4  — setup_mirrors, install_base
#    [new] Phase 5  — generate_chroot_script, run_chroot
#    [new] Phase 6  — verify_installation, finish
#    [new] save_config / load_config
#    [new] Complete main() flow: Phase1 menu → Phase2 summary → Phase3-6 install
# =============================================================================

set -euo pipefail

LOG_FILE="/tmp/archwizard.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# =============================================================================
#  GUM PRE-FLIGHT  (plain bash — no gum calls before this check)
# =============================================================================
if ! command -v gum &>/dev/null; then
    printf '\n\033[1;31m[FATAL]\033[0m gum is not installed.\n'
    printf '        Install:  pacman -Sy gum   OR   paru -S gum\n\n'
    exit 1
fi

# ── Error trap (plain bash only — gum must never be called inside a trap) ─────
trap 'RC=$?
      echo "CRASH line=$LINENO exit=$RC cmd=${BASH_COMMAND}" >> "$LOG_FILE"
      printf "\n\033[1;31m[FATAL]\033[0m Crashed at line %s (exit %s)\n" "$LINENO" "$RC" >&2
      printf "        cmd : %s\n"  "${BASH_COMMAND}" >&2
      printf "        log : %s\n\n" "$LOG_FILE" >&2' ERR

# =============================================================================
#  GLOBAL STATE
# =============================================================================
DRY_RUN=false
VERBOSE=false
FIRMWARE_MODE="uefi"
CONFIG_FILE=""

CPU_VENDOR="unknown"
GPU_VENDOR="unknown"

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

USE_LUKS=false
LUKS_PASSWORD=""
SWAP_TYPE="zram"
SWAP_SIZE="8"

HOSTNAME=""
GRUB_ENTRY_NAME=""
USERNAME=""
USER_PASSWORD=""
ROOT_PASSWORD=""
TIMEZONE="UTC"
LOCALE="en_US.UTF-8"
KEYMAP="us"

KERNEL="linux"
BOOTLOADER=""
SECURE_BOOT=false
DESKTOPS=()
AUR_HELPER="paru-bin"
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
FIREWALL="nftables"

# =============================================================================
#  GUM THEME
# =============================================================================
readonly GUM_C_TITLE="99"
readonly GUM_C_OK="46"
readonly GUM_C_WARN="214"
readonly GUM_C_ERR="196"
readonly GUM_C_INFO="51"
readonly GUM_C_DIM="242"
readonly GUM_C_ACCENT="141"
readonly GUM_WIDTH=72

_clr() { printf '\033[38;5;%sm%s\033[0m' "$1" "$2"; }

# =============================================================================
#  GUM WRAPPER HELPERS
# =============================================================================

section() {
    echo ""
    gum style \
        --foreground "$GUM_C_TITLE" --bold \
        --border-foreground "$GUM_C_TITLE" --border normal \
        --padding "0 1" --width "$GUM_WIDTH" \
        "  ◆  $*" 2>/dev/null \
        || printf '\033[1;35m══  %s  ══\033[0m\n' "$*"
    echo ""
}

ok()    { gum style --foreground "$GUM_C_OK"   " ✔  $*" 2>/dev/null || printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*"; }
warn()  { gum style --foreground "$GUM_C_WARN" " ⚠  $*" 2>/dev/null || printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
error() { gum style --foreground "$GUM_C_ERR"  " ✗  $*" >&2 2>/dev/null || printf '\033[0;31m[ERR ]\033[0m  %s\n' "$*" >&2; }
info()  { gum style --foreground "$GUM_C_INFO" " ℹ  $*" 2>/dev/null || printf '\033[0;36m[INFO]\033[0m  %s\n' "$*"; }
log()   { echo "[$(date '+%H:%M:%S')] $*"; }
blank() { echo ""; }

die() {
    echo ""
    gum style \
        --foreground "$GUM_C_ERR" \
        --border-foreground "$GUM_C_ERR" --border thick \
        --padding "0 2" --width "$GUM_WIDTH" \
        "FATAL ERROR" "" "$*" "" "Log: $LOG_FILE" 2>/dev/null \
        || printf '\033[1;31m[FATAL]\033[0m %s\n        Log: %s\n' "$*" "$LOG_FILE" >&2
    echo ""
    exit 1
}

# ── run — central command executor ───────────────────────────────────────────
run() {
    if [[ "$DRY_RUN" == true ]]; then
        gum style --faint " [dry-run] $*" 2>/dev/null || printf '[dry-run] %s\n' "$*"
    else
        log "CMD: $*"
        eval "$@"
    fi
}

# ── run_spin — long-running command with spinner ─────────────────────────────
# NOTE: stdout of the wrapped command is NOT captured — use for fire-and-forget.
run_spin() {
    local title="$1"; shift
    if [[ "$DRY_RUN" == true ]]; then
        gum style --faint " [dry-run] $*" 2>/dev/null || printf '[dry-run] %s\n' "$*"
        return
    fi
    log "CMD: $*"
    gum spin --spinner dot --title " $title" \
        -- bash -c "$* >> \"$LOG_FILE\" 2>&1" 2>/dev/null \
        || eval "$@"
}

# ── run_interactive — for commands that need real /dev/tty ───────────────────
# Used by parted's resize confirmation prompt.  The exec redirection done at
# the top of the script replaces stdout/stderr with a pipe; parted reads its
# interactive prompt from /dev/tty and writes the answer back there.
run_interactive() {
    if [[ "$DRY_RUN" == true ]]; then
        gum style --faint " [dry-run] $*" 2>/dev/null || printf '[dry-run] %s\n' "$*"
    else
        log "CMD (interactive): $*"
        eval "$@" </dev/tty >/dev/tty 2>/dev/tty
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
    local prompt="$1" placeholder="${2:-}"
    gum input \
        --prompt " › " --prompt.foreground "$GUM_C_ACCENT" \
        --placeholder "$placeholder" \
        --header "$prompt" --header.foreground "$GUM_C_INFO" \
        --width "$GUM_WIDTH"
}

password_gum() {
    local prompt="$1" pass1 pass2
    while true; do
        pass1=$(gum input --password \
            --prompt " › " --prompt.foreground "$GUM_C_ACCENT" \
            --header "$prompt" --header.foreground "$GUM_C_INFO" \
            --width "$GUM_WIDTH")
        pass2=$(gum input --password \
            --prompt " › " --prompt.foreground "$GUM_C_ACCENT" \
            --header "Confirm: $prompt" --header.foreground "$GUM_C_INFO" \
            --width "$GUM_WIDTH")
        if [[ "$pass1" == "$pass2" && -n "$pass1" ]]; then
            echo "$pass1"; return
        fi
        warn "Passwords don't match or are empty — try again."
    done
}

choose_one() {
    # $1 = preferred default (exact match), $2..N = items
    local default="$1"; shift
    local match=false
    for item in "$@"; do [[ "$item" == "$default" ]] && match=true && break; done
    if [[ "$match" == true ]]; then
        gum choose \
            --selected "$default" \
            --selected.foreground "$GUM_C_TITLE" \
            --cursor.foreground "$GUM_C_ACCENT" \
            --height 12 "$@"
    else
        gum choose \
            --selected.foreground "$GUM_C_TITLE" \
            --cursor.foreground "$GUM_C_ACCENT" \
            --height 12 "$@"
    fi
}

choose_many() {
    # $1 = comma-separated defaults (may be empty), $2..N = items
    local defaults="$1"; shift
    if [[ -n "$defaults" ]]; then
        gum choose --no-limit \
            --selected "$defaults" \
            --selected.foreground "$GUM_C_TITLE" \
            --cursor.foreground "$GUM_C_ACCENT" \
            --height 14 "$@"
    else
        gum choose --no-limit \
            --selected.foreground "$GUM_C_TITLE" \
            --cursor.foreground "$GUM_C_ACCENT" \
            --height 14 "$@"
    fi
}

# =============================================================================
#  CORE HELPERS
# =============================================================================

# ── part_name — derive partition device from disk + number ───────────────────
part_name() {
    local disk="$1" num="$2"
    if [[ "$disk" == *"nvme"* || "$disk" == *"mmcblk"* ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

# ── _is_protected — returns 0 if partition is in PROTECTED_PARTS ─────────────
_is_protected() {
    local p="$1"
    for pp in "${PROTECTED_PARTS[@]+"${PROTECTED_PARTS[@]}"}"; do
        [[ "$pp" == "$p" ]] && return 0
    done
    return 1
}

# ── _refresh_partitions — tell the kernel about GPT changes (retry) ───────────
_refresh_partitions() {
    local disk="$1" attempt
    for attempt in 1 2 3; do
        if partprobe "$disk" 2>/dev/null; then
            sleep 1; ok "Kernel partition table updated"; return 0
        fi
        warn "partprobe attempt ${attempt}/3 failed — retrying in 2s…"
        sleep 2
    done
    if partx -u "$disk" 2>/dev/null; then
        sleep 1; ok "Kernel partition table updated via partx"; return 0
    fi
    udevadm settle 2>/dev/null || true
    sleep 3
    warn "Could not confirm kernel saw partition changes — continuing."
}

# ── probe_os_from_part — detect OS on a block device ────────────────────────
PROBE_OS_RESULT=""
probe_os_from_part() {
    local p="$1"
    PROBE_OS_RESULT=""
    local fstype
    fstype=$(blkid -s TYPE -o value "$p" 2>/dev/null || echo "")

    if [[ "$fstype" == "crypto_LUKS" ]]; then PROBE_OS_RESULT="[encrypted]"; return 0; fi
    if [[ "$fstype" == "ntfs" ]]; then
        local lbl; lbl=$(blkid -s LABEL -o value "$p" 2>/dev/null || echo "")
        PROBE_OS_RESULT="${lbl:-Windows}"; return 0
    fi

    local _mnt="/tmp/archwizard_probe_$$"
    mkdir -p "$_mnt"

    _osrel() {
        local m="$1" n=""
        [[ -f "$m/etc/os-release" ]] || return 0
        n=$(grep '^PRETTY_NAME=' "$m/etc/os-release" | cut -d= -f2- | tr -d '"' | head -1)
        [[ -z "$n" ]] && n=$(grep '^NAME=' "$m/etc/os-release" | cut -d= -f2- | tr -d '"' | head -1 || true)
        echo "$n"; return 0
    }

    if mount -o ro,noexec,nosuid "$p" "$_mnt" 2>/dev/null; then
        PROBE_OS_RESULT=$(_osrel "$_mnt") || true
        umount "$_mnt" 2>/dev/null || true
        if [[ -n "$PROBE_OS_RESULT" ]]; then rmdir "$_mnt" 2>/dev/null; return 0; fi
    fi

    if [[ "$fstype" == "btrfs" ]]; then
        local sv
        for sv in @ @root root arch debian ubuntu fedora opensuse manjaro; do
            if mount -o ro,noexec,nosuid,subvol="$sv" "$p" "$_mnt" 2>/dev/null; then
                PROBE_OS_RESULT=$(_osrel "$_mnt") || true
                umount "$_mnt" 2>/dev/null || true
                if [[ -n "$PROBE_OS_RESULT" ]]; then rmdir "$_mnt" 2>/dev/null; return 0; fi
            fi
        done
    fi

    rmdir "$_mnt" 2>/dev/null || true
    local lbl; lbl=$(blkid -s LABEL -o value "$p" 2>/dev/null || echo "")
    PROBE_OS_RESULT="${lbl:-Linux (${fstype:-unknown})}"
    return 0
}

# =============================================================================
#  BANNER
# =============================================================================
show_banner() {
    clear
    gum style \
        --foreground "$GUM_C_TITLE" --bold \
        --border double --border-foreground "$GUM_C_TITLE" \
        --padding "1 4" --width "$GUM_WIDTH" \
        "ARCH WIZARD  ✨" \
        "v5.5.0-gum-2.0.0" "" \
        "The most wonderful Arch Linux installer ever crafted" "" \
        "log: $LOG_FILE" 2>/dev/null \
        || printf '\033[1;35m  ARCH WIZARD  v5.5.0-gum-2.0.0\033[0m\n\n'
    echo ""
}

# =============================================================================
#  PHASE 1 — STEP 1: SANITY CHECKS & KEYBOARD
# =============================================================================
sanity_checks() {
    section "Pre-flight Checks"

    gum spin --spinner dot --title " Checking root privileges…" -- sleep 0.3 2>/dev/null || true
    if [[ $EUID -ne 0 ]]; then
        die "Must run as root.\nBoot from the official Arch ISO and run with: bash archwizardGum_2_0.sh"
    fi
    ok "Running as root"

    gum spin --spinner dot --title " Detecting firmware mode…" -- sleep 0.3 2>/dev/null || true
    if [[ -d /sys/firmware/efi/efivars ]]; then
        FIRMWARE_MODE="uefi"
        ok "Firmware: UEFI — full feature support (GRUB, systemd-boot, Secure Boot)"
    else
        FIRMWARE_MODE="bios"
        warn "Firmware: BIOS/Legacy — GRUB with MBR will be used"
        warn "systemd-boot and Secure Boot are NOT available in BIOS mode"
    fi

    local net_ok=false
    if ping -c 1 -W 3 8.8.8.8 &>/dev/null || ping -c 1 -W 3 1.1.1.1 &>/dev/null; then
        net_ok=true
    fi

    if [[ "$net_ok" == false ]]; then
        warn "No internet connection detected"
        blank
        local wifi_ifaces=()
        while IFS= read -r iface; do
            [[ -z "$iface" ]] && continue; wifi_ifaces+=("$iface")
        done < <(iw dev 2>/dev/null | awk '/Interface/{print $2}' || true)

        if [[ ${#wifi_ifaces[@]} -gt 0 ]]; then
            info "WiFi interface(s) detected: ${wifi_ifaces[*]}"
            gum style --border normal --border-foreground "$GUM_C_DIM" \
                --padding "0 2" --width "$GUM_WIDTH" \
                "$(_clr "$GUM_C_INFO" "iwctl quick guide")" "" \
                "  device list" \
                "  station ${wifi_ifaces[0]} scan" \
                "  station ${wifi_ifaces[0]} get-networks" \
                "  station ${wifi_ifaces[0]} connect \"YourSSID\"" \
                "  exit" 2>/dev/null || true
            blank
            if confirm_gum "Open iwctl now to connect to WiFi?"; then
                iwctl </dev/tty >/dev/tty 2>/dev/tty || true
                info "Checking connectivity after WiFi setup…"; sleep 3
                if ping -c 1 -W 5 8.8.8.8 &>/dev/null || ping -c 1 -W 5 1.1.1.1 &>/dev/null; then
                    ok "Internet connection established via WiFi"; net_ok=true
                fi
            fi
        fi
        if [[ "$net_ok" == false ]]; then
            die "No internet connection.\nCheck Ethernet or use: iwctl / nmtui / dhcpcd <iface>"
        fi
    else
        ok "Internet connection OK"
    fi

    local missing=() tools=(sgdisk mkfs.fat mkfs.btrfs arch-chroot pacstrap genfstab blkid lsblk)
    for t in "${tools[@]}"; do command -v "$t" &>/dev/null || missing+=("$t"); done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required tools: ${missing[*]}\nBoot from the official Arch ISO."
    fi
    ok "All required tools present"

    if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then CPU_VENDOR="intel"
    elif grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then CPU_VENDOR="amd"; fi
    ok "CPU vendor: ${CPU_VENDOR}"

    if lspci 2>/dev/null | grep -qi "nvidia"; then
        GPU_VENDOR="nvidia"; ok "GPU detected: NVIDIA"
    elif lspci 2>/dev/null | grep -qi "amd.*vga\|vga.*amd\|radeon"; then
        GPU_VENDOR="amd"; ok "GPU detected: AMD Radeon"
    elif lspci 2>/dev/null | grep -qi "intel.*vga\|vga.*intel"; then
        GPU_VENDOR="intel"; ok "GPU detected: Intel"
    else
        warn "GPU vendor could not be determined"
    fi

    timedatectl set-ntp true &>/dev/null & disown
    ok "NTP sync requested (background)"
}

choose_keyboard() {
    section "Keyboard Layout"
    info "Choose your console keymap (French users: fr-latin1, not fr)"
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
        KEYMAP=$(input_gum "Enter keymap name (e.g. fr-latin1, pl2)" "fr-latin1")
    else
        KEYMAP=$(echo "$selection" | awk '{print $1}')
    fi

    if find /usr/share/kbd/keymaps \
            \( -name "${KEYMAP}.map.gz" -o -name "${KEYMAP}.map" \) \
            2>/dev/null | grep -q .; then
        run "loadkeys $KEYMAP"
        ok "Keyboard layout: ${KEYMAP}"
    else
        warn "Layout '${KEYMAP}' not found — falling back to 'us'"
        KEYMAP="us"; run "loadkeys us"
    fi
}

# =============================================================================
#  PHASE 1 — STEP 2: DISK DISCOVERY
# =============================================================================
_disk_table() {
    local rows=()
    while IFS= read -r dev; do
        local name size rota tran pttype model media
        name=$(lsblk   -dno NAME   "/dev/${dev}" 2>/dev/null || echo "$dev")
        size=$(lsblk   -dno SIZE   "/dev/${dev}" 2>/dev/null || echo "?")
        rota=$(lsblk   -dno ROTA   "/dev/${dev}" 2>/dev/null || echo "")
        tran=$(lsblk   -dno TRAN   "/dev/${dev}" 2>/dev/null || echo "")
        pttype=$(lsblk -dno PTTYPE "/dev/${dev}" 2>/dev/null || echo "")
        model=$(lsblk  -dno MODEL  "/dev/${dev}" 2>/dev/null | cut -c1-22 || echo "Unknown")
        if   [[ "$tran" == "nvme" ]]; then media="NVMe"
        elif [[ "$rota" == "0"   ]]; then media="SSD"
        elif [[ "$tran" == "usb" ]]; then media="USB"
        else                              media="HDD"; fi
        rows+=("$(printf '%-14s  %-7s  %-5s  %-6s  %-5s  %-22s' \
            "/dev/${name}" "${size}" "${media}" \
            "${tran:---}" "${pttype:---}" "${model:-Unknown}")")
    done < <(lsblk -d -n -o NAME 2>/dev/null | grep -v "^loop\|^sr")

    gum style \
        --border rounded --border-foreground "$GUM_C_TITLE" \
        --padding "0 1" --width "$GUM_WIDTH" \
        "$(_clr "$GUM_C_ACCENT" "$(printf '%-14s  %-7s  %-5s  %-6s  %-5s  %-22s' DEVICE SIZE TYPE TRAN TABLE MODEL)")" \
        "${rows[@]}" 2>/dev/null || true
}

discover_disks() {
    section "Disk Discovery"
    gum spin --spinner dot --title " Scanning block devices…" -- sleep 0.5 2>/dev/null || true
    _disk_table; blank

    info "Existing partitions:"
    blank
    while IFS= read -r dev; do
        local has_parts
        has_parts=$(lsblk -n -o NAME "/dev/${dev}" 2>/dev/null | tail -n +2)
        [[ -z "$has_parts" ]] && continue
        gum style --foreground "$GUM_C_INFO" --bold "  /dev/${dev}" 2>/dev/null \
            || printf '\033[0;36m  /dev/%s\033[0m\n' "$dev"
        lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "/dev/${dev}" 2>/dev/null \
            | tail -n +2 | while IFS= read -r line; do
                gum style --foreground "$GUM_C_DIM" "    $line" 2>/dev/null \
                    || printf '    %s\n' "$line"
              done
        blank
    done < <(lsblk -d -n -o NAME 2>/dev/null | grep -v "^loop\|^sr")

    # ── OS detection ──────────────────────────────────────────────────────
    gum spin --spinner dot --title " Probing for existing operating systems…" -- sleep 0.3 2>/dev/null || true

    local _mounted_devs
    _mounted_devs=$(awk '{print $1}' /proc/mounts 2>/dev/null | sort -u)

    local _candidates=()
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        echo "$_mounted_devs" | grep -qxF "$p" && continue
        [[ "$p" == /dev/loop* || "$p" == /dev/sr* ]] && continue
        local _pb; _pb=$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)
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
            _found_names+=("$PROBE_OS_RESULT"); _found_parts+=("$p")
        fi
    done

    # UEFI NVRAM supplement
    if command -v efibootmgr &>/dev/null; then
        local _bl="BootManager|BootApp|EFI Default|^Windows|ArchWizard"
        _bl+="|^UEFI[[:space:]]|^UEFI:|Firmware|Setup|Admin|^Shell|^EFI Shell"
        _bl+="|PXE|iPXE|Network|LAN|USB|CD-ROM|DVD|Recovery|Maintenance"
        while IFS= read -r line; do
            local _lbl
            _lbl=$(echo "$line" \
                   | sed 's/Boot[0-9A-Fa-f]*\*[[:space:]]*//' \
                   | sed 's/[[:space:]]*[A-Z][A-Z](.*$//' \
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
                _found_names+=("$_lbl"); _found_parts+=("")
            fi
        done < <(efibootmgr 2>/dev/null | grep -E '^Boot[0-9A-Fa-f]{4}' || true)
    fi

    # Windows NTFS
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        _found_names+=("Windows"); _found_parts+=("$p")
    done < <(blkid -t TYPE="ntfs" -o device 2>/dev/null || true)

    if [[ ${#_found_names[@]} -gt 0 ]]; then
        blank; warn "Existing OS(es) detected:"; blank
        local os_lines=()
        for i in "${!_found_names[@]}"; do
            local _pinfo=""
            if [[ -n "${_found_parts[$i]}" ]]; then
                local _psize; _psize=$(lsblk -dno SIZE "${_found_parts[$i]}" 2>/dev/null || echo "?")
                _pinfo="  (${_found_parts[$i]}, ${_psize})"
            fi
            os_lines+=("  →  ${_found_names[$i]}${_pinfo}")
        done
        gum style --border normal --border-foreground "$GUM_C_WARN" \
            --padding "0 2" --width "$GUM_WIDTH" "${os_lines[@]}" 2>/dev/null || true
        blank

        if confirm_gum "Install Arch Linux alongside these system(s)?"; then
            DUAL_BOOT=true
            for n in "${_found_names[@]}"; do
                echo "$n" | grep -qi "windows" && EXISTING_WINDOWS=true || EXISTING_LINUX=true
                EXISTING_SYSTEMS+=("$n")
            done
            ok "Multi-boot mode enabled — existing partitions will be preserved"
            info "GRUB + os-prober will be strongly recommended as bootloader"
        fi
    fi

    # EFI detection for dual-boot
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
                info "  →  $p  (${_esize})${_elabel:+  label: $_elabel}"
            done
            blank

            if [[ ${#efi_list[@]} -eq 1 ]]; then
                EFI_PART="${efi_list[0]}"; REUSE_EFI=true
                ok "Using existing EFI: ${EFI_PART} — shared between OSes"
            else
                if confirm_gum "Reuse the existing EFI partition? (Strongly recommended for multi-boot)"; then
                    REUSE_EFI=true
                    info "Select which EFI partition to use:"; blank
                    EFI_PART=$(choose_one "${efi_list[0]}" "${efi_list[@]}")
                    ok "Will reuse EFI: ${EFI_PART}"
                fi
            fi
        fi
    fi
}

# =============================================================================
#  PHASE 1 — STEP 3: DISK SELECTION
# =============================================================================
_check_and_plan_space() {
    local disk="$1"
    local NEEDED_GB=7

    local total_free_bytes=0
    while IFS= read -r line; do
        local fb; fb=$(echo "$line" | awk '{print $3}' | tr -d 'B')
        total_free_bytes=$(( total_free_bytes + ${fb:-0} ))
    done < <(parted -s "$disk" unit B print free 2>/dev/null | grep "Free Space" || true)
    local free_gb=$(( total_free_bytes / 1073741824 ))

    local disposable_parts=() disposable_gb=0
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
        disposable_parts+=("$p"); disposable_gb=$(( disposable_gb + _pb_gb ))
    done < <(lsblk -ln -o PATH "$disk" 2>/dev/null | tail -n +2)

    local total_avail_gb=$(( free_gb + disposable_gb ))
    FREE_GB_AVAIL=$total_avail_gb

    section "Space Analysis — ${disk}"
    gum style --border rounded --border-foreground "$GUM_C_DIM" \
        --padding "0 1" --width "$GUM_WIDTH" \
        "$(_clr "$GUM_C_INFO" "  Unallocated space:        ${free_gb} GB")" \
        "$(_clr "$GUM_C_INFO" "  Minimum needed:           ${NEEDED_GB} GB")" \
        "$(_clr "$GUM_C_OK"   "  Total available for Arch: ${total_avail_gb} GB")" 2>/dev/null || true
    blank

    if (( free_gb >= NEEDED_GB )); then
        ok "Sufficient unallocated space (${free_gb} GB ≥ ${NEEDED_GB} GB)"
        return
    fi

    if (( total_avail_gb >= NEEDED_GB && ${#disposable_parts[@]} > 0 )); then
        ok "Enough space by deleting unneeded partitions"
        blank
        for p in "${disposable_parts[@]}"; do
            probe_os_from_part "$p" || true
            local _n="${PROBE_OS_RESULT:-partition}"
            local _s; _s=$(lsblk -dno SIZE "$p" 2>/dev/null || echo "?")
            warn "  Will DELETE: ${p}  (${_s})  — ${_n}"
        done
        blank
        REPLACE_PART="${disposable_parts[0]}"
        REPLACE_PARTS_ALL=("${disposable_parts[@]}")
        FREE_GB_AVAIL=$total_avail_gb
        warn "Deletions will happen after you confirm the installation summary"
        return
    fi

    warn "Not enough space (${total_avail_gb} GB < ${NEEDED_GB} GB)"
    blank

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
        [[ "$ft" == "swap" ]] && os_n="[swap]"
        candidates+=("$p|$ft|$pb_gb|${os_n}")
    done < <(lsblk -ln -o PATH "$disk" 2>/dev/null | tail -n +2)

    if [[ ${#candidates[@]} -eq 0 ]]; then
        for _pp in "${PROTECTED_PARTS[@]+"${PROTECTED_PARTS[@]}"}"; do
            local _ft _pb_gb
            _ft=$(blkid -s TYPE -o value "$_pp" 2>/dev/null || echo "?")
            _pb_gb=$(( $(blockdev --getsize64 "$_pp" 2>/dev/null || echo 0) / 1073741824 ))
            candidates+=("$_pp|$_ft|$_pb_gb|[kept OS — shrink to make space]")
        done
    fi

    if [[ ${#candidates[@]} -eq 0 ]]; then
        warn "No suitable partitions found — use GParted live to free space"
        FREE_GB_AVAIL=0; return 0
    fi

    local other_disks=()
    while IFS= read -r dev; do
        [[ "/dev/$dev" == "$disk" ]] && continue
        local ob; ob=$(blockdev --getsize64 "/dev/$dev" 2>/dev/null || echo 0)
        if [[ $(( ob / 1073741824 )) -ge $NEEDED_GB ]]; then other_disks+=("/dev/$dev"); fi
    done < <(lsblk -d -n -o NAME 2>/dev/null | grep -v "^loop\|^sr")

    local space_opts=()
    if [[ ${#other_disks[@]} -gt 0 ]]; then space_opts+=("Use a different disk entirely"); fi

    local _has_unprotected=false
    for _c in "${candidates[@]}"; do
        local _cp="${_c%%|*}"
        if ! _is_protected "$_cp"; then _has_unprotected=true; break; fi
    done
    if [[ "$_has_unprotected" == true ]]; then
        space_opts+=("Replace a partition (delete — ALL DATA LOST)")
    fi
    space_opts+=("Shrink a partition (keep data, reduce size)")

    info "How do you want to make space for Arch Linux?"; blank
    local space_choice; space_choice=$(choose_one "${space_opts[0]}" "${space_opts[@]}")

    if [[ "$space_choice" == "Use a different disk entirely" ]]; then
        local alt_labels=()
        for d in "${other_disks[@]}"; do
            local dsz dm
            dsz=$(lsblk -dno SIZE  "$d" 2>/dev/null || echo "?")
            dm=$(lsblk  -dno MODEL "$d" 2>/dev/null | cut -c1-28 || echo "")
            alt_labels+=("$(printf '%-14s  %-7s  %s' "$d" "$dsz" "$dm")")
        done
        info "Select disk for Arch Linux root (/):"; blank
        local sel_disk; sel_disk=$(choose_one "${alt_labels[0]}" "${alt_labels[@]}")
        DISK_ROOT=$(echo "$sel_disk" | awk '{print $1}')
        local new_free; new_free=$(( $(blockdev --getsize64 "$DISK_ROOT" 2>/dev/null || echo 0) / 1073741824 ))
        FREE_GB_AVAIL=$new_free
        ok "Arch will be installed on ${DISK_ROOT} (${new_free} GB available)"
        return
    fi

    local cand_labels=()
    for c in "${candidates[@]}"; do
        local cp="${c%%|*}" rest="${c#*|}"; local cf="${rest%%|*}" rest2="${rest#*|}"
        local csz="${rest2%%|*}" con="${rest2##*|}"
        local lbl; lbl="$(printf '%-14s  [%-10s]  %3s GB' "$cp" "$cf" "$csz")"
        [[ -n "$con" ]] && lbl+="  — ${con}"
        cand_labels+=("$lbl")
    done

    if [[ "$space_choice" == Replace* ]]; then
        blank; warn "ALL DATA on the selected partition will be permanently lost"; blank
        info "Select partition to DELETE:"; blank
        local rep_choice; rep_choice=$(choose_one "${cand_labels[0]}" "${cand_labels[@]}")
        REPLACE_PART=$(echo "$rep_choice" | awk '{print $1}')
        local rep_gb; rep_gb=$(( $(blockdev --getsize64 "$REPLACE_PART" 2>/dev/null || echo 0) / 1073741824 ))
        FREE_GB_AVAIL=$(( free_gb + rep_gb ))
        blank
        gum style --foreground "$GUM_C_ERR" --border thick --border-foreground "$GUM_C_ERR" \
            --padding "0 2" --width "$GUM_WIDTH" \
            "PLAN: DELETE ${REPLACE_PART}  (${rep_gb} GB)" "" \
            "ALL DATA WILL BE PERMANENTLY LOST" \
            "Freed: ${rep_gb} GB → total available: ${FREE_GB_AVAIL} GB" 2>/dev/null || true
        blank
        warn "Deletion will happen after you confirm the installation summary"
        return
    fi

    # Shrink path
    blank; info "Select partition to SHRINK:"; blank
    local shrink_labels=() shrink_map=()
    for c in "${candidates[@]}"; do
        local cp="${c%%|*}" rest="${c#*|}"; local cf="${rest%%|*}" rest2="${rest#*|}"
        local csz="${rest2%%|*}" con="${rest2##*|}"
        if [[ "$cf" == "xfs" ]];        then warn "  ⚠  ${cp}  [xfs] — cannot shrink"; continue; fi
        if [[ "$cf" == "crypto_LUKS" ]]; then warn "  ⚠  ${cp}  [LUKS] — cannot shrink"; continue; fi
        [[ "$cf" == "swap" ]] && continue
        (( csz < 5 )) && continue
        local lbl; lbl="$(printf '%-14s  [%-10s]  %3s GB' "$cp" "$cf" "$csz")"
        [[ -n "$con" ]] && lbl+="  — ${con}"
        shrink_labels+=("$lbl"); shrink_map+=("$cp|$cf|$csz")
    done

    if [[ ${#shrink_labels[@]} -eq 0 ]]; then
        warn "No shrinkable partitions available (XFS/LUKS/too small)"
        FREE_GB_AVAIL=0; return 0
    fi

    local shrink_choice; shrink_choice=$(choose_one "${shrink_labels[0]}" "${shrink_labels[@]}")
    local sel_idx=0
    for item in "${shrink_labels[@]}"; do
        [[ "$item" == "$shrink_choice" ]] && break; sel_idx=$(( sel_idx + 1 ))
    done
    local sel="${shrink_map[$sel_idx]}"
    RESIZE_PART="${sel%%|*}"; local rft="${sel#*|}"; rft="${rft%%|*}"; local rsize_gb="${sel##*|}"

    local min_safe_gb=2
    case "$rft" in
        ntfs)
            local ntfs_min_mb
            ntfs_min_mb=$(ntfsresize --no-action --size 1M "$RESIZE_PART" 2>&1 \
                           | grep -i "minimum size" | grep -oE '[0-9]+' | head -1 || echo 0)
            min_safe_gb=$(( (ntfs_min_mb * 12 / 10) / 1024 + 1 )) ;;
        ext4)
            e2fsck -fn "$RESIZE_PART" &>/dev/null || true
            local bsz ucnt
            bsz=$(tune2fs -l "$RESIZE_PART" 2>/dev/null | awk '/^Block size/{print $3}')
            ucnt=$(tune2fs -l "$RESIZE_PART" 2>/dev/null | awk '/^Block count/{print $3}')
            local used_mb=$(( (${bsz:-4096} * ${ucnt:-0}) / 1048576 ))
            min_safe_gb=$(( (used_mb * 12 / 10) / 1024 + 1 )) ;;
        btrfs)
            local used_b
            used_b=$(btrfs filesystem usage -b "$RESIZE_PART" 2>/dev/null \
                     | awk '/Used:/{print $2}' | head -1 || echo 0)
            min_safe_gb=$(( (${used_b:-0} * 12 / 10) / 1073741824 + 2 )) ;;
    esac

    gum style --border rounded --border-foreground "$GUM_C_DIM" \
        --padding "0 2" --width "$GUM_WIDTH" \
        "$(_clr "$GUM_C_INFO" "  Partition:  ${RESIZE_PART}  [${rft}]  current: ${rsize_gb} GB")" \
        "$(_clr "$GUM_C_WARN" "  Min safe size (data + 20% margin): ${min_safe_gb} GB")" 2>/dev/null || true
    blank

    local new_gb
    while true; do
        new_gb=$(input_gum \
            "New size for ${RESIZE_PART} in GB  [min: ${min_safe_gb}  max: $(( rsize_gb - 1 ))]" \
            "$(( (min_safe_gb + rsize_gb) / 2 ))")
        if [[ "$new_gb" =~ ^[0-9]+$ ]] && (( new_gb >= min_safe_gb && new_gb < rsize_gb )); then break; fi
        warn "Enter a number between ${min_safe_gb} and $(( rsize_gb - 1 ))"
    done

    RESIZE_NEW_GB=$new_gb
    local freed=$(( rsize_gb - new_gb ))
    FREE_GB_AVAIL=$(( free_gb + freed ))
    blank
    ok "Plan: shrink ${RESIZE_PART}  ${rsize_gb} GB → ${new_gb} GB  (frees ${freed} GB)"
    ok "Total space available for Arch: ${FREE_GB_AVAIL} GB"
    warn "Resize will happen after you confirm the installation summary"
    blank
}

select_disks() {
    section "Select Disks"

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

    if [[ ${#disk_list[@]} -eq 0 ]]; then die "No disks found!"; fi

    info "Select disk for ROOT (/):"; blank
    local root_choice; root_choice=$(choose_one "${disk_list[0]}" "${disk_list[@]}")
    DISK_ROOT=$(echo "$root_choice" | awk '{print $1}')
    # BUG FIX: Set DISK_HOME AFTER DISK_ROOT is determined
    DISK_HOME="$DISK_ROOT"
    ok "Root disk: ${DISK_ROOT}"

    local root_bytes root_gb
    root_bytes=$(blockdev --getsize64 "$DISK_ROOT" 2>/dev/null || echo 0)
    root_gb=$(( root_bytes / 1073741824 ))
    if (( root_gb < 15 )); then
        blank; warn "Disk ${DISK_ROOT} is only ${root_gb} GB (minimum recommended: 20 GB)"; blank
        confirm_gum "Continue anyway?" || { info "Aborted."; exit 0; }
    fi

    # OS guard + late multi-boot offer
    if [[ "$DUAL_BOOT" == false ]]; then
        local _guard_found=()
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            local _pb; _pb=$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)
            (( _pb < 1073741824 )) && continue
            probe_os_from_part "$p" || true
            [[ -n "$PROBE_OS_RESULT" ]] && _guard_found+=("${PROBE_OS_RESULT}|${p}")
        done < <(lsblk -ln -o PATH "$DISK_ROOT" 2>/dev/null | tail -n +2)

        if [[ ${#_guard_found[@]} -gt 0 ]]; then
            blank; warn "The selected disk contains existing OS(es):"; blank
            for entry in "${_guard_found[@]}"; do
                local _en="${entry%%|*}" _ep="${entry##*|}"
                local _es; _es=$(lsblk -dno SIZE "$_ep" 2>/dev/null || echo "?")
                gum style --foreground "$GUM_C_WARN" \
                    "    →  ${_en}  (${_ep}, ${_es})" 2>/dev/null || true
            done
            blank

            local _any_kept=false
            for entry in "${_guard_found[@]}"; do
                local _en="${entry%%|*}" _ep="${entry##*|}"
                local _es; _es=$(lsblk -dno SIZE "$_ep" 2>/dev/null || echo "?")
                blank
                if confirm_gum "Keep ${_en} (${_ep}, ${_es})? (No = available for deletion)"; then
                    EXISTING_SYSTEMS+=("$_en"); PROTECTED_PARTS+=("$_ep")
                    echo "$_en" | grep -qi "windows" && EXISTING_WINDOWS=true || EXISTING_LINUX=true
                    ok "  ${_en} → will be PRESERVED"; _any_kept=true
                else
                    warn "  ${_en} (${_ep}) → available for deletion or reuse"
                fi
            done
            blank

            if [[ "$_any_kept" == true ]]; then
                DUAL_BOOT=true
                ok "Multi-boot enabled — will preserve: ${EXISTING_SYSTEMS[*]}"
                info "GRUB + os-prober will be strongly recommended"
                _check_and_plan_space "$DISK_ROOT"
            else
                blank
                gum style --foreground "$GUM_C_ERR" --border thick \
                    --border-foreground "$GUM_C_ERR" --padding "0 2" --width "$GUM_WIDTH" \
                    "No OS will be kept — entire disk will be wiped" 2>/dev/null || true
                blank
                confirm_gum "I understand — erase everything on ${DISK_ROOT}" \
                    || { info "Aborted — no changes made."; exit 0; }
            fi
        else
            info "No existing OS detected on ${DISK_ROOT} — fresh install"
        fi
    fi

    # Separate /home disk
    blank
    if [[ ${#disk_list[@]} -gt 1 ]] && confirm_gum "Use a separate disk for /home?"; then
        local home_candidates=()
        for item in "${disk_list[@]}"; do
            local d; d=$(echo "$item" | awk '{print $1}')
            [[ "$d" == "$DISK_ROOT" ]] && continue
            home_candidates+=("$item")
        done
        if [[ ${#home_candidates[@]} -eq 0 ]]; then
            warn "No other disk available for /home — using ${DISK_ROOT}"
        else
            blank; info "Select disk for /home:"; blank
            local home_choice; home_choice=$(choose_one "${home_candidates[0]}" "${home_candidates[@]}")
            DISK_HOME=$(echo "$home_choice" | awk '{print $1}')
            SEP_HOME=true; ok "Home disk: ${DISK_HOME}"
        fi
    fi

    # Danger banner
    blank
    local banner_lines=("  Disk(s) WILL be modified:" "")
    banner_lines+=("  →  ${DISK_ROOT}  ($(lsblk -dno SIZE "$DISK_ROOT" 2>/dev/null || echo ?))")
    if [[ "$DISK_HOME" != "$DISK_ROOT" ]]; then
        banner_lines+=("  →  ${DISK_HOME}  ($(lsblk -dno SIZE "$DISK_HOME" 2>/dev/null || echo ?))")
    fi
    if [[ "$DUAL_BOOT" == false ]]; then
        banner_lines+=("" "  ALL existing data on the root disk will be ERASED")
    fi
    gum style --foreground "$GUM_C_WARN" --border double \
        --border-foreground "$GUM_C_WARN" --padding "0 1" --width "$GUM_WIDTH" \
        "${banner_lines[@]}" 2>/dev/null || true
    blank
    confirm_gum "Confirm disk selection?" || { info "Aborted."; exit 0; }
    ok "Disk selection confirmed"
}

# =============================================================================
#  PHASE 1 — STEP 4: PARTITION WIZARD
# =============================================================================
GB_RESULT=""
_get_gb_gum() {
    local prompt="$1" default="$2" max="$3" min="${4:-1}" val
    while true; do
        val=$(input_gum "$prompt  [${min}–${max} GB]" "$default")
        if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= min && val <= max )); then
            GB_RESULT="$val"; return
        fi
        warn "Enter a whole number between ${min} and ${max}"
    done
}

_layout_preview() {
    local lines=()
    if [[ "$FIRMWARE_MODE" == "bios" ]]; then
        lines+=("$(_clr "$GUM_C_DIM"  "  BIOS mode — no EFI partition")")
    elif [[ "$REUSE_EFI" == true ]]; then
        lines+=("$(_clr "$GUM_C_INFO" "  EFI       reused  (${EFI_PART})")")
    else
        lines+=("$(_clr "$GUM_C_INFO" "  EFI       ${EFI_SIZE_MB} MB   FAT32")")
    fi
    if [[ "$SWAP_TYPE" == "partition" ]]; then
        lines+=("$(_clr "$GUM_C_WARN" "  swap      ${SWAP_SIZE} GB    linux-swap")")
    fi
    local root_disp="${ROOT_SIZE} GB"
    [[ "$ROOT_SIZE" == "rest" ]] && root_disp="remaining space"
    local luks_tag=""; [[ "$USE_LUKS" == true ]] && luks_tag="  [LUKS2]"
    lines+=("$(_clr "$GUM_C_OK"     "  root (/)  ${root_disp}   ${ROOT_FS}${luks_tag}")")
    if [[ "$SEP_HOME" == true && "$DISK_HOME" == "$DISK_ROOT" ]]; then
        local home_disp="${HOME_SIZE} GB"
        [[ "$HOME_SIZE" == "rest" ]] && home_disp="remaining space"
        lines+=("$(_clr "$GUM_C_ACCENT" "  /home     ${home_disp}   ${HOME_FS}${luks_tag}")")
    fi
    gum style --border rounded --border-foreground "$GUM_C_TITLE" \
        --padding "0 2" --width "$GUM_WIDTH" \
        "$(_clr "$GUM_C_TITLE" "  Planned layout — ${DISK_ROOT}")" \
        "" "${lines[@]}" 2>/dev/null || true
    if [[ "$SEP_HOME" == true && "$DISK_HOME" != "$DISK_ROOT" ]]; then
        blank
        local home_disp2="${HOME_SIZE} GB"
        [[ "$HOME_SIZE" == "rest" ]] && home_disp2="full disk"
        gum style --border rounded --border-foreground "$GUM_C_ACCENT" \
            --padding "0 2" --width "$GUM_WIDTH" \
            "$(_clr "$GUM_C_ACCENT" "  /home layout — ${DISK_HOME}")" \
            "" "$(_clr "$GUM_C_ACCENT" "  /home     ${home_disp2}   ${HOME_FS}")" 2>/dev/null || true
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
        info "BIOS mode — no EFI partition needed"
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
                   || { [[ "$(blkid -s TYPE -o value "$p" 2>/dev/null)" == "vfat" ]] \
                        && (( _esz <= 1024 )); }; then
                    _esp_found="$p"; break
                fi
            done < <(lsblk -ln -o PATH "$DISK_ROOT" 2>/dev/null | tail -n +2)
            if [[ -n "$_esp_found" ]]; then
                EFI_PART="$_esp_found"; REUSE_EFI=true
                ok "Found ESP: ${EFI_PART} — will be reused"
            else
                warn "No ESP found — a new 512 MB EFI partition will be created"
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
            warn "Invalid value — using 512 MB"; EFI_SIZE_MB=512
        fi
        ok "EFI: ${EFI_SIZE_MB} MB"
        avail_gb=$(( avail_gb - 1 ))
    fi
    blank

    # ── Layout ───────────────────────────────────────────────────────────────
    section "Partition Layout"
    gum style --border rounded --border-foreground "$GUM_C_DIM" \
        --padding "0 2" --width "$GUM_WIDTH" \
        "$(_clr "$GUM_C_INFO" "  Disk:               ${DISK_ROOT}  (${disk_gb} GB total)")" \
        "$(_clr "$GUM_C_OK"   "  Available for Arch: ${avail_gb} GB")" 2>/dev/null || true
    blank

    local layout_choice
    if [[ "$DISK_HOME" != "$DISK_ROOT" ]]; then
        SEP_HOME=true; layout_choice="split_disk"
        info "Separate home disk selected: ${DISK_HOME}"
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
            fi ;;
        root_home|root_home_swap)
            local suggested=40
            if   (( avail_gb > 100 )); then suggested=60
            elif (( avail_gb <  60 )); then suggested=25
            elif (( avail_gb <  30 )); then suggested=15
            elif (( avail_gb <  15 )); then suggested=$(( avail_gb * 6 / 10 )); fi
            local home_preview=$(( avail_gb - suggested ))
            gum style --border rounded --border-foreground "$GUM_C_DIM" \
                --padding "0 2" --width "$GUM_WIDTH" \
                "$(_clr "$GUM_C_INFO" "  Available:        ${avail_gb} GB")" \
                "$(_clr "$GUM_C_INFO" "  Suggested root:   ${suggested} GB")" \
                "$(_clr "$GUM_C_DIM"  "  Remaining → /home: ~${home_preview} GB")" 2>/dev/null || true
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
            fi ;;
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
            fi ;;
    esac
    blank; ok "Sizes: root=${ROOT_SIZE} GB${SEP_HOME:+  |  home=${HOME_SIZE} GB}"

    # ── Filesystem ───────────────────────────────────────────────────────────
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
        info "Note: Snapper requires btrfs — will be disabled if selected later"
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

    # ── Swap ─────────────────────────────────────────────────────────────────
    section "Swap"
    local ram_kb ram_gb rec_swap
    ram_kb=$(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    ram_gb=$(( ram_kb / 1048576 ))
    if   (( ram_gb >= 32 )); then rec_swap=0
    elif (( ram_gb >= 16 )); then rec_swap=4
    elif (( ram_gb >=  8 )); then rec_swap=8
    else                          rec_swap=$(( ram_gb * 2 )); fi
    gum style --border rounded --border-foreground "$GUM_C_DIM" \
        --padding "0 2" --width "$GUM_WIDTH" \
        "$(_clr "$GUM_C_INFO" "  Detected RAM:      ${ram_gb} GB")" \
        "$(_clr "$GUM_C_INFO" "  Recommended swap:  ${rec_swap} GB")" 2>/dev/null || true
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
            SWAP_TYPE="zram"; SWAP_SIZE="$sw_default" ;;
    esac
    ok "Swap: ${SWAP_TYPE}${SWAP_SIZE:+  (${SWAP_SIZE} GB)}"

    # ── LUKS ─────────────────────────────────────────────────────────────────
    section "Disk Encryption"
    blank
    gum style --border rounded --border-foreground "$GUM_C_DIM" \
        --padding "0 2" --width "$GUM_WIDTH" \
        "$(_clr "$GUM_C_INFO" "  LUKS2 encrypts root (and /home) at the block level")" \
        "$(_clr "$GUM_C_WARN" "  Passphrase required at EVERY boot — do not lose it")" \
        "$(_clr "$GUM_C_DIM"  "  Cipher: AES-256-XTS  ·  KDF: SHA-512")" 2>/dev/null || true
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
#  PHASE 1 — STEP 5: SYSTEM IDENTITY
# =============================================================================
configure_system() {
    section "System Identity"
    while true; do
        HOSTNAME=$(input_gum "Hostname" "archlinux")
        if [[ "$HOSTNAME" =~ ^[a-zA-Z][a-zA-Z0-9-]{0,62}$ ]]; then break; fi
        warn "Invalid hostname — letters/digits/hyphens, start with a letter, max 63 chars"
    done
    blank
    info "GRUB entry name — the label shown when selecting this OS at boot"; blank
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
            warn "Timezone file missing on this ISO — will be set during install"
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
        "$(_clr "$GUM_C_OK" "  Locale    : ${LOCALE}")" 2>/dev/null || true
    blank
}

# =============================================================================
#  PHASE 1 — STEP 6: USER ACCOUNTS
# =============================================================================
configure_users() {
    section "User Accounts"
    info "Username: lowercase letters, digits, underscores, hyphens. Start with letter/underscore."
    blank
    while true; do
        USERNAME=$(input_gum "New username" "archuser")
        if [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then break; fi
        warn "Invalid username — see rules above"
    done
    ok "Username: ${USERNAME}  (wheel/sudo group)"; blank
    USER_PASSWORD=$(password_gum "Password for '${USERNAME}'")
    ok "User password set"; blank
    info "Root password — for emergency console access"; blank
    ROOT_PASSWORD=$(password_gum "Root password")
    ok "Root password set"; blank
    gum style --border rounded --border-foreground "$GUM_C_OK" \
        --padding "0 2" --width "$GUM_WIDTH" \
        "$(_clr "$GUM_C_OK"  "  User   : ${USERNAME}")" \
        "$(_clr "$GUM_C_DIM" "  Groups : wheel, audio, video, storage, optical, network, input")" \
        "$(_clr "$GUM_C_OK"  "  Root   : password set")" 2>/dev/null || true
    blank
}

# =============================================================================
#  PHASE 1 — STEP 7: KERNEL & BOOTLOADER
# =============================================================================
choose_kernel_bootloader() {
    section "Kernel"
    blank
    local k_sel
    k_sel=$(choose_one \
        "linux          — latest stable  (recommended)" \
        "linux          — latest stable  (recommended)" \
        "linux-lts      — long-term support, rock-solid" \
        "linux-zen      — optimised for desktop responsiveness" \
        "linux-hardened — security-hardened, extra mitigations")
    KERNEL="${k_sel%% *}"
    ok "Kernel: ${KERNEL}"

    section "Bootloader"
    blank
    if [[ "$DUAL_BOOT" == true ]]; then
        info "Multi-boot active — detected systems:"
        for sys in "${EXISTING_SYSTEMS[@]}"; do
            gum style --foreground "$GUM_C_INFO" "    →  ${sys}" 2>/dev/null || true
        done
        gum style --foreground "$GUM_C_INFO" "    →  Arch Linux  (this install)" 2>/dev/null || true
        blank; warn "GRUB is strongly recommended for multi-boot (os-prober auto-detects all OSes)"; blank
    fi

    if [[ "$FIRMWARE_MODE" == "bios" ]]; then
        BOOTLOADER="grub"
        ok "Bootloader: GRUB  (only option in BIOS/Legacy mode)"
        info "GRUB will be installed to the MBR of ${DISK_ROOT}"
    else
        local bl_opt2="systemd-boot   — minimal and fast, ideal for single-OS installs"
        if [[ "$DUAL_BOOT" == true ]]; then
            bl_opt2="systemd-boot   — NOT recommended in multi-boot (no os-prober)"
        fi
        local bl_sel
        bl_sel=$(choose_one \
            "GRUB           — recommended, auto-detects all OSes via os-prober" \
            "GRUB           — recommended, auto-detects all OSes via os-prober" \
            "$bl_opt2")
        case "${bl_sel%% *}" in
            systemd-boot)
                BOOTLOADER="systemd-boot"
                if [[ "$DUAL_BOOT" == true ]]; then
                    blank; warn "Other OSes will NOT appear in the boot menu automatically"; blank
                    if ! confirm_gum "Proceed with systemd-boot anyway?"; then
                        BOOTLOADER="grub"; ok "Switched to GRUB"
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
#  PHASE 1 — STEP 8: DESKTOP ENVIRONMENT
# =============================================================================
choose_desktop() {
    section "Desktop Environment"
    info "Space to toggle, Enter to confirm — multiple selections allowed"; blank

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
    mapfile -t selected_lines < <(choose_many "" "${de_options[@]}" || true)

    DESKTOPS=()
    if [[ ${#selected_lines[@]} -eq 0 ]]; then
        warn "No desktop selected — defaulting to TTY"; DESKTOPS=("none")
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
#  PHASE 1 — STEP 9: OPTIONAL EXTRAS
# =============================================================================
choose_extras() {
    section "Optional Extras"

    blank; gum style --foreground "$GUM_C_ACCENT" --bold "  Mirrors" 2>/dev/null || printf '  Mirrors\n'; blank
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

    blank; gum style --foreground "$GUM_C_ACCENT" --bold "  Audio" 2>/dev/null || printf '  Audio\n'; blank
    if confirm_gum "Install PipeWire? (modern audio — replaces PulseAudio)"; then
        USE_PIPEWIRE=true; ok "PipeWire: enabled"
    else
        USE_PIPEWIRE=false
    fi

    blank; gum style --foreground "$GUM_C_ACCENT" --bold "  GPU Drivers" 2>/dev/null || printf '  GPU Drivers\n'; blank
    if [[ "$GPU_VENDOR" == "nvidia" ]]; then
        if confirm_gum "Install NVIDIA proprietary drivers? (auto-detected NVIDIA GPU)"; then
            USE_NVIDIA=true; ok "NVIDIA drivers: enabled"
        else
            USE_NVIDIA=false
        fi
    elif [[ "$GPU_VENDOR" == "amd" ]]; then
        info "AMD GPU — mesa always included"
        if confirm_gum "Install AMD Vulkan + video acceleration? (vulkan-radeon, libva-mesa-driver)"; then
            USE_AMD_VULKAN=true; ok "AMD Vulkan: enabled"
        else
            USE_AMD_VULKAN=false
        fi
    elif [[ "$GPU_VENDOR" == "intel" ]]; then
        info "Intel GPU — mesa + backlight drivers included in kernel"
    else
        info "GPU not identified — mesa included in base"
    fi

    blank; gum style --foreground "$GUM_C_ACCENT" --bold "  Peripherals" 2>/dev/null || printf '  Peripherals\n'; blank
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

    blank; gum style --foreground "$GUM_C_ACCENT" --bold "  btrfs Snapshots" 2>/dev/null || printf '  btrfs Snapshots\n'; blank
    if [[ "$ROOT_FS" == "btrfs" ]]; then
        if confirm_gum "Set up Snapper for automatic btrfs snapshots?"; then
            USE_SNAPPER=true; ok "Snapper: enabled"
        else
            USE_SNAPPER=false
        fi
    else
        info "Snapper requires btrfs — skipped (root is ${ROOT_FS})"; USE_SNAPPER=false
    fi

    blank; gum style --foreground "$GUM_C_ACCENT" --bold "  Firewall" 2>/dev/null || printf '  Firewall\n'; blank
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

    blank; gum style --foreground "$GUM_C_ACCENT" --bold "  AUR Helper" 2>/dev/null || printf '  AUR Helper\n'; blank
    local aur_sel
    aur_sel=$(choose_one \
        "paru-bin  — pre-built binary, installs in seconds  (recommended)" \
        "paru-bin  — pre-built binary, installs in seconds  (recommended)" \
        "paru      — compiled from source  (slower on VM)" \
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
#  SAVE / LOAD CONFIG
# =============================================================================
save_config() {
    local default_path="/tmp/archwizard_config_$(date +%Y%m%d_%H%M%S).sh"
    blank; section "Save Configuration"
    info "Save your choices to a file — useful for reinstalls or a second machine"
    blank; warn "The file will contain passwords in plaintext — keep it secure!"; blank

    if ! confirm_gum "Save configuration to file?"; then return 0; fi

    local cfg_path
    cfg_path=$(input_gum "Save to" "$default_path")

    cat > "$cfg_path" << CFGEOF
#!/usr/bin/env bash
# ArchWizard saved configuration — $(date '+%Y-%m-%d %H:%M:%S')
# Usage: bash archwizardGum_2_0.sh --load-config $(basename "$cfg_path")
# WARNING: contains passwords in plaintext — store securely!

CPU_VENDOR="${CPU_VENDOR}";       GPU_VENDOR="${GPU_VENDOR}"
DISK_ROOT="${DISK_ROOT}";         DISK_HOME="${DISK_HOME}"
ROOT_FS="${ROOT_FS}";             HOME_FS="${HOME_FS}"
EFI_PART="${EFI_PART}";           EFI_SIZE_MB="${EFI_SIZE_MB}"
ROOT_SIZE="${ROOT_SIZE}";         SEP_HOME="${SEP_HOME}"
HOME_SIZE="${HOME_SIZE}";         SWAP_TYPE="${SWAP_TYPE}"
SWAP_SIZE="${SWAP_SIZE}";         DUAL_BOOT="${DUAL_BOOT}"
REUSE_EFI="${REUSE_EFI}";         USE_LUKS="${USE_LUKS}"
HOSTNAME="${HOSTNAME}";           GRUB_ENTRY_NAME="${GRUB_ENTRY_NAME}"
USERNAME="${USERNAME}";           USER_PASSWORD="${USER_PASSWORD}"
ROOT_PASSWORD="${ROOT_PASSWORD}"; TIMEZONE="${TIMEZONE}"
LOCALE="${LOCALE}";               KEYMAP="${KEYMAP}"
KERNEL="${KERNEL}";               BOOTLOADER="${BOOTLOADER}"
SECURE_BOOT="${SECURE_BOOT}";     AUR_HELPER="${AUR_HELPER}"
DESKTOPS=(${DESKTOPS[@]+"${DESKTOPS[@]}"})
USE_REFLECTOR="${USE_REFLECTOR}"; REFLECTOR_COUNTRIES="${REFLECTOR_COUNTRIES}"
REFLECTOR_NUMBER="${REFLECTOR_NUMBER}"; REFLECTOR_AGE="${REFLECTOR_AGE}"
USE_MULTILIB="${USE_MULTILIB}";   USE_PIPEWIRE="${USE_PIPEWIRE}"
USE_NVIDIA="${USE_NVIDIA}";       USE_AMD_VULKAN="${USE_AMD_VULKAN}"
USE_BLUETOOTH="${USE_BLUETOOTH}"; USE_CUPS="${USE_CUPS}"
USE_SNAPPER="${USE_SNAPPER}";     FIREWALL="${FIREWALL}"
CFGEOF

    chmod 600 "$cfg_path"
    ok "Config saved → ${cfg_path}"
    warn "Contains passwords — delete or encrypt when done"
    blank
}

load_config() {
    local cfg="$1"
    if [[ ! -f "$cfg" ]]; then die "Config file not found: ${cfg}"; fi
    info "Loading config from: ${cfg}"
    # shellcheck source=/dev/null
    source "$cfg"
    ok "Config loaded — Phase 1 steps will be skipped"
    blank
}

# =============================================================================
#  PHASE 2 — SUMMARY & FINAL CONFIRMATION
# =============================================================================
show_summary() {
    section "Installation Summary"
    blank

    local rows=(
        "$(_clr "$GUM_C_ACCENT" "  DISKS & PARTITIONS")"
        "$(_clr "$GUM_C_DIM"    "  Root disk      : ${CYAN:-}${DISK_ROOT}")"
        "$(_clr "$GUM_C_DIM"    "  Root size      : ${ROOT_SIZE} GB  [${ROOT_FS}]")"
    )
    if [[ "$SEP_HOME" == true ]]; then
        rows+=("$(_clr "$GUM_C_DIM" "  Home disk      : ${DISK_HOME}")")
        rows+=("$(_clr "$GUM_C_DIM" "  Home size      : ${HOME_SIZE} GB  [${HOME_FS}]")")
    fi
    if [[ "$REUSE_EFI" == true ]]; then
        rows+=("$(_clr "$GUM_C_DIM" "  EFI            : ${EFI_PART}  (reused)")")
    fi
    rows+=("$(_clr "$GUM_C_DIM" "  Swap           : ${SWAP_TYPE}${SWAP_SIZE:+ (${SWAP_SIZE} GB)}")")
    rows+=("$(_clr "$GUM_C_DIM" "  LUKS encrypt   : ${USE_LUKS}")")
    rows+=("$(_clr "$GUM_C_DIM" "  Multi-boot     : ${DUAL_BOOT}")")

    if [[ ${#REPLACE_PARTS_ALL[@]} -gt 0 ]]; then
        rows+=("$(_clr "$GUM_C_ERR" "  Space plan     : DELETE ${REPLACE_PARTS_ALL[*]}  — ALL DATA LOST")")
    elif [[ -n "$REPLACE_PART" ]]; then
        rows+=("$(_clr "$GUM_C_ERR" "  Space plan     : DELETE ${REPLACE_PART}  — ALL DATA LOST")")
    elif [[ -n "$RESIZE_PART" ]]; then
        rows+=("$(_clr "$GUM_C_WARN" "  Space plan     : SHRINK ${RESIZE_PART} → ${RESIZE_NEW_GB} GB")")
    fi
    if [[ ${#EXISTING_SYSTEMS[@]} -gt 0 ]]; then
        rows+=("$(_clr "$GUM_C_DIM" "  Other OSes     : ${EXISTING_SYSTEMS[*]}")")
    fi

    rows+=("" "$(_clr "$GUM_C_ACCENT" "  SYSTEM")"
        "$(_clr "$GUM_C_DIM" "  Hostname       : ${HOSTNAME}")"
        "$(_clr "$GUM_C_DIM" "  GRUB name      : ${GRUB_ENTRY_NAME}")"
        "$(_clr "$GUM_C_DIM" "  Timezone       : ${TIMEZONE}")"
        "$(_clr "$GUM_C_DIM" "  Locale         : ${LOCALE}")"
        "$(_clr "$GUM_C_DIM" "  Keymap         : ${KEYMAP}")"
        "$(_clr "$GUM_C_DIM" "  User           : ${USERNAME}  (wheel/sudo)")"
    )

    rows+=("" "$(_clr "$GUM_C_ACCENT" "  SOFTWARE")"
        "$(_clr "$GUM_C_DIM" "  Kernel         : ${KERNEL}")"
        "$(_clr "$GUM_C_DIM" "  Bootloader     : ${BOOTLOADER}")"
        "$(_clr "$GUM_C_DIM" "  Secure Boot    : ${SECURE_BOOT}")"
        "$(_clr "$GUM_C_DIM" "  Desktop        : ${DESKTOPS[*]:-none}")"
        "$(_clr "$GUM_C_DIM" "  AUR helper     : ${AUR_HELPER}")"
        "$(_clr "$GUM_C_DIM" "  PipeWire       : ${USE_PIPEWIRE}")"
        "$(_clr "$GUM_C_DIM" "  Multilib       : ${USE_MULTILIB}")"
        "$(_clr "$GUM_C_DIM" "  NVIDIA         : ${USE_NVIDIA}")"
        "$(_clr "$GUM_C_DIM" "  Bluetooth      : ${USE_BLUETOOTH}")"
        "$(_clr "$GUM_C_DIM" "  CUPS           : ${USE_CUPS}")"
        "$(_clr "$GUM_C_DIM" "  Snapper        : ${USE_SNAPPER}")"
        "$(_clr "$GUM_C_DIM" "  Reflector      : ${USE_REFLECTOR}")"
        "$(_clr "$GUM_C_DIM" "  Firewall       : ${FIREWALL}")"
    )

    gum style --border rounded --border-foreground "$GUM_C_TITLE" \
        --padding "0 2" --width "$GUM_WIDTH" \
        "${rows[@]}" 2>/dev/null || true
    blank

    gum style --foreground "$GUM_C_ERR" --bold \
        " ⚠  After this confirmation your disk(s) will be modified!" 2>/dev/null \
        || printf '\033[1;31m  After this confirmation your disk(s) will be modified!\033[0m\n'
    blank

    confirm_gum "Begin installation?" \
        || { info "Aborted — no changes were made."; exit 0; }
}

# =============================================================================
#  PHASE 3 — REPLACE PARTITIONS  (multi-boot: delete unwanted partitions)
# =============================================================================
replace_partition() {
    if [[ "$DUAL_BOOT" == false ]]; then return 0; fi

    local _to_delete=()
    if [[ ${#REPLACE_PARTS_ALL[@]} -gt 0 ]]; then
        _to_delete=("${REPLACE_PARTS_ALL[@]}")
    elif [[ -n "$REPLACE_PART" ]]; then
        _to_delete=("$REPLACE_PART")
    else
        return 0
    fi

    section "Delete Partitions (freeing space for Arch Linux)"

    # Sort by partition number descending — delete highest first
    local _sorted=()
    while IFS= read -r line; do _sorted+=("$line"); done < <(
        printf '%s\n' "${_to_delete[@]}" \
        | awk '{match($0,/[0-9]+$/); print substr($0,RSTART)+0, $0}' \
        | sort -rn | awk '{print $2}')

    local _total_freed=0
    for p in "${_sorted[@]}"; do
        [[ -z "$p" ]] && continue
        local _gb _num
        _gb=$(( $(blockdev --getsize64 "$p" 2>/dev/null || echo 0) / 1073741824 ))
        _num=$(echo "$p" | grep -oE '[0-9]+$')
        info "Deleting ${p} (${_gb} GB) — ALL DATA LOST"
        run "sgdisk -d ${_num} ${DISK_ROOT}"
        _total_freed=$(( _total_freed + _gb ))
        ok "${p} removed from GPT"
    done

    _refresh_partitions "${DISK_ROOT}"

    blank
    info "Updated layout of ${DISK_ROOT}:"
    parted -s "$DISK_ROOT" unit GiB print free 2>/dev/null || true
    blank
    ok "Total freed: ${_total_freed} GB now unallocated"
    blank
}

# =============================================================================
#  PHASE 3 — RESIZE PARTITIONS  (shrink existing partition to make room)
# =============================================================================
resize_partitions() {
    if [[ "$DUAL_BOOT" == false ]]; then return 0; fi
    if [[ -z "$RESIZE_PART" ]]; then return 0; fi

    section "Resize Partition: ${RESIZE_PART} → ${RESIZE_NEW_GB} GB"

    local target_part="$RESIZE_PART"
    local new_gb="$RESIZE_NEW_GB"
    local target_fs; target_fs=$(blkid -s TYPE -o value "$target_part" 2>/dev/null || echo "unknown")
    local cur_gb; cur_gb=$(( $(blockdev --getsize64 "$target_part" 2>/dev/null || echo 0) / 1073741824 ))
    local freed=$(( cur_gb - new_gb ))
    local new_bytes=$(( new_gb * 1073741824 ))
    local new_mb=$(( new_gb * 1024 ))

    info "Executing: ${target_part}  ${cur_gb} GB → ${new_gb} GB  (freeing ${freed} GB)"
    blank

    case "$target_fs" in
        ntfs)
            info "Shrinking NTFS filesystem…"
            run "ntfsresize --no-action --size ${new_mb}M $target_part"
            run "ntfsresize --force --size ${new_mb}M $target_part"
            ok "NTFS filesystem shrunk to ${new_gb} GB" ;;
        ext4)
            info "Shrinking ext4 filesystem…"
            run "e2fsck -fy $target_part"
            run "resize2fs $target_part ${new_mb}M"
            ok "ext4 filesystem shrunk" ;;
        btrfs)
            info "Shrinking btrfs filesystem…"
            local _btmp="/tmp/archwizard_btrfs_resize"
            mkdir -p "$_btmp"
            run "mount -o rw $target_part $_btmp"
            run "btrfs filesystem resize ${new_mb}M $_btmp"
            run "umount $_btmp"
            rmdir "$_btmp" 2>/dev/null || true
            ok "btrfs filesystem shrunk" ;;
        *)
            error "Unsupported filesystem '${target_fs}' for resize"; return 1 ;;
    esac

    local part_num; part_num=$(echo "$target_part" | grep -oE '[0-9]+$')
    local start_bytes
    start_bytes=$(parted -s "$DISK_ROOT" unit B print 2>/dev/null \
                  | awk "/^ *${part_num} /{print \$2}" | tr -d 'B')
    local new_end=$(( ${start_bytes:-0} + new_bytes ))
    info "parted will ask you to confirm the resize — type 'Yes' and press Enter"
    run_interactive "parted $DISK_ROOT resizepart $part_num ${new_end}B"
    ok "GPT partition entry updated"
    _refresh_partitions "$DISK_ROOT"
    blank
    info "Updated layout:"; parted -s "$DISK_ROOT" unit GiB print free 2>/dev/null || true
    blank; ok "Done — ~${freed} GB of unallocated space now available"; blank
}

# =============================================================================
#  PHASE 3 — CREATE PARTITIONS
# =============================================================================
create_partitions() {
    section "Partitioning Disks"
    blank

    local part_num=1

    if [[ "$DUAL_BOOT" == true ]]; then
        info "Multi-boot mode — adding partitions to existing layout"

        if [[ "$SWAP_TYPE" == "partition" ]]; then
            run "sgdisk -n 0:0:+${SWAP_SIZE}G -t 0:8200 -c 0:arch_swap $DISK_ROOT"
            SWAP_PART=$(part_name "$DISK_ROOT" "$(sgdisk -p "$DISK_ROOT" 2>/dev/null | tail -1 | awk '{print $1}')")
        fi

        if [[ "$SEP_HOME" == true && "$DISK_HOME" == "$DISK_ROOT" ]]; then
            if [[ "$ROOT_SIZE" == "rest" ]]; then
                run "sgdisk -n 0:0:0 -t 0:8300 -c 0:arch_root $DISK_ROOT"
            else
                run "sgdisk -n 0:0:+${ROOT_SIZE}G -t 0:8300 -c 0:arch_root $DISK_ROOT"
            fi
            ROOT_PART=$(part_name "$DISK_ROOT" "$(sgdisk -p "$DISK_ROOT" 2>/dev/null | tail -1 | awk '{print $1}')")
            if [[ "$HOME_SIZE" == "rest" ]]; then
                run "sgdisk -n 0:0:0 -t 0:8302 -c 0:arch_home $DISK_ROOT"
            else
                run "sgdisk -n 0:0:+${HOME_SIZE}G -t 0:8302 -c 0:arch_home $DISK_ROOT"
            fi
            HOME_PART=$(part_name "$DISK_ROOT" "$(sgdisk -p "$DISK_ROOT" 2>/dev/null | tail -1 | awk '{print $1}')")
        else
            if [[ "$ROOT_SIZE" == "rest" ]]; then
                run "sgdisk -n 0:0:0 -t 0:8300 -c 0:arch_root $DISK_ROOT"
            else
                run "sgdisk -n 0:0:+${ROOT_SIZE}G -t 0:8300 -c 0:arch_root $DISK_ROOT"
            fi
            ROOT_PART=$(part_name "$DISK_ROOT" "$(sgdisk -p "$DISK_ROOT" 2>/dev/null | tail -1 | awk '{print $1}')")
        fi

    elif [[ "$FIRMWARE_MODE" == "bios" ]]; then
        warn "Wiping $DISK_ROOT and creating new MBR partition table (BIOS mode)…"
        run "parted -s $DISK_ROOT mklabel msdos"
        run "parted -s $DISK_ROOT mkpart primary 1MiB 2MiB"
        run "parted -s $DISK_ROOT set 1 bios_grub on"
        part_num=2

        if [[ "$SWAP_TYPE" == "partition" ]]; then
            local _swap_end=$(( 2 + SWAP_SIZE * 1024 ))
            run "parted -s $DISK_ROOT mkpart primary linux-swap 2MiB ${_swap_end}MiB"
            SWAP_PART=$(part_name "$DISK_ROOT" "$part_num")
            part_num=$(( part_num + 1 ))
            local _next_start="${_swap_end}MiB"
        else
            local _next_start="2MiB"
        fi

        if [[ "$ROOT_SIZE" == "rest" ]]; then
            run "parted -s $DISK_ROOT mkpart primary ${_next_start} 100%"
            ROOT_PART=$(part_name "$DISK_ROOT" "$part_num")
        else
            local _root_end=$(( (${_next_start//MiB/} + ROOT_SIZE * 1024) ))
            run "parted -s $DISK_ROOT mkpart primary ${_next_start} ${_root_end}MiB"
            ROOT_PART=$(part_name "$DISK_ROOT" "$part_num")
            part_num=$(( part_num + 1 ))
            if [[ "$SEP_HOME" == true && "$DISK_HOME" == "$DISK_ROOT" ]]; then
                if [[ "$HOME_SIZE" == "rest" ]]; then
                    run "parted -s $DISK_ROOT mkpart primary ${_root_end}MiB 100%"
                else
                    local _home_end=$(( _root_end + HOME_SIZE * 1024 ))
                    run "parted -s $DISK_ROOT mkpart primary ${_root_end}MiB ${_home_end}MiB"
                fi
                HOME_PART=$(part_name "$DISK_ROOT" "$part_num")
            fi
        fi
        run "parted -s $DISK_ROOT set $(echo "$ROOT_PART" | grep -oE '[0-9]+$') boot on"

    else
        # UEFI fresh install
        warn "Wiping $DISK_ROOT and creating new GPT partition table…"
        run "sgdisk --zap-all $DISK_ROOT"
        run "sgdisk -o $DISK_ROOT"

        run "sgdisk -n 1:0:+${EFI_SIZE_MB}M -t 1:ef00 -c 1:EFI $DISK_ROOT"
        EFI_PART=$(part_name "$DISK_ROOT" "1")
        part_num=2

        if [[ "$SWAP_TYPE" == "partition" ]]; then
            run "sgdisk -n ${part_num}:0:+${SWAP_SIZE}G -t ${part_num}:8200 -c ${part_num}:swap $DISK_ROOT"
            SWAP_PART=$(part_name "$DISK_ROOT" "$part_num")
            part_num=$(( part_num + 1 ))
        fi

        if [[ "$ROOT_SIZE" == "rest" ]]; then
            run "sgdisk -n ${part_num}:0:0 -t ${part_num}:8300 -c ${part_num}:root $DISK_ROOT"
            ROOT_PART=$(part_name "$DISK_ROOT" "$part_num")
        else
            run "sgdisk -n ${part_num}:0:+${ROOT_SIZE}G -t ${part_num}:8300 -c ${part_num}:root $DISK_ROOT"
            ROOT_PART=$(part_name "$DISK_ROOT" "$part_num")
            part_num=$(( part_num + 1 ))
            if [[ "$SEP_HOME" == true && "$DISK_HOME" == "$DISK_ROOT" ]]; then
                if [[ "$HOME_SIZE" == "rest" ]]; then
                    run "sgdisk -n ${part_num}:0:0 -t ${part_num}:8302 -c ${part_num}:home $DISK_ROOT"
                else
                    run "sgdisk -n ${part_num}:0:+${HOME_SIZE}G -t ${part_num}:8302 -c ${part_num}:home $DISK_ROOT"
                fi
                HOME_PART=$(part_name "$DISK_ROOT" "$part_num")
            fi
        fi
    fi

    if [[ "$SEP_HOME" == true && "$DISK_HOME" != "$DISK_ROOT" ]]; then
        warn "Wiping $DISK_HOME for /home…"
        run "sgdisk --zap-all $DISK_HOME"
        run "sgdisk -o $DISK_HOME"
        if [[ "$HOME_SIZE" == "rest" ]]; then
            run "sgdisk -n 1:0:0 -t 1:8302 -c 1:home $DISK_HOME"
        else
            run "sgdisk -n 1:0:+${HOME_SIZE}G -t 1:8302 -c 1:home $DISK_HOME"
        fi
        HOME_PART=$(part_name "$DISK_HOME" "1")
    fi

    _refresh_partitions "$DISK_ROOT"
    if [[ "$DISK_HOME" != "$DISK_ROOT" ]]; then _refresh_partitions "$DISK_HOME"; fi

    ok "Partitions created"
    blank; lsblk "$DISK_ROOT" 2>/dev/null || true
    if [[ "$DISK_HOME" != "$DISK_ROOT" ]]; then lsblk "$DISK_HOME" 2>/dev/null || true; fi
}

# =============================================================================
#  PHASE 3 — LUKS ENCRYPTION
# =============================================================================
setup_luks() {
    if [[ "$USE_LUKS" == false ]]; then return 0; fi
    section "LUKS2 Encryption"

    info "Encrypting ${ROOT_PART}…"
    echo -n "$LUKS_PASSWORD" | run "cryptsetup luksFormat --type luks2 \
        --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
        --batch-mode $ROOT_PART -"
    echo -n "$LUKS_PASSWORD" | run "cryptsetup open --allow-discards --persistent $ROOT_PART cryptroot -"
    ROOT_PART_MAPPED="/dev/mapper/cryptroot"
    ok "LUKS container opened → ${ROOT_PART_MAPPED}"

    if [[ "$SEP_HOME" == true && -n "$HOME_PART" ]]; then
        blank
        if confirm_gum "Also encrypt /home with the same passphrase?"; then
            echo -n "$LUKS_PASSWORD" | run "cryptsetup luksFormat --type luks2 \
                --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
                --batch-mode $HOME_PART -"
            echo -n "$LUKS_PASSWORD" | run "cryptsetup open --allow-discards --persistent $HOME_PART crypthome -"
            HOME_PART="/dev/mapper/crypthome"
            ok "/home encrypted → ${HOME_PART}"
        fi
    fi
}

# =============================================================================
#  PHASE 3 — FORMAT FILESYSTEMS
# =============================================================================
format_filesystems() {
    section "Formatting Filesystems"

    local root_dev="${ROOT_PART_MAPPED:-$ROOT_PART}"

    if [[ "$FIRMWARE_MODE" == "bios" ]]; then
        ok "BIOS mode — no EFI partition to format"
    elif [[ "$DUAL_BOOT" == true ]]; then
        ok "Multi-boot: reusing existing EFI partition: $EFI_PART (not reformatted)"
    elif [[ "$REUSE_EFI" == false ]]; then
        run "mkfs.fat -F32 -n EFI $EFI_PART"
        ok "EFI formatted → FAT32 ($EFI_PART)"
    else
        ok "Reusing existing EFI: $EFI_PART"
    fi

    case "$ROOT_FS" in
        btrfs) run "mkfs.btrfs -f -L arch_root $root_dev" ;;
        ext4)  run "mkfs.ext4  -F -L arch_root $root_dev" ;;
        xfs)   run "mkfs.xfs   -f -L arch_root $root_dev" ;;
        f2fs)  run "mkfs.f2fs  -f -l arch_root $root_dev" ;;
    esac
    ok "Root formatted → ${ROOT_FS} ($root_dev)"

    if [[ "$SEP_HOME" == true && -n "$HOME_PART" ]]; then
        case "$HOME_FS" in
            btrfs) run "mkfs.btrfs -f -L arch_home $HOME_PART" ;;
            ext4)  run "mkfs.ext4  -F -L arch_home $HOME_PART" ;;
            xfs)   run "mkfs.xfs   -f -L arch_home $HOME_PART" ;;
            f2fs)  run "mkfs.f2fs  -f -l arch_home $HOME_PART" ;;
        esac
        ok "Home formatted → ${HOME_FS} ($HOME_PART)"
    fi

    if [[ "$SWAP_TYPE" == "partition" && -n "$SWAP_PART" ]]; then
        run "mkswap -L arch_swap $SWAP_PART"
        ok "Swap partition formatted ($SWAP_PART)"
    fi
}

# =============================================================================
#  PHASE 3 — BTRFS SUBVOLUMES
# =============================================================================
create_subvolumes() {
    if [[ "$ROOT_FS" != "btrfs" ]]; then
        info "Filesystem is ${ROOT_FS} — skipping btrfs subvolume creation"
        return 0
    fi

    section "Creating btrfs Subvolumes"
    local root_dev="${ROOT_PART_MAPPED:-$ROOT_PART}"
    run "mount $root_dev /mnt"

    local subvols=("@" "@home" "@snapshots" "@var_log" "@var_cache" "@tmp")
    if [[ "$SWAP_TYPE" == "file" ]]; then subvols+=("@swap"); fi

    for sv in "${subvols[@]}"; do
        run "btrfs subvolume create /mnt/$sv"
        ok "  subvol: $sv"
    done

    run "umount /mnt"
    ok "Subvolumes created"
}

# =============================================================================
#  PHASE 3 — MOUNT FILESYSTEMS
# =============================================================================
mount_filesystems() {
    section "Mounting Filesystems"

    local root_dev="${ROOT_PART_MAPPED:-$ROOT_PART}"
    local btrfs_opts="noatime,compress=zstd:1,space_cache=v2,discard=async"
    local ext4_opts="noatime,discard"
    local xfs_opts="noatime,discard,logbufs=8"
    local f2fs_opts="noatime,lazytime,discard"

    local esp_mount="boot/efi"
    if [[ "$BOOTLOADER" == "systemd-boot" ]]; then esp_mount="boot"; fi

    if [[ "$ROOT_FS" == "btrfs" ]]; then
        run "mount -o ${btrfs_opts},subvol=@ $root_dev /mnt"
        ok "@ → /mnt  (btrfs)"
        run "mkdir -p /mnt/{${esp_mount},home,var/log,var/cache,tmp,.snapshots}"
        if [[ "$SWAP_TYPE" == "file" ]]; then run "mkdir -p /mnt/swap"; fi
        run "mount -o ${btrfs_opts},subvol=@snapshots $root_dev /mnt/.snapshots"
        run "mount -o ${btrfs_opts},subvol=@var_log    $root_dev /mnt/var/log"
        run "mount -o ${btrfs_opts},subvol=@var_cache  $root_dev /mnt/var/cache"
        run "mount -o ${btrfs_opts},subvol=@tmp        $root_dev /mnt/tmp"
        run "chattr +C /mnt/var/log"
        ok "@snapshots @var_log @var_cache @tmp mounted (CoW disabled on var/log)"
    else
        local root_opts
        case "$ROOT_FS" in
            ext4) root_opts="$ext4_opts" ;;
            xfs)  root_opts="$xfs_opts"  ;;
            f2fs) root_opts="$f2fs_opts" ;;
            *)    root_opts="noatime"    ;;
        esac
        run "mount -o ${root_opts} $root_dev /mnt"
        ok "/ → /mnt  (${ROOT_FS})"
        run "mkdir -p /mnt/{${esp_mount},home,var/log,var/cache,tmp}"
        if [[ "$SWAP_TYPE" == "file" ]]; then run "mkdir -p /mnt/swap"; fi
    fi

    if [[ "$SEP_HOME" == true && -n "$HOME_PART" ]]; then
        if [[ "$HOME_FS" == "btrfs" ]]; then
            run "mount $HOME_PART /mnt/home"
            run "btrfs subvolume create /mnt/home/@home"
            run "umount /mnt/home"
            run "mount -o ${btrfs_opts},subvol=@home $HOME_PART /mnt/home"
            ok "Home → /mnt/home  (btrfs @home)"
        else
            local home_opts
            case "$HOME_FS" in
                ext4) home_opts="$ext4_opts" ;;
                xfs)  home_opts="$xfs_opts"  ;;
                f2fs) home_opts="$f2fs_opts" ;;
                *)    home_opts="noatime"    ;;
            esac
            run "mount -o ${home_opts} $HOME_PART /mnt/home"
            ok "Home → /mnt/home  (${HOME_FS})"
        fi
    else
        if [[ "$ROOT_FS" == "btrfs" ]]; then
            run "mount -o ${btrfs_opts},subvol=@home $root_dev /mnt/home"
            ok "@home → /mnt/home"
        fi
    fi

    if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
        if [[ -z "$EFI_PART" ]]; then die "EFI_PART is not set — cannot mount EFI partition"; fi
        run "mount $EFI_PART /mnt/${esp_mount}"
        ok "EFI → /mnt/${esp_mount}"
    else
        ok "BIOS mode — no EFI partition to mount"
    fi

    if [[ "$SWAP_TYPE" == "partition" ]]; then
        run "swapon $SWAP_PART"; ok "Swap partition active"
    elif [[ "$SWAP_TYPE" == "file" ]]; then
        if [[ "$ROOT_FS" == "btrfs" ]]; then
            run "mount -o ${btrfs_opts},subvol=@swap $root_dev /mnt/swap"
            run "btrfs filesystem mkswapfile --size ${SWAP_SIZE}g /mnt/swap/swapfile"
        else
            run "fallocate -l ${SWAP_SIZE}G /mnt/swap/swapfile"
            run "chmod 600 /mnt/swap/swapfile"
            run "mkswap /mnt/swap/swapfile"
        fi
        run "swapon /mnt/swap/swapfile"
        ok "Swap file active (/swap/swapfile, ${SWAP_SIZE}GB)"
    fi
}

# =============================================================================
#  PHASE 4 — MIRRORS & PACSTRAP
# =============================================================================
setup_mirrors() {
    if [[ "$USE_REFLECTOR" == false ]]; then return 0; fi
    section "Optimizing Pacman Mirrors"
    info "Countries: ${REFLECTOR_COUNTRIES} | Mirrors: ${REFLECTOR_NUMBER} | Age ≤${REFLECTOR_AGE}h"

    local country_args=""
    IFS=',' read -ra _countries <<< "$REFLECTOR_COUNTRIES"
    for _c in "${_countries[@]}"; do
        _c="${_c#"${_c%%[![:space:]]*}"}"; _c="${_c%"${_c##*[![:space:]]}"}"
        [[ -n "$_c" ]] && country_args+="--country \"${_c}\" "
    done

    run "reflector ${country_args}--protocol ${REFLECTOR_PROTOCOL} --age ${REFLECTOR_AGE} --latest 20 --number ${REFLECTOR_NUMBER} --sort rate --save /etc/pacman.d/mirrorlist"
    ok "Mirrorlist updated"
}

install_base() {
    section "Installing Base System (pacstrap)"

    local pkgs="base base-devel ${KERNEL} ${KERNEL}-headers linux-firmware dosfstools mtools"

    local all_fs="${ROOT_FS} ${HOME_FS}"
    echo "$all_fs" | grep -q "btrfs" && pkgs+=" btrfs-progs"
    echo "$all_fs" | grep -q "ext4"  && pkgs+=" e2fsprogs"
    echo "$all_fs" | grep -q "xfs"   && pkgs+=" xfsprogs"
    echo "$all_fs" | grep -q "f2fs"  && pkgs+=" f2fs-tools"

    [[ "$CPU_VENDOR" == "intel" ]] && pkgs+=" intel-ucode"
    [[ "$CPU_VENDOR" == "amd"   ]] && pkgs+=" amd-ucode"

    pkgs+=" networkmanager network-manager-applet"
    pkgs+=" iwd wpa_supplicant wireless_tools"
    pkgs+=" git curl wget rsync"
    pkgs+=" nano vim neovim"
    pkgs+=" sudo bash-completion"
    pkgs+=" htop btop fastfetch"
    pkgs+=" zip unzip tar"
    pkgs+=" man-db man-pages"
    pkgs+=" pacman-contrib"
    pkgs+=" xdg-utils xdg-user-dirs"
    pkgs+=" smartmontools openssh"

    if [[ "$DUAL_BOOT" == true ]]; then pkgs+=" os-prober ntfs-3g fuse2"; fi
    if [[ "$USE_AMD_VULKAN" == true ]]; then
        pkgs+=" vulkan-radeon libva-mesa-driver"
        if [[ "$USE_MULTILIB" == true ]]; then pkgs+=" lib32-mesa lib32-vulkan-radeon"; fi
    fi
    if [[ "$USE_REFLECTOR" == true ]]; then pkgs+=" reflector"; fi
    if [[ "$USE_SNAPPER"   == true ]]; then pkgs+=" snapper snap-pac grub-btrfs"; fi

    info "Configuring live ISO pacman…"
    sed -i 's/^#Color/Color/'                               /etc/pacman.conf 2>/dev/null || true
    sed -i 's/^#VerbosePkgLists/VerbosePkgLists/'           /etc/pacman.conf 2>/dev/null || true
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf 2>/dev/null || true
    grep -q "ILoveCandy" /etc/pacman.conf 2>/dev/null \
        || sed -i '/^Color/a ILoveCandy' /etc/pacman.conf 2>/dev/null || true
    ok "Live ISO pacman: Color + ParallelDownloads=5 + ILoveCandy"
    blank

    info "Packages to install: ${pkgs}"
    blank
    info "Running pacstrap — this will take several minutes…"
    run "pacstrap -K /mnt $pkgs"
    ok "Base system installed"

    run "genfstab -U /mnt >> /mnt/etc/fstab"
    ok "fstab generated"
}

# =============================================================================
#  PHASE 5 — GENERATE CHROOT CONFIGURATION SCRIPT
# =============================================================================
generate_chroot_script() {
    section "Generating Chroot Configuration Script"

    # ── Resolve desktop packages and display manager ──────────────────────────
    local all_de_pkgs="" dm_service="" has_wayland=false

    for de in "${DESKTOPS[@]}"; do
        case "$de" in
            kde)
                all_de_pkgs+=" plasma plasma-desktop plasma-nm plasma-pa plasma-workspace"
                all_de_pkgs+=" sddm dolphin konsole kate spectacle gwenview ark kcalc"
                all_de_pkgs+=" okular kdeconnect powerdevil plasma-disks"
                dm_service="sddm"; has_wayland=true ;;
            gnome)
                all_de_pkgs+=" gnome gnome-extra gnome-tweaks gdm gnome-software-packagekit-plugin"
                [[ -z "$dm_service" ]] && dm_service="gdm"; has_wayland=true ;;
            hyprland)
                all_de_pkgs+=" hyprland waybar wofi kitty ttf-font-awesome noto-fonts"
                all_de_pkgs+=" polkit-gnome xdg-desktop-portal-hyprland sddm"
                dm_service="sddm"; has_wayland=true ;;
            sway)
                all_de_pkgs+=" sway waybar swaylock swayidle foot wofi brightnessctl"
                all_de_pkgs+=" xdg-desktop-portal-wlr ly"
                [[ -z "$dm_service" ]] && dm_service="ly"; has_wayland=true ;;
            cosmic)
                all_de_pkgs+=" cosmic cosmic-greeter"
                [[ -z "$dm_service" ]] && dm_service="cosmic-greeter"; has_wayland=true ;;
            xfce)
                all_de_pkgs+=" xfce4 xfce4-goodies lightdm lightdm-gtk-greeter"
                all_de_pkgs+=" gvfs xarchiver network-manager-applet mousepad ristretto"
                [[ -z "$dm_service" ]] && dm_service="lightdm" ;;
            none) ;;
        esac
    done
    # sddm wins for KDE/Hyprland (second pass)
    for de in "${DESKTOPS[@]}"; do
        [[ "$de" == "kde" || "$de" == "hyprland" ]] && dm_service="sddm" && break
    done

    local nvidia_pkgs=""
    if [[ "$USE_NVIDIA" == true ]]; then
        nvidia_pkgs="nvidia nvidia-utils nvidia-settings"
        [[ "$USE_MULTILIB" == true ]] && nvidia_pkgs+=" lib32-nvidia-utils"
        [[ "$has_wayland"  == true ]] && nvidia_pkgs+=" egl-wayland"
    fi

    local bootloader_pkgs="efibootmgr"
    if [[ "$FIRMWARE_MODE" == "bios" ]]; then bootloader_pkgs="grub"
    else
        [[ "$BOOTLOADER" == "grub" ]] && bootloader_pkgs+=" grub"
        [[ "$DUAL_BOOT" == true && "$BOOTLOADER" == "grub" ]] && bootloader_pkgs+=" os-prober"
        [[ "$USE_SNAPPER" == true && "$BOOTLOADER" == "grub" ]] && bootloader_pkgs+=" grub-btrfs"
        [[ "$SECURE_BOOT" == true ]] && bootloader_pkgs+=" sbctl"
    fi

    # Collect UUIDs from host (must be done before chroot)
    local root_uuid luks_uuid
    if [[ "$DRY_RUN" == false ]]; then
        local _rdev="${ROOT_PART_MAPPED:-$ROOT_PART}"
        root_uuid=$(blkid -s UUID -o value "$_rdev"     2>/dev/null || echo "ROOT-UUID")
        luks_uuid=$(blkid -s UUID -o value "$ROOT_PART" 2>/dev/null || echo "LUKS-UUID")
    else
        root_uuid="DRY-ROOT-UUID"; luks_uuid="DRY-LUKS-UUID"
    fi

    local mkinit_hooks="base udev autodetect microcode modconf kms keyboard keymap consolefont block"
    [[ "$USE_LUKS" == true ]] && mkinit_hooks+=" encrypt"
    mkinit_hooks+=" filesystems fsck"

    local kernel_img="vmlinuz-${KERNEL}"
    local initrd_img="initramfs-${KERNEL}.img"

    local sd_options
    if [[ "$ROOT_FS" == "btrfs" ]]; then
        sd_options="root=UUID=${root_uuid} rootflags=subvol=@ rw quiet splash"
        [[ "$USE_LUKS" == true ]] && \
            sd_options="cryptdevice=UUID=${luks_uuid}:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet"
    else
        sd_options="root=UUID=${root_uuid} rw quiet splash"
        [[ "$USE_LUKS" == true ]] && \
            sd_options="cryptdevice=UUID=${luks_uuid}:cryptroot root=/dev/mapper/cryptroot rw quiet"
    fi

    local S=/mnt/archwizard-configure.sh
    : > "$S"

    # ── Header ────────────────────────────────────────────────────────────────
    cat >> "$S" << 'HDR'
#!/usr/bin/env bash
set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()      { echo -e "${GREEN}${BOLD}[ OK ]${NC}  $*"; }
info()    { echo -e "${CYAN}${BOLD}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}${BOLD}[ERR ]${NC}  $*" >&2; }
section() { echo -e "\n${CYAN}${BOLD}━━━  $*  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
trap 'error "Chroot config failed at line $LINENO — command: ${BASH_COMMAND}"' ERR

section "Keyring Refresh"
pacman -Sy --noconfirm archlinux-keyring 2>/dev/null || true
ok "archlinux-keyring refreshed"
HDR

    # Timezone
    cat >> "$S" << TZEOF

section "Timezone & Clock"
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc
ok "Timezone: ${TIMEZONE}"
TZEOF

    # Locale
    cat >> "$S" << LOCEOF

section "Locale & Console"
echo "${LOCALE} UTF-8" >> /etc/locale.gen
grep -q "en_US.UTF-8" /etc/locale.gen || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}"   > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
ok "Locale: ${LOCALE} | Keymap: ${KEYMAP}"
LOCEOF

    # Hostname
    cat >> "$S" << HOSTEOF

section "Hostname"
echo "${HOSTNAME}" > /etc/hostname
{ echo "127.0.0.1  localhost"
  echo "::1        localhost"
  echo "127.0.1.1  ${HOSTNAME}.localdomain  ${HOSTNAME}"; } > /etc/hosts
ok "Hostname: ${HOSTNAME}"
HOSTEOF

    # Pacman tweaks
    cat >> "$S" << 'PACEOF'

section "Pacman Tweaks"
sed -i 's/^#Color/Color/'                               /etc/pacman.conf
sed -i 's/^#VerbosePkgLists/VerbosePkgLists/'           /etc/pacman.conf
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
grep -q "ILoveCandy" /etc/pacman.conf || sed -i '/^Color/a ILoveCandy' /etc/pacman.conf
ok "pacman: colour + parallel downloads + ILoveCandy"
PACEOF

    # makepkg tuning
    cat >> "$S" << 'MKPEOF'

section "makepkg.conf — Compiler Optimisation"
NPROC=$(nproc)
sed -i "s/^#MAKEFLAGS=.*/MAKEFLAGS=\"-j${NPROC}\"/" /etc/makepkg.conf
sed -i "s/-march=x86-64 -mtune=generic/-march=native -mtune=native/" /etc/makepkg.conf
grep -q "^RUSTFLAGS=" /etc/makepkg.conf \
    && sed -i 's/^RUSTFLAGS=.*/RUSTFLAGS="-C opt-level=2 -C target-cpu=native"/' /etc/makepkg.conf \
    || echo 'RUSTFLAGS="-C opt-level=2 -C target-cpu=native"' >> /etc/makepkg.conf
ok "makepkg: -j${NPROC} | -march=native | RUSTFLAGS=target-cpu=native"
MKPEOF

    # Kernel hardening
    cat >> "$S" << 'SYSCTLEOF'

section "Kernel Hardening — sysctl"
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-security.conf << 'SYSEOF'
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
SYSEOF
ok "Kernel hardening sysctl written"
SYSCTLEOF

    # Journal cap
    cat >> "$S" << 'JRNEOF'

section "systemd Journal — Size Cap"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/00-journal.conf << 'JEOF'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=50M
MaxRetentionSec=2week
JEOF
ok "Journal capped at 200 MB persistent + 50 MB runtime"
JRNEOF

    # Multilib
    if [[ "$USE_MULTILIB" == true ]]; then
        cat >> "$S" << 'MLEOF'

section "Multilib"
sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' /etc/pacman.conf
pacman -Sy --noconfirm
ok "Multilib repository enabled"
MLEOF
    fi

    # Reflector
    if [[ "$USE_REFLECTOR" == true ]]; then
        local _ref_country_args=""
        IFS=',' read -ra _ref_countries <<< "$REFLECTOR_COUNTRIES"
        for _c in "${_ref_countries[@]}"; do
            _c="${_c#"${_c%%[![:space:]]*}"}"; _c="${_c%"${_c##*[![:space:]]}"}"
            [[ -n "$_c" ]] && _ref_country_args+="--country \"${_c}\" "
        done
        local _ref_conf_lines=""
        IFS=',' read -ra _conf_countries <<< "$REFLECTOR_COUNTRIES"
        for _cc in "${_conf_countries[@]}"; do
            _cc="${_cc#"${_cc%%[![:space:]]*}"}"; _cc="${_cc%"${_cc##*[![:space:]]}"}"
            [[ -n "$_cc" ]] && _ref_conf_lines+="--country ${_cc}\n"
        done

        cat >> "$S" << REFEOF

section "Reflector — Mirror Optimisation"
reflector ${_ref_country_args}--protocol ${REFLECTOR_PROTOCOL} --age ${REFLECTOR_AGE} --latest 20 --number ${REFLECTOR_NUMBER} --sort rate --save /etc/pacman.d/mirrorlist
mkdir -p /etc/xdg/reflector
printf '%b' "${_ref_conf_lines}--protocol ${REFLECTOR_PROTOCOL}\n--age ${REFLECTOR_AGE}\n--latest 20\n--number ${REFLECTOR_NUMBER}\n--sort rate\n--save /etc/pacman.d/mirrorlist\n" > /etc/xdg/reflector/reflector.conf
ok "Mirrors optimised + reflector.conf written for timer"
REFEOF
    fi

    # Bootloader packages
    cat >> "$S" << BPEOF

section "Bootloader Packages"
pacman -S --noconfirm --ask 4 --needed ${bootloader_pkgs}
ok "Bootloader packages installed"
BPEOF

    # Desktop packages
    if [[ -n "${all_de_pkgs// /}" ]]; then
        cat >> "$S" << DEEOF

section "Desktop Environments: ${DESKTOPS[*]}"
pacman -S --noconfirm --ask 4 --needed ${all_de_pkgs}
ok "Desktop(s) installed"
DEEOF
    fi

    # PipeWire
    if [[ "$USE_PIPEWIRE" == true ]]; then
        cat >> "$S" << 'PWEOF'

section "Audio — PipeWire"
pacman -S --noconfirm --ask 4 --needed pipewire pipewire-alsa pipewire-pulse wireplumber
if pacman -Qq jack2 &>/dev/null; then
    pacman -S --noconfirm --ask 4 --needed pipewire-jack
    ok "PipeWire + pipewire-jack installed (jack2 replaced)"
else
    pacman -S --noconfirm --ask 4 --needed pipewire-jack
    ok "PipeWire + JACK bridge installed"
fi
PWEOF
    fi

    # NVIDIA
    if [[ -n "$nvidia_pkgs" ]]; then
        cat >> "$S" << NVEOF

section "NVIDIA Drivers"
pacman -S --noconfirm --ask 4 --needed ${nvidia_pkgs}
echo 'options nvidia_drm modeset=1 fbdev=1' > /etc/modprobe.d/nvidia.conf
ok "NVIDIA drivers installed + DRM modesetting enabled"
NVEOF
    fi

    # Bluetooth
    if [[ "$USE_BLUETOOTH" == true ]]; then
        cat >> "$S" << 'BTEOF'

section "Bluetooth"
pacman -S --noconfirm --ask 4 --needed bluez bluez-utils
systemctl enable bluetooth
ok "Bluetooth enabled"
BTEOF
    fi

    # CUPS
    if [[ "$USE_CUPS" == true ]]; then
        cat >> "$S" << 'CPEOF'

section "CUPS Printing"
pacman -S --noconfirm --ask 4 --needed cups cups-pdf system-config-printer
systemctl enable cups
ok "CUPS enabled"
CPEOF
    fi

    # mkinitcpio
    cat >> "$S" << MKEOF

section "mkinitcpio — Initramfs"
sed -i 's|^HOOKS=.*|HOOKS=(${mkinit_hooks})|' /etc/mkinitcpio.conf
mkinitcpio -P
ok "Initramfs generated"
MKEOF

    # ── GRUB ─────────────────────────────────────────────────────────────────
    if [[ "$BOOTLOADER" == "grub" ]]; then
        {
            echo 'section "GRUB Bootloader"'
            if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
                echo '_hostname=$(cat /etc/hostname 2>/dev/null | tr -d " " || echo arch)'
                echo '_mid=$(cat /etc/machine-id 2>/dev/null | head -c6 || echo 000000)'
                echo 'GRUB_ID="Arch-${_hostname}-${_mid}"'
                echo 'grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$GRUB_ID" --recheck'
                echo 'ok "GRUB installed — EFI entry: ${GRUB_ID}"'
            else
                echo "grub-install --target=i386-pc ${DISK_ROOT}"
                echo "ok \"GRUB installed to MBR of ${DISK_ROOT}\""
            fi
        } >> "$S"

        cat >> "$S" << GNEOF
if grep -q '^GRUB_DISTRIBUTOR=' /etc/default/grub; then
    sed -i 's|^GRUB_DISTRIBUTOR=.*|GRUB_DISTRIBUTOR="${GRUB_ENTRY_NAME}"|' /etc/default/grub
else
    echo 'GRUB_DISTRIBUTOR="${GRUB_ENTRY_NAME}"' >> /etc/default/grub
fi
ok "GRUB boot menu name: ${GRUB_ENTRY_NAME}"
GNEOF

        if [[ "$DUAL_BOOT" == true ]]; then
            cat >> "$S" << 'OSPEOF'
if grep -q 'GRUB_DISABLE_OS_PROBER' /etc/default/grub; then
    sed -i 's/.*GRUB_DISABLE_OS_PROBER.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
else
    echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
fi
ok "GRUB_DISABLE_OS_PROBER=false set"
OSPEOF
        fi

        if [[ "$USE_LUKS" == true ]]; then
            if [[ "$ROOT_FS" == "btrfs" ]]; then
                echo "sed -i 's|^GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=${luks_uuid}:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@\"|' /etc/default/grub" >> "$S"
            else
                echo "sed -i 's|^GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=${luks_uuid}:cryptroot root=/dev/mapper/cryptroot\"|' /etc/default/grub" >> "$S"
            fi
        fi

        if [[ "$ROOT_FS" == "btrfs" && "$USE_LUKS" == false ]]; then
            echo "sed -i 's|^GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"rootflags=subvol=@\"|' /etc/default/grub" >> "$S"
        fi

        if [[ "$USE_NVIDIA" == true ]]; then
            echo "sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=\"|GRUB_CMDLINE_LINUX_DEFAULT=\"nvidia_drm.modeset=1 |' /etc/default/grub" >> "$S"
        fi

        if [[ "$USE_SNAPPER" == true ]]; then
            echo "systemctl enable grub-btrfsd" >> "$S"
        fi

        cat >> "$S" << 'GRUB2EOF'
_osp_base="/mnt/osprober"
mkdir -p "$_osp_base"
_osp_dirs=()
_osp_idx=0
_cur_root=$(findmnt -n -o SOURCE / 2>/dev/null || echo "none")
while IFS=' ' read -r _dev _fstype; do
    [[ -z "$_dev" ]] && continue
    findmnt -S "$_dev" > /dev/null 2>&1 && continue
    [[ "$_dev" == "$_cur_root" ]] && continue
    _pt=$(lsblk -no PARTTYPE "$_dev" 2>/dev/null || echo "")
    [[ "$_pt" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] && continue
    [[ "$_pt" == "0657fd6d-a4ab-43c4-84e5-0933c84b4f4f" ]] && continue
    _osp_dir="${_osp_base}/${_osp_idx}"
    mkdir -p "$_osp_dir"
    if [[ "$_fstype" == "btrfs" ]]; then
        mount -o ro,noexec,nosuid,subvol=@ "$_dev" "$_osp_dir" 2>/dev/null \
        || mount -o ro,noexec,nosuid       "$_dev" "$_osp_dir" 2>/dev/null || continue
    else
        mount -o ro,noexec,nosuid "$_dev" "$_osp_dir" 2>/dev/null || continue
    fi
    _osp_dirs+=("$_osp_dir")
    _osp_idx=$(( _osp_idx + 1 ))
done < <(lsblk -ln -o PATH,FSTYPE | awk '$2 ~ /^(btrfs|ext4|xfs|f2fs|ntfs)$/ {print $1, $2}')
os-prober 2>/dev/null || true
grub-mkconfig -o /boot/grub/grub.cfg
for _d in "${_osp_dirs[@]}"; do umount "$_d" 2>/dev/null || true; rmdir "$_d" 2>/dev/null || true; done
rmdir "$_osp_base" 2>/dev/null || true
ok "GRUB configured — all partitions scanned by os-prober"
GRUB2EOF

    # ── systemd-boot ─────────────────────────────────────────────────────────
    elif [[ "$BOOTLOADER" == "systemd-boot" ]]; then
        cat >> "$S" << 'SDEOF'

section "systemd-boot"
bootctl install --esp-path=/boot
mkdir -p /boot/loader/entries
cat > /boot/loader/loader.conf << 'LOADEREOF'
default arch.conf
timeout 5
console-mode max
editor no
LOADEREOF
SDEOF
        {
            echo "cat > /boot/loader/entries/arch.conf << 'ENTRYEOF'"
            echo "title   ${GRUB_ENTRY_NAME}"
            echo "linux   /${kernel_img}"
            [[ "$CPU_VENDOR" != "unknown" ]] && echo "initrd  /${CPU_VENDOR}-ucode.img"
            echo "initrd  /${initrd_img}"
            echo "options ${sd_options}"
            echo "ENTRYEOF"
            echo "cat > /boot/loader/entries/arch-fallback.conf << 'FBEOF'"
            echo "title   ${GRUB_ENTRY_NAME} (fallback)"
            echo "linux   /${kernel_img}"
            [[ "$CPU_VENDOR" != "unknown" ]] && echo "initrd  /${CPU_VENDOR}-ucode.img"
            echo "initrd  /initramfs-${KERNEL}-fallback.img"
            echo "options ${sd_options}"
            echo "FBEOF"
            echo "systemctl enable systemd-boot-update.service"
            echo "ok \"systemd-boot installed and configured\""
        } >> "$S"
    fi

    # ── User accounts ─────────────────────────────────────────────────────────
    cat >> "$S" << USREOF

section "User Accounts"
useradd -mG wheel,audio,video,optical,storage,network,input "${USERNAME}"
xdg-user-dirs-update --force 2>/dev/null || true
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd
echo "root:${ROOT_PASSWORD}"        | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
ok "User '${USERNAME}' created with sudo (wheel)"
USREOF

    # ── Core services ─────────────────────────────────────────────────────────
    cat >> "$S" << 'SVCEOF'

section "Enabling Core Services"
systemctl enable NetworkManager
systemctl enable systemd-resolved
systemctl enable fstrim.timer
systemctl enable systemd-oomd
systemctl enable paccache.timer
SVCEOF
    [[ -n "$dm_service" ]]         && echo "systemctl enable ${dm_service}" >> "$S"
    [[ "$USE_REFLECTOR" == true ]] && echo "systemctl enable reflector.timer" >> "$S"
    echo 'ok "Core services enabled"' >> "$S"

    # ── Snapper ──────────────────────────────────────────────────────────────
    if [[ "$USE_SNAPPER" == true ]]; then
        cat >> "$S" << 'SNAPEOF'

section "Snapper — btrfs Auto-Snapshots"
umount /.snapshots 2>/dev/null || true
rm -rf /.snapshots
mkdir -p /.snapshots
mount -a
chmod 750 /.snapshots
chown :wheel /.snapshots 2>/dev/null || true
mkdir -p /etc/snapper/configs
cat > /etc/snapper/configs/root << 'SNACONF'
SUBVOLUME="/"; FSTYPE="btrfs"
ALLOW_GROUPS="wheel"; SYNC_ACL="no"
BACKGROUND_COMPARISON="yes"
NUMBER_CLEANUP="yes"; NUMBER_MIN_AGE="1800"; NUMBER_LIMIT="10"; NUMBER_LIMIT_IMPORTANT="10"
TIMELINE_CREATE="yes"; TIMELINE_CLEANUP="yes"; TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="5"; TIMELINE_LIMIT_DAILY="7"; TIMELINE_LIMIT_WEEKLY="2"
TIMELINE_LIMIT_MONTHLY="1"; TIMELINE_LIMIT_YEARLY="0"
EMPTY_PRE_POST_CLEANUP="yes"; EMPTY_PRE_POST_MIN_AGE="1800"
SNACONF
mkdir -p /etc/conf.d
echo 'SNAPPER_CONFIGS="root"' > /etc/conf.d/snapper
systemctl enable snapper-timeline.timer snapper-cleanup.timer snapper-boot.timer
ok "Snapper configured"
SNAPEOF
    fi

    # ── Firewall ─────────────────────────────────────────────────────────────
    if [[ "$FIREWALL" == "nftables" ]]; then
        cat >> "$S" << 'NFTEOF'

section "Firewall — nftables"
pacman -S --noconfirm --ask 4 --needed nftables
cat > /etc/nftables.conf << 'NFTRULES'
#!/usr/bin/nft -f
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        ct state invalid drop
        ct state { established, related } accept
        iifname lo accept
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
        counter drop
    }
    chain forward { type filter hook forward priority filter; policy drop; }
    chain output  { type filter hook output  priority filter; policy accept; }
}
NFTRULES
systemctl enable nftables
ok "nftables enabled with stateful desktop ruleset"
NFTEOF
    elif [[ "$FIREWALL" == "ufw" ]]; then
        cat >> "$S" << 'UFWEOF'

section "Firewall — ufw"
pacman -S --noconfirm --ask 4 --needed ufw
mkdir -p /etc/default
printf 'IPV6=yes\nDEFAULT_INPUT_POLICY="DROP"\nDEFAULT_OUTPUT_POLICY="ACCEPT"\nDEFAULT_FORWARD_POLICY="DROP"\nDEFAULT_APPLICATION_POLICY="SKIP"\nMANAGE_BUILTINS=no\n' > /etc/default/ufw
mkdir -p /etc/ufw
printf 'ENABLED=yes\nLOGLEVEL=low\n' > /etc/ufw/ufw.conf
systemctl enable ufw
ok "ufw installed and enabled — firewall active on first boot"
UFWEOF
    fi

    # ── zram ─────────────────────────────────────────────────────────────────
    if [[ "$SWAP_TYPE" == "zram" ]]; then
        cat >> "$S" << 'ZRAMEOF'

section "zram Compressed Swap"
pacman -S --noconfirm --ask 4 --needed zram-generator
cat > /etc/systemd/zram-generator.conf << 'ZGENEOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
ZGENEOF
cat > /etc/sysctl.d/99-zram.conf << 'SWAPEOF'
vm.swappiness = 100
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
SWAPEOF
ok "zram configured (up to 8 GB compressed RAM swap, swappiness=100)"
ZRAMEOF
    fi

    if [[ "$SWAP_TYPE" == "file" ]]; then
        echo "echo '/swap/swapfile none swap defaults 0 0' >> /etc/fstab" >> "$S"
        echo 'ok "Swap file entry added to fstab"' >> "$S"
    fi

    # ── AUR helper ───────────────────────────────────────────────────────────
    if [[ "$AUR_HELPER" != "none" ]]; then
        cat >> "$S" << AUREOF

section "AUR Helper: ${AUR_HELPER}"
pacman -S --noconfirm --ask 4 --needed git base-devel
sudo -u ${USERNAME} bash -c '
    set -euo pipefail
    cd /tmp
    rm -rf "${AUR_HELPER}"
    git clone https://aur.archlinux.org/${AUR_HELPER}.git
    cd ${AUR_HELPER}
    makepkg -si --noconfirm
'
ok "${AUR_HELPER} installed"
AUREOF
    fi

    # Secure Boot reminder
    if [[ "$SECURE_BOOT" == true ]]; then
        cat >> "$S" << 'SBEOF'

section "Secure Boot — Post-Boot Steps Required"
info "sbctl is installed. After first boot run:"
info "  sudo sbctl enroll-keys --microsoft"
info "  sudo sbctl sign-all"
SBEOF
    fi

    # Footer
    cat >> "$S" << 'FTEOF'

section "Chroot Configuration Complete"
echo -e "\n\033[0;32m\033[1m  ✓  All chroot steps finished successfully.\033[0m\n"
FTEOF

    chmod +x "$S"
    ok "Chroot script written → /mnt/archwizard-configure.sh  ($(wc -l < "$S") lines)"
}

# =============================================================================
#  PHASE 5 — EXECUTE CHROOT
# =============================================================================
run_chroot() {
    section "Running arch-chroot Configuration"
    info "This step configures the installed system — may take several minutes…"
    run "arch-chroot /mnt /archwizard-configure.sh"
    ok "Chroot configuration complete"

    section "DNS — systemd-resolved stub symlink"
    run "ln -sf ../run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf"
    ok "resolv.conf → systemd-resolved stub resolver"
}

# =============================================================================
#  PHASE 6 — VERIFICATION
# =============================================================================
verify_installation() {
    section "Post-Installation Verification"
    local issues=0

    local kernel_path="/mnt/boot/vmlinuz-${KERNEL}"
    if [[ -f "$kernel_path" ]]; then ok "Kernel image found: ${kernel_path}"
    else warn "Kernel image NOT found at ${kernel_path}"; issues=$(( issues + 1 )); fi

    local initrd_path="/mnt/boot/initramfs-${KERNEL}.img"
    if [[ -f "$initrd_path" ]]; then ok "initramfs found"
    else warn "initramfs NOT found at ${initrd_path}"; issues=$(( issues + 1 )); fi

    if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
        if [[ "$BOOTLOADER" == "grub" ]]; then
            if efibootmgr 2>/dev/null | grep -qi "arch"; then
                ok "GRUB EFI entry found in UEFI NVRAM"
            else
                warn "No Arch GRUB entry found in UEFI NVRAM"; issues=$(( issues + 1 ))
            fi
            if [[ -f "/mnt/boot/grub/grub.cfg" ]]; then ok "grub.cfg found"
            else warn "grub.cfg NOT found"; issues=$(( issues + 1 )); fi
        elif [[ "$BOOTLOADER" == "systemd-boot" ]]; then
            if [[ -f "/mnt/boot/loader/entries/arch.conf" ]]; then ok "systemd-boot entry found"
            else warn "systemd-boot entry NOT found"; issues=$(( issues + 1 )); fi
        fi
    else
        if dd if="$DISK_ROOT" bs=512 count=1 2>/dev/null | strings | grep -qi "grub"; then
            ok "GRUB signature found in MBR"
        else
            warn "GRUB not detected in MBR of ${DISK_ROOT}"; issues=$(( issues + 1 ))
        fi
    fi

    if [[ -f "/mnt/etc/fstab" ]]; then
        local fstab_lines; fstab_lines=$(grep -c "^[^#]" /mnt/etc/fstab 2>/dev/null || echo 0)
        if (( fstab_lines > 0 )); then ok "fstab has ${fstab_lines} active entries"
        else warn "fstab appears empty"; issues=$(( issues + 1 )); fi
    else
        warn "fstab NOT found"; issues=$(( issues + 1 ))
    fi

    for svc in NetworkManager systemd-resolved; do
        if [[ -e "/mnt/etc/systemd/system/multi-user.target.wants/${svc}.service" ]] \
           || [[ -e "/mnt/etc/systemd/system/network-online.target.wants/${svc}.service" ]]; then
            ok "Service enabled: ${svc}"
        else
            warn "Service NOT enabled: ${svc}"; issues=$(( issues + 1 ))
        fi
    done

    if [[ -s "/mnt/etc/hostname" ]]; then
        ok "Hostname: $(cat /mnt/etc/hostname)"
    else
        warn "Hostname not set"; issues=$(( issues + 1 ))
    fi

    blank
    if (( issues == 0 )); then
        gum style --foreground "$GUM_C_OK" --bold \
            " ✔  All verification checks passed — installation looks healthy" 2>/dev/null \
            || printf '\033[0;32m  ✔  All checks passed.\033[0m\n'
    else
        warn "${issues} issue(s) found — see warnings above"
        warn "The system may still boot — review these points before rebooting"
    fi
    blank
}

# =============================================================================
#  PHASE 6 — CLEANUP & REBOOT
# =============================================================================
finish() {
    section "Cleanup"

    run "rm -f /mnt/archwizard-configure.sh"
    info "Unmounting all filesystems…"
    run "sync"
    run "swapoff -a" || true
    run "umount -R /mnt" || true
    if [[ "$USE_LUKS" == true && "$DRY_RUN" == false ]]; then
        cryptsetup close cryptroot 2>/dev/null || true
        cryptsetup close crypthome 2>/dev/null || true
    fi
    ok "All filesystems unmounted"

    blank
    gum style \
        --foreground "$GUM_C_OK" --bold \
        --border double --border-foreground "$GUM_C_OK" \
        --padding "1 4" --width "$GUM_WIDTH" \
        "🎉  ArchWizard installation complete!  🎉" "" \
        "Full log: /tmp/archwizard.log" "" \
        "➜  Remove installation media" \
        "➜  Type 'reboot' to boot into Arch Linux" 2>/dev/null \
        || printf '\033[0;32m  Installation complete! Remove media and reboot.\033[0m\n'
    blank

    if confirm_gum "Reboot now?"; then
        run "reboot"
    else
        info "Reboot manually with: reboot"
        info "Log: /tmp/archwizard.log"
    fi
}

# =============================================================================
#  MAIN MENU  (Phase 1 only — configuration)
# =============================================================================
_step_done() {
    case "$1" in
        1) [[ "$CPU_VENDOR" != "unknown" ]]       ;;
        2) [[ -n "$DISK_ROOT" ]]                  ;;
        3) [[ -n "$ROOT_SIZE" ]]                  ;;
        4) [[ -n "$HOSTNAME" ]]                   ;;
        5) [[ -n "$USERNAME" ]]                   ;;
        6) [[ -n "$KERNEL" && -n "$BOOTLOADER" ]] ;;
        7) [[ ${#DESKTOPS[@]} -gt 0 ]]            ;;
        8) [[ -n "$FIREWALL" ]]                   ;;
        *) return 1 ;;
    esac
}

_all_steps_done() {
    for n in 1 2 3 4 5 6 7 8; do _step_done "$n" || return 1; done
    return 0
}

_step_summary() {
    case "$1" in
        1) if _step_done 1; then printf 'cpu:%s  gpu:%s  kbd:%s  fw:%s' "$CPU_VENDOR" "$GPU_VENDOR" "$KEYMAP" "$FIRMWARE_MODE"
           else printf 'not done'; fi ;;
        2) if _step_done 2; then
               local s="$DISK_ROOT"
               [[ "$DISK_HOME" != "$DISK_ROOT" && -n "$DISK_HOME" ]] && s+="  home:${DISK_HOME}"
               [[ "$DUAL_BOOT" == true ]] && s+="  [multi-boot]"
               printf '%s' "$s"
           else printf 'not done'; fi ;;
        3) if _step_done 3; then
               local s="root=${ROOT_SIZE}GB [${ROOT_FS}]"
               [[ "$SEP_HOME" == true ]] && s+="  home=${HOME_SIZE}GB [${HOME_FS}]"
               s+="  swap=${SWAP_TYPE}"
               [[ "$USE_LUKS" == true ]] && s+="  LUKS2"
               printf '%s' "$s"
           else printf 'not done'; fi ;;
        4) if _step_done 4; then printf '%s  tz:%s  %s' "$HOSTNAME" "$TIMEZONE" "$LOCALE"
           else printf 'not done'; fi ;;
        5) if _step_done 5; then printf 'user:%s' "$USERNAME"
           else printf 'not done'; fi ;;
        6) if _step_done 6; then
               local s="${KERNEL}  boot:${BOOTLOADER}"
               [[ "$SECURE_BOOT" == true ]] && s+="  SecureBoot"
               printf '%s' "$s"
           else printf 'not done'; fi ;;
        7) if _step_done 7; then printf '%s' "${DESKTOPS[*]:-none}"
           else printf 'not done'; fi ;;
        8) if _step_done 8; then
               printf 'fw:%s  aur:%s%s%s' \
                   "$FIREWALL" "$AUR_HELPER" \
                   "$([[ "$USE_PIPEWIRE"  == true ]] && echo '  pipewire'  || echo '')" \
                   "$([[ "$USE_REFLECTOR" == true ]] && echo '  reflector' || echo '')"
           else printf 'not done'; fi ;;
    esac
}

_menu_entry() {
    local n="$1" label="$2"
    local summary; summary=$(_step_summary "$n")
    local tick
    if _step_done "$n"; then tick=$(_clr "$GUM_C_OK"  "✔")
    else                     tick=$(_clr "$GUM_C_ERR" "·"); fi
    local sum_col
    if _step_done "$n"; then sum_col=$(_clr "$GUM_C_DIM" "$summary")
    else                     sum_col=$(_clr "$GUM_C_ERR" "not done"); fi
    printf ' %s  Step %s — %-30s%s' "$tick" "$n" "$label" "$sum_col"
}

main_menu() {
    while true; do
        show_banner

        local e1 e2 e3 e4 e5 e6 e7 e8
        e1=$(_menu_entry 1 "Sanity checks & keyboard")
        e2=$(_menu_entry 2 "Disk discovery & selection")
        e3=$(_menu_entry 3 "Partition wizard")
        e4=$(_menu_entry 4 "System identity")
        e5=$(_menu_entry 5 "Users & passwords")
        e6=$(_menu_entry 6 "Kernel & bootloader")
        e7=$(_menu_entry 7 "Desktop environment")
        e8=$(_menu_entry 8 "Optional extras")

        local proceed_label="  ▶  Save config & proceed to installation"
        if _all_steps_done; then
            proceed_label="$(_clr "$GUM_C_OK" "  ▶  All steps done — proceed to installation!")"
        fi

        local choice
        choice=$(gum choose \
            --selected.foreground "$GUM_C_TITLE" \
            --cursor.foreground   "$GUM_C_ACCENT" \
            --height 15 \
            "$e1" "$e2" "$e3" "$e4" "$e5" "$e6" "$e7" "$e8" \
            "─────────────────────────────────────────────────────────────" \
            "  ⚡  Run all remaining steps in sequence" \
            "$proceed_label" \
            "  ✗  Quit")

        case "$choice" in
            *"Step 1"*)  sanity_checks; choose_keyboard ;;
            *"Step 2"*)  discover_disks; select_disks ;;
            *"Step 3"*)
                if ! _step_done 2; then
                    blank; warn "Complete Step 2 (disk selection) first"; sleep 2; continue
                fi
                partition_wizard ;;
            *"Step 4"*)  configure_system ;;
            *"Step 5"*)  configure_users ;;
            *"Step 6"*)  choose_kernel_bootloader ;;
            *"Step 7"*)  choose_desktop ;;
            *"Step 8"*)  choose_extras ;;
            *"Run all"*)
                if ! _step_done 1; then sanity_checks; choose_keyboard; fi
                if ! _step_done 2; then discover_disks; select_disks; fi
                if ! _step_done 3; then partition_wizard; fi
                if ! _step_done 4; then configure_system; fi
                if ! _step_done 5; then configure_users; fi
                if ! _step_done 6; then choose_kernel_bootloader; fi
                if ! _step_done 7; then choose_desktop; fi
                if ! _step_done 8; then choose_extras; fi ;;
            *"proceed to installation"*)
                if ! _all_steps_done; then
                    blank; warn "Please complete all steps before proceeding"; sleep 2; continue
                fi
                break ;;
            *"Quit"*|"─"*)
                blank; info "Quit — no changes made."; exit 0 ;;
        esac

        blank
        gum confirm \
            --affirmative "Back to menu" \
            --negative "" \
            --prompt.foreground "$GUM_C_DIM" \
            "  Press Enter to return to menu" 2>/dev/null || true
    done
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
                printf 'Usage: bash archwizardGum_2_0.sh [OPTIONS]\n\n'
                printf '  --dry-run           Show commands without executing\n'
                printf '  --verbose           Print every command (set -x)\n'
                printf '  --load-config FILE  Load saved config, skip Phase 1\n'
                printf '  --help              This message\n\n'
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

    if [[ "$DRY_RUN" == true ]]; then
        warn "DRY-RUN mode: no changes will be written to disk"
    fi

    # ── PHASE 1: Configuration ─────────────────────────────────────────────
    if [[ -n "$CONFIG_FILE" ]]; then
        sanity_checks
        choose_keyboard
        load_config "$CONFIG_FILE"
    else
        main_menu
    fi

    # ── Offer to save config ───────────────────────────────────────────────
    save_config

    # ── PHASE 2: Summary & final confirmation ─────────────────────────────
    show_summary

    # ── PHASE 3: Free space → partition → encrypt → format → mount ────────
    replace_partition
    resize_partitions
    create_partitions
    setup_luks
    format_filesystems
    create_subvolumes
    mount_filesystems

    # ── PHASE 4: Mirrors + install ────────────────────────────────────────
    setup_mirrors
    install_base

    # ── PHASE 5: Configure ────────────────────────────────────────────────
    generate_chroot_script
    run_chroot

    # ── PHASE 6: Verify + done ────────────────────────────────────────────
    verify_installation
    finish
}

main "$@"
