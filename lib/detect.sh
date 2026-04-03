#!/usr/bin/env bash
# =============================================================================
#  lib/detect.sh — Step 1: environment detection + keyboard
#
#  Also owns the shared low-level helpers used by disk.sh and partition.sh:
#    part_name()          — device naming (NVMe vs SATA)
#    _is_protected()      — partition guard
#    probe_os_from_part() — OS detection from a block device
#
#  Architecture: sanity_checks() and choose_keyboard() are UI functions
#  that call pure detection helpers. Nothing here writes to disk.
# =============================================================================

# -----------------------------------------------------------------------------
#  Pure helpers — no gum, no disk writes
# -----------------------------------------------------------------------------

# part_name DISK NUM → /dev/nvme0n1p1 or /dev/sda1
function part_name() {
    # inputs: disk_path num / outputs: partition device path
    local disk="$1" num="$2"
    if [[ "$disk" == *"nvme"* || "$disk" == *"mmcblk"* ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

# _is_protected PART → 0 if in PROTECTED_PARTS[], 1 otherwise
function _is_protected() {
    # inputs: partition_path / outputs: exit code
    local p="$1"
    local pp
    for pp in "${PROTECTED_PARTS[@]+"${PROTECTED_PARTS[@]}"}"; do
        if [[ "$pp" == "$p" ]]; then return 0; fi
    done
    return 1
}

# probe_os_from_part PART → sets PROBE_OS_RESULT
# Detection order: crypto_LUKS → ntfs → mount → btrfs subvols → label fallback
PROBE_OS_RESULT=""
function probe_os_from_part() {
    # inputs: partition_path / outputs: PROBE_OS_RESULT global
    local p="$1"
    PROBE_OS_RESULT=""
    local fstype
    fstype=$(blkid -s TYPE -o value "$p" 2>/dev/null || echo "")

    if [[ "$fstype" == "crypto_LUKS" ]]; then
        PROBE_OS_RESULT="[encrypted]"
        return 0
    fi

    if [[ "$fstype" == "ntfs" ]]; then
        local lbl
        lbl=$(blkid -s LABEL -o value "$p" 2>/dev/null || echo "")
        PROBE_OS_RESULT="${lbl:-Windows}"
        return 0
    fi

    local _mnt="/tmp/archwizard_probe_$$"
    mkdir -p "$_mnt"

    # Inner helper — reads /etc/os-release from a mount point
    _osrel() {
        local m="$1" n=""
        if [[ ! -f "$m/etc/os-release" ]]; then return 0; fi
        n=$(grep '^PRETTY_NAME=' "$m/etc/os-release" \
            | cut -d= -f2- | tr -d '"' | head -1)
        if [[ -z "$n" ]]; then
            n=$(grep '^NAME=' "$m/etc/os-release" \
                | cut -d= -f2- | tr -d '"' | head -1 || true)
        fi
        echo "$n"
    }

    if mount -o ro,noexec,nosuid "$p" "$_mnt" 2>/dev/null; then
        PROBE_OS_RESULT=$(_osrel "$_mnt") || true
        umount "$_mnt" 2>/dev/null || true
        if [[ -n "$PROBE_OS_RESULT" ]]; then
            rmdir "$_mnt" 2>/dev/null
            return 0
        fi
    fi

    if [[ "$fstype" == "btrfs" ]]; then
        local sv
        for sv in @ @root root arch debian ubuntu fedora opensuse manjaro; do
            if mount -o ro,noexec,nosuid,subvol="$sv" "$p" "$_mnt" 2>/dev/null; then
                PROBE_OS_RESULT=$(_osrel "$_mnt") || true
                umount "$_mnt" 2>/dev/null || true
                if [[ -n "$PROBE_OS_RESULT" ]]; then
                    rmdir "$_mnt" 2>/dev/null
                    return 0
                fi
            fi
        done
    fi

    rmdir "$_mnt" 2>/dev/null || true
    local lbl
    lbl=$(blkid -s LABEL -o value "$p" 2>/dev/null || echo "")
    PROBE_OS_RESULT="${lbl:-Linux (${fstype:-unknown})}"
    return 0
}

# _refresh_partitions DISK — inform kernel of new partition table
# Call DIRECTLY — never via run()/eval (shell function is lost in eval subshell)
# Call ONCE after batching all sgdisk -d deletions, not after each individual one
function _refresh_partitions() {
    # inputs: disk_path / side-effects: kernel partition table updated
    local disk="$1" attempt
    udevadm settle --timeout=10 2>/dev/null || true
    for attempt in 1 2 3; do
        if partprobe "$disk" 2>/dev/null; then
            udevadm settle --timeout=5 2>/dev/null || true
            sleep 1; ok "Kernel partition table updated"; return 0
        fi
        warn "partprobe attempt ${attempt}/3 — retrying in 2s…"
        udevadm settle --timeout=5 2>/dev/null || true
        sleep 2
    done
    if partx -u "$disk" 2>/dev/null; then
        udevadm settle --timeout=5 2>/dev/null || true
        sleep 1; ok "Kernel partition table updated via partx"; return 0
    fi
    if blockdev --rereadpt "$disk" 2>/dev/null; then
        udevadm settle --timeout=5 2>/dev/null || true
        sleep 1; ok "Kernel partition table updated via blockdev"; return 0
    fi
    udevadm settle 2>/dev/null || true; sleep 3
    warn "Could not confirm kernel saw partition changes — continuing."
}

# _detect_cpu → sets CPU_VENDOR
function _detect_cpu() {
    # inputs: /proc/cpuinfo / outputs: CPU_VENDOR global
    if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
        CPU_VENDOR="intel"
    elif grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
        CPU_VENDOR="amd"
    else
        CPU_VENDOR="unknown"
    fi
}

# _detect_gpu → sets GPU_VENDOR
function _detect_gpu() {
    # inputs: lspci / outputs: GPU_VENDOR global
    if lspci 2>/dev/null | grep -qi "nvidia"; then
        GPU_VENDOR="nvidia"
    elif lspci 2>/dev/null | grep -qi "amd.*vga\|vga.*amd\|radeon"; then
        GPU_VENDOR="amd"
    elif lspci 2>/dev/null | grep -qi "intel.*vga\|vga.*intel"; then
        GPU_VENDOR="intel"
    else
        GPU_VENDOR="unknown"
    fi
}

# _detect_firmware → sets FIRMWARE_MODE ("uefi" or "bios")
function _detect_firmware() {
    # inputs: /sys/firmware/efi / outputs: FIRMWARE_MODE global
    if [[ -d /sys/firmware/efi/efivars ]]; then
        FIRMWARE_MODE="uefi"
    else
        FIRMWARE_MODE="bios"
    fi
}

# _check_net → returns 0 if internet reachable, 1 otherwise
function _check_net() {
    # inputs: none / outputs: exit code
    ping -c 1 -W 3 8.8.8.8 &>/dev/null || ping -c 1 -W 3 1.1.1.1 &>/dev/null
}

# _list_wifi_ifaces → prints WiFi interface names, one per line
function _list_wifi_ifaces() {
    # inputs: iw dev / outputs: interface names to stdout
    iw dev 2>/dev/null | awk '/Interface/{print $2}' || true
}

# _check_tools → sets MISSING_TOOLS array
MISSING_TOOLS=()
function _check_tools() {
    # inputs: command list / outputs: MISSING_TOOLS global
    MISSING_TOOLS=()
    local tools=(sgdisk mkfs.fat mkfs.btrfs arch-chroot pacstrap
                 genfstab blkid lsblk parted)
    local t
    for t in "${tools[@]}"; do
        if ! command -v "$t" &>/dev/null; then
            MISSING_TOOLS+=("$t")
        fi
    done
}

# -----------------------------------------------------------------------------
#  sanity_checks — Step 1 UI function
# -----------------------------------------------------------------------------

function sanity_checks() {
    # inputs: none / side-effects: sets FIRMWARE_MODE CPU_VENDOR GPU_VENDOR
    section "Pre-flight checks"

    # Root
    run_spin "Checking root privileges…" "sleep 0.1"
    if [[ $EUID -ne 0 ]]; then
        die "Must run as root.\nBoot from the official Arch ISO and run as root."
    fi
    ok "Running as root"

    # Firmware
    run_spin "Detecting firmware mode…" "sleep 0.1"
    _detect_firmware
    if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
        ok "Firmware: UEFI"
    else
        warn "Firmware: BIOS/Legacy — GRUB+MBR only; systemd-boot unavailable."
    fi

    # Network — try direct, then offer WiFi helper
    if ! _check_net; then
        warn "No internet connection detected."
        blank

        local wifi_ifaces=()
        while IFS= read -r iface; do
            if [[ -n "$iface" ]]; then wifi_ifaces+=("$iface"); fi
        done < <(_list_wifi_ifaces)

        if [[ ${#wifi_ifaces[@]} -gt 0 ]]; then
            info "WiFi interface(s) found: ${wifi_ifaces[*]}"
            blank

            if [[ "${NO_GUM:-false}" == false ]]; then
                gum style \
                    --border        normal \
                    --border-foreground "$GUM_C_DIM" \
                    --padding       "0 2" \
                    --width         "$GUM_WIDTH" \
                    "$(_clr "$GUM_C_INFO" "iwctl quick guide")" "" \
                    "  device list" \
                    "  station ${wifi_ifaces[0]} scan" \
                    "  station ${wifi_ifaces[0]} get-networks" \
                    "  station ${wifi_ifaces[0]} connect \"YourSSID\"" \
                    "  exit" 2>/dev/null || true
                blank
            fi

            if confirm_gum "Open iwctl to connect to WiFi?"; then
                iwctl </dev/tty >/dev/tty 2>/dev/tty || true
                blank
                info "Checking connectivity…"
                sleep 3
                if _check_net; then
                    ok "Internet connected via WiFi"
                else
                    die "Still no connectivity.\nCheck cable or use: iwctl / nmtui / dhcpcd <iface>"
                fi
            else
                die "No internet.\nConnect manually then re-run ArchWizard."
            fi
        else
            die "No internet and no WiFi interface found.\nCheck your network connection."
        fi
    else
        ok "Internet OK"
    fi

    # Required prerequisites (gum, git, archlinux-keyring)
    # Run AFTER network is confirmed so pacman can reach mirrors.
    run_spin "Checking prerequisites…" "sleep 0.1"
    local _missing_prereqs=()
    command -v gum &>/dev/null || _missing_prereqs+=("gum")
    command -v git &>/dev/null || _missing_prereqs+=("git")

    if [[ ${#_missing_prereqs[@]} -gt 0 ]]; then
        blank
        warn "Missing recommended tools: ${_missing_prereqs[*]}"
    fi
    blank
    if confirm_gum "Install / refresh prerequisites? (gum  git  archlinux-keyring)"; then
        run_spin "Syncing package databases…"   "pacman -Sy  --noconfirm"
        run_spin "Installing prerequisites…" \
            "pacman -S --noconfirm --needed gum git archlinux-keyring"
        # If gum was just installed, activate it for the rest of the wizard.
        if command -v gum &>/dev/null && [[ "${NO_GUM:-false}" == true ]]; then
            NO_GUM=false
            ok "gum activated — switching to rich UI"
        fi
        ok "Prerequisites ready"
    elif [[ ${#_missing_prereqs[@]} -gt 0 ]]; then
        warn "Proceeding without: ${_missing_prereqs[*]} — some features may degrade."
    fi
    blank

    # Required tools
    run_spin "Checking required tools…" "sleep 0.1"
    _check_tools
    if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
        die "Missing tools: ${MISSING_TOOLS[*]}\nBoot from the official Arch ISO."
    fi
    ok "All required tools present"

    # CPU & GPU
    _detect_cpu
    _detect_gpu
    ok "CPU: ${CPU_VENDOR}  |  GPU: ${GPU_VENDOR}"

    # NTP — fire and forget; don't block on it
    timedatectl set-ntp true &>/dev/null &
    disown
    ok "NTP sync requested"
}

# -----------------------------------------------------------------------------
#  choose_keyboard — Step 1 UI function (second half)
# -----------------------------------------------------------------------------

function choose_keyboard() {
    # inputs: none / side-effects: sets KEYMAP global, calls loadkeys
    section "Keyboard layout"

    local common_keymaps=(
        "us          — US QWERTY"
        "fr-latin1   — French AZERTY"
        "de-latin1   — German QWERTZ"
        "uk          — British QWERTY"
        "es          — Spanish"
        "it          — Italian"
        "be-latin1   — Belgian AZERTY"
        "pt-latin1   — Portuguese"
        "ru          — Russian"
        "pl2         — Polish"
        "dvorak      — Dvorak"
        "colemak     — Colemak"
        "$BACK"
        "Other…      — type manually"
    )

    local selection
    selection=$(choose_one "fr-latin1   — French AZERTY" "${common_keymaps[@]}")

    if [[ "$selection" == "$BACK" ]]; then return 1; fi

    if [[ "$selection" == "Other…"* ]]; then
        local manual
        manual=$(input_gum "Keymap name  (e.g. fr-latin1, pl2, jp106)" "us")
        if [[ "$manual" == "$BACK" || -z "$manual" ]]; then return 1; fi
        KEYMAP="$manual"
    else
        KEYMAP=$(echo "$selection" | awk '{print $1}')
    fi

    # Validate against installed keymaps
    if find /usr/share/kbd/keymaps \
            -name "${KEYMAP}.map.gz" \
            -o -name "${KEYMAP}.map" \
            2>/dev/null | grep -q .; then
        run "loadkeys $KEYMAP"
        ok "Keymap: ${KEYMAP}"
    else
        warn "Keymap '${KEYMAP}' not found — falling back to 'us'."
        KEYMAP="us"
        run "loadkeys us"
    fi
    return 0
}
