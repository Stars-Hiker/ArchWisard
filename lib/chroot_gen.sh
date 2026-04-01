#!/usr/bin/env bash
# =============================================================================
#  lib/chroot_gen.sh — Serialize installer state, deploy chroot template  ⚠
#
#  Architecture (replaces 300-line heredoc from original files):
#    1. _serialize_chroot_vars() → /mnt/arch_install_vars.sh
#       Unquoted EOF: all variables expand at write-time.
#       Every variable the chroot needs is explicitly listed here.
#
#    2. cp templates/chroot_base.sh → /mnt/arch_configure.sh
#       Template uses 'quoted EOF' blocks — real bash logic, no string embedding.
#       First line of template: source /arch_install_vars.sh
#
#    3. arch-chroot /mnt /arch_configure.sh
#
#    4. Cleanup: rm /mnt/arch_configure.sh /mnt/arch_install_vars.sh
# =============================================================================

# _compute_de_pkgs → sets DE_PKGS and DM_SERVICE globals
DE_PKGS=""
DM_SERVICE=""
function _compute_de_pkgs() {
    # inputs: DESKTOPS[] USE_MULTILIB USE_NVIDIA / side-effects: DE_PKGS DM_SERVICE
    DE_PKGS=""
    DM_SERVICE=""
    local has_wayland=false

    local de
    for de in "${DESKTOPS[@]+"${DESKTOPS[@]}"}"; do
        case "$de" in
            kde)
                DE_PKGS+=" plasma plasma-desktop plasma-nm plasma-pa plasma-workspace"
                DE_PKGS+=" sddm dolphin konsole kate spectacle gwenview ark kcalc"
                DE_PKGS+=" okular kdeconnect powerdevil plasma-disks"
                DM_SERVICE="sddm"; has_wayland=true ;;
            gnome)
                DE_PKGS+=" gnome gnome-extra gnome-tweaks gdm"
                DE_PKGS+=" gnome-software-packagekit-plugin"
                if [[ -z "$DM_SERVICE" ]]; then DM_SERVICE="gdm"; fi
                has_wayland=true ;;
            hyprland)
                DE_PKGS+=" hyprland waybar wofi kitty ttf-font-awesome noto-fonts"
                DE_PKGS+=" polkit-gnome xdg-desktop-portal-hyprland sddm"
                DM_SERVICE="sddm"; has_wayland=true ;;
            sway)
                DE_PKGS+=" sway waybar swaylock swayidle foot wofi brightnessctl"
                DE_PKGS+=" xdg-desktop-portal-wlr ly"
                if [[ -z "$DM_SERVICE" ]]; then DM_SERVICE="ly"; fi
                has_wayland=true ;;
            cosmic)
                DE_PKGS+=" cosmic cosmic-greeter"
                if [[ -z "$DM_SERVICE" ]]; then DM_SERVICE="cosmic-greeter"; fi
                has_wayland=true ;;
            xfce)
                DE_PKGS+=" xfce4 xfce4-goodies lightdm lightdm-gtk-greeter"
                DE_PKGS+=" gvfs xarchiver network-manager-applet mousepad ristretto"
                if [[ -z "$DM_SERVICE" ]]; then DM_SERVICE="lightdm"; fi ;;
            none) ;;
        esac
    done

    # sddm takes priority when KDE or Hyprland is present
    for de in "${DESKTOPS[@]+"${DESKTOPS[@]}"}"; do
        if [[ "$de" == "kde" || "$de" == "hyprland" ]]; then
            DM_SERVICE="sddm"; break
        fi
    done

    # NVIDIA Wayland extras
    if [[ "${USE_NVIDIA:-false}" == true && "$has_wayland" == true ]]; then
        NVIDIA_PKGS="${NVIDIA_PKGS} egl-wayland"
    fi
}

# _compute_nvidia_pkgs → sets NVIDIA_PKGS global
NVIDIA_PKGS=""
function _compute_nvidia_pkgs() {
    # inputs: USE_NVIDIA USE_MULTILIB / side-effects: NVIDIA_PKGS
    NVIDIA_PKGS=""
    if [[ "${USE_NVIDIA:-false}" == false ]]; then return 0; fi
    NVIDIA_PKGS="nvidia nvidia-utils nvidia-settings"
    if [[ "${USE_MULTILIB:-false}" == true ]]; then
        NVIDIA_PKGS+=" lib32-nvidia-utils"
    fi
}

