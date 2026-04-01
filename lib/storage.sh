#!/usr/bin/env bash
# =============================================================================
#  lib/storage.sh — Step 3: Storage stack selection
#
#  This is a NEW step that did not exist in either source file.
#  It separates "what encryption/volume layer do you want?" from
#  "how big do you want the partitions?" (Step 4, layout.sh).
#
#  Sets:
#    STORAGE_STACK  — plain | luks | lvm | luks_lvm | btrfs | luks_btrfs | zfs
#    USE_LUKS       — true | false
#    LUKS_PASSWORD  — set if USE_LUKS=true  (NEVER passed via argv)
#    LVM_VG         — VG name if LVM used
#    LVM_LV_ROOT    — LV name for root
#    LVM_LV_HOME    — LV name for home
#    ZFS_POOL       — pool name if ZFS used
#
#  Matrix (from CLAUDE.md):
#    plain       → no extra layer, raw partition → FS
#    luks        → LUKS2 → FS
#    lvm         → LVM PV/VG/LV → FS
#    luks_lvm    → LUKS2 → LVM PV/VG/LV → FS
#    btrfs       → raw partition → btrfs + subvols   (most common default)
#    luks_btrfs  → LUKS2 → btrfs + subvols
#    zfs         → ZFS pool (requires archzfs from AUR)
#
#  mkinitcpio hook order (hard rule — never change):
#    plain/lvm/btrfs/zfs:  ... block [lvm2] filesystems fsck
#    luks/luks_lvm:        ... block encrypt [lvm2] filesystems fsck
#    encrypt MUST come before lvm2 — always.
# =============================================================================

# _zfs_available → returns 0 if zfs command present in live env
function _zfs_available() {
    command -v zfs &>/dev/null && command -v zpool &>/dev/null
}

# _lvm_available → returns 0 if lvm2 tools present
function _lvm_available() {
    command -v pvcreate &>/dev/null && command -v vgcreate &>/dev/null
}

# _derive_storage_stack → sets STORAGE_STACK from USE_LUKS / LVM / ROOT_FS
function _derive_storage_stack() {
    # inputs: USE_LUKS _USE_LVM ROOT_FS / side-effects: STORAGE_STACK
    local _USE_LVM="${1:-false}"
    if [[ "$ROOT_FS" == "zfs" ]]; then
        STORAGE_STACK="zfs"
    elif [[ "$USE_LUKS" == true && "$_USE_LVM" == true ]]; then
        STORAGE_STACK="luks_lvm"
    elif [[ "$USE_LUKS" == true && "$ROOT_FS" == "btrfs" ]]; then
        STORAGE_STACK="luks_btrfs"
    elif [[ "$USE_LUKS" == true ]]; then
        STORAGE_STACK="luks"
    elif [[ "$_USE_LVM" == true ]]; then
        STORAGE_STACK="lvm"
    elif [[ "$ROOT_FS" == "btrfs" ]]; then
        STORAGE_STACK="btrfs"
    else
        STORAGE_STACK="plain"
    fi
}

# _mkinitcpio_hooks → echoes the correct HOOKS line for STORAGE_STACK
function _mkinitcpio_hooks() {
    # inputs: STORAGE_STACK / outputs: hook string to stdout
    local base="base udev autodetect microcode modconf kms keyboard keymap consolefont block"
    local tail="filesystems fsck"
    case "${STORAGE_STACK:-plain}" in
        plain|btrfs)
            echo "${base} ${tail}" ;;
        luks|luks_btrfs)
            echo "${base} encrypt ${tail}" ;;
        lvm)
            echo "${base} lvm2 ${tail}" ;;
        luks_lvm)
            # encrypt MUST come before lvm2 — hard rule
            echo "${base} encrypt lvm2 ${tail}" ;;
        zfs)
            echo "${base} zfs ${tail}" ;;
        *)
            echo "${base} ${tail}" ;;
    esac
}

# -----------------------------------------------------------------------------
#  storage_wizard — Step 3 UI function
# -----------------------------------------------------------------------------

