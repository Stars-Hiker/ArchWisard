#!/usr/bin/env bash
# =============================================================================
#  lib/ui.sh — All UI wrappers + gum theme constants
#  Architecture rule: ZERO logic here. Pure presentation.
#  NO_GUM=true  → every function falls back to plain read/printf.
#
#  THE TEE PIPE PROBLEM:
#    archwizard.sh runs:  exec > >(tee -a "$LOG_FILE") 2>&1
#    This redirects stdout+stderr through tee for logging.
#    gum detects stdout is not a tty and either renders nothing (interactive)
#    or strips ANSI colors (display). Both break the UI completely.
#
#  FIX — two patterns used throughout:
#    Display  (section/ok/warn/info):  write to /dev/tty when stdout is piped
#    Interactive (confirm/choose/input): use </dev/tty 2>/dev/tty so gum gets
#      a real terminal for both rendering (stderr) and keyboard input (stdin),
#      while stdout is still captured by $() for the selection result.
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

# _clr COLOR "text" — inline ANSI 256-colour; safe inside gum --title strings
function _clr() { printf '\033[38;5;%sm%s\033[0m' "$1" "$2"; }

# _tty_out — fd/path for display output; /dev/tty when stdout is piped, else 1
function _tty_out() {
    if [[ ! -t 1 ]] && [[ -w /dev/tty ]]; then echo "/dev/tty"
    else echo "1"; fi
}

# -----------------------------------------------------------------------------
#  Display wrappers — write to /dev/tty when piped so tee doesn't swallow color
# -----------------------------------------------------------------------------

function _ui_msg() {
    local color="$1" icon="$2"; shift 2
    if [[ "${NO_GUM:-false}" == true ]]; then
        printf '%s %s\n' "$icon" "$*"
        return 0
    fi
    local out; out=$(_tty_out)
    gum style --foreground "$color" "${icon} $*" > "$out" 2>/dev/null \
        || printf '%s %s\n' "$icon" "$*" > "$out"
}

function log() {
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
    echo ""
    local out; out=$(_tty_out)
    if [[ "${NO_GUM:-false}" == true ]]; then
        printf '\033[1;35m══  %s  ══\033[0m\n\n' "$*" > "$out"
        return 0
    fi
    gum style \
        --foreground        "$GUM_C_TITLE" \
        --bold \
        --border-foreground "$GUM_C_TITLE" \
        --border            normal \
        --padding           "0 1" \
        --width             "$GUM_WIDTH" \
        "  ◆  $*" > "$out" 2>/dev/null \
        || printf '\033[1;35m══  %s  ══\033[0m\n' "$*" > "$out"
    echo ""
}

function die() {
    echo "" >&2
    if [[ "${NO_GUM:-false}" == true ]]; then
        printf '\033[1;31m[FATAL]\033[0m %s\n' "$*" >&2
        printf '        Log: %s\n\n' "${LOG_FILE:-/tmp/archwizard.log}" >&2
        exit 1
    fi
    local out; out=$(_tty_out)
    gum style \
        --foreground        "$GUM_C_ERR" \
        --border-foreground "$GUM_C_ERR" \
        --border            thick \
        --padding           "0 2" \
        --width             "$GUM_WIDTH" \
        "FATAL ERROR" "" "$*" "" \
        "Log: ${LOG_FILE:-/tmp/archwizard.log}" > "$out" 2>/dev/null \
        || printf '\033[1;31m[FATAL]\033[0m %s\n' "$*" >&2
    echo "" >&2
    exit 1
}

function show_banner() {
    if [[ "${NO_GUM:-false}" == true ]]; then
        printf '\n\033[1;35m  ArchWizard 7.0  —  Arch Linux Installer\033[0m\n'
        printf '\033[2m  log: %s\033[0m\n\n' "${LOG_FILE:-/tmp/archwizard.log}"
        return 0
    fi
    clear
    local out; out=$(_tty_out)
    gum style \
        --foreground        "$GUM_C_TITLE" \
        --bold \
        --border            double \
        --border-foreground "$GUM_C_TITLE" \
        --padding           "1 4" \
        --width             "$GUM_WIDTH" \
        "ARCH WIZARD" "v7.0.0" "" \
        "The most reliable Arch Linux installer" "" \
        "log: ${LOG_FILE:-/tmp/archwizard.log}" > "$out" 2>/dev/null \
        || printf '\033[1;35m  ARCH WIZARD  v7.0.0\033[0m\n' > "$out"
    echo ""
}

# -----------------------------------------------------------------------------
#  Interactive wrappers — all use </dev/tty 2>/dev/tty so gum gets a real tty
#  even when the outer exec > >(tee) has hijacked stdout+stderr.
#  Pattern: result=$(gum choose ... </dev/tty 2>/dev/tty)
#    stdin  </dev/tty  → gum reads keyboard from real terminal
#    stderr 2>/dev/tty → gum renders its TUI to real terminal
#    stdout            → captured by $() as the final selection
# -----------------------------------------------------------------------------

function confirm_gum() {
    if [[ "${NO_GUM:-false}" == true ]]; then
        local ans
        printf ' ? %s [y/N]: ' "$*" >/dev/tty
        read -r ans </dev/tty
        [[ "${ans,,}" == "y" ]]
        return
    fi
    gum confirm \
        --prompt.foreground     "$GUM_C_ACCENT" \
        --selected.background   "$GUM_C_TITLE" \
        --unselected.foreground "$GUM_C_DIM" \
        "$@" </dev/tty 2>/dev/tty
}

