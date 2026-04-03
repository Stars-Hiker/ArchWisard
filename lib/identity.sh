#!/usr/bin/env bash
# =============================================================================
#  lib/identity.sh — Steps 5-8: system identity, users, kernel/bootloader,
#                    desktop & extras, and the Phase 9 summary gate
#
#  All functions return 1 when user picks ← Back.
#  No gum calls inside logic — only inside UI functions.
# =============================================================================

# =============================================================================
#  Step 5 — System identity
# =============================================================================

function configure_system() {
    # inputs: none / side-effects: HOSTNAME GRUB_ENTRY_NAME TIMEZONE LOCALE
    section "System identity"

    # Hostname
    while true; do
        HOSTNAME=$(input_gum "Hostname" "${HOSTNAME:-archlinux}")
        if [[ "$HOSTNAME" == "$BACK" ]]; then return 1; fi
        if [[ "$HOSTNAME" =~ ^[a-zA-Z][a-zA-Z0-9-]{0,62}$ ]]; then break; fi
        warn "Invalid — letters, digits, hyphens; start with a letter; max 63 chars."
    done
    blank

    # GRUB entry label
    info "Boot menu label — shown in GRUB / systemd-boot at startup."
    blank
    local grub_input
    grub_input=$(input_gum "Boot menu name" \
        "${GRUB_ENTRY_NAME:-Arch Linux (${HOSTNAME})}")
    if [[ "$grub_input" == "$BACK" ]]; then return 1; fi
    GRUB_ENTRY_NAME="${grub_input:-Arch Linux (${HOSTNAME})}"
    blank

    # Timezone
    local tz_common=(
        "Europe/Paris"      "Europe/London"     "Europe/Berlin"
        "Europe/Rome"       "Europe/Madrid"     "Europe/Amsterdam"
        "Europe/Brussels"   "Europe/Warsaw"     "UTC"
        "America/New_York"  "America/Chicago"   "America/Los_Angeles"
        "America/Sao_Paulo" "Asia/Tokyo"        "Asia/Shanghai"
        "Asia/Kolkata"      "Australia/Sydney"
        "Other… — type manually"
        "$BACK"
    )
    info "Select timezone:"
    blank
    local tz_sel
    tz_sel=$(choose_one "${TIMEZONE:-Europe/Paris}" "${tz_common[@]}")
    if [[ "$tz_sel" == "$BACK" ]]; then return 1; fi

    if [[ "$tz_sel" == "Other…"* ]]; then
        while true; do
            TIMEZONE=$(input_gum "Timezone  (e.g. Europe/Paris)" "UTC")
            if [[ "$TIMEZONE" == "$BACK" ]]; then return 1; fi
            if [[ -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then break; fi
            warn "Not found. Browse: ls /usr/share/zoneinfo/"
        done
    else
        TIMEZONE="$tz_sel"
    fi
    ok "Timezone: ${TIMEZONE}"
    blank

    # Locale
    local locale_common=(
        "en_US.UTF-8"  "en_GB.UTF-8"  "fr_FR.UTF-8"  "de_DE.UTF-8"
        "es_ES.UTF-8"  "it_IT.UTF-8"  "nl_NL.UTF-8"  "pt_PT.UTF-8"
        "pt_BR.UTF-8"  "ru_RU.UTF-8"  "ja_JP.UTF-8"  "zh_CN.UTF-8"
        "Other… — type manually"
        "$BACK"
    )
    info "Select locale:"
    blank
    local locale_sel
    locale_sel=$(choose_one "${LOCALE:-fr_FR.UTF-8}" "${locale_common[@]}")
    if [[ "$locale_sel" == "$BACK" ]]; then return 1; fi

    if [[ "$locale_sel" == "Other…"* ]]; then
        while true; do
            LOCALE=$(input_gum "Locale  (e.g. en_US.UTF-8)" "en_US.UTF-8")
            if [[ "$LOCALE" == "$BACK" ]]; then return 1; fi
            if grep -q "^#\?${LOCALE} " /etc/locale.gen 2>/dev/null \
               || find /usr/share/i18n/locales -name "${LOCALE%%.*}" \
                  2>/dev/null | grep -q .; then break; fi
            warn "Locale '${LOCALE}' not found — format: en_US.UTF-8"
        done
    else
        LOCALE="$locale_sel"
    fi
    ok "Locale: ${LOCALE}"
    blank

    # Confirmation box
    if [[ "${NO_GUM:-false}" == false ]]; then
        gum style \
            --border        rounded \
            --border-foreground "$GUM_C_OK" \
            --padding       "0 2" \
            --width         "$GUM_WIDTH" \
            "$(_clr "$GUM_C_OK" "  Hostname : ${HOSTNAME}")" \
            "$(_clr "$GUM_C_OK" "  Boot name: ${GRUB_ENTRY_NAME}")" \
            "$(_clr "$GUM_C_OK" "  Timezone : ${TIMEZONE}")" \
            "$(_clr "$GUM_C_OK" "  Locale   : ${LOCALE}")" \
            2>/dev/null || true
    else
        ok "Hostname: ${HOSTNAME}  |  TZ: ${TIMEZONE}  |  Locale: ${LOCALE}"
    fi
    blank
    return 0
}

# =============================================================================
#  Step 6 — User accounts
# =============================================================================

function configure_users() {
    # inputs: none / side-effects: USERNAME USER_PASSWORD ROOT_PASSWORD
    section "User accounts"

    info "Username: lowercase letters, digits, underscores, hyphens."
    info "Must start with a letter or underscore."
    blank

    while true; do
        USERNAME=$(input_gum "Username" "${USERNAME:-archuser}")
        if [[ "$USERNAME" == "$BACK" ]]; then return 1; fi
        if [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then break; fi
        warn "Invalid username."
    done
    ok "User: ${USERNAME}  (groups: wheel audio video storage optical)"
    blank

    USER_PASSWORD=$(password_gum "Password for '${USERNAME}'")
    ok "User password set."
    blank

    info "Root password — for emergency console access only."
    blank
    ROOT_PASSWORD=$(password_gum "Root password")
    ok "Root password set."
    blank
    return 0
}

# =============================================================================
#  Step 7 — Kernel & bootloader
# =============================================================================

function choose_kernel_bootloader() {
    # inputs: DUAL_BOOT FIRMWARE_MODE / side-effects: KERNEL KERNELS BOOTLOADER SECURE_BOOT
    section "Kernel"
    blank
    info "Space to toggle, Enter to confirm. Multiple kernels can be installed."
    blank

    local k_options=(
        "linux          — latest stable  (recommended)"
        "linux-lts      — long-term support, slower updates"
        "linux-zen      — desktop responsiveness optimised"
        "linux-hardened — security-hardened, extra mitigations"
    )

    local selected_k_lines
    mapfile -t selected_k_lines < <(choose_many \
        "linux          — latest stable  (recommended)" \
        "${k_options[@]}")

    KERNELS=()
    if [[ ${#selected_k_lines[@]} -eq 0 ]]; then
        warn "No kernel selected — defaulting to linux."
        KERNELS=("linux")
    else
        local _kl
        for _kl in "${selected_k_lines[@]}"; do
            KERNELS+=("${_kl%% *}")
        done
    fi
    KERNEL="${KERNELS[0]}"
    ok "Kernel(s): ${KERNELS[*]}"
    blank

    section "Bootloader"
    blank

    if [[ "$DUAL_BOOT" == true ]]; then
        info "Multi-boot active — detected:"
        local sys
        for sys in "${EXISTING_SYSTEMS[@]+"${EXISTING_SYSTEMS[@]}"}"; do
            info "    →  ${sys}"
        done
        info "    →  Arch Linux  (this install)"
        blank
        warn "GRUB strongly recommended — os-prober detects all OSes automatically."
        blank
    fi

    if [[ "$FIRMWARE_MODE" == "bios" ]]; then
        BOOTLOADER="grub"
        ok "GRUB  (only option in BIOS/Legacy mode)"
        info "Will install to MBR of ${DISK_ROOT}."
        blank
        return 0
    fi

    local bl_opt2
    if [[ "$DUAL_BOOT" == true ]]; then
        bl_opt2="systemd-boot   — NOT recommended for multi-boot"
    else
        bl_opt2="systemd-boot   — minimal, fast, single-OS installs"
    fi

    local bl_sel
    bl_sel=$(choose_one \
        "GRUB           — recommended, os-prober support" \
        "GRUB           — recommended, os-prober support" \
        "$bl_opt2" \
        "$BACK")
    if [[ "$bl_sel" == "$BACK" ]]; then return 1; fi

    case "${bl_sel%% *}" in
        systemd-boot|systemd*)
            BOOTLOADER="systemd-boot"
            if [[ "$DUAL_BOOT" == true ]]; then
                blank
                warn "Other OSes will NOT appear in the boot menu automatically."
                blank
                if ! confirm_gum "Proceed with systemd-boot anyway?"; then
                    BOOTLOADER="grub"
                    ok "Switched to GRUB."
                fi
            fi ;;
        *) BOOTLOADER="grub" ;;
    esac
    ok "Bootloader: ${BOOTLOADER}"
    blank

    # Secure Boot — only on UEFI
    SECURE_BOOT=false
    if confirm_gum "Enable Secure Boot? (requires sbctl after first boot)"; then
        SECURE_BOOT=true
        warn "After first boot: sbctl enroll-keys --microsoft && sbctl sign-all"
    fi
    blank
    return 0
}

# =============================================================================
#  Step 8a — Desktop environment
# =============================================================================

function choose_desktop() {
    # inputs: none / side-effects: DESKTOPS[]
    section "Desktop environment"
    info "Space to toggle, Enter to confirm. Multiple selections allowed."
    blank

    local de_options=(
        "KDE Plasma    — feature-rich, Wayland-ready"
        "GNOME         — polished Wayland, great touchpad/HiDPI"
        "Hyprland      — dynamic tiling Wayland compositor"
        "Sway          — i3-compatible tiling WM, Wayland"
        "COSMIC        — Rust-based DE by System76  (alpha)"
        "XFCE          — lightweight GTK, classic and reliable"
        "None / TTY    — minimal, configure WM manually"
    )

    local selected_lines
    mapfile -t selected_lines < <(choose_many "" "${de_options[@]}")

    DESKTOPS=()
    if [[ ${#selected_lines[@]} -eq 0 ]]; then
        warn "No desktop selected — TTY only."
        DESKTOPS=("none")
    else
        local line
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
    ok "Desktop(s): ${DESKTOPS[*]}"
    blank
    return 0
}

# =============================================================================
#  Step 8b — Optional extras
# =============================================================================

function choose_extras() {
    # inputs: GPU_VENDOR ROOT_FS / side-effects: USE_* FIREWALL AUR_HELPER
    section "Optional extras"

    # ── Mirrors ──────────────────────────────────────────────────────────────
    _ui_subsection "Mirrors"
    if confirm_gum "Enable reflector? (auto-optimise mirrorlist on boot)"; then
        USE_REFLECTOR=true
        REFLECTOR_COUNTRIES=$(input_gum "Countries (comma-separated)" \
            "${REFLECTOR_COUNTRIES:-France,Germany}")
        REFLECTOR_NUMBER=$(input_gum "Mirror count" "${REFLECTOR_NUMBER:-10}")
        REFLECTOR_AGE=$(input_gum "Max age (hours)" "${REFLECTOR_AGE:-12}")
        ok "Reflector: ${REFLECTOR_NUMBER} mirrors | ${REFLECTOR_COUNTRIES} | ≤${REFLECTOR_AGE}h"
    else
        USE_REFLECTOR=false
    fi
    blank
    if confirm_gum "Enable multilib? (32-bit: Steam, Wine, Proton)"; then
        USE_MULTILIB=true; ok "Multilib: enabled"
    else
        USE_MULTILIB=false
    fi

    # ── Audio ─────────────────────────────────────────────────────────────────
    blank
    _ui_subsection "Audio"
    if confirm_gum "Install PipeWire? (modern audio server)"; then
        USE_PIPEWIRE=true; ok "PipeWire: enabled"
    else
        USE_PIPEWIRE=false
    fi

    # ── GPU ───────────────────────────────────────────────────────────────────
    blank
    _ui_subsection "GPU drivers"
    if [[ "$GPU_VENDOR" == "nvidia" ]]; then
        if confirm_gum "Install NVIDIA proprietary drivers?  (detected NVIDIA GPU)"; then
            USE_NVIDIA=true; ok "NVIDIA drivers: enabled"
        else
            USE_NVIDIA=false
        fi
    elif [[ "$GPU_VENDOR" == "amd" ]]; then
        info "AMD GPU — mesa always included in base."
        if confirm_gum "Install AMD Vulkan + video accel?  (vulkan-radeon, libva-mesa-driver)"; then
            USE_AMD_VULKAN=true; ok "AMD Vulkan: enabled"
        else
            USE_AMD_VULKAN=false
        fi
    elif [[ "$GPU_VENDOR" == "intel" ]]; then
        info "Intel GPU — mesa + i915 included in kernel."
    else
        info "GPU unidentified — mesa included in base."
    fi

    # ── Peripherals ───────────────────────────────────────────────────────────
    blank
    _ui_subsection "Peripherals"
    if confirm_gum "Bluetooth? (bluez + bluez-utils)"; then
        USE_BLUETOOTH=true; ok "Bluetooth: enabled"
    else
        USE_BLUETOOTH=false
    fi
    if confirm_gum "CUPS printing?"; then
        USE_CUPS=true; ok "CUPS: enabled"
    else
        USE_CUPS=false
    fi

    # ── Snapshots ─────────────────────────────────────────────────────────────
    blank
    _ui_subsection "btrfs snapshots"
    if [[ "$ROOT_FS" == "btrfs" ]]; then
        if confirm_gum "Snapper automatic snapshots?"; then
            USE_SNAPPER=true; ok "Snapper: enabled"
        else
            USE_SNAPPER=false
        fi
    else
        info "Snapper requires btrfs — skipped (root: ${ROOT_FS})."
        USE_SNAPPER=false
    fi

    # ── Firewall ──────────────────────────────────────────────────────────────
    blank
    _ui_subsection "Firewall"
    local fw_sel
    fw_sel=$(choose_one \
        "nftables  — stateful ruleset, Linux-native  (recommended)" \
        "nftables  — stateful ruleset, Linux-native  (recommended)" \
        "ufw       — Uncomplicated Firewall, simpler CLI" \
        "None      — no firewall  (not recommended)" \
        "$BACK")
    if [[ "$fw_sel" == "$BACK" ]]; then return 1; fi
    case "${fw_sel%% *}" in
        ufw)  FIREWALL="ufw"      ;;
        None) FIREWALL="none"     ;;
        *)    FIREWALL="nftables" ;;
    esac
    ok "Firewall: ${FIREWALL}"

    # ── AUR helper ────────────────────────────────────────────────────────────
    blank
    _ui_subsection "AUR helper"
    local aur_sel
    aur_sel=$(choose_one \
        "paru-bin  — pre-built binary, fast install  (recommended)" \
        "paru-bin  — pre-built binary, fast install  (recommended)" \
        "paru      — compiled from source" \
        "yay       — Go-based, most popular" \
        "None      — no AUR helper" \
        "$BACK")
    if [[ "$aur_sel" == "$BACK" ]]; then return 1; fi
    case "${aur_sel%% *}" in
        paru-bin) AUR_HELPER="paru-bin" ;;
        paru)     AUR_HELPER="paru"     ;;
        yay)      AUR_HELPER="yay"      ;;
        *)        AUR_HELPER="none"     ;;
    esac
    ok "AUR helper: ${AUR_HELPER}"
    blank
    return 0
}

