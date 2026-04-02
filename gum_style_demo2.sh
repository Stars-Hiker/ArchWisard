#!/usr/bin/env bash
# =============================================================================
#  gum_style_demo.sh — Illustrates gumMasterPrompt v2.0 rules applied to
#  ArchWizard patterns. NOT a real installer step — demo/reference only.
#
#  Shows: theme block, TTY escape hatch, gum style (OSC-safe), gum table,
#         gum spin, gum confirm, NO_GUM fallback, bash 5.x perf rules.
# =============================================================================
set -euo pipefail

command -v gum &>/dev/null || NO_GUM=true   # Layer 6: auto-degrade

# ── Catppuccin Mocha theme (Layer 2) ─────────────────────────────────────────
# Hex colours for env-var driven gum choose/confirm/input/spin defaults
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

# 256-colour integers for gum style --foreground / _c() helper.
# Numeric 256-colour avoids the lipgloss HasDarkBackground() OSC query
# that hex adaptive colours trigger — critical when stdout is piped.
readonly C_TITLE=141  C_OK=114  C_WARN=215  C_ERR=203
readonly C_INFO=117   C_DIM=242 C_ACCENT=183
readonly WIDTH=72

# ── TTY escape hatch (Layer 1 / T1) ──────────────────────────────────────────
_tty() { [[ ! -t 1 ]] && [[ -w /dev/tty ]] && echo /dev/tty || echo 1; }

# ── Inline 256-colour (T3 — never embed $(gum style) inside --title/--header) ─
_c() { printf '\033[38;5;%sm%s\033[0m' "$1" "$2"; }

# ── OSC-safe display helpers (match ui.sh pattern; --foreground + 256-int) ───
# gum style --foreground <256-int> does NOT call HasDarkBackground().
# gum log DOES call it (adaptive level colours) — never use gum log here.
_ok()   { gum style --foreground $C_OK   " ✔  $*" > "$(_tty)" 2>/dev/null || printf ' ✔  %s\n' "$*"; }
_info() { gum style --foreground $C_INFO " ℹ  $*" > "$(_tty)" 2>/dev/null || printf ' ℹ  %s\n' "$*"; }
_warn() { gum style --foreground $C_WARN " ⚠  $*" > "$(_tty)" 2>/dev/null || printf ' ⚠  %s\n' "$*"; }

# =============================================================================
#  _show_banner
# =============================================================================
_show_banner() {
    # inputs: none | side-effects: prints banner to terminal
    if [[ "${NO_GUM:-false}" == true ]]; then
        printf '\n\033[1;35m  ARCH WIZARD — style demo\033[0m\n\n'; return
    fi
    gum style \
        --border double \
        --border-foreground $C_TITLE \
        --padding "1 4" --width "$WIDTH" --align center \
        "$(_c $C_TITLE "ARCH WIZARD")  $(_c $C_DIM "style demo")" "" \
        "$(_c $C_DIM "Illustrates gumMasterPrompt v2.0 rules")" \
        > "$(_tty)" 2>/dev/null || printf '\n  ARCH WIZARD — style demo\n\n'
}

# =============================================================================
#  _step_header
# =============================================================================
_step_header() {
    # inputs: $1=step_n $2=total $3=title | side-effects: prints step header
    local -i n=$1 total=$2; local title="$3"
    echo
    if [[ "${NO_GUM:-false}" == true ]]; then
        printf '\033[1;35m══  Step %d/%d — %s  ══\033[0m\n\n' "$n" "$total" "$title"; return
    fi
    gum style \
        --border normal --border-foreground $C_ACCENT \
        --padding "0 1" --width "$WIDTH" \
        "$(_c $C_ACCENT "  ◆  Step ${n}/${total}")  $(_c $C_DIM "$title")" \
        > "$(_tty)" 2>/dev/null || printf '  ◆  Step %d/%d — %s\n' "$n" "$total" "$title"
    echo
}

# =============================================================================
#  _build_disk_rows  — pure, no gum
#  Separate lsblk calls per field: lsblk -dno with multiple columns outputs
#  space-padded alignment, making IFS-read unreliable when model has spaces.
#  Uses | as CSV separator: locale decimal comma in SIZE (e.g. "119,2G" in
#  French locale) would break comma-based gum table parsing.
# =============================================================================
_build_disk_rows() {
    # inputs: none | outputs: pipe-separated rows to stdout (DEVICE|SIZE|TYPE|MODEL)
    local dev size rota tran model media
    while IFS= read -r dev; do
        size=$(lsblk  -dno SIZE  "/dev/${dev}" 2>/dev/null || echo "?")
        rota=$(lsblk  -dno ROTA  "/dev/${dev}" 2>/dev/null || echo "1")
        tran=$(lsblk  -dno TRAN  "/dev/${dev}" 2>/dev/null || echo "")
        model=$(lsblk -dno MODEL "/dev/${dev}" 2>/dev/null | cut -c1-20 || echo "")
        case "$tran" in
            nvme) media="NVMe" ;;
            usb)  media="USB"  ;;
            *)    [[ "$rota" == "0" ]] && media="SSD" || media="HDD" ;;
        esac
        printf '/dev/%s|%s|%s|%s\n' "$dev" "$size" "$media" "$model"
    done < <(lsblk -dno NAME 2>/dev/null | grep -v '^loop\|^sr')
}

