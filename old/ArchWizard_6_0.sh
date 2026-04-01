#!/usr/bin/env bash
# ArchWizard 6.0 — Arch Linux installer
# Usage: bash ArchWizard_6_0.sh [--dry-run] [--verbose] [--load-config FILE]

set -euo pipefail

# crash: [[ ]] && kills under set -e → always if/then/fi
# crash: empty array under set -u → "${A[@]+"${A[@]}"}"
# crash: passwords never in argv → pipe via stdin
# crash: batch all sgdisk -d, then ONE _refresh_partitions
# crash: delete partitions in reverse number order
# crash: chroot script uses cat >> $S, never sed placeholders (corrupts UUIDs)
# crash: _refresh_partitions → call DIRECTLY, never via run()/eval

trap 'RC=$?; echo "CRASH line=$LINENO exit=$RC cmd=${BASH_COMMAND}" >/tmp/archwizard_crash.txt
      echo -e "\n[ERR] CRASH line=$LINENO exit=$RC cmd=${BASH_COMMAND}" >&2' ERR

LOG_FILE="/tmp/archwizard.log"
exec > >(tee -a "$LOG_FILE") 2>&1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log()     { echo -e "${DIM}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()      { echo -e "${GREEN}${BOLD}[ OK ]${NC}  $*"; }
info()    { echo -e "${CYAN}${BOLD}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}${BOLD}[ERR ]${NC}  $*" >&2; }
section() { echo -e "\n${MAGENTA}${BOLD}━━━  $*  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
ask()     { echo -e -n "${YELLOW}${BOLD}[ ? ]${NC}  $* " >&2; }
blank()   { echo ""; }

# =============================================================================
#  GLOBALS
# =============================================================================
DRY_RUN=false; VERBOSE=false; CONFIG_FILE=""
FIRMWARE_MODE="uefi"; CPU_VENDOR="unknown"; GPU_VENDOR="unknown"

DISK_ROOT=""; DISK_HOME=""
EFI_PART=""; ROOT_PART=""; ROOT_PART_MAPPED=""; HOME_PART=""; SWAP_PART=""
EFI_SIZE_MB=512; ROOT_SIZE=""; HOME_SIZE=""
SEP_HOME=false; DUAL_BOOT=false; REUSE_EFI=false
RESIZE_PART=""; RESIZE_NEW_GB=0; REPLACE_PART=""; FREE_GB_AVAIL=0
REPLACE_PARTS_ALL=(); PROTECTED_PARTS=()
EXISTING_WINDOWS=false; EXISTING_LINUX=false; EXISTING_SYSTEMS=()

ROOT_FS="btrfs"; HOME_FS="btrfs"
USE_LUKS=false; LUKS_PASSWORD=""
SWAP_TYPE="zram"; SWAP_SIZE="8"

HOSTNAME=""; GRUB_ENTRY_NAME=""; USERNAME=""
USER_PASSWORD=""; ROOT_PASSWORD=""
TIMEZONE="UTC"; LOCALE="en_US.UTF-8"; KEYMAP="us"

KERNEL="linux"; BOOTLOADER=""; SECURE_BOOT=false
DESKTOPS=(); AUR_HELPER="none"
USE_REFLECTOR=false; REFLECTOR_COUNTRIES="France,Germany"
REFLECTOR_AGE=12; REFLECTOR_NUMBER=10; REFLECTOR_PROTOCOL="https"
USE_MULTILIB=false; USE_PIPEWIRE=false; USE_NVIDIA=false
USE_AMD_VULKAN=false; USE_BLUETOOTH=false; USE_CUPS=false
USE_SNAPPER=false; FIREWALL="none"

# =============================================================================
#  CORE HELPERS
# =============================================================================

# part_name disk num → /dev/nvme0n1p1 or /dev/sda1
part_name() {
    local disk="$1" num="$2"
    if [[ "$disk" == *"nvme"* || "$disk" == *"mmcblk"* ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

confirm() {
    local msg="$1" default="${2:-n}" prompt ans
    [[ "$default" == "y" ]] && prompt="[Y/n]" || prompt="[y/N]"
    ask "$msg $prompt"; read -r ans
    case "${ans:-$default}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

select_option() {
    local prompt="$1"; shift; local options=("$@")
    blank; echo -e "${YELLOW}${BOLD}[ ? ]${NC}  $prompt"
    for i in "${!options[@]}"; do
        echo -e "      ${BOLD}$((i+1)))${NC} ${options[$i]}"
    done
    while true; do
        ask "Enter choice [1-${#options[@]}]:"; read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            REPLY="${options[$((choice-1))]}"; return 0
        fi
        warn "Invalid. Enter 1–${#options[@]}."
    done
}

get_input() {
    local prompt="$1" default="${2:-}" ans
    if [[ -n "$default" ]]; then ask "$prompt [${CYAN}${default}${NC}]:"
    else ask "$prompt:"; fi
    read -r ans; echo "${ans:-$default}"
}

get_password() {
    local prompt="$1" pass confirm_pass
    while true; do
        ask "$prompt:"; read -rs pass; echo >&2
        ask "Confirm:"; read -rs confirm_pass; echo >&2
        if [[ "$pass" == "$confirm_pass" && -n "$pass" ]]; then echo "$pass"; return; fi
        warn "Passwords don't match or empty."
    done
}

# run — wraps ALL destructive commands; eval handles dynamic strings
run() {
    if [[ "$DRY_RUN" == true ]]; then echo -e "${DIM}[DRY-RUN]${NC} $*"
    else log "CMD: $*"; eval "$@"; fi
}

# run_interactive — parted resize only; exec redirects restore /dev/tty
# needed because top-level tee pipe breaks interactive read() in parted
run_interactive() {
    if [[ "$DRY_RUN" == true ]]; then echo -e "${DIM}[DRY-RUN]${NC} $*"
    else log "CMD (interactive): $*"; eval "$@" </dev/tty >/dev/tty 2>/dev/tty; fi
}

# _refresh_partitions — NEVER call via run()/eval; shell fn can't survive eval subshell
_refresh_partitions() {
    local disk="$1" attempt
    for attempt in 1 2 3; do
        if partprobe "$disk" 2>/dev/null; then sleep 1; ok "Kernel partition table updated"; return 0; fi
        warn "partprobe attempt ${attempt}/3 — retrying in 2s…"; sleep 2
    done
    if partx -u "$disk" 2>/dev/null; then sleep 1; ok "Kernel partition table updated via partx"; return 0; fi
    udevadm settle 2>/dev/null || true; sleep 3
    warn "Could not confirm kernel saw partition changes — continuing."
}

# probe_os_from_part — sets PROBE_OS_RESULT; order: LUKS→NTFS→mount→btrfs subvols→label
PROBE_OS_RESULT=""
probe_os_from_part() {
    local p="$1"; PROBE_OS_RESULT=""
    local fstype; fstype=$(blkid -s TYPE -o value "$p" 2>/dev/null || echo "")
    if [[ "$fstype" == "crypto_LUKS" ]]; then PROBE_OS_RESULT="[encrypted]"; return 0; fi
    if [[ "$fstype" == "ntfs" ]]; then
        local lbl; lbl=$(blkid -s LABEL -o value "$p" 2>/dev/null || echo "")
        PROBE_OS_RESULT="${lbl:-Windows}"; return 0
    fi
    local _mnt="/tmp/archwizard_probe_$$"; mkdir -p "$_mnt"
    _osrel() {
        local m="$1"
        [[ -f "$m/etc/os-release" ]] || return 0
        local n; n=$(grep '^PRETTY_NAME=' "$m/etc/os-release" | cut -d= -f2- | tr -d '"' | head -1)
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
    PROBE_OS_RESULT="${lbl:-Linux (${fstype:-unknown})}"; return 0
}

_is_protected() {
    local p="$1" pp
    for pp in "${PROTECTED_PARTS[@]+"${PROTECTED_PARTS[@]}"}"; do
        [[ "$pp" == "$p" ]] && return 0
    done
    return 1
}

# =============================================================================
#  PHASE 1 — QUESTIONNAIRE (no disk writes)
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
    echo -e "${NC}${BOLD}         ArchWizard 6.0 — Arch Linux Installer${NC}"
    echo -e "${DIM}         log: $LOG_FILE  |  usage: bash ArchWizard_6_0.sh [--dry-run] [--verbose] [--load-config FILE]${NC}\n"
}

sanity_checks() {
    section "Pre-flight Checks"
    [[ $EUID -ne 0 ]] && { error "Must run as root."; exit 1; }
    ok "Running as root"

    if [[ -d /sys/firmware/efi/efivars ]]; then
        FIRMWARE_MODE="uefi"; ok "Firmware: UEFI"
    else
        FIRMWARE_MODE="bios"
        warn "Firmware: BIOS/Legacy — GRUB+MBR; systemd-boot and Secure Boot unavailable."
    fi

    if ! ping -c1 -W3 8.8.8.8 &>/dev/null && ! ping -c1 -W3 1.1.1.1 &>/dev/null; then
        warn "No internet detected."
        local wifi_ifaces=()
        while IFS= read -r iface; do [[ -n "$iface" ]] && wifi_ifaces+=("$iface"); done \
            < <(iw dev 2>/dev/null | awk '/Interface/{print $2}' || true)
        if [[ ${#wifi_ifaces[@]} -gt 0 ]]; then
            info "WiFi detected: ${wifi_ifaces[*]}"
            info "  device list → station ${wifi_ifaces[0]} scan → connect \"SSID\""
            if confirm "Open iwctl now?" "y"; then
                iwctl </dev/tty >/dev/tty 2>/dev/tty || true; sleep 3
                if ping -c1 -W5 8.8.8.8 &>/dev/null || ping -c1 -W5 1.1.1.1 &>/dev/null; then
                    ok "Internet connected via WiFi"
                else
                    error "Still no connectivity."; exit 1
                fi
            else
                info "Connect manually then re-run."; exit 1
            fi
        else
            error "No internet and no WiFi interface."; exit 1
        fi
    else
        ok "Internet OK"
    fi

    local missing=() tools=(sgdisk mkfs.fat mkfs.btrfs arch-chroot pacstrap genfstab blkid lsblk)
    for t in "${tools[@]}"; do command -v "$t" &>/dev/null || missing+=("$t"); done
    if [[ ${#missing[@]} -gt 0 ]]; then error "Missing: ${missing[*]}"; exit 1; fi
    ok "All tools present"

    if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then CPU_VENDOR="intel"
    elif grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then CPU_VENDOR="amd"; fi
    ok "CPU: $CPU_VENDOR"

    if lspci 2>/dev/null | grep -qi "nvidia"; then GPU_VENDOR="nvidia"
    elif lspci 2>/dev/null | grep -qi "amd.*vga\|vga.*amd\|radeon"; then GPU_VENDOR="amd"
    elif lspci 2>/dev/null | grep -qi "intel.*vga\|vga.*intel"; then GPU_VENDOR="intel"; fi
    ok "GPU: $GPU_VENDOR"

    timedatectl set-ntp true &>/dev/null & disown
    ok "NTP requested"
}

choose_keyboard() {
    section "Keyboard Layout"
    info "Common: us  uk  fr-latin1  de-latin1  es  it  (French → fr-latin1 not fr)"
    KEYMAP=$(get_input "Keymap" "fr-latin1")
    if find /usr/share/kbd/keymaps -name "${KEYMAP}.map.gz" -o -name "${KEYMAP}.map" 2>/dev/null | grep -q .; then
        run "loadkeys $KEYMAP"; ok "Keymap: $KEYMAP"
    else
        warn "'$KEYMAP' not found — falling back to 'us'."; KEYMAP="us"; run "loadkeys us"
    fi
}

discover_disks() {
    section "Disk Discovery"
    blank
    echo -e "  ${BOLD}┌──────────────────────────────────────────────────────────────────┐${NC}"
    printf "  │  %-12s %-8s %-6s %-6s %-5s  %-20s│\n" "DEVICE" "SIZE" "TYPE" "TRAN" "TABLE" "MODEL"
    echo -e "  ${BOLD}├──────────────────────────────────────────────────────────────────┤${NC}"
    while IFS= read -r dev; do
        local name size rota tran pttype model media col
        name=$(lsblk -dno NAME   "/dev/${dev}" 2>/dev/null)
        size=$(lsblk -dno SIZE   "/dev/${dev}" 2>/dev/null)
        rota=$(lsblk -dno ROTA   "/dev/${dev}" 2>/dev/null)
        tran=$(lsblk -dno TRAN   "/dev/${dev}" 2>/dev/null)
        pttype=$(lsblk -dno PTTYPE "/dev/${dev}" 2>/dev/null)
        model=$(lsblk -dno MODEL  "/dev/${dev}" 2>/dev/null | cut -c1-20)
        if   [[ "$tran" == "nvme" ]]; then media="NVMe"; col="$GREEN"
        elif [[ "$rota" == "0"   ]]; then media="SSD";  col="$GREEN"
        elif [[ "$tran" == "usb" ]]; then media="USB";  col="$DIM"
        else                              media="HDD";  col="$YELLOW"; fi
        printf "  │  ${col}${BOLD}%-12s${NC} %-8s ${col}%-6s${NC} %-6s %-5s  %-20s│\n" \
            "/dev/${name}" "${size}" "${media}" "${tran:-—}" "${pttype:-—}" "${model:-Unknown}"
    done < <(lsblk -d -n -o NAME 2>/dev/null | grep -v "^loop\|^sr")
    echo -e "  ${BOLD}└──────────────────────────────────────────────────────────────────┘${NC}"
    blank

    info "Existing partitions:"
    while IFS= read -r dev; do
        local has_parts; has_parts=$(lsblk -n -o NAME "/dev/${dev}" 2>/dev/null | tail -n +2)
        if [[ -n "$has_parts" ]]; then
            echo -e "  ${CYAN}${BOLD}/dev/${dev}${NC}"
            lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "/dev/${dev}" 2>/dev/null \
                | tail -n +2 | while IFS= read -r line; do echo "    $line"; done
            blank
        fi
    done < <(lsblk -d -n -o NAME 2>/dev/null | grep -v "^loop\|^sr")

    # OS detection
    local _mounted_devs; _mounted_devs=$(awk '{print $1}' /proc/mounts 2>/dev/null | sort -u)
    local _candidates=()
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        echo "$_mounted_devs" | grep -qxF "$p" && continue
        [[ "$p" == /dev/loop* || "$p" == /dev/sr* ]] && continue
        local _pb; _pb=$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)
        (( _pb < 1073741824 )) && continue
        _candidates+=("$p")
    done < <({ blkid -t TYPE="ext4" -t TYPE="btrfs" -t TYPE="xfs" \
               -t TYPE="f2fs" -t TYPE="crypto_LUKS" -o device 2>/dev/null; } | sort -u)

    local _found_names=() _found_parts=()
    for p in "${_candidates[@]}"; do
        probe_os_from_part "$p" || true
        if [[ -n "$PROBE_OS_RESULT" ]]; then
            _found_names+=("$PROBE_OS_RESULT"); _found_parts+=("$p")
        fi
    done

    # NVRAM supplement (filter firmware/boot-manager noise)
    local _bl="BootManager|BootApp|EFI Default|^Windows|ArchWizard|^UEFI[[:space:]]|^UEFI:"
    _bl+="|Firmware|Setup|Admin|^Shell|^EFI Shell|PXE|iPXE|Network|LAN|WAN"
    _bl+="|Diagnostic|MemTest|USB|CD-ROM|DVD|Optical|SD Card|Recovery|Maintenance"
    if command -v efibootmgr &>/dev/null; then
        while IFS= read -r line; do
            local _lbl
            _lbl=$(echo "$line" | sed 's/Boot[0-9A-Fa-f]*\*[[:space:]]*//' \
                   | sed 's/[[:space:]]*[A-Z][A-Z](.*$//' | sed 's/[[:space:]]*$//')
            [[ -z "$_lbl" || ${#_lbl} -lt 2 ]] && continue
            echo "$_lbl" | grep -q '[a-zA-Z]' || continue
            echo "$_lbl" | grep -qiE "$_bl" && continue
            echo "$_lbl" | grep -qi "windows" && continue
            local _seen=false
            for n in "${_found_names[@]}"; do
                echo "$n" | grep -qi "$_lbl" && _seen=true && break
            done
            if [[ "$_seen" == false ]]; then _found_names+=("$_lbl"); _found_parts+=(""); fi
        done < <(efibootmgr 2>/dev/null | grep -E '^Boot[0-9A-Fa-f]{4}' || true)
    fi

    # NTFS / Windows
    while IFS= read -r p; do
        [[ -n "$p" ]] && _found_names+=("Windows") && _found_parts+=("$p")
    done < <(blkid -t TYPE="ntfs" -o device 2>/dev/null || true)

    if [[ ${#_found_names[@]} -gt 0 ]]; then
        blank; warn "Existing OS(es) detected:"
        for i in "${!_found_names[@]}"; do
            local _pinfo=""
            if [[ -n "${_found_parts[$i]}" ]]; then
                local _psize; _psize=$(lsblk -dno SIZE "${_found_parts[$i]}" 2>/dev/null || echo "?")
                _pinfo="  ${DIM}(${_found_parts[$i]}, ${_psize})${NC}"
            fi
            echo -e "    ${CYAN}${BOLD}→ ${_found_names[$i]}${NC}${_pinfo}"
        done
        blank
        if confirm "Install Arch alongside these system(s)?" "y"; then
            DUAL_BOOT=true
            for n in "${_found_names[@]}"; do
                echo "$n" | grep -qi "windows" && EXISTING_WINDOWS=true || EXISTING_LINUX=true
                EXISTING_SYSTEMS+=("$n")
            done
            ok "Multi-boot enabled — existing partitions preserved"
            info "GRUB + os-prober strongly recommended."
        fi
    fi

    # EFI detection for multi-boot
    if [[ "$DUAL_BOOT" == true ]]; then
        local efi_list=()
        while IFS= read -r p; do
            local pttype_p size_mb
            pttype_p=$(lsblk -no PARTTYPE "$p" 2>/dev/null || echo "")
            size_mb=$(( $(blockdev --getsize64 "$p" 2>/dev/null || echo 0) / 1048576 ))
            if [[ "$pttype_p" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] || (( size_mb <= 1024 )); then
                efi_list+=("$p")
            fi
        done < <(blkid -t TYPE="vfat" -o device 2>/dev/null || true)

        if [[ ${#efi_list[@]} -gt 0 ]]; then
            info "EFI partition(s): ${efi_list[*]}"
            if [[ ${#efi_list[@]} -eq 1 ]]; then
                EFI_PART="${efi_list[0]}"; REUSE_EFI=true
                ok "Using existing EFI: $EFI_PART"
            else
                if confirm "Reuse existing EFI partition? (strongly recommended)" "y"; then
                    REUSE_EFI=true
                    select_option "Which EFI partition?" "${efi_list[@]}"
                    EFI_PART="$REPLY"
                    ok "Will reuse EFI: $EFI_PART"
                fi
            fi
        fi
    fi
}

_check_and_plan_space() {
    local disk="$1"; local NEEDED_GB=7
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

    section "Space Analysis — $disk"
    info "Unallocated: ${free_gb} GB  |  Minimum needed: ${NEEDED_GB} GB"
    if [[ ${#disposable_parts[@]} -gt 0 ]]; then
        info "Reclaimable (unneeded): ${disposable_gb} GB  (${disposable_parts[*]})"
        info "Total available: ${total_avail_gb} GB"
    fi
    blank

    if (( free_gb >= NEEDED_GB )); then
        ok "Sufficient unallocated space."; blank; return
    fi

    if (( total_avail_gb >= NEEDED_GB && ${#disposable_parts[@]} > 0 )); then
        ok "Enough space by deleting unneeded partitions."
        for p in "${disposable_parts[@]}"; do
            probe_os_from_part "$p" || true
            local _s; _s=$(lsblk -dno SIZE "$p" 2>/dev/null || echo "?")
            warn "  Will DELETE: $p  (${_s})  — ${PROBE_OS_RESULT:-partition}"
        done
        REPLACE_PART="${disposable_parts[0]}"
        REPLACE_PARTS_ALL=("${disposable_parts[@]}")
        FREE_GB_AVAIL=$total_avail_gb
        warn "Deletions happen after Phase 2 confirmation."; blank; return
    fi

    warn "Not enough space (${total_avail_gb} GB < ${NEEDED_GB} GB)."
    blank; lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$disk" 2>/dev/null \
        | while IFS= read -r line; do echo "    $line"; done; blank

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
        local os_n="${PROBE_OS_RESULT}"
        [[ "$ft" == "swap" ]] && os_n="[swap]"
        candidates+=("$p|$ft|$pb_gb|${os_n}")
    done < <(lsblk -ln -o PATH "$disk" 2>/dev/null | tail -n +2)

    if [[ ${#candidates[@]} -eq 0 ]]; then
        warn "All partitions marked 'keep' — must shrink one to make space."
        for _pp in "${PROTECTED_PARTS[@]+"${PROTECTED_PARTS[@]}"}"; do
            local _ft _pb_gb
            _ft=$(blkid -s TYPE -o value "$_pp" 2>/dev/null || echo "?")
            _pb_gb=$(( $(blockdev --getsize64 "$_pp" 2>/dev/null || echo 0) / 1073741824 ))
            candidates+=("$_pp|$_ft|$_pb_gb|[kept OS]")
        done
    fi

    if [[ ${#candidates[@]} -eq 0 ]]; then
        warn "No suitable partitions. Use GParted live to free space."; FREE_GB_AVAIL=0; return 0
    fi

    local other_disks=()
    while IFS= read -r dev; do
        [[ "/dev/$dev" == "$disk" ]] && continue
        local ob; ob=$(blockdev --getsize64 "/dev/$dev" 2>/dev/null || echo 0)
        [[ $(( ob / 1073741824 )) -ge $NEEDED_GB ]] && other_disks+=("/dev/$dev")
    done < <(lsblk -d -n -o NAME 2>/dev/null | grep -v "^loop\|^sr")

    local space_opts=()
    [[ ${#other_disks[@]} -gt 0 ]] && space_opts+=("Use a different disk entirely")
    local _has_unprotected=false
    for _c in "${candidates[@]}"; do
        local _cp="${_c%%|*}"
        if ! _is_protected "$_cp"; then _has_unprotected=true; break; fi
    done
    if [[ "$_has_unprotected" == true ]]; then
        space_opts+=("Replace a partition (delete — ALL DATA LOST)")
    fi
    space_opts+=("Shrink a partition (keep data)")
    select_option "How to make space:" "${space_opts[@]}"
    local space_choice="$REPLY"

    if [[ "$space_choice" == "Use a different disk entirely" ]]; then
        local alt_list=()
        for d in "${other_disks[@]}"; do
            local dsz dm; dsz=$(lsblk -dno SIZE "$d" 2>/dev/null)
            dm=$(lsblk -dno MODEL "$d" 2>/dev/null | cut -c1-28)
            alt_list+=("$(printf '%s  %-6s  %s' "$d" "$dsz" "$dm")")
        done
        select_option "Select disk for Arch root:" "${alt_list[@]}"
        DISK_ROOT=$(echo "$REPLY" | awk '{print $1}')
        FREE_GB_AVAIL=$(( $(blockdev --getsize64 "$DISK_ROOT" 2>/dev/null || echo 0) / 1073741824 ))
        ok "Arch on $DISK_ROOT (${FREE_GB_AVAIL} GB)"; return
    fi

    local cand_labels=()
    for c in "${candidates[@]}"; do
        local cp="${c%%|*}" rest="${c#*|}"
        local cf="${rest%%|*}" rest2="${rest#*|}"
        local csz="${rest2%%|*}" con="${rest2##*|}"
        local lbl; lbl="$(printf '%-14s  [%-10s]  %s GB' "$cp" "$cf" "$csz")"
        [[ -n "$con" ]] && lbl+="  (${con})"
        cand_labels+=("$lbl")
    done

    if [[ "$space_choice" == Replace* ]]; then
        select_option "Partition to DELETE (ALL DATA LOST):" "${cand_labels[@]}"
        REPLACE_PART=$(echo "$REPLY" | awk '{print $1}')
        local rep_gb; rep_gb=$(( $(blockdev --getsize64 "$REPLACE_PART" 2>/dev/null || echo 0) / 1073741824 ))
        FREE_GB_AVAIL=$(( free_gb + rep_gb ))
        warn "PLAN: DELETE $REPLACE_PART (${rep_gb} GB) — frees ${FREE_GB_AVAIL} GB total"
        warn "Deletion happens after Phase 2 confirmation."; blank; return
    fi

    # Shrink
    local shrink_labels=() shrink_map=()
    for c in "${candidates[@]}"; do
        local cp="${c%%|*}" rest="${c#*|}"; local cf="${rest%%|*}" rest2="${rest#*|}"; local csz="${rest2%%|*}" con="${rest2##*|}"
        if [[ "$cf" == "xfs" ]]; then echo -e "  ${YELLOW}→ ${cp} [xfs] — cannot shrink${NC}"; continue; fi
        if [[ "$cf" == "crypto_LUKS" ]]; then echo -e "  ${YELLOW}→ ${cp} [LUKS] — cannot shrink${NC}"; continue; fi
        [[ "$cf" == "swap" ]] && continue; (( csz < 5 )) && continue
        local lbl; lbl="$(printf '%-14s  [%-10s]  %s GB' "$cp" "$cf" "$csz")"
        [[ -n "$con" ]] && lbl+="  — ${con}"
        shrink_labels+=("$lbl"); shrink_map+=("$cp|$cf|$csz")
    done

    if [[ ${#shrink_labels[@]} -eq 0 ]]; then
        warn "No shrinkable partitions."; FREE_GB_AVAIL=0; return 0
    fi

    select_option "Partition to SHRINK:" "${shrink_labels[@]}"
    local sel_idx=0
    for item in "${shrink_labels[@]}"; do [[ "$item" == "$REPLY" ]] && break; sel_idx=$(( sel_idx + 1 )); done
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
            min_safe_gb=$(( ((${bsz:-4096} * ${ucnt:-0}) / 1048576 * 12 / 10) / 1024 + 1 )) ;;
        btrfs)
            local used_b
            used_b=$(btrfs filesystem usage -b "$RESIZE_PART" 2>/dev/null | awk '/Used:/{print $2}' | head -1 || echo 0)
            min_safe_gb=$(( (${used_b:-0} * 12 / 10) / 1073741824 + 2 )) ;;
    esac

    info "Partition: $RESIZE_PART  [${rft}]  current: ${rsize_gb} GB  |  min safe: ${min_safe_gb} GB"
    local new_gb
    while true; do
        ask "New size in GB [min: ${min_safe_gb}, max: $(( rsize_gb - 1 ))]:"; read -r new_gb
        if [[ "$new_gb" =~ ^[0-9]+$ ]] && (( new_gb >= min_safe_gb && new_gb < rsize_gb )); then break; fi
        warn "Enter ${min_safe_gb}–$(( rsize_gb - 1 ))."
    done
    RESIZE_NEW_GB=$new_gb
    FREE_GB_AVAIL=$(( free_gb + rsize_gb - new_gb ))
    ok "Plan: shrink $RESIZE_PART → ${new_gb} GB  (frees $(( rsize_gb - new_gb )) GB  |  total: ${FREE_GB_AVAIL} GB)"
    warn "Resize happens after Phase 2 confirmation."; blank
}

select_disks() {
    section "Select Disks"
    local disk_list=()
    while IFS= read -r dev; do
        local size rota tran model media
        size=$(lsblk  -dno SIZE  "/dev/${dev}" 2>/dev/null); rota=$(lsblk -dno ROTA "/dev/${dev}" 2>/dev/null)
        tran=$(lsblk  -dno TRAN  "/dev/${dev}" 2>/dev/null); model=$(lsblk -dno MODEL "/dev/${dev}" 2>/dev/null | cut -c1-28)
        if [[ "$tran" == "nvme" ]]; then media="NVMe"
        elif [[ "$rota" == "0" ]]; then media="SSD"
        elif [[ "$tran" == "usb" ]]; then media="USB"
        else media="HDD"; fi
        disk_list+=("$(printf '/dev/%-10s  %-5s  %-5s  %s' "$dev" "$size" "$media" "$model")")
    done < <(lsblk -d -n -o NAME 2>/dev/null | grep -v "^loop\|^sr")
    [[ ${#disk_list[@]} -eq 0 ]] && { error "No disks found!"; exit 1; }

    select_option "Select disk for ROOT (/):" "${disk_list[@]}"
    DISK_ROOT=$(echo "$REPLY" | awk '{print $1}'); DISK_HOME="$DISK_ROOT"

    local root_gb; root_gb=$(( $(blockdev --getsize64 "$DISK_ROOT" 2>/dev/null || echo 0) / 1073741824 ))
    if (( root_gb < 15 )); then
        warn "$DISK_ROOT is only ${root_gb} GB — recommended ≥20 GB."
        confirm "Continue anyway?" "n" || { info "Aborted."; exit 0; }
    fi

    if [[ "$DUAL_BOOT" == false ]]; then
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
            blank; warn "Existing OS(es) on $DISK_ROOT:"
            for entry in "${_guard_found[@]}"; do
                local _en="${entry%%|*}" _ep="${entry##*|}"
                echo -e "    ${CYAN}${BOLD}→ ${_en}${NC}  ${DIM}(${_ep}, $(lsblk -dno SIZE "$_ep" 2>/dev/null || echo ?))${NC}"
            done
            blank
            local _any_kept=false
            for entry in "${_guard_found[@]}"; do
                local _en="${entry%%|*}" _ep="${entry##*|}"
                blank; echo -e "  ${CYAN}${BOLD}[$_en]${NC}  ${DIM}${_ep}${NC}"
                if confirm "  Keep ${BOLD}${_en}${NC}? (No = available for deletion)" "y"; then
                    EXISTING_SYSTEMS+=("$_en"); PROTECTED_PARTS+=("$_ep")
                    echo "$_en" | grep -qi "windows" && EXISTING_WINDOWS=true || EXISTING_LINUX=true
                    ok "  $_en → PRESERVED"; _any_kept=true
                else
                    warn "  $_en → available for deletion"
                fi
            done
            blank
            if [[ "$_any_kept" == true ]]; then
                DUAL_BOOT=true
                local _sys_str; _sys_str=$(IFS=', '; echo "${EXISTING_SYSTEMS[*]}")
                ok "Multi-boot — preserving: $_sys_str"
                _check_and_plan_space "$DISK_ROOT"
            else
                warn "No OS kept — entire disk will be wiped."
                confirm "${RED}${BOLD}I understand — erase everything on $DISK_ROOT${NC}" "n" || { info "Aborted."; exit 0; }
            fi
        else
            info "No existing OS on $DISK_ROOT — fresh install."
        fi
    fi

    DISK_HOME="$DISK_ROOT"
    if [[ ${#disk_list[@]} -gt 1 ]]; then
        blank
        if confirm "Put /home on a different disk?" "n"; then
            select_option "Select disk for /home:" "${disk_list[@]}"
            DISK_HOME=$(echo "$REPLY" | awk '{print $1}')
            ok "Home disk: $DISK_HOME"
        fi
    fi

    blank
    warn "╔═══════════════════════════════════════════════════════════╗"
    warn "  DISKS TO BE MODIFIED:"
    warn "    Root : $DISK_ROOT"
    [[ "$DISK_HOME" != "$DISK_ROOT" ]] && warn "    Home : $DISK_HOME"
    if [[ "$DUAL_BOOT" == true ]]; then
        local sl; sl=$(IFS=', '; echo "${EXISTING_SYSTEMS[*]}")
        warn "  Mode : multi-boot — keep: $sl"
    else
        warn "  Mode : fresh install (ENTIRE DISK WIPED)"
    fi
    warn "╚═══════════════════════════════════════════════════════════╝"; blank
}

partition_wizard() {
    section "Partition Layout"
    local disk_bytes disk_gb avail_gb
    disk_bytes=$(blockdev --getsize64 "$DISK_ROOT" 2>/dev/null || echo 0)
    disk_gb=$(( disk_bytes / 1073741824 ))
    if [[ "$DUAL_BOOT" == true ]]; then
        avail_gb=$(( FREE_GB_AVAIL > 0 ? FREE_GB_AVAIL : disk_gb / 2 ))
        [[ "$FREE_GB_AVAIL" -eq 0 ]] && warn "Space budget unknown — using conservative estimate: ${avail_gb} GB"
    else
        avail_gb=$disk_gb
    fi

    _get_gb() {
        local prompt="$1" default="$2" max="$3" val
        while true; do
            val=$(get_input "$prompt" "$default")
            if [[ "$val" == "rest" ]]; then GB_RESULT="rest"; return; fi
            if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 1 && val <= max )); then GB_RESULT="$val"; return; fi
            warn "Enter 1–${max} or 'rest'."
        done
    }

    # EFI
    section "EFI Partition"
    if [[ "$FIRMWARE_MODE" == "bios" ]]; then
        info "BIOS mode — no EFI partition needed."
    elif [[ "$DUAL_BOOT" == true ]]; then
        if [[ "$REUSE_EFI" == false || -z "$EFI_PART" ]]; then
            local _esp_found=""
            while IFS= read -r p; do
                [[ -z "$p" ]] && continue
                local _ept _esz
                _ept=$(lsblk -no PARTTYPE "$p" 2>/dev/null || echo "")
                _esz=$(( $(blockdev --getsize64 "$p" 2>/dev/null || echo 0) / 1048576 ))
                if [[ "$_ept" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] \
                   || [[ "$(blkid -s TYPE -o value "$p" 2>/dev/null)" == "vfat" && $_esz -le 1024 ]]; then
                    _esp_found="$p"; break
                fi
            done < <(lsblk -ln -o PATH "$DISK_ROOT" 2>/dev/null | tail -n +2)
            if [[ -n "$_esp_found" ]]; then
                EFI_PART="$_esp_found"; REUSE_EFI=true; ok "Found ESP: $EFI_PART — reusing"
            else
                warn "No ESP found — will create 512 MB EFI partition."; EFI_SIZE_MB=512; REUSE_EFI=false
            fi
        else
            ok "Reusing EFI: $EFI_PART  ($(lsblk -dno SIZE "$EFI_PART" 2>/dev/null || echo ?))"
        fi
        info "Available for Arch: ${avail_gb} GB"
    else
        info "Disk: $DISK_ROOT — total: ${disk_gb} GB"
        EFI_SIZE_MB=$(get_input "EFI size (MB)" "512")
        avail_gb=$(( avail_gb - 1 ))
        info "Remaining after EFI: ~${avail_gb} GB"
    fi
    blank

    # Layout strategy
    section "Layout"
    info "Available: ${avail_gb} GB"
    blank
    SEP_HOME=false
    local layout_choice
    if [[ "$DISK_HOME" != "$DISK_ROOT" ]]; then
        SEP_HOME=true; layout_choice="split_disk"
        info "Separate home: $DISK_HOME"
    else
        echo -e "  ${BOLD}1)${NC} /             — root takes all space"
        echo -e "  ${BOLD}2)${NC} / + /home     — recommended"
        echo -e "  ${BOLD}3)${NC} / + /home + swap — explicit swap partition"
        blank; ask "Layout [1-3] (default: 2):"; read -r layout_raw
        case "${layout_raw:-2}" in
            1) layout_choice="root_only" ;; 3) layout_choice="root_home_swap" ;; *) layout_choice="root_home" ;;
        esac
    fi

    local root_max=$(( avail_gb - 1 ))
    case "$layout_choice" in
        root_only)
            if confirm "Use all ${avail_gb} GB for /?" "y"; then ROOT_SIZE="rest"
            else _get_gb "Root (/) GB" "$avail_gb" "$root_max"; ROOT_SIZE="$GB_RESULT"; fi ;;
        root_home|root_home_swap)
            local suggested=40
            (( avail_gb < 60  )) && suggested=25; (( avail_gb < 30 )) && suggested=15
            (( avail_gb < 15  )) && suggested=$(( avail_gb * 6 / 10 ))
            (( avail_gb > 100 )) && suggested=60
            info "Suggested root: ${suggested} GB  (remaining → /home)"
            _get_gb "Root (/) GB" "$suggested" "$(( avail_gb - 4 ))"
            ROOT_SIZE="$GB_RESULT"; avail_gb=$(( avail_gb - ROOT_SIZE ))
            info "Remaining for /home: ${avail_gb} GB"; SEP_HOME=true
            if confirm "Give all ${avail_gb} GB to /home?" "y"; then HOME_SIZE="rest"
            else _get_gb "Home (/home) GB" "$avail_gb" "$avail_gb"; HOME_SIZE="$GB_RESULT"; fi ;;
        split_disk)
            local root_default=60
            (( avail_gb < 80 )) && root_default=40; (( avail_gb < 40 )) && root_default=20
            _get_gb "Root (/) GB on $DISK_ROOT" "$root_default" "$root_max"
            ROOT_SIZE="$GB_RESULT"
            local home_gb; home_gb=$(( $(blockdev --getsize64 "$DISK_HOME" 2>/dev/null || echo 0) / 1073741824 ))
            info "Home disk $DISK_HOME: ${home_gb} GB"
            if confirm "Give all ${home_gb} GB to /home?" "y"; then HOME_SIZE="rest"
            else _get_gb "Home (/home) GB" "$home_gb" "$home_gb"; HOME_SIZE="$GB_RESULT"; fi ;;
    esac
    ok "root=${ROOT_SIZE} GB${SEP_HOME:+  |  home=${HOME_SIZE} GB}"
    blank

    # Filesystem
    section "Filesystem"
    echo -e "  ${BOLD}1)${NC} btrfs  ${DIM}snapshots, compression, CoW${NC}"
    echo -e "  ${BOLD}2)${NC} ext4   ${DIM}rock-solid, most compatible${NC}"
    echo -e "  ${BOLD}3)${NC} xfs    ${DIM}high-perf large files (cannot shrink)${NC}"
    echo -e "  ${BOLD}4)${NC} f2fs   ${DIM}optimised for NVMe/SSD${NC}"
    blank; ask "Root FS [1-4] (default: 1):"; read -r fs_choice
    case "${fs_choice:-1}" in
        2) ROOT_FS="ext4" ;; 3) ROOT_FS="xfs" ;; 4) ROOT_FS="f2fs" ;; *) ROOT_FS="btrfs" ;;
    esac
    ok "Root FS: $ROOT_FS"
    [[ "$ROOT_FS" != "btrfs" ]] && info "Note: Snapper requires btrfs."

    HOME_FS="$ROOT_FS"
    if [[ "$SEP_HOME" == true ]]; then
        info "Home FS (default: same as root — $ROOT_FS):"
        echo -e "  1) same  2) btrfs  3) ext4  4) xfs  5) f2fs"
        ask "Home FS [1-5] (default: 1):"; read -r hfs_choice
        case "${hfs_choice:-1}" in
            2) HOME_FS="btrfs" ;; 3) HOME_FS="ext4" ;; 4) HOME_FS="xfs" ;; 5) HOME_FS="f2fs" ;; *) HOME_FS="$ROOT_FS" ;;
        esac
        ok "Home FS: $HOME_FS"
    fi

    # Swap
    section "Swap"
    local ram_kb ram_gb rec_swap
    ram_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}'); ram_gb=$(( ${ram_kb:-0} / 1048576 ))
    if   (( ram_gb >= 32 )); then rec_swap="0"
    elif (( ram_gb >= 16 )); then rec_swap="4"
    elif (( ram_gb >=  8 )); then rec_swap="8"
    else rec_swap="$(( ram_gb * 2 ))"; fi
    info "RAM: ${ram_gb} GB  |  Recommended swap: ${rec_swap} GB"
    echo -e "  ${BOLD}1)${NC} zram          ${DIM}compressed RAM, fastest${NC}"
    echo -e "  ${BOLD}2)${NC} Swap file     ${DIM}supports hibernation${NC}"
    echo -e "  ${BOLD}3)${NC} Swap partition${DIM}dedicated partition${NC}"
    echo -e "  ${BOLD}4)${NC} None"
    blank; ask "Swap [1-4] (default: 1):"; read -r swap_choice
    local sw_def="${rec_swap//[^0-9]/8}"; (( ${sw_def:-0} < 1 )) && sw_def=4
    case "${swap_choice:-1}" in
        2) SWAP_TYPE="file";      _get_gb "Swap file GB"      "$sw_def" "$(( disk_gb / 4 ))"; SWAP_SIZE="$GB_RESULT" ;;
        3) SWAP_TYPE="partition"; _get_gb "Swap partition GB"  "$sw_def" "$(( disk_gb / 4 ))"; SWAP_SIZE="$GB_RESULT" ;;
        4) SWAP_TYPE="none" ;;
        *) SWAP_TYPE="zram" ;;
    esac
    ok "Swap: $SWAP_TYPE${SWAP_SIZE:+ (${SWAP_SIZE} GB)}"

    # LUKS
    section "Encryption"
    if confirm "Enable LUKS2 full-disk encryption?" "n"; then
        USE_LUKS=true
        warn "Passphrase required at EVERY boot — do not lose it."
        LUKS_PASSWORD=$(get_password "LUKS passphrase")
        ok "LUKS2 enabled"
    fi

    # Layout preview
    blank; info "Planned layout for $DISK_ROOT:"
    echo -e "  ${BOLD}┌────────────────────────────────────────────────────┐${NC}"
    if [[ "$REUSE_EFI" == true ]]; then
        echo -e "  │  ${CYAN}EFI${NC}       reused  ($EFI_PART)                  │"
    elif [[ "$FIRMWARE_MODE" == "uefi" ]]; then
        echo -e "  │  ${CYAN}EFI${NC}       ${EFI_SIZE_MB} MB  FAT32                       │"
    fi
    [[ "$SWAP_TYPE" == "partition" ]] && echo -e "  │  ${CYAN}swap${NC}      ${SWAP_SIZE} GB                              │"
    local rdisp="${ROOT_SIZE} GB"; [[ "$ROOT_SIZE" == "rest" ]] && rdisp="remaining"
    local luks_note=""; [[ "$USE_LUKS" == true ]] && luks_note=" [LUKS2]"
    echo -e "  │  ${CYAN}root (/)${NC}  ${rdisp}   ${ROOT_FS}${luks_note}                │"
    if [[ "$SEP_HOME" == true && "$DISK_HOME" == "$DISK_ROOT" ]]; then
        local hdisp="${HOME_SIZE} GB"; [[ "$HOME_SIZE" == "rest" ]] && hdisp="remaining"
        echo -e "  │  ${CYAN}/home${NC}     ${hdisp}   ${HOME_FS}${luks_note}                │"
    fi
    echo -e "  ${BOLD}└────────────────────────────────────────────────────┘${NC}"
    blank
}

configure_system() {
    section "System Identity"
    HOSTNAME=$(get_input "Hostname" "archlinux")
    blank; info "GRUB entry name shown at boot."
    GRUB_ENTRY_NAME=$(get_input "GRUB menu name" "Arch Linux (${HOSTNAME})")
    blank; info "Timezone examples: Europe/Paris  America/New_York  Asia/Tokyo  UTC"
    while true; do
        TIMEZONE=$(get_input "Timezone" "Europe/Paris")
        [[ -f "/usr/share/zoneinfo/${TIMEZONE}" ]] && break
        warn "'$TIMEZONE' not found. Browse: ls /usr/share/zoneinfo/"
    done
    blank; info "Locale examples: en_US.UTF-8  fr_FR.UTF-8  de_DE.UTF-8"
    while true; do
        LOCALE=$(get_input "Locale" "fr_FR.UTF-8")
        if grep -q "^#\?${LOCALE} " /etc/locale.gen 2>/dev/null \
           || find /usr/share/i18n/locales -name "${LOCALE%%.*}" 2>/dev/null | grep -q .; then
            break
        fi
        warn "Locale '$LOCALE' not found. Format: en_US.UTF-8"
    done
    ok "Hostname: $HOSTNAME  |  Timezone: $TIMEZONE  |  Locale: $LOCALE"
}

configure_users() {
    section "User Accounts"
    while true; do
        USERNAME=$(get_input "Username")
        [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
        warn "Invalid: lowercase, digits, _-; start with letter/underscore."
    done
    USER_PASSWORD=$(get_password "Password for '${USERNAME}'"  )
    ROOT_PASSWORD=$(get_password "Root password")
    ok "User '$USERNAME' configured (wheel/sudo)"
}

choose_kernel() {
    section "Kernel"
    echo -e "  ${BOLD}1)${NC} linux           ${DIM}latest stable${NC}"
    echo -e "  ${BOLD}2)${NC} linux-lts        ${DIM}long-term support${NC}"
    echo -e "  ${BOLD}3)${NC} linux-zen        ${DIM}desktop-optimised${NC}"
    echo -e "  ${BOLD}4)${NC} linux-hardened   ${DIM}security-hardened${NC}"
    blank; ask "Kernel [1-4] (default: 1):"; read -r k
    case "${k:-1}" in 2) KERNEL="linux-lts" ;; 3) KERNEL="linux-zen" ;; 4) KERNEL="linux-hardened" ;; *) KERNEL="linux" ;; esac
    ok "Kernel: $KERNEL"
}

choose_bootloader() {
    section "Bootloader"
    if [[ "$DUAL_BOOT" == true ]]; then
        info "Multi-boot active — detected: ${EXISTING_SYSTEMS[*]}"
        warn "GRUB strongly recommended (os-prober auto-detects all OSes)."
        blank
    fi
    if [[ "$FIRMWARE_MODE" == "bios" ]]; then
        BOOTLOADER="grub"; ok "GRUB (only option in BIOS mode)"; return 0
    fi
    echo -e "  ${BOLD}1)${NC} GRUB           ${DIM}recommended — os-prober support${NC}"
    if [[ "$DUAL_BOOT" == true ]]; then
        echo -e "  ${BOLD}2)${NC} systemd-boot   ${DIM}${YELLOW}NOT recommended in multi-boot${NC}"
    else
        echo -e "  ${BOLD}2)${NC} systemd-boot   ${DIM}minimal, fast — single-OS installs${NC}"
    fi
    blank; ask "Bootloader [1/2] (default: 1):"; read -r bl
    case "${bl:-1}" in
        2)  BOOTLOADER="systemd-boot"
            if [[ "$DUAL_BOOT" == true ]]; then
                warn "Other OSes will NOT auto-appear in the boot menu."
                confirm "Proceed with systemd-boot anyway?" "n" || { BOOTLOADER="grub"; ok "Switched to GRUB."; }
            fi ;;
        *)  BOOTLOADER="grub" ;;
    esac
    ok "Bootloader: $BOOTLOADER"
    blank
    if confirm "Enable Secure Boot? (sbctl enrollment required after first boot)" "n"; then
        SECURE_BOOT=true
        warn "After first boot: sbctl enroll-keys --microsoft && sbctl sign-all"
    fi
}

choose_desktop() {
    section "Desktop Environment"
    info "Enter numbers separated by spaces (e.g. '1 3' for KDE+Hyprland)"
    echo -e "  ${BOLD}1)${NC} KDE Plasma   ${BOLD}2)${NC} GNOME    ${BOLD}3)${NC} Hyprland"
    echo -e "  ${BOLD}4)${NC} Sway         ${BOLD}5)${NC} COSMIC   ${BOLD}6)${NC} XFCE     ${BOLD}7)${NC} None"
    blank
    while true; do
        ask "Desktop(s) [1-7]:"; local raw_input; read -r raw_input
        [[ -z "$raw_input" ]] && { warn "Must choose (7 for none)."; continue; }
        local -a tokens; read -ra tokens <<< "$raw_input"
        DESKTOPS=(); local valid=true
        for c in "${tokens[@]}"; do
            c="${c//[[:space:]]/}"; [[ -z "$c" ]] && continue
            case "$c" in
                1) DESKTOPS+=("kde") ;; 2) DESKTOPS+=("gnome") ;; 3) DESKTOPS+=("hyprland") ;;
                4) DESKTOPS+=("sway") ;; 5) DESKTOPS+=("cosmic") ;; 6) DESKTOPS+=("xfce") ;;
                7) DESKTOPS=("none"); break ;;
                *) warn "Invalid: '$c'"; valid=false; break ;;
            esac
        done
        if [[ "$valid" == true && "${#DESKTOPS[@]}" -gt 0 ]]; then
            local -A _seen=(); local -a _dedup=()
            for d in "${DESKTOPS[@]}"; do
                if [[ -z "${_seen[$d]+x}" ]]; then _dedup+=("$d"); _seen[$d]=1; fi
            done
            DESKTOPS=("${_dedup[@]}"); break
        fi
        [[ "${#DESKTOPS[@]}" -eq 0 ]] && warn "No valid selection."
    done
    ok "Desktop(s): ${DESKTOPS[*]}"
}

choose_extras() {
    section "Optional Extras"
    blank; echo -e "${BOLD}  Mirrors${NC}"
    if confirm "  Enable reflector?" "y"; then
        USE_REFLECTOR=true
        REFLECTOR_COUNTRIES=$(get_input "Countries (comma-separated)" "France,Germany")
        REFLECTOR_NUMBER=$(get_input "Mirror count" "10")
        REFLECTOR_AGE=$(get_input "Max age (hours)" "12")
        ok "  Reflector: ${REFLECTOR_NUMBER} mirrors | ${REFLECTOR_COUNTRIES} | ≤${REFLECTOR_AGE}h"
    fi
    confirm "  Enable multilib (Steam, Wine, Proton)?" "y" && USE_MULTILIB=true

    blank; echo -e "${BOLD}  Audio${NC}"
    confirm "  Install PipeWire?" "y" && USE_PIPEWIRE=true

    blank; echo -e "${BOLD}  GPU${NC}"
    if [[ "$GPU_VENDOR" == "nvidia" ]]; then
        confirm "  Install NVIDIA proprietary drivers?" "y" && USE_NVIDIA=true
    elif [[ "$GPU_VENDOR" == "amd" ]]; then
        info "  AMD GPU — mesa always included."
        confirm "  Install AMD Vulkan + video accel (vulkan-radeon, libva-mesa-driver)?" "y" && USE_AMD_VULKAN=true
    fi

    blank; echo -e "${BOLD}  Peripherals${NC}"
    confirm "  Bluetooth (bluez + bluez-utils)?" "y" && USE_BLUETOOTH=true
    confirm "  CUPS printing?" "n" && USE_CUPS=true

    blank; echo -e "${BOLD}  Snapshots${NC}"
    if [[ "$ROOT_FS" == "btrfs" ]]; then
        confirm "  Snapper auto-snapshots?" "y" && USE_SNAPPER=true
    else
        info "  Snapper skipped (requires btrfs, root is $ROOT_FS)."; USE_SNAPPER=false
    fi

    blank; echo -e "${BOLD}  Firewall${NC}"
    echo -e "  ${BOLD}1)${NC} nftables  ${BOLD}2)${NC} ufw  ${BOLD}3)${NC} None"
    ask "  Firewall [1-3] (default: 1):"; read -r fw
    case "${fw:-1}" in 2) FIREWALL="ufw" ;; 3) FIREWALL="none" ;; *) FIREWALL="nftables" ;; esac
    ok "  Firewall: $FIREWALL"

    blank; echo -e "${BOLD}  AUR Helper${NC}"
    echo -e "  ${BOLD}1)${NC} yay  ${BOLD}2)${NC} paru  ${BOLD}3)${NC} paru-bin ${DIM}(recommended — pre-built)${NC}  ${BOLD}4)${NC} None"
    ask "  AUR helper [1-4] (default: 3):"; read -r aur
    case "${aur:-3}" in 1) AUR_HELPER="yay" ;; 2) AUR_HELPER="paru" ;; 4) AUR_HELPER="none" ;; *) AUR_HELPER="paru-bin" ;; esac
    ok "  AUR: $AUR_HELPER"
}

save_config() {
    section "Save Configuration"
    warn "Config file contains passwords in plaintext — keep it secure."
    confirm "Save config to file?" "y" || return 0
    local cfg_path; cfg_path=$(get_input "Save to" "/tmp/archwizard_config_$(date +%Y%m%d_%H%M%S).sh")
    cat > "$cfg_path" << CFGEOF
#!/usr/bin/env bash
# ArchWizard 6.0 saved config — $(date '+%Y-%m-%d %H:%M:%S')
CPU_VENDOR="${CPU_VENDOR}"; GPU_VENDOR="${GPU_VENDOR}"
DISK_ROOT="${DISK_ROOT}"; DISK_HOME="${DISK_HOME}"; ROOT_FS="${ROOT_FS}"; HOME_FS="${HOME_FS}"
EFI_PART="${EFI_PART}"; EFI_SIZE_MB="${EFI_SIZE_MB}"; ROOT_SIZE="${ROOT_SIZE}"
SEP_HOME="${SEP_HOME}"; HOME_SIZE="${HOME_SIZE}"; SWAP_TYPE="${SWAP_TYPE}"; SWAP_SIZE="${SWAP_SIZE}"
DUAL_BOOT="${DUAL_BOOT}"; REUSE_EFI="${REUSE_EFI}"; USE_LUKS="${USE_LUKS}"
HOSTNAME="${HOSTNAME}"; GRUB_ENTRY_NAME="${GRUB_ENTRY_NAME}"; USERNAME="${USERNAME}"
USER_PASSWORD="${USER_PASSWORD}"; ROOT_PASSWORD="${ROOT_PASSWORD}"
TIMEZONE="${TIMEZONE}"; LOCALE="${LOCALE}"; KEYMAP="${KEYMAP}"
KERNEL="${KERNEL}"; BOOTLOADER="${BOOTLOADER}"; SECURE_BOOT="${SECURE_BOOT}"
DESKTOPS=(${DESKTOPS[@]+"${DESKTOPS[@]}"})
AUR_HELPER="${AUR_HELPER}"; USE_REFLECTOR="${USE_REFLECTOR}"
REFLECTOR_COUNTRIES="${REFLECTOR_COUNTRIES}"; REFLECTOR_NUMBER="${REFLECTOR_NUMBER}"
REFLECTOR_AGE="${REFLECTOR_AGE}"; USE_MULTILIB="${USE_MULTILIB}"
USE_PIPEWIRE="${USE_PIPEWIRE}"; USE_NVIDIA="${USE_NVIDIA}"; USE_AMD_VULKAN="${USE_AMD_VULKAN}"
USE_BLUETOOTH="${USE_BLUETOOTH}"; USE_CUPS="${USE_CUPS}"; USE_SNAPPER="${USE_SNAPPER}"
FIREWALL="${FIREWALL}"
CFGEOF
    chmod 600 "$cfg_path"
    ok "Config saved → $cfg_path"
}

load_config() {
    local cfg="$1"
    [[ ! -f "$cfg" ]] && { error "Config not found: $cfg"; exit 1; }
    info "Loading config: $cfg"
    # shellcheck source=/dev/null
    source "$cfg"
    ok "Config loaded — Phase 1 skipped."
}

# =============================================================================
#  PHASE 2 — SUMMARY & CONFIRMATION GATE
# =============================================================================

show_summary() {
    section "Installation Summary"
    echo -e "  ┌─────────────────────────────────────────────────────────────┐"
    echo -e "  │  ${BOLD}DISKS${NC}"
    echo -e "  │   Root: ${CYAN}$DISK_ROOT${NC}"
    [[ "$SEP_HOME" == true ]] && echo -e "  │   Home: ${CYAN}$DISK_HOME${NC}"
    [[ "$REUSE_EFI" == true ]] && echo -e "  │   EFI : ${CYAN}$EFI_PART (reused)${NC}"
    echo -e "  │   Root: ${CYAN}${ROOT_SIZE} GB [${ROOT_FS}]${NC}"
    [[ "$SEP_HOME" == true ]] && echo -e "  │   Home: ${CYAN}${HOME_SIZE} GB [${HOME_FS}]${NC}"
    echo -e "  │   Swap: ${CYAN}${SWAP_TYPE}${SWAP_SIZE:+ (${SWAP_SIZE}GB)}${NC}  LUKS: ${CYAN}${USE_LUKS}${NC}  Multi-boot: ${CYAN}${DUAL_BOOT}${NC}"
    if [[ ${#REPLACE_PARTS_ALL[@]} -gt 0 ]]; then
        local _rlist _rtotal=0
        _rlist=$(printf '%s ' "${REPLACE_PARTS_ALL[@]}")
        for _rp in "${REPLACE_PARTS_ALL[@]}"; do
            local _rg; _rg=$(( $(blockdev --getsize64 "$_rp" 2>/dev/null || echo 0) / 1073741824 ))
            _rtotal=$(( _rtotal + _rg ))
        done
        echo -e "  │   Plan: ${RED}DELETE ${_rlist}(${_rtotal} GB — ALL DATA LOST)${NC}"
    elif [[ -n "$REPLACE_PART" ]]; then
        local _rep_gb; _rep_gb=$(( $(blockdev --getsize64 "$REPLACE_PART" 2>/dev/null || echo 0) / 1073741824 ))
        echo -e "  │   Plan: ${RED}DELETE $REPLACE_PART (${_rep_gb} GB — ALL DATA LOST)${NC}"
    elif [[ -n "$RESIZE_PART" ]]; then
        echo -e "  │   Plan: ${CYAN}SHRINK $RESIZE_PART → ${RESIZE_NEW_GB} GB${NC}"
    fi
    [[ ${#EXISTING_SYSTEMS[@]} -gt 0 ]] && echo -e "  │   Keep: ${CYAN}$(IFS=', '; echo "${EXISTING_SYSTEMS[*]}")${NC}"
    echo -e "  ├─────────────────────────────────────────────────────────────┤"
    echo -e "  │  ${BOLD}SYSTEM${NC}"
    echo -e "  │   Host: ${CYAN}$HOSTNAME${NC}  GRUB: ${CYAN}$GRUB_ENTRY_NAME${NC}"
    echo -e "  │   TZ:   ${CYAN}$TIMEZONE${NC}  Locale: ${CYAN}$LOCALE${NC}  Keymap: ${CYAN}$KEYMAP${NC}"
    echo -e "  │   User: ${CYAN}$USERNAME${NC} (wheel/sudo)"
    echo -e "  ├─────────────────────────────────────────────────────────────┤"
    echo -e "  │  ${BOLD}SOFTWARE${NC}"
    echo -e "  │   Kernel: ${CYAN}$KERNEL${NC}  Boot: ${CYAN}$BOOTLOADER${NC}  SecureBoot: ${CYAN}$SECURE_BOOT${NC}"
    echo -e "  │   DE:     ${CYAN}${DESKTOPS[*]}${NC}"
    echo -e "  │   AUR:    ${CYAN}$AUR_HELPER${NC}  PipeWire: ${CYAN}$USE_PIPEWIRE${NC}  Multilib: ${CYAN}$USE_MULTILIB${NC}"
    echo -e "  │   NVIDIA: ${CYAN}$USE_NVIDIA${NC}  BT: ${CYAN}$USE_BLUETOOTH${NC}  CUPS: ${CYAN}$USE_CUPS${NC}  Snapper: ${CYAN}$USE_SNAPPER${NC}"
    echo -e "  │   Reflector: ${CYAN}$USE_REFLECTOR${NC}  Firewall: ${CYAN}$FIREWALL${NC}"
    echo -e "  └─────────────────────────────────────────────────────────────┘"
    blank; warn "After confirmation — disk(s) will be modified!"
    blank
    confirm "${RED}${BOLD}Begin installation?${NC}" "n" || { info "Aborted."; exit 0; }
}

# =============================================================================
#  PHASE 3 — DISK OPERATIONS
# =============================================================================

replace_partition() {
    [[ "$DUAL_BOOT" == false ]] && return 0
    local _to_delete=()
    if [[ ${#REPLACE_PARTS_ALL[@]} -gt 0 ]]; then _to_delete=("${REPLACE_PARTS_ALL[@]}")
    elif [[ -n "$REPLACE_PART" ]]; then _to_delete=("$REPLACE_PART")
    else return 0; fi

    section "Delete Partitions"
    # crash: reverse number order — prevents GPT slot renumbering mid-loop
    local _sorted=()
    while IFS= read -r line; do _sorted+=("$line"); done \
        < <(printf '%s\n' "${_to_delete[@]}" \
            | awk '{match($0,/[0-9]+$/); print substr($0,RSTART)+0, $0}' \
            | sort -rn | awk '{print $2}')

    # crash: batch all sgdisk -d calls, then one _refresh_partitions
    local _total_freed=0
    for p in "${_sorted[@]}"; do
        [[ -z "$p" ]] && continue
        local _gb _num
        _gb=$(( $(blockdev --getsize64 "$p" 2>/dev/null || echo 0) / 1073741824 ))
        _num=$(echo "$p" | grep -oE '[0-9]+$')
        info "Deleting $p (${_gb} GB)"
        run "sgdisk -d ${_num} ${DISK_ROOT}"
        _total_freed=$(( _total_freed + _gb ))
        ok "$p removed from GPT"
    done
    _refresh_partitions "$DISK_ROOT"
    info "Updated layout:"; parted -s "$DISK_ROOT" unit GiB print free 2>/dev/null || true
    ok "Freed: ${_total_freed} GB"; blank
}

resize_partitions() {
    [[ "$DUAL_BOOT" == false ]] && return 0
    [[ -z "$RESIZE_PART" ]] && return 0

    section "Resize: $RESIZE_PART → ${RESIZE_NEW_GB} GB"
    local target_fs; target_fs=$(blkid -s TYPE -o value "$RESIZE_PART" 2>/dev/null || echo "unknown")
    local cur_gb; cur_gb=$(( $(blockdev --getsize64 "$RESIZE_PART" 2>/dev/null || echo 0) / 1073741824 ))
    local new_bytes=$(( RESIZE_NEW_GB * 1073741824 ))
    local new_mb=$(( RESIZE_NEW_GB * 1024 ))
    info "Executing: $RESIZE_PART  ${cur_gb} GB → ${RESIZE_NEW_GB} GB  (frees $(( cur_gb - RESIZE_NEW_GB )) GB)"

    case "$target_fs" in
        ntfs)
            run "ntfsresize --no-action --size ${new_mb}M $RESIZE_PART"
            run "ntfsresize --force --size ${new_mb}M $RESIZE_PART"
            ok "NTFS shrunk to ${RESIZE_NEW_GB} GB" ;;
        ext4)
            run "e2fsck -fy $RESIZE_PART"
            run "resize2fs $RESIZE_PART ${new_mb}M"
            ok "ext4 shrunk to ~${RESIZE_NEW_GB} GB" ;;
        btrfs)
            local _btmp="/tmp/archwizard_btrfs_resize"; mkdir -p "$_btmp"
            run "mount -o rw $RESIZE_PART $_btmp"
            run "btrfs filesystem resize ${new_mb}M $_btmp"
            run "umount $_btmp"; rmdir "$_btmp" 2>/dev/null || true
            ok "btrfs shrunk to ~${RESIZE_NEW_GB} GB" ;;
        *) error "Unsupported FS '$target_fs' for resize."; return 1 ;;
    esac

    local part_num; part_num=$(echo "$RESIZE_PART" | grep -oE '[0-9]+$')
    local start_bytes; start_bytes=$(parted -s "$DISK_ROOT" unit B print 2>/dev/null \
        | awk "/^ *${part_num} /{print \$2}" | tr -d 'B')
    local new_end=$(( ${start_bytes:-0} + new_bytes ))
    info "parted will ask you to confirm — type 'Yes' and press Enter."
    run_interactive "parted $DISK_ROOT resizepart $part_num ${new_end}B"
    ok "GPT partition entry updated"
    _refresh_partitions "$DISK_ROOT"
    info "Updated layout:"; parted -s "$DISK_ROOT" unit GiB print free 2>/dev/null || true
    ok "Done — $(( cur_gb - RESIZE_NEW_GB )) GB unallocated."; blank
}

create_partitions() {
    section "Partitioning"
    local part_num=1

    if [[ "$DUAL_BOOT" == true ]]; then
        info "Multi-boot — adding to existing layout"
        if [[ "$SWAP_TYPE" == "partition" ]]; then
            run "sgdisk -n 0:0:+${SWAP_SIZE}G -t 0:8200 -c 0:arch_swap $DISK_ROOT"
            SWAP_PART=$(part_name "$DISK_ROOT" "$(sgdisk -p "$DISK_ROOT" 2>/dev/null | tail -1 | awk '{print $1}')")
        fi
        if [[ "$SEP_HOME" == true && "$DISK_HOME" == "$DISK_ROOT" ]]; then
            if [[ "$ROOT_SIZE" == "rest" ]]; then run "sgdisk -n 0:0:0 -t 0:8300 -c 0:arch_root $DISK_ROOT"
            else run "sgdisk -n 0:0:+${ROOT_SIZE}G -t 0:8300 -c 0:arch_root $DISK_ROOT"; fi
            ROOT_PART=$(part_name "$DISK_ROOT" "$(sgdisk -p "$DISK_ROOT" 2>/dev/null | tail -1 | awk '{print $1}')")
            if [[ "$HOME_SIZE" == "rest" ]]; then run "sgdisk -n 0:0:0 -t 0:8302 -c 0:arch_home $DISK_ROOT"
            else run "sgdisk -n 0:0:+${HOME_SIZE}G -t 0:8302 -c 0:arch_home $DISK_ROOT"; fi
            HOME_PART=$(part_name "$DISK_ROOT" "$(sgdisk -p "$DISK_ROOT" 2>/dev/null | tail -1 | awk '{print $1}')")
        else
            if [[ "$ROOT_SIZE" == "rest" ]]; then run "sgdisk -n 0:0:0 -t 0:8300 -c 0:arch_root $DISK_ROOT"
            else run "sgdisk -n 0:0:+${ROOT_SIZE}G -t 0:8300 -c 0:arch_root $DISK_ROOT"; fi
            ROOT_PART=$(part_name "$DISK_ROOT" "$(sgdisk -p "$DISK_ROOT" 2>/dev/null | tail -1 | awk '{print $1}')")
        fi

    elif [[ "$FIRMWARE_MODE" == "bios" ]]; then
        warn "Wiping $DISK_ROOT — new MBR table (BIOS mode)"
        run "parted -s $DISK_ROOT mklabel msdos"
        run "parted -s $DISK_ROOT mkpart primary 1MiB 2MiB"
        run "parted -s $DISK_ROOT set 1 bios_grub on"
        part_num=2
        local _next_start="2MiB"
        if [[ "$SWAP_TYPE" == "partition" ]]; then
            local _swap_end=$(( 2 + SWAP_SIZE * 1024 ))
            run "parted -s $DISK_ROOT mkpart primary linux-swap 2MiB ${_swap_end}MiB"
            SWAP_PART=$(part_name "$DISK_ROOT" "$part_num"); part_num=$(( part_num + 1 ))
            _next_start="${_swap_end}MiB"
        fi
        if [[ "$ROOT_SIZE" == "rest" ]]; then
            run "parted -s $DISK_ROOT mkpart primary 100% 100%"
            ROOT_PART=$(part_name "$DISK_ROOT" "$part_num")
        else
            local _root_end=$(( ${_next_start//MiB/} + ROOT_SIZE * 1024 ))
            run "parted -s $DISK_ROOT mkpart primary ${_next_start} ${_root_end}MiB"
            ROOT_PART=$(part_name "$DISK_ROOT" "$part_num"); part_num=$(( part_num + 1 ))
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
        warn "Wiping $DISK_ROOT — new GPT"
        run "sgdisk --zap-all $DISK_ROOT"
        run "sgdisk -o $DISK_ROOT"
        run "sgdisk -n 1:0:+${EFI_SIZE_MB}M -t 1:ef00 -c 1:EFI $DISK_ROOT"
        EFI_PART=$(part_name "$DISK_ROOT" "1"); part_num=2
        if [[ "$SWAP_TYPE" == "partition" ]]; then
            run "sgdisk -n ${part_num}:0:+${SWAP_SIZE}G -t ${part_num}:8200 -c ${part_num}:swap $DISK_ROOT"
            SWAP_PART=$(part_name "$DISK_ROOT" "$part_num"); part_num=$(( part_num + 1 ))
        fi
        if [[ "$ROOT_SIZE" == "rest" ]]; then
            run "sgdisk -n ${part_num}:0:0 -t ${part_num}:8300 -c ${part_num}:root $DISK_ROOT"
            ROOT_PART=$(part_name "$DISK_ROOT" "$part_num")
        else
            run "sgdisk -n ${part_num}:0:+${ROOT_SIZE}G -t ${part_num}:8300 -c ${part_num}:root $DISK_ROOT"
            ROOT_PART=$(part_name "$DISK_ROOT" "$part_num"); part_num=$(( part_num + 1 ))
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
        warn "Wiping $DISK_HOME for /home"
        run "sgdisk --zap-all $DISK_HOME"; run "sgdisk -o $DISK_HOME"
        if [[ "$HOME_SIZE" == "rest" ]]; then run "sgdisk -n 1:0:0 -t 1:8302 -c 1:home $DISK_HOME"
        else run "sgdisk -n 1:0:+${HOME_SIZE}G -t 1:8302 -c 1:home $DISK_HOME"; fi
        HOME_PART=$(part_name "$DISK_HOME" "1")
    fi

    _refresh_partitions "$DISK_ROOT"
    if [[ "$DISK_HOME" != "$DISK_ROOT" ]]; then _refresh_partitions "$DISK_HOME"; fi
    ok "Partitions created"; blank
    lsblk "$DISK_ROOT" 2>/dev/null || true
    if [[ "$DISK_HOME" != "$DISK_ROOT" ]]; then lsblk "$DISK_HOME" 2>/dev/null || true; fi
}

setup_luks() {
    [[ "$USE_LUKS" == false ]] && return 0
    section "LUKS2 Encryption"
    info "Encrypting $ROOT_PART…"
    # crash: passwords never in argv — pipe via stdin
    echo -n "$LUKS_PASSWORD" | run "cryptsetup luksFormat --type luks2 \
        --cipher aes-xts-plain64 --key-size 512 --hash sha512 --batch-mode $ROOT_PART -"
    echo -n "$LUKS_PASSWORD" | run "cryptsetup open --allow-discards --persistent $ROOT_PART cryptroot -"
    ROOT_PART_MAPPED="/dev/mapper/cryptroot"
    ok "LUKS opened → $ROOT_PART_MAPPED"
    if [[ "$SEP_HOME" == true && -n "$HOME_PART" ]]; then
        blank
        if confirm "Also encrypt /home with same passphrase?" "y"; then
            echo -n "$LUKS_PASSWORD" | run "cryptsetup luksFormat --type luks2 \
                --cipher aes-xts-plain64 --key-size 512 --hash sha512 --batch-mode $HOME_PART -"
            echo -n "$LUKS_PASSWORD" | run "cryptsetup open --allow-discards --persistent $HOME_PART crypthome -"
            HOME_PART="/dev/mapper/crypthome"; ok "/home encrypted → $HOME_PART"
        fi
    fi
}

format_filesystems() {
    section "Formatting"
    local root_dev="${ROOT_PART_MAPPED:-$ROOT_PART}"
    if [[ "$FIRMWARE_MODE" == "bios" ]]; then ok "BIOS — no EFI to format"
    elif [[ "$DUAL_BOOT" == true ]]; then ok "Multi-boot: reusing EFI $EFI_PART"
    elif [[ "$REUSE_EFI" == false ]]; then run "mkfs.fat -F32 -n EFI $EFI_PART"; ok "EFI → FAT32"
    else ok "Reusing EFI: $EFI_PART"; fi

    case "$ROOT_FS" in
        btrfs) run "mkfs.btrfs -f -L arch_root $root_dev" ;;
        ext4)  run "mkfs.ext4  -F -L arch_root $root_dev" ;;
        xfs)   run "mkfs.xfs   -f -L arch_root $root_dev" ;;
        f2fs)  run "mkfs.f2fs  -f -l arch_root $root_dev" ;;
    esac
    ok "Root → $ROOT_FS ($root_dev)"

    if [[ "$SEP_HOME" == true && -n "$HOME_PART" ]]; then
        case "$HOME_FS" in
            btrfs) run "mkfs.btrfs -f -L arch_home $HOME_PART" ;;
            ext4)  run "mkfs.ext4  -F -L arch_home $HOME_PART" ;;
            xfs)   run "mkfs.xfs   -f -L arch_home $HOME_PART" ;;
            f2fs)  run "mkfs.f2fs  -f -l arch_home $HOME_PART" ;;
        esac
        ok "Home → $HOME_FS ($HOME_PART)"
    fi
    if [[ "$SWAP_TYPE" == "partition" && -n "$SWAP_PART" ]]; then
        run "mkswap -L arch_swap $SWAP_PART"; ok "Swap formatted"
    fi
}

create_subvolumes() {
    if [[ "$ROOT_FS" != "btrfs" ]]; then info "Skipping btrfs subvols ($ROOT_FS)"; return 0; fi
    section "btrfs Subvolumes"
    local root_dev="${ROOT_PART_MAPPED:-$ROOT_PART}"
    run "mount $root_dev /mnt"
    local subvols=("@" "@home" "@snapshots" "@var_log" "@var_cache" "@tmp")
    [[ "$SWAP_TYPE" == "file" ]] && subvols+=("@swap")
    for sv in "${subvols[@]}"; do run "btrfs subvolume create /mnt/$sv"; ok "  $sv"; done
    run "umount /mnt"; ok "Subvolumes created"
}

mount_filesystems() {
    section "Mounting"
    local root_dev="${ROOT_PART_MAPPED:-$ROOT_PART}"
    local btrfs_opts="noatime,compress=zstd:1,space_cache=v2,discard=async"
    local ext4_opts="noatime,discard"
    local xfs_opts="noatime,discard,logbufs=8"
    local f2fs_opts="noatime,lazytime,discard"
    local esp_mount="boot/efi"; [[ "$BOOTLOADER" == "systemd-boot" ]] && esp_mount="boot"

    if [[ "$ROOT_FS" == "btrfs" ]]; then
        run "mount -o ${btrfs_opts},subvol=@ $root_dev /mnt"
        run "mkdir -p /mnt/{${esp_mount},home,var/log,var/cache,tmp,.snapshots}"
        [[ "$SWAP_TYPE" == "file" ]] && run "mkdir -p /mnt/swap"
        run "mount -o ${btrfs_opts},subvol=@snapshots $root_dev /mnt/.snapshots"
        run "mount -o ${btrfs_opts},subvol=@var_log    $root_dev /mnt/var/log"
        run "mount -o ${btrfs_opts},subvol=@var_cache  $root_dev /mnt/var/cache"
        run "mount -o ${btrfs_opts},subvol=@tmp        $root_dev /mnt/tmp"
        run "chattr +C /mnt/var/log"
        ok "btrfs subvols mounted (CoW disabled on var/log)"
    else
        local root_opts
        case "$ROOT_FS" in ext4) root_opts="$ext4_opts" ;; xfs) root_opts="$xfs_opts" ;;
            f2fs) root_opts="$f2fs_opts" ;; *) root_opts="noatime" ;; esac
        run "mount -o ${root_opts} $root_dev /mnt"
        run "mkdir -p /mnt/{${esp_mount},home,var/log,var/cache,tmp}"
        [[ "$SWAP_TYPE" == "file" ]] && run "mkdir -p /mnt/swap"
        ok "/ → /mnt ($ROOT_FS)"
    fi

    if [[ "$SEP_HOME" == true && -n "$HOME_PART" ]]; then
        if [[ "$HOME_FS" == "btrfs" ]]; then
            run "mount $HOME_PART /mnt/home"
            run "btrfs subvolume create /mnt/home/@home"
            run "umount /mnt/home"
            run "mount -o ${btrfs_opts},subvol=@home $HOME_PART /mnt/home"
            ok "Home → btrfs @home"
        else
            local home_opts
            case "$HOME_FS" in ext4) home_opts="$ext4_opts" ;; xfs) home_opts="$xfs_opts" ;;
                f2fs) home_opts="$f2fs_opts" ;; *) home_opts="noatime" ;; esac
            run "mount -o ${home_opts} $HOME_PART /mnt/home"; ok "Home → $HOME_FS"
        fi
    else
        if [[ "$ROOT_FS" == "btrfs" ]]; then
            run "mount -o ${btrfs_opts},subvol=@home $root_dev /mnt/home"; ok "@home → /mnt/home"
        fi
    fi

    if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
        [[ -z "$EFI_PART" ]] && { error "EFI_PART not set."; exit 1; }
        run "mount $EFI_PART /mnt/${esp_mount}"; ok "EFI → /mnt/${esp_mount}"
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
        run "swapon /mnt/swap/swapfile"; ok "Swap file active (${SWAP_SIZE} GB)"
    fi
}

