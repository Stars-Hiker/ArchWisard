#!/usr/bin/env bash
# =============================================================================
#  lib/partition.sh — All destructive partition operations  ⚠
#
#  Crash rules enforced here:
#    - Batch all sgdisk -d calls, then ONE _refresh_partitions
#    - Delete partitions in REVERSE number order (GPT renumbering)
#    - _refresh_partitions called DIRECTLY, never via run()/eval
#    - parted resize via run_interactive (restores /dev/tty)
#    - LUKS passwords piped via stdin, never in argv
# =============================================================================

# =============================================================================
#  replace_partition — delete planned partitions  ⚠
# =============================================================================

function replace_partition() {
    # inputs: REPLACE_PARTS_ALL REPLACE_PART DUAL_BOOT / side-effects: disk GPT
    if [[ "$DUAL_BOOT" == false ]]; then return 0; fi

    local _to_delete=()
    if [[ ${#REPLACE_PARTS_ALL[@]} -gt 0 ]]; then
        _to_delete=("${REPLACE_PARTS_ALL[@]}")
    elif [[ -n "${REPLACE_PART:-}" ]]; then
        _to_delete=("$REPLACE_PART")
    else
        return 0
    fi

    section "Deleting partitions"

    # Sort in reverse numeric order — crash rule: prevents GPT renumbering mid-loop
    local _sorted=()
    while IFS= read -r line; do
        _sorted+=("$line")
    done < <(printf '%s\n' "${_to_delete[@]}" \
        | awk '{match($0,/[0-9]+$/); print substr($0,RSTART)+0, $0}' \
        | sort -rn | awk '{print $2}')

    # Batch all deletions — crash rule: one _refresh_partitions after all sgdisk -d
    local _total_freed=0 p _gb _num
    for p in "${_sorted[@]}"; do
        if [[ -z "$p" ]]; then continue; fi
        _gb=$(( $(blockdev --getsize64 "$p" 2>/dev/null || echo 0) / 1073741824 ))
        _num=$(echo "$p" | grep -oE '[0-9]+$')
        info "Deleting ${p}  (${_gb} GB) — ALL DATA LOST"
        run "sgdisk -d ${_num} ${DISK_ROOT}"
        _total_freed=$(( _total_freed + _gb ))
        ok "${p} removed from GPT"
    done

    # Direct call — crash rule: never via run()/eval
    _refresh_partitions "${DISK_ROOT}"

    blank
    info "Updated layout of ${DISK_ROOT}:"
    parted -s "$DISK_ROOT" unit GiB print free 2>/dev/null || true
    blank
    ok "Freed: ${_total_freed} GB now unallocated."
    blank
}

# =============================================================================
#  resize_partitions — shrink an existing partition  ⚠
# =============================================================================

function resize_partitions() {
    # inputs: RESIZE_PART RESIZE_NEW_GB DUAL_BOOT / side-effects: partition + FS
    if [[ "$DUAL_BOOT" == false ]]; then return 0; fi
    if [[ -z "${RESIZE_PART:-}" ]]; then return 0; fi

    section "Resize: ${RESIZE_PART} → ${RESIZE_NEW_GB} GB"

    local target_part="$RESIZE_PART"
    local new_gb="$RESIZE_NEW_GB"
    local target_fs
    target_fs=$(blkid -s TYPE -o value "$target_part" 2>/dev/null || echo "unknown")

    local cur_gb
    cur_gb=$(( $(blockdev --getsize64 "$target_part" 2>/dev/null || echo 0) / 1073741824 ))
    local freed=$(( cur_gb - new_gb ))
    local new_bytes=$(( new_gb * 1073741824 ))
    local new_mb=$(( new_gb * 1024 ))

    info "${target_part}  ${cur_gb} GB → ${new_gb} GB  (freeing ${freed} GB)"
    blank

    case "$target_fs" in
        ntfs)
            run_spin "Checking NTFS minimum size…" \
                "ntfsresize --no-action --size ${new_mb}M $target_part"
            run_spin "Shrinking NTFS…" \
                "ntfsresize --force --size ${new_mb}M $target_part"
            ok "NTFS shrunk to ${new_gb} GB" ;;
        ext4)
            run_spin "Checking ext4 (fsck)…" "e2fsck -fy $target_part"
            run_spin "Shrinking ext4…"        "resize2fs $target_part ${new_mb}M"
            ok "ext4 shrunk to ~${new_gb} GB" ;;
        btrfs)
            local _btmp="/tmp/archwizard_btrfs_resize"
            mkdir -p "$_btmp"
            run "mount -o rw $target_part $_btmp"
            run_spin "Shrinking btrfs…" "btrfs filesystem resize ${new_mb}M $_btmp"
            run "umount $_btmp"
            rmdir "$_btmp" 2>/dev/null || true
            ok "btrfs shrunk to ~${new_gb} GB" ;;
        *)
            error "Unsupported filesystem '${target_fs}' for resize."
            return 1 ;;
    esac

    # Update the GPT partition entry to match the new FS size
    local part_num
    part_num=$(echo "$target_part" | grep -oE '[0-9]+$')
    local start_bytes
    start_bytes=$(parted -s "$DISK_ROOT" unit B print 2>/dev/null \
        | awk "/^ *${part_num} /{print \$2}" | tr -d 'B')
    local new_end=$(( ${start_bytes:-0} + new_bytes ))

    info "parted will ask you to confirm — type 'Yes' and press Enter."
    # run_interactive — crash rule: parted resize is interactive
    run_interactive "parted $DISK_ROOT resizepart $part_num ${new_end}B"
    ok "GPT entry updated"

    _refresh_partitions "$DISK_ROOT"

    blank
    info "Updated layout:"
    parted -s "$DISK_ROOT" unit GiB print free 2>/dev/null || true
    blank
    ok "~${freed} GB now unallocated."
    blank
}

