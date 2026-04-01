#!/usr/bin/env bash
# =============================================================================
#  lib/ui.sh — All UI wrappers + gum theme constants
#  Architecture rule: ZERO logic here. Pure presentation.
#  NO_GUM=true  → every function falls back to plain read/printf.
#  Gum failures → every gum call has a silent || fallback.
# =============================================================================

# -----------------------------------------------------------------------------
#  Theme constants — readonly; never hardcode numbers elsewhere
# -----------------------------------------------------------------------------
readonly GUM_C_TITLE=99
readonly GUM_C_OK=46
readonly GUM_C_WARN=214
readonly GUM_C_ERR=196
readonly GUM_C_INFO=51
readonly GUM_C_DIM=242
readonly GUM_C_ACCENT=141
readonly GUM_WIDTH=70

# _clr COLOR "text"
# Inline ANSI 256-colour. Safe inside gum --title/--header strings;
# nested $(gum style) crashes when stdout is piped — this never does.
function _clr() {
    # inputs: color_number text / outputs: ANSI-wrapped string
    printf '\033[38;5;%sm%s\033[0m' "$1" "$2"
}

# -----------------------------------------------------------------------------
#  Internal dispatcher — shared logic for ok/warn/info/error
# -----------------------------------------------------------------------------
function _ui_msg() {
    # inputs: color icon message / outputs: styled line to stdout (or stderr)
    local color="$1" icon="$2"; shift 2
    if [[ "${NO_GUM:-false}" == true ]]; then
        printf '%s %s\n' "$icon" "$*"
        return 0
    fi
    gum style --foreground "$color" "${icon} $*" 2>/dev/null \
        || printf '%s %s\n' "$icon" "$*"
}

# -----------------------------------------------------------------------------
#  Status printers
# -----------------------------------------------------------------------------
function log() {
    # inputs: message / side-effects: stdout + LOG_FILE
    local m="[$(date '+%H:%M:%S')] $*"
    echo "$m"
    echo "$m" >> "${LOG_FILE:-/tmp/archwizard.log}"
}

function ok()    { _ui_msg "$GUM_C_OK"   " ✔ " "$@"; }
function warn()  { _ui_msg "$GUM_C_WARN" " ⚠ " "$@"; }
function info()  { _ui_msg "$GUM_C_INFO" " ℹ " "$@"; }
function error() { _ui_msg "$GUM_C_ERR"  " ✗ " "$@" >&2; }
function blank() { echo ""; }

function section() {
    # inputs: title / outputs: section header
    echo ""
    if [[ "${NO_GUM:-false}" == true ]]; then
        printf '\033[1;35m══  %s  ══\033[0m\n\n' "$*"
        return 0
    fi
    gum style \
        --foreground        "$GUM_C_TITLE" \
        --bold \
        --border-foreground "$GUM_C_TITLE" \
        --border            normal \
        --padding           "0 1" \
        --width             "$GUM_WIDTH" \
        "  ◆  $*" 2>/dev/null \
        || printf '\033[1;35m══  %s  ══\033[0m\n' "$*"
    echo ""
}

function die() {
    # inputs: message / side-effects: fatal box to stderr, exits 1
    # Always goes to stderr so the tee pipe on stdout doesn't interfere.
    echo "" >&2
    if [[ "${NO_GUM:-false}" == true ]]; then
        printf '\033[1;31m[FATAL]\033[0m %s\n' "$*" >&2
        printf '        Log: %s\n\n' "${LOG_FILE:-/tmp/archwizard.log}" >&2
        exit 1
    fi
    gum style \
        --foreground        "$GUM_C_ERR" \
        --border-foreground "$GUM_C_ERR" \
        --border            thick \
        --padding           "0 2" \
        --width             "$GUM_WIDTH" \
        "FATAL ERROR" "" "$*" "" \
        "Log: ${LOG_FILE:-/tmp/archwizard.log}" 2>/dev/null \
        || printf '\033[1;31m[FATAL]\033[0m %s\n' "$*" >&2
    echo "" >&2
    exit 1
}