# =============================================================================
#  PHASE 4 — BASE INSTALL
# =============================================================================

setup_mirrors() {
    [[ "$USE_REFLECTOR" == false ]] && return 0
    section "Optimizing Mirrors"
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
    section "pacstrap"
    local pkgs="base base-devel ${KERNEL} ${KERNEL}-headers linux-firmware dosfstools mtools"
    local all_fs="${ROOT_FS} ${HOME_FS}"
    echo "$all_fs" | grep -q "btrfs" && pkgs+=" btrfs-progs"
    echo "$all_fs" | grep -q "ext4"  && pkgs+=" e2fsprogs"
    echo "$all_fs" | grep -q "xfs"   && pkgs+=" xfsprogs"
    echo "$all_fs" | grep -q "f2fs"  && pkgs+=" f2fs-tools"
    [[ "$CPU_VENDOR" == "intel" ]] && pkgs+=" intel-ucode"
    [[ "$CPU_VENDOR" == "amd"   ]] && pkgs+=" amd-ucode"
    pkgs+=" networkmanager network-manager-applet iwd wpa_supplicant wireless_tools"
    pkgs+=" git curl wget rsync nano vim neovim sudo bash-completion"
    pkgs+=" htop btop fastfetch zip unzip tar man-db man-pages pacman-contrib"
    pkgs+=" xdg-utils xdg-user-dirs smartmontools openssh"
    [[ "$DUAL_BOOT"    == true ]] && pkgs+=" os-prober ntfs-3g fuse2"
    [[ "$USE_AMD_VULKAN" == true ]] && pkgs+=" vulkan-radeon libva-mesa-driver" \
        && [[ "$USE_MULTILIB" == true ]] && pkgs+=" lib32-mesa lib32-vulkan-radeon"
    [[ "$USE_REFLECTOR" == true ]] && pkgs+=" reflector"
    [[ "$USE_SNAPPER"   == true ]] && pkgs+=" snapper snap-pac grub-btrfs"

    sed -i 's/^#Color/Color/; s/^#VerbosePkgLists/VerbosePkgLists/; s/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf 2>/dev/null || true
    grep -q "ILoveCandy" /etc/pacman.conf 2>/dev/null || sed -i '/^Color/a ILoveCandy' /etc/pacman.conf 2>/dev/null || true
    ok "Live pacman: Color + ParallelDownloads=5"

    info "Packages: $pkgs"
    run "pacstrap -K /mnt $pkgs"
    ok "Base installed"
    run "genfstab -U /mnt >> /mnt/etc/fstab"
    ok "fstab generated"
}

