#!/usr/bin/env bash
# =============================================================================
#  ArchWizard 7.0.0-gum
#  Arch Linux Installer — gum TUI + NO_GUM plain-text edition
#
#  Usage: bash archwizardGum_7_0.sh [--dry-run] [--verbose] [--no-gum]
#                                    [--load-config FILE] [--help]
#
#  This file: infrastructure layer.
#    - All globals (CLAUDE.md canonical list)
#    - Theme constants + _clr()
#    - Logging + run helpers
#    - All gum wrappers with NO_GUM fallbacks
#    - Shared pure-bash helpers (part_name, _refresh_partitions, probe_os_from_part)
#    - _step_done / _step_summary predicates
#    - Step state machine (main_menu)
#    - Stub step functions showing exact caller patterns
#    - Argument parsing + entry point
#
#  Step implementations are stubs; fill in iteratively from archwizardGum_2_0.sh
#  and ArchWizard_6_0.sh (reference).
# =============================================================================

set -euo pipefail

# =============================================================================
#  TRAPS
# =============================================================================

# INT: clean exit on Ctrl+C — must fire BEFORE ERR so gum exits don't mis-trigger it
trap 'printf "\n\033[1;33m[WARN]\033[0m  Interrupted.\n"; exit 130' INT

# ERR: crash log + human-readable fatal message
trap 'RC=$?
      printf "CRASH line=%s exit=%s cmd=%s\n" \
          "$LINENO" "$RC" "${BASH_COMMAND}" >> "${LOG_FILE:-/tmp/archwizard.log}"
      printf "\n\033[1;31m[FATAL]\033[0m  Crashed at line %s (exit %s)\n" \
          "$LINENO" "$RC" >&2
      printf "         cmd : %s\n" "${BASH_COMMAND}" >&2
      printf "         log : %s\n\n" "${LOG_FILE:-/tmp/archwizard.log}" >&2' ERR

# =============================================================================
#  LOG FILE
#  No exec tee — gum output must not be globally captured; run() logs per-command.
# =============================================================================
LOG_FILE="/tmp/archwizard.log"
: > "$LOG_FILE"

# =============================================================================
#  GLOBALS  (canonical list from CLAUDE.md — do not add/remove without updating docs)
# =============================================================================

# ── Runtime ───────────────────────────────────────────────────────────────────
DRY_RUN=false
VERBOSE=false
NO_GUM=false
CONFIG_FILE=""
FIRMWARE_MODE="uefi"    # detected — NEVER set by user input
CPU_VENDOR="unknown"    # detected
GPU_VENDOR="unknown"    # detected
LOG_FILE="/tmp/archwizard.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── UI state ──────────────────────────────────────────────────────────────────
# BACK_REQUESTED: set true by choose_one/choose_many/confirm_gum on ← Back.
# Callers check this immediately after the function returns 1.
BACK_REQUESTED=false
# REPLY: output variable for choose_one (single string) and choose_many
# (newline-separated; use: mapfile -t ARR <<< "$REPLY").
REPLY=""

# ── Disk & partition ─────────────────────────────────────────────────────────
DISK_ROOT=""
DISK_HOME=""
EFI_PART=""
ROOT_PART=""
ROOT_PART_MAPPED=""     # /dev/mapper/cryptroot when LUKS active
HOME_PART=""
SWAP_PART=""
EFI_SIZE_MB=512
ROOT_SIZE=""            # GB integer or "rest"
HOME_SIZE=""            # GB integer or "rest"
SEP_HOME=false

# ── Multi-boot ────────────────────────────────────────────────────────────────
DUAL_BOOT=false
REUSE_EFI=false
PROTECTED_PARTS=()      # partitions to never touch
REPLACE_PARTS_ALL=()    # partitions to delete
REPLACE_PART=""
RESIZE_PART=""
RESIZE_NEW_GB=0
FREE_GB_AVAIL=0
EXISTING_WINDOWS=false
EXISTING_LINUX=false
EXISTING_SYSTEMS=()

# ── Storage stack ─────────────────────────────────────────────────────────────
STORAGE_STACK="plain"   # plain | luks | lvm | luks_lvm | btrfs | luks_btrfs | zfs
STORAGE_CONFIGURED=false  # set true by step_storage; used by _step_done(4)
ROOT_FS="btrfs"
HOME_FS="btrfs"
SWAP_TYPE="zram"        # zram | file | partition | none
SWAP_SIZE="8"
USE_LUKS=false
LUKS_PASSWORD=""        # NEVER in argv — always piped via stdin
LVM_VG=""
LVM_LV_ROOT=""
LVM_LV_HOME=""
ZFS_POOL=""

# ── System identity ───────────────────────────────────────────────────────────
HOSTNAME=""
GRUB_ENTRY_NAME=""
USERNAME=""
USER_PASSWORD=""        # NEVER in argv
ROOT_PASSWORD=""        # NEVER in argv
TIMEZONE="UTC"
LOCALE="en_US.UTF-8"
KEYMAP="us"

# ── Software ──────────────────────────────────────────────────────────────────
KERNEL="linux"          # linux | linux-lts | linux-zen | linux-hardened
BOOTLOADER=""           # grub | systemd-boot
SECURE_BOOT=false
DESKTOPS=()
AUR_HELPER="none"       # paru-bin | paru | yay | none
USE_REFLECTOR=false
REFLECTOR_COUNTRIES="France,Germany"
REFLECTOR_AGE=12
REFLECTOR_NUMBER=10
REFLECTOR_PROTOCOL="https"
USE_MULTILIB=false
USE_PIPEWIRE=false
USE_NVIDIA=false
USE_AMD_VULKAN=false
USE_BLUETOOTH=false
USE_CUPS=false
USE_SNAPPER=false
FIREWALL="none"         # nftables | ufw | none

# ── OS probe (used by shared helpers) ────────────────────────────────────────
PROBE_OS_RESULT=""

# =============================================================================
#  THEME  (readonly — never mutate after init)
# =============================================================================
readonly GUM_C_TITLE=99
readonly GUM_C_OK=46
readonly GUM_C_WARN=214
readonly GUM_C_ERR=196
readonly GUM_C_INFO=51
readonly GUM_C_DIM=242
readonly GUM_C_ACCENT=141
readonly GUM_WIDTH=70

# _clr ANSI_256_COLOR TEXT → inline ANSI-256 color (works in both gum and plain mode)
# !crash: never use $(gum style) inside gum --title/--header — use _clr instead
function _clr() {
    # inputs: $1=color_number $2=text / outputs: colored string on stdout / no side-effects
    printf '\033[38;5;%sm%s\033[0m' "$1" "$2"
}

# =============================================================================
#  LOGGING
# =============================================================================

function log() {
    # inputs: message args / outputs: timestamped line to stdout + LOG_FILE / no side-effects
    local m; m="[$(date '+%H:%M:%S')] $*"
    printf '%s\n' "$m"
    printf '%s\n' "$m" >> "$LOG_FILE"
}

function ok() {
    # inputs: message args / outputs: green ✔ line / no side-effects
    if [[ "$NO_GUM" == true ]]; then
        printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*"
    else
        gum style --foreground "$GUM_C_OK" " ✔  $*" 2>/dev/null \
            || printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*"
    fi
}

function warn() {
    # inputs: message args / outputs: yellow ⚠ line / no side-effects
    if [[ "$NO_GUM" == true ]]; then
        printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"
    else
        gum style --foreground "$GUM_C_WARN" " ⚠  $*" 2>/dev/null \
            || printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"
    fi
}

