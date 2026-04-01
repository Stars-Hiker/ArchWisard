#!/usr/bin/env bash
# =============================================================================
#    █████╗ ██████╗  ██████╗██╗  ██╗    ██╗    ██╗██╗███████╗ █████╗ ██████╗ ██████╗
#   ██╔══██╗██╔══██╗██╔════╝██║  ██║    ██║    ██║██║╚══███╔╝██╔══██╗██╔══██╗██╔══██╗
#   ███████║██████╔╝██║     ███████║    ██║ █╗ ██║██║  ███╔╝ ███████║██████╔╝██║  ██║
#   ██╔══██║██╔══██╗██║     ██╔══██║    ██║███╗██║██║ ███╔╝  ██╔══██║██╔══██╗██║  ██║
#   ██║  ██║██║  ██║╚██████╗██║  ██║    ╚███╔███╔╝██║███████╗██║  ██║██║  ██║██████╔╝
#   ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝    ╚══╝╚══╝ ╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝
# =============================================================================
#  The most wonderful Arch Linux installation script ever crafted  ✨
#  Version : 5.5.0
#  License : MIT
#  Usage   : bash archwizard.sh [--dry-run] [--verbose] [--load-config FILE]
# =============================================================================

# set -e  : exit immediately if any command returns a non-zero status
# set -u  : treat unset variables as errors (prevents silent bugs)
# set -o pipefail : a pipeline fails if ANY command in it fails (not just the last one)
# IFS is intentionally left at its default (space/tab/newline) so that word-splitting
# on space-separated strings (desktop selections, package lists) works correctly.
set -euo pipefail

# ── Error trap ────────────────────────────────────────────────────────────────
# If any command fails (triggers set -e), print the line number and exit code,
# then point the user to the log file for debugging.
trap 'RC=$?; CMD="${BASH_COMMAND}"; echo "CRASH line=$LINENO exit=$RC cmd=$CMD" > /tmp/archwizard_crash.txt; echo -e "\n[ERR] CRASH line=$LINENO exit=$RC cmd=$CMD" >&2; set +x' ERR

