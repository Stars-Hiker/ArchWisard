#!/usr/bin/env bash
# =============================================================================
#  gum_style_demo.sh — Illustrates gumMasterPrompt v2.0 rules applied to
#  ArchWizard patterns. NOT a real installer step — demo/reference only.
#
#  Shows: theme block, TTY escape hatch, gum log, gum table, gum spin,
#         gum confirm, NO_GUM fallback, bash 5.x perf rules, safety rules.
# =============================================================================
set -euo pipefail

command -v gum &>/dev/null || NO_GUM=true   # Layer 6: auto-degrade

# ── Catppuccin Mocha theme (Layer 2) ─────────────────────────────────────────
export GUM_CHOOSE_CURSOR_FOREGROUND="#CBA6F7"
export GUM_CHOOSE_SELECTED_FOREGROUND="#CBA6F7"
export GUM_CHOOSE_HEADER_FOREGROUND="#89DCEB"
export GUM_CONFIRM_PROMPT_FOREGROUND="#89B4FA"
export GUM_CONFIRM_SELECTED_BACKGROUND="#CBA6F7"
export GUM_CONFIRM_UNSELECTED_FOREGROUND="#6C7086"
export GUM_INPUT_PROMPT_FOREGROUND="#CBA6F7"
export GUM_INPUT_CURSOR_FOREGROUND="#F38BA8"
export GUM_INPUT_HEADER_FOREGROUND="#89DCEB"
export GUM_SPIN_SPINNER_FOREGROUND="#CBA6F7"
export GUM_LOG_LEVEL_TIME_FOREGROUND="#6C7086"

readonly C_TITLE=141  C_OK=114  C_WARN=215  C_ERR=203
readonly C_INFO=117   C_DIM=242 C_ACCENT=183
readonly WIDTH=72

# ── TTY escape hatch (Layer 1 / T1) ──────────────────────────────────────────
_tty() { [[ ! -t 1 ]] && [[ -w /dev/tty ]] && echo /dev/tty || echo 1; }

# ── Inline 256-colour (Layer 1 / T3 — never embed $(gum style) in --title) ───
_c() { printf '\033[38;5;%sm%s\033[0m' "$1" "$2"; }

# =============================================================================
#  _show_banner — gum style panel, writes to /dev/tty (T1)
# =============================================================================
_show_banner() {
    # inputs: none | side-effects: prints banner to terminal
    gum style \
        --border double \
        --border-foreground "#CBA6F7" \
        --padding "1 4" --width "$WIDTH" \
        --align center \
        "$(_c $C_TITLE "ARCH WIZARD")  $(_c $C_DIM "style demo")" \
        "" \
        "$(_c $C_DIM "Illustrates gumMasterPrompt v2.0 rules")" \
        > "$(_tty)" 2>/dev/null || printf '\n  ARCH WIZARD — style demo\n\n'
}

# =============================================================================
#  _build_disk_rows — pure, no gum, B1/B3/B6 rules
# =============================================================================
_build_disk_rows() {
    # inputs: none | outputs: CSV lines to stdout (DEVICE,SIZE,TYPE,MODEL)
    local dev size rota tran model media
    while IFS= read -r dev; do
        # B6: one lsblk pass per device — all fields at once
        IFS=$'\t' read -r size rota tran model \
            < <(lsblk -dno SIZE,ROTA,TRAN,MODEL "/dev/${dev}" 2>/dev/null \
                || printf '?\t?\t?\t?\n')
        case "$tran" in
            nvme) media="NVMe" ;;
            usb)  media="USB"  ;;
            *)    media=$([[ "$rota" == "0" ]] && echo "SSD" || echo "HDD") ;;
        esac
        # B7: printf over echo for lines with variables
        printf '/dev/%s\t%s\t%s\t%s\n' "$dev" "$size" "$media" "${model:0:22}"
    done < <(lsblk -dno NAME 2>/dev/null | grep -v '^loop\|^sr')
}

