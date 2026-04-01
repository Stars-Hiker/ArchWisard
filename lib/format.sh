#!/usr/bin/env bash
# =============================================================================
#  lib/format.sh — Format filesystems, btrfs subvolumes, mount tree  ⚠
#
#  Depends on: ROOT_PART ROOT_PART_MAPPED EFI_PART HOME_PART SWAP_PART
#              ROOT_FS HOME_FS SWAP_TYPE SWAP_SIZE STORAGE_STACK
#              FIRMWARE_MODE BOOTLOADER DUAL_BOOT REUSE_EFI SEP_HOME
# =============================================================================

# =============================================================================
#  format_filesystems  ⚠
# =============================================================================

function format_filesystems() {
    # inputs: all partition globals / side-effects: writes filesystem metadata to disk
    section "Formatting filesystems"

    local root_dev="${ROOT_PART_MAPPED:-$ROOT_PART}"

    # EFI
    if [[ "$FIRMWARE_MODE" == "bios" ]]; then
        ok "BIOS mode — no EFI to format"
    elif [[ "$DUAL_BOOT" == true || "$REUSE_EFI" == true ]]; then
        ok "Reusing existing EFI: ${EFI_PART}"
    else
        run_spin "Formatting EFI (FAT32)…" "mkfs.fat -F32 -n EFI ${EFI_PART}"
        ok "EFI → FAT32"
    fi

    # Root
    case "$ROOT_FS" in
        btrfs) run_spin "Formatting root (btrfs)…"  "mkfs.btrfs -f -L arch_root ${root_dev}" ;;
        ext4)  run_spin "Formatting root (ext4)…"   "mkfs.ext4  -F -L arch_root ${root_dev}" ;;
        xfs)   run_spin "Formatting root (xfs)…"    "mkfs.xfs   -f -L arch_root ${root_dev}" ;;
        f2fs)  run_spin "Formatting root (f2fs)…"   "mkfs.f2fs  -f -l arch_root ${root_dev}" ;;
        zfs)   ok "ZFS — pool will be created in mount_filesystems" ;;
    esac
    if [[ "$ROOT_FS" != "zfs" ]]; then
        ok "Root → ${ROOT_FS}  (${root_dev})"
    fi

    # Home (if separate)
    if [[ "${SEP_HOME:-false}" == true && -n "${HOME_PART:-}" ]]; then
        case "$HOME_FS" in
            btrfs) run_spin "Formatting home (btrfs)…" "mkfs.btrfs -f -L arch_home ${HOME_PART}" ;;
            ext4)  run_spin "Formatting home (ext4)…"  "mkfs.ext4  -F -L arch_home ${HOME_PART}" ;;
            xfs)   run_spin "Formatting home (xfs)…"   "mkfs.xfs   -f -L arch_home ${HOME_PART}" ;;
            f2fs)  run_spin "Formatting home (f2fs)…"  "mkfs.f2fs  -f -l arch_home ${HOME_PART}" ;;
        esac
        ok "Home → ${HOME_FS}  (${HOME_PART})"
    fi

    # Swap partition (if used)
    if [[ "$SWAP_TYPE" == "partition" && -n "${SWAP_PART:-}" ]]; then
        run "mkswap -L arch_swap ${SWAP_PART}"
        ok "Swap partition formatted"
    fi
}

# =============================================================================
#  create_subvolumes — btrfs only  ⚠
# =============================================================================

function create_subvolumes() {
    # inputs: ROOT_FS ROOT_PART_MAPPED ROOT_PART SWAP_TYPE
    # side-effects: btrfs subvolumes on root device
    if [[ "$ROOT_FS" != "btrfs" ]]; then
        info "Skipping btrfs subvolumes (root is ${ROOT_FS})"
        return 0
    fi
    section "btrfs subvolumes"

    local root_dev="${ROOT_PART_MAPPED:-$ROOT_PART}"
    run "mount ${root_dev} /mnt"

    local sv
    local subvols=("@" "@home" "@snapshots" "@var_log" "@var_cache" "@tmp")
    if [[ "$SWAP_TYPE" == "file" ]]; then subvols+=("@swap"); fi

    for sv in "${subvols[@]}"; do
        run "btrfs subvolume create /mnt/${sv}"
        ok "  @subvol: ${sv}"
    done

    run "umount /mnt"
    ok "Subvolumes created"
}

# =============================================================================
#  mount_filesystems  ⚠
# =============================================================================