# -----------------------------------------------------------------------------
#  Banner
# -----------------------------------------------------------------------------
function show_banner() {
    # inputs: none / outputs: banner to stdout
    if [[ "${NO_GUM:-false}" == true ]]; then
        printf '\n\033[1;35m  ArchWizard 7.0  —  Arch Linux Installer\033[0m\n'
        printf '\033[2m  log: %s\033[0m\n\n' "${LOG_FILE:-/tmp/archwizard.log}"
        return 0
    fi
    clear
    gum style \
        --foreground        "$GUM_C_TITLE" \
        --bold \
        --border            double \
        --border-foreground "$GUM_C_TITLE" \
        --padding           "1 4" \
        --width             "$GUM_WIDTH" \
        "ARCH WIZARD" \
        "v7.0.0" \
        "" \
        "The most reliable Arch Linux installer" \
        "" \
        "log: ${LOG_FILE:-/tmp/archwizard.log}" 2>/dev/null \
        || printf '\033[1;35m  ARCH WIZARD  v7.0.0\033[0m\n'
    echo ""
}

# -----------------------------------------------------------------------------
#  Interactive wrappers — all fall back to plain bash when NO_GUM=true
# -----------------------------------------------------------------------------

# confirm_gum "Question?" → returns 0 (yes) or 1 (no)
function confirm_gum() {
    # inputs: prompt string / outputs: exit code 0=yes 1=no
    if [[ "${NO_GUM:-false}" == true ]]; then
        local ans
        printf ' ? %s [y/N]: ' "$*" >&2
        read -r ans
        [[ "${ans,,}" == "y" ]]
        return
    fi
    gum confirm \
        --prompt.foreground    "$GUM_C_ACCENT" \
        --selected.background  "$GUM_C_TITLE" \
        --unselected.foreground "$GUM_C_DIM" \
        "$@"
}

# input_gum "Header" "placeholder" → echoes trimmed input to stdout
function input_gum() {
    # inputs: header placeholder / outputs: user string to stdout
    local header="${1:-Input}" placeholder="${2:-}"
    if [[ "${NO_GUM:-false}" == true ]]; then
        local val
        printf ' › %s%s: ' "$header" "${placeholder:+ [$placeholder]}" >&2
        read -r val
        echo "${val:-$placeholder}"
        return 0
    fi
    gum input \
        --prompt          " › " \
        --prompt.foreground "$GUM_C_ACCENT" \
        --placeholder     "$placeholder" \
        --header          "$header" \
        --header.foreground "$GUM_C_INFO" \
        --width           "$GUM_WIDTH"
}

# password_gum "Label" → echoes confirmed password to stdout; loops until match
function password_gum() {
    # inputs: label / outputs: password to stdout
    local label="${1:-Password}"
    if [[ "${NO_GUM:-false}" == true ]]; then
        local p1 p2
        while true; do
            printf ' › %s: ' "$label"       >&2; read -rs p1; echo >&2
            printf ' › Confirm %s: ' "$label" >&2; read -rs p2; echo >&2
            if [[ "$p1" == "$p2" && -n "$p1" ]]; then
                echo "$p1"; return 0
            fi
            warn "Passwords don't match or are empty — try again."
        done
    fi
    local pass1 pass2
    while true; do
        pass1=$(gum input --password \
            --prompt " › " --prompt.foreground "$GUM_C_ACCENT" \
            --header "$label" --header.foreground "$GUM_C_INFO" \
            --width "$GUM_WIDTH")
        pass2=$(gum input --password \
            --prompt " › " --prompt.foreground "$GUM_C_ACCENT" \
            --header "Confirm: $label" --header.foreground "$GUM_C_INFO" \
            --width "$GUM_WIDTH")
        if [[ "$pass1" == "$pass2" && -n "$pass1" ]]; then
            echo "$pass1"; return 0
        fi
        warn "Passwords don't match or are empty — try again."
    done
}

