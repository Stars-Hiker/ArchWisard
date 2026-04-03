#!/usr/bin/env bash
# =============================================================================
#  lib/disk.sh — Step 2: disk survey, OS probe, space planning, selection
#
#  Pure logic functions (no gum):
#    _probe_all_oses()       — scans all partitions, populates _FOUND_* arrays
#    _probe_free_space()     — computes free/disposable GB for a disk
#    _probe_efi_parts()      — finds ESP candidates on a disk
#    _build_disk_list()      — populates DISK_LIST_LABELS array
#
#  UI functions:
#    discover_disks()        — display table + OS detection + multi-boot confirm
#    select_disks()          — pick root/home disk, guard existing OSes
#    _check_and_plan_space() — space analysis wizard (delete/shrink/other disk)
# =============================================================================

# Populated by _probe_all_oses() — parallel arrays
_FOUND_NAMES=()
_FOUND_PARTS=()

# Populated by _build_disk_list()
DISK_LIST_LABELS=()

# -----------------------------------------------------------------------------
#  Pure probing helpers
# -----------------------------------------------------------------------------

# _probe_all_oses → populates _FOUND_NAMES[] _FOUND_PARTS[]
function _probe_all_oses() {
    # inputs: blkid / side-effects: _FOUND_NAMES _FOUND_PARTS globals
    _FOUND_NAMES=()
    _FOUND_PARTS=()

    local _mounted_devs
    _mounted_devs=$(awk '{print $1}' /proc/mounts 2>/dev/null | sort -u)

    # Collect candidates: unmounted, ≥1 GB, known FS types
    local _candidates=()
    while IFS= read -r p; do
        if [[ -z "$p" ]]; then continue; fi
        if echo "$_mounted_devs" | grep -qxF "$p"; then continue; fi
        if [[ "$p" == /dev/loop* || "$p" == /dev/sr* ]]; then continue; fi
        local _pb
        _pb=$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)
        if (( _pb < 1073741824 )); then continue; fi
        _candidates+=("$p")
    done < <({
        blkid -t TYPE="ext4"        -o device 2>/dev/null
        blkid -t TYPE="btrfs"       -o device 2>/dev/null
        blkid -t TYPE="xfs"         -o device 2>/dev/null
        blkid -t TYPE="f2fs"        -o device 2>/dev/null
        blkid -t TYPE="crypto_LUKS" -o device 2>/dev/null
    } | sort -u)

    local p
    for p in "${_candidates[@]}"; do
        probe_os_from_part "$p" || true
        if [[ -n "$PROBE_OS_RESULT" ]]; then
            _FOUND_NAMES+=("$PROBE_OS_RESULT")
            _FOUND_PARTS+=("$p")
        fi
    done

    # Supplement from NVRAM — catches bootloaders not on a mounted partition
    local _bl
    _bl="BootManager|BootApp|EFI Default|SortOrder"
    _bl+="|^Windows|ArchWizard"
    _bl+="|^UEFI[[:space:]]|^UEFI:|Firmware|Setup|Admin"
    _bl+="|^Shell|^EFI Shell"
    _bl+="|PXE|iPXE|Network|LAN|WAN"
    _bl+="|Diagnostic|MemTest|Memory Test"
    _bl+="|USB|CD-ROM|DVD|Optical|SD Card"
    _bl+="|Recovery|Maintenance|Internal|Application|Menu|Manager"

    if command -v efibootmgr &>/dev/null; then
        local line _lbl
        while IFS= read -r line; do
            _lbl=$(echo "$line" \
                | sed 's/Boot[0-9A-Fa-f]*\*[[:space:]]*//' \
                | sed 's/[[:space:]]*[A-Z][A-Z](.*$//'     \
                | sed 's/[[:space:]]*$//')
            if [[ -z "$_lbl" || ${#_lbl} -lt 2 ]]; then continue; fi
            if ! echo "$_lbl" | grep -q '[a-zA-Z]'; then continue; fi
            if echo "$_lbl" | grep -qiE "$_bl"; then continue; fi
            if echo "$_lbl" | grep -qi "windows"; then continue; fi
            local _seen=false _n
            for _n in "${_FOUND_NAMES[@]+"${_FOUND_NAMES[@]}"}"; do
                if echo "$_n" | grep -qi "$_lbl"; then _seen=true; break; fi
            done
            if [[ "$_seen" == false ]]; then
                _FOUND_NAMES+=("$_lbl")
                _FOUND_PARTS+=("")
            fi
        done < <(efibootmgr 2>/dev/null | grep -E '^Boot[0-9A-Fa-f]{4}' || true)
    fi

    # Windows NTFS partitions
    local _wp
    while IFS= read -r _wp; do
        if [[ -n "$_wp" ]]; then
            _FOUND_NAMES+=("Windows")
            _FOUND_PARTS+=("$_wp")
        fi
    done < <(blkid -t TYPE="ntfs" -o device 2>/dev/null || true)
}

# _probe_free_space DISK → sets _FREE_GB _DISPOSABLE_GB _DISPOSABLE_PARTS[]
_FREE_GB=0
_DISPOSABLE_GB=0
_DISPOSABLE_PARTS=()
function _probe_free_space() {
    # inputs: disk_path / side-effects: _FREE_GB _DISPOSABLE_GB _DISPOSABLE_PARTS
    local disk="$1"
    _FREE_GB=0
    _DISPOSABLE_GB=0
    _DISPOSABLE_PARTS=()

    # Unallocated space
    local total_free_bytes=0
    local fb
    while IFS= read -r line; do
        fb=$(echo "$line" | awk '{print $3}' | tr -d 'B')
        total_free_bytes=$(( total_free_bytes + ${fb:-0} ))
    done < <(parted -s "$disk" unit B print free 2>/dev/null \
              | grep "Free Space" || true)
    _FREE_GB=$(( total_free_bytes / 1073741824 ))

    # Disposable: partitions we could delete (not EFI, not swap-type, not protected, ≥1 GB)
    local p _pt _pb _pb_gb
    while IFS= read -r p; do
        if [[ -z "$p" ]]; then continue; fi
        _pt=$(lsblk -no PARTTYPE "$p" 2>/dev/null || echo "")
        _pb=$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)
        _pb_gb=$(( _pb / 1073741824 ))
        # Skip EFI system partition
        if [[ "$_pt" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]]; then continue; fi
        # Skip BIOS boot partition
        if [[ "$_pt" == "0657fd6d-a4ab-43c4-84e5-0933c84b4f4f" ]]; then continue; fi
        if (( _pb_gb < 1 )); then continue; fi
        if _is_protected "$p"; then continue; fi
        _DISPOSABLE_PARTS+=("$p")
        _DISPOSABLE_GB=$(( _DISPOSABLE_GB + _pb_gb ))
    done < <(lsblk -ln -o PATH "$disk" 2>/dev/null | tail -n +2)
}

# _probe_efi_parts DISK → populates _EFI_LIST[]
_EFI_LIST=()
function _probe_efi_parts() {
    # inputs: disk_path / side-effects: _EFI_LIST global
    _EFI_LIST=()
    local p pttype size_mb
    while IFS= read -r p; do
        pttype=$(lsblk -no PARTTYPE "$p" 2>/dev/null || echo "")
        size_mb=$(( $(blockdev --getsize64 "$p" 2>/dev/null || echo 0) / 1048576 ))
        if [[ "$pttype" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] \
           || (( size_mb <= 1024 )); then
            _EFI_LIST+=("$p")
        fi
    done < <(blkid -t TYPE="vfat" -o device 2>/dev/null || true)
}

# _build_disk_list → populates DISK_LIST_LABELS[]
function _build_disk_list() {
    # inputs: lsblk / side-effects: DISK_LIST_LABELS global
    DISK_LIST_LABELS=()
    local dev size rota tran model media
    while IFS= read -r dev; do
        size=$(lsblk  -dno SIZE  "/dev/${dev}" 2>/dev/null || echo "?")
        rota=$(lsblk  -dno ROTA  "/dev/${dev}" 2>/dev/null || echo "")
        tran=$(lsblk  -dno TRAN  "/dev/${dev}" 2>/dev/null || echo "")
        model=$(lsblk -dno MODEL "/dev/${dev}" 2>/dev/null | cut -c1-28 || echo "")
        if   [[ "$tran" == "nvme" ]]; then media="NVMe"
        elif [[ "$rota" == "0"   ]]; then media="SSD"
        elif [[ "$tran" == "usb" ]]; then media="USB"
        else                              media="HDD"; fi
        DISK_LIST_LABELS+=("$(printf '/dev/%-10s  %-7s  %-5s  %s' \
            "$dev" "$size" "$media" "$model")")
    done < <(lsblk -d -n -o NAME 2>/dev/null | grep -v "^loop\|^sr")
}

# -----------------------------------------------------------------------------
#  UI helpers
# -----------------------------------------------------------------------------

function _ui_disk_table() {
    # inputs: none / side-effects: prints formatted disk table
    local rows=()
    local dev name size rota tran pttype model media
    while IFS= read -r dev; do
        name=$(lsblk   -dno NAME    "/dev/${dev}" 2>/dev/null)
        size=$(lsblk   -dno SIZE    "/dev/${dev}" 2>/dev/null)
        rota=$(lsblk   -dno ROTA    "/dev/${dev}" 2>/dev/null)
        tran=$(lsblk   -dno TRAN    "/dev/${dev}" 2>/dev/null)
        pttype=$(lsblk -dno PTTYPE  "/dev/${dev}" 2>/dev/null)
        model=$(lsblk  -dno MODEL   "/dev/${dev}" 2>/dev/null | cut -c1-22)
        if   [[ "$tran" == "nvme" ]]; then media="NVMe"
        elif [[ "$rota" == "0"   ]]; then media="SSD"
        elif [[ "$tran" == "usb" ]]; then media="USB"
        else                              media="HDD"; fi
        rows+=("$(printf '%-14s  %-7s  %-5s  %-6s  %-5s  %-22s' \
            "/dev/${name}" "${size}" "${media}" \
            "${tran:---}" "${pttype:---}" "${model:-Unknown}")")
    done < <(lsblk -d -n -o NAME 2>/dev/null | grep -v "^loop\|^sr")

    if [[ "${NO_GUM:-false}" == true ]]; then
        printf '%-14s  %-7s  %-5s  %-6s  %-5s  %-22s\n' \
            DEVICE SIZE TYPE TRAN TABLE MODEL
        printf '%s\n' "──────────────────────────────────────────────────────"
        local r
        for r in "${rows[@]}"; do printf '%s\n' "$r"; done
        return 0
    fi

    gum style \
        --border        rounded \
        --border-foreground "$GUM_C_TITLE" \
        --padding       "0 1" \
        --width         "$GUM_WIDTH" \
        "$(_clr "$GUM_C_ACCENT" "$(printf '%-14s  %-7s  %-5s  %-6s  %-5s  %-22s' \
            DEVICE SIZE TYPE TRAN TABLE MODEL)")" \
        "$(_clr "$GUM_C_DIM"    "$(printf '%-14s  %-7s  %-5s  %-6s  %-5s  %-22s' \
            '──────────────' '───────' '─────' '──────' '─────' '──────────────────────')")" \
        "${rows[@]}" 2>/dev/null || true
}

function _ui_disk_partitions() {
    # inputs: none / side-effects: prints partition layout per disk
    local dev has_parts
    while IFS= read -r dev; do
        has_parts=$(lsblk -n -o NAME "/dev/${dev}" 2>/dev/null | tail -n +2)
        if [[ -z "$has_parts" ]]; then continue; fi
        if [[ "${NO_GUM:-false}" == true ]]; then
            printf '  /dev/%s\n' "$dev"
        else
            gum style --foreground "$GUM_C_INFO" --bold "  /dev/${dev}" 2>/dev/null \
                || printf '  /dev/%s\n' "$dev"
        fi
        lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "/dev/${dev}" 2>/dev/null \
            | tail -n +2 \
            | while IFS= read -r line; do
                if [[ "${NO_GUM:-false}" == true ]]; then
                    printf '    %s\n' "$line"
                else
                    gum style --foreground "$GUM_C_DIM" "    $line" 2>/dev/null \
                        || printf '    %s\n' "$line"
                fi
              done
        blank
    done < <(lsblk -d -n -o NAME 2>/dev/null | grep -v "^loop\|^sr")
}

# -----------------------------------------------------------------------------
#  discover_disks — Step 2 first half
# -----------------------------------------------------------------------------

function discover_disks() {
    # inputs: none / side-effects: sets DUAL_BOOT EXISTING_SYSTEMS EFI_PART REUSE_EFI
    section "Disk discovery"

    run_spin "Scanning block devices…" "sleep 0.3"
    _ui_disk_table
    blank
    info "Partitions:"
    blank
    _ui_disk_partitions

    run_spin "Probing for existing operating systems…" "sleep 0.2"
    _probe_all_oses

    if [[ ${#_FOUND_NAMES[@]} -gt 0 ]]; then
        blank
        warn "Existing OS(es) detected:"
        blank

        local os_lines=() i
        for i in "${!_FOUND_NAMES[@]}"; do
            local _pinfo=""
            if [[ -n "${_FOUND_PARTS[$i]}" ]]; then
                local _psize
                _psize=$(lsblk -dno SIZE "${_FOUND_PARTS[$i]}" 2>/dev/null || echo "?")
                _pinfo="  (${_FOUND_PARTS[$i]}, ${_psize})"
            fi
            os_lines+=("  →  ${_FOUND_NAMES[$i]}${_pinfo}")
        done

        if [[ "${NO_GUM:-false}" == true ]]; then
            local l; for l in "${os_lines[@]}"; do printf '%s\n' "$l"; done
        else
            gum style \
                --border        normal \
                --border-foreground "$GUM_C_WARN" \
                --padding       "0 2" \
                --width         "$GUM_WIDTH" \
                "${os_lines[@]}" 2>/dev/null || true
        fi
        blank

        if confirm_gum "Install Arch alongside these system(s)?"; then
            DUAL_BOOT=true
            local n
            for n in "${_FOUND_NAMES[@]}"; do
                if echo "$n" | grep -qi "windows"; then EXISTING_WINDOWS=true; fi
                if ! echo "$n" | grep -qi "windows"; then EXISTING_LINUX=true; fi
                EXISTING_SYSTEMS+=("$n")
            done
            ok "Multi-boot mode — existing partitions will be preserved"
            if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
                info "GRUB + os-prober strongly recommended for multi-boot."
            fi
        fi
    fi

    # ESP detection for multi-boot
    if [[ "$DUAL_BOOT" == true && "$FIRMWARE_MODE" == "uefi" ]]; then
        _probe_efi_parts ""  # pass empty, we search all vfat devices

        if [[ ${#_EFI_LIST[@]} -gt 0 ]]; then
            blank
            info "EFI System Partition(s) found:"
            blank
            local ep _esize _elbl
            for ep in "${_EFI_LIST[@]}"; do
                _esize=$(lsblk -dno SIZE "$ep" 2>/dev/null || echo "?")
                _elbl=$(blkid -s LABEL -o value "$ep" 2>/dev/null || echo "")
                info "  →  ${ep}  (${_esize})${_elbl:+  label: ${_elbl}}"
            done
            blank

            if [[ ${#_EFI_LIST[@]} -eq 1 ]]; then
                EFI_PART="${_EFI_LIST[0]}"
                REUSE_EFI=true
                ok "Reusing ESP: ${EFI_PART}"
            else
                if confirm_gum "Reuse existing ESP? (strongly recommended for multi-boot)"; then
                    REUSE_EFI=true
                    EFI_PART=$(choose_one "${_EFI_LIST[0]}" "${_EFI_LIST[@]}")
                    if [[ "$EFI_PART" == "$BACK" || -z "$EFI_PART" ]]; then
                        REUSE_EFI=false
                        EFI_PART=""
                    else
                        ok "Will reuse ESP: ${EFI_PART}"
                    fi
                fi
            fi
        fi
    fi
}

# -----------------------------------------------------------------------------
#  select_disks — Step 2 second half
# -----------------------------------------------------------------------------

function select_disks() {
    # inputs: _FOUND_* / side-effects: DISK_ROOT DISK_HOME DUAL_BOOT PROTECTED_PARTS
    section "Select disks"

    _build_disk_list

    if [[ ${#DISK_LIST_LABELS[@]} -eq 0 ]]; then
        die "No block devices found. Something is very wrong."
    fi

    # Pick root disk
    info "Select disk for root (/):"
    blank
    local root_choice
    root_choice=$(choose_one "${DISK_LIST_LABELS[0]}" "${DISK_LIST_LABELS[@]}" "$BACK")
    if [[ "$root_choice" == "$BACK" ]]; then return 1; fi
    DISK_ROOT=$(echo "$root_choice" | awk '{print $1}')
    DISK_HOME="$DISK_ROOT"
    ok "Root disk: ${DISK_ROOT}"

    # Sanity: minimum size warning
    local root_gb
    root_gb=$(( $(blockdev --getsize64 "$DISK_ROOT" 2>/dev/null || echo 0) / 1073741824 ))
    if (( root_gb < 15 )); then
        blank
        warn "${DISK_ROOT} is only ${root_gb} GB — 20 GB minimum recommended."
        blank
        if ! confirm_gum "Continue anyway?"; then return 1; fi
    fi

    # OS guard: if DUAL_BOOT wasn't already confirmed via discover_disks,
    # probe for OSes on the selected disk and ask per-OS keep/discard.
    if [[ "$DUAL_BOOT" == false ]]; then
        local _guard_found=()
        local p _pt _pb
        while IFS= read -r p; do
            if [[ -z "$p" ]]; then continue; fi
            _pt=$(lsblk -no PARTTYPE "$p" 2>/dev/null || echo "")
            _pb=$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)
            if [[ "$_pt" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]]; then continue; fi
            if [[ "$_pt" == "0657fd6d-a4ab-43c4-84e5-0933c84b4f4f" ]]; then continue; fi
            if (( _pb < 500000000 )); then continue; fi
            probe_os_from_part "$p" || true
            if [[ -n "$PROBE_OS_RESULT" ]]; then
                _guard_found+=("${PROBE_OS_RESULT}|${p}")
            fi
        done < <(lsblk -ln -o PATH "$DISK_ROOT" 2>/dev/null | tail -n +2)

        if [[ ${#_guard_found[@]} -gt 0 ]]; then
            blank
            warn "Existing OS(es) on ${DISK_ROOT}:"
            blank
            local entry _en _ep _es
            for entry in "${_guard_found[@]}"; do
                _en="${entry%%|*}"
                _ep="${entry##*|}"
                _es=$(lsblk -dno SIZE "$_ep" 2>/dev/null || echo "?")
                info "  →  ${_en}  (${_ep}, ${_es})"
            done
            blank

        local _any_kept=false
        local _discarded_parts=()   # partitions user explicitly said "don't keep"
        local entry _en _ep _es
        for entry in "${_guard_found[@]}"; do
            _en="${entry%%|*}"
            _ep="${entry##*|}"
            _es=$(lsblk -dno SIZE "$_ep" 2>/dev/null || echo "?")
            blank
            info "[${_en}]  ${_ep} (${_es})"
            if confirm_gum "Keep ${_en}? (No = available for deletion/reuse)"; then
                EXISTING_SYSTEMS+=("$_en")
                PROTECTED_PARTS+=("$_ep")
                if echo "$_en" | grep -qi "windows"; then
                    EXISTING_WINDOWS=true
                else
                    EXISTING_LINUX=true
                fi
                ok "${_en} → PRESERVED"
                _any_kept=true
            else
                warn "${_en} (${_ep}) → will be DELETED"
                _discarded_parts+=("$_ep")
            fi
        done
        blank

        if [[ "$_any_kept" == true ]]; then
            DUAL_BOOT=true
            local _sys_str
            _sys_str=$(IFS=', '; echo "${EXISTING_SYSTEMS[*]}")
            ok "Multi-boot — preserving: ${_sys_str}"

            # Queue explicitly discarded partitions BEFORE space analysis so
            # _check_and_plan_space knows about them and won't re-detect them.
            if [[ ${#_discarded_parts[@]} -gt 0 ]]; then
                REPLACE_PARTS_ALL=("${_discarded_parts[@]}")
                REPLACE_PART="${_discarded_parts[0]}"
                local _dp _dg _total_freed=0
                for _dp in "${_discarded_parts[@]}"; do
                    _dg=$(( $(blockdev --getsize64 "$_dp" 2>/dev/null || echo 0) / 1073741824 ))
                    _total_freed=$(( _total_freed + _dg ))
                done
                info "Explicit deletion plan: ${_discarded_parts[*]}  (${_total_freed} GB freed)"
            fi

            _check_and_plan_space "$DISK_ROOT"
            else
                blank
                if [[ "${NO_GUM:-false}" == false ]]; then
                    gum style \
                        --foreground        "$GUM_C_ERR" \
                        --border            thick \
                        --border-foreground "$GUM_C_ERR" \
                        --padding           "0 2" \
                        --width             "$GUM_WIDTH" \
                        "No OS kept — entire disk will be wiped." \
                        2>/dev/null || true
                else
                    warn "No OS kept — entire disk will be wiped."
                fi
                blank
                confirm_gum "I understand — erase everything on ${DISK_ROOT}" \
                    || return 1
            fi
        else
            info "No existing OS on ${DISK_ROOT} — fresh install."
        fi
    fi

    # Optional: separate home disk
    if [[ ${#DISK_LIST_LABELS[@]} -gt 1 ]]; then
        blank
        if confirm_gum "Put /home on a different disk?"; then
            local home_candidates=()
            local item d
            for item in "${DISK_LIST_LABELS[@]}"; do
                d=$(echo "$item" | awk '{print $1}')
                if [[ "$d" != "$DISK_ROOT" ]]; then
                    home_candidates+=("$item")
                fi
            done
            if [[ ${#home_candidates[@]} -eq 0 ]]; then
                warn "No other disk available — /home stays on ${DISK_ROOT}."
            else
                blank
                info "Select disk for /home:"
                blank
                local home_choice
                home_choice=$(choose_one "${home_candidates[0]}" \
                    "${home_candidates[@]}" "$BACK")
                if [[ "$home_choice" != "$BACK" && -n "$home_choice" ]]; then
                    DISK_HOME=$(echo "$home_choice" | awk '{print $1}')
                    ok "Home disk: ${DISK_HOME}"
                fi
            fi
        fi
    fi

    # Summary banner
    blank
    local banner_lines=("  DISKS TO BE MODIFIED:" "")
    banner_lines+=("    Root : $DISK_ROOT")
    if [[ "$DISK_HOME" != "$DISK_ROOT" ]]; then
        banner_lines+=("    Home : $DISK_HOME")
    fi
    if [[ "$DUAL_BOOT" == true ]]; then
        local _sl
        _sl=$(IFS=', '; echo "${EXISTING_SYSTEMS[*]}")
        banner_lines+=("  Mode : multi-boot — preserving: ${_sl}")
    else
        banner_lines+=("  Mode : fresh install — ENTIRE DISK WILL BE WIPED")
    fi

    if [[ "${NO_GUM:-false}" == true ]]; then
        local l; for l in "${banner_lines[@]}"; do warn "$l"; done
    else
        gum style \
            --foreground        "$GUM_C_WARN" \
            --border            double \
            --border-foreground "$GUM_C_WARN" \
            --padding           "0 1" \
            --width             "$GUM_WIDTH" \
            "${banner_lines[@]}" 2>/dev/null || true
    fi
    blank
    return 0
}

# -----------------------------------------------------------------------------
#  _check_and_plan_space — called from select_disks when multi-boot is confirmed
# -----------------------------------------------------------------------------

function _check_and_plan_space() {
    # inputs: disk_path / side-effects: REPLACE_PART REPLACE_PARTS_ALL RESIZE_PART
    #         RESIZE_NEW_GB FREE_GB_AVAIL
    local disk="$1"
    local NEEDED_GB=7

    _probe_free_space "$disk"
    local free_gb=$_FREE_GB
    local disposable_gb=$_DISPOSABLE_GB
    local total_avail_gb=$(( free_gb + disposable_gb ))
    FREE_GB_AVAIL=$total_avail_gb

    section "Space analysis — ${disk}"

    local info_lines=(
        "$(_clr "$GUM_C_INFO" "  Unallocated:       ${free_gb} GB")"
        "$(_clr "$GUM_C_INFO" "  Minimum needed:    ${NEEDED_GB} GB")"
    )
    if [[ ${#_DISPOSABLE_PARTS[@]} -gt 0 ]]; then
        info_lines+=(
            "$(_clr "$GUM_C_WARN" "  Reclaimable:       ${disposable_gb} GB  (${_DISPOSABLE_PARTS[*]})")"
            "$(_clr "$GUM_C_OK"   "  Total for Arch:    ${total_avail_gb} GB")"
        )
    fi

    if [[ "${NO_GUM:-false}" == true ]]; then
        local l; for l in "${info_lines[@]}"; do printf '%s\n' "$l"; done
    else
        gum style \
            --border        rounded \
            --border-foreground "$GUM_C_DIM" \
            --padding       "0 1" \
            --width         "$GUM_WIDTH" \
            "${info_lines[@]}" 2>/dev/null || true
    fi
    blank

    # Case 1: enough unallocated space already
    if (( free_gb >= NEEDED_GB )); then
        ok "Sufficient unallocated space (${free_gb} GB ≥ ${NEEDED_GB} GB)."
        # Add space freed by any pre-planned deletions to the layout budget.
        local _pre_freed=0 _prp _prg
        for _prp in "${REPLACE_PARTS_ALL[@]+"${REPLACE_PARTS_ALL[@]}"}"; do
            _prg=$(( $(blockdev --getsize64 "$_prp" 2>/dev/null || echo 0) / 1073741824 ))
            _pre_freed=$(( _pre_freed + _prg ))
        done
        FREE_GB_AVAIL=$(( free_gb + _pre_freed ))
        blank
        return 0
    fi

    # Case 2: enough if we delete disposable partitions — plan it automatically
    if (( total_avail_gb >= NEEDED_GB && ${#_DISPOSABLE_PARTS[@]} > 0 )); then
        ok "Enough space by removing unneeded partitions."
        blank
        # Only auto-assign if not already set by explicit user decisions above.
        if [[ ${#REPLACE_PARTS_ALL[@]} -eq 0 ]]; then
            local dp
            for dp in "${_DISPOSABLE_PARTS[@]}"; do
                probe_os_from_part "$dp" || true
                local _ds
                _ds=$(lsblk -dno SIZE "$dp" 2>/dev/null || echo "?")
                warn "  Will DELETE: ${dp}  (${_ds})  — ${PROBE_OS_RESULT:-partition}"
            done
            REPLACE_PART="${_DISPOSABLE_PARTS[0]}"
            REPLACE_PARTS_ALL=("${_DISPOSABLE_PARTS[@]}")
        fi
        FREE_GB_AVAIL=$total_avail_gb
        warn "Deletions will occur after installation summary is confirmed."
        blank
        return 0
    fi

    # Case 3: need user help — not enough space
    if [[ "${NO_GUM:-false}" == false ]]; then
        gum style \
            --foreground        "$GUM_C_WARN" \
            --border            thick \
            --border-foreground "$GUM_C_WARN" \
            --padding           "0 2" \
            --width             "$GUM_WIDTH" \
            "Not enough space (${total_avail_gb} GB < ${NEEDED_GB} GB)." \
            2>/dev/null || true
    else
        warn "Not enough space (${total_avail_gb} GB < ${NEEDED_GB} GB)."
    fi
    blank

    # Build candidate list for delete/shrink
    local candidates=()
    local p pt ft pb pb_gb
    while IFS= read -r p; do
        if [[ -z "$p" ]]; then continue; fi
        pt=$(lsblk  -no PARTTYPE "$p" 2>/dev/null || echo "")
        ft=$(blkid  -s TYPE -o value "$p" 2>/dev/null || echo "")
        pb=$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)
        pb_gb=$(( pb / 1073741824 ))
        if [[ "$pt" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]]; then continue; fi
        if _is_protected "$p"; then continue; fi
        if (( pb_gb < 1 )); then continue; fi
        probe_os_from_part "$p" || true
        local os_n="${PROBE_OS_RESULT:-}"
        if [[ "$ft" == "swap" ]]; then os_n="[swap]"; fi
        candidates+=("$p|$ft|$pb_gb|${os_n}")
    done < <(lsblk -ln -o PATH "$disk" 2>/dev/null | tail -n +2)

    # Fall back to protected partitions for shrink if nothing else available
    if [[ ${#candidates[@]} -eq 0 ]]; then
        local _pp _ft _pb_gb
        for _pp in "${PROTECTED_PARTS[@]+"${PROTECTED_PARTS[@]}"}"; do
            _ft=$(blkid -s TYPE -o value "$_pp" 2>/dev/null || echo "?")
            _pb_gb=$(( $(blockdev --getsize64 "$_pp" 2>/dev/null || echo 0) / 1073741824 ))
            candidates+=("$_pp|$_ft|$_pb_gb|[kept — shrink to make space]")
        done
    fi

    if [[ ${#candidates[@]} -eq 0 ]]; then
        warn "No suitable partitions. Use GParted live to free space, then re-run."
        FREE_GB_AVAIL=0
        return 0
    fi

    # Check for other disks
    local other_disks=()
    local dev ob
    while IFS= read -r dev; do
        if [[ "/dev/$dev" == "$disk" ]]; then continue; fi
        ob=$(blockdev --getsize64 "/dev/$dev" 2>/dev/null || echo 0)
        if [[ $(( ob / 1073741824 )) -ge $NEEDED_GB ]]; then
            other_disks+=("/dev/$dev")
        fi
    done < <(lsblk -d -n -o NAME 2>/dev/null | grep -v "^loop\|^sr")

    # Offer options
    local space_opts=()
    if [[ ${#other_disks[@]} -gt 0 ]]; then
        space_opts+=("Use a different disk entirely")
    fi
    local _has_unprotected=false _c _cp
    for _c in "${candidates[@]}"; do
        _cp="${_c%%|*}"
        if ! _is_protected "$_cp"; then _has_unprotected=true; break; fi
    done
    if [[ "$_has_unprotected" == true ]]; then
        space_opts+=("Delete a partition  (ALL DATA LOST)")
    fi
    space_opts+=("Shrink a partition  (keep data, reduce size)")

    info "How do you want to make space for Arch?"
    blank
    local space_choice
    space_choice=$(choose_one "${space_opts[0]}" "${space_opts[@]}" "$BACK")
    if [[ "$space_choice" == "$BACK" ]]; then return 1; fi

    # Branch: use different disk
    if [[ "$space_choice" == "Use a different disk"* ]]; then
        local alt_labels=()
        local d dsz dm
        for d in "${other_disks[@]}"; do
            dsz=$(lsblk -dno SIZE  "$d" 2>/dev/null || echo "?")
            dm=$(lsblk  -dno MODEL "$d" 2>/dev/null | cut -c1-28 || echo "")
            alt_labels+=("$(printf '%-14s  %-7s  %s' "$d" "$dsz" "$dm")")
        done
        info "Select disk for Arch root:"
        blank
        local sel_disk
        sel_disk=$(choose_one "${alt_labels[0]}" "${alt_labels[@]}" "$BACK")
        if [[ "$sel_disk" == "$BACK" ]]; then return 1; fi
        DISK_ROOT=$(echo "$sel_disk" | awk '{print $1}')
        DISK_HOME="$DISK_ROOT"
        FREE_GB_AVAIL=$(( $(blockdev --getsize64 "$DISK_ROOT" 2>/dev/null \
            || echo 0) / 1073741824 ))
        ok "Arch will be installed on ${DISK_ROOT} (${FREE_GB_AVAIL} GB)"
        return 0
    fi

    # Build candidate labels for choose_one
    local cand_labels=()
    local c cp rest cf rest2 csz con lbl
    for c in "${candidates[@]}"; do
        cp="${c%%|*}"; rest="${c#*|}"
        cf="${rest%%|*}"; rest2="${rest#*|}"
        csz="${rest2%%|*}"; con="${rest2##*|}"
        lbl="$(printf '%-14s  [%-10s]  %3s GB' "$cp" "$cf" "$csz")"
        if [[ -n "$con" ]]; then lbl+="  — ${con}"; fi
        cand_labels+=("$lbl")
    done

    # Branch: delete
    if [[ "$space_choice" == "Delete"* ]]; then
        blank
        warn "ALL DATA on the chosen partition will be permanently lost."
        blank
        info "Select partition to DELETE:"
        blank
        local rep_choice
        rep_choice=$(choose_one "${cand_labels[0]}" "${cand_labels[@]}" "$BACK")
        if [[ "$rep_choice" == "$BACK" ]]; then return 1; fi
        REPLACE_PART=$(echo "$rep_choice" | awk '{print $1}')
        local rep_gb
        rep_gb=$(( $(blockdev --getsize64 "$REPLACE_PART" 2>/dev/null \
            || echo 0) / 1073741824 ))
        FREE_GB_AVAIL=$(( free_gb + rep_gb ))
        blank
        if [[ "${NO_GUM:-false}" == false ]]; then
            gum style \
                --foreground        "$GUM_C_ERR" \
                --border            thick \
                --border-foreground "$GUM_C_ERR" \
                --padding           "0 2" \
                --width             "$GUM_WIDTH" \
                "PLAN: DELETE ${REPLACE_PART}  (${rep_gb} GB)" "" \
                "ALL DATA WILL BE PERMANENTLY LOST." \
                "Frees ${rep_gb} GB → total available: ${FREE_GB_AVAIL} GB" \
                2>/dev/null || true
        else
            warn "PLAN: DELETE ${REPLACE_PART} (${rep_gb} GB) — ALL DATA LOST"
        fi
        blank
        warn "Deletion happens after installation summary is confirmed."
        blank
        return 0
    fi

    # Branch: shrink
    local shrink_labels=()
    local shrink_map=()
    for c in "${candidates[@]}"; do
        cp="${c%%|*}"; rest="${c#*|}"
        cf="${rest%%|*}"; rest2="${rest#*|}"
        csz="${rest2%%|*}"; con="${rest2##*|}"
        if [[ "$cf" == "xfs"        ]]; then warn "  ${cp} [xfs] cannot be shrunk — skipped."; continue; fi
        if [[ "$cf" == "crypto_LUKS" ]]; then warn "  ${cp} [LUKS] cannot be shrunk — skipped."; continue; fi
        if [[ "$cf" == "swap"        ]]; then continue; fi
        if (( csz < 5              )); then continue; fi
        lbl="$(printf '%-14s  [%-10s]  %3s GB' "$cp" "$cf" "$csz")"
        if [[ -n "$con" ]]; then lbl+="  — ${con}"; fi
        shrink_labels+=("$lbl")
        shrink_map+=("$cp|$cf|$csz")
    done

    if [[ ${#shrink_labels[@]} -eq 0 ]]; then
        warn "No shrinkable partitions available."
        FREE_GB_AVAIL=0
        return 0
    fi

    blank
    info "Select partition to SHRINK:"
    blank
    local shrink_choice
    shrink_choice=$(choose_one "${shrink_labels[0]}" "${shrink_labels[@]}" "$BACK")
    if [[ "$shrink_choice" == "$BACK" ]]; then return 1; fi

    local sel_idx=0 item
    for item in "${shrink_labels[@]}"; do
        if [[ "$item" == "$shrink_choice" ]]; then break; fi
        sel_idx=$(( sel_idx + 1 ))
    done
    local sel="${shrink_map[$sel_idx]}"
    RESIZE_PART="${sel%%|*}"
    local rft="${sel#*|}"; rft="${rft%%|*}"
    local rsize_gb="${sel##*|}"

    # Compute minimum safe size for the chosen FS type
    local min_safe_gb=2
    case "$rft" in
        ntfs)
            local ntfs_min_mb
            ntfs_min_mb=$(ntfsresize --no-action --size 1M "$RESIZE_PART" 2>&1 \
                | grep -i "minimum size" | grep -oE '[0-9]+' | head -1 || echo 0)
            min_safe_gb=$(( (ntfs_min_mb * 12 / 10) / 1024 + 1 ))
            ;;
        ext4)
            e2fsck -fn "$RESIZE_PART" &>/dev/null || true
            local bsz ucnt
            bsz=$(tune2fs -l "$RESIZE_PART" 2>/dev/null | awk '/^Block size/{print $3}')
            ucnt=$(tune2fs -l "$RESIZE_PART" 2>/dev/null | awk '/^Block count/{print $3}')
            min_safe_gb=$(( ((${bsz:-4096} * ${ucnt:-0}) / 1048576 * 12 / 10) / 1024 + 1 ))
            ;;
        btrfs)
            local used_b
            used_b=$(btrfs filesystem usage -b "$RESIZE_PART" 2>/dev/null \
                | awk '/Used:/{print $2}' | head -1 || echo 0)
            min_safe_gb=$(( (${used_b:-0} * 12 / 10) / 1073741824 + 2 ))
            ;;
    esac

    if [[ "${NO_GUM:-false}" == false ]]; then
        gum style \
            --border        rounded \
            --border-foreground "$GUM_C_DIM" \
            --padding       "0 2" \
            --width         "$GUM_WIDTH" \
            "$(_clr "$GUM_C_INFO" "  Partition: ${RESIZE_PART}  [${rft}]  current: ${rsize_gb} GB")" \
            "$(_clr "$GUM_C_WARN" "  Min safe (data + 20% margin): ${min_safe_gb} GB")" \
            2>/dev/null || true
    else
        info "Partition: ${RESIZE_PART}  [${rft}]  current: ${rsize_gb} GB"
        info "Min safe (data + 20% margin): ${min_safe_gb} GB"
    fi
    blank

    local new_gb
    while true; do
        new_gb=$(input_gum \
            "New size in GB  [min: ${min_safe_gb}  max: $(( rsize_gb - 1 ))]" \
            "$(( (min_safe_gb + rsize_gb) / 2 ))")
        if [[ "$new_gb" == "$BACK" ]]; then return 1; fi
        if [[ "$new_gb" =~ ^[0-9]+$ ]] \
           && (( new_gb >= min_safe_gb )) \
           && (( new_gb < rsize_gb )); then
            break
        fi
        warn "Enter ${min_safe_gb}–$(( rsize_gb - 1 ))."
    done

    RESIZE_NEW_GB=$new_gb
    local freed=$(( rsize_gb - new_gb ))
    FREE_GB_AVAIL=$(( free_gb + freed ))
    blank
    ok "Plan: shrink ${RESIZE_PART}  ${rsize_gb} GB → ${new_gb} GB  (frees ${freed} GB)"
    ok "Total available: ${FREE_GB_AVAIL} GB"
    warn "Resize happens after installation summary is confirmed."
    blank
    return 0
}
