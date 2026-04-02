#!/usr/bin/env bash
# =============================================================================
#  ArchWizard chroot configuration script
#  Auto-generated — do not edit directly.
#  State sourced from /arch_install_vars.sh (also auto-generated).
# =============================================================================
set -euo pipefail

# shellcheck source=/dev/null
source /arch_install_vars.sh

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()      { echo -e "${GREEN}${BOLD}[ OK ]${NC}  $*"; }
info()    { echo -e "${CYAN}${BOLD}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}${BOLD}[ERR ]${NC}  $*" >&2; }
section() { echo -e "\n${CYAN}${BOLD}━━━  $*  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
trap 'error "Chroot failed at line $LINENO — cmd: ${BASH_COMMAND}"' ERR

# =============================================================================
section "Keyring"
# =============================================================================
pacman -Sy --noconfirm archlinux-keyring 2>/dev/null || true
ok "archlinux-keyring refreshed"

# =============================================================================
section "Timezone & hardware clock"
# =============================================================================
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc
ok "Timezone: ${TIMEZONE}"

# =============================================================================
section "Locale & console"
# =============================================================================
echo "${LOCALE} UTF-8" >> /etc/locale.gen
grep -q "en_US.UTF-8" /etc/locale.gen || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}"   > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
ok "Locale: ${LOCALE}  |  Keymap: ${KEYMAP}"

# =============================================================================
section "Hostname"
# =============================================================================
echo "${HOSTNAME}" > /etc/hostname
{
    echo "127.0.0.1  localhost"
    echo "::1        localhost"
    echo "127.0.1.1  ${HOSTNAME}.localdomain  ${HOSTNAME}"
} > /etc/hosts
ok "Hostname: ${HOSTNAME}"

# =============================================================================
section "pacman tweaks"
# =============================================================================
sed -i 's/^#Color/Color/
        s/^#VerbosePkgLists/VerbosePkgLists/
        s/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
grep -q "ILoveCandy" /etc/pacman.conf \
    || sed -i '/^Color/a ILoveCandy' /etc/pacman.conf
ok "Color + ParallelDownloads=5 + ILoveCandy"

# =============================================================================
section "makepkg compiler optimisation"
# =============================================================================
NPROC=$(nproc)
sed -i "s/^#MAKEFLAGS=.*/MAKEFLAGS=\"-j${NPROC}\"/" /etc/makepkg.conf
sed -i "s/-march=x86-64 -mtune=generic/-march=native -mtune=native/" /etc/makepkg.conf
if grep -q "^RUSTFLAGS=" /etc/makepkg.conf; then
    sed -i 's/^RUSTFLAGS=.*/RUSTFLAGS="-C opt-level=2 -C target-cpu=native"/' \
        /etc/makepkg.conf
else
    echo 'RUSTFLAGS="-C opt-level=2 -C target-cpu=native"' >> /etc/makepkg.conf
fi
ok "makepkg: -j${NPROC}  -march=native  RUSTFLAGS=native"

# =============================================================================
section "Kernel hardening (sysctl)"
# =============================================================================
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

# =============================================================================
section "Journal size cap"
# =============================================================================
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/00-journal.conf << 'JEOF'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=50M
MaxRetentionSec=2week
JEOF
ok "Journal capped at 200 MB"

# =============================================================================
if [[ "$USE_MULTILIB" == true ]]; then
section "Multilib repo"
sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' /etc/pacman.conf
pacman -Sy --noconfirm
ok "Multilib enabled"
fi