# _ui_subsection — small section divider inside choose_extras
function _ui_subsection() {
    if [[ "${NO_GUM:-false}" == false ]]; then
        gum style --foreground "$GUM_C_ACCENT" --bold "  $*" 2>/dev/null \
            || printf '\033[1m  %s\033[0m\n' "$*"
    else
        printf '  ── %s\n' "$*"
    fi
    blank
}

# =============================================================================
#  Phase 9 — Summary + confirmation gate  (last safe exit)
# =============================================================================

function show_summary() {
    # inputs: all globals / side-effects: none  returns 0=proceed 1=back
    section "Installation summary"

    # Build display rows
    local rows=()

    # ── Disks & partitions ────────────────────────────────────────────────────
    rows+=("$(_clr "$GUM_C_ACCENT" "  DISKS & PARTITIONS")")
    rows+=("  Root disk  : $(_clr "$GUM_C_INFO" "$DISK_ROOT")")
    if [[ "${SEP_HOME:-false}" == true ]]; then
        rows+=("  Home disk  : $(_clr "$GUM_C_INFO" "$DISK_HOME")")
    fi
    if [[ "$REUSE_EFI" == true && -n "$EFI_PART" ]]; then
        rows+=("  EFI        : $(_clr "$GUM_C_INFO" "${EFI_PART}  (reused)")")
    fi
    rows+=("  Stack      : $(_clr "$GUM_C_INFO" "${STORAGE_STACK}")")
    rows+=("  Root       : $(_clr "$GUM_C_INFO" "${ROOT_SIZE} GB  [${ROOT_FS}]")")
    if [[ "${SEP_HOME:-false}" == true ]]; then
        rows+=("  Home       : $(_clr "$GUM_C_INFO" "${HOME_SIZE} GB  [${HOME_FS}]")")
    fi
    if [[ "$SWAP_TYPE" == "zram" && "${SWAP_SIZE:-}" == *% ]]; then
        rows+=("  Swap       : $(_clr "$GUM_C_INFO" "zram  (${SWAP_SIZE} of RAM)")")
    elif [[ -n "${SWAP_SIZE:-}" ]]; then
        rows+=("  Swap       : $(_clr "$GUM_C_INFO" "${SWAP_TYPE}  (${SWAP_SIZE} GB)")")
    else
        rows+=("  Swap       : $(_clr "$GUM_C_INFO" "${SWAP_TYPE}")")
    fi
    rows+=("  LUKS2      : $(_clr "$GUM_C_INFO" "${USE_LUKS}")")
    rows+=("  Multi-boot : $(_clr "$GUM_C_INFO" "${DUAL_BOOT}")")

    # Destructive plan
    if [[ ${#REPLACE_PARTS_ALL[@]} -gt 0 ]]; then
        local _rlist _rtotal=0 _rp _rg
        _rlist=$(printf '%s ' "${REPLACE_PARTS_ALL[@]}")
        for _rp in "${REPLACE_PARTS_ALL[@]}"; do
            _rg=$(( $(blockdev --getsize64 "$_rp" 2>/dev/null || echo 0) / 1073741824 ))
            _rtotal=$(( _rtotal + _rg ))
        done
        rows+=("  Plan       : $(_clr "$GUM_C_ERR" \
            "DELETE ${_rlist}(${_rtotal} GB — ALL DATA LOST)")")
    elif [[ -n "${REPLACE_PART:-}" ]]; then
        local _rep_gb
        _rep_gb=$(( $(blockdev --getsize64 "$REPLACE_PART" 2>/dev/null || echo 0) \
            / 1073741824 ))
        rows+=("  Plan       : $(_clr "$GUM_C_ERR" \
            "DELETE ${REPLACE_PART}  (${_rep_gb} GB — ALL DATA LOST)")")
    elif [[ -n "${RESIZE_PART:-}" ]]; then
        rows+=("  Plan       : $(_clr "$GUM_C_WARN" \
            "SHRINK ${RESIZE_PART} → ${RESIZE_NEW_GB} GB")")
    fi

    if [[ ${#EXISTING_SYSTEMS[@]} -gt 0 ]]; then
        local _sl
        _sl=$(IFS=', '; echo "${EXISTING_SYSTEMS[*]}")
        rows+=("  Keep       : $(_clr "$GUM_C_INFO" "${_sl}")")
    fi

    # ── System ────────────────────────────────────────────────────────────────
    rows+=("" "$(_clr "$GUM_C_ACCENT" "  SYSTEM")")
    rows+=("  Hostname   : $(_clr "$GUM_C_INFO" "${HOSTNAME}")")
    rows+=("  Boot label : $(_clr "$GUM_C_INFO" "${GRUB_ENTRY_NAME}")")
    rows+=("  Timezone   : $(_clr "$GUM_C_INFO" "${TIMEZONE}")")
    rows+=("  Locale     : $(_clr "$GUM_C_INFO" "${LOCALE}")")
    rows+=("  Keymap     : $(_clr "$GUM_C_INFO" "${KEYMAP}")")
    rows+=("  User       : $(_clr "$GUM_C_INFO" "${USERNAME}  (wheel/sudo)")")

    # ── Software ──────────────────────────────────────────────────────────────
    rows+=("" "$(_clr "$GUM_C_ACCENT" "  SOFTWARE")")
    rows+=("  Kernel     : $(_clr "$GUM_C_INFO" "${KERNELS[*]:-${KERNEL}}")")
    rows+=("  Bootloader : $(_clr "$GUM_C_INFO" "${BOOTLOADER}")")
    rows+=("  Secure Boot: $(_clr "$GUM_C_INFO" "${SECURE_BOOT}")")
    rows+=("  Desktop(s) : $(_clr "$GUM_C_INFO" "${DESKTOPS[*]:-none}")")
    rows+=("  AUR helper : $(_clr "$GUM_C_INFO" "${AUR_HELPER}")")
    rows+=("  PipeWire   : $(_clr "$GUM_C_INFO" "${USE_PIPEWIRE}")")
    rows+=("  Multilib   : $(_clr "$GUM_C_INFO" "${USE_MULTILIB}")")
    rows+=("  NVIDIA     : $(_clr "$GUM_C_INFO" "${USE_NVIDIA}")")
    if [[ "$GPU_VENDOR" == "amd" ]]; then
        rows+=("  AMD Vulkan : $(_clr "$GUM_C_INFO" "${USE_AMD_VULKAN}")")
    fi
    rows+=("  Bluetooth  : $(_clr "$GUM_C_INFO" "${USE_BLUETOOTH}")")
    rows+=("  CUPS       : $(_clr "$GUM_C_INFO" "${USE_CUPS}")")
    rows+=("  Snapper    : $(_clr "$GUM_C_INFO" "${USE_SNAPPER}")")
    rows+=("  Reflector  : $(_clr "$GUM_C_INFO" "${USE_REFLECTOR}")")
    rows+=("  Firewall   : $(_clr "$GUM_C_INFO" "${FIREWALL}")")

    if [[ "${NO_GUM:-false}" == false ]]; then
        gum style \
            --border        rounded \
            --border-foreground "$GUM_C_TITLE" \
            --padding       "0 1" \
            --width         "$GUM_WIDTH" \
            "${rows[@]}" 2>/dev/null || true
        blank
        gum style \
            --foreground        "$GUM_C_ERR" \
            --border            thick \
            --border-foreground "$GUM_C_ERR" \
            --padding           "0 2" \
            --width             "$GUM_WIDTH" \
            "  After this point your disk(s) will be modified." \
            "  This is the last safe exit." \
            2>/dev/null || true
    else
        local r; for r in "${rows[@]}"; do printf '%s\n' "$r"; done
        warn "After this point your disk(s) will be modified."
    fi
    blank

    if ! confirm_gum "Begin installation?"; then
        info "Aborted — no changes made."
        return 1
    fi
    return 0
}