function info() {
    # inputs: message args / outputs: cyan ℹ line / no side-effects
    if [[ "$NO_GUM" == true ]]; then
        printf '\033[0;36m[INFO]\033[0m  %s\n' "$*"
    else
        gum style --foreground "$GUM_C_INFO" " ℹ  $*" 2>/dev/null \
            || printf '\033[0;36m[INFO]\033[0m  %s\n' "$*"
    fi
}

function error() {
    # inputs: message args / outputs: red ✗ line on stderr / no side-effects
    if [[ "$NO_GUM" == true ]]; then
        printf '\033[0;31m[ERR ]\033[0m  %s\n' "$*" >&2
    else
        gum style --foreground "$GUM_C_ERR" " ✗  $*" 2>/dev/null >&2 \
            || printf '\033[0;31m[ERR ]\033[0m  %s\n' "$*" >&2
    fi
}

function blank() {
    # inputs: none / outputs: blank line / no side-effects
    echo ""
}

function section() {
    # inputs: title args / outputs: decorated section header / no side-effects
    echo ""
    if [[ "$NO_GUM" == true ]]; then
        printf '\033[1;35m━━━  %s  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n' "$*"
    else
        gum style \
            --foreground "$GUM_C_TITLE" --bold \
            --border-foreground "$GUM_C_TITLE" --border normal \
            --padding "0 1" --width "$GUM_WIDTH" \
            "  ◆  $*" 2>/dev/null \
        || printf '\033[1;35m━━━  %s  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n' "$*"
    fi
    echo ""
}

function die() {
    # inputs: message args / outputs: fatal error box on stderr / side-effects: exit 1
    echo ""
    if [[ "$NO_GUM" == true ]]; then
        printf '\033[1;31m╔══════════════════════════════════════════════════╗\033[0m\n' >&2
        printf '\033[1;31m  FATAL: %s\033[0m\n' "$*" >&2
        printf '\033[1;31m  Log  : %s\033[0m\n' "$LOG_FILE" >&2
        printf '\033[1;31m╚══════════════════════════════════════════════════╝\033[0m\n' >&2
    else
        gum style \
            --foreground "$GUM_C_ERR" \
            --border-foreground "$GUM_C_ERR" --border thick \
            --padding "0 2" --width "$GUM_WIDTH" \
            "FATAL ERROR" "" "$*" "" "Log: $LOG_FILE" 2>/dev/null >&2 \
        || printf '\033[1;31m[FATAL]\033[0m %s\n  Log: %s\n' "$*" "$LOG_FILE" >&2
    fi
    echo ""
    exit 1
}

# =============================================================================
#  RUN HELPERS
# =============================================================================

function run() {
    # inputs: command and args / outputs: command stdout+stderr (tee to log) / side-effects: executes cmd
    # Wraps ALL destructive commands. DRY_RUN=true → prints only, no exec.
    # Uses eval "$@" not eval "$*" to preserve argument boundaries.
    # !crash: never call _refresh_partitions via run() — shell function is lost in eval subshell
    if [[ "$DRY_RUN" == true ]]; then
        if [[ "$NO_GUM" == true ]]; then
            printf '\033[2m[dry-run] %s\033[0m\n' "$*"
        else
            gum style --faint " [dry-run] $*" 2>/dev/null \
                || printf '\033[2m[dry-run] %s\033[0m\n' "$*"
        fi
        return 0
    fi
    log "CMD: $*"
    eval "$@" 2>&1 | tee -a "$LOG_FILE"
}

function run_interactive() {
    # inputs: command and args / outputs: forwarded to /dev/tty / side-effects: executes cmd interactively
    # For parted resize ONLY — requires interactive terminal read().
    # !crash: top-level tee pipe breaks interactive read(); must redirect all streams to /dev/tty
    if [[ "$DRY_RUN" == true ]]; then
        if [[ "$NO_GUM" == true ]]; then
            printf '\033[2m[dry-run interactive] %s\033[0m\n' "$*"
        else
            gum style --faint " [dry-run interactive] $*" 2>/dev/null \
                || printf '\033[2m[dry-run interactive] %s\033[0m\n' "$*"
        fi
        return 0
    fi
    log "CMD (interactive): $*"
    eval "$@" </dev/tty >/dev/tty 2>/dev/tty
}

function run_spin() {
    # inputs: $1=title, rest=command / outputs: spinner (gum) or info+output (NO_GUM) / side-effects: executes cmd
    # !crash: never $(gum style) inside --title — crashes when stdout is piped; use plain string
    local title="$1"; shift
    if [[ "$DRY_RUN" == true ]]; then
        if [[ "$NO_GUM" == true ]]; then
            printf '\033[2m[dry-run] %s\033[0m\n' "$*"
        else
            gum style --faint " [dry-run] $*" 2>/dev/null \
                || printf '\033[2m[dry-run] %s\033[0m\n' "$*"
        fi
        return 0
    fi
    log "CMD: $*"
    if [[ "$NO_GUM" == true ]]; then
        info "$title"
        eval "$@" 2>&1 | tee -a "$LOG_FILE"
    else
        gum spin --spinner dot --title " ${title}" \
            -- bash -c "$* 2>&1 | tee -a \"$LOG_FILE\"" 2>/dev/null \
        || { info "$title"; eval "$@" 2>&1 | tee -a "$LOG_FILE"; }
    fi
}

# =============================================================================
#  GUM UI WRAPPERS  (all with NO_GUM fallbacks)
# =============================================================================
#
#  Contract for back navigation:
#    choose_one / choose_many / confirm_gum:
#      → return 0  : user made a valid selection  (REPLY set for choose_*)
#      → return 1  : user selected ← Back         (BACK_REQUESTED=true)
#      → BACK_REQUESTED is reset to false at the top of each call
#
#  Caller pattern for choose_one / choose_many:
#      choose_one "default" "opt1" "opt2" || return 1
#      local selected="$REPLY"
#
#  Caller pattern for confirm_gum:
#      confirm_gum "Enable X?" "y"; local _rc=$? _back=$BACK_REQUESTED
#      [[ "$_back" == true ]] && return 1
#      (( _rc == 0 )) && FEATURE=true || FEATURE=false
#
#  input_gum / password_gum: output via stdout (capture with $()).
#  No back option — text fields; callers control flow via choose_one upstream.