# choose_one "default" item1 item2 … → echoes selection to stdout
# If user presses Esc / q in gum, echoes BACK sentinel (see state.sh).
# Returns 0 always; caller checks if result == "$BACK".
function choose_one() {
    # inputs: default items... / outputs: selected item to stdout
    local default="$1"; shift

    if [[ "${NO_GUM:-false}" == true ]]; then
        local items=("$@") i=1
        echo "" >&2
        for item in "${items[@]}"; do
            # Skip visual separators
            if [[ "$item" == ─* ]]; then
                printf '  ──\n' >&2
            else
                printf '  %d) %s\n' "$i" "$item" >&2
            fi
            i=$(( i + 1 ))
        done
        local choice
        while true; do
            printf ' › Choose [1-%d]: ' "${#items[@]}" >&2
            read -r choice
            if [[ "$choice" =~ ^[0-9]+$ ]] \
               && (( choice >= 1 && choice <= ${#items[@]} )); then
                echo "${items[$(( choice - 1 ))]}"
                return 0
            fi
            warn "Enter a number between 1 and ${#items[@]}."
        done
    fi

    # Check whether default is actually in the list before using --selected.
    # gum choose --selected "" exits non-zero — crash pattern #4.
    local match=false
    for item in "$@"; do
        if [[ "$item" == "$default" ]]; then match=true; break; fi
    done

    local result
    if [[ "$match" == true ]]; then
        result=$(gum choose \
            --selected            "$default" \
            --selected.foreground "$GUM_C_TITLE" \
            --cursor.foreground   "$GUM_C_ACCENT" \
            --height              12 \
            "$@" 2>/dev/null) || true
    else
        result=$(gum choose \
            --selected.foreground "$GUM_C_TITLE" \
            --cursor.foreground   "$GUM_C_ACCENT" \
            --height              12 \
            "$@" 2>/dev/null) || true
    fi

    # Empty result means user pressed Esc/q — treat as back.
    if [[ -z "$result" ]]; then
        echo "${BACK:-← Back}"
        return 0
    fi
    echo "$result"
}

# choose_many "defaults_csv" item1 item2 … → one selected item per line
function choose_many() {
    # inputs: comma-separated defaults items... / outputs: selections to stdout
    local defaults="$1"; shift

    if [[ "${NO_GUM:-false}" == true ]]; then
        local items=("$@") i=1
        echo "" >&2
        for item in "${items[@]}"; do
            printf '  %d) %s\n' "$i" "$item" >&2
            i=$(( i + 1 ))
        done
        local raw
        printf ' › Space-separated numbers (e.g. 1 3): ' >&2
        read -r raw
        for n in $raw; do
            if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#items[@]} )); then
                echo "${items[$(( n - 1 ))]}"
            fi
        done
        return 0
    fi

    gum choose --no-limit \
        --selected            "$defaults" \
        --selected.foreground "$GUM_C_TITLE" \
        --cursor.foreground   "$GUM_C_ACCENT" \
        --height              14 \
        "$@" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
#  Command execution wrappers
# -----------------------------------------------------------------------------

# run "cmd …" — wraps ALL destructive commands; dry-run safe
# Uses eval "$@" not eval "$*" — preserves argument boundaries.
function run() {
    # inputs: command string(s) / side-effects: executes unless dry-run
    if [[ "${DRY_RUN:-false}" == true ]]; then
        _ui_msg "$GUM_C_DIM" "[dry]" "$*"
        return 0
    fi
    log "CMD: $*"
    eval "$@" 2>&1 | tee -a "${LOG_FILE:-/tmp/archwizard.log}"
}

# run_spin "Label" "cmd …" — spinner for slow ops; dry-run + NO_GUM safe
function run_spin() {
    # inputs: label command_string / side-effects: executes command
    local label="$1"; shift
    if [[ "${DRY_RUN:-false}" == true ]]; then
        _ui_msg "$GUM_C_DIM" "[dry]" "$*"
        return 0
    fi
    log "CMD: $*"
    if [[ "${NO_GUM:-false}" == true ]]; then
        info "$label"
        eval "$@" 2>&1 | tee -a "${LOG_FILE:-/tmp/archwizard.log}"
        return 0
    fi
    # gum spin --title must not contain $(gum style) — crash pattern #3.
    gum spin \
        --spinner dot \
        --title   " $label" \
        -- bash -c "$* 2>&1 | tee -a \"${LOG_FILE:-/tmp/archwizard.log}\"" \
        2>/dev/null \
        || { info "$label"; eval "$@" 2>&1 | tee -a "${LOG_FILE:-/tmp/archwizard.log}"; }
}

# run_interactive "cmd …" — parted resize ONLY; restores /dev/tty
# Required because the top-level exec > >(tee …) breaks interactive read().
function run_interactive() {
    # inputs: command string(s) / side-effects: executes with tty restored
    if [[ "${DRY_RUN:-false}" == true ]]; then
        _ui_msg "$GUM_C_DIM" "[dry]" "$*"
        return 0
    fi
    log "CMD (interactive): $*"
    eval "$@" </dev/tty >/dev/tty 2>/dev/tty
}