function storage_wizard() {
    # inputs: none / side-effects: sets STORAGE_STACK USE_LUKS LVM_* ZFS_* globals
    section "Storage stack"

    # ── Filesystem ────────────────────────────────────────────────────────────
    section "Filesystem"
    local fs_opts=(
        "btrfs  — snapshots, zstd compression, CoW  (recommended)"
        "ext4   — rock-solid, most compatible"
        "xfs    — high performance, large files  (cannot shrink later)"
        "f2fs   — Flash-Friendly, optimised for NVMe/SSD"
        "$BACK"
    )
    local fs_sel
    fs_sel=$(choose_one "${fs_opts[0]}" "${fs_opts[@]}")
    if [[ "$fs_sel" == "$BACK" ]]; then return 1; fi

    case "${fs_sel%% *}" in
        ext4) ROOT_FS="ext4" ;;
        xfs)  ROOT_FS="xfs"  ;;
        f2fs) ROOT_FS="f2fs" ;;
        *)    ROOT_FS="btrfs" ;;
    esac
    ok "Root filesystem: ${ROOT_FS}"

    if [[ "$ROOT_FS" == "btrfs" ]]; then
        info "btrfs subvolumes: @  @home  @snapshots  @var_log  @var_cache  @tmp"
    fi
    if [[ "$ROOT_FS" != "btrfs" ]]; then
        info "Note: Snapper snapshots require btrfs — will be unavailable."
    fi
    blank

    # ── ZFS path — separate flow ──────────────────────────────────────────────
    if [[ "$ROOT_FS" == "zfs" ]]; then
        blank
        if [[ "${NO_GUM:-false}" == false ]]; then
            gum style \
                --border        rounded \
                --border-foreground "$GUM_C_WARN" \
                --padding       "0 2" \
                --width         "$GUM_WIDTH" \
                "$(_clr "$GUM_C_WARN" "  ZFS on Arch requires archzfs from the AUR.")" \
                "$(_clr "$GUM_C_DIM"  "  The installer will attempt to bootstrap it")" \
                "$(_clr "$GUM_C_DIM"  "  in the live environment before proceeding.")" \
                2>/dev/null || true
        else
            warn "ZFS requires archzfs from AUR — will bootstrap in live env."
        fi
        blank

        if ! _zfs_available; then
            warn "ZFS tools not found in live environment."
            if confirm_gum "Attempt to install zfs-dkms + zfs-utils now? (takes 2-5 min)"; then
                run_spin "Installing ZFS DKMS (compiling kernel modules)…" \
                    "pacman -Sy --noconfirm archlinux-keyring && \
                     curl -s https://archzfs.com/archzfs.gpg | pacman-key --add - && \
                     pacman-key --lsign-key archzfs && \
                     pacman -Sy --noconfirm zfs-dkms zfs-utils"
                if ! _zfs_available; then
                    warn "ZFS bootstrap failed — falling back to btrfs."
                    ROOT_FS="btrfs"
                fi
            else
                warn "ZFS not available — falling back to btrfs."
                ROOT_FS="btrfs"
            fi
        fi

        if [[ "$ROOT_FS" == "zfs" ]]; then
            local zpool_input
            zpool_input=$(input_gum "ZFS pool name" "zroot")
            if [[ -n "$zpool_input" && "$zpool_input" != "$BACK" ]]; then
                ZFS_POOL="$zpool_input"
            fi
            STORAGE_STACK="zfs"
            USE_LUKS=false
            ok "Storage stack: ZFS  (pool: ${ZFS_POOL})"
            blank
            return 0
        fi
    fi

    # ── Encryption ────────────────────────────────────────────────────────────
    section "Encryption"
    if [[ "${NO_GUM:-false}" == false ]]; then
        gum style \
            --border        rounded \
            --border-foreground "$GUM_C_DIM" \
            --padding       "0 2" \
            --width         "$GUM_WIDTH" \
            "$(_clr "$GUM_C_INFO" "  LUKS2 encrypts at the block device level.")" \
            "$(_clr "$GUM_C_WARN" "  Passphrase required at EVERY boot — do not lose it.")" \
            "$(_clr "$GUM_C_DIM"  "  Cipher: AES-256-XTS  •  KDF: argon2id")" \
            2>/dev/null || true
    else
        info "LUKS2: AES-256-XTS, argon2id KDF. Passphrase required at every boot."
    fi
    blank

    if confirm_gum "Enable LUKS2 full-disk encryption?"; then
        USE_LUKS=true
        # Passwords NEVER in argv — collected via password_gum which reads from tty
        LUKS_PASSWORD=$(password_gum "LUKS passphrase")
        ok "LUKS2 enabled"
    else
        USE_LUKS=false
        ok "No encryption"
    fi
    blank

    # ── LVM ───────────────────────────────────────────────────────────────────
    # LVM is only offered for ext4/xfs/f2fs — btrfs has its own volume system.
    local _USE_LVM=false
    if [[ "$ROOT_FS" != "btrfs" ]]; then
        section "Volume management"
        if [[ "${NO_GUM:-false}" == false ]]; then
            gum style \
                --border        rounded \
                --border-foreground "$GUM_C_DIM" \
                --padding       "0 2" \
                --width         "$GUM_WIDTH" \
                "$(_clr "$GUM_C_INFO" "  LVM allows resizing volumes without repartitioning.")" \
                "$(_clr "$GUM_C_DIM"  "  Recommended when you want flexible volume management.")" \
                "$(_clr "$GUM_C_DIM"  "  Not needed for most single-disk installs.")" \
                2>/dev/null || true
        fi
        blank

        if confirm_gum "Use LVM (Logical Volume Manager)?"; then
            if ! _lvm_available; then
                warn "lvm2 tools not found — installing now."
                run_spin "Installing lvm2…" "pacman -Sy --noconfirm lvm2"
            fi
            _USE_LVM=true

            local vg_input
            vg_input=$(input_gum "LVM Volume Group name" "${LVM_VG:-arch_vg}")
            if [[ -n "$vg_input" && "$vg_input" != "$BACK" ]]; then
                LVM_VG="$vg_input"
            fi

            local lv_root_input
            lv_root_input=$(input_gum "LV name for root" "${LVM_LV_ROOT:-root}")
            if [[ -n "$lv_root_input" && "$lv_root_input" != "$BACK" ]]; then
                LVM_LV_ROOT="$lv_root_input"
            fi

            local lv_home_input
            lv_home_input=$(input_gum "LV name for home (used if /home is separate)" \
                "${LVM_LV_HOME:-home}")
            if [[ -n "$lv_home_input" && "$lv_home_input" != "$BACK" ]]; then
                LVM_LV_HOME="$lv_home_input"
            fi
            ok "LVM: VG=${LVM_VG}  root=${LVM_LV_ROOT}  home=${LVM_LV_HOME}"
        else
            ok "No LVM"
        fi
        blank
    fi

    # ── Derive and display final stack ────────────────────────────────────────
    _derive_storage_stack "$_USE_LVM"

    local hooks
    hooks=$(_mkinitcpio_hooks)

    if [[ "${NO_GUM:-false}" == false ]]; then
        gum style \
            --border        rounded \
            --border-foreground "$GUM_C_OK" \
            --padding       "0 2" \
            --width         "$GUM_WIDTH" \
            "$(_clr "$GUM_C_OK"  "  Stack  : ${STORAGE_STACK}")" \
            "$(_clr "$GUM_C_DIM" "  FS     : ${ROOT_FS}")" \
            "$(_clr "$GUM_C_DIM" "  LUKS2  : ${USE_LUKS}")" \
            "$(_clr "$GUM_C_DIM" "  LVM    : ${_USE_LVM}")" \
            "$(_clr "$GUM_C_DIM" "  Hooks  : ${hooks}")" \
            2>/dev/null || true
    else
        ok "Stack: ${STORAGE_STACK}  FS: ${ROOT_FS}  LUKS: ${USE_LUKS}  LVM: ${_USE_LVM}"
    fi
    blank
    return 0
}
