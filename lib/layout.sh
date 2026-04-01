#!/usr/bin/env bash
# =============================================================================
#  lib/layout.sh — Step 4: partition layout wizard
#
#  LUKS is handled in Step 3 (storage.sh) — not here.
#  This step only handles: sizes, filesystems, swap, EFI size.
#
#  Pure helpers:
#    _suggest_root_gb()    — heuristic root size based on available space
#    _rec_swap_gb()        — recommended swap based on RAM
#
#  UI functions:
#    partition_wizard()    — main Step 4 wizard
#    _layout_preview()     — display planned layout box (also called by state.sh summary)
#    _ask_gb()             — validated GB input helper
# =============================================================================

# _suggest_root_gb AVAIL_GB → echoes suggested root size
function _suggest_root_gb() {
    # inputs: avail_gb / outputs: integer to stdout
    local avail=$1
    if   (( avail > 100 )); then echo 60
    elif (( avail > 60  )); then echo 40
    elif (( avail > 30  )); then echo 25
    elif (( avail > 15  )); then echo 15
    else echo $(( avail * 6 / 10 )); fi
}

# _rec_swap_gb → echoes recommended swap GB based on /proc/meminfo
function _rec_swap_gb() {
    # inputs: /proc/meminfo / outputs: integer to stdout
    local ram_kb ram_gb
    ram_kb=$(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    ram_gb=$(( ram_kb / 1048576 ))
    if   (( ram_gb >= 32 )); then echo 0
    elif (( ram_gb >= 16 )); then echo 4
    elif (( ram_gb >= 8  )); then echo 8
    else echo $(( ram_gb * 2 )); fi
}

# _ask_gb PROMPT DEFAULT MAX [MIN] → sets GB_RESULT global
GB_RESULT=""
function _ask_gb() {
    # inputs: prompt default max [min] / side-effects: GB_RESULT global
    local prompt="$1" default="$2" max="$3" min="${4:-1}"
    local val
    while true; do
        val=$(input_gum "${prompt}  [${min}–${max} GB]" "$default")
        if [[ "$val" == "$BACK" ]]; then GB_RESULT="$BACK"; return 0; fi
        if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= min && val <= max )); then
            GB_RESULT="$val"
            return 0
        fi
        warn "Enter a whole number between ${min} and ${max}."
    done
}

# -----------------------------------------------------------------------------
#  _layout_preview — used here and in show_summary
# -----------------------------------------------------------------------------

function _layout_preview() {
    # inputs: all layout globals / side-effects: prints layout box
    local lines=()

    if [[ "$REUSE_EFI" == true && -n "$EFI_PART" ]]; then
        lines+=("$(_clr "$GUM_C_INFO"   "  EFI       reused  (${EFI_PART})")")
    elif [[ "$FIRMWARE_MODE" == "uefi" ]]; then
        lines+=("$(_clr "$GUM_C_INFO"   "  EFI       ${EFI_SIZE_MB} MB   FAT32")")
    fi

    if [[ "$SWAP_TYPE" == "partition" ]]; then
        lines+=("$(_clr "$GUM_C_WARN"   "  swap      ${SWAP_SIZE} GB    linux-swap")")
    fi

    local root_disp="${ROOT_SIZE} GB"
    if [[ "$ROOT_SIZE" == "rest" ]]; then root_disp="remaining"; fi
    local stack_tag="${STORAGE_STACK:-plain}"
    lines+=("$(_clr "$GUM_C_OK"         "  / (root)  ${root_disp}   ${ROOT_FS}  [${stack_tag}]")")

    if [[ "${SEP_HOME:-false}" == true && "$DISK_HOME" == "$DISK_ROOT" ]]; then
        local home_disp="${HOME_SIZE} GB"
        if [[ "$HOME_SIZE" == "rest" ]]; then home_disp="remaining"; fi
        lines+=("$(_clr "$GUM_C_ACCENT" "  /home     ${home_disp}   ${HOME_FS}")")
    fi

    if [[ "${NO_GUM:-false}" == false ]]; then
        gum style \
            --border        rounded \
            --border-foreground "$GUM_C_TITLE" \
            --padding       "0 2" \
            --width         "$GUM_WIDTH" \
            "$(_clr "$GUM_C_TITLE" "  Planned layout — ${DISK_ROOT}")" \
            "" "${lines[@]}" 2>/dev/null || true

        if [[ "${SEP_HOME:-false}" == true && "$DISK_HOME" != "$DISK_ROOT" ]]; then
            blank
            local home_disp2="${HOME_SIZE} GB"
            if [[ "$HOME_SIZE" == "rest" ]]; then home_disp2="full disk"; fi
            gum style \
                --border        rounded \
                --border-foreground "$GUM_C_ACCENT" \
                --padding       "0 2" \
                --width         "$GUM_WIDTH" \
                "$(_clr "$GUM_C_ACCENT" "  /home layout — ${DISK_HOME}")" \
                "" \
                "$(_clr "$GUM_C_ACCENT" "  /home     ${home_disp2}   ${HOME_FS}")" \
                2>/dev/null || true
        fi
    else
        info "Planned layout — ${DISK_ROOT}:"
        local l; for l in "${lines[@]}"; do printf '  %s\n' "$l"; done
        if [[ "${SEP_HOME:-false}" == true && "$DISK_HOME" != "$DISK_ROOT" ]]; then
            info "/home layout — ${DISK_HOME}: ${HOME_SIZE} GB  ${HOME_FS}"
        fi
    fi
}

