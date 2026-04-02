#!/usr/bin/env bash
# =============================================================================
#  lib/bootloader.sh — Host-side bootloader helpers
#
#  The actual bootloader INSTALL happens inside the chroot via
#  templates/chroot_base.sh. This file owns:
#
#    _bl_detect_existing()   — find installed bootloaders pre-install
#    _bl_efi_guard()         — validate EFI partition is sane before chroot
#    _bl_nvram_check()       — post-chroot: verify EFI entry was created
#    _bl_secureboot_prep()   — pre-chroot: install sbctl if Secure Boot wanted
#    _bl_grub_efi_workaround()  — copy fallback EFI binary for firmware bugs
#
#  Called from _exec_install() in state.sh, sandwiched around run_chroot().
# =============================================================================

# =============================================================================
#  _bl_detect_existing — scan NVRAM and ESP for existing bootloaders
#  Sets _BL_EXISTING[] array with names found
# =============================================================================
_BL_EXISTING=()
function _bl_detect_existing() {
    # inputs: FIRMWARE_MODE / side-effects: _BL_EXISTING global
    _BL_EXISTING=()
    if [[ "$FIRMWARE_MODE" != "uefi" ]]; then return 0; fi
    if ! command -v efibootmgr &>/dev/null; then return 0; fi

    local line _lbl
    while IFS= read -r line; do
        _lbl=$(echo "$line" \
            | sed 's/Boot[0-9A-Fa-f]*\*[[:space:]]*//' \
            | sed 's/[[:space:]]*[A-Z][A-Z](.*$//' \
            | sed 's/[[:space:]]*$//')
        if [[ -z "$_lbl" || ${#_lbl} -lt 2 ]]; then continue; fi
        if ! echo "$_lbl" | grep -q '[a-zA-Z]'; then continue; fi
        # Skip firmware/network noise
        if echo "$_lbl" | grep -qiE \
            "PXE|iPXE|Network|LAN|WAN|USB|CD-ROM|DVD|Optical|Recovery|\
Diagnostic|MemTest|Firmware|Setup|Admin|Shell|Manager|Internal"; then
            continue
        fi
        _BL_EXISTING+=("$_lbl")
    done < <(efibootmgr 2>/dev/null | grep -E '^Boot[0-9A-Fa-f]{4}\*' || true)
}

# =============================================================================
#  _bl_efi_guard — sanity checks on EFI_PART before we mount it
# =============================================================================
function _bl_efi_guard() {
    # inputs: EFI_PART FIRMWARE_MODE REUSE_EFI / side-effects: warns on issues
    if [[ "$FIRMWARE_MODE" != "uefi" ]]; then return 0; fi
    if [[ -z "${EFI_PART:-}" ]]; then
        die "EFI_PART is empty — cannot install bootloader."
    fi

    local esp_mb
    esp_mb=$(( $(blockdev --getsize64 "$EFI_PART" 2>/dev/null || echo 0) / 1048576 ))

    # Minimum 100 MB; warn below 260 MB (Windows Update needs headroom)
    if (( esp_mb < 100 )); then
        die "EFI partition ${EFI_PART} is only ${esp_mb} MB — too small."
    fi
    if (( esp_mb < 260 )); then
        warn "EFI partition is ${esp_mb} MB. 260 MB+ recommended for Windows coexistence."
    fi

    # Warn if reusing and free space is low
    if [[ "$REUSE_EFI" == true ]]; then
        local esp_free_kb
        esp_free_kb=$(df -k "$EFI_PART" 2>/dev/null | tail -1 | awk '{print $4}' || echo 0)
        local esp_free_mb=$(( esp_free_kb / 1024 ))
        if (( esp_free_mb < 50 )); then
            warn "Shared EFI partition has only ${esp_free_mb} MB free."
            warn "GRUB install may fail. Consider freeing space in the ESP."
        fi
    fi

    ok "EFI partition: ${EFI_PART}  (${esp_mb} MB)"
}

# =============================================================================
#  _bl_nvram_check — verify EFI boot entry was written after chroot
# =============================================================================
function _bl_nvram_check() {
    # inputs: BOOTLOADER FIRMWARE_MODE / side-effects: warns if entry missing
    if [[ "$FIRMWARE_MODE" != "uefi" ]]; then return 0; fi
    if ! command -v efibootmgr &>/dev/null; then return 0; fi

    if [[ "$BOOTLOADER" == "grub" ]]; then
        if efibootmgr 2>/dev/null | grep -qi "arch"; then
            ok "NVRAM: Arch EFI boot entry registered"
        else
            warn "NVRAM: No Arch EFI entry found — GRUB install may have failed."
            warn "  On next boot, enter BIOS setup and add /EFI/Arch-*/grubx64.efi manually."
        fi
    elif [[ "$BOOTLOADER" == "systemd-boot" ]]; then
        if [[ -f "/mnt/boot/loader/loader.conf" ]]; then
            ok "NVRAM: systemd-boot loader.conf present"
        else
            warn "NVRAM: systemd-boot loader.conf missing — install may have failed."
        fi
    fi
}

# =============================================================================
#  _bl_secureboot_prep — install sbctl in live env if Secure Boot requested
# =============================================================================
function _bl_secureboot_prep() {
    # inputs: SECURE_BOOT / side-effects: installs sbctl to /mnt if needed
    if [[ "${SECURE_BOOT:-false}" == false ]]; then return 0; fi

    section "Secure Boot preparation"
    info "sbctl will be installed inside the chroot via BOOTLOADER_PKGS."
    info "After first boot run:"
    info "  sudo sbctl create-keys"
    info "  sudo sbctl enroll-keys --microsoft"
    info "  sudo sbctl sign-all"
    blank
    ok "Secure Boot keys will be managed post-boot via sbctl"
}

# =============================================================================
#  _bl_grub_efi_fallback — copy GRUB binary to removable media path
#  Needed for firmware that ignores NVRAM and only boots \EFI\BOOT\BOOTX64.EFI
# =============================================================================
function _bl_grub_efi_fallback() {
    # inputs: BOOTLOADER FIRMWARE_MODE EFI_PART / side-effects: copies EFI binary
    if [[ "$BOOTLOADER" != "grub" || "$FIRMWARE_MODE" != "uefi" ]]; then return 0; fi

    local esp_mnt="/mnt/boot/efi"
    if [[ "$BOOTLOADER" == "systemd-boot" ]]; then esp_mnt="/mnt/boot"; fi

    # Find the Arch GRUB binary (path contains the bootloader-id we set)
    local arch_efi
    arch_efi=$(find "${esp_mnt}/EFI" -name "grubx64.efi" \
        ! -path "*/BOOT/*" 2>/dev/null | head -1 || echo "")

    if [[ -z "$arch_efi" ]]; then
        warn "GRUB EFI binary not found — skipping fallback copy."
        return 0
    fi

    local fallback_dir="${esp_mnt}/EFI/BOOT"
    local fallback_bin="${fallback_dir}/BOOTX64.EFI"

    mkdir -p "$fallback_dir"

    # Only overwrite if the existing BOOTX64.EFI is not a Windows bootmgr
    if [[ -f "$fallback_bin" ]]; then
        if strings "$fallback_bin" 2>/dev/null | grep -qi "windows"; then
            info "Existing BOOTX64.EFI appears to be Windows bootmgr — not overwriting."
            return 0
        fi
    fi

    run "cp ${arch_efi} ${fallback_bin}"
    ok "Fallback EFI: ${fallback_bin}  (firmware compatibility)"
}

# =============================================================================
#  bootloader_pre_chroot — called before generate_chroot_script
# =============================================================================
function bootloader_pre_chroot() {
    # inputs: all bootloader globals / side-effects: guards and prep
    _bl_efi_guard
    _bl_secureboot_prep
    _bl_detect_existing
    if [[ ${#_BL_EXISTING[@]} -gt 0 ]]; then
        info "Existing EFI entries: ${_BL_EXISTING[*]}"
    fi
}

# =============================================================================
#  bootloader_post_chroot — called after run_chroot
# =============================================================================
function bootloader_post_chroot() {
    # inputs: all bootloader globals / side-effects: fallback EFI copy + NVRAM check
    _bl_grub_efi_fallback
    _bl_nvram_check
}