# ── confirm_gum ───────────────────────────────────────────────────────────────
function confirm_gum() {
    # inputs: $1=message $2=default(y|n) / outputs: none / side-effects: sets BACK_REQUESTED
    # Returns 0 (Yes), 1 (No or ← Back). BACK_REQUESTED=true distinguishes Back from No.
    local msg="$1" default="${2:-n}"
    BACK_REQUESTED=false

    if [[ "$NO_GUM" == true ]]; then
        local prompt ans
        [[ "$default" == "y" ]] && prompt="[Y/n/b=back]" || prompt="[y/N/b=back]"
        printf '\033[1;33m[ ? ]\033[0m  %s %s: ' "$msg" "$prompt" >&2
        read -r ans
        case "${ans:-$default}" in
            [Yy]*) return 0 ;;
            [Bb]*) BACK_REQUESTED=true; return 1 ;;
            *)     return 1 ;;
        esac
    fi

    # !crash: gum choose --selected "" exits non-zero — always pass a non-empty string
    local def_item
    [[ "$default" == "y" ]] && def_item="Yes" || def_item="No"

    local sel
    # gum choose gives us Yes / No / ← Back  (3-item list, not gum confirm)
    sel=$(gum choose \
        --selected "$def_item" \
        --selected.foreground "$GUM_C_TITLE" \
        --cursor.foreground   "$GUM_C_ACCENT" \
        --height 4 \
        "Yes" "No" "← Back" 2>/dev/null) || {
        # gum failed (e.g. not a tty) — plain fallback
        local ans2
        printf '\033[1;33m[ ? ]\033[0m  %s [y/N/b=back]: ' "$msg" >&2
        read -r ans2
        case "${ans2:-$default}" in
            [Yy]*) return 0 ;;
            [Bb]*) BACK_REQUESTED=true; return 1 ;;
            *)     return 1 ;;
        esac
        return
    }

    case "$sel" in
        "Yes")    return 0 ;;
        "← Back") BACK_REQUESTED=true; return 1 ;;
        *)        return 1 ;;
    esac
}

# ── input_gum ─────────────────────────────────────────────────────────────────
function input_gum() {
    # inputs: $1=prompt $2=placeholder / outputs: entered text on stdout / no side-effects
    # No back option — text fields are never the first choice in a step.
    # Empty input returns placeholder value (use placeholder="" to allow empty).
    local prompt="$1" placeholder="${2:-}"

    if [[ "$NO_GUM" == true ]]; then
        if [[ -n "$placeholder" ]]; then
            printf '\033[0;36m[INFO]\033[0m  %s [%s]: ' "$prompt" "$placeholder" >&2
        else
            printf '\033[0;36m[INFO]\033[0m  %s: ' "$prompt" >&2
        fi
        local val
        read -r val
        printf '%s' "${val:-$placeholder}"
        return
    fi

    gum input \
        --prompt " › " \
        --prompt.foreground "$GUM_C_ACCENT" \
        --placeholder       "$placeholder" \
        --header            "$prompt" \
        --header.foreground "$GUM_C_INFO" \
        --width             "$GUM_WIDTH" 2>/dev/null \
    || {
        # gum failed — plain fallback
        if [[ -n "$placeholder" ]]; then
            printf '\033[0;36m[INFO]\033[0m  %s [%s]: ' "$prompt" "$placeholder" >&2
        else
            printf '\033[0;36m[INFO]\033[0m  %s: ' "$prompt" >&2
        fi
        local val2; read -r val2
        printf '%s' "${val2:-$placeholder}"
    }
}

# ── password_gum ──────────────────────────────────────────────────────────────
function password_gum() {
    # inputs: $1=prompt / outputs: password on stdout / no side-effects
    # Loops until two identical non-empty inputs. No back option.
    local prompt="$1"
    local pass1 pass2

    while true; do
        if [[ "$NO_GUM" == true ]]; then
            printf '\033[0;36m[INFO]\033[0m  %s: ' "$prompt" >&2
            read -rs pass1; echo >&2
            printf '\033[0;36m[INFO]\033[0m  Confirm: ' >&2
            read -rs pass2; echo >&2
        else
            pass1=$(gum input \
                --password \
                --prompt " › " \
                --prompt.foreground "$GUM_C_ACCENT" \
                --header            "$prompt" \
                --header.foreground "$GUM_C_INFO" \
                --width             "$GUM_WIDTH" 2>/dev/null) \
            || {
                printf '\033[0;36m[INFO]\033[0m  %s: ' "$prompt" >&2
                read -rs pass1; echo >&2
            }
            pass2=$(gum input \
                --password \
                --prompt " › " \
                --prompt.foreground "$GUM_C_ACCENT" \
                --header            "Confirm: $prompt" \
                --header.foreground "$GUM_C_INFO" \
                --width             "$GUM_WIDTH" 2>/dev/null) \
            || {
                printf '\033[0;36m[INFO]\033[0m  Confirm %s: ' "$prompt" >&2
                read -rs pass2; echo >&2
            }
        fi

        if [[ "$pass1" == "$pass2" && -n "$pass1" ]]; then
            printf '%s' "$pass1"
            return 0
        fi
        warn "Passwords do not match or are empty — try again."
    done
}