# =============================================================================
#  _show_disk_table — gum table (Layer 3)
# =============================================================================
_show_disk_table() {
    # inputs: none | side-effects: renders disk table to terminal
    if [[ "${NO_GUM:-false}" == true ]]; then
        printf '%-14s  %-7s  %-5s  %s\n' DEVICE SIZE TYPE MODEL
        printf '%s\n' "────────────────────────────────────"
        while IFS=$'\t' read -r dev sz tp md; do
            printf '%-14s  %-7s  %-5s  %s\n' "$dev" "$sz" "$tp" "$md"
        done < <(_build_disk_rows)
        return
    fi

    {   printf 'DEVICE\tSIZE\tTYPE\tMODEL\n'
        _build_disk_rows
    } | gum table \
        --border rounded \
        --border.foreground "#CBA6F7" \
        --separator $'\t' \
        --widths 16,7,6,24 \
        --print \
        > "$(_tty)" 2>/dev/null
}

# =============================================================================
#  _pick_disk — gum choose + NO_GUM fallback (Layer 6)
# =============================================================================
_pick_disk() {
    # inputs: none | outputs: selected /dev/... path on stdout
    local -a labels=()
    local dev size media model
    while IFS=$'\t' read -r dev size media model; do
        labels+=("$(printf '%-14s  %-7s  %-5s  %s' "$dev" "$size" "$media" "$model")")
    done < <(_build_disk_rows)

    if [[ ${#labels[@]} -eq 0 ]]; then
        gum log -l error "No block devices found." > "$(_tty)" 2>/dev/null
        return 1
    fi

    if [[ "${NO_GUM:-false}" == true ]]; then   # Layer 6 fallback
        local -i i=1
        for lbl in "${labels[@]}"; do printf '  %d) %s\n' "$i" "$lbl" >&2; (( i++ )); done
        local n; read -rp "Choice [1-${#labels[@]}]: " n </dev/tty
        echo "${labels[$(( n - 1 ))]}" | awk '{print $1}'
        return
    fi

    # T4: guard --selected to avoid empty-string crash
    local default="${labels[0]}"
    local choice
    choice=$(gum choose \
        --header "  Select disk for root ( / )" \
        --height 10 \
        --selected "$default" \
        "${labels[@]}" \
        </dev/tty 2>/dev/tty) || true

    [[ -z "$choice" ]] && return 1
    awk '{print $1}' <<< "$choice"   # B1: <<< not echo | awk
}

# =============================================================================
#  _confirm_erase — gum confirm, S8 destructive guard (Layer 0 / S8)
# =============================================================================
_confirm_erase() {
    # inputs: $1=disk | outputs: exit code 0=yes 1=no
    local disk="$1"
    local -i size_gb=$(( $(blockdev --getsize64 "$disk" 2>/dev/null || echo 0) / 1073741824 ))

    # Side-by-side warning panel (V1: max info per screen)
    local LEFT RIGHT
    LEFT=$(gum style --border rounded --width 34 --border-foreground "#F38BA8" \
        "$(_c $C_ERR  "  ⚠  DESTRUCTIVE")" \
        "" \
        "$(_c $C_WARN "  Disk : $disk")" \
        "$(_c $C_WARN "  Size : ${size_gb} GB")" \
        "$(_c $C_ERR  "  ALL DATA WILL BE LOST")" 2>/dev/null)
    RIGHT=$(gum style --border rounded --width 34 --border-foreground "#6C7086" \
        "$(_c $C_DIM  "  This is your last safe")" \
        "$(_c $C_DIM  "  exit before any writes.")" \
        "" \
        "$(_c $C_INFO "  Ctrl-C to abort safely")" 2>/dev/null)
    gum join --horizontal "$LEFT" "$RIGHT" > "$(_tty)" 2>/dev/null
    echo

    if [[ "${NO_GUM:-false}" == true ]]; then
        local ans
        printf ' ⚠  Erase %s? [y/N]: ' "$disk" >/dev/tty
        read -r ans </dev/tty
        [[ "${ans,,}" == "y" ]]; return
    fi

    # S3: if/then/fi — never [[ ]] && cmd under set -e
    if gum confirm "Erase $disk  (${size_gb} GB) — ALL DATA LOST?" \
            </dev/tty 2>/dev/tty; then   # ⚠ DESTRUCTIVE
        return 0
    fi
    return 1
}

# =============================================================================
#  _probe_disks — gum spin wrapper, B1/B3 rules (Layer 3 / Layer 4)
# =============================================================================
_probe_disks() {
    # inputs: none | side-effects: populates DISK_ROWS[] global
    if [[ "${NO_GUM:-false}" == true ]]; then
        gum log -l info "Scanning block devices…" > "$(_tty)" 2>/dev/null \
            || printf ' ℹ  Scanning…\n'
        mapfile -t DISK_ROWS < <(_build_disk_rows)   # B3: mapfile, no subshell games
        return
    fi

    gum spin \
        --spinner globe \
        --title " Scanning block devices…" \
        -- bash -c 'sleep 0.4' \
        </dev/tty 2>/dev/tty

    mapfile -t DISK_ROWS < <(_build_disk_rows)   # B3
    gum log -l info "Found ${#DISK_ROWS[@]} disk(s)" > "$(_tty)" 2>/dev/tty || true
}

# =============================================================================
#  _step_header — gum format Lip Gloss template (Layer 3)
# =============================================================================
_step_header() {
    # inputs: $1=step_n $2=total $3=title | side-effects: prints header
    local -i n=$1 total=$2
    local title="$3"
    if [[ "${NO_GUM:-false}" == true ]]; then
        printf '\n\033[1;35m══  Step %d/%d — %s  ══\033[0m\n\n' "$n" "$total" "$title"
        return
    fi
    # gum format -t template leaks OSC sequences via /dev/tty redirect — use gum style
    gum style \
        --border normal \
        --border-foreground "#CBA6F7" \
        --padding "0 1" --width "$WIDTH" \
        "$(_c $C_ACCENT "  ◆  Step ${n}/${total}")  $(_c $C_DIM "$title")" \
        > "$(_tty)" 2>/dev/null \
        || printf '\n  Step %d/%d — %s\n\n' "$n" "$total" "$title"
    echo
}

# =============================================================================
#  main
# =============================================================================
main() {
    # inputs: "$@" | side-effects: drives demo flow
    local rc=0
    _cleanup() { local rc=$?; gum log -l warn "Interrupted (rc=$rc)" > "$(_tty)" 2>/dev/null; exit "$rc"; }
    trap '_cleanup'           INT TERM   # S2
    trap 'gum log -l error "line $LINENO: $BASH_COMMAND" > "$(_tty)" 2>/dev/null; exit 1' ERR

    _show_banner
    echo

    _step_header 1 2 "Disk discovery"
    _probe_disks

    _show_disk_table
    echo

    _step_header 2 2 "Disk selection"
    local disk
    disk=$(_pick_disk) || { gum log -l error "No disk selected." > "$(_tty)" 2>/dev/null; exit 1; }
    gum log -l info "Selected: $disk" > "$(_tty)" 2>/dev/null || printf ' ✔  Selected: %s\n' "$disk"
    echo

    # S3 + S8
    if _confirm_erase "$disk"; then
        gum log -l warn "Would now erase $disk … (demo — no writes)" > "$(_tty)" 2>/dev/null \
            || printf ' ⚠  Would erase %s (demo — no writes)\n' "$disk"
    else
        gum log -l info "Aborted — no changes made." > "$(_tty)" 2>/dev/null \
            || printf ' ℹ  Aborted.\n'
    fi
}

main "$@"