# _compute_bootloader_pkgs → sets BOOTLOADER_PKGS global
BOOTLOADER_PKGS=""
function _compute_bootloader_pkgs() {
    # inputs: BOOTLOADER DUAL_BOOT USE_SNAPPER SECURE_BOOT FIRMWARE_MODE
    BOOTLOADER_PKGS="efibootmgr"
    if [[ "$BOOTLOADER" == "grub" ]]; then
        BOOTLOADER_PKGS+=" grub"
        if [[ "$DUAL_BOOT" == true ]]; then BOOTLOADER_PKGS+=" os-prober"; fi
        if [[ "${USE_SNAPPER:-false}" == true ]]; then BOOTLOADER_PKGS+=" grub-btrfs"; fi
    fi
    if [[ "${SECURE_BOOT:-false}" == true ]]; then BOOTLOADER_PKGS+=" sbctl"; fi
}

# _compute_sd_boot_vars → sets SD_INITRD_UCODE SD_OPTIONS globals
SD_INITRD_UCODE=""
SD_OPTIONS=""
function _compute_sd_boot_vars() {
    # inputs: CPU_VENDOR ROOT_FS USE_LUKS LUKS_UUID ROOT_UUID KERNEL
    if [[ "$CPU_VENDOR" != "unknown" ]]; then
        SD_INITRD_UCODE="initrd  /${CPU_VENDOR}-ucode.img\n"
    fi

    if [[ "$ROOT_FS" == "btrfs" ]]; then
        if [[ "${USE_LUKS:-false}" == true ]]; then
            SD_OPTIONS="cryptdevice=UUID=${LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet"
        else
            SD_OPTIONS="root=UUID=${ROOT_UUID} rootflags=subvol=@ rw quiet splash"
        fi
    else
        if [[ "${USE_LUKS:-false}" == true ]]; then
            SD_OPTIONS="cryptdevice=UUID=${LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot rw quiet"
        else
            SD_OPTIONS="root=UUID=${ROOT_UUID} rw quiet splash"
        fi
    fi
}