# ── ANSI color codes ──────────────────────────────────────────────────────────
# Used by the ok/warn/error/section helper functions below.
# NC (No Color) resets formatting after colored output.
RED='\033[0;31m';    GREEN='\033[0;32m';   YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';    MAGENTA='\033[0;35m'
BOLD='\033[1m';      DIM='\033[2m';         NC='\033[0m'

# ── Logging ───────────────────────────────────────────────────────────────────
# Redirect all stdout and stderr through `tee` so every line appears on screen
# AND is appended to the log file simultaneously. The log survives reboots and
# lets the user diagnose any failure after the fact.
LOG_FILE="/tmp/archwizard.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log()     { echo -e "${DIM}[$(date '+%H:%M:%S')]${NC} $*"; }
info()    { echo -e "${CYAN}${BOLD}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}${BOLD}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}${BOLD}[ERR ]${NC}  $*" >&2; }
section() { echo -e "\n${MAGENTA}${BOLD}━━━  $*  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
ask()     { echo -e -n "${YELLOW}${BOLD}[ ? ]${NC}  $* " >&2; }
blank()   { echo ""; }

# =============================================================================
#  GLOBAL STATE — all user choices are stored here
# =============================================================================
DRY_RUN=false
VERBOSE=false          # true → set -x (print every command executed)
FIRMWARE_MODE="uefi"   # uefi | bios — detected in sanity_checks
CONFIG_FILE=""         # path to a saved config file to load (--load-config)   # uefi | bios — detected in sanity_checks, never set by user

# Hardware
CPU_VENDOR="unknown"
GPU_VENDOR="unknown"

# Disks & Partitions
DISK_ROOT=""
ROOT_FS="btrfs"        # btrfs | ext4 | xfs | f2fs
HOME_FS="btrfs"        # btrfs | ext4 | xfs | f2fs (only used when SEP_HOME=true)
DISK_HOME=""
EFI_PART=""
ROOT_PART=""
ROOT_PART_MAPPED=""    # /dev/mapper/cryptroot if LUKS, else same as ROOT_PART
HOME_PART=""
SWAP_PART=""
EFI_SIZE_MB=512
ROOT_SIZE=""
SEP_HOME=false
HOME_SIZE=""
DUAL_BOOT=false        # true when installing alongside ANY existing OS
RESIZE_PART=""         # partition to shrink before install (empty = no resize)
RESIZE_NEW_GB=0        # new size in GB for RESIZE_PART
REPLACE_PART=""        # first partition to delete (for backward compat)
REPLACE_PARTS_ALL=()   # ALL partitions to delete (may be multiple)
PROTECTED_PARTS=()     # partitions the user wants to KEEP (never offered in replace menu)
FREE_GB_AVAIL=0        # projected free GB available for Arch (used by Section 5)
EXISTING_WINDOWS=false # true when Windows/NTFS detected
EXISTING_LINUX=false   # true when another Linux distro detected
EXISTING_SYSTEMS=()    # human-readable list of detected OSes for the summary
REUSE_EFI=false

# Encryption & Swap
USE_LUKS=false
LUKS_PASSWORD=""
SWAP_TYPE="zram"
SWAP_SIZE="8"

# System identity
HOSTNAME=""
GRUB_ENTRY_NAME=""     # label shown in GRUB boot menu
USERNAME=""
USER_PASSWORD=""
ROOT_PASSWORD=""
TIMEZONE="UTC"
LOCALE="en_US.UTF-8"
KEYMAP="us"

# Software
KERNEL="linux"              # linux | linux-lts | linux-zen
BOOTLOADER=""
SECURE_BOOT=false
DESKTOPS=()          # array — user may select multiple
AUR_HELPER="none"
USE_REFLECTOR=false
REFLECTOR_COUNTRIES="France,Germany"
REFLECTOR_AGE=12
REFLECTOR_NUMBER=10
REFLECTOR_PROTOCOL="https"
USE_MULTILIB=false
USE_PIPEWIRE=false
USE_NVIDIA=false
USE_AMD_VULKAN=false   # install vulkan-radeon + libva-mesa-driver for AMD GPU
USE_BLUETOOTH=false
USE_CUPS=false
USE_SNAPPER=false
FIREWALL="none"              # none | nftables | ufw

# =============================================================================
#  HELPER FUNCTIONS
# =============================================================================

# ── part_name ─────────────────────────────────────────────────────────────────
# Derives the correct partition device path from a disk and partition number.
# NVMe and MMC devices use a 'p' separator before the number (e.g. nvme0n1p1),
# while traditional SATA/SCSI disks do not (e.g. sda1).
part_name() {
    local disk="$1" num="$2"
    if [[ "$disk" == *"nvme"* || "$disk" == *"mmcblk"* ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

# ── confirm ───────────────────────────────────────────────────────────────────
# Prompts the user for a yes/no answer.
# The second argument sets the default if the user just presses Enter.
# Returns 0 (true) for yes, 1 (false) for no — safe to use in `if` statements.
confirm() {
    local msg="$1" default="${2:-n}" prompt ans
    [[ "$default" == "y" ]] && prompt="[Y/n]" || prompt="[y/N]"
    ask "$msg $prompt"
    read -r ans
    case "${ans:-$default}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# ── select_option ─────────────────────────────────────────────────────────────
# Displays a numbered list and waits for a valid numeric choice.
# Sets the global $REPLY variable to the full text of the selected item.
# Loops forever until the user enters a valid number.
select_option() {
    local prompt="$1"; shift
    local options=("$@")
    blank
    echo -e "${YELLOW}${BOLD}[ ? ]${NC}  $prompt"
    for i in "${!options[@]}"; do
        echo -e "      ${BOLD}$((i+1)))${NC} ${options[$i]}"
    done
    while true; do
        ask "Enter choice [1-${#options[@]}]:"
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            REPLY="${options[$((choice-1))]}"
            return 0
        fi
        warn "Invalid choice. Please enter a number between 1 and ${#options[@]}."
    done
}

# ── get_input ─────────────────────────────────────────────────────────────────
# Prompts for a text value, showing the default in cyan brackets.
# If the user presses Enter without typing, the default is returned.
# IMPORTANT: ask() writes to stderr so that VAR=$(get_input ...) only captures
# what the user typed — not the prompt text itself.
get_input() {
    local prompt="$1" default="${2:-}" ans
    if [[ -n "$default" ]]; then
        ask "$prompt [${CYAN}${default}${NC}]:"
    else
        ask "$prompt:"
    fi
    read -r ans
    echo "${ans:-$default}"
}

# ── get_password ──────────────────────────────────────────────────────────────
# Reads a password twice (no echo on screen) and verifies both entries match.
# Uses `read -rs` (-r: no backslash escaping, -s: silent/no echo).
# The `echo >&2` after each read prints a newline to stderr (terminal) without
# polluting stdout — same reason as ask(): stderr vs stdout separation.
get_password() {
    local prompt="$1" pass confirm_pass
    while true; do
        ask "$prompt:"
        read -rs pass; echo >&2
        ask "Confirm:"
        read -rs confirm_pass; echo >&2
        if [[ "$pass" == "$confirm_pass" && -n "$pass" ]]; then
            echo "$pass"
            return
        fi
        warn "Passwords don't match or are empty. Try again."
    done
}

# ── run ───────────────────────────────────────────────────────────────────────
# Central command executor. In normal mode it logs the command and runs it.
# In --dry-run mode it only prints what *would* be executed — no disk changes.
# All destructive operations (sgdisk, mkfs, pacstrap, cryptsetup…) go through run().
# We use eval "$@" rather than "$@" to handle commands built as strings with
# embedded quotes and spaces (e.g. the sgdisk calls built dynamically).
run() {
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${DIM}[DRY-RUN]${NC} $*"
    else
        log "CMD: $*"
        eval "$@"
    fi
}

# ── run_interactive ────────────────────────────────────────────────────────────
# Variant of run() for commands that display interactive prompts the user must
# answer — specifically parted's "Shrinking a partition can cause data loss,
# are you sure you want to continue?" warning.
#
# WHY THIS IS NEEDED:
#   The script redirects all output through tee at startup:
#     exec > >(tee -a "$LOG_FILE") 2>&1
#   This replaces the process stdin/stdout with a pipe. When parted shows its
#   interactive warning and calls read(), it reads from the pipe (which is
#   empty) — gets EOF immediately — and the script dies via set -e.
#   Even "echo Yes | parted ..." fails because parted reads prompts from
#   /dev/tty directly on some versions, ignoring piped stdin.
#
#   Solution: redirect stdin/stdout/stderr to /dev/tty for the duration of
#   this one command so the user sees the prompt and can type their answer
#   on the real terminal. Normal logging resumes after the call returns.
run_interactive() {
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${DIM}[DRY-RUN]${NC} $*"
    else
        log "CMD (interactive): $*"
        eval "$@" </dev/tty >/dev/tty 2>/dev/tty
    fi
}

# ── _refresh_partitions ────────────────────────────────────────────────────────
# Updates the kernel's view of the partition table after GPT changes (sgdisk,
# parted resizepart, etc.). Must be called DIRECTLY — not via run() — because
# shell functions cannot be reliably invoked through eval in a subshell context.
# Strategy: partprobe x3 → partx -u → udevadm settle → warn and continue.
_refresh_partitions() {
    local disk="$1"
    local attempt
    for attempt in 1 2 3; do
        if partprobe "$disk" 2>/dev/null; then
            sleep 1
            ok "Kernel partition table updated"
            return 0
        fi
        warn "partprobe attempt ${attempt}/3 failed — retrying in 2 s…"
        sleep 2
    done
    if partx -u "$disk" 2>/dev/null; then
        sleep 1
        ok "Kernel partition table updated via partx"
        return 0
    fi
    udevadm settle 2>/dev/null || true
    sleep 3
    warn "Could not confirm kernel saw partition changes — continuing anyway."
}

# ── probe_os_from_part ────────────────────────────────────────────────────────
# Probes a block device and returns the OS name it contains.
# Sets the global PROBE_OS_RESULT variable.
# Strategy:
#   1. LUKS → "[encrypted]" immediately, no mount attempt
#   2. Plain mount → read /etc/os-release (ext4, xfs, f2fs, btrfs toplevel)
#   3. btrfs subvolume fallback → try @, @root, root, arch, debian, ubuntu…
#   4. NTFS → "Windows" (no mount needed)
#   5. Fallback → partition LABEL, then "Linux (fstype)"
# The mount point /tmp/archwizard_probe is used and cleaned up each time.
PROBE_OS_RESULT=""
probe_os_from_part() {
    local p="$1"
    PROBE_OS_RESULT=""
    local fstype
    fstype=$(blkid -s TYPE -o value "$p" 2>/dev/null || echo "")

    # LUKS — cannot read without passphrase
    if [[ "$fstype" == "crypto_LUKS" ]]; then
        PROBE_OS_RESULT="[encrypted]"
        return 0
    fi

    # NTFS = Windows, no mount needed
    if [[ "$fstype" == "ntfs" ]]; then
        local lbl
        lbl=$(blkid -s LABEL -o value "$p" 2>/dev/null || echo "")
        PROBE_OS_RESULT="${lbl:-Windows}"
        return 0
    fi

    local _mnt="/tmp/archwizard_probe_$$"
    mkdir -p "$_mnt"

    # Helper: read PRETTY_NAME or NAME from os-release
    # MUST return 0 always — called via PROBE_OS_RESULT=$(_osrel ...) and
    # with set -e a non-zero exit code from the subshell kills the script.
    _osrel() {
        local m="$1" n=""
        [[ -f "$m/etc/os-release" ]] || return 0   # no file → return 0 (empty output)
        n=$(grep '^PRETTY_NAME=' "$m/etc/os-release" | cut -d= -f2- | tr -d '"' | head -1)
        [[ -z "$n" ]] && n=$(grep '^NAME=' "$m/etc/os-release" | cut -d= -f2- | tr -d '"' | head -1 || true)
        echo "$n"
        return 0
    }

    # Plain mount (ext4, xfs, f2fs, btrfs toplevel)
    if mount -o ro,noexec,nosuid "$p" "$_mnt" 2>/dev/null; then
        PROBE_OS_RESULT=$(_osrel "$_mnt") || true
        umount "$_mnt" 2>/dev/null || true
        if [[ -n "$PROBE_OS_RESULT" ]]; then rmdir "$_mnt" 2>/dev/null; return 0; fi
    fi

    # btrfs subvolume fallback
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

    # Fallback: label or fstype description
    local lbl
    lbl=$(blkid -s LABEL -o value "$p" 2>/dev/null || echo "")
    PROBE_OS_RESULT="${lbl:-Linux (${fstype:-unknown})}"
    return 0
}


# ── _is_protected ─────────────────────────────────────────────────────────────
# Returns 0 (true) if partition $1 is in PROTECTED_PARTS, 1 otherwise.
_is_protected() {
    local p="$1" pp
    for pp in "${PROTECTED_PARTS[@]+"${PROTECTED_PARTS[@]}"}"; do
        [[ "$pp" == "$p" ]] && return 0
    done
    return 1
}


# =============================================================================
#  SECTION 1 — BANNER & PRE-FLIGHT CHECKS
# =============================================================================

show_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'

    █████╗ ██████╗  ██████╗██╗  ██╗    ██╗    ██╗██╗███████╗ █████╗ ██████╗ ██████╗
   ██╔══██╗██╔══██╗██╔════╝██║  ██║    ██║    ██║██║╚══███╔╝██╔══██╗██╔══██╗██╔══██╗
   ███████║██████╔╝██║     ███████║    ██║ █╗ ██║██║  ███╔╝ ███████║██████╔╝██║  ██║
   ██╔══██║██╔══██╗██║     ██╔══██║    ██║███╗██║██║ ███╔╝  ██╔══██║██╔══██╗██║  ██║
   ██║  ██║██║  ██║╚██████╗██║  ██║    ╚███╔███╔╝██║███████╗██║  ██║██║  ██║██████╔╝
   ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝    ╚══╝╚══╝ ╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝

EOF
    echo -e "${NC}${BOLD}         The most wonderful Arch Linux installer ever crafted  ✨${NC}"
    echo -e "${DIM}         v5.5.0  •  Full log: /tmp/archwizard.log${NC}"
    echo -e "${DIM}         Usage: bash archwizard.sh [--dry-run] [--verbose] [--load-config FILE]${NC}\n"
}

# ── sanity_checks ─────────────────────────────────────────────────────────────
# Verifies all hard requirements before touching anything:
#   • Must run as root (UID 0) — partitioning and pacstrap require it
#   • Must be in UEFI mode — the script uses GPT + EFI, not BIOS/MBR
#   • Must have internet — pacstrap downloads ~1 GB of packages
#   • Must have all required tools — some may be missing on minimal live ISOs
#   • Detects CPU vendor for correct microcode package (intel-ucode / amd-ucode)
#   • Detects GPU for optional NVIDIA driver offer
#   • Starts NTP sync in the background — timedatectl can hang 10-30 s on the ISO
#     if called synchronously, so we fire-and-forget it with `& disown`
sanity_checks() {
    section "Pre-flight Checks"

    # Root
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo or boot from Arch ISO)."
        exit 1
    fi
    ok "Running as root"

    # Firmware mode detection — UEFI preferred, BIOS supported with restrictions
    if [[ -d /sys/firmware/efi/efivars ]]; then
        FIRMWARE_MODE="uefi"
        ok "Firmware: ${BOLD}UEFI${NC} — full feature support (GRUB, systemd-boot, Secure Boot)"
    else
        FIRMWARE_MODE="bios"
        warn "Firmware: ${BOLD}BIOS/Legacy${NC} — GRUB with MBR will be used."
        warn "systemd-boot and Secure Boot are NOT available in BIOS mode."
        warn "Dual-boot with UEFI systems on the same disk is NOT supported in BIOS mode."
        blank
    fi

    # Internet — ping two IPs directly (no DNS lookup) to avoid a 5–10 s delay.
    # The live ISO may not have a working resolver yet; raw IPs always work.
    if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null && ! ping -c 1 -W 3 1.1.1.1 &>/dev/null; then
        warn "No internet connection detected."
        blank

        # ── WiFi assistant ───────────────────────────────────────────────────
        # Detect WiFi interfaces and offer to connect via iwctl (iwd).
        # iwctl is included on the official Arch ISO and supports WPA2/WPA3.
        # We do NOT try to automate iwctl (passwords, SSIDs vary too much) —
        # instead we launch it interactively so the user connects manually,
        # then we verify connectivity before continuing.
        local wifi_ifaces=()
        while IFS= read -r iface; do
            [[ -z "$iface" ]] && continue
            wifi_ifaces+=("$iface")
        done < <(iw dev 2>/dev/null | awk '/Interface/{print $2}' || true)

        if [[ ${#wifi_ifaces[@]} -gt 0 ]]; then
            blank
            info "WiFi interface(s) detected: ${BOLD}${wifi_ifaces[*]}${NC}"
            info "You can connect using iwctl. Quick guide:"
            echo -e "  ${DIM}[iwctl]${NC}  device list"
            echo -e "  ${DIM}[iwctl]${NC}  station ${wifi_ifaces[0]} scan"
            echo -e "  ${DIM}[iwctl]${NC}  station ${wifi_ifaces[0]} get-networks"
            echo -e "  ${DIM}[iwctl]${NC}  station ${wifi_ifaces[0]} connect "YourSSID""
            echo -e "  ${DIM}[iwctl]${NC}  exit"
            blank

            if confirm "Open iwctl to connect to WiFi now?" "y"; then
                # Run iwctl interactively on the real terminal
                iwctl </dev/tty >/dev/tty 2>/dev/tty || true
                blank
                info "Checking connectivity after WiFi setup…"
                sleep 3
                if ping -c 1 -W 5 8.8.8.8 &>/dev/null || ping -c 1 -W 5 1.1.1.1 &>/dev/null; then
                    ok "Internet connection established via WiFi"
                else
                    error "Still no connectivity. Please connect manually and re-run the script."
                    error "You can also use: nmtui, dhcpcd, or configure manually with ip/iwctl."
                    exit 1
                fi
            else
                info "Skipping WiFi assistant."
                info "Connect manually (iwctl / nmtui / dhcpcd) then re-run the script."
                exit 1
            fi
        else
            # No WiFi detected — Ethernet or no hardware
            error "No internet and no WiFi interface found."
            error "Check your Ethernet cable or network card."
            error "If using Ethernet: ip link  →  dhcpcd <interface>"
            exit 1
        fi
    else
        ok "Internet connection OK"
    fi

    # Required tools
    local missing=() tools=(sgdisk mkfs.fat mkfs.btrfs arch-chroot pacstrap genfstab blkid lsblk)
    for t in "${tools[@]}"; do
        command -v "$t" &>/dev/null || missing+=("$t")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing tools: ${missing[*]}. Boot from the official Arch ISO."
        exit 1
    fi
    ok "All required tools present"

    # CPU microcode detection — reads /proc/cpuinfo (always available, no D-Bus).
    # The detected vendor is used later to add intel-ucode or amd-ucode to pacstrap
    # and to add the correct initrd line in the systemd-boot entry.
    if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
        CPU_VENDOR="intel"
    elif grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
        CPU_VENDOR="amd"
    fi
    ok "CPU vendor: ${BOLD}${CPU_VENDOR}${NC}"

    # GPU detection
    if lspci 2>/dev/null | grep -qi "nvidia"; then
        GPU_VENDOR="nvidia"
        ok "GPU detected: ${BOLD}NVIDIA${NC} (proprietary drivers available)"
    elif lspci 2>/dev/null | grep -qi "amd.*vga\|vga.*amd\|radeon"; then
        GPU_VENDOR="amd"
        ok "GPU detected: ${BOLD}AMD Radeon${NC}"
    elif lspci 2>/dev/null | grep -qi "intel.*vga\|vga.*intel"; then
        GPU_VENDOR="intel"
        ok "GPU detected: ${BOLD}Intel${NC}"
    else
        warn "GPU vendor could not be determined"
    fi

    # NTP — timedatectl blocks for up to 30 s on the live ISO waiting for
    # systemd-timesyncd to respond. We fire it in the background and disown it
    # so it keeps running even if this script exits before it finishes.
    timedatectl set-ntp true &>/dev/null & disown
    ok "NTP sync requested (background)"
}

# =============================================================================
#  SECTION 2 — KEYBOARD LAYOUT
# =============================================================================

# ── choose_keyboard ───────────────────────────────────────────────────────────
# Asks for a console keymap and validates it by checking the actual .map.gz files
# under /usr/share/kbd/keymaps. We cannot use `localectl list-keymaps` here
# because localectl talks to systemd-localed over D-Bus, which is not running on
# the live ISO — it would block or fail silently.
# NOTE: the correct name for French AZERTY is "fr-latin1", not "fr".
# "fr" exists as a locale name but not as a keymap file.
choose_keyboard() {
    section "Keyboard Layout"
    info "Common layouts: us  uk  fr-latin1  de-latin1  es  it  be-latin1  ru  dvorak  colemak"
    info "(French users: use ${BOLD}fr-latin1${NC}, not 'fr')"
    KEYMAP=$(get_input "Keyboard layout" "fr-latin1")
    # Validate against the real keymap file tree — no D-Bus needed.
    if find /usr/share/kbd/keymaps -name "${KEYMAP}.map.gz" -o -name "${KEYMAP}.map" 2>/dev/null | grep -q .; then
        run "loadkeys $KEYMAP"
        ok "Keyboard: ${BOLD}$KEYMAP${NC}"
    else
        warn "Layout '${KEYMAP}' not found in /usr/share/kbd/keymaps, defaulting to 'us'."
        warn "Tip: try 'fr-latin1' for French, 'de-latin1' for German, 'uk' for British."
        KEYMAP="us"
        run "loadkeys us"
    fi
}

# =============================================================================
#  SECTION 3 — DISK DISCOVERY
# =============================================================================

# ── discover_disks ────────────────────────────────────────────────────────────
# Provides a detailed picture of every block device on the system:
#   • Enriched lsblk table: transport (NVMe/SATA/USB), rotation (SSD/HDD),
#     partition table type (GPT/MBR/none), and existing filesystem summary
#   • Per-disk partition listing so the user can see what's already there
#   • Detects NTFS → offers dual-boot mode (add partitions, never wipe)
#   • Detects existing Linux filesystems → warns before overwriting
#   • Detects FAT32 EFI → offers to reuse Windows ESP in dual-boot
discover_disks() {
    section "Disk Discovery"
    blank

    # ── Enriched disk table ───────────────────────────────────────────────
    # ROTA=0 → SSD/NVMe, ROTA=1 → spinning HDD
    # TRAN shows the transport (nvme, sata, usb, …)
    # PTTYPE shows the partition table format (gpt, dos/MBR, or empty)
    echo -e "  ${BOLD}┌──────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "  ${BOLD}│  Block Devices                                                   │${NC}"
    echo -e "  ${BOLD}├──────────────────────────────────────────────────────────────────┤${NC}"
    printf "  │  %-12s %-8s %-6s %-6s %-5s  %-20s│
"         "DEVICE" "SIZE" "TYPE" "TRAN" "TABLE" "MODEL"
    echo -e "  ${BOLD}├──────────────────────────────────────────────────────────────────┤${NC}"
    while IFS= read -r dev; do
        local name size rota tran pttype model media
        name=$(lsblk -dno NAME   "/dev/${dev}" 2>/dev/null)
        size=$(lsblk -dno SIZE   "/dev/${dev}" 2>/dev/null)
        rota=$(lsblk -dno ROTA   "/dev/${dev}" 2>/dev/null)
        tran=$(lsblk -dno TRAN   "/dev/${dev}" 2>/dev/null)
        pttype=$(lsblk -dno PTTYPE "/dev/${dev}" 2>/dev/null)
        model=$(lsblk -dno MODEL  "/dev/${dev}" 2>/dev/null | cut -c1-20)
        # Human-readable media type
        if [[ "$rota" == "0" ]]; then media="SSD"; else media="HDD"; fi
        [[ "$tran" == "nvme" ]] && media="NVMe"
        [[ "$tran" == "usb"  ]] && media="USB"
        # Colour code: green=SSD/NVMe, yellow=HDD, dim=USB
        local col="$GREEN"
        [[ "$media" == "HDD" ]] && col="$YELLOW"
        [[ "$media" == "USB" ]] && col="$DIM"
        printf "  │  ${col}${BOLD}%-12s${NC} %-8s ${col}%-6s${NC} %-6s %-5s  %-20s│
"             "/dev/${name}" "${size}" "${media}" "${tran:-—}" "${pttype:-—}" "${model:-Unknown}"
    done < <(lsblk -d -n -o NAME 2>/dev/null | grep -v "^loop\|^sr")
    echo -e "  ${BOLD}└──────────────────────────────────────────────────────────────────┘${NC}"
    blank

    # ── Per-disk partition listing ────────────────────────────────────────
    # Shows existing partitions so the user knows what is already on each disk.
    info "Existing partitions:"
    blank
    while IFS= read -r dev; do
        local has_parts
        has_parts=$(lsblk -n -o NAME "/dev/${dev}" 2>/dev/null | tail -n +2)
        if [[ -n "$has_parts" ]]; then
            echo -e "  ${CYAN}${BOLD}/dev/${dev}${NC}"
            lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "/dev/${dev}" 2>/dev/null                 | tail -n +2                 | while IFS= read -r line; do echo "    $line"; done
            blank
        fi
    done < <(lsblk -d -n -o NAME 2>/dev/null | grep -v "^loop\|^sr")

    # ── OS detection — unified probe ─────────────────────────────────────
    #
    # OS detection using the global probe_os_from_part() function.
    # For each candidate partition it tries in order:
    #
    #   A. LUKS check  — if TYPE=crypto_LUKS skip (can't mount without key)
    #   B. Plain mount — works for ext4, xfs, f2fs, and btrfs toplevel
    #   C. btrfs subvol fallback — try common subvolume names:
    #        @, @root, root, arch, debian, ubuntu, fedora, opensuse
    #      Most distros that use btrfs put / in one of these.
    #   D. Fallback chain — LABEL → fstype string
    #
    # efibootmgr is only used to SUPPLEMENT, never as primary source,
    # because labels like "debian" are unreliable (user may rename them)
    # and they don't map to a partition.
    #
    # All results go into two parallel arrays:
    #   _found_names[]  — human-readable OS name ("Debian GNU/Linux 12")
    #   _found_parts[]  — device path ("/dev/sda3")
    # Both arrays are indexed together — no index mismatch possible.

    # ── Candidate OS partitions ──────────────────────────────────────────
    # Use the global probe_os_from_part() — defined at top of script.
    # Exclude currently mounted devices (live ISO partitions).
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

    # UEFI NVRAM supplement — adds names for OSes whose partition wasn't
    # found by blkid (e.g. OS on a disk not scanned, or unusual filesystem).
    # Only used if it provides something not already covered.
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
            # Skip Windows (already handled above)
            echo "$_lbl" | grep -qi "windows"  && continue
            # Only add if not already represented in _found_names
            local _seen=false
            for n in "${_found_names[@]}"; do
                echo "$n" | grep -qi "$_lbl" && _seen=true && break
            done
            if [[ "$_seen" == false ]]; then
                _found_names+=("$_lbl")
                _found_parts+=("")   # no partition — UEFI-only entry
            fi
        done < <(efibootmgr 2>/dev/null | grep -E '^Boot[0-9A-Fa-f]{4}' || true)
    fi

    # ── Windows / NTFS detection ──────────────────────────────────────────
    local _win_parts=()
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        _win_parts+=("$p")
    done < <(blkid -t TYPE="ntfs" -o device 2>/dev/null || true)

    if [[ ${#_win_parts[@]} -gt 0 ]]; then
        for p in "${_win_parts[@]}"; do
            _found_names+=("Windows")
            _found_parts+=("$p")
        done
    fi

    # ── Display all detected systems and ask once ─────────────────────────
    if [[ ${#_found_names[@]} -gt 0 ]]; then
        blank
        warn "Existing OS(es) detected on this machine:"
        blank
        for i in "${!_found_names[@]}"; do
            local _pinfo=""
            if [[ -n "${_found_parts[$i]}" ]]; then
                local _psize
                _psize=$(lsblk -dno SIZE "${_found_parts[$i]}" 2>/dev/null || echo "?")
                _pinfo="  ${DIM}on ${_found_parts[$i]} (${_psize})${NC}"
            fi
            echo -e "    ${CYAN}${BOLD}→ ${_found_names[$i]}${NC}${_pinfo}"
        done
        blank

        if confirm "Install Arch Linux alongside these system(s)?" "y"; then
            DUAL_BOOT=true
            for n in "${_found_names[@]}"; do
                # Track Windows and Linux separately for bootloader recommendation
                echo "$n" | grep -qi "windows" && EXISTING_WINDOWS=true
                echo "$n" | grep -qi "windows" || EXISTING_LINUX=true
                EXISTING_SYSTEMS+=("$n")
            done
            ok "Multi-boot mode enabled — existing partitions will be preserved"
            blank
            info "  ${BOLD}GRUB${NC} + ${BOLD}os-prober${NC} will be strongly recommended as bootloader."
            blank
        fi
    fi

    # ── EFI partition detection (any multi-boot mode) ─────────────────────
    if [[ "$DUAL_BOOT" == true ]]; then
        local efi_parts efi_list=()
        # Filter for small FAT32 partitions with EFI partition type (ef00)
        while IFS= read -r p; do
            local pttype_p
            pttype_p=$(lsblk -no PARTTYPE "$p" 2>/dev/null || echo "")
            # EFI System Partition GUID or just any vfat ≤ 1 GB
            local size_mb
            size_mb=$(( $(blockdev --getsize64 "$p" 2>/dev/null || echo 0) / 1048576 ))
            if [[ "$pttype_p" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" || $size_mb -le 1024 ]]; then
                efi_list+=("$p")
            fi
        done < <(blkid -t TYPE="vfat" -o device 2>/dev/null || true)

        if [[ ${#efi_list[@]} -gt 0 ]]; then
            info "Detected EFI System Partition(s):"
            for p in "${efi_list[@]}"; do
                local _esize _elabel
                _esize=$(lsblk -dno SIZE "$p" 2>/dev/null || echo "?")
                _elabel=$(blkid -s LABEL -o value "$p" 2>/dev/null || echo "")
                echo -e "  ${CYAN}→ ${BOLD}$p${NC}  (${_esize})${_elabel:+  label: $_elabel}"
            done
            blank
            # In multi-boot, sharing the existing ESP is mandatory — the firmware
            # expects one ESP per disk. Only ask when there are multiple ESPs.
            if [[ ${#efi_list[@]} -eq 1 ]]; then
                # Single ESP: auto-select without asking
                EFI_PART="${efi_list[0]}"
                REUSE_EFI=true
                ok "Using existing EFI partition: ${BOLD}$EFI_PART${NC} — shared between OSes"
            else
                if confirm "Reuse the existing EFI partition? (Strongly recommended for multi-boot)" "y"; then
                    REUSE_EFI=true
                    select_option "Which EFI partition to use?" "${efi_list[@]}"
                    EFI_PART="$REPLY"
                    ok "Will reuse EFI: ${BOLD}$EFI_PART${NC}  ($(lsblk -dno SIZE "$EFI_PART" 2>/dev/null))"
                fi
            fi
        fi
    fi
}

# =============================================================================
#  SECTION 4 — DISK SELECTION
# =============================================================================


# ── _check_and_plan_space ─────────────────────────────────────────────────────
# Called immediately after the user confirms multi-boot.
# Analyses free space on $1 (the root disk) and either:
#   a) Reports that enough space is already available → sets FREE_GB_AVAIL
#   b) Offers to use a different disk if multiple disks exist
#   c) Lists shrinkable partitions and collects resize parameters
#      → sets RESIZE_PART, RESIZE_NEW_GB, FREE_GB_AVAIL
#      The actual resize is deferred to Phase 3 (resize_partitions),
#      but the PLAN is made here so Section 5 knows the real space budget.
_check_and_plan_space() {
    local disk="$1"
    local NEEDED_GB=7    # minimum for a base Arch install (no DE); 15-20 GB recommended with DE

    # ── Measure unallocated space ─────────────────────────────────────────
    local total_free_bytes=0
    while IFS= read -r line; do
        local fb
        fb=$(echo "$line" | awk '{print $3}' | tr -d 'B')
        total_free_bytes=$(( total_free_bytes + ${fb:-0} ))
    done < <(parted -s "$disk" unit B print free 2>/dev/null | grep "Free Space" || true)
    local free_gb=$(( total_free_bytes / 1073741824 ))

    # ── Also count partitions the user already chose NOT to keep ─────────
    # PROTECTED_PARTS holds what the user said to keep; everything else on
    # the disk (excluding EFI/swap/tiny) is fair game for deletion and its
    # space should be counted as "available" right now.
    local disposable_parts=()   # partitions user doesn't want to keep
    local disposable_gb=0
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        local _pt _pb _pb_gb
        _pt=$(lsblk -no PARTTYPE "$p" 2>/dev/null || echo "")
        _pb=$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)
        _pb_gb=$(( _pb / 1073741824 ))
        # Skip EFI, swap, tiny
        [[ "$_pt" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] && continue
        [[ "$_pt" == "0657fd6d-a4ab-43c4-84e5-0933c84b4f4f" ]] && continue
        (( _pb_gb < 1 )) && continue
        # Skip protected partitions
        _is_protected "$p" && continue
        # This partition is disposable — user said they don't want to keep it
        disposable_parts+=("$p")
        disposable_gb=$(( disposable_gb + _pb_gb ))
    done < <(lsblk -ln -o PATH "$disk" 2>/dev/null | tail -n +2)

    local total_avail_gb=$(( free_gb + disposable_gb ))
    FREE_GB_AVAIL=$total_avail_gb

    section "Space Analysis — ${disk}"
    info "Unallocated space:        ${BOLD}${free_gb} GB${NC}"
    if [[ ${#disposable_parts[@]} -gt 0 ]]; then
        info "Reclaimable (not kept):   ${BOLD}${disposable_gb} GB${NC}  (${disposable_parts[*]})"
        info "Total available for Arch: ${BOLD}${total_avail_gb} GB${NC}"
    fi
    info "Minimum needed:           ${BOLD}${NEEDED_GB} GB${NC}"
    blank

    # ── Case A: enough space already (unallocated alone) ─────────────────
    if (( free_gb >= NEEDED_GB )); then
        ok "Sufficient unallocated space (${free_gb} GB ≥ ${NEEDED_GB} GB)."
        ok "Arch Linux partitions will be created in that space."
        blank
        return
    fi

    # ── Case B: enough space if we delete the disposable partitions ───────
    # The user already said they don't want those partitions — no need to ask
    # again. Auto-plan their deletion and move on.
    if (( total_avail_gb >= NEEDED_GB && ${#disposable_parts[@]} > 0 )); then
        ok "Enough space available by deleting the unneeded partitions."
        blank
        for p in "${disposable_parts[@]}"; do
            local _n _s
            probe_os_from_part "$p" || true
            _n="${PROBE_OS_RESULT:-partition}"
            _s=$(lsblk -dno SIZE "$p" 2>/dev/null || echo "?")
            warn "  Will DELETE: ${BOLD}${p}${NC}  (${_s})  — ${_n}"
        done
        blank
        # Store the first disposable partition as REPLACE_PART.
        # If there are multiple, they are all deleted in replace_partition().
        REPLACE_PART="${disposable_parts[0]}"
        # Store full list for Phase 3 (replace_partition handles them all)
        REPLACE_PARTS_ALL=("${disposable_parts[@]}")
        FREE_GB_AVAIL=$total_avail_gb
        warn "Deletions will happen after you confirm the installation summary."
        blank
        return
    fi

    # ── Not enough space even after deleting disposable parts ─────────────
    warn "Not enough space even after reclaiming unneeded partitions (${total_avail_gb} GB < ${NEEDED_GB} GB)."
    blank
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$disk" 2>/dev/null | \
        while IFS= read -r line; do echo "    $line"; done
    blank

    # ── Build list of candidate partitions ───────────────────────────────
    # Candidates for replace/shrink: all partitions EXCEPT:
    #   - The EFI System Partition (never touch)
    #   - PROTECTED_PARTS (partitions the user said to keep)
    #   - Tiny partitions < 1 GB (recovery, MSR, etc.)
    local candidates=()   # "path|fstype|size_gb|os_name"
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        local pt ft pb pb_gb os_n=""
        pt=$(lsblk  -no PARTTYPE "$p" 2>/dev/null || echo "")
        ft=$(blkid  -s TYPE -o value "$p" 2>/dev/null || echo "")
        pb=$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)
        pb_gb=$(( pb / 1073741824 ))
        # Skip EFI System Partition — never touch it
        [[ "$pt" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] && continue
        # Skip partitions the user explicitly said to keep
        local _prot=false
        for _pp in "${PROTECTED_PARTS[@]+"${PROTECTED_PARTS[@]}"}"; do
            [[ "$_pp" == "$p" ]] && _prot=true && break
        done
        [[ "$_prot" == true ]] && continue
        # Skip tiny partitions (< 1 GB) — recovery, MSR, etc.
        (( pb_gb < 1 )) && continue
        # Probe OS name via global function
        probe_os_from_part "$p" || true
        os_n="${PROBE_OS_RESULT}"
        [[ "$ft" == "swap" ]] && os_n="[swap]"
        candidates+=("$p|$ft|$pb_gb|${os_n}")
    done < <(lsblk -ln -o PATH "$disk" 2>/dev/null | tail -n +2)

    if [[ ${#candidates[@]} -eq 0 ]]; then
        # No unprotected candidates — offer to shrink a PROTECTED partition.
        # This happens when the disk only contains OS(es) the user wants to keep.
        # The user must shrink one of their "kept" OSes to make room.
        blank
        warn "All partitions on ${disk} are marked as 'keep'."
        warn "To install Arch alongside the existing OS, you must SHRINK one of them."
        blank
        info "Protected partitions (OSes you chose to keep):"
        for _pp in "${PROTECTED_PARTS[@]+"${PROTECTED_PARTS[@]}"}"; do
            local _pt _pb_gb _ft _os
            _ft=$(blkid -s TYPE -o value "$_pp" 2>/dev/null || echo "?")
            _pb_gb=$(( $(blockdev --getsize64 "$_pp" 2>/dev/null || echo 0) / 1073741824 ))
            echo -e "    ${CYAN}${BOLD}→ $_pp${NC}  [${_ft}]  ${_pb_gb} GB"
            # Add them as shrink candidates
            candidates+=("$_pp|$_ft|$_pb_gb|[kept OS — shrink to make space]")
        done
        blank
        warn "Shrinking a kept OS partition will reduce its available space."
        warn "Make sure the OS can fit in the new smaller size before proceeding."
        blank
    fi

    if [[ ${#candidates[@]} -eq 0 ]]; then
        warn "No suitable partitions found on ${disk}."
        warn "Tip: use GParted live to free space, then re-run ArchWizard."
        FREE_GB_AVAIL=0
        return 0
    fi

    # ── Collect other disks (for option A) ───────────────────────────────
    local other_disks=()
    while IFS= read -r dev; do
        [[ "/dev/$dev" == "$disk" ]] && continue
        local ob
        ob=$(blockdev --getsize64 "/dev/$dev" 2>/dev/null || echo 0)
        [[ $(( ob / 1073741824 )) -ge $NEEDED_GB ]] && other_disks+=("/dev/$dev")
    done < <(lsblk -d -n -o NAME 2>/dev/null | grep -v "^loop\|^sr")

    # ── Present the space options menu ────────────────────────────────────
    blank
    info "How do you want to make space for Arch Linux?"
    blank
    local space_opts=()
    [[ ${#other_disks[@]} -gt 0 ]] && \
        space_opts+=("Use a different disk entirely")
    # Only offer "Replace" for non-protected candidates
    # (can't delete an OS the user said to keep)
    local _has_unprotected=false
    for _c in "${candidates[@]}"; do
        local _cp="${_c%%|*}" _is_prot=false
        for _pp in "${PROTECTED_PARTS[@]+"${PROTECTED_PARTS[@]}"}"; do
            [[ "$_pp" == "$_cp" ]] && _is_prot=true && break
        done
        [[ "$_is_prot" == false ]] && _has_unprotected=true && break
    done
    [[ "$_has_unprotected" == true ]] && \
        space_opts+=("Replace a partition (delete it — ALL DATA LOST)")
    space_opts+=("Shrink a partition  (keep data, reduce size)")
    select_option "Choose an option:" "${space_opts[@]}"
    local space_choice="$REPLY"

    # ── Option A: different disk ──────────────────────────────────────────
    if [[ "$space_choice" == "Use a different disk entirely" ]]; then
        local alt_list=()
        for d in "${other_disks[@]}"; do
            local dsz dm
            dsz=$(lsblk -dno SIZE  "$d" 2>/dev/null)
            dm=$(lsblk  -dno MODEL "$d" 2>/dev/null | cut -c1-28)
            alt_list+=("$(printf '%s  %-6s  %s' "$d" "$dsz" "$dm")")
        done
        select_option "Select disk for Arch Linux root (/):" "${alt_list[@]}"
        DISK_ROOT=$(echo "$REPLY" | awk '{print $1}')
        local new_free
        new_free=$(( $(blockdev --getsize64 "$DISK_ROOT" 2>/dev/null || echo 0) / 1073741824 ))
        FREE_GB_AVAIL=$new_free
        ok "Arch will be installed on ${BOLD}${DISK_ROOT}${NC} (${new_free} GB available)"
        return
    fi

    # ── Build display list of partitions ─────────────────────────────────
    _show_candidates() {
        local idx=0
        for c in "${candidates[@]}"; do
            local cp="${c%%|*}" rest="${c#*|}"
            local cf="${rest%%|*}" rest2="${rest#*|}"
            local csz="${rest2%%|*}" con="${rest2##*|}"
            idx=$(( idx + 1 ))
            local info_str="[${cf}]  ${csz} GB"
            [[ -n "$con" ]] && info_str+="  — ${con}"
            echo -e "    ${CYAN}${BOLD}${idx}) ${cp}${NC}  ${info_str}"
        done
    }

    # ── Option B: replace (delete entirely) ──────────────────────────────
    if [[ "$space_choice" == Replace* ]]; then
        blank
        info "Select the partition to DELETE entirely:"
        info "${RED}ALL DATA on this partition will be permanently lost.${NC}"
        blank
        _show_candidates

        # Build select_option list
        local rep_items=()
        for c in "${candidates[@]}"; do
            local cp="${c%%|*}" rest="${c#*|}"
            local cf="${rest%%|*}" rest2="${rest#*|}"
            local csz="${rest2%%|*}" con="${rest2##*|}"
            local lbl="$(printf '%-14s  [%-10s]  %s GB' "$cp" "$cf" "$csz")"
            [[ -n "$con" ]] && lbl+="  (${con})"
            rep_items+=("$lbl")
        done
        select_option "Which partition to delete?" "${rep_items[@]}"
        REPLACE_PART=$(echo "$REPLY" | awk '{print $1}')

        local rep_gb
        rep_gb=$(( $(blockdev --getsize64 "$REPLACE_PART" 2>/dev/null || echo 0) / 1073741824 ))
        FREE_GB_AVAIL=$(( free_gb + rep_gb ))

        blank
        warn "╔══════════════════════════════════════════════════════════╗"
        warn "  PLAN: DELETE ${REPLACE_PART}  (${rep_gb} GB)"
        warn "  ALL DATA ON THIS PARTITION WILL BE PERMANENTLY LOST."
        warn "  This will free ${rep_gb} GB → total available: ${FREE_GB_AVAIL} GB"
        warn "╚══════════════════════════════════════════════════════════╝"
        blank
        warn "The deletion will happen after you confirm the installation summary."
        blank
        return
    fi

    # ── Option C: shrink ──────────────────────────────────────────────────
    blank
    info "Select the partition to SHRINK:"
    blank

    # Filter: exclude swap, LUKS, XFS (cannot shrink), and show warnings
    local shrink_items=()
    local shrink_map=()   # parallel array: index → candidate index
    local idx=0
    for c in "${candidates[@]}"; do
        local cp="${c%%|*}" rest="${c#*|}"
        local cf="${rest%%|*}" rest2="${rest#*|}"
        local csz="${rest2%%|*}" con="${rest2##*|}"
        idx=$(( idx + 1 ))
        if [[ "$cf" == "xfs" ]]; then
            echo -e "    ${YELLOW}→ ${cp}${NC}  [xfs]  ${csz} GB  ${DIM}(XFS cannot be shrunk)${NC}"
            continue
        fi
        if [[ "$cf" == "crypto_LUKS" ]]; then
            echo -e "    ${YELLOW}→ ${cp}${NC}  [LUKS]  ${csz} GB  ${DIM}(encrypted — cannot shrink)${NC}"
            continue
        fi
        if [[ "$cf" == "swap" ]]; then continue; fi
        (( csz < 5 )) && continue
        local lbl="$(printf '%-14s  [%-10s]  %s GB' "$cp" "$cf" "$csz")"
        [[ -n "$con" ]] && lbl+="  (${con})"
        shrink_items+=("$lbl")
        shrink_map+=("$cp|$cf|$csz")
    done

    if [[ ${#shrink_items[@]} -eq 0 ]]; then
        warn "No shrinkable partitions available (XFS/LUKS/too small)."
        warn "Try the 'Replace' option or use GParted live."
        FREE_GB_AVAIL=0
        return 0
    fi

    select_option "Which partition to shrink?" "${shrink_items[@]}"
    # Map selection back to the candidate
    local sel_idx=0
    for item in "${shrink_items[@]}"; do
        if [[ "$item" == "$REPLY" ]]; then break; fi
        sel_idx=$(( sel_idx + 1 ))
    done
    local sel="${shrink_map[$sel_idx]}"
    RESIZE_PART="${sel%%|*}"
    local rest="${sel#*|}"
    local rft="${rest%%|*}"
    local rsize_gb="${rest##*|}"

    # Measure minimum safe size
    local min_safe_gb=2
    case "$rft" in
        ntfs)
            local ntfs_min_mb
            ntfs_min_mb=$(ntfsresize --no-action --size 1M "$RESIZE_PART" 2>&1                           | grep -i "minimum size" | grep -oE '[0-9]+' | head -1 || echo 0)
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
            used_b=$(btrfs filesystem usage -b "$RESIZE_PART" 2>/dev/null                      | awk '/Used:/{print $2}' | head -1 || echo 0)
            min_safe_gb=$(( (${used_b:-0} * 12 / 10) / 1073741824 + 2 ))
            ;;
    esac

    info "Partition: ${BOLD}${RESIZE_PART}${NC}  [${rft}]  current: ${rsize_gb} GB"
    info "Minimum safe size (data + 20% margin): ${BOLD}${min_safe_gb} GB${NC}"
    blank

    local new_gb
    while true; do
        ask "New size for ${RESIZE_PART} in GB [min: ${min_safe_gb}, max: $(( rsize_gb - 1 ))]:"
        read -r new_gb
        if [[ "$new_gb" =~ ^[0-9]+$ ]]             && (( new_gb >= min_safe_gb ))             && (( new_gb < rsize_gb )); then
            break
        fi
        warn "Enter a number between ${min_safe_gb} and $(( rsize_gb - 1 ))."
    done

    RESIZE_NEW_GB=$new_gb
    local freed=$(( rsize_gb - new_gb ))
    FREE_GB_AVAIL=$(( free_gb + freed ))

    blank
    ok "Plan: shrink ${BOLD}${RESIZE_PART}${NC}  ${rsize_gb} GB → ${new_gb} GB  (frees ${freed} GB)"
    ok "Total space available for Arch: ${BOLD}${FREE_GB_AVAIL} GB${NC}"
    warn "The resize will happen after you confirm the installation summary."
    blank
}

# ── select_disks ─────────────────────────────────────────────────────────────
# Lets the user pick the root disk (and optionally a separate home disk).
# Adds useful guards:
#   • Media type (NVMe/SSD/HDD/USB) shown in the menu
#   • Disk size shown in GiB (not just raw bytes)
#   • Warning if disk is smaller than 15 GB (barely enough for base + DE)
#   • Warning if the chosen root disk contains Windows partitions but dual-boot
#     mode is NOT active (user may be about to destroy Windows accidentally)
#   • Final danger banner listing every disk that will be modified
select_disks() {
    section "Select Disks"

    # Build enriched disk list for the selection menu
    local disk_list=()
    while IFS= read -r dev; do
        local size rota tran model media
        size=$(lsblk  -dno SIZE  "/dev/${dev}" 2>/dev/null)
        rota=$(lsblk  -dno ROTA  "/dev/${dev}" 2>/dev/null)
        tran=$(lsblk  -dno TRAN  "/dev/${dev}" 2>/dev/null)
        model=$(lsblk -dno MODEL "/dev/${dev}" 2>/dev/null | cut -c1-28)
        if   [[ "$tran" == "nvme" ]]; then media="NVMe"
        elif [[ "$rota" == "0"   ]]; then media="SSD "
        elif [[ "$tran" == "usb" ]]; then media="USB "
        else                              media="HDD "; fi
        disk_list+=("$(printf '/dev/%-10s  %-5s  %-6s  %s' "$dev" "$size" "$media" "$model")")
    done < <(lsblk -d -n -o NAME 2>/dev/null | grep -v "^loop\|^sr")

    if [[ ${#disk_list[@]} -eq 0 ]]; then
        error "No disks found! Something is very wrong."
        exit 1
    fi

    # ── Root disk ─────────────────────────────────────────────────────────
    select_option "Select disk for ROOT (/):" "${disk_list[@]}"
    DISK_ROOT=$(echo "$REPLY" | awk '{print $1}')

    # Size guard — warn if < 15 GB
    local root_bytes root_gb_check
    root_bytes=$(blockdev --getsize64 "$DISK_ROOT" 2>/dev/null || echo 0)
    root_gb_check=$(( root_bytes / 1073741824 ))
    if (( root_gb_check < 15 )); then
        warn "Disk ${DISK_ROOT} is only ${root_gb_check} GB — minimum recommended is 20 GB."
        confirm "Continue anyway?" "n" || { info "Aborted."; exit 0; }
    fi

    # ── OS guard + multi-boot offer ─────────────────────────────────────
    # Runs ONLY if Section 3 didn't already enable multi-boot.
    # Probes the partitions of the chosen disk to find any existing OS,
    # then asks the right question IN THE RIGHT ORDER:
    #   1. "Do you want to KEEP it?" (multi-boot)   ← offered FIRST
    #   2. Only if the user says NO: "I understand it will be erased"
    #
    # This replaces the old two-block design where the user had to confirm
    # erasure BEFORE being offered the multi-boot option — which was
    # confusing and caused the "multi-boot was not enabled" false alarm.
    if [[ "$DUAL_BOOT" == false ]]; then

        # Probe every partition on the chosen disk using the global probe_os_from_part().
        # Use global probe_os_from_part() — no need for local duplicate
        local _guard_found=()
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            local _pt _pb
            _pt=$(lsblk -no PARTTYPE "$p" 2>/dev/null || echo "")
            _pb=$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)
            [[ "$_pt" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] && continue
            [[ "$_pt" == "0657fd6d-a4ab-43c4-84e5-0933c84b4f4f" ]] && continue
            (( _pb < 500000000 )) && continue
            probe_os_from_part "$p" || true
            [[ -n "$PROBE_OS_RESULT" ]] && _guard_found+=("${PROBE_OS_RESULT}|${p}")
        done < <(lsblk -ln -o PATH "$DISK_ROOT" 2>/dev/null | tail -n +2)

        if [[ ${#_guard_found[@]} -gt 0 ]]; then
            blank
            warn "Existing OS(es) found on ${BOLD}${DISK_ROOT}${NC}:"
            blank
            for entry in "${_guard_found[@]}"; do
                local _en="${entry%%|*}" _ep="${entry##*|}"
                local _es
                _es=$(lsblk -dno SIZE "$_ep" 2>/dev/null || echo "?")
                echo -e "    ${CYAN}${BOLD}→ ${_en}${NC}  ${DIM}(${_ep}, ${_es})${NC}"
            done
            blank

            # ── Ask per-OS what the user wants to do ─────────────────────
            # With multiple OSes on the same disk, the user may want to keep
            # some and sacrifice others to make room for Arch.
            # We ask for each OS individually, then run the space check with
            # full knowledge of which partitions are protected.
            local _any_kept=false
            for entry in "${_guard_found[@]}"; do
                local _en="${entry%%|*}" _ep="${entry##*|}"
                local _es
                _es=$(lsblk -dno SIZE "$_ep" 2>/dev/null || echo "?")
                blank
                echo -e "  ${CYAN}${BOLD}[$_en]${NC}  ${DIM}${_ep} (${_es})${NC}"
                if confirm "  Keep ${BOLD}${_en}${NC}? (say No to make it available for deletion/reuse)" "y"; then
                    EXISTING_SYSTEMS+=("$_en")
                    PROTECTED_PARTS+=("$_ep")
                    echo "$_en" | grep -qi "windows"                         && EXISTING_WINDOWS=true || EXISTING_LINUX=true
                    ok "  ${_en} → will be PRESERVED"
                    _any_kept=true
                else
                    warn "  ${_en} (${_ep}) → available for deletion or reuse"
                fi
            done
            blank

            if [[ "$_any_kept" == true ]]; then
                # At least one OS will be kept → multi-boot mode
                DUAL_BOOT=true
                local _sys_str
                _sys_str=$(IFS=', '; echo "${EXISTING_SYSTEMS[*]}")
                ok "Multi-boot enabled — will preserve: ${BOLD}${_sys_str}${NC}"
                info "GRUB + os-prober will be strongly recommended as bootloader."
                blank
                # Space analysis — partitions marked for deletion are offered
                # in the replace menu; protected partitions are excluded.
                _check_and_plan_space "$DISK_ROOT"
            else
                # No OS kept → fresh install (entire disk will be wiped)
                blank
                warn "╔══════════════════════════════════════════════════════════╗"
                warn "  No OS will be kept — entire disk will be wiped."
                warn "╚══════════════════════════════════════════════════════════╝"
                blank
                if ! confirm "${RED}${BOLD}I understand — erase everything on ${DISK_ROOT}${NC}" "n"; then
                    info "Aborted — no changes made."
                    exit 0
                fi
            fi

        else
            # No OS found on this disk — fresh install, no confirmation needed
            info "No existing OS detected on ${DISK_ROOT} — fresh install."
        fi
    fi

    # ── Optional separate home disk ───────────────────────────────────────
    DISK_HOME="$DISK_ROOT"
    if [[ ${#disk_list[@]} -gt 1 ]]; then
        blank
        if confirm "Put /home on a different disk?" "n"; then
            select_option "Select disk for /home:" "${disk_list[@]}"
            DISK_HOME=$(echo "$REPLY" | awk '{print $1}')
            local home_bytes home_gb_check
            home_bytes=$(blockdev --getsize64 "$DISK_HOME" 2>/dev/null || echo 0)
            home_gb_check=$(( home_bytes / 1073741824 ))
            ok "Home disk → ${BOLD}$DISK_HOME${NC}  (${home_gb_check} GB)"
        fi
    fi

    # ── Danger banner ─────────────────────────────────────────────────────
    blank
    warn "╔══════════════════════════════════════════════════════════╗"
    warn "  DISK(S) THAT WILL BE MODIFIED:"
    warn "    Root : $DISK_ROOT"
    [[ "$DISK_HOME" != "$DISK_ROOT" ]] && warn "    Home : $DISK_HOME"
    if [[ "$DUAL_BOOT" == true ]]; then
        local sys_label
        sys_label=$(IFS=', '; echo "${EXISTING_SYSTEMS[*]}")
        warn "  Mode : multi-boot (existing partitions will be PRESERVED)"
        warn "  Keep : ${sys_label}"
    else
        warn "  Mode : fresh install (ENTIRE DISK WILL BE WIPED)"
    fi
    warn "╚══════════════════════════════════════════════════════════╝"
    blank
}

# =============================================================================
#  SECTION 5 — PARTITION LAYOUT WIZARD
# =============================================================================

# ── partition_wizard ──────────────────────────────────────────────────────────
# Collects all partition sizing decisions BEFORE touching any disk.
# Improvements over the naive approach:
#   • Validates all numeric inputs (rejects letters, negatives, oversized values)
#   • Tracks remaining disk space and shows it after each size entry
#   • Recommends a swap size based on detected physical RAM
#   • Shows a visual partition layout preview at the end so the user can
#     verify the plan matches their expectations before proceeding
partition_wizard() {
    section "Partition Layout"

    local disk_bytes disk_gb avail_gb
    disk_bytes=$(blockdev --getsize64 "$DISK_ROOT" 2>/dev/null || echo 0)
    disk_gb=$(( disk_bytes / 1073741824 ))

    # In multi-boot mode, FREE_GB_AVAIL was set by _check_and_plan_space()
    # and reflects the real space that will be available (free + resize plan).
    # Use that as the budget instead of the full disk size.
    # IMPORTANT: FREE_GB_AVAIL=0 means "not set yet" OR "no space found".
    # When DUAL_BOOT=true but FREE_GB_AVAIL=0, it means _check_and_plan_space
    # couldn't find any space — warn and use a conservative budget.
    if [[ "$DUAL_BOOT" == true ]]; then
        if [[ "$FREE_GB_AVAIL" -gt 0 ]]; then
            avail_gb=$FREE_GB_AVAIL
            info "Space budget for Arch Linux: ${BOLD}${avail_gb} GB${NC} (planned space after resize/delete)"
        else
            # No space was found/planned — use a small conservative value
            # to force the user to enter realistic sizes
            avail_gb=$(( disk_gb / 2 ))
            warn "Space budget could not be determined — using conservative estimate: ${avail_gb} GB"
            warn "Make sure your size choices fit within the actual unallocated space."
        fi
    else
        avail_gb=$disk_gb   # fresh install: full disk is available
    fi

    # ── Helper: validate a numeric GB input ──────────────────────────────
    # Usage: _get_gb "prompt" default_value max_gb → sets result in $GB_RESULT
    _get_gb() {
        local prompt="$1" default="$2" max="$3" val
        while true; do
            val=$(get_input "$prompt" "$default")
            if [[ "$val" == "rest" ]]; then GB_RESULT="rest"; return; fi
            if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 1 )) && (( val <= max )); then
                GB_RESULT="$val"; return
            fi
            warn "Enter a number between 1 and ${max}, or 'rest'."
        done
    }

    # ── EFI (UEFI only) ──────────────────────────────────────────────────
    # In BIOS mode there is no EFI System Partition — GRUB is installed
    # directly to the disk MBR. Skip the entire EFI section.
    if [[ "$FIRMWARE_MODE" == "bios" ]]; then
        info "BIOS mode — no EFI partition needed."
    elif [[ "$DUAL_BOOT" == true ]]; then
        # In multi-boot mode there is ALWAYS an existing EFI System Partition
        # (the other OS needs one to boot). We MUST reuse it — creating a
        # second ESP would confuse the UEFI firmware.
        # If discover_disks() didn't auto-detect it (e.g. unusual GPT flags),
        # we scan for it here as a fallback.
        if [[ "$REUSE_EFI" == false || -z "$EFI_PART" ]]; then
            info "Searching for existing EFI System Partition…"
            local _esp_found=""
            while IFS= read -r p; do
                [[ -z "$p" ]] && continue
                local _ept
                _ept=$(lsblk -no PARTTYPE "$p" 2>/dev/null || echo "")
                local _esz
                _esz=$(( $(blockdev --getsize64 "$p" 2>/dev/null || echo 0) / 1048576 ))
                # Match by EFI GUID or by FAT32 ≤ 1 GB
                if [[ "$_ept" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]]                    || [[ "$(blkid -s TYPE -o value "$p" 2>/dev/null)" == "vfat"                          && $_esz -le 1024 ]]; then
                    _esp_found="$p"
                    break
                fi
            done < <(lsblk -ln -o PATH "$DISK_ROOT" 2>/dev/null | tail -n +2)

            if [[ -n "$_esp_found" ]]; then
                EFI_PART="$_esp_found"
                REUSE_EFI=true
                ok "Found EFI System Partition: ${BOLD}${EFI_PART}${NC} — will be reused"
            else
                # No ESP found on the disk — very unusual in multi-boot UEFI context
                warn "No EFI System Partition found on ${DISK_ROOT}."
                warn "This is unexpected in a UEFI multi-boot setup."
                warn "A new 512 MB EFI partition will be created in unallocated space."
                EFI_SIZE_MB=512
                REUSE_EFI=false
            fi
        else
            ok "Reusing existing EFI: ${BOLD}${EFI_PART}${NC}  ($(lsblk -dno SIZE "$EFI_PART" 2>/dev/null))"
        fi
        info "Disk: ${BOLD}$DISK_ROOT${NC} — available for Arch: ${BOLD}${avail_gb} GB${NC}"
    elif [[ "$REUSE_EFI" == false ]]; then
        info "Disk: ${BOLD}$DISK_ROOT${NC} — total: ${BOLD}${disk_gb} GB${NC}"
        EFI_SIZE_MB=$(get_input "EFI partition size (MB)" "512")
        avail_gb=$(( avail_gb - 1 ))    # ~512 MB rounded to 1 GB for display
        info "Remaining after EFI: ${BOLD}~${avail_gb} GB${NC}"
    else
        info "Disk: ${BOLD}$DISK_ROOT${NC} — total: ${BOLD}${disk_gb} GB${NC} (reusing existing EFI)"
    fi
    blank

    # ── Partition layout strategy ─────────────────────────────────────────
    # Choose the layout BEFORE asking for sizes, so the size questions are
    # clear and contextualised. Avoids the previous problem where the user
    # could accidentally select "rest" for root then be asked about /home.
    section "Partition Layout Strategy"
    info "Available space for Arch: ${BOLD}${avail_gb} GB${NC}"
    blank

    # Different options depending on whether home disk is separate
    SEP_HOME=false
    local layout_choice
    if [[ "$DISK_HOME" != "$DISK_ROOT" ]]; then
        # Separate home disk selected earlier — /home always goes there
        SEP_HOME=true
        layout_choice="split_disk"
        info "Layout: ${BOLD}/ on $DISK_ROOT${NC} + ${BOLD}/home on $DISK_HOME${NC}"
    else
        echo -e "  ${BOLD}1)${NC} / only          ${DIM}root takes all available space — simplest${NC}"
        echo -e "              ${DIM}  → recommended for small disks or single-purpose installs${NC}"
        echo -e "  ${BOLD}2)${NC} / + /home       ${DIM}separate home partition — user data isolated from system${NC}"
        echo -e "              ${DIM}  → recommended: reinstall OS without losing user files${NC}"
        echo -e "  ${BOLD}3)${NC} / + /home + /swap ${DIM}explicit swap partition (if not using zram)${NC}"
        blank
        ask "Choose layout [1-3] (default: 2):"
        read -r layout_raw
        case "${layout_raw:-2}" in
            1) layout_choice="root_only"  ;;
            3) layout_choice="root_home_swap" ;;
            *) layout_choice="root_home" ;;
        esac
    fi

    # ── Size questions based on chosen layout ────────────────────────────
    local root_max=$(( avail_gb - 1 ))   # 1 GB headroom minimum

    case "$layout_choice" in

        root_only)
            # Root takes everything — no /home partition
            info "Root (/) will use all ${avail_gb} GB of available space."
            if confirm "Use all available space for /? (recommended for this layout)" "y"; then
                ROOT_SIZE="rest"
            else
                _get_gb "Root (/) size in GB" "$avail_gb" "$root_max"
                ROOT_SIZE="$GB_RESULT"
            fi
            ;;

        root_home|root_home_swap)
            # Suggest a sensible root size based on available space and DE
            local suggested_root=40
            (( avail_gb < 60  )) && suggested_root=25
            (( avail_gb < 30  )) && suggested_root=15
            (( avail_gb < 15  )) && suggested_root=$(( avail_gb * 6 / 10 ))
            (( avail_gb > 100 )) && suggested_root=60

            info "Available: ${BOLD}${avail_gb} GB${NC}"
            info "Suggested root size: ${BOLD}${suggested_root} GB${NC}  (remaining goes to /home)"
            blank
            _get_gb "Root (/) size in GB" "$suggested_root" "$(( avail_gb - 4 ))"
            ROOT_SIZE="$GB_RESULT"
            avail_gb=$(( avail_gb - ROOT_SIZE ))
            info "Remaining for /home: ${BOLD}${avail_gb} GB${NC}"
            blank

            SEP_HOME=true
            if confirm "Give all remaining space (${avail_gb} GB) to /home?" "y"; then
                HOME_SIZE="rest"
            else
                _get_gb "Home (/home) size in GB" "$avail_gb" "$avail_gb"
                HOME_SIZE="$GB_RESULT"
                avail_gb=$(( avail_gb - HOME_SIZE ))
            fi
            ;;

        split_disk)
            # Root on DISK_ROOT, home on DISK_HOME
            local root_default=60
            (( avail_gb < 80  )) && root_default=40
            (( avail_gb < 40  )) && root_default=20
            _get_gb "Root (/) size in GB on $DISK_ROOT  [or 'rest']" "$root_default" "$root_max"
            ROOT_SIZE="$GB_RESULT"

            local home_bytes home_gb
            home_bytes=$(blockdev --getsize64 "$DISK_HOME" 2>/dev/null || echo 0)
            home_gb=$(( home_bytes / 1073741824 ))
            info "Home disk ${BOLD}$DISK_HOME${NC}: ${BOLD}${home_gb} GB${NC} available"
            if confirm "Give all ${home_gb} GB to /home?" "y"; then
                HOME_SIZE="rest"
            else
                _get_gb "Home (/home) size in GB on $DISK_HOME" "$home_gb" "$home_gb"
                HOME_SIZE="$GB_RESULT"
            fi
            ;;
    esac
    blank

    ok "Layout: root=${ROOT_SIZE} GB${SEP_HOME:+ | home=${HOME_SIZE} GB}"
    blank

    # ── Filesystem ────────────────────────────────────────────────────────
    section "Filesystem Type"
    info "Choose the filesystem for root (/) and optionally /home."
    blank
    echo -e "  ${BOLD}1)${NC} btrfs   ${DIM}default — snapshots, transparent compression, CoW, modern${NC}"
    echo -e "            ${DIM}  → enables Snapper, zstd compression, subvolumes${NC}"
    echo -e "  ${BOLD}2)${NC} ext4    ${DIM}most widely used, rock-solid, excellent compatibility${NC}"
    echo -e "            ${DIM}  → journaling, mature, works everywhere${NC}"
    echo -e "  ${BOLD}3)${NC} xfs     ${DIM}high performance for large files and parallel I/O${NC}"
    echo -e "            ${DIM}  → excellent for servers, data disks; cannot shrink${NC}"
    echo -e "  ${BOLD}4)${NC} f2fs    ${DIM}Flash-Friendly FS — optimised for NAND flash (SSD/NVMe/SD)${NC}"
    echo -e "            ${DIM}  → great write performance on flash storage${NC}"
    blank
    ask "Root filesystem [1-4] (default: 1):"
    read -r fs_choice
    case "${fs_choice:-1}" in
        2) ROOT_FS="ext4" ;;
        3) ROOT_FS="xfs"  ;;
        4) ROOT_FS="f2fs" ;;
        *) ROOT_FS="btrfs" ;;
    esac
    ok "Root filesystem: ${BOLD}${ROOT_FS}${NC}"

    # Disable Snapper and btrfs-specific swap if not btrfs
    if [[ "$ROOT_FS" != "btrfs" ]]; then
        info "Note: Snapper snapshots require btrfs — will be disabled."
        info "Note: btrfs swap file unavailable — zram or swap partition recommended."
    fi

    # Separate /home filesystem (only asked when SEP_HOME=true)
    HOME_FS="$ROOT_FS"   # default: same as root
    if [[ "$SEP_HOME" == true ]]; then
        blank
        info "Home partition filesystem (press Enter to use same as root: ${ROOT_FS}):"
        echo -e "  ${BOLD}1)${NC} same as root  (${ROOT_FS})"
        echo -e "  ${BOLD}2)${NC} btrfs"
        echo -e "  ${BOLD}3)${NC} ext4"
        echo -e "  ${BOLD}4)${NC} xfs"
        echo -e "  ${BOLD}5)${NC} f2fs"
        blank
        ask "Home filesystem [1-5] (default: 1):"
        read -r hfs_choice
        case "${hfs_choice:-1}" in
            2) HOME_FS="btrfs" ;;
            3) HOME_FS="ext4"  ;;
            4) HOME_FS="xfs"   ;;
            5) HOME_FS="f2fs"  ;;
            *) HOME_FS="$ROOT_FS" ;;
        esac
        ok "Home filesystem: ${BOLD}${HOME_FS}${NC}"
    fi
    blank

    # ── Swap ─────────────────────────────────────────────────────────────
    # Recommend a sensible swap size based on detected RAM.
    local ram_kb ram_gb recommended_swap
    ram_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
    ram_gb=$(( ${ram_kb:-0} / 1048576 ))
    if   (( ram_gb >= 32 )); then recommended_swap="0 (not needed with ${ram_gb}GB RAM)"
    elif (( ram_gb >= 16 )); then recommended_swap="4"
    elif (( ram_gb >=  8 )); then recommended_swap="8"
    else                          recommended_swap="$(( ram_gb * 2 ))"; fi

    section "Swap Configuration"
    info "Detected RAM: ${BOLD}${ram_gb} GB${NC}  — recommended swap: ${BOLD}${recommended_swap} GB${NC}"
    blank
    echo -e "  ${BOLD}1)${NC} zram          ${DIM}zstd-compressed RAM swap — no disk use, fastest${NC}"
    echo -e "              ${DIM}  → ideal for ${ram_gb}+ GB RAM; swappiness=100 recommended${NC}"
    if [[ "$ROOT_FS" == "btrfs" ]]; then
        echo -e "  ${BOLD}2)${NC} Swap file     ${DIM}btrfs swapfile in @swap subvol — supports hibernation${NC}"
    else
        echo -e "  ${BOLD}2)${NC} Swap file     ${DIM}regular swapfile in /swap — supports hibernation${NC}"
    fi
    echo -e "  ${BOLD}3)${NC} Swap partition${DIM}dedicated partition — most compatible (legacy systems)${NC}"
    echo -e "  ${BOLD}4)${NC} None          ${DIM}no swap — only safe with 32 GB+ RAM${NC}"
    blank
    ask "Choose swap type [1-4] (default: 1):"
    read -r swap_choice
    case "${swap_choice:-1}" in
        2) SWAP_TYPE="file"
           _get_gb "Swap file size (GB)" "${recommended_swap//[^0-9]/8}" "$(( disk_gb / 4 ))"
           SWAP_SIZE="$GB_RESULT" ;;
        3) SWAP_TYPE="partition"
           _get_gb "Swap partition size (GB)" "${recommended_swap//[^0-9]/8}" "$(( disk_gb / 4 ))"
           SWAP_SIZE="$GB_RESULT" ;;
        4) SWAP_TYPE="none" ;;
        *) SWAP_TYPE="zram" ;;
    esac
    ok "Swap: ${BOLD}${SWAP_TYPE}${NC}${SWAP_SIZE:+ — ${SWAP_SIZE} GB}"

    # ── LUKS ─────────────────────────────────────────────────────────────
    blank
    if confirm "Enable LUKS2 full-disk encryption?" "n"; then
        USE_LUKS=true
        warn "You will need this passphrase at EVERY boot — do not forget it!"
        LUKS_PASSWORD=$(get_password "LUKS passphrase")
        ok "LUKS2 encryption enabled  (AES-256-XTS, SHA-512)"
    fi

    # ── Partition layout preview ──────────────────────────────────────────
    blank
    info "Planned partition layout for ${BOLD}$DISK_ROOT${NC}:"
    echo -e "  ${BOLD}┌─────────────────────────────────────────────────────┐${NC}"
    if [[ "$REUSE_EFI" == true ]]; then
        echo -e "  │  ${CYAN}EFI${NC}       reused  (${EFI_PART})                     │"
    else
        echo -e "  │  ${CYAN}EFI${NC}       ${EFI_SIZE_MB} MB   FAT32                          │"
    fi
    [[ "$SWAP_TYPE" == "partition" ]] &&     echo -e "  │  ${CYAN}swap${NC}      ${SWAP_SIZE} GB    linux-swap                    │"
    local root_disp="${ROOT_SIZE} GB"
    [[ "$ROOT_SIZE" == "rest" ]] && root_disp="remaining space"
    local luks_note=""; [[ "$USE_LUKS" == true ]] && luks_note=" [LUKS2]"
    echo -e "  │  ${CYAN}root (/)${NC}  ${root_disp}   btrfs${luks_note}                 │"
    if [[ "$SEP_HOME" == true && "$DISK_HOME" == "$DISK_ROOT" ]]; then
        local home_disp="${HOME_SIZE} GB"
        [[ "$HOME_SIZE" == "rest" ]] && home_disp="remaining space"
        echo -e "  │  ${CYAN}/home${NC}     ${home_disp}   btrfs${luks_note}                 │"
    fi
    echo -e "  ${BOLD}└─────────────────────────────────────────────────────┘${NC}"
    if [[ "$SEP_HOME" == true && "$DISK_HOME" != "$DISK_ROOT" ]]; then
        info "Planned layout for ${BOLD}$DISK_HOME${NC} (/home):"
        echo -e "  ${BOLD}┌─────────────────────────────────────────────────────┐${NC}"
        local home_disp2="${HOME_SIZE} GB"
        [[ "$HOME_SIZE" == "rest" ]] && home_disp2="full disk"
        echo -e "  │  ${CYAN}/home${NC}     ${home_disp2}   btrfs                         │"
        echo -e "  ${BOLD}└─────────────────────────────────────────────────────┘${NC}"
    fi
    blank
}

# =============================================================================
#  SECTION 6 — SYSTEM IDENTITY
# =============================================================================

configure_system() {
    section "System Identity"
    HOSTNAME=$(get_input "Hostname" "archlinux")

    blank
    info "GRUB boot menu entry — the name shown when you select this OS at boot."
    info "Examples: "Arch Linux", "Arch Gaming", "Arch Work", "Arch Dev""
    GRUB_ENTRY_NAME=$(get_input "GRUB boot menu name" "Arch Linux (${HOSTNAME})")

    blank
    info "Timezone examples: Europe/Paris  America/New_York  Asia/Tokyo  UTC"
    while true; do
        TIMEZONE=$(get_input "Timezone" "Europe/Paris")
        if [[ -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
            break
        fi
        warn "Timezone '${TIMEZONE}' not found in /usr/share/zoneinfo/."
        warn "Browse available zones: ls /usr/share/zoneinfo/"
    done

    blank
    info "Locale examples: en_US.UTF-8  fr_FR.UTF-8  de_DE.UTF-8"
    while true; do
        LOCALE=$(get_input "Locale" "fr_FR.UTF-8")
        # Validate: locale must exist in /etc/locale.gen supported list
        if grep -q "^#\?${LOCALE} " /etc/locale.gen 2>/dev/null ||            find /usr/share/i18n/locales -name "${LOCALE%%.*}" 2>/dev/null | grep -q .; then
            break
        fi
        warn "Locale '${LOCALE}' not found. Use format: en_US.UTF-8 / fr_FR.UTF-8"
    done

    ok "Hostname: ${BOLD}$HOSTNAME${NC}  GRUB: ${BOLD}$GRUB_ENTRY_NAME${NC}"
    ok "Timezone: ${BOLD}$TIMEZONE${NC}  Locale: ${BOLD}$LOCALE${NC}"
}

# =============================================================================
#  SECTION 7 — USER ACCOUNTS
# =============================================================================

configure_users() {
    section "User Accounts"
    while true; do
        USERNAME=$(get_input "New username")
        if [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            break
        fi
        warn "Invalid: use lowercase letters, digits, underscores, hyphens; start with a letter."
    done

    USER_PASSWORD=$(get_password "Password for '${USERNAME}'")
    ROOT_PASSWORD=$(get_password "Root password")
    ok "User ${BOLD}$USERNAME${NC} configured (sudo via wheel group)"
}

# =============================================================================
#  SECTION 8 — KERNEL CHOICE
# =============================================================================

choose_kernel() {
    section "Kernel"
    echo -e "  ${BOLD}1)${NC} linux           ${DIM}latest stable — recommended for most users${NC}"
    echo -e "  ${BOLD}2)${NC} linux-lts        ${DIM}long-term support — rock-solid, slower updates${NC}"
    echo -e "  ${BOLD}3)${NC} linux-zen        ${DIM}zen — optimised for desktop responsiveness${NC}"
    echo -e "  ${BOLD}4)${NC} linux-hardened   ${DIM}security-hardened — extra kernel mitigations${NC}"
    blank
    ask "Choose kernel [1-4] (default: 1):"
    read -r kernel_choice
    case "${kernel_choice:-1}" in
        2) KERNEL="linux-lts"      ;;
        3) KERNEL="linux-zen"      ;;
        4) KERNEL="linux-hardened" ;;
        *) KERNEL="linux"          ;;
    esac
    ok "Kernel: ${BOLD}$KERNEL${NC}"
}

# =============================================================================
#  SECTION 9 — BOOTLOADER
# =============================================================================

choose_bootloader() {
    section "Bootloader"

    # In any multi-boot scenario, GRUB is the right choice because:
    #   • os-prober auto-detects Windows, Debian, Ubuntu, Fedora, etc.
    #     and adds them to the GRUB menu without manual configuration.
    #   • GRUB can chainload any bootloader (Windows Boot Manager, other GRUBs,
    #     systemd-boot of other distros).
    #   • grub-btrfs adds btrfs snapshot entries to the boot menu.
    #
    # systemd-boot in multi-boot:
    #   • Cannot auto-detect other Linux distros — each must be added manually
    #     by creating a .conf entry pointing to the exact vmlinuz path.
    #   • Can chainload Windows via a special loader entry (works but fragile).
    #   • Does NOT support os-prober — it has no equivalent mechanism.
    #   • Fine for single-OS Arch installs; not recommended for multi-boot.
    if [[ "$DUAL_BOOT" == true ]]; then
        blank
        info "Multi-boot mode is active. Detected systems:"
        for sys in "${EXISTING_SYSTEMS[@]}"; do
            echo -e "  ${CYAN}→ ${BOLD}${sys}${NC}"
        done
        echo -e "  ${CYAN}→ ${BOLD}Arch Linux${NC} (this install)"
        blank
        warn "${BOLD}GRUB is strongly recommended${NC} for multi-boot."
        warn "os-prober will auto-detect all OSes and add them to the boot menu."
        blank
    fi

    if [[ "$FIRMWARE_MODE" == "bios" ]]; then
        # BIOS mode: only GRUB supports legacy boot — no choice needed
        BOOTLOADER="grub"
        ok "Bootloader: ${BOLD}GRUB${NC} (only option in BIOS/Legacy mode)"
        info "GRUB will be installed to the MBR of ${BOLD}${DISK_ROOT}${NC}."
        return 0
    fi

    # UEFI mode: offer GRUB or systemd-boot
    echo -e "  ${BOLD}1)${NC} GRUB           ${DIM}recommended — auto-detects all OSes via os-prober${NC}"
    if [[ "$DUAL_BOOT" == true ]]; then
        echo -e "  ${BOLD}2)${NC} systemd-boot   ${DIM}${YELLOW}NOT recommended in multi-boot — no os-prober support${NC}"
    else
        echo -e "  ${BOLD}2)${NC} systemd-boot   ${DIM}minimal, fast — ideal for single-OS installs${NC}"
    fi
    blank
    ask "Choose bootloader [1/2] (default: 1):"
    read -r bl_choice
    case "${bl_choice:-1}" in
        2) BOOTLOADER="systemd-boot"
           if [[ "$DUAL_BOOT" == true ]]; then
               blank
               warn "You chose systemd-boot with multi-boot active."
               warn "Other OSes will NOT appear in the boot menu automatically."
               warn "You will need to add boot entries manually after install."
               blank
               confirm "Proceed with systemd-boot anyway?" "n"                    || { BOOTLOADER="grub"; ok "Switched to GRUB."; }
           fi ;;
        *) BOOTLOADER="grub" ;;
    esac
    ok "Bootloader: ${BOLD}$BOOTLOADER${NC}"

    blank
    if confirm "Enable Secure Boot support? (requires sbctl key enrollment after first boot)" "n"; then
        SECURE_BOOT=true
        warn "After first boot, run: sbctl enroll-keys --microsoft && sbctl sign-all"
    fi
}

# =============================================================================
#  SECTION 10 — DESKTOP ENVIRONMENT (multi-select)
# =============================================================================

# ── choose_desktop ────────────────────────────────────────────────────────────
# Lets the user pick one or more desktop environments (multi-select).
# The input is a space-separated list of numbers, e.g. "1 3" for KDE + Hyprland.
#
# Key implementation detail: IFS is left at its default (space/tab/newline) so
# that `read -ra tokens <<< "$raw_input"` splits on spaces correctly.
# A previous version set `IFS=$'\n\t'` globally which removed space from the
# splitter and broke multi-desktop selection entirely.
#
# Deduplication: if the user enters "1 1 2", the DESKTOPS array ends up as
# ("kde" "gnome") — duplicates removed while preserving order.
#
# Display manager priority (evaluated again in generate_chroot_script):
#   sddm wins if KDE or Hyprland is present (both use Qt / are Wayland-first)
#   gdm   wins for GNOME
#   lightdm for XFCE
#   ly    fallback for Sway (minimal TUI login manager)
choose_desktop() {
    section "Desktop Environment"
    info "You can install multiple desktops. Enter numbers separated by spaces."
    info "Example: ${BOLD}1 3${NC} installs KDE Plasma + Hyprland"
    blank
    echo -e "  ${BOLD}1)${NC} KDE Plasma     ${DIM}feature-rich, fully Wayland-ready${NC}"
    echo -e "  ${BOLD}2)${NC} GNOME          ${DIM}polished Wayland, excellent touchpad/HiDPI support${NC}"
    echo -e "  ${BOLD}3)${NC} Hyprland       ${DIM}dynamic tiling Wayland compositor, highly customizable${NC}"
    echo -e "  ${BOLD}4)${NC} Sway           ${DIM}stable i3-compatible tiling WM, battle-tested Wayland${NC}"
    echo -e "  ${BOLD}5)${NC} COSMIC         ${DIM}new Rust-based DE by System76 (alpha — adventurous!)${NC}"
    echo -e "  ${BOLD}6)${NC} XFCE           ${DIM}lightweight GTK desktop, classic and reliable${NC}"
    echo -e "  ${BOLD}7)${NC} None           ${DIM}minimal TTY — configure your WM manually later${NC}"
    blank

    while true; do
        ask "Choose desktop(s) [1-7, space-separated] (no default — must choose):"
        local raw_input
        read -r raw_input
        # No default here — force an explicit choice to avoid accidentally
        # installing KDE when the user just pressed Enter expecting XFCE
        if [[ -z "$raw_input" ]]; then
            warn "Please enter a number (e.g. 1 for KDE, 6 for XFCE, 7 for none)."
            continue
        fi

        # Split on spaces explicitly — safe regardless of IFS setting
        local -a tokens
        read -ra tokens <<< "$raw_input"

        DESKTOPS=()
        local valid=true
        for c in "${tokens[@]}"; do
            # Strip any extra whitespace
            c="${c//[[:space:]]/}"
            [[ -z "$c" ]] && continue
            case "$c" in
                1) DESKTOPS+=("kde") ;;
                2) DESKTOPS+=("gnome") ;;
                3) DESKTOPS+=("hyprland") ;;
                4) DESKTOPS+=("sway") ;;
                5) DESKTOPS+=("cosmic") ;;
                6) DESKTOPS+=("xfce") ;;
                7) DESKTOPS=("none"); break ;;
                *) warn "Invalid choice: '$c'. Use numbers 1-7."; valid=false; break ;;
            esac
        done

        if [[ "$valid" == true && "${#DESKTOPS[@]}" -gt 0 ]]; then
            # Deduplicate while preserving order.
        # Uses an associative array (_seen) as a set — bash 4+ required.
            local -A _seen=()
            local -a _dedup=()
            for d in "${DESKTOPS[@]}"; do
                if [[ -z "${_seen[$d]+x}" ]]; then
                    _dedup+=("$d")
                    _seen[$d]=1
                fi
            done
            DESKTOPS=("${_dedup[@]}")
            break
        elif [[ "${#DESKTOPS[@]}" -eq 0 ]]; then
            warn "No valid desktop selected. Try again."
        fi
    done

    # Display manager priority: sddm > gdm > lightdm > ly
    # Determined at install time; re-evaluated in generate_chroot_script
    ok "Desktop(s) selected: ${BOLD}${DESKTOPS[*]}${NC}"
}

# =============================================================================
#  SECTION 11 — OPTIONAL EXTRAS
# =============================================================================

# ── choose_extras ─────────────────────────────────────────────────────────────
# Collects all remaining optional software choices.
# Every choice here only sets a boolean or string variable — nothing is installed yet.
# All installation happens in generate_chroot_script / arch-chroot.
#
# Reflector: fetches only HTTPS mirrors newer than N hours from selected countries,
#   tests their download speed, and keeps the fastest N. Runs on the live ISO first
#   (setup_mirrors) and again inside the installed system via reflector.timer.
#   The settings are persisted to /etc/xdg/reflector/reflector.conf so the timer
#   always uses the user's preferences, not reflector's built-in defaults.
#
# PipeWire: modern audio server that replaces both PulseAudio and JACK.
#   Installed with pipewire-alsa (ALSA compat), pipewire-pulse (PulseAudio compat),
#   pipewire-jack (JACK compat), and wireplumber (session/policy manager).
#   NOTE: pipewire-jack conflicts with jack2 — the chroot script handles the swap.
#
# Firewall: two options with the same security posture (drop all incoming):
#   nftables — Linux kernel's native packet filter, zero extra deps, configured
#              with a single flush+ruleset file. Preferred for servers and power users.
#   ufw      — "Uncomplicated Firewall", a friendly frontend over iptables/nftables.
#              Better for users who want to open ports with simple commands later.
#
# AUR helper: paru-bin is the default because it avoids compiling the Rust toolchain
#   (10–15 min on slow machines). paru (source) and yay (Go, faster compile) are
#   also available. All three are functionally equivalent for daily use.
choose_extras() {
    section "Optional Extras"
    blank

    echo -e "${BOLD}  System & Mirrors${NC}"
    if confirm "  Enable reflector (auto-optimize pacman mirrors on boot)?" "y"; then
        USE_REFLECTOR=true
        blank
        info "  Reflector options (press Enter to keep defaults):"
        info "  Country list examples: France  France,Germany  United States  worldwide"
        REFLECTOR_COUNTRIES=$(get_input "    Countries (comma-separated)" "France,Germany")
        REFLECTOR_NUMBER=$(get_input "    Number of mirrors to keep" "10")
        REFLECTOR_AGE=$(get_input "    Max mirror age in hours" "12")
        echo -e "  ${DIM}Protocol will be https only (most secure & reliable)${NC}"
        ok "  Reflector → ${REFLECTOR_NUMBER} mirrors | Countries: ${REFLECTOR_COUNTRIES} | Age ≤${REFLECTOR_AGE}h"
    fi
    confirm "  Enable multilib repo (32-bit support, Steam, Wine, Proton)?" "y" && USE_MULTILIB=true

    blank
    echo -e "${BOLD}  Audio${NC}"
    confirm "  Install PipeWire (modern audio — replaces PulseAudio)?" "y" && USE_PIPEWIRE=true

    blank
    echo -e "${BOLD}  GPU Drivers${NC}"
    if [[ "$GPU_VENDOR" == "nvidia" ]]; then
        confirm "  Install NVIDIA proprietary drivers (auto-detected NVIDIA GPU)?" "y" && USE_NVIDIA=true
    elif [[ "$GPU_VENDOR" == "amd" ]]; then
        info "  AMD GPU detected — mesa (open-source) is always included."
        info "  Vulkan support adds: vulkan-radeon, libva-mesa-driver (hardware video decode)"
        [[ "$USE_MULTILIB" == true ]] && info "  + lib32-mesa, lib32-vulkan-radeon (32-bit / Steam / Wine)"
        if confirm "  Install AMD Vulkan + video acceleration packages?" "y"; then
            USE_AMD_VULKAN=true
        fi
    elif [[ "$GPU_VENDOR" == "intel" ]]; then
        info "  Intel GPU detected — mesa + intel_backlight drivers included in kernel."
        info "  For Vulkan: vulkan-intel is available but not installed by default."
    else
        info "  GPU not identified — open-source drivers (mesa) included in base."
    fi

    blank
    echo -e "${BOLD}  Peripherals${NC}"
    confirm "  Install Bluetooth support (bluez + bluez-utils)?" "y" && USE_BLUETOOTH=true
    confirm "  Install CUPS printing support?" "n" && USE_CUPS=true

    blank
    echo -e "${BOLD}  btrfs Snapshots${NC}"
    if [[ "$ROOT_FS" == "btrfs" ]]; then
        confirm "  Setup Snapper for automatic btrfs snapshots?" "y" && USE_SNAPPER=true
    else
        info "  Snapper requires btrfs — skipped (root is ${ROOT_FS})."
        USE_SNAPPER=false
    fi

    blank
    echo -e "${BOLD}  Firewall${NC}"
    echo -e "  ${BOLD}1)${NC} nftables   ${DIM}Linux-native, minimal stateful ruleset — recommended${NC}"
    echo -e "  ${BOLD}2)${NC} ufw        ${DIM}Uncomplicated Firewall — simpler CLI, more user-friendly${NC}"
    echo -e "  ${BOLD}3)${NC} None       ${DIM}No firewall (not recommended on untrusted networks)${NC}"
    ask "  Choose firewall [1-3] (default: 1):"
    read -r fw_choice
    case "${fw_choice:-1}" in
        2) FIREWALL="ufw" ;;
        3) FIREWALL="none" ;;
        *) FIREWALL="nftables" ;;
    esac
    ok "Firewall: ${BOLD}$FIREWALL${NC}"

    blank
    echo -e "${BOLD}  AUR Helper${NC}"
    echo -e "  ${BOLD}1)${NC} yay        ${DIM}Go-based, most popular, fast compile${NC}"
    echo -e "  ${BOLD}2)${NC} paru       ${DIM}Rust-based, PKGBUILD diffs — compiled from source (slow on VM)${NC}"
    echo -e "  ${BOLD}3)${NC} paru-bin   ${DIM}Rust-based, PKGBUILD diffs — pre-built binary, installs in seconds${NC}"
    echo -e "  ${BOLD}4)${NC} None"
    ask "  Choose AUR helper [1-4] (default: 3):"
    read -r aur_choice
    case "${aur_choice:-3}" in
        1) AUR_HELPER="yay" ;;
        2) AUR_HELPER="paru" ;;
        4) AUR_HELPER="none" ;;
        *) AUR_HELPER="paru-bin" ;;
    esac
    ok "AUR helper: ${BOLD}$AUR_HELPER${NC}"
}

# =============================================================================
#  SECTION 11b — CONFIG EXPORT / IMPORT
# =============================================================================

# ── save_config ───────────────────────────────────────────────────────────────
# Writes all user choices to a bash-sourceable file.
# The file can be passed back with --load-config to skip Phase 1 questions
# on a fresh installation (reinstall, second machine, disaster recovery).
#
# SECURITY NOTE: the config file contains passwords in plaintext.
# It is saved to /tmp by default — it disappears on reboot.
# The user can specify a different path (USB stick, etc.).
#
# The file format is pure bash: `variable="value"` — can be sourced directly
# or read as-is for human review.
save_config() {
    local default_path="/tmp/archwizard_config_$(date +%Y%m%d_%H%M%S).sh"
    blank
    section "Save Configuration"
    info "Your choices can be saved to a file so you can:"
    info "  • Reinstall Arch with identical settings in seconds"
    info "  • Replicate this setup on another machine"
    info "  • Review and audit all choices before confirming"
    blank
    warn "The file will contain passwords in plaintext — keep it secure!"
    blank
    if ! confirm "Save configuration to file?" "y"; then
        return 0
    fi

    local cfg_path
    cfg_path=$(get_input "Save to" "$default_path")

    cat > "$cfg_path" << CFGEOF
#!/usr/bin/env bash
# ArchWizard saved configuration — $(date '+%Y-%m-%d %H:%M:%S')
# Usage: bash archwizard.sh --load-config $(basename "$cfg_path")
# WARNING: contains passwords in plaintext — store securely!

# ── Hardware ─────────────────────────────────────────────────────────────────
CPU_VENDOR="${CPU_VENDOR}"
GPU_VENDOR="${GPU_VENDOR}"

# ── Disks & Partitions ───────────────────────────────────────────────────────
DISK_ROOT="${DISK_ROOT}"
DISK_HOME="${DISK_HOME}"
ROOT_FS="${ROOT_FS}"
HOME_FS="${HOME_FS}"
EFI_PART="${EFI_PART}"
EFI_SIZE_MB="${EFI_SIZE_MB}"
ROOT_SIZE="${ROOT_SIZE}"
SEP_HOME="${SEP_HOME}"
HOME_SIZE="${HOME_SIZE}"
SWAP_TYPE="${SWAP_TYPE}"
SWAP_SIZE="${SWAP_SIZE}"
DUAL_BOOT="${DUAL_BOOT}"
REUSE_EFI="${REUSE_EFI}"
USE_LUKS="${USE_LUKS}"

# ── System identity ──────────────────────────────────────────────────────────
HOSTNAME="${HOSTNAME}"
GRUB_ENTRY_NAME="${GRUB_ENTRY_NAME}"
USERNAME="${USERNAME}"
USER_PASSWORD="${USER_PASSWORD}"
ROOT_PASSWORD="${ROOT_PASSWORD}"
TIMEZONE="${TIMEZONE}"
LOCALE="${LOCALE}"
KEYMAP="${KEYMAP}"

# ── Software ─────────────────────────────────────────────────────────────────
KERNEL="${KERNEL}"
BOOTLOADER="${BOOTLOADER}"
SECURE_BOOT="${SECURE_BOOT}"
DESKTOPS=(${DESKTOPS[@]+"${DESKTOPS[@]}"})
AUR_HELPER="${AUR_HELPER}"
USE_REFLECTOR="${USE_REFLECTOR}"
REFLECTOR_COUNTRIES="${REFLECTOR_COUNTRIES}"
REFLECTOR_NUMBER="${REFLECTOR_NUMBER}"
REFLECTOR_AGE="${REFLECTOR_AGE}"
USE_MULTILIB="${USE_MULTILIB}"
USE_PIPEWIRE="${USE_PIPEWIRE}"
USE_NVIDIA="${USE_NVIDIA}"
USE_AMD_VULKAN="${USE_AMD_VULKAN}"
USE_BLUETOOTH="${USE_BLUETOOTH}"
USE_CUPS="${USE_CUPS}"
USE_SNAPPER="${USE_SNAPPER}"
FIREWALL="${FIREWALL}"
CFGEOF

    chmod 600 "$cfg_path"
    ok "Config saved → ${BOLD}${cfg_path}${NC}"
    warn "This file contains passwords — delete or encrypt it when done."
    blank
}

# ── load_config ───────────────────────────────────────────────────────────────
# Sources a previously saved config file and skips Phase 1 questions.
# After loading, shows the summary for review before proceeding.
load_config() {
    local cfg="$1"
    if [[ ! -f "$cfg" ]]; then
        error "Config file not found: ${cfg}"
        exit 1
    fi
    info "Loading config from: ${BOLD}${cfg}${NC}"
    # shellcheck source=/dev/null
    source "$cfg"
    ok "Config loaded — Phase 1 questions will be skipped."
    ok "Review the summary on the next screen before confirming."
    blank
}


# =============================================================================
#  SECTION 12 — SUMMARY & FINAL CONFIRMATION
# =============================================================================

show_summary() {
    section "Installation Summary"
    blank
    echo -e "  ┌─────────────────────────────────────────────────────────────┐"
    echo -e "  │  ${BOLD}DISKS & PARTITIONS${NC}"
    echo -e "  │   Root disk     : ${CYAN}$DISK_ROOT${NC}"
    [[ "$SEP_HOME" == true ]] && \
    echo -e "  │   Home disk     : ${CYAN}$DISK_HOME${NC}"
    [[ "$REUSE_EFI" == true ]] && \
    echo -e "  │   EFI           : ${CYAN}${EFI_PART}${NC} (reused from Windows)"
    echo -e "  │   Root size     : ${CYAN}${ROOT_SIZE} GB${NC}  [${ROOT_FS}]"
    [[ "$SEP_HOME" == true ]] && \
    echo -e "  │   Home size     : ${CYAN}${HOME_SIZE} GB${NC}  [${HOME_FS}]"
    echo -e "  │   Swap          : ${CYAN}${SWAP_TYPE}${SWAP_SIZE:+ (${SWAP_SIZE}GB)}${NC}"
    echo -e "  │   LUKS encrypt  : ${CYAN}${USE_LUKS}${NC}"
    echo -e "  │   Multi-boot    : ${CYAN}${DUAL_BOOT}${NC}"
    if [[ ${#REPLACE_PARTS_ALL[@]} -gt 0 ]]; then
        local _rlist _rtotal=0
        _rlist=$(printf '%s ' "${REPLACE_PARTS_ALL[@]}")
        for _rp in "${REPLACE_PARTS_ALL[@]}"; do
            local _rg; _rg=$(( $(blockdev --getsize64 "$_rp" 2>/dev/null||echo 0)/1073741824 ))
            _rtotal=$(( _rtotal + _rg ))
        done
        echo -e "  │   Space plan    : ${RED}DELETE ${_rlist}(${_rtotal} GB total — ALL DATA LOST)${NC}"
    elif [[ -n "$REPLACE_PART" ]]; then
        local _rep_gb
        _rep_gb=$(( $(blockdev --getsize64 "$REPLACE_PART" 2>/dev/null || echo 0) / 1073741824 ))
        echo -e "  │   Space plan    : ${RED}DELETE ${REPLACE_PART} (${_rep_gb} GB — ALL DATA LOST)${NC}"
    elif [[ -n "$RESIZE_PART" ]]; then
        echo -e "  │   Space plan    : ${CYAN}SHRINK ${RESIZE_PART} → ${RESIZE_NEW_GB} GB${NC}"
    fi
    if [[ ${#EXISTING_SYSTEMS[@]} -gt 0 ]]; then
        local sys_str
        sys_str=$(IFS=', '; echo "${EXISTING_SYSTEMS[*]}")
        echo -e "  │   Other OSes    : ${CYAN}${sys_str}${NC}"
    fi
    echo -e "  ├─────────────────────────────────────────────────────────────┤"
    echo -e "  │  ${BOLD}SYSTEM${NC}"
    echo -e "  │   Hostname      : ${CYAN}${HOSTNAME}${NC}"
    echo -e "  │   GRUB name     : ${CYAN}${GRUB_ENTRY_NAME}${NC}"
    echo -e "  │   Timezone      : ${CYAN}${TIMEZONE}${NC}"
    echo -e "  │   Locale        : ${CYAN}${LOCALE}${NC}"
    echo -e "  │   Keymap        : ${CYAN}${KEYMAP}${NC}"
    echo -e "  │   Username      : ${CYAN}${USERNAME}${NC}  (wheel/sudo)"
    echo -e "  ├─────────────────────────────────────────────────────────────┤"
    echo -e "  │  ${BOLD}SOFTWARE${NC}"
    echo -e "  │   Kernel        : ${CYAN}${KERNEL}${NC}"
    echo -e "  │   Bootloader    : ${CYAN}${BOOTLOADER}${NC}"
    echo -e "  │   Secure Boot   : ${CYAN}${SECURE_BOOT}${NC}"
    echo -e "  │   Desktop       : ${CYAN}${DESKTOPS[*]}${NC}"
    echo -e "  │   AUR helper    : ${CYAN}${AUR_HELPER}${NC}"
    echo -e "  │   PipeWire      : ${CYAN}${USE_PIPEWIRE}${NC}"
    echo -e "  │   Multilib      : ${CYAN}${USE_MULTILIB}${NC}"
    echo -e "  │   NVIDIA        : ${CYAN}${USE_NVIDIA}${NC}"
    [[ "$GPU_VENDOR" == "amd" ]] && \
    echo -e "  │   AMD Vulkan    : ${CYAN}${USE_AMD_VULKAN}${NC}"
    echo -e "  │   Bluetooth     : ${CYAN}${USE_BLUETOOTH}${NC}"
    echo -e "  │   CUPS          : ${CYAN}${USE_CUPS}${NC}"
    echo -e "  │   Snapper       : ${CYAN}${USE_SNAPPER}${NC}"
    echo -e "  │   Reflector     : ${CYAN}${USE_REFLECTOR}${NC}"
    echo -e "  │   Firewall      : ${CYAN}${FIREWALL}${NC}"
    echo -e "  └─────────────────────────────────────────────────────────────┘"
    blank
    warn "After this confirmation, your disk(s) will be modified!"
    blank
    if ! confirm "${RED}${BOLD}Begin installation?${NC}" "n"; then
        info "Aborted. No changes were made."
        exit 0
    fi
}


# =============================================================================
#  SECTION 13 — RESIZE EXISTING PARTITIONS  (multi-boot only)
# =============================================================================

# ── resize_partitions ─────────────────────────────────────────────────────────
# In multi-boot mode, the target disk may have no unallocated space.
# This function lets the user shrink an existing partition to make room.
#
# Supported filesystems:
#   ntfs    → ntfsresize (shrinks the NTFS data, then parted resizes the partition)
#   ext4    → e2fsck + resize2fs (must fsck first, then resize)
#   btrfs   → btrfs filesystem resize (online-capable, but we do it offline here)
#   xfs     → xfs can only grow, NOT shrink → warn and skip
#   fat32   → parted resizepart only (no fs-aware tool needed for empty space)
#
# SAFETY RULES enforced:
#   • We NEVER shrink a partition below its minimum safe size (filesystem usage + 20%)
#   • We refuse to shrink if the filesystem check fails
#   • We always run filesystem check before AND after resize
#   • The user must type the new size explicitly — no accidental Enter-to-confirm
#
# Tools required: parted, ntfsresize (ntfs-3g), e2fsck + resize2fs (e2fsprogs),
#                 btrfs-progs.  All present on the Arch ISO.

# ── replace_partition ─────────────────────────────────────────────────────────
# Deletes all partitions in REPLACE_PARTS_ALL (set by _check_and_plan_space
# when the user had already said they don't want to keep certain partitions).
# Falls back to the single REPLACE_PART for the manual-selection case.
# Processes partitions in REVERSE number order so deleting one doesn't shift
# the GPT numbers of the others.
replace_partition() {
    if [[ "$DUAL_BOOT" == false ]]; then return 0; fi

    # Build the definitive list
    local _to_delete=()
    if [[ ${#REPLACE_PARTS_ALL[@]} -gt 0 ]]; then
        _to_delete=("${REPLACE_PARTS_ALL[@]}")
    elif [[ -n "$REPLACE_PART" ]]; then
        _to_delete=("$REPLACE_PART")
    else
        return 0   # nothing to delete
    fi

    section "Delete Partitions (freeing space for Arch Linux)"

    # Sort by partition number descending — delete highest numbers first
    # so lower-numbered GPT entries are not renumbered during the loop.
    local _sorted=()
    while IFS= read -r line; do
        _sorted+=("$line")
    done < <(printf '%s\n' "${_to_delete[@]}" \
             | awk '{match($0,/[0-9]+$/); print substr($0,RSTART)+0, $0}' \
             | sort -rn | awk '{print $2}')

    # ── Step 1: all sgdisk -d calls first, no partprobe between them ─────
    # Calling partprobe after each individual deletion can fail with
    # "unable to inform the kernel" because udev is still processing the
    # previous change. Batch all deletions first, then update the kernel
    # partition table once at the end.
    local _total_freed=0
    for p in "${_sorted[@]}"; do
        [[ -z "$p" ]] && continue
        local _gb _num
        _gb=$(( $(blockdev --getsize64 "$p" 2>/dev/null || echo 0) / 1073741824 ))
        _num=$(echo "$p" | grep -oE '[0-9]+$')
        info "Deleting ${BOLD}${p}${NC} (${_gb} GB) — ALL DATA LOST"
        run "sgdisk -d ${_num} ${DISK_ROOT}"
        _total_freed=$(( _total_freed + _gb ))
        ok "${p} removed from GPT"
    done

    # ── Step 2: single kernel table update with retry ────────────────────
    # Call the global _refresh_partitions helper (defined after run()).
    # NOT via run() — shell functions cannot be called through eval in a
    # subshell context the way run() works.
    _refresh_partitions "${DISK_ROOT}"

    blank
    info "Updated layout of ${DISK_ROOT}:"
    parted -s "$DISK_ROOT" unit GiB print free 2>/dev/null || true
    blank
    ok "Total freed: ${BOLD}${_total_freed} GB${NC} now unallocated."
    blank
}

# ── resize_partitions ─────────────────────────────────────────────────────────
# Phase 3 execution of the resize plan collected during Phase 1.
# The plan was built by _check_and_plan_space() and stored in:
#   RESIZE_PART    — partition device to shrink (empty = nothing to do)
#   RESIZE_NEW_GB  — target size in GB
# If no plan was set, this function is a no-op.
resize_partitions() {
    if [[  "$DUAL_BOOT" == false  ]]; then return 0; fi
    if [[ -z "$RESIZE_PART" ]]; then return 0; fi   # no resize planned

    section "Resize Partition: ${RESIZE_PART} → ${RESIZE_NEW_GB} GB"

    local target_part="$RESIZE_PART"
    local new_gb="$RESIZE_NEW_GB"
    local target_fs
    target_fs=$(blkid -s TYPE -o value "$target_part" 2>/dev/null || echo "unknown")

    local cur_gb
    cur_gb=$(( $(blockdev --getsize64 "$target_part" 2>/dev/null || echo 0) / 1073741824 ))
    local freed=$(( cur_gb - new_gb ))
    local new_bytes=$(( new_gb * 1073741824 ))
    local new_mb=$(( new_gb * 1024 ))

    # No confirmation here — the resize plan was reviewed in Phase 1
    # (_check_and_plan_space) and the full installation summary was confirmed
    # in Phase 2 (show_summary). A third "are you sure?" would be confusing.
    info "Executing resize plan: ${BOLD}${target_part}${NC} ${cur_gb} GB → ${new_gb} GB (freeing ${freed} GB)"
    blank

    # ── Filesystem resize ─────────────────────────────────────────────────
    case "$target_fs" in
        ntfs)
            info "Shrinking NTFS filesystem…"
            run "ntfsresize --no-action --size ${new_mb}M $target_part"  # dry-run
            run "ntfsresize --force --size ${new_mb}M $target_part"
            ok "NTFS filesystem shrunk to ${new_gb} GB"
            ;;
        ext4)
            info "Shrinking ext4 filesystem…"
            run "e2fsck -fy $target_part"
            run "resize2fs $target_part ${new_mb}M"
            ok "ext4 filesystem shrunk to ~${new_gb} GB"
            ;;
        btrfs)
            info "Shrinking btrfs filesystem…"
            local _btmp="/tmp/archwizard_btrfs_resize"
            mkdir -p "$_btmp"
            run "mount -o rw $target_part $_btmp"
            run "btrfs filesystem resize ${new_mb}M $_btmp"
            run "umount $_btmp"
            rmdir "$_btmp" 2>/dev/null || true
            ok "btrfs filesystem shrunk to ~${new_gb} GB"
            ;;
        *)
            error "Unsupported filesystem '${target_fs}' for resize."
            return 1 ;;
    esac

    # ── GPT partition entry update ────────────────────────────────────────
    local part_num
    part_num=$(echo "$target_part" | grep -oE '[0-9]+$')
    local start_bytes
    start_bytes=$(parted -s "$DISK_ROOT" unit B print 2>/dev/null                   | awk "/^ *${part_num} /{print \$2}" | tr -d 'B')
    local new_end=$(( ${start_bytes:-0} + new_bytes ))
    # parted's "Shrinking a partition can cause data loss" warning is
    # interactive even with -s. run_interactive() restores /dev/tty so
    # the user sees the prompt and can type their answer directly.
    info "parted will ask you to confirm the resize — type 'Yes' and press Enter."
    run_interactive "parted $DISK_ROOT resizepart $part_num ${new_end}B"
    ok "GPT partition entry updated"

    _refresh_partitions "$DISK_ROOT"

    blank
    info "Updated layout:"
    parted -s "$DISK_ROOT" unit GiB print free 2>/dev/null || true
    blank
    ok "Done — ${BOLD}~${freed} GB${NC} of unallocated space now available."
    blank
}

# =============================================================================
#  SECTION 13 — CREATE PARTITIONS
# =============================================================================

# ── create_partitions ─────────────────────────────────────────────────────────
# Creates the partition layout using sgdisk (GPT only — no MBR support).
#
# GPT partition type codes used:
#   ef00 — EFI System Partition (FAT32, read by UEFI firmware)
#   8200 — Linux swap
#   8300 — Linux filesystem (generic, used for root)
#   8302 — Linux /home
#
# sgdisk -n syntax:  -n PARTNUM:START:END
#   PARTNUM 0 means "next available number"
#   START   0 means "first available sector after previous partition"
#   END     0 means "last available sector" (uses all remaining space)
#   END   +XG means "START + X gibibytes"
#
# TWO PATHS:
#   Dual-boot + reuse EFI: we only ADD new partitions in unallocated space.
#     sgdisk --zap-all is NOT called — that would destroy Windows.
#     The EFI_PART variable already holds the Windows ESP from discover_disks().
#
#   Fresh install: we wipe the entire disk (sgdisk --zap-all) and build a new
#     GPT from scratch. The partition order is: EFI → [swap] → root → [home].
#
# After creating partitions, `partprobe` tells the kernel to re-read the partition
# table. `sleep 2` gives udev time to create the new /dev/sdXN device nodes.
create_partitions() {
    section "Partitioning Disks"
    blank

    local part_num=1

    if [[ "$DUAL_BOOT" == true ]]; then
        # ── Multi-boot: only ADD new partitions — never wipe existing ones ──
        # This branch runs whenever DUAL_BOOT=true, regardless of REUSE_EFI.
        # The old condition was "DUAL_BOOT && REUSE_EFI" which fell through to
        # sgdisk --zap-all when REUSE_EFI=false — wiping the entire disk.
        info "Multi-boot mode — adding partitions to existing layout"

        if [[ "$SWAP_TYPE" == "partition" ]]; then
            run "sgdisk -n 0:0:+${SWAP_SIZE}G -t 0:8200 -c 0:arch_swap $DISK_ROOT"
            SWAP_PART=$(part_name "$DISK_ROOT" "$(sgdisk -p "$DISK_ROOT" 2>/dev/null | tail -1 | awk '{print $1}')")
            info "Swap partition: $SWAP_PART"
        fi

        if [[ "$SEP_HOME" == true && "$DISK_HOME" == "$DISK_ROOT" ]]; then
            # Root (sized)
            if [[ "$ROOT_SIZE" == "rest" ]]; then
                run "sgdisk -n 0:0:0 -t 0:8300 -c 0:arch_root $DISK_ROOT"
            else
                run "sgdisk -n 0:0:+${ROOT_SIZE}G -t 0:8300 -c 0:arch_root $DISK_ROOT"
            fi
            ROOT_PART=$(part_name "$DISK_ROOT" "$(sgdisk -p "$DISK_ROOT" 2>/dev/null | tail -1 | awk '{print $1}')")

            # Home (rest)
            if [[ "$HOME_SIZE" == "rest" ]]; then
                run "sgdisk -n 0:0:0 -t 0:8302 -c 0:arch_home $DISK_ROOT"
            else
                run "sgdisk -n 0:0:+${HOME_SIZE}G -t 0:8302 -c 0:arch_home $DISK_ROOT"
            fi
            HOME_PART=$(part_name "$DISK_ROOT" "$(sgdisk -p "$DISK_ROOT" 2>/dev/null | tail -1 | awk '{print $1}')")
        else
            # Root takes remaining space
            if [[ "$ROOT_SIZE" == "rest" ]]; then
                run "sgdisk -n 0:0:0 -t 0:8300 -c 0:arch_root $DISK_ROOT"
            else
                run "sgdisk -n 0:0:+${ROOT_SIZE}G -t 0:8300 -c 0:arch_root $DISK_ROOT"
            fi
            ROOT_PART=$(part_name "$DISK_ROOT" "$(sgdisk -p "$DISK_ROOT" 2>/dev/null | tail -1 | awk '{print $1}')")
        fi

    elif [[ "$FIRMWARE_MODE" == "bios" ]]; then
        # ── BIOS/Legacy fresh install — MBR partition table ─────────────────
        # GRUB in BIOS mode embeds its core image in the "BIOS Boot Partition"
        # (type ef02, 1 MiB) at the start of the disk. This partition is NOT
        # mounted — it is only used by GRUB at install time to store the boot code.
        # No EFI partition is created or needed.
        warn "Wiping $DISK_ROOT and creating new MBR partition table (BIOS mode)…"
        run "parted -s $DISK_ROOT mklabel msdos"

        # 1 — BIOS boot partition (1 MiB, unformatted, for GRUB core)
        run "parted -s $DISK_ROOT mkpart primary 1MiB 2MiB"
        run "parted -s $DISK_ROOT set 1 bios_grub on"
        BIOS_BOOT_PART=$(part_name "$DISK_ROOT" "1")
        part_num=2

        # 2 — Swap (optional)
        if [[ "$SWAP_TYPE" == "partition" ]]; then
            local _swap_end=$(( 2 + SWAP_SIZE * 1024 ))
            run "parted -s $DISK_ROOT mkpart primary linux-swap 2MiB ${_swap_end}MiB"
            SWAP_PART=$(part_name "$DISK_ROOT" "$part_num")
            part_num=$(( part_num + 1 ))
            local _next_start="${_swap_end}MiB"
        else
            local _next_start="2MiB"
        fi

        # 3 — Root (and optional home)
        if [[ "$ROOT_SIZE" == "rest" ]]; then
            run "parted -s $DISK_ROOT mkpart primary 100% 100%"
            ROOT_PART=$(part_name "$DISK_ROOT" "$part_num")
        else
            local _root_end
            _root_end=$(( (${_next_start//MiB/} + ROOT_SIZE * 1024) ))
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

        # Set boot flag on root partition (MBR bootable)
        run "parted -s $DISK_ROOT set $(echo "$ROOT_PART" | grep -oE '[0-9]+$') boot on"

    else
        # ── UEFI fresh install: wipe and build GPT from scratch ─────────────
        warn "Wiping $DISK_ROOT and creating new GPT partition table..."
        run "sgdisk --zap-all $DISK_ROOT"
        run "sgdisk -o $DISK_ROOT"

        # 1 — EFI
        run "sgdisk -n 1:0:+${EFI_SIZE_MB}M -t 1:ef00 -c 1:EFI $DISK_ROOT"
        EFI_PART=$(part_name "$DISK_ROOT" "1")
        part_num=2

        # 2 — Swap partition (before root)
        if [[ "$SWAP_TYPE" == "partition" ]]; then
            run "sgdisk -n ${part_num}:0:+${SWAP_SIZE}G -t ${part_num}:8200 -c ${part_num}:swap $DISK_ROOT"
            SWAP_PART=$(part_name "$DISK_ROOT" "$part_num")
            part_num=$(( part_num + 1 ))
        fi

        # 3 — Root
        # Always respect ROOT_SIZE when set to a specific value.
        # The old code only used ROOT_SIZE when SEP_HOME=true, causing root
        # to take the entire disk when SEP_HOME=false — even if the user
        # had entered "15" as the root size.
        if [[ "$ROOT_SIZE" == "rest" ]]; then
            # User wants root to take all remaining space
            run "sgdisk -n ${part_num}:0:0 -t ${part_num}:8300 -c ${part_num}:root $DISK_ROOT"
            ROOT_PART=$(part_name "$DISK_ROOT" "$part_num")
        else
            # User specified an exact size — always honour it
            run "sgdisk -n ${part_num}:0:+${ROOT_SIZE}G -t ${part_num}:8300 -c ${part_num}:root $DISK_ROOT"
            ROOT_PART=$(part_name "$DISK_ROOT" "$part_num")
            part_num=$(( part_num + 1 ))

            # 4 — Home on same disk (only if SEP_HOME requested)
            if [[ "$SEP_HOME" == true && "$DISK_HOME" == "$DISK_ROOT" ]]; then
                if [[ "$HOME_SIZE" == "rest" ]]; then
                    run "sgdisk -n ${part_num}:0:0 -t ${part_num}:8302 -c ${part_num}:home $DISK_ROOT"
                else
                    run "sgdisk -n ${part_num}:0:+${HOME_SIZE}G -t ${part_num}:8302 -c ${part_num}:home $DISK_ROOT"
                fi
                HOME_PART=$(part_name "$DISK_ROOT" "$part_num")
            fi
            # If SEP_HOME=false: remaining space stays unallocated (available
            # for future installations, LVM, or manual partitioning later)
        fi
    fi

    # Home on separate disk
    if [[ "$SEP_HOME" == true && "$DISK_HOME" != "$DISK_ROOT" ]]; then
        warn "Wiping $DISK_HOME for /home..."
        run "sgdisk --zap-all $DISK_HOME"
        run "sgdisk -o $DISK_HOME"
        if [[ "$HOME_SIZE" == "rest" ]]; then
            run "sgdisk -n 1:0:0 -t 1:8302 -c 1:home $DISK_HOME"
        else
            run "sgdisk -n 1:0:+${HOME_SIZE}G -t 1:8302 -c 1:home $DISK_HOME"
        fi
        HOME_PART=$(part_name "$DISK_HOME" "1")
    fi

    # Refresh partition tables — retry helper always available (global function)
    _refresh_partitions "$DISK_ROOT"
    [[ "$DISK_HOME" != "$DISK_ROOT" ]] && _refresh_partitions "$DISK_HOME"

    ok "Partitions created"
    blank
    lsblk "$DISK_ROOT" 2>/dev/null || true
    [[ "$DISK_HOME" != "$DISK_ROOT" ]] && lsblk "$DISK_HOME" 2>/dev/null || true
}

# =============================================================================
#  SECTION 14 — LUKS ENCRYPTION
# =============================================================================

# ── setup_luks ────────────────────────────────────────────────────────────────
# Sets up LUKS2 full-disk encryption on the root (and optionally home) partition.
#
# Cipher choices explained:
#   aes-xts-plain64  — AES in XTS mode, the standard for disk encryption.
#                      XTS (XEX-based Tweaked CodeBook mode with ciphertext Stealing)
#                      is designed specifically for block devices.
#   --key-size 512   — 512-bit key for AES-XTS = two 256-bit AES keys (XTS uses two).
#                      This gives AES-256 effective security.
#   --hash sha512    — used to derive the master key from the passphrase via PBKDF2.
#
# --allow-discards --persistent:
#   Enables TRIM (discard) support for the encrypted device. Without this, the SSD
#   cannot reclaim blocks erased by the filesystem, which hurts long-term performance.
#   --persistent writes this flag into the LUKS2 header so every future `cryptsetup open`
#   activates discards automatically — no need for kernel cmdline parameters.
#   Trade-off: discard reveals which blocks are free (minor information leak).
#              Acceptable for most desktop users; disable for high-security contexts.
#
# The password is piped via stdin (`echo -n ... | cryptsetup ... -`) rather than
# passed as an argument to avoid it appearing in `ps` output or shell history.
setup_luks() {
    if [[ "$USE_LUKS" == false ]]; then return 0; fi
    section "LUKS2 Encryption"

    info "Encrypting $ROOT_PART …"
    echo -n "$LUKS_PASSWORD" | run "cryptsetup luksFormat --type luks2 \
        --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
        --batch-mode $ROOT_PART -"
    # --allow-discards --persistent writes TRIM support into the LUKS2 header
    # so it is active on every subsequent open without extra kernel params
    echo -n "$LUKS_PASSWORD" | run "cryptsetup open --allow-discards --persistent $ROOT_PART cryptroot -"
    ROOT_PART_MAPPED="/dev/mapper/cryptroot"
    ok "LUKS container opened → $ROOT_PART_MAPPED"

    if [[ "$SEP_HOME" == true && -n "$HOME_PART" ]]; then
        blank
        if confirm "Also encrypt /home with the same passphrase?" "y"; then
            echo -n "$LUKS_PASSWORD" | run "cryptsetup luksFormat --type luks2 \
                --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
                --batch-mode $HOME_PART -"
            echo -n "$LUKS_PASSWORD" | run "cryptsetup open --allow-discards --persistent $HOME_PART crypthome -"
            HOME_PART="/dev/mapper/crypthome"
            ok "/home encrypted → $HOME_PART"
        fi
    fi
}

# =============================================================================
#  SECTION 15 — FORMAT FILESYSTEMS
# =============================================================================

format_filesystems() {
    section "Formatting Filesystems"

    local root_dev="${ROOT_PART_MAPPED:-$ROOT_PART}"

    if [[ "$FIRMWARE_MODE" == "bios" ]]; then
        # BIOS mode: no EFI partition to format.
        # The BIOS boot partition (bios_grub flag) is not a filesystem —
        # GRUB writes its core image there directly (done by grub-install).
        ok "BIOS mode — no EFI partition to format"
    elif [[ "$DUAL_BOOT" == true ]]; then
        ok "Multi-boot: reusing existing EFI partition: $EFI_PART (not reformatted)"
    elif [[ "$REUSE_EFI" == false ]]; then
        run "mkfs.fat -F32 -n EFI $EFI_PART"
        ok "EFI formatted → FAT32 ($EFI_PART)"
    else
        ok "Reusing existing EFI partition: $EFI_PART"
    fi

    # Format root partition with chosen filesystem
    case "$ROOT_FS" in
        btrfs) run "mkfs.btrfs -f -L arch_root $root_dev"      ;;
        ext4)  run "mkfs.ext4  -F -L arch_root $root_dev"      ;;
        xfs)   run "mkfs.xfs   -f -L arch_root $root_dev"      ;;
        f2fs)  run "mkfs.f2fs  -f -l arch_root $root_dev"      ;;
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
#  SECTION 16 — btrfs SUBVOLUMES
# =============================================================================

# ── create_subvolumes ─────────────────────────────────────────────────────────
# Creates btrfs subvolumes. Each subvolume is a separately-mountable namespace
# within the btrfs filesystem — they look like directories but behave like
# independent mini-filesystems for snapshot purposes.
#
# Why these subvolumes?
#   @            — root filesystem (/). The top-level subvolume that gets snapshotted.
#   @home        — /home. Kept separate so user data snapshots are independent of /.
#   @snapshots   — /.snapshots. Where snapper stores all snapshot trees.
#                  Must be a subvolume (not a plain directory) so it is excluded
#                  from root snapshots (otherwise snapshots would contain snapshots).
#   @var_log     — /var/log. Excluded from root snapshots because log files change
#                  constantly and you generally do NOT want logs to roll back when
#                  you restore a snapshot (you need the logs to diagnose the problem).
#                  CoW is also disabled on this subvolume (chattr +C) to prevent
#                  journald's high write frequency from fragmenting the filesystem.
#   @var_cache   — /var/cache. pacman's package cache lives here. Excluded from root
#                  snapshots because it's large, changes often, and is rebuildable.
#   @tmp         — /tmp. Temporary files. No value in snapshotting or restoring them.
#   @swap        — /swap. Created only when swap type = "file". btrfs swap files MUST
#                  live on a subvolume with CoW disabled (mkswapfile handles this).
#                  A separate subvolume ensures the swapfile is never snapshotted
#                  (snapshotting a live swapfile would corrupt it).
#
# The convention of prefixing subvolume names with @ is a community standard,
# not a btrfs requirement. It makes them easy to identify and avoids collisions
# with top-level directory names.
create_subvolumes() {
    # Only btrfs uses subvolumes — skip entirely for other filesystems
    if [[ "$ROOT_FS" != "btrfs" ]]; then
        info "Filesystem is ${ROOT_FS} — skipping btrfs subvolume creation."
        return 0
    fi

    section "Creating btrfs Subvolumes"

    local root_dev="${ROOT_PART_MAPPED:-$ROOT_PART}"

    run "mount $root_dev /mnt"

    local subvols=("@" "@home" "@snapshots" "@var_log" "@var_cache" "@tmp")
    [[ "$SWAP_TYPE" == "file" ]] && subvols+=("@swap")

    for sv in "${subvols[@]}"; do
        run "btrfs subvolume create /mnt/$sv"
        ok "  subvol: $sv"
    done

    run "umount /mnt"
    ok "Subvolumes created"
}

# =============================================================================
#  SECTION 17 — MOUNT FILESYSTEMS
# =============================================================================

# ── mount_filesystems ─────────────────────────────────────────────────────────
# Mounts all subvolumes and partitions under /mnt so pacstrap and genfstab
# see the final filesystem layout.
#
# btrfs mount options explained:
#   noatime         — do not update file access times on reads. Eliminates a
#                     massive amount of unnecessary write I/O (every `cat` would
#                     otherwise trigger a write to update atime metadata).
#   compress=zstd:1 — transparent compression using zstd at level 1.
#                     Level 1 is nearly as fast as no compression but saves 20–40%
#                     of disk space on typical system files. Higher levels are
#                     slower with diminishing returns.
#   space_cache=v2  — improved free-space cache (v2 is faster and more reliable
#                     than the legacy v1 cache, especially after unclean shutdowns).
#   discard=async   — asynchronous TRIM: the kernel accumulates discarded extents
#                     and sends them to the drive in batches, rather than one TRIM
#                     command per freed block (synchronous discard). This avoids
#                     latency spikes on heavy delete workloads.
#                     Combined with fstrim.timer (weekly full TRIM) and LUKS
#                     --allow-discards, this gives complete SSD TRIM coverage.
#
# chattr +C on /mnt/var/log:
#   Disables Copy-on-Write on the var_log subvolume mount point BEFORE pacstrap
#   writes anything there. CoW on log files causes heavy fragmentation because
#   journald writes many small records — each triggers a new COW extent chain.
#   With +C, writes go directly to the existing blocks (like a conventional
#   filesystem), which is exactly what you want for append-heavy log files.
#   IMPORTANT: chattr +C must be set on an empty directory; it has no effect
#   on files already written. That's why it's done here, before pacstrap.
mount_filesystems() {
    section "Mounting Filesystems"

    local root_dev="${ROOT_PART_MAPPED:-$ROOT_PART}"

    # Mount options per filesystem
    local btrfs_opts="noatime,compress=zstd:1,space_cache=v2,discard=async"
    local ext4_opts="noatime,discard"
    local xfs_opts="noatime,discard,logbufs=8"
    local f2fs_opts="noatime,lazytime,discard"

    # ESP mount point depends on bootloader
    local esp_mount="boot/efi"
    [[ "$BOOTLOADER" == "systemd-boot" ]] && esp_mount="boot"

    # ── Root mount ────────────────────────────────────────────────────────
    if [[ "$ROOT_FS" == "btrfs" ]]; then
        run "mount -o ${btrfs_opts},subvol=@ $root_dev /mnt"
        ok "@ → /mnt  (btrfs)"
        run "mkdir -p /mnt/{${esp_mount},home,var/log,var/cache,tmp,.snapshots}"
        [[ "$SWAP_TYPE" == "file" ]] && run "mkdir -p /mnt/swap"
        run "mount -o ${btrfs_opts},subvol=@snapshots $root_dev /mnt/.snapshots"
        run "mount -o ${btrfs_opts},subvol=@var_log    $root_dev /mnt/var/log"
        run "mount -o ${btrfs_opts},subvol=@var_cache  $root_dev /mnt/var/cache"
        run "mount -o ${btrfs_opts},subvol=@tmp        $root_dev /mnt/tmp"
        run "chattr +C /mnt/var/log"
        ok "@snapshots @var_log @var_cache @tmp → mounted (CoW disabled on var/log)"
    else
        # Non-btrfs: plain mount, create directories, no subvolumes
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
        [[ "$SWAP_TYPE" == "file" ]] && run "mkdir -p /mnt/swap"
    fi

    # ── Home mount ────────────────────────────────────────────────────────
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
        # Non-btrfs: home is part of root, already mounted
    fi

    # ── EFI mount (UEFI only) ────────────────────────────────────────────
    if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
        if [[ -z "$EFI_PART" ]]; then
            error "EFI_PART is not set — cannot mount EFI partition."
            exit 1
        fi
        run "mount $EFI_PART /mnt/${esp_mount}"
        ok "EFI → /mnt/${esp_mount}"
    else
        ok "BIOS mode — no EFI partition to mount"
    fi

    # ── Swap ─────────────────────────────────────────────────────────────
    if [[ "$SWAP_TYPE" == "partition" ]]; then
        run "swapon $SWAP_PART"
        ok "Swap partition active"
    elif [[ "$SWAP_TYPE" == "file" ]]; then
        if [[ "$ROOT_FS" == "btrfs" ]]; then
            run "mount -o ${btrfs_opts},subvol=@swap $root_dev /mnt/swap"
            run "btrfs filesystem mkswapfile --size ${SWAP_SIZE}g /mnt/swap/swapfile"
        else
            # Non-btrfs: plain fallocate swapfile
            run "fallocate -l ${SWAP_SIZE}G /mnt/swap/swapfile"
            run "chmod 600 /mnt/swap/swapfile"
            run "mkswap /mnt/swap/swapfile"
        fi
        run "swapon /mnt/swap/swapfile"
        ok "Swap file active (/swap/swapfile, ${SWAP_SIZE}GB)"
    fi
}

# =============================================================================
#  SECTION 18 — REFLECTOR & PACSTRAP
# =============================================================================

setup_mirrors() {
    if [[ "$USE_REFLECTOR" == false ]]; then return 0; fi
    section "Optimizing Pacman Mirrors"
    info "Countries: ${REFLECTOR_COUNTRIES} | Mirrors: ${REFLECTOR_NUMBER} | Age ≤${REFLECTOR_AGE}h | Protocol: ${REFLECTOR_PROTOCOL}"
    info "This may take a moment…"
    # Build country args (comma-separated → multiple --country flags)
    local country_args=""
    IFS=',' read -ra _countries <<< "$REFLECTOR_COUNTRIES"
    for _c in "${_countries[@]}"; do
        _c="${_c#"${_c%%[![:space:]]*}"}"   # ltrim
        _c="${_c%"${_c##*[![:space:]]}"}"   # rtrim
        [[ -n "$_c" ]] && country_args+="--country "${_c}" "
    done
    run "reflector ${country_args}--protocol ${REFLECTOR_PROTOCOL} --age ${REFLECTOR_AGE} --latest 20 --number ${REFLECTOR_NUMBER} --sort rate --save /etc/pacman.d/mirrorlist"
    ok "Mirrorlist updated"
}

# ── install_base ──────────────────────────────────────────────────────────────
# Installs the base system using pacstrap, then generates /etc/fstab.
#
# Package groups explained:
#   base            — minimal Arch system (bash, coreutils, systemd, pacman, etc.)
#   base-devel      — build tools (gcc, make, binutils…) — needed for AUR helpers
#   linux           — the kernel itself
#   linux-headers   — kernel headers — needed to build DKMS modules (NVIDIA, VirtualBox…)
#   linux-firmware  — firmware blobs for WiFi cards, GPUs, Bluetooth adapters, etc.
#   btrfs-progs     — btrfs userspace tools (btrfs command, fsck.btrfs, etc.)
#   dosfstools      — mkfs.fat for EFI partition formatting / fsck.fat
#   mtools          — FAT filesystem tools (used by some EFI bootloader installers)
#   intel-ucode /
#   amd-ucode       — CPU microcode updates loaded by the bootloader at boot.
#                     Microcode patches silicon bugs in the CPU; critical for
#                     security (Spectre/Meltdown mitigations live here) and stability.
#   networkmanager  — connection manager with D-Bus API. Enabled in services block.
#   pacman-contrib  — extra pacman tools: paccache (cache cleanup), pacdiff
#                     (config file diffing), checkupdates (safe update checking),
#                     rankmirrors. paccache.timer (enabled later) needs this.
#
# genfstab -U:
#   Generates /etc/fstab using UUIDs (-U) rather than device names (/dev/sdaX).
#   UUIDs are stable across disk reorders and USB hot-plug events. The fstab
#   captures all currently mounted filesystems under /mnt — which is why
#   mount_filesystems() must run first and mount everything in its final place.
install_base() {
    section "Installing Base System (pacstrap)"

    local pkgs=""

    # Core system — use the kernel chosen by the user
    pkgs+="base base-devel ${KERNEL} ${KERNEL}-headers linux-firmware"
    pkgs+=" dosfstools mtools"   # dosfstools for EFI, mtools for FAT utilities

    # Filesystem tools — only install what's needed
    local all_fs="${ROOT_FS} ${HOME_FS}"
    echo "$all_fs" | grep -q "btrfs" && pkgs+=" btrfs-progs"
    echo "$all_fs" | grep -q "ext4"  && pkgs+=" e2fsprogs"
    echo "$all_fs" | grep -q "xfs"   && pkgs+=" xfsprogs"
    echo "$all_fs" | grep -q "f2fs"  && pkgs+=" f2fs-tools"

    # Microcode
    [[ "$CPU_VENDOR" == "intel" ]] && pkgs+=" intel-ucode"
    [[ "$CPU_VENDOR" == "amd" ]]   && pkgs+=" amd-ucode"

    # Networking
    pkgs+=" networkmanager network-manager-applet"
    # WiFi backends — iwd is modern and fast; wpa_supplicant is the classic fallback.
    # wireless_tools provides iwconfig/iwlist for diagnostics.
    # Both are used by NetworkManager depending on its backend config.
    pkgs+=" iwd wpa_supplicant wireless_tools"

    # CLI essentials
    pkgs+=" git curl wget rsync"
    pkgs+=" nano vim neovim"
    pkgs+=" sudo bash-completion"
    pkgs+=" htop btop fastfetch"
    pkgs+=" zip unzip tar"
    pkgs+=" man-db man-pages"
    pkgs+=" pacman-contrib"                    # paccache, pacdiff, checkupdates
    # xdg-utils: xdg-open, xdg-mime etc. — needed by many desktop apps to
    #            open files with the right application
    pkgs+=" xdg-utils xdg-user-dirs"
    # smartmontools: S.M.A.R.T. disk health monitoring (smartctl command)
    pkgs+=" smartmontools"
    # openssh: SSH client + server (server disabled by default, client always useful)
    pkgs+=" openssh"

    # Dual-boot helpers
    # os-prober detects Windows AND other Linux distros for GRUB menu generation.
    # ntfs-3g: needed to mount Windows NTFS partitions (for os-prober and user access).
    # fuse2: os-prober uses FUSE internally to probe some filesystems.
    if [[ "$DUAL_BOOT" == true ]]; then
        pkgs+=" os-prober ntfs-3g fuse2"
    fi

    # GPU packages
    if [[ "$USE_AMD_VULKAN" == true ]]; then
        pkgs+=" vulkan-radeon libva-mesa-driver"
        [[ "$USE_MULTILIB" == true ]] && pkgs+=" lib32-mesa lib32-vulkan-radeon"
        info "AMD Vulkan packages will be installed"
    fi

    # Reflector for installed system
    [[ "$USE_REFLECTOR" == true ]] && pkgs+=" reflector"

    # Snapper (install now, configure in chroot)
    [[ "$USE_SNAPPER" == true ]] && pkgs+=" snapper snap-pac grub-btrfs"

    # ── Configure live ISO pacman.conf before pacstrap ──────────────────
    # pacstrap uses the live ISO's /etc/pacman.conf — NOT the installed
    # system's. Without configuration, downloads show no colors, no progress
    # bars, no parallel downloads. We patch the live ISO config first so
    # pacstrap benefits from the same settings we apply in the chroot later.
    info "Configuring live ISO pacman for better download display…"
    sed -i 's/^#Color/Color/'                               /etc/pacman.conf 2>/dev/null || true
    sed -i 's/^#VerbosePkgLists/VerbosePkgLists/'           /etc/pacman.conf 2>/dev/null || true
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf 2>/dev/null || true
    grep -q "ILoveCandy" /etc/pacman.conf 2>/dev/null ||         sed -i '/^Color/a ILoveCandy' /etc/pacman.conf 2>/dev/null || true
    ok "Live ISO pacman: Color + ParallelDownloads=5 + ILoveCandy"
    blank

    info "Packages: $pkgs"
    blank
    run "pacstrap -K /mnt $pkgs"
    ok "Base system installed"

    run "genfstab -U /mnt >> /mnt/etc/fstab"
    ok "fstab generated"
}

# =============================================================================
#  SECTION 19 — GENERATE CHROOT CONFIGURATION SCRIPT
# =============================================================================

# ── generate_chroot_script ────────────────────────────────────────────────────
# Writes /mnt/archwizard-configure.sh — a self-contained bash script that runs
# INSIDE arch-chroot to finish configuring the installed system.
#
# WHY A SEPARATE SCRIPT?
#   `arch-chroot /mnt some-command` can only run one command. For a complex
#   multi-step configuration we need many commands. Generating a script and
#   running it in one arch-chroot call is cleaner than multiple chroot invocations
#   (each of which re-mounts /proc, /sys, /dev, etc.).
#
# WHY NOT A HEREDOC WITH sed PLACEHOLDERS?
#   An earlier version used a single large heredoc with @@VARIABLE@@ placeholders
#   replaced by sed. This caused a catastrophic bug: sed was expanding the fstab
#   content (which contains UUIDs and equal signs) as regex, corrupting it.
#   The current approach writes the script section-by-section using `cat >> "$S"`.
#   Sections with no variable substitution use quoted heredoc markers ('MARKER')
#   to prevent accidental expansion. Sections that need variables use unquoted
#   markers (MARKER) so bash expands $VARIABLE at write-time on the HOST.
#
# UUID COLLECTION:
#   UUIDs are read from the live ISO environment (where partitions are mounted and
#   blkid can read them) and baked into the chroot script as literal strings.
#   Inside the chroot the partition devices may not be visible, so we cannot call
#   blkid from within the chroot.
#
# MKINITCPIO HOOKS:
#   The hook order matters:
#     base udev autodetect microcode modconf kms keyboard keymap consolefont block
#     [encrypt — only if LUKS]
#     filesystems fsck
#   - microcode: loads CPU microcode early (before any userspace)
#   - kms: loads GPU kernel mode-setting drivers early (prevents blank screen flicker)
#   - keyboard/keymap: enables the chosen keymap in the initramfs
#   - encrypt: the LUKS unlock hook — must come BEFORE filesystems
#   - filesystems: mounts the root filesystem
#   - fsck: filesystem check on root before mounting
generate_chroot_script() {
    section "Generating Chroot Configuration Script"

    # ── Resolve packages for every selected desktop ───────────────────────
    local all_de_pkgs="" dm_service="" has_wayland=false

    for de in "${DESKTOPS[@]}"; do
        case "$de" in
            kde)
                # sddm is KDE's reference DM — included in the package list.
                # We do NOT use kde-applications (the group) because it pulls in
                # 600+ packages including games, redundant apps, etc. — against
                # the Arch philosophy. A curated minimal list is used instead.
                # Users can always `pacman -S kde-applications` after install.
                all_de_pkgs+=" plasma plasma-desktop plasma-nm plasma-pa plasma-workspace"
                all_de_pkgs+=" sddm dolphin konsole kate spectacle gwenview ark kcalc"
                all_de_pkgs+=" okular kdeconnect powerdevil plasma-disks"
                dm_service="sddm"; has_wayland=true ;;
            gnome)
                # gdm is GNOME's reference DM — included in the gnome group.
                # gnome-software-packagekit-plugin: required for GNOME Software
                # to show and manage Arch packages (without it the app store is empty).
                all_de_pkgs+=" gnome gnome-extra gnome-tweaks gdm gnome-software-packagekit-plugin"
                [[ -z "$dm_service" ]] && dm_service="gdm"; has_wayland=true ;;
            hyprland)
                # Hyprland uses sddm but it is NOT in the hyprland group — add it explicitly
                all_de_pkgs+=" hyprland waybar wofi kitty ttf-font-awesome noto-fonts"
                all_de_pkgs+=" polkit-gnome xdg-desktop-portal-hyprland sddm"
                dm_service="sddm"; has_wayland=true ;;
            sway)
                # ly is a minimal TUI DM for Sway — add it explicitly (not in sway group)
                all_de_pkgs+=" sway waybar swaylock swayidle foot wofi brightnessctl"
                all_de_pkgs+=" xdg-desktop-portal-wlr ly"
                [[ -z "$dm_service" ]] && dm_service="ly"; has_wayland=true ;;
            cosmic)
                # cosmic-greeter is COSMIC's DM — already in the cosmic group
                all_de_pkgs+=" cosmic cosmic-greeter"
                [[ -z "$dm_service" ]] && dm_service="cosmic-greeter"; has_wayland=true ;;
            xfce)
                # lightdm + greeter included explicitly (not in xfce4 group)
                # gvfs         — trash, network shares, removable media in Thunar
                # xarchiver    — archive manager (7zip, zip, tar) for Thunar
                # network-manager-applet — system tray NM icon for XFCE panel
                # mousepad     — lightweight GTK text editor
                # ristretto    — image viewer (fast, minimal)
                all_de_pkgs+=" xfce4 xfce4-goodies lightdm lightdm-gtk-greeter"
                all_de_pkgs+=" gvfs xarchiver network-manager-applet mousepad ristretto"
                [[ -z "$dm_service" ]] && dm_service="lightdm" ;;
            none) ;;
        esac
    done
    # Display manager priority pass: sddm overrides all other DMs when KDE or
    # Hyprland is in the list because both use SDDM as their reference DM and
    # SDDM handles Wayland sessions best in the Qt ecosystem.
    # This second loop runs AFTER the main loop so sddm can override gdm/lightdm
    # even if gnome or xfce was processed last.
    for de in "${DESKTOPS[@]}"; do
        [[ "$de" == "kde" || "$de" == "hyprland" ]] && dm_service="sddm" && break
    done

    local nvidia_pkgs=""
    if [[ "$USE_NVIDIA" == true ]]; then
        nvidia_pkgs="nvidia nvidia-utils nvidia-settings"
        [[ "$USE_MULTILIB"  == true ]] && nvidia_pkgs+=" lib32-nvidia-utils"
        [[ "$has_wayland"   == true ]] && nvidia_pkgs+=" egl-wayland"
    fi

    local bootloader_pkgs="efibootmgr"
    [[ "$BOOTLOADER"  == "grub" ]]  && bootloader_pkgs+=" grub"
    [[ "$DUAL_BOOT"   == true && "$BOOTLOADER" == "grub" ]] && bootloader_pkgs+=" os-prober"
    [[ "$USE_SNAPPER" == true && "$BOOTLOADER" == "grub" ]] && bootloader_pkgs+=" grub-btrfs"
    [[ "$SECURE_BOOT" == true ]]    && bootloader_pkgs+=" sbctl"

    # ── Collect UUIDs — must be done NOW, from the host ──────────────────
    # blkid reads UUIDs from open, mounted partitions on the live system.
    # Two UUIDs are needed:
    #   root_uuid  — UUID of the btrfs filesystem (or /dev/mapper/cryptroot if LUKS).
    #                Used in the systemd-boot kernel cmdline: root=UUID=...
    #   luks_uuid  — UUID of the raw encrypted PARTITION (not the mapper device).
    #                Used in cryptdevice=UUID=...:cryptroot so the bootloader knows
    #                which partition to ask for the passphrase at boot.
    # In dry-run mode we substitute placeholder strings so the generated script
    # is still syntactically valid and reviewable.
    local root_uuid luks_uuid
    if [[ "$DRY_RUN" == false ]]; then
        local _rdev="${ROOT_PART_MAPPED:-$ROOT_PART}"
        root_uuid=$(blkid -s UUID -o value "$_rdev"     2>/dev/null || echo "ROOT-UUID")
        luks_uuid=$(blkid -s UUID -o value "$ROOT_PART" 2>/dev/null || echo "LUKS-UUID")
    else
        root_uuid="DRY-ROOT-UUID"; luks_uuid="DRY-LUKS-UUID"
    fi

    # mkinitcpio hooks — filesystems hook handles all FS types.
    # For btrfs: no extra hooks needed (built into kernel or autodetected).
    # For LUKS: encrypt hook must come BEFORE filesystems.
    # The autodetect hook scans the running kernel and includes only needed modules.
    local mkinit_hooks="base udev autodetect microcode modconf kms keyboard keymap consolefont block"
    [[ "$USE_LUKS" == true ]] && mkinit_hooks+=" encrypt"
    mkinit_hooks+=" filesystems fsck"
    # Note: all filesystems (btrfs, ext4, xfs, f2fs) are handled by the
    # 'filesystems' hook — no FS-specific hooks needed in modern mkinitcpio.

    # systemd-boot entry kernel path depends on chosen kernel:
    #   linux     → /vmlinuz-linux
    #   linux-lts → /vmlinuz-linux-lts
    #   linux-zen → /vmlinuz-linux-zen
    local kernel_img="vmlinuz-${KERNEL}"
    local initrd_img="initramfs-${KERNEL}.img"

    # rootflags=subvol=@ is btrfs-specific — other filesystems must NOT have it
    local sd_options
    if [[ "$ROOT_FS" == "btrfs" ]]; then
        sd_options="root=UUID=${root_uuid} rootflags=subvol=@ rw quiet splash"
        [[ "$USE_LUKS" == true ]] &&             sd_options="cryptdevice=UUID=${luks_uuid}:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet"
    else
        sd_options="root=UUID=${root_uuid} rw quiet splash"
        [[ "$USE_LUKS" == true ]] &&             sd_options="cryptdevice=UUID=${luks_uuid}:cryptroot root=/dev/mapper/cryptroot rw quiet"
    fi

    # ── Write the chroot script section by section (no fragile sed/heredoc) ─
    local S=/mnt/archwizard-configure.sh
    : > "$S"

    # Header — also refresh archlinux-keyring first to prevent GPG signature
    # errors when pacman installs packages. The live ISO keyring may be stale
    # if the ISO is months old. This is the same fix archinstall applies.
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
# The ISO keyring can be months old; stale keys cause GPG verification failures
# when pacman downloads packages. Always update the keyring first.
pacman -Sy --noconfirm archlinux-keyring 2>/dev/null || true
ok "archlinux-keyring refreshed"
HDR

    # ── Timezone ─────────────────────────────────────────────────────────────
    # ln -sf creates a symlink from /etc/localtime to the correct zone file.
    # hwclock --systohc sets the hardware (BIOS/UEFI) clock to UTC, matching
    # the software clock. Windows uses local time in the hardware clock by default —
    # if dual-booting, Windows will need a registry fix to use UTC instead.
    cat >> "$S" << TZEOF

section "Timezone & Clock"
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc
ok "Timezone: ${TIMEZONE}"
TZEOF

    # ── Locale ───────────────────────────────────────────────────────────────
    # locale.gen lists which locales to compile. We always include en_US.UTF-8
    # as a fallback because many programs default to it when their own locale
    # messages are missing. The user's chosen locale is set in locale.conf (LANG).
    # vconsole.conf persists the keymap for the virtual consoles (TTY) on the
    # installed system — the `loadkeys` done earlier only affects the live ISO session.
    cat >> "$S" << LOCEOF

section "Locale & Console"
echo "${LOCALE} UTF-8" >> /etc/locale.gen
grep -q "en_US.UTF-8" /etc/locale.gen || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}"   > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
ok "Locale: ${LOCALE} | Keymap: ${KEYMAP}"
LOCEOF

    # ── Hostname & /etc/hosts ────────────────────────────────────────────────
    # /etc/hosts provides static name resolution without DNS.
    # 127.0.1.1 → hostname  is the standard Arch setup for machines without a
    # static external IP. It allows the hostname to resolve locally, which some
    # services (e.g. Postfix, cups, Avahi) require.
    # The ::1 entry is the IPv6 loopback address (equivalent to 127.0.0.1).
    cat >> "$S" << HOSTEOF

section "Hostname"
echo "${HOSTNAME}" > /etc/hostname
{
  echo "127.0.0.1  localhost"
  echo "::1        localhost"
  echo "127.0.1.1  ${HOSTNAME}.localdomain  ${HOSTNAME}"
} > /etc/hosts
ok "Hostname: ${HOSTNAME}"
HOSTEOF

    # ── Pacman tweaks ────────────────────────────────────────────────────────
    # Uncomments useful pacman.conf options:
    #   Color            — colored terminal output (easier to read)
    #   VerbosePkgLists  — shows old → new versions during upgrades
    #   ParallelDownloads — downloads up to 5 packages simultaneously
    #   ILoveCandy       — replaces the progress bar with a Pac-Man animation 🎮
    cat >> "$S" << 'PACEOF'

section "Pacman Tweaks"
sed -i 's/^#Color/Color/'                               /etc/pacman.conf
sed -i 's/^#VerbosePkgLists/VerbosePkgLists/'           /etc/pacman.conf
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
grep -q "ILoveCandy" /etc/pacman.conf || sed -i '/^Color/a ILoveCandy' /etc/pacman.conf
ok "pacman: colour + parallel downloads + ILoveCandy enabled"
PACEOF

    # makepkg.conf performance tuning
    cat >> "$S" << 'MKPEOF'

section "makepkg.conf — Compiler Optimisation"
# Parallel jobs = all CPU threads
NPROC=$(nproc)
sed -i "s/^#MAKEFLAGS=.*/MAKEFLAGS="-j${NPROC}"/" /etc/makepkg.conf

# Native CPU architecture — lets GCC/Clang use every instruction the CPU supports
# (only beneficial on the machine being built; do NOT do this for packages you share)
sed -i "s/-march=x86-64 -mtune=generic/-march=native -mtune=native/" /etc/makepkg.conf

# Same for Rust-based AUR packages (paru, etc.)
grep -q "^RUSTFLAGS=" /etc/makepkg.conf     && sed -i 's/^RUSTFLAGS=.*/RUSTFLAGS="-C opt-level=2 -C target-cpu=native"/' /etc/makepkg.conf     || echo 'RUSTFLAGS="-C opt-level=2 -C target-cpu=native"' >> /etc/makepkg.conf

ok "makepkg: -j${NPROC} | -march=native | RUSTFLAGS=target-cpu=native"
MKPEOF

    # Kernel sysctl hardening
    cat >> "$S" << 'SYSCTLEOF'

section "Kernel Hardening — sysctl"
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-security.conf << 'SYSEOF'
# Hide kernel pointers from unprivileged users (and even root)
kernel.kptr_restrict = 2
# Block unprivileged users from reading the kernel ring buffer
kernel.dmesg_restrict = 1
# SYN flood protection
net.ipv4.tcp_syncookies = 1
# Reverse path filtering — drop packets with spoofed source IPs
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.rp_filter = 1
# Disable ICMP redirects (prevent MITM on local network)
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
# Do not send ICMP redirects
net.ipv4.conf.all.send_redirects = 0
SYSEOF
ok "Kernel hardening sysctl written to /etc/sysctl.d/99-security.conf"
SYSCTLEOF

    # Journal size cap
    cat >> "$S" << 'JRNEOF'

section "systemd Journal — Size Cap"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/00-journal.conf << 'JEOF'
[Journal]
# Cap persistent journal at 200 MB, in-memory at 50 MB
SystemMaxUse=200M
RuntimeMaxUse=50M
# Keep at least 2 weeks of logs
MaxRetentionSec=2week
JEOF
ok "Journal capped at 200 MB (persistent) + 50 MB (runtime)"
JRNEOF

    # ── Multilib ─────────────────────────────────────────────────────────────
    # Multilib is an optional pacman repository that contains 32-bit libraries
    # (lib32-*). Required for: Steam, Wine, Proton, some 32-bit games.
    # The sed command uncomments both the [multilib] header line AND the
    # Include = /etc/pacman.d/mirrorlist line immediately below it.
    # Regex breakdown: match "#[multilib]", remove its #, advance to next line (n),
    # remove the # from that line too — both must be uncommented together.
    if [[ "$USE_MULTILIB" == true ]]; then
        cat >> "$S" << 'MLEOF'

section "Multilib"
sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' /etc/pacman.conf
pacman -Sy --noconfirm
ok "Multilib repository enabled"
MLEOF
    fi

    # Reflector — build country args the same way as setup_mirrors
    if [[ "$USE_REFLECTOR" == true ]]; then
        local _ref_country_args=""
        IFS=',' read -ra _ref_countries <<< "$REFLECTOR_COUNTRIES"
        for _c in "${_ref_countries[@]}"; do
            _c="${_c#"${_c%%[![:space:]]*}"}"; _c="${_c%"${_c##*[![:space:]]}"}"
            [[ -n "$_c" ]] && _ref_country_args+="--country \"${_c}\" "
        done
        # Build one --country flag per line for reflector.conf
        local _ref_conf_country_lines=""
        IFS=',' read -ra _conf_countries <<< "$REFLECTOR_COUNTRIES"
        for _cc in "${_conf_countries[@]}"; do
            _cc="${_cc#"${_cc%%[![:space:]]*}"}"; _cc="${_cc%"${_cc##*[![:space:]]}"}"
            [[ -n "$_cc" ]] && _ref_conf_country_lines+="--country ${_cc}\n"
        done

        cat >> "$S" << REFEOF

section "Reflector — Mirror Optimisation"
reflector ${_ref_country_args}--protocol ${REFLECTOR_PROTOCOL} --age ${REFLECTOR_AGE} --latest 20 --number ${REFLECTOR_NUMBER} --sort rate --save /etc/pacman.d/mirrorlist
# Write reflector.conf so reflector.timer uses the same settings on every future run
mkdir -p /etc/xdg/reflector
printf '%b' "${_ref_conf_country_lines}--protocol ${REFLECTOR_PROTOCOL}\n--age ${REFLECTOR_AGE}\n--latest 20\n--number ${REFLECTOR_NUMBER}\n--sort rate\n--save /etc/pacman.d/mirrorlist\n" > /etc/xdg/reflector/reflector.conf
ok "Mirrors optimised + /etc/xdg/reflector/reflector.conf written for timer"
REFEOF
    fi

    # Bootloader packages
    cat >> "$S" << BPEOF

section "Bootloader Packages"
pacman -S --noconfirm --ask 4 --needed ${bootloader_pkgs}
ok "Bootloader packages installed"
BPEOF

    # Desktop environments
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
# Install pipewire core first (no jack conflict here)
pacman -S --noconfirm --ask 4 --needed pipewire pipewire-alsa pipewire-pulse wireplumber

# pipewire-jack conflicts with jack2 — let pacman handle the swap properly.
# --ask 4 (conflict bit) auto-confirms "Replace jack2 with pipewire-jack? [y/N]"
# We never manually remove jack2 because it may have dependents that need
# the 'jack' provider — pipewire-jack satisfies that same provide after the swap.
if pacman -Qq jack2 &>/dev/null; then
    info "jack2 detected — letting pacman replace it with pipewire-jack..."
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

    # ── GRUB bootloader ──────────────────────────────────────────────────────
    # grub-install flags:
    #   --target=x86_64-efi   — install the UEFI version of GRUB (not BIOS)
    #   --efi-directory       — where the ESP is mounted
    #   --bootloader-id       — name shown in the UEFI firmware boot menu
    #   --recheck             — re-probe devices even if a cached device.map exists
    #
    # os-prober: detects other OSes (Windows, other Linux distros) and adds them
    # to the GRUB menu. Disabled by default in Arch's grub package for security
    # reasons — we re-enable it only when DUAL_BOOT=true.
    #
    # LUKS GRUB cmdline: cryptdevice=UUID=<luks_uuid>:cryptroot tells the kernel
    # which partition to decrypt at boot and what mapper name to give it.
    # root=/dev/mapper/cryptroot then mounts the decrypted btrfs filesystem.
    #
    # grub-btrfs: adds a submenu to GRUB listing all snapper snapshots as
    # bootable entries. Requires the grub-btrfsd daemon (enabled separately)
    # to watch for new snapshots and regenerate grub.cfg automatically.
    if [[ "$BOOTLOADER" == "grub" ]]; then
        # ── GRUB install ────────────────────────────────────────────────────
        # Use echo lines to $S rather than heredocs to avoid nesting issues.
        # FIRMWARE_MODE is expanded here (at chroot-script-generation time).
        {
            echo 'section "GRUB Bootloader"'
            if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
                echo '# UEFI: unique bootloader-id = hostname + first 6 chars of machine-id'
                echo '_hostname=$(cat /etc/hostname 2>/dev/null | tr -d '"'"' '"'"' || echo arch)'
                echo '_mid=$(cat /etc/machine-id 2>/dev/null | head -c6 || echo 000000)'
                echo 'GRUB_ID="Arch-${_hostname}-${_mid}"'
                echo 'grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$GRUB_ID" --recheck'
                echo 'ok "GRUB installed — EFI entry: ${GRUB_ID}"'
            else
                # BIOS: install to MBR; DISK_ROOT is expanded at generation time
                echo "grub-install --target=i386-pc ${DISK_ROOT}"
                echo "ok \"GRUB installed to MBR of ${DISK_ROOT}\""
            fi
        } >> "$S"
        # Set GRUB_DISTRIBUTOR to the user-chosen boot menu name
        # This variable is expanded at script-generation time (no single quotes on heredoc marker)
        cat >> "$S" << GNEOF
# Set the GRUB boot menu entry name chosen during installation
if grep -q '^GRUB_DISTRIBUTOR=' /etc/default/grub; then
    sed -i 's|^GRUB_DISTRIBUTOR=.*|GRUB_DISTRIBUTOR="${GRUB_ENTRY_NAME}"|' /etc/default/grub
else
    echo 'GRUB_DISTRIBUTOR="${GRUB_ENTRY_NAME}"' >> /etc/default/grub
fi
ok "GRUB boot menu name: ${GRUB_ENTRY_NAME}"
GNEOF
        if [[ "$DUAL_BOOT" == true ]]; then
            # Enable os-prober robustly regardless of how the line appears in grub default
            cat >> "$S" << 'OSPEOF'
# Enable os-prober — handles all three possible states in /etc/default/grub:
#   1. Line present and commented:   #GRUB_DISABLE_OS_PROBER=false  → uncomment
#   2. Line present and set to true: GRUB_DISABLE_OS_PROBER=true    → change to false
#   3. Line absent entirely                                          → add it
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
        # For btrfs without LUKS, add rootflags=subvol=@ to GRUB_CMDLINE_LINUX.
        # GRUB_CMDLINE_LINUX is empty by default ("") and always appended to the
        # kernel cmdline regardless of recovery mode. Use this (not _DEFAULT)
        # so the match is reliable — _DEFAULT contains "loglevel=3 quiet" which
        # varies and would break the sed pattern.
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
# Mount all other Linux/NTFS partitions so os-prober can detect them.
#
# os-prober works by scanning /proc/mounts for mounted filesystems and
# looking for /boot/grub/grub.cfg, kernels, Windows bootloaders, etc.
# In the chroot only the new system is mounted → os-prober sees nothing else.
#
# KEY FIXES vs previous approach:
#   1. btrfs partitions mounted with subvol=@ — that's where /boot lives
#   2. Partitions stay mounted DURING grub-mkconfig (not unmounted early)
#   3. Device-already-mounted check uses findmnt -S (source), not mountpoint
#   4. grub-install uses hostname + machine-id suffix to avoid EFI collision

_osp_base="/mnt/osprober"
mkdir -p "$_osp_base"
_osp_dirs=()
_osp_idx=0

# Get current root source device (to skip it)
_cur_root=$(findmnt -n -o SOURCE / 2>/dev/null || echo "none")

while IFS=' ' read -r _dev _fstype; do
    [[ -z "$_dev" ]] && continue
    # Skip if this device is already mounted as a source
    findmnt -S "$_dev" > /dev/null 2>&1 && continue
    # Skip current root
    [[ "$_dev" == "$_cur_root" ]] && continue
    # Skip EFI/swap/loop
    _pt=$(lsblk -no PARTTYPE "$_dev" 2>/dev/null || echo "")
    [[ "$_pt" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] && continue
    [[ "$_pt" == "0657fd6d-a4ab-43c4-84e5-0933c84b4f4f" ]] && continue

    _osp_dir="${_osp_base}/${_osp_idx}"
    mkdir -p "$_osp_dir"

    # btrfs: mount the @ subvolume — that's where the OS root lives
    # (toplevel btrfs mount shows only subvolume entries, not OS files)
    if [[ "$_fstype" == "btrfs" ]]; then
        mount -o ro,noexec,nosuid,subvol=@ "$_dev" "$_osp_dir" 2>/dev/null || \
        mount -o ro,noexec,nosuid         "$_dev" "$_osp_dir" 2>/dev/null || continue
    else
        mount -o ro,noexec,nosuid "$_dev" "$_osp_dir" 2>/dev/null || continue
    fi

    _osp_dirs+=("$_osp_dir")
    _osp_idx=$(( _osp_idx + 1 ))
    info "Mounted for os-prober: $_dev → $_osp_dir"

done < <(lsblk -ln -o PATH,FSTYPE | awk '$2 ~ /^(btrfs|ext4|xfs|f2fs|ntfs)$/ {print $1, $2}')

# Run os-prober — it will find the mounted partitions in /proc/mounts
os-prober 2>/dev/null || true

# Generate GRUB config with all OSes detected
grub-mkconfig -o /boot/grub/grub.cfg

# Unmount probe mounts
for _d in "${_osp_dirs[@]}"; do
    umount "$_d" 2>/dev/null || true
    rmdir  "$_d" 2>/dev/null || true
done
rmdir "$_osp_base" 2>/dev/null || true

ok "GRUB configured — all partitions scanned by os-prober"
GRUB2EOF

    # ── systemd-boot ─────────────────────────────────────────────────────────
    # systemd-boot is a simple UEFI boot manager included in systemd.
    # It reads .conf files from /boot/loader/entries/ and presents them
    # as a menu. Much simpler than GRUB but: UEFI-only, no BIOS support,
    # no built-in os-prober, no btrfs snapshot menu.
    #
    # ESP mount point: /boot (not /boot/efi like GRUB).
    # When pacman installs linux, the kernel lands at /boot/vmlinuz-linux.
    # Since the ESP IS /boot, the kernel is on the ESP and systemd-boot
    # can read it directly. With /boot/efi the kernel would be on btrfs,
    # which systemd-boot cannot read — hence the "only firmware" boot menu.
    #
    # loader.conf options:
    #   default arch.conf  — which entry to boot by default
    #   timeout 5          — show menu for 5 seconds (0 = skip menu)
    #   console-mode max   — use highest available console resolution
    #   editor no          — disable kernel cmdline editing at boot (security)
    #
    # The entry file (arch.conf) references kernel and initrd by path relative
    # to the ESP root (/boot). The microcode initrd must come BEFORE
    # initramfs-linux.img — the bootloader loads them in order and the
    # microcode must be applied before the main initramfs runs.
    #
    # systemd-boot-update.service: auto-updates the EFI binary when the
    # systemd package updates. Without it the bootloader EFI and the installed
    # systemd version can drift apart over time.
    elif [[ "$BOOTLOADER" == "systemd-boot" ]]; then
        cat >> "$S" << 'SDEOF'

section "systemd-boot"
# ESP is mounted at /boot for systemd-boot — the kernel is installed there by pacman.
# bootctl reads /boot as the ESP root, so /vmlinuz-linux = /boot/vmlinuz-linux on disk.
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
            # Primary boot entry
            echo "cat > /boot/loader/entries/arch.conf << 'ENTRYEOF'"
            echo "title   ${GRUB_ENTRY_NAME}"
            echo "linux   /${kernel_img}"
            [[ "$CPU_VENDOR" != "unknown" ]] && echo "initrd  /${CPU_VENDOR}-ucode.img"
            echo "initrd  /${initrd_img}"
            echo "options ${sd_options}"
            echo "ENTRYEOF"
            # Fallback entry — uses fallback initramfs (no autodetect, more modules)
            echo "cat > /boot/loader/entries/arch-fallback.conf << 'FBEOF'"
            echo "title   ${GRUB_ENTRY_NAME} (fallback)"
            echo "linux   /${kernel_img}"
            [[ "$CPU_VENDOR" != "unknown" ]] && echo "initrd  /${CPU_VENDOR}-ucode.img"
            echo "initrd  /initramfs-${KERNEL}-fallback.img"
            echo "options ${sd_options}"
            echo "FBEOF"
            echo "# Auto-update bootloader EFI binary when systemd package updates"
            echo "systemctl enable systemd-boot-update.service"
            echo "ok \"systemd-boot installed and configured\""
        } >> "$S"
    fi

    # ── User accounts ────────────────────────────────────────────────────────
    # useradd flags:
    #   -m  — create the home directory (/home/USERNAME)
    #   -G  — add to supplementary groups:
    #     wheel    — sudo access (sudoers: %wheel ALL=(ALL:ALL) ALL)
    #     audio    — direct audio device access (legacy ALSA; PipeWire handles this too)
    #     video    — direct GPU/framebuffer access
    #     optical  — CD/DVD drives
    #     storage  — USB drives and disk management
    #     network  — NetworkManager policy (allows the user to configure networks)
    #     input    — input devices (mice, keyboards, gamepads via /dev/input/)
    #
    # chpasswd reads "user:password" from stdin — safer than `passwd --stdin`
    # which is not universally available and avoids the password appearing in
    # process arguments.
    #
    # The sed command uncomments `%wheel ALL=(ALL:ALL) ALL` in /etc/sudoers,
    # giving all wheel members full passworded sudo access.
    cat >> "$S" << USREOF

section "User Accounts"
useradd -mG wheel,audio,video,optical,storage,network,input "${USERNAME}"
# xdg-user-dirs creates ~/Desktop ~/Downloads ~/Music etc. on first login.
# We also create them now so they exist before the user logs in.
xdg-user-dirs-update --force 2>/dev/null || true
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd
echo "root:${ROOT_PASSWORD}"        | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
ok "User '${USERNAME}' created with sudo (wheel)"
USREOF

    # ── Core services ────────────────────────────────────────────────────────
    # Services enabled here are started on every boot automatically:
    #
    #   NetworkManager    — manages wired, WiFi, VPN connections. The applet
    #                       (nm-applet) provides the system tray icon for DEs.
    #
    #   systemd-resolved  — local DNS stub resolver with caching and optional
    #                       DNSSEC validation. Listens on 127.0.0.53. The symlink
    #                       /etc/resolv.conf → stub-resolv.conf (created after
    #                       arch-chroot returns) points all DNS queries here.
    #
    #   fstrim.timer      — runs `fstrim -av` weekly on all mounted filesystems
    #                       that support TRIM (SSDs, NVMe). Reclaims freed blocks
    #                       at the drive level for better long-term performance.
    #                       Works alongside discard=async (which handles real-time
    #                       small discards) and LUKS --allow-discards.
    #
    #   systemd-oomd      — userspace Out-Of-Memory daemon. Uses cgroups-v2 PSI
    #                       (Pressure Stall Information) to detect memory exhaustion
    #                       BEFORE the kernel OOM killer fires. Kills the most
    #                       memory-hungry cgroup gracefully instead of killing
    #                       random processes as the kernel OOM killer does.
    #
    #   paccache.timer    — runs `paccache -r` weekly to delete all cached package
    #                       versions except the 3 most recent. Without this the
    #                       /var/cache/pacman/pkg directory grows without bound.
    #                       Requires pacman-contrib (installed in install_base).
    cat >> "$S" << 'SVCEOF'

section "Enabling Core Services"
systemctl enable NetworkManager
# systemd-resolved: local DNS stub with caching and DNSSEC
systemctl enable systemd-resolved
# Weekly TRIM for all SSD/NVMe filesystems (complements discard=async in fstab)
systemctl enable fstrim.timer
# Kill memory-hogging processes before the kernel OOM killer fires
systemctl enable systemd-oomd
# Weekly pacman cache cleanup — keeps only last 3 versions of each package
systemctl enable paccache.timer
SVCEOF
    [[ -n "$dm_service" ]]         && echo "systemctl enable ${dm_service}" >> "$S"
    [[ "$USE_REFLECTOR" == true ]] && echo "systemctl enable reflector.timer" >> "$S"
    echo "ok \"Core services enabled\"" >> "$S"

    # ── Snapper btrfs snapshots ───────────────────────────────────────────────
    # Snapper manages btrfs snapshots automatically based on timers and pre/post
    # hooks (snap-pac triggers a pre/post snapshot around every pacman transaction).
    #
    # WHY WE DON'T CALL "snapper create-config" IN THE CHROOT:
    #   `snapper create-config /` talks to the snapper daemon over D-Bus.
    #   D-Bus is not running inside arch-chroot — there is no systemd session,
    #   no dbus-daemon, nothing. The call throws:
    #     org.freedesktop.DBus.Error.ServiceUnknown
    #   and fails. The fix is to write the config file directly: it's just a
    #   plain shell-sourced key=value file in /etc/snapper/configs/root.
    #   On first real boot, snapper finds the config and works perfectly.
    #
    # TIMERS enabled:
    #   snapper-timeline.timer  — takes hourly snapshots, cleans up old ones
    #                             per the TIMELINE_LIMIT_* settings
    #   snapper-cleanup.timer   — removes snapshots that exceed the retention limits
    #   snapper-boot.timer      — takes a snapshot on every successful boot,
    #                             capturing the state BEFORE any changes this session
    #
    # The .snapshots subvolume must be empty before snapper sets it up, so we
    # unmount it, delete the mount point, recreate it, and re-mount via `mount -a`
    # (which reads the already-generated /etc/fstab).
    if [[ "$USE_SNAPPER" == true ]]; then
        cat >> "$S" << 'SNAPEOF'

section "Snapper — btrfs Auto-Snapshots"
# Ensure @snapshots subvolume is properly mounted at /.snapshots
umount /.snapshots 2>/dev/null || true
rm -rf /.snapshots
mkdir -p /.snapshots
mount -a   # remounts from fstab — picks up @snapshots subvol
chmod 750 /.snapshots
chown :wheel /.snapshots 2>/dev/null || true

# Create snapper config dir and write the root config manually.
# This avoids calling "snapper create-config" which needs DBus (not
# available in chroot) and would throw:
#   org.freedesktop.DBus.Error.ServiceUnknown
mkdir -p /etc/snapper/configs

cat > /etc/snapper/configs/root << 'SNACONF'
# Snapper config for subvolume / — written by ArchWizard
SUBVOLUME="/"
FSTYPE="btrfs"

# Snapshot type
ALLOW_USERS=""
ALLOW_GROUPS="wheel"
SYNC_ACL="no"

# Background comparison
BACKGROUND_COMPARISON="yes"

# Number of snapshots to keep
NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="10"
NUMBER_LIMIT_IMPORTANT="10"

# Timeline snapshots
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="5"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="2"
TIMELINE_LIMIT_MONTHLY="1"
TIMELINE_LIMIT_YEARLY="0"

# Empty pre/post cleanup
EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"
SNACONF

# Register config in snapper's global list
if [[ -f /etc/snapper/configs ]]; then
    : # it is a file somehow — skip
elif grep -q "^SNAPPER_CONFIGS=" /etc/conf.d/snapper 2>/dev/null; then
    sed -i 's/^SNAPPER_CONFIGS=.*/SNAPPER_CONFIGS="root"/' /etc/conf.d/snapper
else
    mkdir -p /etc/conf.d
    echo 'SNAPPER_CONFIGS="root"' > /etc/conf.d/snapper
fi

# Enable timers — they will work on first real boot with DBus running
# snapper-boot: takes a snapshot on every successful boot (catches kernel/driver breakage)
systemctl enable snapper-timeline.timer snapper-cleanup.timer snapper-boot.timer

ok "Snapper configured — config written directly (no DBus needed in chroot)"
ok "First snapshot will be taken automatically on next boot"
SNAPEOF
    fi

    # Firewall
    if [[ "$FIREWALL" == "nftables" ]]; then
        cat >> "$S" << 'NFTEOF'

section "Firewall — nftables"
pacman -S --noconfirm --ask 4 --needed nftables
# The default /etc/nftables.conf shipped with the package is already a solid
# stateful desktop ruleset: drop all incoming, allow established/related,
# allow loopback, allow ICMP. We use it as-is.
# Backup the default in case the user wants to review it
cp /etc/nftables.conf /etc/nftables.conf.archwizard-default
# Ensure the ruleset is explicitly written (idempotent)
cat > /etc/nftables.conf << 'NFTRULES'
#!/usr/bin/nft -f
# ArchWizard default stateful desktop ruleset

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        ct state invalid drop
        ct state { established, related } accept
        iifname lo accept
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
        # Uncomment to allow SSH:
        # tcp dport 22 accept
        counter drop
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
    }
    chain output {
        type filter hook output priority filter; policy accept;
    }
}
NFTRULES
systemctl enable nftables
ok "nftables enabled with stateful desktop ruleset (drop all incoming)"
NFTEOF
    elif [[ "$FIREWALL" == "ufw" ]]; then
        cat >> "$S" << 'UFWEOF'

section "Firewall — ufw"
pacman -S --noconfirm --ask 4 --needed ufw
# NOTE: ufw --force enable is intentionally NOT called here.
# Activating UFW inside arch-chroot fails because the chroot has no running
# kernel — iptables/nftables modules cannot be loaded, causing ufw to error.
# Instead we pre-configure the policy and enable the systemd service so UFW
# activates automatically and correctly on first real boot.

# Pre-configure default policy (deny incoming / allow outgoing)
mkdir -p /etc/default
cat > /etc/default/ufw << 'UFWDEFAULT'
IPV6=yes
DEFAULT_INPUT_POLICY="DROP"
DEFAULT_OUTPUT_POLICY="ACCEPT"
DEFAULT_FORWARD_POLICY="DROP"
DEFAULT_APPLICATION_POLICY="SKIP"
MANAGE_BUILTINS=no
UFWDEFAULT

# Tell ufw it should be enabled at boot
mkdir -p /etc/ufw
printf 'ENABLED=yes\nLOGLEVEL=low\n' > /etc/ufw/ufw.conf

# Enable the systemd service — rules load into kernel at first real boot
systemctl enable ufw
ok "ufw installed and enabled — firewall will be active on first boot"
UFWEOF
    fi

    # ── zram compressed swap ─────────────────────────────────────────────────
    # zram creates a block device in RAM that compresses its contents with zstd.
    # It acts as a swap device but never touches disk — ideal for machines with
    # 8 GB+ RAM where you want a swap safety net without disk latency.
    #
    # zram-generator is a systemd unit generator: it reads zram-generator.conf
    # and creates systemd-zram-setup@zram0.service automatically at boot.
    #
    # Config options:
    #   zram-size = min(ram/2, 8192)  — use half of physical RAM up to 8 GB.
    #     Example: 16 GB machine → 8 GB zram. 32 GB machine → still 8 GB (cap).
    #   compression-algorithm = zstd  — best balance of speed and ratio.
    #
    # vm.swappiness = 100:
    #   The default swappiness (60) was tuned for spinning disks where swapping
    #   is expensive. With zram the "disk" is compressed RAM — extremely fast.
    #   Setting swappiness=100 tells the kernel to move cold pages to zram
    #   aggressively, freeing physical RAM for active processes. This is the
    #   official recommendation for zram in the Arch wiki and the Linux kernel docs.
    #
    # vm.watermark_boost_factor = 0:
    #   Disables the memory watermark boost (which over-eagerly reclaims memory
    #   and can cause unnecessary swapping on zram systems).
    #
    # vm.watermark_scale_factor = 125:
    #   Increases the gap between low and high memory watermarks, giving kswapd
    #   more time to reclaim memory gradually before hitting pressure states.
    if [[ "$SWAP_TYPE" == "zram" ]]; then
        cat >> "$S" << 'ZRAMEOF'

section "zram Compressed Swap"
pacman -S --noconfirm --ask 4 --needed zram-generator
cat > /etc/systemd/zram-generator.conf << 'ZGENEOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
ZGENEOF
# With zram, swap IO cost is lower than disk — swappiness=100 is recommended
# (kernel aggressively moves cold pages to compressed RAM, freeing physical RAM)
cat > /etc/sysctl.d/99-zram.conf << 'SWAPEOF'
# zram: swap is cheap — use it aggressively
vm.swappiness = 100
# Better memory pressure response before OOM
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
SWAPEOF
ok "zram configured (up to 8 GB compressed RAM swap, swappiness=100)"
ZRAMEOF
    fi

    # Swap file fstab entry
    if [[ "$SWAP_TYPE" == "file" ]]; then
        echo "echo '/swap/swapfile none swap defaults 0 0' >> /etc/fstab" >> "$S"
        echo "ok \"Swap file entry added to fstab\"" >> "$S"
    fi

    # ── AUR helper ───────────────────────────────────────────────────────────
    # AUR helpers are not in the official repositories — they must be bootstrapped
    # by cloning their PKGBUILD from the AUR and building with makepkg.
    #
    # WHY sudo -u ${USERNAME}:
    #   makepkg explicitly refuses to run as root (to prevent PKGBUILDs from
    #   silently trashing the system). We switch to the regular user for the
    #   build step. The user already exists (created earlier in the chroot script)
    #   and has sudo rights, so makepkg -si can call `sudo pacman -U` to install.
    #
    # paru-bin vs paru:
    #   paru      — clones the Rust source and compiles it. Takes 10–15 min on
    #               slow machines / VMs because it downloads and compiles the entire
    #               Rust toolchain as a dependency.
    #   paru-bin  — pre-compiled binary from the AUR. Installs in seconds.
    #               Functionally identical to paru — same binary, same features.
    #   yay       — Go-based, compiles in ~2 min. Good middle ground.
    #
    # set -euo pipefail inside the sudo subshell ensures any failure (git clone,
    # makepkg, pacman install) is caught and propagates back to the chroot script,
    # which has set -e at the top, so the whole installation fails cleanly rather
    # than silently proceeding with no AUR helper installed.
    if [[ "$AUR_HELPER" != "none" ]]; then
        cat >> "$S" << AUREOF

section "AUR Helper: ${AUR_HELPER}"
pacman -S --noconfirm --ask 4 --needed git base-devel
# Build / install as the regular user (makepkg refuses to run as root)
sudo -u ${USERNAME} bash -c '
    set -euo pipefail
    cd /tmp
    # Clean any previous attempt
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
echo ""
echo -e "\033[0;32m\033[1m  ✓  All chroot steps finished successfully.\033[0m"
echo ""
FTEOF

    chmod +x "$S"
    ok "Chroot script written → /mnt/archwizard-configure.sh  ($(wc -l < "$S") lines)"
}

# =============================================================================
#  SECTION 20 — EXECUTE CHROOT
# =============================================================================

# ── run_chroot ────────────────────────────────────────────────────────────────
# Executes the generated configuration script inside the installed system using
# arch-chroot, which:
#   1. Binds /proc, /sys, /dev, /run from the host into /mnt
#   2. Chroots into /mnt
#   3. Runs /archwizard-configure.sh
#   4. Unmounts all the bind mounts on exit
#
# After arch-chroot returns we create the resolv.conf symlink from the HOST.
# WHY NOT FROM INSIDE THE CHROOT:
#   During the chroot, /etc/resolv.conf inside the jail is a bind-mount of the
#   live ISO's own /etc/resolv.conf. It is a regular file, not a symlink, and
#   it is bind-mounted read-only. Any attempt to `ln -sf` over it from inside
#   the chroot fails with "Device or resource busy". The symlink must be created
#   AFTER arch-chroot exits and the bind mount is released, targeting the path
#   on the installed system's real filesystem (relative path so it works after
#   reboot when /mnt is no longer in the picture).
run_chroot() {
    section "Running arch-chroot Configuration"
    run "arch-chroot /mnt /archwizard-configure.sh"
    ok "Chroot configuration complete"

    # resolv.conf symlink — must be created from the HOST after arch-chroot
    # returns because /etc/resolv.conf is bind-mounted from the live ISO inside
    # the chroot and cannot be replaced with a symlink from within it.
    section "DNS — systemd-resolved stub symlink"
    run "ln -sf ../run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf"
    ok "resolv.conf → systemd-resolved stub resolver (DNS caching + DNSSEC)"
}


# =============================================================================
#  SECTION 21 — POST-INSTALLATION VERIFICATION
# =============================================================================

# ── verify_installation ───────────────────────────────────────────────────────
# Runs a series of sanity checks on the installed system BEFORE unmounting.
# Everything is still mounted at /mnt so we can inspect files directly.
# Issues found here are reported as warnings (not fatal) — the system may
# still boot, but the user should be aware.
#
# Checks performed:
#   1. Kernel image exists in the expected location
#   2. initramfs exists
#   3. GRUB/bootctl installed correctly (UEFI: efibootmgr entry, BIOS: MBR marker)
#   4. fstab is valid (findmnt --verify)
#   5. Critical services are enabled (NetworkManager, fstrim.timer)
#   6. /etc/hostname is set
verify_installation() {
    section "Post-Installation Verification"
    local issues=0

    # ── 1. Kernel image ───────────────────────────────────────────────────
    local kernel_path
    if [[ "$BOOTLOADER" == "systemd-boot" ]]; then
        kernel_path="/mnt/boot/vmlinuz-${KERNEL}"
    else
        kernel_path="/mnt/boot/vmlinuz-${KERNEL}"
    fi
    if [[ -f "$kernel_path" ]]; then
        ok "Kernel image found: ${kernel_path}"
    else
        warn "Kernel image NOT found at ${kernel_path}"
        warn "  → mkinitcpio or pacstrap may have failed. Check the log."
        issues=$(( issues + 1 ))
    fi

    # ── 2. initramfs ──────────────────────────────────────────────────────
    local initrd_path="/mnt/boot/initramfs-${KERNEL}.img"
    local initrd_fallback="/mnt/boot/initramfs-${KERNEL}-fallback.img"
    if [[ -f "$initrd_path" ]]; then
        ok "initramfs found: ${initrd_path}"
    else
        warn "initramfs NOT found at ${initrd_path}"
        issues=$(( issues + 1 ))
    fi
    if [[ -f "$initrd_fallback" ]]; then
        ok "Fallback initramfs found"
    else
        warn "Fallback initramfs missing — recovery boot will not be available"
        issues=$(( issues + 1 ))
    fi

    # ── 3. Bootloader ─────────────────────────────────────────────────────
    if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
        if [[ "$BOOTLOADER" == "grub" ]]; then
            # Check that an Arch-* entry exists in UEFI NVRAM
            if efibootmgr 2>/dev/null | grep -qi "arch"; then
                ok "GRUB EFI entry found in UEFI NVRAM"
            else
                warn "No Arch GRUB entry found in UEFI NVRAM (efibootmgr)"
                warn "  → Try: arch-chroot /mnt grub-install --target=x86_64-efi ..."
                issues=$(( issues + 1 ))
            fi
            # Check grub.cfg was generated
            if [[ -f "/mnt/boot/grub/grub.cfg" ]]; then
                ok "grub.cfg found"
            else
                warn "grub.cfg NOT found — run grub-mkconfig -o /boot/grub/grub.cfg"
                issues=$(( issues + 1 ))
            fi
        elif [[ "$BOOTLOADER" == "systemd-boot" ]]; then
            if [[ -f "/mnt/boot/loader/entries/arch.conf" ]]; then
                ok "systemd-boot entry found: arch.conf"
            else
                warn "systemd-boot entry NOT found at /boot/loader/entries/arch.conf"
                issues=$(( issues + 1 ))
            fi
        fi
    else
        # BIOS: check that stage 1 bootloader is in MBR
        if dd if="$DISK_ROOT" bs=512 count=1 2>/dev/null | strings | grep -qi "grub"; then
            ok "GRUB signature found in MBR of ${DISK_ROOT}"
        else
            warn "GRUB not detected in MBR of ${DISK_ROOT}"
            warn "  → Try: arch-chroot /mnt grub-install --target=i386-pc ${DISK_ROOT}"
            issues=$(( issues + 1 ))
        fi
    fi

    # ── 4. fstab validity ─────────────────────────────────────────────────
    if [[ -f "/mnt/etc/fstab" ]]; then
        local fstab_lines
        fstab_lines=$(grep -c "^[^#]" /mnt/etc/fstab 2>/dev/null || echo 0)
        if (( fstab_lines > 0 )); then
            ok "fstab has ${fstab_lines} active entries"
        else
            warn "fstab appears empty — no mountpoints will be auto-mounted"
            issues=$(( issues + 1 ))
        fi
        # Check for UUID-based entries (more robust than device names)
        if grep -q "^UUID=" /mnt/etc/fstab 2>/dev/null; then
            ok "fstab uses UUIDs (stable across reboots)"
        else
            warn "fstab does not use UUIDs — entries may break after disk changes"
            issues=$(( issues + 1 ))
        fi
    else
        warn "fstab NOT found at /mnt/etc/fstab"
        issues=$(( issues + 1 ))
    fi

    # ── 5. Critical services ──────────────────────────────────────────────
    local services_ok=true
    for svc in NetworkManager systemd-resolved; do
        if [[ -e "/mnt/etc/systemd/system/multi-user.target.wants/${svc}.service" ]] ||            [[ -e "/mnt/etc/systemd/system/network-online.target.wants/${svc}.service" ]]; then
            ok "Service enabled: ${svc}"
        else
            warn "Service NOT enabled: ${svc}"
            services_ok=false
            issues=$(( issues + 1 ))
        fi
    done

    # ── 6. Hostname ───────────────────────────────────────────────────────
    if [[ -s "/mnt/etc/hostname" ]]; then
        local installed_hostname
        installed_hostname=$(cat /mnt/etc/hostname)
        ok "Hostname set: ${BOLD}${installed_hostname}${NC}"
    else
        warn "Hostname NOT set (/mnt/etc/hostname missing or empty)"
        issues=$(( issues + 1 ))
    fi

    # ── Summary ───────────────────────────────────────────────────────────
    blank
    if (( issues == 0 )); then
        ok "${GREEN}${BOLD}All verification checks passed — installation looks healthy.${NC}"
    else
        warn "${issues} issue(s) found — see warnings above."
        warn "The system may still boot, but review these points before rebooting."
    fi
    blank
}

# =============================================================================
#  SECTION 21 — CLEANUP & REBOOT
# =============================================================================

# ── finish ────────────────────────────────────────────────────────────────────
# Cleans up after the installation and prepares for reboot.
#
# Step by step:
#   rm archwizard-configure.sh  — removes the chroot script from the installed
#                                  system (it served its purpose and contains the
#                                  user's passwords in plaintext; must be deleted).
#   sync                         — flushes all pending I/O to disk. Critical before
#                                  unmounting to ensure nothing is still in the page
#                                  cache. Prevents filesystem corruption on power loss
#                                  during the brief unmount window.
#   swapoff -a                   — deactivates all swap. Required before unmounting
#                                  partitions that back swap devices.
#   umount -R /mnt               — recursively unmounts all filesystems under /mnt
#                                  (root, home, EFI, var/log, var/cache, tmp,
#                                  .snapshots). -R handles the whole tree in one call.
#   cryptsetup close             — closes LUKS containers, removes /dev/mapper/*
#                                  entries. Only when LUKS was used and we're not
#                                  in dry-run (mapper devices don't exist in dry-run).
finish() {
    section "Cleanup"

    run "rm -f /mnt/archwizard-configure.sh"

    info "Unmounting all filesystems…"
    run "sync"
    run "swapoff -a" || true
    run "umount -R /mnt" || true
    if [[ "$USE_LUKS" == true && "$DRY_RUN" == false ]]; then
        cryptsetup close cryptroot  2>/dev/null || true
        cryptsetup close crypthome  2>/dev/null || true
    fi
    ok "All filesystems unmounted"

    blank
    echo -e "${GREEN}${BOLD}"
    echo "  ╔════════════════════════════════════════════════════╗"
    echo "  ║                                                    ║"
    echo "  ║     🎉  ArchWizard installation complete!  🎉     ║"
    echo "  ║                                                    ║"
    echo "  ║   Full log saved to: /tmp/archwizard.log           ║"
    echo "  ║                                                    ║"
    echo "  ║   ➜  Remove installation media                     ║"
    echo "  ║   ➜  Type 'reboot' to boot into Arch Linux         ║"
    echo "  ║                                                    ║"
    echo "  ╚════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    blank
    if confirm "Reboot now?" "y"; then
        run "reboot"
    else
        info "You can reboot manually with: reboot"
        info "Log available at: /tmp/archwizard.log"
    fi
}

# =============================================================================
#  MAIN FLOW
# =============================================================================

# ── main ──────────────────────────────────────────────────────────────────────
# Orchestrates the full installation in 6 phases:
#
#   PHASE 1 — Interactive questionnaire (NO disk changes yet).
#     Every question is asked upfront so the user can review before committing.
#     Answers are stored in global variables (DISK_ROOT, HOSTNAME, DESKTOPS, etc.)
#
#   PHASE 2 — Summary table + final confirmation gate.
#     Shows a full summary of all choices. The user must explicitly type 'yes'
#     before any destructive action begins. This is the last safe exit point.
#
#   PHASE 3 — Partition, encrypt, format, create subvolumes, mount.
#     Destructive. Once this phase starts, the selected disk(s) are modified.
#
#   PHASE 4 — pacstrap + genfstab.
#     Downloads and installs the base system into /mnt.
#     Also optimizes pacman mirrors first (if reflector was selected).
#
#   PHASE 5 — Generate and run the chroot configuration script.
#     Configures timezone, locale, bootloader, users, services, DEs, etc.
#     All of this runs inside the installed system's environment.
#
#   PHASE 6 — Cleanup and reboot.
#     Removes temporary files, unmounts everything, closes LUKS containers,
#     offers to reboot.
main() {
    # ── Argument parsing ─────────────────────────────────────────────────
    local _prev_arg=""
    for arg in "$@"; do
        case "$arg" in
            --dry-run)   DRY_RUN=true ;;
            --verbose)   VERBOSE=true ;;
            --load-config)  : ;;   # next arg will be the file path
            --help|-h)
                echo "Usage: bash archwizard.sh [--dry-run] [--verbose] [--load-config FILE]"
                echo "  --dry-run          Show all commands without executing"
                echo "  --verbose          Print every command as it executes (set -x)"
                echo "  --load-config FILE Load a saved config and skip Phase 1 questions"
                exit 0 ;;
            *)
                if [[ "$_prev_arg" == "--load-config" ]]; then
                    CONFIG_FILE="$arg"
                fi ;;
        esac
        _prev_arg="$arg"
    done

    # Enable verbose trace if requested via flag
    if [[ "$VERBOSE" == true ]]; then
        set -x
    fi

    show_banner
    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN mode: no changes will be written to disk."
    [[ "$VERBOSE" == true ]] && warn "VERBOSE mode: every command will be printed."

    # ── PHASE 1: Gather all information — no disk changes yet ────────────
    if [[ -n "$CONFIG_FILE" ]]; then
        # Skip all Phase 1 questions — load choices from saved config
        sanity_checks   # still run hardware checks + internet test
        load_config "$CONFIG_FILE"
    else
        sanity_checks
        choose_keyboard
        discover_disks
        select_disks
        partition_wizard
        configure_system
        configure_users
        choose_kernel
        choose_bootloader
        choose_desktop
        choose_extras

        # Offer to save the config at the end of Phase 1 (before any disk changes)
        save_config
    fi

    # ── PHASE 2: Summary & confirmation ──────────────────────────────────
    show_summary

    # ── PHASE 3: Free space (delete or shrink) then partition
    replace_partition
    resize_partitions
    create_partitions
    setup_luks
    format_filesystems
    create_subvolumes
    mount_filesystems

    # ── PHASE 4: Install system ───────────────────────────────────────────
    setup_mirrors
    install_base

    # ── PHASE 5: Configure ────────────────────────────────────────────────
    generate_chroot_script
    run_chroot

    # ── PHASE 6: Verify + Done ───────────────────────────────────────────────
    verify_installation
    finish
}

main "$@"