# ── choose_one ────────────────────────────────────────────────────────────────
function choose_one() {
    # inputs: $1=default, rest=items / outputs: sets REPLY / side-effects: sets BACK_REQUESTED
    # Returns 0 (REPLY set to chosen item) or 1 (BACK_REQUESTED=true, ← Back selected).
    # Always appends "← Back" as the final option — step functions use || return 1.
    # !crash: gum choose --selected "" exits non-zero — guard the --selected flag
    local default="$1"; shift
    local -a items=("$@")
    BACK_REQUESTED=false
    REPLY=""

    if [[ "$NO_GUM" == true ]]; then
        echo "" >&2
        local i=1
        for item in "${items[@]}"; do
            printf '  \033[1m%2d)\033[0m %s\n' "$i" "$item" >&2
            i=$(( i + 1 ))
        done
        printf '  \033[2m%2d) ← Back\033[0m\n' "$i" >&2
        local total=$i
        while true; do
            printf '\033[1;33m[ ? ]\033[0m  Choice [1-%d]: ' "$total" >&2
            local choice
            read -r choice
            if [[ "$choice" =~ ^[0-9]+$ ]]; then
                if (( choice >= 1 && choice <= ${#items[@]} )); then
                    REPLY="${items[$(( choice - 1 ))]}"; return 0
                elif (( choice == total )); then
                    BACK_REQUESTED=true; return 1
                fi
            fi
            warn "Enter a number between 1 and ${total}."
        done
    fi

    # gum mode
    # !crash: only pass --selected when default actually matches one of the items
    local match=false
    local item
    for item in "${items[@]}"; do
        [[ "$item" == "$default" ]] && match=true && break
    done

    local -a gum_items=("${items[@]}" "← Back")
    local sel
    if [[ "$match" == true ]]; then
        sel=$(gum choose \
            --selected            "$default" \
            --selected.foreground "$GUM_C_TITLE" \
            --cursor.foreground   "$GUM_C_ACCENT" \
            --height 12 \
            "${gum_items[@]}" 2>/dev/null) \
        || { BACK_REQUESTED=true; return 1; }
    else
        sel=$(gum choose \
            --selected.foreground "$GUM_C_TITLE" \
            --cursor.foreground   "$GUM_C_ACCENT" \
            --height 12 \
            "${gum_items[@]}" 2>/dev/null) \
        || { BACK_REQUESTED=true; return 1; }
    fi

    if [[ "$sel" == "← Back" ]]; then
        BACK_REQUESTED=true; return 1
    fi
    REPLY="$sel"; return 0
}

# ── choose_many ───────────────────────────────────────────────────────────────
function choose_many() {
    # inputs: $1=defaults(comma-sep or ""), rest=items / outputs: sets REPLY (newline-sep)
    # side-effects: sets BACK_REQUESTED
    # Returns 0 (REPLY set, may be empty string for no selection) or 1 (BACK_REQUESTED=true).
    # If ← Back appears anywhere in selection, back takes priority over chosen items.
    # Caller: mapfile -t MY_ARRAY <<< "$REPLY"
    # !crash: omit --selected entirely when defaults is empty string (exits non-zero)
    local defaults="$1"; shift
    local -a items=("$@")
    BACK_REQUESTED=false
    REPLY=""

    if [[ "$NO_GUM" == true ]]; then
        echo "" >&2
        info "Select items — enter space-separated numbers (0 = ← Back, Enter = confirm):" >&2
        local i=1
        for item in "${items[@]}"; do
            # show a ✔ next to pre-selected items
            local marker="  "
            if [[ -n "$defaults" ]]; then
                local d
                IFS=',' read -ra _defs <<< "$defaults"
                for d in "${_defs[@]}"; do
                    [[ "$d" == "$item" ]] && marker="✔ " && break
                done
            fi
            printf '  \033[1m%2d)\033[0m %s%s\n' "$i" "$marker" "$item" >&2
            i=$(( i + 1 ))
        done
        printf '  \033[2m 0) ← Back\033[0m\n' >&2

        while true; do
            printf '\033[1;33m[ ? ]\033[0m  Numbers (0=back, Enter=confirm with shown): ' >&2
            local raw; read -r raw
            if [[ -z "$raw" ]]; then
                REPLY=""; return 0  # confirm with empty selection
            fi
            local -a chosen=()
            local valid=true is_back=false
            local num
            for num in $raw; do
                if [[ "$num" == "0" ]]; then is_back=true; break; fi
                if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#items[@]} )); then
                    chosen+=("${items[$(( num - 1 ))]}")
                else
                    warn "Invalid: '$num'"; valid=false; break
                fi
            done
            if [[ "$is_back" == true ]]; then BACK_REQUESTED=true; return 1; fi
            if [[ "$valid" == true ]]; then
                REPLY="$(printf '%s\n' "${chosen[@]+"${chosen[@]}"})"
                return 0
            fi
        done
    fi

    # gum mode
    local -a gum_items=("${items[@]}" "← Back")
    local sel_output
    if [[ -n "$defaults" ]]; then
        # !crash: only pass --selected when the string is non-empty
        sel_output=$(gum choose \
            --no-limit \
            --selected            "$defaults" \
            --selected.foreground "$GUM_C_TITLE" \
            --cursor.foreground   "$GUM_C_ACCENT" \
            --height 14 \
            "${gum_items[@]}" 2>/dev/null) \
        || { BACK_REQUESTED=true; return 1; }
    else
        sel_output=$(gum choose \
            --no-limit \
            --selected.foreground "$GUM_C_TITLE" \
            --cursor.foreground   "$GUM_C_ACCENT" \
            --height 14 \
            "${gum_items[@]}" 2>/dev/null) \
        || { BACK_REQUESTED=true; return 1; }
    fi

    # ← Back anywhere in selection takes priority
    if printf '%s\n' "$sel_output" | grep -qxF "← Back"; then
        BACK_REQUESTED=true; return 1
    fi

    REPLY="$sel_output"; return 0
}

# =============================================================================
#  SHARED HELPERS  (pure bash — zero gum calls; called by UI wrapper functions)
# =============================================================================

function part_name() {
    # inputs: $1=disk $2=partition_number / outputs: device path / no side-effects
    # Returns /dev/nvme0n1p1 (NVMe/MMC) or /dev/sda1 (SATA/other).
    local disk="$1" num="$2"
    if [[ "$disk" == *"nvme"* || "$disk" == *"mmcblk"* ]]; then
        printf '%s' "${disk}p${num}"
    else
        printf '%s' "${disk}${num}"
    fi
}

function _is_protected() {
    # inputs: $1=partition_path / outputs: none / no side-effects
    # Returns 0 if partition is in PROTECTED_PARTS[], 1 otherwise.
    local p="$1" pp
    for pp in "${PROTECTED_PARTS[@]+"${PROTECTED_PARTS[@]}"}"; do
        [[ "$pp" == "$p" ]] && return 0
    done
    return 1
}

function _refresh_partitions() {
    # inputs: $1=disk / outputs: none / side-effects: kernel rescans partition table
    # !crash: call DIRECTLY — never via run()/eval; shell function is lost in eval subshell
    # !crash: batch ALL sgdisk -d calls first, then call this ONCE — not after each deletion
    local disk="$1" attempt
    for attempt in 1 2 3; do
        if partprobe "$disk" 2>/dev/null; then
            sleep 1; ok "Kernel partition table updated"; return 0
        fi
        warn "partprobe attempt ${attempt}/3 — retrying in 2s…"; sleep 2
    done
    if partx -u "$disk" 2>/dev/null; then
        sleep 1; ok "Kernel partition table updated via partx"; return 0
    fi
    udevadm settle 2>/dev/null || true
    sleep 3
    warn "Could not confirm kernel saw partition changes — continuing."
}

function probe_os_from_part() {
    # inputs: $1=partition_path / outputs: sets PROBE_OS_RESULT / no other side-effects
    # Detection order: crypto_LUKS → ntfs → mount → btrfs subvols → label fallback
    local p="$1"
    PROBE_OS_RESULT=""
    local fstype; fstype=$(blkid -s TYPE -o value "$p" 2>/dev/null || echo "")

    if [[ "$fstype" == "crypto_LUKS" ]]; then PROBE_OS_RESULT="[encrypted]"; return 0; fi
    if [[ "$fstype" == "ntfs" ]]; then
        local lbl; lbl=$(blkid -s LABEL -o value "$p" 2>/dev/null || echo "")
        PROBE_OS_RESULT="${lbl:-Windows}"; return 0
    fi

    local _mnt="/tmp/archwizard_probe_$$"
    mkdir -p "$_mnt"

    _osrel() {
        local m="$1"
        [[ -f "$m/etc/os-release" ]] || return 0
        local n
        n=$(grep '^PRETTY_NAME=' "$m/etc/os-release" | cut -d= -f2- | tr -d '"' | head -1)
        [[ -z "$n" ]] && n=$(grep '^NAME=' "$m/etc/os-release" \
            | cut -d= -f2- | tr -d '"' | head -1 || true)
        printf '%s' "$n"; return 0
    }

    if mount -o ro,noexec,nosuid "$p" "$_mnt" 2>/dev/null; then
        PROBE_OS_RESULT=$(_osrel "$_mnt") || true
        umount "$_mnt" 2>/dev/null || true
        if [[ -n "$PROBE_OS_RESULT" ]]; then rmdir "$_mnt" 2>/dev/null; return 0; fi
    fi

    if [[ "$fstype" == "btrfs" ]]; then
        local sv
        for sv in @ @root root arch debian ubuntu fedora opensuse manjaro; do
            if mount -o ro,noexec,nosuid,subvol="$sv" "$p" "$_mnt" 2>/dev/null; then
                PROBE_OS_RESULT=$(_osrel "$_mnt") || true
                umount "$_mnt" 2>/dev/null || true
                if [[ -n "$PROBE_OS_RESULT" ]]; then rmdir "$_mnt" 2>/dev/null; return 0; fi
            fi
        done
    fi

    rmdir "$_mnt" 2>/dev/null || true
    local lbl; lbl=$(blkid -s LABEL -o value "$p" 2>/dev/null || echo "")
    PROBE_OS_RESULT="${lbl:-Linux (${fstype:-unknown})}"; return 0
}

# =============================================================================
#  STEP PREDICATES  (pure bash — zero gum calls)
# =============================================================================

function _step_done() {
    # inputs: $1=step_number / outputs: none / no side-effects
    # Returns 0 if step N has been completed (all required globals set), 1 otherwise.
    case "$1" in
        1) [[ "$CPU_VENDOR" != "unknown" ]]                           ;;
        2) [[ -n "$DISK_ROOT" ]]                                      ;;
        3) [[ -n "$ROOT_SIZE" ]]                                      ;;
        4) [[ "$STORAGE_CONFIGURED" == true ]]                        ;;
        5) [[ -n "$HOSTNAME" ]]                                       ;;
        6) [[ -n "$USERNAME" ]]                                       ;;
        7) [[ -n "$KERNEL" && -n "$BOOTLOADER" && ${#DESKTOPS[@]} -gt 0 ]] ;;
        8) [[ -n "$FIREWALL" ]]                                       ;;
        *) return 1 ;;
    esac
}