# =============================================================================
#  create_partitions — the main partitioning step  ⚠
# =============================================================================

function create_partitions() {
    # inputs: all disk/layout globals / side-effects: EFI_PART ROOT_PART HOME_PART SWAP_PART
    section "Partitioning"
    blank

    local part_num=1

    if [[ "$DUAL_BOOT" == true ]]; then
        # ── Multi-boot: append new partitions to existing table ───────────────
        info "Multi-boot — appending to existing partition table"
        blank

        if [[ "$SWAP_TYPE" == "partition" ]]; then
            run "sgdisk -n 0:0:+${SWAP_SIZE}G -t 0:8200 -c 0:arch_swap ${DISK_ROOT}"
            SWAP_PART=$(part_name "$DISK_ROOT" \
                "$(sgdisk -p "$DISK_ROOT" 2>/dev/null | tail -1 | awk '{print $1}')")
        fi

        if [[ "${SEP_HOME:-false}" == true && "$DISK_HOME" == "$DISK_ROOT" ]]; then
            if [[ "$ROOT_SIZE" == "rest" ]]; then
                run "sgdisk -n 0:0:0 -t 0:8300 -c 0:arch_root ${DISK_ROOT}"
            else
                run "sgdisk -n 0:0:+${ROOT_SIZE}G -t 0:8300 -c 0:arch_root ${DISK_ROOT}"
            fi
            ROOT_PART=$(part_name "$DISK_ROOT" \
                "$(sgdisk -p "$DISK_ROOT" 2>/dev/null | tail -1 | awk '{print $1}')")

            if [[ "$HOME_SIZE" == "rest" ]]; then
                run "sgdisk -n 0:0:0 -t 0:8302 -c 0:arch_home ${DISK_ROOT}"
            else
                run "sgdisk -n 0:0:+${HOME_SIZE}G -t 0:8302 -c 0:arch_home ${DISK_ROOT}"
            fi
            HOME_PART=$(part_name "$DISK_ROOT" \
                "$(sgdisk -p "$DISK_ROOT" 2>/dev/null | tail -1 | awk '{print $1}')")
        else
            if [[ "$ROOT_SIZE" == "rest" ]]; then
                run "sgdisk -n 0:0:0 -t 0:8300 -c 0:arch_root ${DISK_ROOT}"
            else
                run "sgdisk -n 0:0:+${ROOT_SIZE}G -t 0:8300 -c 0:arch_root ${DISK_ROOT}"
            fi
            ROOT_PART=$(part_name "$DISK_ROOT" \
                "$(sgdisk -p "$DISK_ROOT" 2>/dev/null | tail -1 | awk '{print $1}')")
        fi

    elif [[ "$FIRMWARE_MODE" == "bios" ]]; then
        # ── BIOS/MBR fresh install ─────────────────────────────────────────────
        warn "Wiping ${DISK_ROOT} — new MBR table (BIOS mode)"
        run "parted -s ${DISK_ROOT} mklabel msdos"
        run "parted -s ${DISK_ROOT} mkpart primary 1MiB 2MiB"
        run "parted -s ${DISK_ROOT} set 1 bios_grub on"
        part_num=2
        local _next="2MiB"

        if [[ "$SWAP_TYPE" == "partition" ]]; then
            local _swap_end=$(( 2 + SWAP_SIZE * 1024 ))
            run "parted -s ${DISK_ROOT} mkpart primary linux-swap 2MiB ${_swap_end}MiB"
            SWAP_PART=$(part_name "$DISK_ROOT" "$part_num")
            part_num=$(( part_num + 1 ))
            _next="${_swap_end}MiB"
        fi

        if [[ "$ROOT_SIZE" == "rest" ]]; then
            run "parted -s ${DISK_ROOT} mkpart primary ${_next} 100%"
            ROOT_PART=$(part_name "$DISK_ROOT" "$part_num")
        else
            local _root_end=$(( ${_next//MiB/} + ROOT_SIZE * 1024 ))
            run "parted -s ${DISK_ROOT} mkpart primary ${_next} ${_root_end}MiB"
            ROOT_PART=$(part_name "$DISK_ROOT" "$part_num")
            part_num=$(( part_num + 1 ))

            if [[ "${SEP_HOME:-false}" == true && "$DISK_HOME" == "$DISK_ROOT" ]]; then
                if [[ "$HOME_SIZE" == "rest" ]]; then
                    run "parted -s ${DISK_ROOT} mkpart primary ${_root_end}MiB 100%"
                else
                    local _home_end=$(( _root_end + HOME_SIZE * 1024 ))
                    run "parted -s ${DISK_ROOT} mkpart primary ${_root_end}MiB ${_home_end}MiB"
                fi
                HOME_PART=$(part_name "$DISK_ROOT" "$part_num")
            fi
        fi
        run "parted -s ${DISK_ROOT} set $(echo "$ROOT_PART" | grep -oE '[0-9]+$') boot on"

    else
        # ── UEFI/GPT fresh install ─────────────────────────────────────────────
        warn "Wiping ${DISK_ROOT} — new GPT"
        run "sgdisk --zap-all ${DISK_ROOT}"
        run "sgdisk -o ${DISK_ROOT}"

        run "sgdisk -n 1:0:+${EFI_SIZE_MB}M -t 1:ef00 -c 1:EFI ${DISK_ROOT}"
        EFI_PART=$(part_name "$DISK_ROOT" "1")
        part_num=2

        if [[ "$SWAP_TYPE" == "partition" ]]; then
            run "sgdisk -n ${part_num}:0:+${SWAP_SIZE}G \
                -t ${part_num}:8200 -c ${part_num}:swap ${DISK_ROOT}"
            SWAP_PART=$(part_name "$DISK_ROOT" "$part_num")
            part_num=$(( part_num + 1 ))
        fi

        if [[ "$ROOT_SIZE" == "rest" ]]; then
            run "sgdisk -n ${part_num}:0:0 -t ${part_num}:8300 -c ${part_num}:root ${DISK_ROOT}"
            ROOT_PART=$(part_name "$DISK_ROOT" "$part_num")
        else
            run "sgdisk -n ${part_num}:0:+${ROOT_SIZE}G \
                -t ${part_num}:8300 -c ${part_num}:root ${DISK_ROOT}"
            ROOT_PART=$(part_name "$DISK_ROOT" "$part_num")
            part_num=$(( part_num + 1 ))

            if [[ "${SEP_HOME:-false}" == true && "$DISK_HOME" == "$DISK_ROOT" ]]; then
                if [[ "$HOME_SIZE" == "rest" ]]; then
                    run "sgdisk -n ${part_num}:0:0 -t ${part_num}:8302 -c ${part_num}:home ${DISK_ROOT}"
                else
                    run "sgdisk -n ${part_num}:0:+${HOME_SIZE}G \
                        -t ${part_num}:8302 -c ${part_num}:home ${DISK_ROOT}"
                fi
                HOME_PART=$(part_name "$DISK_ROOT" "$part_num")
            fi
        fi
    fi

    # Separate home disk
    if [[ "${SEP_HOME:-false}" == true && "$DISK_HOME" != "$DISK_ROOT" ]]; then
        warn "Wiping ${DISK_HOME} for /home"
        run "sgdisk --zap-all ${DISK_HOME}"
        run "sgdisk -o ${DISK_HOME}"
        if [[ "$HOME_SIZE" == "rest" ]]; then
            run "sgdisk -n 1:0:0 -t 1:8302 -c 1:home ${DISK_HOME}"
        else
            run "sgdisk -n 1:0:+${HOME_SIZE}G -t 1:8302 -c 1:home ${DISK_HOME}"
        fi
        HOME_PART=$(part_name "$DISK_HOME" "1")
    fi

    # Direct calls — crash rule
    _refresh_partitions "$DISK_ROOT"
    if [[ "$DISK_HOME" != "$DISK_ROOT" ]]; then
        _refresh_partitions "$DISK_HOME"
    fi

    ok "Partitions created"
    blank
    lsblk "$DISK_ROOT" 2>/dev/null || true
    if [[ "$DISK_HOME" != "$DISK_ROOT" ]]; then
        lsblk "$DISK_HOME" 2>/dev/null || true
    fi
}

# =============================================================================
#  setup_luks — open LUKS2 containers  ⚠
# =============================================================================

function setup_luks() {
    # inputs: USE_LUKS LUKS_PASSWORD ROOT_PART HOME_PART
    # side-effects: ROOT_PART_MAPPED HOME_PART (remapped to /dev/mapper/*)
    if [[ "$USE_LUKS" == false ]]; then return 0; fi
    section "LUKS2 encryption"

    info "Formatting ${ROOT_PART} as LUKS2 container…"
    # crash rule: password via stdin, never argv
    echo -n "$LUKS_PASSWORD" | run "cryptsetup luksFormat \
        --type luks2 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --hash sha512 \
        --batch-mode \
        ${ROOT_PART} -"

    echo -n "$LUKS_PASSWORD" | run "cryptsetup open \
        --allow-discards \
        --persistent \
        ${ROOT_PART} cryptroot -"

    ROOT_PART_MAPPED="/dev/mapper/cryptroot"
    ok "LUKS opened → ${ROOT_PART_MAPPED}"

    # Optional: also encrypt home
    if [[ "${SEP_HOME:-false}" == true && -n "${HOME_PART:-}" ]]; then
        blank
        if confirm_gum "Also encrypt /home with the same passphrase?"; then
            echo -n "$LUKS_PASSWORD" | run "cryptsetup luksFormat \
                --type luks2 \
                --cipher aes-xts-plain64 \
                --key-size 512 \
                --hash sha512 \
                --batch-mode \
                ${HOME_PART} -"

            echo -n "$LUKS_PASSWORD" | run "cryptsetup open \
                --allow-discards \
                --persistent \
                ${HOME_PART} crypthome -"

            HOME_PART="/dev/mapper/crypthome"
            ok "/home encrypted → ${HOME_PART}"
        fi
    fi
}
