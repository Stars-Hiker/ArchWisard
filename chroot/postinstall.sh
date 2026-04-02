#!/usr/bin/env bash
# =============================================================================
#  lib/postinstall.sh — Post-install verification, cleanup, reboot
# =============================================================================

# =============================================================================
#  verify_installation
# =============================================================================

function verify_installation() {
    # inputs: KERNEL BOOTLOADER FIRMWARE_MODE / side-effects: none (read-only)
    section "Post-install verification"
    local issues=0

    # Kernel image
    local kpath="/mnt/boot/vmlinuz-${KERNEL}"
    if [[ -f "$kpath" ]]; then
        ok "Kernel: ${kpath}"
    else
        warn "Kernel NOT found: ${kpath}"
        issues=$(( issues + 1 ))
    fi

    # initramfs
    local ipath="/mnt/boot/initramfs-${KERNEL}.img"
    local fpath="/mnt/boot/initramfs-${KERNEL}-fallback.img"
    if [[ -f "$ipath" ]]; then ok "initramfs: ${ipath}"
    else warn "initramfs NOT found"; issues=$(( issues + 1 )); fi

    if [[ -f "$fpath" ]]; then ok "Fallback initramfs: present"
    else warn "Fallback initramfs: missing"; issues=$(( issues + 1 )); fi

    # Bootloader
    if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
        if [[ "$BOOTLOADER" == "grub" ]]; then
            if efibootmgr 2>/dev/null | grep -qi "arch"; then
                ok "GRUB: EFI entry in NVRAM"
            else
                warn "GRUB: no Arch EFI entry found in NVRAM"
                issues=$(( issues + 1 ))
            fi
            if [[ -f "/mnt/boot/grub/grub.cfg" ]]; then ok "grub.cfg: present"
            else warn "grub.cfg: missing"; issues=$(( issues + 1 )); fi
        elif [[ "$BOOTLOADER" == "systemd-boot" ]]; then
            if [[ -f "/mnt/boot/loader/entries/arch.conf" ]]; then
                ok "systemd-boot: arch.conf present"
            else
                warn "systemd-boot: arch.conf missing"
                issues=$(( issues + 1 ))
            fi
        fi
    else
        if dd if="$DISK_ROOT" bs=512 count=1 2>/dev/null \
           | strings | grep -qi "grub"; then
            ok "GRUB: signature in MBR of ${DISK_ROOT}"
        else
            warn "GRUB: not detected in MBR"
            issues=$(( issues + 1 ))
        fi
    fi

    # fstab
    if [[ -f "/mnt/etc/fstab" ]]; then
        local n
        n=$(grep -c "^[^#]" /mnt/etc/fstab 2>/dev/null || echo 0)
        if (( n > 0 )); then ok "fstab: ${n} active entries"
        else warn "fstab: empty"; issues=$(( issues + 1 )); fi
        if grep -q "^UUID=" /mnt/etc/fstab 2>/dev/null; then ok "fstab: uses UUIDs"
        else warn "fstab: not UUID-based"; issues=$(( issues + 1 )); fi
    else
        warn "fstab: missing"; issues=$(( issues + 1 ))
    fi

    # crypttab (if LUKS was used)
    if [[ "${USE_LUKS:-false}" == true ]]; then
        if [[ -f "/mnt/etc/crypttab" ]] && grep -q "cryptroot" /mnt/etc/crypttab; then
            ok "crypttab: cryptroot entry present"
        else
            warn "crypttab: cryptroot entry missing"
            issues=$(( issues + 1 ))
        fi
    fi

    # Core services
    local svc
    for svc in NetworkManager systemd-resolved; do
        if [[ -e "/mnt/etc/systemd/system/multi-user.target.wants/${svc}.service" ]] \
           || [[ -e "/mnt/etc/systemd/system/network-online.target.wants/${svc}.service" ]]; then
            ok "Service enabled: ${svc}"
        else
            warn "Service NOT enabled: ${svc}"
            issues=$(( issues + 1 ))
        fi
    done

    # Hostname
    if [[ -s "/mnt/etc/hostname" ]]; then
        ok "Hostname: $(cat /mnt/etc/hostname)"
    else
        warn "Hostname: not set"
        issues=$(( issues + 1 ))
    fi

    blank
    if (( issues == 0 )); then
        if [[ "${NO_GUM:-false}" == false ]]; then
            gum style --foreground "$GUM_C_OK" --bold \
                " ✔  All verification checks passed." 2>/dev/null \
                || ok "All verification checks passed."
        else
            ok "All verification checks passed."
        fi
    else
        warn "${issues} issue(s) — review warnings above."
    fi
    blank
}

# =============================================================================
#  finish — cleanup and reboot
# =============================================================================

function finish() {
    # inputs: USE_LUKS / side-effects: unmounts /mnt, optionally reboots
    section "Cleanup"

    run "rm -f /mnt/arch_configure.sh /mnt/arch_install_vars.sh"
    info "Unmounting all filesystems…"
    run "sync"
    run "swapoff -a" || true
    run "umount -R /mnt" || true

    if [[ "${USE_LUKS:-false}" == true && "$DRY_RUN" == false ]]; then
        cryptsetup close cryptroot  2>/dev/null || true
        cryptsetup close crypthome  2>/dev/null || true
    fi
    ok "Filesystems unmounted"

    blank
    if [[ "${NO_GUM:-false}" == false ]]; then
        gum style \
            --foreground        "$GUM_C_OK" \
            --border            double \
            --border-foreground "$GUM_C_OK" \
            --padding           "1 4" \
            --width             "$GUM_WIDTH" \
            "ArchWizard 7.0 — installation complete!" \
            "" \
            "Log: ${LOG_FILE}" \
            "" \
            "  ➜  Remove installation media" \
            "  ➜  Type 'reboot'" \
            2>/dev/null || true
    else
        ok "ArchWizard 7.0 — installation complete!"
        info "Log: ${LOG_FILE}"
        info "Remove installation media and reboot."
    fi
    blank

    if confirm_gum "Reboot now?"; then
        run "reboot"
    else
        info "Reboot manually when ready:  reboot"
        info "Log: ${LOG_FILE}"
    fi
}