function _step_summary() {
    # inputs: $1=step_number / outputs: one-line summary string on stdout / no side-effects
    case "$1" in
        1)  if _step_done 1; then
                printf 'cpu:%s  gpu:%s  kbd:%s  fw:%s' \
                    "$CPU_VENDOR" "$GPU_VENDOR" "$KEYMAP" "$FIRMWARE_MODE"
            else printf 'not done'; fi ;;
        2)  if _step_done 2; then
                local s="$DISK_ROOT"
                [[ "$DISK_HOME" != "$DISK_ROOT" ]] && s+="  home:${DISK_HOME}"
                [[ "$DUAL_BOOT" == true ]] && s+="  [multi-boot]"
                printf '%s' "$s"
            else printf 'not done'; fi ;;
        3)  if _step_done 3; then
                local s="root=${ROOT_SIZE}GB"
                [[ "$SEP_HOME" == true ]] && s+="  home=${HOME_SIZE}GB"
                printf '%s' "$s"
            else printf 'not done'; fi ;;
        4)  if _step_done 4; then
                local s="${STORAGE_STACK}  root:${ROOT_FS}"
                [[ "$SEP_HOME" == true ]] && s+="  home:${HOME_FS}"
                s+="  swap:${SWAP_TYPE}"
                [[ "$USE_LUKS" == true ]] && s+="  LUKS2"
                printf '%s' "$s"
            else printf 'not done'; fi ;;
        5)  if _step_done 5; then
                printf 'host:%s  tz:%s  locale:%s' "$HOSTNAME" "$TIMEZONE" "$LOCALE"
            else printf 'not done'; fi ;;
        6)  if _step_done 6; then printf 'user:%s' "$USERNAME"
            else printf 'not done'; fi ;;
        7)  if _step_done 7; then
                local s="${KERNEL}  boot:${BOOTLOADER}  de:${DESKTOPS[*]:-none}"
                [[ "$SECURE_BOOT" == true ]] && s+="  SecureBoot"
                printf '%s' "$s"
            else printf 'not done'; fi ;;
        8)  if _step_done 8; then
                local s="fw:${FIREWALL}  aur:${AUR_HELPER}"
                [[ "$USE_PIPEWIRE"  == true ]] && s+="  pipewire"
                [[ "$USE_REFLECTOR" == true ]] && s+="  reflector"
                printf '%s' "$s"
            else printf 'not done'; fi ;;
    esac
}

# =============================================================================
#  BANNER
# =============================================================================

function show_banner() {
    # inputs: none / outputs: ASCII art banner / no side-effects
    clear
    if [[ "$NO_GUM" == true ]]; then
        printf '\033[1;35m'
        cat << 'BANNER'

  █████╗ ██████╗  ██████╗██╗  ██╗    ██╗    ██╗██╗███████╗ █████╗ ██████╗ ██████╗
 ██╔══██╗██╔══██╗██╔════╝██║  ██║    ██║    ██║██║╚══███╔╝██╔══██╗██╔══██╗██╔══██╗
 ███████║██████╔╝██║     ███████║    ██║ █╗ ██║██║  ███╔╝ ███████║██████╔╝██║  ██║
 ██╔══██║██╔══██╗██║     ██╔══██║    ██║███╗██║██║ ███╔╝  ██╔══██║██╔══██╗██║  ██║
 ██║  ██║██║  ██║╚██████╗██║  ██║    ╚███╔███╔╝██║███████╗██║  ██║██║  ██║██████╔╝
 ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝    ╚══╝╚══╝ ╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝

BANNER
        printf '\033[0m'
        printf '  ArchWizard 7.0.0-gum — Arch Linux Installer\n'
        printf '  log : %s\n' "$LOG_FILE"
        [[ "$DRY_RUN" == true ]] && printf '  mode: DRY-RUN (no disk writes)\n'
        [[ "$NO_GUM"  == true ]] && printf '  mode: NO-GUM (plain text UI)\n'
        echo ""
        return
    fi

    gum style \
        --foreground "$GUM_C_TITLE" --bold \
        --border double --border-foreground "$GUM_C_TITLE" \
        --padding "1 4" --width "$GUM_WIDTH" \
        "ARCH WIZARD  7.0.0-gum" \
        "" \
        "The most wonderful Arch Linux installer ever crafted" \
        "" \
        "log : $LOG_FILE" \
        "mode: ${DRY_RUN:+DRY-RUN }${NO_GUM:+NO-GUM}" 2>/dev/null \
    || {
        printf '\033[1;35m  ARCH WIZARD  7.0.0-gum\033[0m\n'
        printf '  log: %s\n\n' "$LOG_FILE"
    }
    echo ""
}

# =============================================================================
#  STEP FUNCTION STUBS
# =============================================================================
#  Each step_*() must:
#    - Return 0 to advance to the next step
#    - Return 1 to go back (set BACK_REQUESTED=true first via choose_one/confirm_gum)
#    - Set all globals documented in the "outputs" comment
#    - Contain ZERO gum calls directly — delegate to ui wrappers above
#
#  Stub pattern for single-choice:
#      choose_one "default" "opt1" "opt2" || return 1
#      local sel="$REPLY"
#
#  Stub pattern for confirm:
#      confirm_gum "Enable X?" "y"; local _rc=$? _back=$BACK_REQUESTED
#      [[ "$_back" == true ]] && return 1
#      (( _rc == 0 )) && FEATURE=true || FEATURE=false
#
#  TODO: port logic from archwizardGum_2_0.sh / ArchWizard_6_0.sh per step.
# =============================================================================

# ── Step 1: Environment Detection ─────────────────────────────────────────────
function step_detect() {
    # inputs: none
    # outputs: CPU_VENDOR GPU_VENDOR FIRMWARE_MODE KEYMAP
    # side-effects: loadkeys; timedatectl set-ntp true
    # note: no back from step 1 (state machine uses || true)
    section "Pre-flight Checks & Keyboard"
    # TODO: port sanity_checks() + choose_keyboard() from archwizardGum_2_0.sh
    #   1. EUID check
    #   2. Firmware detect (/sys/firmware/efi/efivars)
    #   3. Internet check + iwctl offer
    #   4. Tool availability check
    #   5. CPU/GPU vendor detect (/proc/cpuinfo, lspci)
    #   6. choose_one keyboard layout (no back needed here since step 1 has none)
    CPU_VENDOR="unknown"
    GPU_VENDOR="unknown"
    warn "step_detect: STUB — implement sanity_checks + keyboard"
    info "Faking detection for scaffold testing."
    CPU_VENDOR="amd"; GPU_VENDOR="amd"; KEYMAP="fr-latin1"
    ok "Step 1 stub complete"
    return 0
}