# -----------------------------------------------------------------------------
#  _serialize_chroot_vars — writes /mnt/arch_install_vars.sh
#  Unquoted EOF: all ${variables} expand at write-time. This is intentional.
# -----------------------------------------------------------------------------
function _serialize_chroot_vars() {
    # inputs: all globals / side-effects: /mnt/arch_install_vars.sh
    local _rdev="${ROOT_PART_MAPPED:-$ROOT_PART}"
    local ROOT_UUID="" LUKS_UUID="" HOME_LUKS_UUID=""

    if [[ "$DRY_RUN" == false ]]; then
        ROOT_UUID=$(blkid -s UUID -o value "$_rdev"       2>/dev/null || echo "ROOT-UUID")
        LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART"   2>/dev/null || echo "LUKS-UUID")
        # Home LUKS UUID — only if home was separately encrypted
        local _home_raw="${HOME_PART:-}"
        if [[ "$_home_raw" == "/dev/mapper/crypthome" ]]; then
            # The raw partition was remapped; find it via dmsetup
            local _home_raw_dev
            _home_raw_dev=$(dmsetup info -c --noheadings -o blkdevs_used crypthome \
                2>/dev/null | tr -d ' ' || echo "")
            if [[ -n "$_home_raw_dev" ]]; then
                HOME_LUKS_UUID=$(blkid -s UUID -o value "/dev/${_home_raw_dev}" \
                    2>/dev/null || echo "")
            fi
        fi
    else
        ROOT_UUID="DRY-ROOT-UUID"
        LUKS_UUID="DRY-LUKS-UUID"
    fi

    # Compute derived values
    _compute_de_pkgs
    _compute_nvidia_pkgs
    _compute_bootloader_pkgs
    _compute_sd_boot_vars

    # Get mkinitcpio hooks from storage.sh helper
    local MKINIT_HOOKS
    MKINIT_HOOKS=$(_mkinitcpio_hooks)

    # Unquoted heredoc — variables expand NOW at write-time
    cat > /mnt/arch_install_vars.sh << EOF
#!/usr/bin/env bash
# ArchWizard — chroot variables  (generated $(date '+%Y-%m-%d %H:%M:%S'))
# Sourced by /arch_configure.sh at the start of chroot execution.

# ── Hardware ──────────────────────────────────────────────────────────────────
CPU_VENDOR="${CPU_VENDOR}"
GPU_VENDOR="${GPU_VENDOR}"
FIRMWARE_MODE="${FIRMWARE_MODE}"

# ── Disk & partition ──────────────────────────────────────────────────────────
DISK_ROOT="${DISK_ROOT}"
DISK_HOME="${DISK_HOME:-$DISK_ROOT}"
EFI_PART="${EFI_PART:-}"
ROOT_PART="${ROOT_PART}"
ROOT_PART_MAPPED="${ROOT_PART_MAPPED:-}"
HOME_PART="${HOME_PART:-}"
SWAP_PART="${SWAP_PART:-}"

# ── UUIDs (expanded at write-time) ────────────────────────────────────────────
ROOT_UUID="${ROOT_UUID}"
LUKS_UUID="${LUKS_UUID}"
HOME_LUKS_UUID="${HOME_LUKS_UUID}"

# ── Storage stack ─────────────────────────────────────────────────────────────
STORAGE_STACK="${STORAGE_STACK}"
ROOT_FS="${ROOT_FS}"
HOME_FS="${HOME_FS}"
SEP_HOME=${SEP_HOME:-false}
SWAP_TYPE="${SWAP_TYPE}"
SWAP_SIZE="${SWAP_SIZE}"
USE_LUKS=${USE_LUKS}
LVM_VG="${LVM_VG:-arch_vg}"
LVM_LV_ROOT="${LVM_LV_ROOT:-root}"
LVM_LV_HOME="${LVM_LV_HOME:-home}"
ZFS_POOL="${ZFS_POOL:-zroot}"

# ── Multi-boot ────────────────────────────────────────────────────────────────
DUAL_BOOT=${DUAL_BOOT}
REUSE_EFI=${REUSE_EFI}

# ── System identity ───────────────────────────────────────────────────────────
HOSTNAME="${HOSTNAME}"
GRUB_ENTRY_NAME="${GRUB_ENTRY_NAME}"
TIMEZONE="${TIMEZONE}"
LOCALE="${LOCALE}"
KEYMAP="${KEYMAP}"

# ── Users (passwords via chpasswd stdin — never in process argv) ──────────────
USERNAME="${USERNAME}"
USER_PASSWORD="${USER_PASSWORD}"
ROOT_PASSWORD="${ROOT_PASSWORD}"

# ── Kernel & bootloader ───────────────────────────────────────────────────────
KERNEL="${KERNEL}"
BOOTLOADER="${BOOTLOADER}"
SECURE_BOOT=${SECURE_BOOT:-false}
BOOTLOADER_PKGS="${BOOTLOADER_PKGS}"

# systemd-boot entries (computed above)
SD_INITRD_UCODE="${SD_INITRD_UCODE}"
SD_OPTIONS="${SD_OPTIONS}"

# ── Desktop & extras ──────────────────────────────────────────────────────────
DESKTOPS=(${DESKTOPS[@]+"${DESKTOPS[@]}"})
DE_PKGS="${DE_PKGS}"
DM_SERVICE="${DM_SERVICE}"
NVIDIA_PKGS="${NVIDIA_PKGS}"
AUR_HELPER="${AUR_HELPER}"
USE_REFLECTOR=${USE_REFLECTOR:-false}
REFLECTOR_COUNTRIES="${REFLECTOR_COUNTRIES}"
REFLECTOR_NUMBER="${REFLECTOR_NUMBER}"
REFLECTOR_AGE="${REFLECTOR_AGE}"
REFLECTOR_PROTOCOL="${REFLECTOR_PROTOCOL}"
USE_MULTILIB=${USE_MULTILIB:-false}
USE_PIPEWIRE=${USE_PIPEWIRE:-false}
USE_NVIDIA=${USE_NVIDIA:-false}
USE_AMD_VULKAN=${USE_AMD_VULKAN:-false}
USE_BLUETOOTH=${USE_BLUETOOTH:-false}
USE_CUPS=${USE_CUPS:-false}
USE_SNAPPER=${USE_SNAPPER:-false}
FIREWALL="${FIREWALL}"

# ── mkinitcpio hooks (derived from STORAGE_STACK) ─────────────────────────────
MKINIT_HOOKS="${MKINIT_HOOKS}"
EOF

    chmod 600 /mnt/arch_install_vars.sh
    ok "State serialized → /mnt/arch_install_vars.sh"
}

# =============================================================================
#  generate_chroot_script — copies template; no heredoc building
# =============================================================================

function generate_chroot_script() {
    # inputs: SCRIPT_DIR / side-effects: /mnt/arch_configure.sh
    section "Preparing chroot script"

    local template="${SCRIPT_DIR}/templates/chroot_base.sh"
    if [[ ! -f "$template" ]]; then
        die "Template not found: ${template}\nEnsure templates/chroot_base.sh is present."
    fi

    _serialize_chroot_vars

    run "cp ${template} /mnt/arch_configure.sh"
    run "chmod +x /mnt/arch_configure.sh"

    local lines
    lines=$(wc -l < /mnt/arch_configure.sh 2>/dev/null || echo "?")
    ok "Chroot script ready  (${lines} lines + vars)"
}

# =============================================================================
#  run_chroot
# =============================================================================

function run_chroot() {
    # inputs: none / side-effects: executes chroot configuration ⚠
    section "arch-chroot"
    run_spin "Configuring installed system (this takes a while)…" \
        "arch-chroot /mnt /arch_configure.sh"
    ok "Chroot configuration complete"

    # symlink must be created from HOST after chroot releases the bind-mount
    run "ln -sf ../run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf"
    ok "resolv.conf → systemd-resolved stub"
}