function mount_filesystems() {
    # inputs: all layout/partition globals / side-effects: /mnt mounted tree
    section "Mounting filesystems"

    local root_dev="${ROOT_PART_MAPPED:-$ROOT_PART}"

    # Mount options per FS type
    local btrfs_opts="noatime,compress=zstd:1,space_cache=v2,discard=async"
    local ext4_opts="noatime,discard"
    local xfs_opts="noatime,discard,logbufs=8"
    local f2fs_opts="noatime,lazytime,discard"

    # ESP mount point depends on bootloader
    local esp_mount="boot/efi"
    if [[ "$BOOTLOADER" == "systemd-boot" ]]; then esp_mount="boot"; fi

    # ── ZFS ───────────────────────────────────────────────────────────────────
    if [[ "$ROOT_FS" == "zfs" ]]; then
        run "zpool create -f \
            -o ashift=12 \
            -O acltype=posixacl \
            -O relatime=on \
            -O xattr=sa \
            -O dnodesize=auto \
            -O normalization=formD \
            -O mountpoint=none \
            -O canmount=off \
            -O devices=off \
            -R /mnt \
            ${ZFS_POOL} ${ROOT_PART}"
        run "zfs create -o mountpoint=/ ${ZFS_POOL}/ROOT"
        run "zfs create -o mountpoint=/home ${ZFS_POOL}/home"
        run "zpool export ${ZFS_POOL}"
        run "zpool import -d /dev/disk/by-id -R /mnt ${ZFS_POOL}"
        run "mkdir -p /mnt/${esp_mount}"
        ok "ZFS pool mounted"
    # ── btrfs ─────────────────────────────────────────────────────────────────
    elif [[ "$ROOT_FS" == "btrfs" ]]; then
        run "mount -o ${btrfs_opts},subvol=@ ${root_dev} /mnt"
        ok "@ → /mnt"
        run "mkdir -p /mnt/{${esp_mount},home,var/log,var/cache,tmp,.snapshots}"
        if [[ "$SWAP_TYPE" == "file" ]]; then run "mkdir -p /mnt/swap"; fi

        run "mount -o ${btrfs_opts},subvol=@snapshots ${root_dev} /mnt/.snapshots"
        run "mount -o ${btrfs_opts},subvol=@var_log    ${root_dev} /mnt/var/log"
        run "mount -o ${btrfs_opts},subvol=@var_cache  ${root_dev} /mnt/var/cache"
        run "mount -o ${btrfs_opts},subvol=@tmp        ${root_dev} /mnt/tmp"
        # Disable CoW on var/log — avoids fragmentation from journal writes
        run "chattr +C /mnt/var/log"
        ok "@snapshots @var_log @var_cache @tmp → mounted  (CoW off on var/log)"
    # ── ext4 / xfs / f2fs ─────────────────────────────────────────────────────
    else
        local root_opts
        case "$ROOT_FS" in
            ext4) root_opts="$ext4_opts" ;;
            xfs)  root_opts="$xfs_opts"  ;;
            f2fs) root_opts="$f2fs_opts" ;;
            *)    root_opts="noatime"    ;;
        esac
        run "mount -o ${root_opts} ${root_dev} /mnt"
        run "mkdir -p /mnt/{${esp_mount},home,var/log,var/cache,tmp}"
        if [[ "$SWAP_TYPE" == "file" ]]; then run "mkdir -p /mnt/swap"; fi
        ok "/ → /mnt  (${ROOT_FS})"
    fi

    # ── /home ─────────────────────────────────────────────────────────────────
    if [[ "${SEP_HOME:-false}" == true && -n "${HOME_PART:-}" ]]; then
        if [[ "$HOME_FS" == "btrfs" ]]; then
            # Create @home subvol on the home device if not already done
            run "mount ${HOME_PART} /mnt/home"
            if ! btrfs subvolume show /mnt/home/@home &>/dev/null 2>&1; then
                run "btrfs subvolume create /mnt/home/@home"
            fi
            run "umount /mnt/home"
            run "mount -o ${btrfs_opts},subvol=@home ${HOME_PART} /mnt/home"
            ok "/home → btrfs @home"
        else
            local home_opts
            case "$HOME_FS" in
                ext4) home_opts="$ext4_opts" ;;
                xfs)  home_opts="$xfs_opts"  ;;
                f2fs) home_opts="$f2fs_opts" ;;
                *)    home_opts="noatime"    ;;
            esac
            run "mount -o ${home_opts} ${HOME_PART} /mnt/home"
            ok "/home → ${HOME_FS}"
        fi
    elif [[ "$ROOT_FS" == "btrfs" ]]; then
        run "mount -o ${btrfs_opts},subvol=@home ${root_dev} /mnt/home"
        ok "@home → /mnt/home"
    fi

    # ── EFI ───────────────────────────────────────────────────────────────────
    if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
        if [[ -z "${EFI_PART:-}" ]]; then
            die "EFI_PART is not set — cannot mount ESP."
        fi
        run "mount ${EFI_PART} /mnt/${esp_mount}"
        ok "EFI → /mnt/${esp_mount}"
    fi

    # ── Swap ──────────────────────────────────────────────────────────────────
    case "$SWAP_TYPE" in
        partition)
            run "swapon ${SWAP_PART}"
            ok "Swap partition active" ;;
        file)
            if [[ "$ROOT_FS" == "btrfs" ]]; then
                run "mount -o ${btrfs_opts},subvol=@swap ${root_dev} /mnt/swap"
                run "btrfs filesystem mkswapfile --size ${SWAP_SIZE}g /mnt/swap/swapfile"
            else
                run "fallocate -l ${SWAP_SIZE}G /mnt/swap/swapfile"
                run "chmod 600 /mnt/swap/swapfile"
                run "mkswap /mnt/swap/swapfile"
            fi
            run "swapon /mnt/swap/swapfile"
            ok "Swap file active  (${SWAP_SIZE} GB)" ;;
    esac
}