# ── Step 2: Disk Discovery & Selection ────────────────────────────────────────
function step_disk() {
    # inputs: FIRMWARE_MODE
    # outputs: DISK_ROOT DISK_HOME DUAL_BOOT EXISTING_SYSTEMS PROTECTED_PARTS
    #          REUSE_EFI EFI_PART FREE_GB_AVAIL REPLACE_PARTS_ALL RESIZE_PART RESIZE_NEW_GB
    section "Disk Discovery & Selection"
    # TODO: port discover_disks() + select_disks() + _check_and_plan_space()
    warn "step_disk: STUB"

    # Example of choose_one back propagation:
    choose_one "/dev/sda" \
        "/dev/sda  500GB  SSD  Samsung 870 EVO" \
        "/dev/nvme0n1  1TB  NVMe  WD Black" \
        || return 1   # ← BACK_REQUESTED=true was set by choose_one
    DISK_ROOT=$(printf '%s' "$REPLY" | awk '{print $1}')
    DISK_HOME="$DISK_ROOT"
    ok "Step 2 stub complete — disk: $DISK_ROOT"
    return 0
}

# ── Step 3: Partition Layout ──────────────────────────────────────────────────
function step_layout() {
    # inputs: DISK_ROOT DISK_HOME DUAL_BOOT FREE_GB_AVAIL
    # outputs: ROOT_SIZE HOME_SIZE SEP_HOME SWAP_TYPE SWAP_SIZE EFI_SIZE_MB
    section "Partition Layout"
    # TODO: port partition_wizard() — sizes only, NOT filesystem type (that is step 4)
    warn "step_layout: STUB"

    choose_one "/ + /home  (recommended)" \
        "/           — root takes all space" \
        "/ + /home  (recommended)" \
        "/ + /home + swap partition" \
        || return 1
    ROOT_SIZE=40; HOME_SIZE="rest"; SEP_HOME=true; SWAP_TYPE="zram"
    ok "Step 3 stub complete"
    return 0
}

# ── Step 4: Storage Stack ─────────────────────────────────────────────────────
function step_storage() {
    # inputs: ROOT_SIZE HOME_SIZE SEP_HOME
    # outputs: STORAGE_STACK ROOT_FS HOME_FS USE_LUKS LUKS_PASSWORD
    #          LVM_VG LVM_LV_ROOT LVM_LV_HOME ZFS_POOL STORAGE_CONFIGURED=true
    section "Storage Stack"
    # TODO: implement storage stack wizard covering all STORAGE_STACK variants
    # See CLAUDE.md Storage Stack Matrix for package/template mapping per stack.
    warn "step_storage: STUB"

    choose_one "btrfs  (recommended)" \
        "plain btrfs  — snapshots, compression  (recommended)" \
        "plain ext4   — most compatible" \
        "plain xfs    — high performance, cannot shrink" \
        "LUKS2 + btrfs" \
        "LUKS2 + ext4" \
        "LUKS2 + LVM + ext4" \
        || return 1

    # Parse REPLY into STORAGE_STACK and ROOT_FS
    case "$REPLY" in
        "plain btrfs"*)      STORAGE_STACK="btrfs";     ROOT_FS="btrfs" ;;
        "plain ext4"*)       STORAGE_STACK="plain";     ROOT_FS="ext4"  ;;
        "plain xfs"*)        STORAGE_STACK="plain";     ROOT_FS="xfs"   ;;
        "LUKS2 + btrfs"*)    STORAGE_STACK="luks_btrfs"; ROOT_FS="btrfs"; USE_LUKS=true ;;
        "LUKS2 + ext4"*)     STORAGE_STACK="luks";      ROOT_FS="ext4"; USE_LUKS=true ;;
        "LUKS2 + LVM + ext4"*) STORAGE_STACK="luks_lvm"; ROOT_FS="ext4"; USE_LUKS=true ;;
    esac
    HOME_FS="$ROOT_FS"

    if [[ "$USE_LUKS" == true ]]; then
        LUKS_PASSWORD=$(password_gum "LUKS2 passphrase (required at every boot)")
    fi

    STORAGE_CONFIGURED=true  # marks step 4 as done for _step_done(4)
    ok "Step 4 stub complete — stack:${STORAGE_STACK}  root:${ROOT_FS}  luks:${USE_LUKS}"
    return 0
}

# ── Step 5: System Identity ───────────────────────────────────────────────────
function step_identity() {
    # inputs: none
    # outputs: HOSTNAME GRUB_ENTRY_NAME TIMEZONE LOCALE KEYMAP
    section "System Identity"
    # TODO: port configure_system() from archwizardGum_2_0.sh
    # Note: KEYMAP is also set in step_detect; step_identity can refine it.
    warn "step_identity: STUB"

    HOSTNAME=$(input_gum "Hostname" "archlinux")
    # input_gum has no back; the choose_one for timezone gives us the back path
    choose_one "Europe/Paris" \
        "Europe/Paris" "Europe/London" "Europe/Berlin" \
        "America/New_York" "America/Los_Angeles" \
        "Asia/Tokyo" "UTC" "Other (type manually)" \
        || return 1
    if [[ "$REPLY" == "Other (type manually)" ]]; then
        TIMEZONE=$(input_gum "Timezone (e.g. America/Chicago)" "UTC")
    else
        TIMEZONE="$REPLY"
    fi

    choose_one "fr_FR.UTF-8" \
        "en_US.UTF-8" "en_GB.UTF-8" "fr_FR.UTF-8" \
        "de_DE.UTF-8" "es_ES.UTF-8" "it_IT.UTF-8" "Other" \
        || return 1
    if [[ "$REPLY" == "Other" ]]; then
        LOCALE=$(input_gum "Locale (e.g. pt_BR.UTF-8)" "en_US.UTF-8")
    else
        LOCALE="$REPLY"
    fi

    GRUB_ENTRY_NAME="Arch Linux (${HOSTNAME})"
    ok "Step 5 stub complete — host:${HOSTNAME}  tz:${TIMEZONE}  locale:${LOCALE}"
    return 0
}

# ── Step 6: User Accounts ─────────────────────────────────────────────────────
function step_users() {
    # inputs: none
    # outputs: USERNAME USER_PASSWORD ROOT_PASSWORD
    # !crash: passwords never in argv — stored in globals, piped to chpasswd inside chroot
    section "User Accounts"
    # TODO: port configure_users() from archwizardGum_2_0.sh including username validation
    warn "step_users: STUB"

    USERNAME=$(input_gum "Username (lowercase letters, digits, _ -)" "archuser")
    # Back path: if user somehow got here and wants back, they re-run from step 5.
    # input_gum has no back — username is always required. Keyboard-navigate with step machine.

    USER_PASSWORD=$(password_gum "Password for '${USERNAME}'")
    ROOT_PASSWORD=$(password_gum "Root password")
    ok "Step 6 stub complete — user:${USERNAME}"
    return 0
}