# =============================================================================
if [[ "$USE_REFLECTOR" == true ]]; then
section "Reflector mirrors"
_ref_args=""
IFS=',' read -ra _rca <<< "$REFLECTOR_COUNTRIES"
for _c in "${_rca[@]}"; do
    _c="${_c#"${_c%%[![:space:]]*}"}"; _c="${_c%"${_c##*[![:space:]]}"}"
    [[ -n "$_c" ]] && _ref_args+="--country \"${_c}\" "
done
# Non-fatal: reflector exits non-zero when no mirror matches the filter.
# Relax --age if mirrors are scarce; fallback keeps the existing mirrorlist.
# shellcheck disable=SC2086
if reflector ${_ref_args}--protocol "${REFLECTOR_PROTOCOL}" \
    --age "${REFLECTOR_AGE:-24}" \
    --connection-timeout 5 \
    --latest 20 \
    --number "${REFLECTOR_NUMBER}" \
    --sort rate \
    --save /etc/pacman.d/mirrorlist 2>/dev/null; then
    mkdir -p /etc/xdg/reflector
    {   echo "# reflector.conf — generated by ArchWizard"
        IFS=',' read -ra _rcc <<< "$REFLECTOR_COUNTRIES"
        for _cc in "${_rcc[@]}"; do
            _cc="${_cc#"${_cc%%[![:space:]]*}"}"; _cc="${_cc%"${_cc##*[![:space:]]}"}"
            [[ -n "$_cc" ]] && echo "--country ${_cc}"
        done
        echo "--protocol ${REFLECTOR_PROTOCOL}"
        echo "--age ${REFLECTOR_AGE:-24}"
        echo "--connection-timeout 5"
        echo "--latest 20"
        echo "--number ${REFLECTOR_NUMBER}"
        echo "--sort rate"
        echo "--save /etc/pacman.d/mirrorlist"
    } > /etc/xdg/reflector/reflector.conf
    ok "Mirrors updated + reflector.conf written"
else
    warn "reflector found no mirrors matching filter — keeping existing mirrorlist."
    warn "After reboot: edit /etc/xdg/reflector/reflector.conf and run: systemctl start reflector"
fi
fi

# =============================================================================
section "Bootloader packages"
# =============================================================================
pacman -S --noconfirm --ask 4 --needed ${BOOTLOADER_PKGS}
ok "Bootloader packages installed"

# =============================================================================
if [[ -n "$DE_PKGS" ]]; then
section "Desktop environment: ${DESKTOPS[*]}"
pacman -S --noconfirm --ask 4 --needed ${DE_PKGS}
ok "Desktop(s) installed"
fi

# =============================================================================
if [[ "$USE_PIPEWIRE" == true ]]; then
section "PipeWire audio"
pacman -S --noconfirm --ask 4 --needed \
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber
ok "PipeWire installed"
fi

# =============================================================================
if [[ -n "$NVIDIA_PKGS" ]]; then
section "NVIDIA drivers"
pacman -S --noconfirm --ask 4 --needed ${NVIDIA_PKGS}
echo 'options nvidia_drm modeset=1 fbdev=1' > /etc/modprobe.d/nvidia.conf
ok "NVIDIA installed + DRM modesetting enabled"
fi

# =============================================================================
if [[ "$USE_BLUETOOTH" == true ]]; then
section "Bluetooth"
pacman -S --noconfirm --ask 4 --needed bluez bluez-utils
systemctl enable bluetooth
ok "Bluetooth enabled"
fi

# =============================================================================
if [[ "$USE_CUPS" == true ]]; then
section "CUPS printing"
pacman -S --noconfirm --ask 4 --needed cups cups-pdf system-config-printer
systemctl enable cups
ok "CUPS enabled"
fi

# =============================================================================
section "mkinitcpio"
# =============================================================================
sed -i "s|^HOOKS=.*|HOOKS=(${MKINIT_HOOKS})|" /etc/mkinitcpio.conf
mkinitcpio -P
ok "Initramfs built"

# =============================================================================
section "crypttab"
# =============================================================================
if [[ "$USE_LUKS" == true ]]; then
    if [[ -n "$LUKS_UUID" ]]; then
        echo "cryptroot  UUID=${LUKS_UUID}  none  luks,discard" >> /etc/crypttab
        ok "crypttab: root  UUID=${LUKS_UUID}"
    fi
    if [[ -n "$HOME_LUKS_UUID" ]]; then
        echo "crypthome  UUID=${HOME_LUKS_UUID}  none  luks,discard" >> /etc/crypttab
        ok "crypttab: home  UUID=${HOME_LUKS_UUID}"
    fi
fi

# =============================================================================
section "Bootloader install"
# =============================================================================
if [[ "$BOOTLOADER" == "grub" ]]; then
    if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
        _hostname=$(cat /etc/hostname 2>/dev/null | tr -d ' ' || echo arch)
        _mid=$(cat /etc/machine-id 2>/dev/null | head -c6 || echo 000000)
        GRUB_ID="Arch-${_hostname}-${_mid}"
        grub-install \
            --target=x86_64-efi \
            --efi-directory=/boot/efi \
            --bootloader-id="${GRUB_ID}" \
            --recheck
        ok "GRUB installed — EFI entry: ${GRUB_ID}"
    else
        grub-install --target=i386-pc "${DISK_ROOT}"
        ok "GRUB installed to MBR of ${DISK_ROOT}"
    fi

    # GRUB_DISTRIBUTOR (boot menu label)
    if grep -q '^GRUB_DISTRIBUTOR=' /etc/default/grub; then
        sed -i "s|^GRUB_DISTRIBUTOR=.*|GRUB_DISTRIBUTOR=\"${GRUB_ENTRY_NAME}\"|" \
            /etc/default/grub
    else
        echo "GRUB_DISTRIBUTOR=\"${GRUB_ENTRY_NAME}\"" >> /etc/default/grub
    fi

    # os-prober for multi-boot
    if [[ "$DUAL_BOOT" == true ]]; then
        if grep -q 'GRUB_DISABLE_OS_PROBER' /etc/default/grub; then
            sed -i 's/.*GRUB_DISABLE_OS_PROBER.*/GRUB_DISABLE_OS_PROBER=false/' \
                /etc/default/grub
        else
            echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
        fi
        ok "os-prober enabled"
    fi

    # Kernel command line
    if [[ "$USE_LUKS" == true ]]; then
        if [[ "$ROOT_FS" == "btrfs" ]]; then
            _cmdline="cryptdevice=UUID=${LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet"
        else
            _cmdline="cryptdevice=UUID=${LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot rw quiet"
        fi
    elif [[ "$ROOT_FS" == "btrfs" ]]; then
        _cmdline="rootflags=subvol=@"
    else
        _cmdline=""
    fi
    if [[ -n "$_cmdline" ]]; then
        sed -i "s|^GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"${_cmdline}\"|" \
            /etc/default/grub
    fi

    if [[ "$USE_NVIDIA" == true ]]; then
        sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT="|GRUB_CMDLINE_LINUX_DEFAULT="nvidia_drm.modeset=1 |' \
            /etc/default/grub
    fi

    if [[ "$USE_SNAPPER" == true ]]; then
        systemctl enable grub-btrfsd
    fi

    # Mount other OS partitions for os-prober, then generate grub.cfg
    _osp_base="/tmp/osprober_$$"
    mkdir -p "$_osp_base"
    _osp_dirs=()
    _cur_root=$(findmnt -n -o SOURCE / 2>/dev/null || echo "none")
    while IFS=' ' read -r _dev _fstype; do
        [[ -z "$_dev" ]] && continue
        findmnt -S "$_dev" > /dev/null 2>&1 && continue
        [[ "$_dev" == "$_cur_root" ]] && continue
        _pt=$(lsblk -no PARTTYPE "$_dev" 2>/dev/null || echo "")
        [[ "$_pt" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] && continue
        [[ "$_pt" == "0657fd6d-a4ab-43c4-84e5-0933c84b4f4f" ]] && continue
        _osp_dir="${_osp_base}/${#_osp_dirs[@]}"
        mkdir -p "$_osp_dir"
        if [[ "$_fstype" == "btrfs" ]]; then
            mount -o ro,noexec,nosuid,subvol=@ "$_dev" "$_osp_dir" 2>/dev/null || \
            mount -o ro,noexec,nosuid          "$_dev" "$_osp_dir" 2>/dev/null || continue
        else
            mount -o ro,noexec,nosuid "$_dev" "$_osp_dir" 2>/dev/null || continue
        fi
        _osp_dirs+=("$_osp_dir")
        info "Mounted for os-prober: ${_dev}"
    done < <(lsblk -ln -o PATH,FSTYPE \
        | awk '$2 ~ /^(btrfs|ext4|xfs|f2fs|ntfs)$/ {print $1, $2}')
    os-prober 2>/dev/null || true
    grub-mkconfig -o /boot/grub/grub.cfg
    for _d in "${_osp_dirs[@]+"${_osp_dirs[@]}"}"; do
        umount "$_d" 2>/dev/null || true
        rmdir  "$_d" 2>/dev/null || true
    done
    rmdir "$_osp_base" 2>/dev/null || true
    ok "GRUB configured — os-prober scanned all partitions"

elif [[ "$BOOTLOADER" == "systemd-boot" ]]; then
    bootctl install --esp-path=/boot
    mkdir -p /boot/loader/entries
    cat > /boot/loader/loader.conf << 'LOADEREOF'
default arch.conf
timeout 5
console-mode max
editor no
LOADEREOF
    cat > /boot/loader/entries/arch.conf << ENTRYEOF
title   ${GRUB_ENTRY_NAME}
linux   /vmlinuz-${KERNEL}
${SD_INITRD_UCODE}initrd  /initramfs-${KERNEL}.img
options ${SD_OPTIONS}
ENTRYEOF
    cat > /boot/loader/entries/arch-fallback.conf << FBEOF
title   ${GRUB_ENTRY_NAME} (fallback)
linux   /vmlinuz-${KERNEL}
${SD_INITRD_UCODE}initrd  /initramfs-${KERNEL}-fallback.img
options ${SD_OPTIONS}
FBEOF
    systemctl enable systemd-boot-update.service
    ok "systemd-boot configured"
fi

# =============================================================================
section "User accounts"
# =============================================================================
useradd -mG wheel,audio,video,optical,storage,network,input "${USERNAME}"
xdg-user-dirs-update --force 2>/dev/null || true
# crash rule: passwords via chpasswd stdin, never argv
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd
echo "root:${ROOT_PASSWORD}"        | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
ok "User '${USERNAME}' created (wheel/sudo)"

# =============================================================================
section "Core services"
# =============================================================================
systemctl enable NetworkManager systemd-resolved fstrim.timer systemd-oomd paccache.timer
if [[ -n "$DM_SERVICE" ]]; then systemctl enable "${DM_SERVICE}"; fi
if [[ "$USE_REFLECTOR" == true ]]; then systemctl enable reflector.timer; fi
ok "Core services enabled"

# =============================================================================
if [[ "$USE_SNAPPER" == true ]]; then
section "Snapper"
umount /.snapshots 2>/dev/null || true
rm -rf /.snapshots
mkdir -p /.snapshots
mount -a
chmod 750 /.snapshots
chown :wheel /.snapshots 2>/dev/null || true
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
ok "Snapper configured"
fi

# =============================================================================
if [[ "$FIREWALL" == "nftables" ]]; then
section "Firewall — nftables"
pacman -S --noconfirm --ask 4 --needed nftables
cat > /etc/nftables.conf << 'NFTRULES'
#!/usr/bin/nft -f
flush ruleset
table inet filter {
    chain input  { type filter hook input  priority filter; policy drop;
                   ct state invalid drop; ct state { established, related } accept;
                   iifname lo accept; ip protocol icmp accept; ip6 nexthdr icmpv6 accept; }
    chain forward { type filter hook forward priority filter; policy drop; }
    chain output  { type filter hook output  priority filter; policy accept; }
}
NFTRULES
systemctl enable nftables
ok "nftables enabled (stateful, drop-incoming)"

elif [[ "$FIREWALL" == "ufw" ]]; then
section "Firewall — ufw"
pacman -S --noconfirm --ask 4 --needed ufw
mkdir -p /etc/default
cat > /etc/default/ufw << 'UFWDEFAULT'
IPV6=yes
DEFAULT_INPUT_POLICY="DROP"; DEFAULT_OUTPUT_POLICY="ACCEPT"
DEFAULT_FORWARD_POLICY="DROP"; DEFAULT_APPLICATION_POLICY="SKIP"; MANAGE_BUILTINS=no
UFWDEFAULT
mkdir -p /etc/ufw
printf 'ENABLED=yes\nLOGLEVEL=low\n' > /etc/ufw/ufw.conf
systemctl enable ufw
ok "ufw enabled"
fi

# =============================================================================
if [[ "$SWAP_TYPE" == "zram" ]]; then
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
fi

# =============================================================================
if [[ "$SWAP_TYPE" == "file" ]]; then
echo '/swap/swapfile none swap defaults 0 0' >> /etc/fstab
ok "Swap file entry added to fstab"
fi

# =============================================================================
if [[ "$AUR_HELPER" != "none" ]]; then
section "AUR helper: ${AUR_HELPER}"
pacman -S --noconfirm --ask 4 --needed git base-devel
# makepkg refuses to run as root — build as the new user
sudo -u "${USERNAME}" bash -c "
    set -euo pipefail
    cd /tmp
    rm -rf '${AUR_HELPER}'
    git clone https://aur.archlinux.org/${AUR_HELPER}.git
    cd '${AUR_HELPER}'
    makepkg -si --noconfirm
"
ok "${AUR_HELPER} installed"
fi

# =============================================================================
if [[ "$SECURE_BOOT" == true ]]; then
section "Secure Boot"
info "After first boot run:"
info "  sudo sbctl enroll-keys --microsoft"
info "  sudo sbctl sign-all"
fi

# =============================================================================
section "Done"
# =============================================================================
echo -e "\n\033[0;32m\033[1m  ✓  Chroot configuration complete.\033[0m\n"