# -----------------------------------------------------------------------------
#  partition_wizard — Step 4 UI function
# -----------------------------------------------------------------------------

function partition_wizard() {
    # inputs: DISK_ROOT DISK_HOME DUAL_BOOT FREE_GB_AVAIL FIRMWARE_MODE STORAGE_STACK
    # side-effects: EFI_SIZE_MB ROOT_SIZE HOME_SIZE SEP_HOME HOME_FS SWAP_TYPE SWAP_SIZE

    local disk_bytes disk_gb avail_gb
    disk_bytes=$(blockdev --getsize64 "$DISK_ROOT" 2>/dev/null || echo 0)
    disk_gb=$(( disk_bytes / 1073741824 ))

    if [[ "$DUAL_BOOT" == true ]]; then
        if [[ "${FREE_GB_AVAIL:-0}" -gt 0 ]]; then
            avail_gb=$FREE_GB_AVAIL
        else
            avail_gb=$(( disk_gb / 2 ))
            warn "Space budget unknown — using conservative estimate: ${avail_gb} GB"
        fi
    else
        avail_gb=$disk_gb
    fi

    # ── EFI partition size ────────────────────────────────────────────────────
    section "EFI partition"

    if [[ "$FIRMWARE_MODE" == "bios" ]]; then
        info "BIOS/Legacy mode — no EFI partition needed."
    elif [[ "$DUAL_BOOT" == true ]]; then
        # Try to locate an ESP if we don't already have one from discover_disks
        if [[ "$REUSE_EFI" == false || -z "$EFI_PART" ]]; then
            local _esp_found=""
            local p _ept _esz
            while IFS= read -r p; do
                if [[ -z "$p" ]]; then continue; fi
                _ept=$(lsblk -no PARTTYPE "$p" 2>/dev/null || echo "")
                _esz=$(( $(blockdev --getsize64 "$p" 2>/dev/null || echo 0) / 1048576 ))
                if [[ "$_ept" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] \
                   || [[ "$(blkid -s TYPE -o value "$p" 2>/dev/null)" == "vfat" \
                         && $_esz -le 1024 ]]; then
                    _esp_found="$p"; break
                fi
            done < <(lsblk -ln -o PATH "$DISK_ROOT" 2>/dev/null | tail -n +2)

            if [[ -n "$_esp_found" ]]; then
                EFI_PART="$_esp_found"
                REUSE_EFI=true
                ok "Found ESP: ${EFI_PART} — reusing"
            else
                warn "No ESP found — will create 512 MB EFI partition."
                EFI_SIZE_MB=512
                REUSE_EFI=false
            fi
        else
            local _efsz
            _efsz=$(lsblk -dno SIZE "$EFI_PART" 2>/dev/null || echo "?")
            ok "Reusing existing ESP: ${EFI_PART}  (${_efsz})"
        fi
        info "Available for Arch: ${avail_gb} GB"
    else
        # Fresh install — ask EFI size
        local efi_input
        efi_input=$(input_gum "EFI partition size in MB  (256–2048, recommended: 512)" "512")
        if [[ "$efi_input" == "$BACK" ]]; then return 1; fi
        if [[ "$efi_input" =~ ^[0-9]+$ ]] \
           && (( efi_input >= 256 && efi_input <= 2048 )); then
            EFI_SIZE_MB=$efi_input
        else
            warn "Invalid — using 512 MB."
            EFI_SIZE_MB=512
        fi
        ok "EFI: ${EFI_SIZE_MB} MB"
        avail_gb=$(( avail_gb - 1 ))
    fi
    blank

    # ── Layout choice ─────────────────────────────────────────────────────────
    section "Partition layout"

    if [[ "${NO_GUM:-false}" == false ]]; then
        gum style \
            --border        rounded \
            --border-foreground "$GUM_C_DIM" \
            --padding       "0 2" \
            --width         "$GUM_WIDTH" \
            "$(_clr "$GUM_C_INFO" "  Disk:         ${DISK_ROOT}  (${disk_gb} GB)")" \
            "$(_clr "$GUM_C_OK"   "  Available:    ${avail_gb} GB")" \
            "$(_clr "$GUM_C_DIM"  "  Stack:        ${STORAGE_STACK}")" \
            2>/dev/null || true
    else
        info "Disk: ${DISK_ROOT}  (${disk_gb} GB)  available: ${avail_gb} GB"
    fi
    blank

    local layout_choice
    if [[ "$DISK_HOME" != "$DISK_ROOT" ]]; then
        SEP_HOME=true
        layout_choice="split_disk"
        info "Separate home disk: ${DISK_HOME}"
    else
        local layout_sel
        layout_sel=$(choose_one \
            "/ + /home  — separate home partition  (recommended)" \
            "/           — root takes all space  (simple / small disk)" \
            "/ + /home  — separate home partition  (recommended)" \
            "/ + /home + swap partition  — explicit swap" \
            "$BACK")
        if [[ "$layout_sel" == "$BACK" ]]; then return 1; fi
        case "$layout_sel" in
            "/ + /home + "*)  layout_choice="root_home_swap" ;;
            "/ + /home"*)     layout_choice="root_home"      ;;
            *)                layout_choice="root_only"      ;;
        esac
    fi
    blank

    local root_max=$(( avail_gb - 1 ))
    if (( root_max < 1 )); then root_max=1; fi

    case "$layout_choice" in

        root_only)
            if confirm_gum "Use all ${avail_gb} GB for / ?"; then
                ROOT_SIZE="rest"
            else
                _ask_gb "Root (/) size in GB" "$avail_gb" "$root_max" 1
                if [[ "$GB_RESULT" == "$BACK" ]]; then return 1; fi
                ROOT_SIZE="$GB_RESULT"
            fi
            ;;

        root_home|root_home_swap)
            local suggested
            suggested=$(_suggest_root_gb "$avail_gb")
            local home_preview=$(( avail_gb - suggested ))

            if [[ "${NO_GUM:-false}" == false ]]; then
                gum style \
                    --border        rounded \
                    --border-foreground "$GUM_C_DIM" \
                    --padding       "0 2" \
                    --width         "$GUM_WIDTH" \
                    "$(_clr "$GUM_C_INFO" "  Available:       ${avail_gb} GB")" \
                    "$(_clr "$GUM_C_INFO" "  Suggested root:  ${suggested} GB")" \
                    "$(_clr "$GUM_C_DIM"  "  Remaining → /home: ~${home_preview} GB")" \
                    2>/dev/null || true
            else
                info "Available: ${avail_gb} GB  |  Suggested root: ${suggested} GB"
                info "Remaining for /home: ~${home_preview} GB"
            fi
            blank

            local home_budget=$(( avail_gb - 4 ))
            if (( home_budget < 1 )); then home_budget=1; fi
            _ask_gb "Root (/) size in GB" "$suggested" "$home_budget" 5
            if [[ "$GB_RESULT" == "$BACK" ]]; then return 1; fi
            ROOT_SIZE="$GB_RESULT"

            local remaining=$(( avail_gb - ROOT_SIZE ))
            blank
            ok "Root: ${ROOT_SIZE} GB  ·  Remaining for /home: ${remaining} GB"
            blank
            SEP_HOME=true

            if confirm_gum "Give all remaining ${remaining} GB to /home?"; then
                HOME_SIZE="rest"
            else
                _ask_gb "Home (/home) size in GB" "$remaining" "$remaining" 1
                if [[ "$GB_RESULT" == "$BACK" ]]; then return 1; fi
                HOME_SIZE="$GB_RESULT"
            fi
            ;;

        split_disk)
            local root_default
            if   (( avail_gb >= 80 )); then root_default=60
            elif (( avail_gb >= 40 )); then root_default=40
            else root_default=20; fi

            _ask_gb "Root (/) size in GB  [on ${DISK_ROOT}]" \
                "$root_default" "$root_max" 5
            if [[ "$GB_RESULT" == "$BACK" ]]; then return 1; fi
            ROOT_SIZE="$GB_RESULT"

            local home_bytes home_gb
            home_bytes=$(blockdev --getsize64 "$DISK_HOME" 2>/dev/null || echo 0)
            home_gb=$(( home_bytes / 1073741824 ))
            blank
            info "Home disk ${DISK_HOME}: ${home_gb} GB available"

            if confirm_gum "Give all ${home_gb} GB to /home?"; then
                HOME_SIZE="rest"
            else
                _ask_gb "Home (/home) size in GB  [on ${DISK_HOME}]" \
                    "$home_gb" "$home_gb" 1
                if [[ "$GB_RESULT" == "$BACK" ]]; then return 1; fi
                HOME_SIZE="$GB_RESULT"
            fi
            ;;
    esac
    blank
    ok "Sizes: root=${ROOT_SIZE} GB${SEP_HOME:+  |  home=${HOME_SIZE} GB}"

    # ── Home filesystem (if separate) ─────────────────────────────────────────
    HOME_FS="$ROOT_FS"
    if [[ "$SEP_HOME" == true ]]; then
        blank
        info "Home filesystem (default: same as root — ${ROOT_FS}):"
        blank
        local hfs_sel
        hfs_sel=$(choose_one \
            "same as root  (${ROOT_FS})" \
            "same as root  (${ROOT_FS})" \
            "btrfs" "ext4" "xfs" "f2fs" \
            "$BACK")
        if [[ "$hfs_sel" == "$BACK" ]]; then return 1; fi
        case "${hfs_sel%% *}" in
            btrfs) HOME_FS="btrfs" ;;
            ext4)  HOME_FS="ext4"  ;;
            xfs)   HOME_FS="xfs"   ;;
            f2fs)  HOME_FS="f2fs"  ;;
            *)     HOME_FS="$ROOT_FS" ;;
        esac
        ok "Home FS: ${HOME_FS}"
    fi

    # ── Swap ──────────────────────────────────────────────────────────────────
    section "Swap"

    local ram_kb ram_gb rec_swap
    ram_kb=$(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    ram_gb=$(( ram_kb / 1048576 ))
    rec_swap=$(_rec_swap_gb)

    if [[ "${NO_GUM:-false}" == false ]]; then
        gum style \
            --border        rounded \
            --border-foreground "$GUM_C_DIM" \
            --padding       "0 2" \
            --width         "$GUM_WIDTH" \
            "$(_clr "$GUM_C_INFO" "  Detected RAM:     ${ram_gb} GB")" \
            "$(_clr "$GUM_C_INFO" "  Recommended swap: ${rec_swap} GB")" \
            2>/dev/null || true
    else
        info "RAM: ${ram_gb} GB  |  Recommended swap: ${rec_swap} GB"
    fi
    blank

    local swap_sel
    swap_sel=$(choose_one \
        "zram           — compressed RAM swap, fastest  (recommended)" \
        "zram           — compressed RAM swap, fastest  (recommended)" \
        "Swap file      — on-disk file, supports hibernation" \
        "Swap partition — dedicated partition" \
        "None           — no swap  (safe with 32 GB+ RAM)" \
        "$BACK")
    if [[ "$swap_sel" == "$BACK" ]]; then return 1; fi

    local sw_default="${rec_swap:-8}"
    if (( sw_default < 1 )); then sw_default=4; fi

    case "${swap_sel%% *}" in
        "Swap file"*)
            SWAP_TYPE="file"
            local sf_max=$(( disk_gb / 4 ))
            if (( sf_max < 1 )); then sf_max=1; fi
            _ask_gb "Swap file size in GB" "$sw_default" "$sf_max" 1
            if [[ "$GB_RESULT" == "$BACK" ]]; then return 1; fi
            SWAP_SIZE="$GB_RESULT" ;;
        "Swap partition"*)
            SWAP_TYPE="partition"
            local sp_max=$(( disk_gb / 4 ))
            if (( sp_max < 1 )); then sp_max=1; fi
            _ask_gb "Swap partition size in GB" "$sw_default" "$sp_max" 1
            if [[ "$GB_RESULT" == "$BACK" ]]; then return 1; fi
            SWAP_SIZE="$GB_RESULT" ;;
        None*)
            SWAP_TYPE="none"
            SWAP_SIZE="" ;;
        *)
            SWAP_TYPE="zram"
            SWAP_SIZE="8" ;;
    esac
    ok "Swap: ${SWAP_TYPE}${SWAP_SIZE:+  (${SWAP_SIZE} GB)}"

    # ── Final preview ─────────────────────────────────────────────────────────
    blank
    _layout_preview
    blank
    return 0
}