# =============================================================================
#  PHASE 5 — CHROOT CONFIGURATION
# =============================================================================

# crash: cat >> $S sections — never sed placeholders (corrupts UUIDs)
# unquoted EOF marker = variable expansion at write-time; quoted 'EOF' = literal
generate_chroot_script() {
    section "Generating Chroot Script"
    local all_de_pkgs="" dm_service="" has_wayland=false

    for de in "${DESKTOPS[@]+"${DESKTOPS[@]}"}"; do
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
    # sddm wins in priority over gdm/lightdm when KDE or Hyprland present
    for de in "${DESKTOPS[@]+"${DESKTOPS[@]}"}"; do
        [[ "$de" == "kde" || "$de" == "hyprland" ]] && dm_service="sddm" && break
    done

    local nvidia_pkgs=""
    if [[ "$USE_NVIDIA" == true ]]; then
        nvidia_pkgs="nvidia nvidia-utils nvidia-settings"
        [[ "$USE_MULTILIB" == true ]] && nvidia_pkgs+=" lib32-nvidia-utils"
        [[ "$has_wayland"  == true ]] && nvidia_pkgs+=" egl-wayland"
    fi

    local bootloader_pkgs="efibootmgr"
    [[ "$BOOTLOADER"  == "grub" ]] && bootloader_pkgs+=" grub"
    [[ "$DUAL_BOOT"   == true && "$BOOTLOADER" == "grub" ]] && bootloader_pkgs+=" os-prober"
    [[ "$USE_SNAPPER" == true && "$BOOTLOADER" == "grub" ]] && bootloader_pkgs+=" grub-btrfs"
    [[ "$SECURE_BOOT" == true ]] && bootloader_pkgs+=" sbctl"

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
        [[ "$USE_LUKS" == true ]] && sd_options="cryptdevice=UUID=${luks_uuid}:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet"
    else
        sd_options="root=UUID=${root_uuid} rw quiet splash"
        [[ "$USE_LUKS" == true ]] && sd_options="cryptdevice=UUID=${luks_uuid}:cryptroot root=/dev/mapper/cryptroot rw quiet"
    fi

    local S=/mnt/archwizard-configure.sh
    : > "$S"

    cat >> "$S" << 'HDR'
#!/usr/bin/env bash
set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()      { echo -e "${GREEN}${BOLD}[ OK ]${NC}  $*"; }
info()    { echo -e "${CYAN}${BOLD}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[WARN]${NC}  $*"; }
section() { echo -e "\n${CYAN}${BOLD}━━━  $*  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
trap 'echo -e "\n\033[0;31m[ERR]\033[0m chroot failed line $LINENO — cmd: ${BASH_COMMAND}" >&2' ERR

section "Keyring Refresh"
pacman -Sy --noconfirm archlinux-keyring 2>/dev/null || true
ok "archlinux-keyring refreshed"
HDR

    cat >> "$S" << TZEOF

section "Timezone & Clock"
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc
ok "Timezone: ${TIMEZONE}"
TZEOF

    cat >> "$S" << LOCEOF

section "Locale & Console"
echo "${LOCALE} UTF-8" >> /etc/locale.gen
grep -q "en_US.UTF-8" /etc/locale.gen || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}"   > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
ok "Locale: ${LOCALE} | Keymap: ${KEYMAP}"
LOCEOF

    cat >> "$S" << HOSTEOF

section "Hostname"
echo "${HOSTNAME}" > /etc/hostname
{ echo "127.0.0.1  localhost"; echo "::1        localhost"; echo "127.0.1.1  ${HOSTNAME}.localdomain  ${HOSTNAME}"; } > /etc/hosts
ok "Hostname: ${HOSTNAME}"
HOSTEOF

    cat >> "$S" << 'PACEOF'

section "Pacman Tweaks"
sed -i 's/^#Color/Color/; s/^#VerbosePkgLists/VerbosePkgLists/; s/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
grep -q "ILoveCandy" /etc/pacman.conf || sed -i '/^Color/a ILoveCandy' /etc/pacman.conf
ok "pacman: colour + parallel + ILoveCandy"
PACEOF

    cat >> "$S" << 'MKPEOF'

section "makepkg Optimisation"
NPROC=$(nproc)
sed -i "s/^#MAKEFLAGS=.*/MAKEFLAGS=\"-j${NPROC}\"/" /etc/makepkg.conf
sed -i "s/-march=x86-64 -mtune=generic/-march=native -mtune=native/" /etc/makepkg.conf
grep -q "^RUSTFLAGS=" /etc/makepkg.conf \
    && sed -i 's/^RUSTFLAGS=.*/RUSTFLAGS="-C opt-level=2 -C target-cpu=native"/' /etc/makepkg.conf \
    || echo 'RUSTFLAGS="-C opt-level=2 -C target-cpu=native"' >> /etc/makepkg.conf
ok "makepkg: -j${NPROC} | -march=native | RUSTFLAGS=native"
MKPEOF

    cat >> "$S" << 'SYSCTLEOF'

section "Kernel Hardening"
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
ok "sysctl hardening applied"
SYSCTLEOF

    cat >> "$S" << 'JRNEOF'

section "Journal Cap"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/00-journal.conf << 'JEOF'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=50M
MaxRetentionSec=2week
JEOF
ok "Journal capped at 200 MB"
JRNEOF

    if [[ "$USE_MULTILIB" == true ]]; then
        cat >> "$S" << 'MLEOF'

section "Multilib"
sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' /etc/pacman.conf
pacman -Sy --noconfirm
ok "Multilib enabled"
MLEOF
    fi

    if [[ "$USE_REFLECTOR" == true ]]; then
        local _ref_country_args="" _ref_conf_lines=""
        IFS=',' read -ra _rca <<< "$REFLECTOR_COUNTRIES"
        for _c in "${_rca[@]}"; do
            _c="${_c#"${_c%%[![:space:]]*}"}"; _c="${_c%"${_c##*[![:space:]]}"}"
            [[ -n "$_c" ]] && _ref_country_args+="--country \"${_c}\" " && _ref_conf_lines+="--country ${_c}\n"
        done
        cat >> "$S" << REFEOF

section "Reflector"
reflector ${_ref_country_args}--protocol ${REFLECTOR_PROTOCOL} --age ${REFLECTOR_AGE} --latest 20 --number ${REFLECTOR_NUMBER} --sort rate --save /etc/pacman.d/mirrorlist
mkdir -p /etc/xdg/reflector
printf '%b' "${_ref_conf_lines}--protocol ${REFLECTOR_PROTOCOL}\n--age ${REFLECTOR_AGE}\n--latest 20\n--number ${REFLECTOR_NUMBER}\n--sort rate\n--save /etc/pacman.d/mirrorlist\n" > /etc/xdg/reflector/reflector.conf
ok "Mirrors updated + reflector.conf written"
REFEOF
    fi

    cat >> "$S" << BPEOF

section "Bootloader Packages"
pacman -S --noconfirm --ask 4 --needed ${bootloader_pkgs}
ok "Bootloader packages installed"
BPEOF

    if [[ -n "${all_de_pkgs// /}" ]]; then
        cat >> "$S" << DEEOF

section "Desktop: ${DESKTOPS[*]}"
pacman -S --noconfirm --ask 4 --needed ${all_de_pkgs}
ok "Desktop(s) installed"
DEEOF
    fi

    if [[ "$USE_PIPEWIRE" == true ]]; then
        cat >> "$S" << 'PWEOF'

section "PipeWire"
pacman -S --noconfirm --ask 4 --needed pipewire pipewire-alsa pipewire-pulse wireplumber
if pacman -Qq jack2 &>/dev/null; then
    info "jack2 detected — replacing with pipewire-jack…"
    pacman -S --noconfirm --ask 4 --needed pipewire-jack
else
    pacman -S --noconfirm --ask 4 --needed pipewire-jack
fi
ok "PipeWire installed"
PWEOF
    fi

    if [[ -n "$nvidia_pkgs" ]]; then
        cat >> "$S" << NVEOF

section "NVIDIA Drivers"
pacman -S --noconfirm --ask 4 --needed ${nvidia_pkgs}
echo 'options nvidia_drm modeset=1 fbdev=1' > /etc/modprobe.d/nvidia.conf
ok "NVIDIA installed + DRM modesetting enabled"
NVEOF
    fi

    if [[ "$USE_BLUETOOTH" == true ]]; then
        cat >> "$S" << 'BTEOF'

section "Bluetooth"
pacman -S --noconfirm --ask 4 --needed bluez bluez-utils
systemctl enable bluetooth
ok "Bluetooth enabled"
BTEOF
    fi

    if [[ "$USE_CUPS" == true ]]; then
        cat >> "$S" << 'CPEOF'

section "CUPS"
pacman -S --noconfirm --ask 4 --needed cups cups-pdf system-config-printer
systemctl enable cups
ok "CUPS enabled"
CPEOF
    fi

    cat >> "$S" << MKEOF

section "mkinitcpio"
sed -i 's|^HOOKS=.*|HOOKS=(${mkinit_hooks})|' /etc/mkinitcpio.conf
mkinitcpio -P
ok "Initramfs built"
MKEOF

    # Bootloader
    if [[ "$BOOTLOADER" == "grub" ]]; then
        {
            echo 'section "GRUB"'
            if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
                echo '_hostname=$(cat /etc/hostname 2>/dev/null | tr -d '"'"' '"'"' || echo arch)'
                echo '_mid=$(cat /etc/machine-id 2>/dev/null | head -c6 || echo 000000)'
                echo 'GRUB_ID="Arch-${_hostname}-${_mid}"'
                echo 'grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$GRUB_ID" --recheck'
                echo 'ok "GRUB installed — EFI: ${GRUB_ID}"'
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
ok "GRUB menu name: ${GRUB_ENTRY_NAME}"
GNEOF

        if [[ "$DUAL_BOOT" == true ]]; then
            cat >> "$S" << 'OSPEOF'
if grep -q 'GRUB_DISABLE_OS_PROBER' /etc/default/grub; then
    sed -i 's/.*GRUB_DISABLE_OS_PROBER.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
else
    echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
fi
ok "os-prober enabled"
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
        if [[ "$USE_SNAPPER" == true ]]; then echo "systemctl enable grub-btrfsd" >> "$S"; fi

        # os-prober needs partitions mounted during grub-mkconfig
        cat >> "$S" << 'GRUB2EOF'
_osp_base="/mnt/osprober"; mkdir -p "$_osp_base"; _osp_dirs=(); _osp_idx=0
_cur_root=$(findmnt -n -o SOURCE / 2>/dev/null || echo "none")
while IFS=' ' read -r _dev _fstype; do
    [[ -z "$_dev" ]] && continue
    findmnt -S "$_dev" > /dev/null 2>&1 && continue
    [[ "$_dev" == "$_cur_root" ]] && continue
    _pt=$(lsblk -no PARTTYPE "$_dev" 2>/dev/null || echo "")
    [[ "$_pt" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] && continue
    [[ "$_pt" == "0657fd6d-a4ab-43c4-84e5-0933c84b4f4f" ]] && continue
    _osp_dir="${_osp_base}/${_osp_idx}"; mkdir -p "$_osp_dir"
    if [[ "$_fstype" == "btrfs" ]]; then
        mount -o ro,noexec,nosuid,subvol=@ "$_dev" "$_osp_dir" 2>/dev/null || \
        mount -o ro,noexec,nosuid         "$_dev" "$_osp_dir" 2>/dev/null || continue
    else
        mount -o ro,noexec,nosuid "$_dev" "$_osp_dir" 2>/dev/null || continue
    fi
    _osp_dirs+=("$_osp_dir"); _osp_idx=$(( _osp_idx + 1 ))
    info "Mounted for os-prober: $_dev → $_osp_dir"
done < <(lsblk -ln -o PATH,FSTYPE | awk '$2 ~ /^(btrfs|ext4|xfs|f2fs|ntfs)$/ {print $1, $2}')
os-prober 2>/dev/null || true
grub-mkconfig -o /boot/grub/grub.cfg
for _d in "${_osp_dirs[@]}"; do umount "$_d" 2>/dev/null || true; rmdir "$_d" 2>/dev/null || true; done
rmdir "$_osp_base" 2>/dev/null || true
ok "GRUB configured — os-prober scanned all partitions"
GRUB2EOF

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
            echo "ok \"systemd-boot configured\""
        } >> "$S"
    fi

    cat >> "$S" << USREOF

section "Users"
useradd -mG wheel,audio,video,optical,storage,network,input "${USERNAME}"
xdg-user-dirs-update --force 2>/dev/null || true
# crash: passwords never in argv — pipe via stdin
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd
echo "root:${ROOT_PASSWORD}"        | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
ok "User '${USERNAME}' created (wheel)"
USREOF

    cat >> "$S" << 'SVCEOF'

section "Core Services"
systemctl enable NetworkManager systemd-resolved fstrim.timer systemd-oomd paccache.timer
SVCEOF
    [[ -n "$dm_service" ]]         && echo "systemctl enable ${dm_service}" >> "$S"
    [[ "$USE_REFLECTOR" == true ]] && echo "systemctl enable reflector.timer" >> "$S"
    echo "ok \"Core services enabled\"" >> "$S"

    if [[ "$USE_SNAPPER" == true ]]; then
        cat >> "$S" << 'SNAPEOF'

section "Snapper"
umount /.snapshots 2>/dev/null || true; rm -rf /.snapshots; mkdir -p /.snapshots
mount -a; chmod 750 /.snapshots; chown :wheel /.snapshots 2>/dev/null || true
mkdir -p /etc/snapper/configs
cat > /etc/snapper/configs/root << 'SNACONF'
SUBVOLUME="/"; FSTYPE="btrfs"
ALLOW_USERS=""; ALLOW_GROUPS="wheel"; SYNC_ACL="no"
BACKGROUND_COMPARISON="yes"
NUMBER_CLEANUP="yes"; NUMBER_MIN_AGE="1800"; NUMBER_LIMIT="10"; NUMBER_LIMIT_IMPORTANT="10"
TIMELINE_CREATE="yes"; TIMELINE_CLEANUP="yes"; TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="5"; TIMELINE_LIMIT_DAILY="7"; TIMELINE_LIMIT_WEEKLY="2"
TIMELINE_LIMIT_MONTHLY="1"; TIMELINE_LIMIT_YEARLY="0"
EMPTY_PRE_POST_CLEANUP="yes"; EMPTY_PRE_POST_MIN_AGE="1800"
SNACONF
if grep -q "^SNAPPER_CONFIGS=" /etc/conf.d/snapper 2>/dev/null; then
    sed -i 's/^SNAPPER_CONFIGS=.*/SNAPPER_CONFIGS="root"/' /etc/conf.d/snapper
else
    mkdir -p /etc/conf.d; echo 'SNAPPER_CONFIGS="root"' > /etc/conf.d/snapper
fi
systemctl enable snapper-timeline.timer snapper-cleanup.timer snapper-boot.timer
ok "Snapper configured (no DBus needed in chroot)"
SNAPEOF
    fi

    if [[ "$FIREWALL" == "nftables" ]]; then
        cat >> "$S" << 'NFTEOF'

section "Firewall — nftables"
pacman -S --noconfirm --ask 4 --needed nftables
cat > /etc/nftables.conf << 'NFTRULES'
#!/usr/bin/nft -f
flush ruleset
table inet filter {
    chain input  { type filter hook input  priority filter; policy drop;
                   ct state invalid drop; ct state { established, related } accept;
                   iifname lo accept; ip protocol icmp accept; ip6 nexthdr icmpv6 accept; counter drop }
    chain forward { type filter hook forward priority filter; policy drop; }
    chain output  { type filter hook output  priority filter; policy accept; }
}
NFTRULES
systemctl enable nftables
ok "nftables enabled (stateful, drop-incoming)"
NFTEOF
    elif [[ "$FIREWALL" == "ufw" ]]; then
        cat >> "$S" << 'UFWEOF'

section "Firewall — ufw"
pacman -S --noconfirm --ask 4 --needed ufw
mkdir -p /etc/default
cat > /etc/default/ufw << 'UFWDEFAULT'
IPV6=yes
DEFAULT_INPUT_POLICY="DROP"; DEFAULT_OUTPUT_POLICY="ACCEPT"
DEFAULT_FORWARD_POLICY="DROP"; DEFAULT_APPLICATION_POLICY="SKIP"; MANAGE_BUILTINS=no
UFWDEFAULT
mkdir -p /etc/ufw; printf 'ENABLED=yes\nLOGLEVEL=low\n' > /etc/ufw/ufw.conf
systemctl enable ufw
ok "ufw enabled — active on first boot"
UFWEOF
    fi

    if [[ "$SWAP_TYPE" == "zram" ]]; then
        cat >> "$S" << 'ZRAMEOF'

section "zram"
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
ok "zram configured (≤8 GB, zstd, swappiness=100)"
ZRAMEOF
    fi

    if [[ "$SWAP_TYPE" == "file" ]]; then
        echo "echo '/swap/swapfile none swap defaults 0 0' >> /etc/fstab" >> "$S"
        echo "ok \"Swap file added to fstab\"" >> "$S"
    fi

    if [[ "$AUR_HELPER" != "none" ]]; then
        cat >> "$S" << AUREOF

section "AUR: ${AUR_HELPER}"
pacman -S --noconfirm --ask 4 --needed git base-devel
# crash: makepkg refuses root — build as regular user
sudo -u ${USERNAME} bash -c '
    set -euo pipefail; cd /tmp; rm -rf ${AUR_HELPER}
    git clone https://aur.archlinux.org/${AUR_HELPER}.git
    cd ${AUR_HELPER}; makepkg -si --noconfirm
'
ok "${AUR_HELPER} installed"
AUREOF
    fi

    if [[ "$SECURE_BOOT" == true ]]; then
        cat >> "$S" << 'SBEOF'

section "Secure Boot"
info "After first boot run: sudo sbctl enroll-keys --microsoft && sudo sbctl sign-all"
SBEOF
    fi

    cat >> "$S" << 'FTEOF'

section "Chroot Complete"
echo -e "\033[0;32m\033[1m  ✓  All chroot steps finished.\033[0m"
FTEOF

    chmod +x "$S"
    ok "Chroot script → /mnt/archwizard-configure.sh  ($(wc -l < "$S") lines)"
}

run_chroot() {
    section "arch-chroot"
    run "arch-chroot /mnt /archwizard-configure.sh"
    ok "Chroot done"
    # resolv.conf symlink must be created from HOST after chroot releases the bind-mount
    run "ln -sf ../run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf"
    ok "resolv.conf → systemd-resolved stub"
}

# =============================================================================
#  PHASE 6 — VERIFY + CLEANUP
# =============================================================================

verify_installation() {
    section "Verification"
    local issues=0

    local kernel_path="/mnt/boot/vmlinuz-${KERNEL}"
    if [[ -f "$kernel_path" ]]; then ok "Kernel: $kernel_path"
    else warn "Kernel NOT found: $kernel_path"; issues=$(( issues + 1 )); fi

    local initrd_path="/mnt/boot/initramfs-${KERNEL}.img"
    if [[ -f "$initrd_path" ]]; then ok "initramfs: $initrd_path"
    else warn "initramfs NOT found"; issues=$(( issues + 1 )); fi
    if [[ -f "/mnt/boot/initramfs-${KERNEL}-fallback.img" ]]; then ok "Fallback initramfs OK"
    else warn "Fallback initramfs missing"; issues=$(( issues + 1 )); fi

    if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
        if [[ "$BOOTLOADER" == "grub" ]]; then
            if efibootmgr 2>/dev/null | grep -qi "arch"; then ok "GRUB EFI entry in NVRAM"
            else warn "No Arch EFI entry in NVRAM"; issues=$(( issues + 1 )); fi
            if [[ -f "/mnt/boot/grub/grub.cfg" ]]; then ok "grub.cfg found"
            else warn "grub.cfg missing"; issues=$(( issues + 1 )); fi
        elif [[ "$BOOTLOADER" == "systemd-boot" ]]; then
            if [[ -f "/mnt/boot/loader/entries/arch.conf" ]]; then ok "systemd-boot arch.conf OK"
            else warn "systemd-boot entry missing"; issues=$(( issues + 1 )); fi
        fi
    else
        if dd if="$DISK_ROOT" bs=512 count=1 2>/dev/null | strings | grep -qi "grub"; then
            ok "GRUB in MBR of $DISK_ROOT"
        else
            warn "GRUB not detected in MBR"; issues=$(( issues + 1 ))
        fi
    fi

    if [[ -f "/mnt/etc/fstab" ]]; then
        local n; n=$(grep -c "^[^#]" /mnt/etc/fstab 2>/dev/null || echo 0)
        if (( n > 0 )); then ok "fstab: $n entries"
        else warn "fstab empty"; issues=$(( issues + 1 )); fi
        if grep -q "^UUID=" /mnt/etc/fstab 2>/dev/null; then ok "fstab uses UUIDs"
        else warn "fstab not UUID-based"; issues=$(( issues + 1 )); fi
    else
        warn "fstab missing"; issues=$(( issues + 1 ))
    fi

    for svc in NetworkManager systemd-resolved; do
        if [[ -e "/mnt/etc/systemd/system/multi-user.target.wants/${svc}.service" ]] \
           || [[ -e "/mnt/etc/systemd/system/network-online.target.wants/${svc}.service" ]]; then
            ok "$svc enabled"
        else
            warn "$svc NOT enabled"; issues=$(( issues + 1 ))
        fi
    done

    if [[ -s "/mnt/etc/hostname" ]]; then ok "Hostname: $(cat /mnt/etc/hostname)"
    else warn "Hostname not set"; issues=$(( issues + 1 )); fi

    blank
    if (( issues == 0 )); then ok "All checks passed."
    else warn "$issues issue(s) — review warnings above."; fi
    blank
}

finish() {
    section "Cleanup"
    run "rm -f /mnt/archwizard-configure.sh"
    run "sync"; run "swapoff -a" || true; run "umount -R /mnt" || true
    if [[ "$USE_LUKS" == true && "$DRY_RUN" == false ]]; then
        cryptsetup close cryptroot 2>/dev/null || true
        cryptsetup close crypthome 2>/dev/null || true
    fi
    ok "Filesystems unmounted"
    blank
    echo -e "${GREEN}${BOLD}"
    echo "  ╔═══════════════════════════════════════════════════╗"
    echo "  ║   🎉  ArchWizard 6.0 — Installation complete!    ║"
    echo "  ║                                                   ║"
    echo "  ║   Log: /tmp/archwizard.log                        ║"
    echo "  ║   ➜  Remove installation media                    ║"
    echo "  ║   ➜  Type 'reboot'                                ║"
    echo "  ╚═══════════════════════════════════════════════════╝"
    echo -e "${NC}"
    if confirm "Reboot now?" "y"; then run "reboot"
    else info "Run 'reboot' when ready. Log: $LOG_FILE"; fi
}

# =============================================================================
#  MAIN
# =============================================================================
main() {
    local _prev=""
    for arg in "$@"; do
        case "$arg" in
            --dry-run)     DRY_RUN=true ;;
            --verbose)     VERBOSE=true ;;
            --load-config) : ;;
            --help|-h)
                echo "Usage: bash ArchWizard_6_0.sh [--dry-run] [--verbose] [--load-config FILE]"
                exit 0 ;;
            *) [[ "$_prev" == "--load-config" ]] && CONFIG_FILE="$arg" ;;
        esac
        _prev="$arg"
    done
    [[ "$VERBOSE" == true ]] && set -x

    show_banner
    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN: no disk writes."
    [[ "$VERBOSE" == true ]] && warn "VERBOSE: set -x active."

    # Phase 1 — questionnaire
    if [[ -n "$CONFIG_FILE" ]]; then
        sanity_checks; load_config "$CONFIG_FILE"
    else
        sanity_checks; choose_keyboard; discover_disks; select_disks
        partition_wizard; configure_system; configure_users
        choose_kernel; choose_bootloader; choose_desktop; choose_extras
        save_config
    fi

    # Phase 2 — summary + confirmation gate
    show_summary

    # Phase 3 — disk operations
    replace_partition; resize_partitions; create_partitions
    setup_luks; format_filesystems; create_subvolumes; mount_filesystems

    # Phase 4 — base install
    setup_mirrors; install_base

    # Phase 5 — configure
    generate_chroot_script; run_chroot

    # Phase 6 — verify + done
    verify_installation; finish
}

main "$@"