# =============================================================================
#  _show_disk_table  — gum table with pipe separator (Layer 3)
# =============================================================================
_show_disk_table() {
    # inputs: none | side-effects: renders disk table to terminal
    if [[ "${NO_GUM:-false}" == true ]]; then
        printf '%-16s  %-8s  %-5s  %s\n' DEVICE SIZE TYPE MODEL
        printf '%s\n' "────────────────────────────────────────"
        while IFS='|' read -r dev sz tp md; do
            printf '%-16s  %-8s  %-5s  %s\n' "$dev" "$sz" "$tp" "$md"
        done < <(_build_disk_rows)
        return
    fi
    {   printf 'DEVICE|SIZE|TYPE|MODEL\n'
        _build_disk_rows
    } | gum table \
        --separator '|' \
        --border rounded \
        --border.foreground $C_ACCENT \
        --widths 16,8,6,20 \
        --print \
        > "$(_tty)" 2>/dev/null
}

# =============================================================================
#  _probe_disks  — gum spin wrapper (Layer 3 / B3)
# =============================================================================
_probe_disks() {
    # inputs: none | sets: DISK_ROWS[] global
    if [[ "${NO_GUM:-false}" == true ]]; then
        _info "Scanning block devices…"
        mapfile -t DISK_ROWS < <(_build_disk_rows)
        return
    fi
    gum spin --spinner globe --title " Scanning block devices…" \
        -- bash -c 'sleep 0.4' \
        </dev/tty 2>/dev/tty
    mapfile -t DISK_ROWS < <(_build_disk_rows)   # B3: mapfile, no subshell
    _ok "Found ${#DISK_ROWS[@]} disk(s)"
}

# =============================================================================
#  _pick_disk  — gum choose + NO_GUM fallback (Layer 6 / T2 / T4)
# =============================================================================
_pick_disk() {
    # inputs: none | outputs: selected /dev/... path on stdout
    local -a labels=()
    local dev size media model
    while IFS='|' read -r dev size media model; do
        labels+=("$(printf '%-16s  %-8s  %-5s  %s' "$dev" "$size" "$media" "$model")")
    done < <(_build_disk_rows)

    if [[ ${#labels[@]} -eq 0 ]]; then
        _warn "No block devices found."; return 1
    fi

    if [[ "${NO_GUM:-false}" == true ]]; then
        local -i i=1
        for lbl in "${labels[@]}"; do printf '  %d) %s\n' "$i" "$lbl" >&2; (( i++ )); done
        local n; read -rp "Choice [1-${#labels[@]}]: " n </dev/tty
        awk '{print $1}' <<< "${labels[$(( n - 1 ))]}"; return
    fi

    local default="${labels[0]}"
    local choice
    # T4: --selected guard (empty string crashes gum choose)
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
#  _confirm_erase  — gum confirm, S3 + S8 (Layer 0)
#  Uses a single gum style panel instead of gum join: gum join triggers the
#  lipgloss HasDarkBackground() OSC 11 query whose response leaks to screen.
# =============================================================================
_confirm_erase() {
    # inputs: $1=disk | outputs: exit code 0=yes 1=no
    local disk="$1"
    local size; size=$(lsblk -dno SIZE "$disk" 2>/dev/null || echo "?")

    echo
    if [[ "${NO_GUM:-false}" == false ]]; then
        gum style \
            --border rounded --border-foreground $C_ERR \
            --padding "0 2" --width "$WIDTH" \
            "$(_c $C_ERR  "  ⚠  DESTRUCTIVE ACTION")" "" \
            "$(_c $C_WARN "  Disk : $disk  ($size)")" \
            "$(_c $C_ERR  "  ALL DATA WILL BE LOST")" "" \
            "$(_c $C_DIM  "  This is your last safe exit — Ctrl-C to abort")" \
            > "$(_tty)" 2>/dev/null
        echo
    else
        _warn "DESTRUCTIVE: erase $disk ($size) — ALL DATA WILL BE LOST"
    fi

    if [[ "${NO_GUM:-false}" == true ]]; then
        local ans
        printf ' ⚠  Erase %s? [y/N]: ' "$disk" >/dev/tty
        read -r ans </dev/tty
        [[ "${ans,,}" == "y" ]]; return
    fi

    # S3: if/then/fi — never [[ ]] && cmd under set -e
    if gum confirm "Erase $disk ($size) — ALL DATA LOST?" \
            </dev/tty 2>/dev/tty; then   # ⚠ DESTRUCTIVE
        return 0
    fi
    return 1
}

# =============================================================================
#  main
# =============================================================================
main() {
    # inputs: "$@" | side-effects: drives demo flow
    _cleanup() { local rc=$?; _warn "Interrupted (rc=$rc)"; exit "$rc"; }
    trap '_cleanup' INT TERM   # S2
    trap '_warn "line $LINENO: $BASH_COMMAND"; exit 1' ERR

    _show_banner

    _step_header 1 2 "Disk discovery"
    _probe_disks
    _show_disk_table

    _step_header 2 2 "Disk selection"
    local disk
    disk=$(_pick_disk) || { _warn "No disk selected."; exit 1; }
    _ok "Selected: $disk"

    # S3 + S8
    if _confirm_erase "$disk"; then
        _warn "Would now erase $disk … (demo — no writes made)"
    else
        _info "Aborted — no changes made."
    fi
}

main "$@"
