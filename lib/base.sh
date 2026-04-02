#!/usr/bin/env bash
# =============================================================================
#  lib/base.sh — pacstrap base install + genfstab  ⚠
# =============================================================================

# _build_package_list → echoes space-separated package list to stdout
function _build_package_list() {
    # inputs: all software globals / outputs: package string
    local pkgs=""

    # Core
    pkgs+="base base-devel ${KERNEL} ${KERNEL}-headers linux-firmware"
    pkgs+=" dosfstools mtools"

    # FS tools
    local all_fs="${ROOT_FS} ${HOME_FS}"
    if echo "$all_fs" | grep -q "btrfs"; then pkgs+=" btrfs-progs"; fi
    if echo "$all_fs" | grep -q "ext4";  then pkgs+=" e2fsprogs";   fi
    if echo "$all_fs" | grep -q "xfs";   then pkgs+=" xfsprogs";    fi
    if echo "$all_fs" | grep -q "f2fs";  then pkgs+=" f2fs-tools";  fi

    # LUKS/LVM
    case "${STORAGE_STACK:-plain}" in
        luks|luks_btrfs)         pkgs+=" cryptsetup" ;;
        lvm)                      pkgs+=" lvm2" ;;
        luks_lvm)                 pkgs+=" cryptsetup lvm2" ;;
    esac

    # CPU microcode
    if [[ "$CPU_VENDOR" == "intel" ]]; then pkgs+=" intel-ucode"; fi
    if [[ "$CPU_VENDOR" == "amd"   ]]; then pkgs+=" amd-ucode";   fi

    # Network
    pkgs+=" networkmanager network-manager-applet"
    pkgs+=" iwd wpa_supplicant wireless_tools"

    # Essentials
    pkgs+=" git curl wget rsync"
    pkgs+=" nano vim neovim"
    pkgs+=" sudo bash-completion"
    pkgs+=" htop btop fastfetch"
    pkgs+=" zip unzip tar"
    pkgs+=" man-db man-pages"
    pkgs+=" pacman-contrib"
    pkgs+=" xdg-utils xdg-user-dirs"
    pkgs+=" smartmontools openssh"

    # Multi-boot
    if [[ "$DUAL_BOOT" == true ]]; then pkgs+=" os-prober ntfs-3g fuse2"; fi

    # GPU
    if [[ "${USE_AMD_VULKAN:-false}" == true ]]; then
        pkgs+=" vulkan-radeon libva-mesa-driver"
        if [[ "${USE_MULTILIB:-false}" == true ]]; then
            pkgs+=" lib32-mesa lib32-vulkan-radeon"
        fi
    fi

    # Optional
    if [[ "${USE_REFLECTOR:-false}" == true ]]; then pkgs+=" reflector"; fi
    if [[ "${USE_SNAPPER:-false}"   == true ]]; then pkgs+=" snapper snap-pac grub-btrfs"; fi

    echo "$pkgs"
}

# =============================================================================
#  setup_mirrors — run reflector before pacstrap  ⚠
# =============================================================================

function setup_mirrors() {
    # inputs: USE_REFLECTOR REFLECTOR_* / side-effects: /etc/pacman.d/mirrorlist
    if [[ "${USE_REFLECTOR:-false}" == false ]]; then return 0; fi
    section "Optimising mirrors"

    local country_args=""
    local _c
    IFS=',' read -ra _countries <<< "$REFLECTOR_COUNTRIES"
    for _c in "${_countries[@]}"; do
        _c="${_c#"${_c%%[![:space:]]*}"}"
        _c="${_c%"${_c##*[![:space:]]}"}"
        if [[ -n "$_c" ]]; then country_args+="--country \"${_c}\" "; fi
    done

    # Non-fatal: keep existing mirrorlist if no mirror matches the filter
    if ! eval "reflector ${country_args}--protocol ${REFLECTOR_PROTOCOL}          --age ${REFLECTOR_AGE:-24}          --connection-timeout 5          --latest 20          --number ${REFLECTOR_NUMBER}          --sort rate          --save /etc/pacman.d/mirrorlist" 2>/dev/null; then
        warn "reflector found no mirrors — using default mirrorlist for pacstrap."
    else
        ok "Mirrorlist updated"
    fi
}

# =============================================================================
#  install_base — pacstrap + genfstab  ⚠
# =============================================================================

function install_base() {
    # inputs: all software globals / side-effects: installs base to /mnt
    section "pacstrap — base install"

    # Tweak live pacman for speed
    sed -i 's/^#Color/Color/
            s/^#VerbosePkgLists/VerbosePkgLists/
            s/^#ParallelDownloads.*/ParallelDownloads = 5/' \
        /etc/pacman.conf 2>/dev/null || true
    grep -q "ILoveCandy" /etc/pacman.conf 2>/dev/null \
        || sed -i '/^Color/a ILoveCandy' /etc/pacman.conf 2>/dev/null || true
    ok "Live pacman: Color + ParallelDownloads=5"

    local pkgs
    pkgs=$(_build_package_list)
    info "Packages: ${pkgs}"
    blank

    run_spin "Installing base system (this takes a while)…" \
        "pacstrap -K /mnt ${pkgs}"
    ok "Base system installed"

    run "genfstab -U /mnt >> /mnt/etc/fstab"
    ok "fstab generated"
}