# ── Step 7: Software Selection (kernel + bootloader + DE + extras) ────────────
function step_software() {
    # inputs: FIRMWARE_MODE DUAL_BOOT GPU_VENDOR ROOT_FS
    # outputs: KERNEL BOOTLOADER SECURE_BOOT DESKTOPS AUR_HELPER
    #          USE_REFLECTOR USE_MULTILIB USE_PIPEWIRE USE_NVIDIA USE_AMD_VULKAN
    #          USE_BLUETOOTH USE_CUPS USE_SNAPPER FIREWALL REFLECTOR_COUNTRIES
    section "Software Selection"
    # TODO: port choose_kernel_bootloader() + choose_desktop() + choose_extras()
    warn "step_software: STUB"

    # Kernel
    choose_one "linux  — latest stable" \
        "linux          — latest stable" \
        "linux-lts      — long-term support" \
        "linux-zen      — desktop optimised" \
        "linux-hardened — security hardened" \
        || return 1
    KERNEL="${REPLY%% *}"

    # Bootloader
    choose_one "GRUB  — recommended" \
        "GRUB           — recommended (os-prober, multi-boot)" \
        "systemd-boot   — minimal, single-OS installs only" \
        || return 1
    case "${REPLY%% *}" in
        GRUB)         BOOTLOADER="grub" ;;
        systemd-boot) BOOTLOADER="systemd-boot" ;;
    esac

    # Desktop
    choose_many "" \
        "KDE Plasma" "GNOME" "Hyprland" "Sway" "COSMIC" "XFCE" "None / TTY" \
        || return 1
    if [[ -z "$REPLY" ]]; then
        DESKTOPS=("none")
    else
        mapfile -t DESKTOPS <<< "$REPLY"
    fi

    # Firewall
    choose_one "nftables  — recommended" \
        "nftables  — recommended" \
        "ufw       — simpler CLI" \
        "None      — no firewall" \
        || return 1
    case "${REPLY%% *}" in
        nftables) FIREWALL="nftables" ;;
        ufw)      FIREWALL="ufw"      ;;
        None)     FIREWALL="none"     ;;
    esac

    # AUR helper
    choose_one "paru-bin  — recommended" \
        "paru-bin  — pre-built, installs in seconds (recommended)" \
        "paru      — compiled from source" \
        "yay       — Go-based, most popular" \
        "None      — no AUR helper" \
        || return 1
    AUR_HELPER="${REPLY%% *}"
    [[ "$AUR_HELPER" == "None" ]] && AUR_HELPER="none"

    # PipeWire
    confirm_gum "Install PipeWire? (modern audio, replaces PulseAudio)" "y"
    local _rc=$? _back=$BACK_REQUESTED
    [[ "$_back" == true ]] && return 1
    (( _rc == 0 )) && USE_PIPEWIRE=true || USE_PIPEWIRE=false

    ok "Step 7 stub complete — kernel:${KERNEL}  boot:${BOOTLOADER}  de:${DESKTOPS[*]}"
    return 0
}

# ── Step 8: Summary & Final Confirmation (LAST SAFE EXIT) ────────────────────
function step_summary() {
    # inputs: all globals / outputs: none / side-effects: exits 0 if user aborts
    # !crash: nothing destructive before this function returns 0
    section "Installation Summary — Last Safe Exit"
    # TODO: port show_summary() from archwizardGum_2_0.sh — full table of all choices

    warn "After confirmation your disk(s) will be permanently modified."
    blank

    # Minimal summary for stub — replace with full table in implementation
    local summary_lines=(
        "$(_clr "$GUM_C_ACCENT" "  DISKS")"
        "  Root disk : $(_clr "$GUM_C_INFO" "$DISK_ROOT")"
        "  Root size : $(_clr "$GUM_C_INFO" "${ROOT_SIZE}GB  [${ROOT_FS}]")"
        "  Swap      : $(_clr "$GUM_C_INFO" "$SWAP_TYPE")"
        "  LUKS      : $(_clr "$GUM_C_INFO" "$USE_LUKS")"
        ""
        "$(_clr "$GUM_C_ACCENT" "  SYSTEM")"
        "  Hostname  : $(_clr "$GUM_C_INFO" "$HOSTNAME")"
        "  Timezone  : $(_clr "$GUM_C_INFO" "$TIMEZONE")"
        "  Locale    : $(_clr "$GUM_C_INFO" "$LOCALE")"
        "  User      : $(_clr "$GUM_C_INFO" "$USERNAME")"
        ""
        "$(_clr "$GUM_C_ACCENT" "  SOFTWARE")"
        "  Kernel    : $(_clr "$GUM_C_INFO" "$KERNEL")"
        "  Bootloader: $(_clr "$GUM_C_INFO" "$BOOTLOADER")"
        "  Desktop   : $(_clr "$GUM_C_INFO" "${DESKTOPS[*]:-none}")"
        "  Firewall  : $(_clr "$GUM_C_INFO" "$FIREWALL")"
        "  AUR       : $(_clr "$GUM_C_INFO" "$AUR_HELPER")"
    )

    if [[ "$NO_GUM" == true ]]; then
        local line
        for line in "${summary_lines[@]}"; do printf '  %s\n' "$line"; done
    else
        gum style \
            --border rounded --border-foreground "$GUM_C_TITLE" \
            --padding "0 1" --width "$GUM_WIDTH" \
            "${summary_lines[@]}" 2>/dev/null \
        || { local l; for l in "${summary_lines[@]}"; do printf '%s\n' "$l"; done; }
    fi
    blank

    # The back option here lets the user revise any choice before committing
    confirm_gum "Begin installation? (IRREVERSIBLE after this point)" "n"
    local _rc=$? _back=$BACK_REQUESTED
    if [[ "$_back" == true ]]; then return 1; fi  # user wants to revise — go back to step 7
    if (( _rc != 0 )); then
        blank; info "Aborted — no changes made."; exit 0
    fi
    return 0
}

# =============================================================================
#  INSTALLATION EXECUTOR  (Phase 10-15 — all destructive, all irreversible)
# =============================================================================

function exec_install() {
    # inputs: all globals / outputs: installed Arch Linux system
    # ⚠ DESTRUCTIVE: partition, format, pacstrap, chroot config, bootloader
    # !crash: called only after step_summary confirmed — LAST SAFE EXIT has passed
    section "Installation"
    # TODO: port all Phase 3-6 functions from archwizardGum_2_0.sh:
    #   Phase 10: replace_partition + resize_partitions + create_partitions
    #   Phase 11: setup_luks + format_filesystems + create_subvolumes + mount_filesystems
    #   Phase 12: setup_mirrors + install_base
    #   Phase 13: _serialize_chroot_vars + cp template + arch-chroot
    #   Phase 14: (handled inside chroot template)
    #   Phase 15: verify_installation + finish
    warn "exec_install: STUB — no disk operations in this infrastructure version."
    ok "exec_install stub reached — all wizard steps completed successfully."
}

# =============================================================================
#  STEP STATE MACHINE
# =============================================================================
#
#  Sequential wizard with full back navigation.
#  Each step_*() returns 0 (advance) or 1 (← Back selected, go back one step).
#  Step 1 has no back: || true keeps STEP=1, repeating the step (acceptable UX
#  since step 1 is mostly auto-detection with one keyboard choice at the end).
#
#  The || STEP=N pattern is safe under set -e because STEP=N is an assignment
#  (exit code 0), and the overall case arm always evaluates to 0.
#
#  Banner is shown once at entry; steps use section() for visual separation.
# =============================================================================