function input_gum() {
    local header="${1:-Input}" placeholder="${2:-}"
    if [[ "${NO_GUM:-false}" == true ]]; then
        local val
        printf ' › %s%s: ' "$header" "${placeholder:+ [$placeholder]}" >/dev/tty
        read -r val </dev/tty
        echo "${val:-$placeholder}"
        return 0
    fi
    gum input \
        --prompt            " › " \
        --prompt.foreground "$GUM_C_ACCENT" \
        --placeholder       "$placeholder" \
        --header            "$header" \
        --header.foreground "$GUM_C_INFO" \
        --width             "$GUM_WIDTH" \
        </dev/tty 2>/dev/tty
}

function password_gum() {
    local label="${1:-Password}"
    if [[ "${NO_GUM:-false}" == true ]]; then
        local p1 p2
        while true; do
            printf ' › %s: ' "$label"         >/dev/tty; read -rs p1 </dev/tty; echo >/dev/tty
            printf ' › Confirm %s: ' "$label" >/dev/tty; read -rs p2 </dev/tty; echo >/dev/tty
            if [[ "$p1" == "$p2" && -n "$p1" ]]; then echo "$p1"; return 0; fi
            warn "Passwords don't match or are empty — try again."
        done
    fi
    local pass1 pass2
    while true; do
        pass1=$(gum input --password \
            --prompt " › " --prompt.foreground "$GUM_C_ACCENT" \
            --header "$label" --header.foreground "$GUM_C_INFO" \
            --width "$GUM_WIDTH" </dev/tty 2>/dev/tty)
        pass2=$(gum input --password \
            --prompt " › " --prompt.foreground "$GUM_C_ACCENT" \
            --header "Confirm: $label" --header.foreground "$GUM_C_INFO" \
            --width "$GUM_WIDTH" </dev/tty 2>/dev/tty)
        if [[ "$pass1" == "$pass2" && -n "$pass1" ]]; then echo "$pass1"; return 0; fi
        warn "Passwords don't match or are empty — try again."
    done
}

function choose_one() {
    # First arg is default; rest are items. Returns selected item on stdout.
    local default="$1"; shift

    if [[ "${NO_GUM:-false}" == true ]]; then
        local items=("$@") i=1
        echo "" >/dev/tty
        for item in "${items[@]}"; do
            if [[ "$item" == ─* ]]; then printf '  ──\n' >/dev/tty
            else printf '  %d) %s\n' "$i" "$item" >/dev/tty; fi
            i=$(( i + 1 ))
        done
        local choice
        while true; do
            printf ' › Choose [1-%d]: ' "${#items[@]}" >/dev/tty
            read -r choice </dev/tty
            if [[ "$choice" =~ ^[0-9]+$ ]] \
               && (( choice >= 1 && choice <= ${#items[@]} )); then
                echo "${items[$(( choice - 1 ))]}"; return 0
            fi
            warn "Enter a number between 1 and ${#items[@]}."
        done
    fi

    # crash pattern #4: never pass --selected "" to gum choose
    local match=false item
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
            "$@" </dev/tty 2>/dev/tty) || true
    else
        result=$(gum choose \
            --selected.foreground "$GUM_C_TITLE" \
            --cursor.foreground   "$GUM_C_ACCENT" \
            --height              12 \
            "$@" </dev/tty 2>/dev/tty) || true
    fi

    # Empty = user pressed Esc/q — treat as back
    if [[ -z "$result" ]]; then echo "${BACK:-← Back}"; return 0; fi
    echo "$result"
}

function choose_many() {
    local defaults="$1"; shift

    if [[ "${NO_GUM:-false}" == true ]]; then
        local items=("$@") i=1
        echo "" >/dev/tty
        for item in "${items[@]}"; do
            printf '  %d) %s\n' "$i" "$item" >/dev/tty
            i=$(( i + 1 ))
        done
        local raw
        printf ' › Space-separated numbers (e.g. 1 3): ' >/dev/tty
        read -r raw </dev/tty
        local n
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
        "$@" </dev/tty 2>/dev/tty || true
}

# -----------------------------------------------------------------------------
#  Command execution wrappers
# -----------------------------------------------------------------------------

function run() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        _ui_msg "$GUM_C_DIM" "[dry]" "$*"; return 0
    fi
    log "CMD: $*"
    eval "$@" 2>&1 | tee -a "${LOG_FILE:-/tmp/archwizard.log}"
}

function run_spin() {
    local label="$1"; shift
    if [[ "${DRY_RUN:-false}" == true ]]; then
        _ui_msg "$GUM_C_DIM" "[dry]" "$*"; return 0
    fi
    log "CMD: $*"
    if [[ "${NO_GUM:-false}" == true ]]; then
        info "$label"
        eval "$@" 2>&1 | tee -a "${LOG_FILE:-/tmp/archwizard.log}"
        return 0
    fi
    # </dev/tty 2>/dev/tty: spinner renders to terminal; stdout captured as normal
    # crash pattern #3: no $(gum style) inside --title
    gum spin \
        --spinner dot \
        --title   " $label" \
        -- bash -c "$* 2>&1 | tee -a \"${LOG_FILE:-/tmp/archwizard.log}\"" \
        </dev/tty 2>/dev/tty \
        || { info "$label"; eval "$@" 2>&1 | tee -a "${LOG_FILE:-/tmp/archwizard.log}"; }
}

function run_interactive() {
    # parted resize ONLY — restores full /dev/tty for interactive prompts
    if [[ "${DRY_RUN:-false}" == true ]]; then
        _ui_msg "$GUM_C_DIM" "[dry]" "$*"; return 0
    fi
    log "CMD (interactive): $*"
    eval "$@" </dev/tty >/dev/tty 2>/dev/tty
}