function main_menu() {
    # inputs: all globals (previously loaded or default) / outputs: completed install
    show_banner
    local STEP=1
    while true; do
        case $STEP in
            1) step_detect   && STEP=2 || true       ;;  # no back from step 1
            2) step_disk     && STEP=3 || STEP=1     ;;
            3) step_layout   && STEP=4 || STEP=2     ;;
            4) step_storage  && STEP=5 || STEP=3     ;;
            5) step_identity && STEP=6 || STEP=4     ;;
            6) step_users    && STEP=7 || STEP=5     ;;
            7) step_software && STEP=8 || STEP=6     ;;
            8) step_summary  && STEP=9 || STEP=7     ;;
            9) exec_install; break                   ;;  # no back after confirm
            *) break ;;
        esac
    done
}

# =============================================================================
#  CONFIG SAVE / LOAD
# =============================================================================

function save_config() {
    # inputs: all globals / outputs: config file at chosen path / no side-effects
    section "Save Configuration"
    warn "Config file contains passwords in plaintext — store securely and delete after use."
    blank

    confirm_gum "Save configuration to file?" "y"
    local _rc=$? _back=$BACK_REQUESTED
    # Back from save_config just skips saving — no reason to propagate upward
    [[ "$_back" == true || "$_rc" != 0 ]] && return 0

    local default_path="/tmp/archwizard_config_$(date +%Y%m%d_%H%M%S).sh"
    local cfg_path; cfg_path=$(input_gum "Save to" "$default_path")

    # Unquoted EOF: variables expand at write-time — intentional, see CLAUDE.md
    cat > "$cfg_path" << CFGEOF
#!/usr/bin/env bash
# ArchWizard 7.0.0-gum saved configuration — $(date '+%Y-%m-%d %H:%M:%S')
# Usage: bash archwizardGum_7_0.sh --load-config $(basename "$cfg_path")
# WARNING: contains passwords in plaintext — delete or encrypt when done.

CPU_VENDOR="${CPU_VENDOR}"
GPU_VENDOR="${GPU_VENDOR}"
FIRMWARE_MODE="${FIRMWARE_MODE}"
DISK_ROOT="${DISK_ROOT}"
DISK_HOME="${DISK_HOME}"
EFI_PART="${EFI_PART}"
EFI_SIZE_MB="${EFI_SIZE_MB}"
ROOT_SIZE="${ROOT_SIZE}"
HOME_SIZE="${HOME_SIZE}"
SEP_HOME="${SEP_HOME}"
SWAP_TYPE="${SWAP_TYPE}"
SWAP_SIZE="${SWAP_SIZE}"
DUAL_BOOT="${DUAL_BOOT}"
REUSE_EFI="${REUSE_EFI}"
STORAGE_STACK="${STORAGE_STACK}"
STORAGE_CONFIGURED="${STORAGE_CONFIGURED}"
ROOT_FS="${ROOT_FS}"
HOME_FS="${HOME_FS}"
USE_LUKS="${USE_LUKS}"
LUKS_PASSWORD="${LUKS_PASSWORD}"
LVM_VG="${LVM_VG}"
LVM_LV_ROOT="${LVM_LV_ROOT}"
LVM_LV_HOME="${LVM_LV_HOME}"
ZFS_POOL="${ZFS_POOL}"
HOSTNAME="${HOSTNAME}"
GRUB_ENTRY_NAME="${GRUB_ENTRY_NAME}"
USERNAME="${USERNAME}"
USER_PASSWORD="${USER_PASSWORD}"
ROOT_PASSWORD="${ROOT_PASSWORD}"
TIMEZONE="${TIMEZONE}"
LOCALE="${LOCALE}"
KEYMAP="${KEYMAP}"
KERNEL="${KERNEL}"
BOOTLOADER="${BOOTLOADER}"
SECURE_BOOT="${SECURE_BOOT}"
DESKTOPS=(${DESKTOPS[@]+"${DESKTOPS[@]}"})
AUR_HELPER="${AUR_HELPER}"
USE_REFLECTOR="${USE_REFLECTOR}"
REFLECTOR_COUNTRIES="${REFLECTOR_COUNTRIES}"
REFLECTOR_NUMBER="${REFLECTOR_NUMBER}"
REFLECTOR_AGE="${REFLECTOR_AGE}"
USE_MULTILIB="${USE_MULTILIB}"
USE_PIPEWIRE="${USE_PIPEWIRE}"
USE_NVIDIA="${USE_NVIDIA}"
USE_AMD_VULKAN="${USE_AMD_VULKAN}"
USE_BLUETOOTH="${USE_BLUETOOTH}"
USE_CUPS="${USE_CUPS}"
USE_SNAPPER="${USE_SNAPPER}"
FIREWALL="${FIREWALL}"
CFGEOF

    chmod 600 "$cfg_path"
    ok "Config saved → ${cfg_path}"
    warn "Delete this file when you no longer need it."
}

function load_config() {
    # inputs: $1=path to config file / outputs: all globals from file / side-effects: source
    # !crash: source of untrusted config — TODO: add variable validation before full use
    local cfg="$1"
    [[ ! -f "$cfg" ]] && die "Config file not found: ${cfg}"
    info "Loading config: ${cfg}"
    # shellcheck source=/dev/null
    source "$cfg"
    ok "Config loaded — wizard steps will be skipped; jumping to confirmation."
}

# =============================================================================
#  GUM PREFLIGHT
# =============================================================================

function _check_gum() {
    # inputs: NO_GUM / outputs: may set NO_GUM=true / no other side-effects
    # Auto-falls back to NO_GUM mode rather than dying if gum is absent.
    if [[ "$NO_GUM" == false ]] && ! command -v gum &>/dev/null; then
        printf '\n\033[1;33m[WARN]\033[0m  gum not found — switching to plain-text mode.\n'
        printf '        Install: pacman -Sy gum  |  or pass: --no-gum\n\n'
        NO_GUM=true
    fi
}

# =============================================================================
#  ARGUMENT PARSING
# =============================================================================

function parse_args() {
    # inputs: "$@" / outputs: DRY_RUN VERBOSE NO_GUM CONFIG_FILE / no side-effects
    local _prev=""
    local arg
    for arg in "$@"; do
        case "$arg" in
            --dry-run)      DRY_RUN=true    ;;
            --verbose)      VERBOSE=true    ;;
            --no-gum)       NO_GUM=true     ;;
            --load-config)  :               ;;   # next token is the file
            --help|-h)
                cat << 'HELP'

Usage: bash archwizardGum_7_0.sh [OPTIONS]

  --dry-run           Print all commands without executing (no disk writes)
  --verbose           Enable set -x tracing throughout
  --no-gum            Plain read/echo UI (no gum required — works over SSH/CI)
  --load-config FILE  Load saved config, skip the wizard, jump to confirmation
  --help              This message

HELP
                exit 0 ;;
            *)  [[ "$_prev" == "--load-config" ]] && CONFIG_FILE="$arg" ;;
        esac
        _prev="$arg"
    done
    if [[ "$VERBOSE" == true ]]; then set -x; fi
}

# =============================================================================
#  ENTRY POINT
# =============================================================================

function main() {
    # inputs: "$@" / outputs: installed Arch Linux (or dry-run output)
    parse_args "$@"
    _check_gum

    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN mode: no disk writes will occur."
    [[ "$NO_GUM"  == true ]] && warn "NO-GUM mode: plain-text UI active."

    if [[ -n "$CONFIG_FILE" ]]; then
        # Config path: skip wizard, jump straight to confirmation then install
        show_banner
        load_config "$CONFIG_FILE"
        step_summary || { info "Aborted."; exit 0; }
        exec_install
    else
        # Normal path: full sequential wizard
        main_menu
    fi
}

main "$@"
