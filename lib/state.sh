#!/usr/bin/env bash
# =============================================================================
#  lib/state.sh — Step state machine, navigation, config save/load
#
#  Two navigation modes, both share the same _step_run_N() wrappers:
#
#    main_menu()   — jump-to-any-step; user can re-run steps in any order.
#    _linear_run() — sequential wizard with back navigation; called from
#                    main_menu when user picks "Run wizard".
#
#  Step return codes (from _step_run_N functions):
#    0  → step completed, advance
#    1  → user chose ← Back, go to previous step
#
#  Crash patterns respected throughout:
#    - Never [[ ]] && cmd under set -e  → always if/then/fi
#    - Never "${A[@]}" on empty array   → always "${A[@]+"${A[@]}"}"
#    - No gum calls here                → only calls through lib/ui.sh wrappers
# =============================================================================

# The back sentinel — single constant, used in every choose_one that supports back.
# choose_one() echoes this string when the user presses Esc/q in gum.
readonly BACK="← Back"

# Set to true by _linear_run(); false in main_menu().
# Step runners use this to decide whether to offer Skip/Back on already-done steps.
_IN_LINEAR_WIZARD=false

# Current step in linear wizard (1-indexed). Persists across _linear_run calls
# so "Run wizard" always resumes from the right place.
STEP=1

# =============================================================================
#  Step predicates — pure functions, read globals only, set nothing
# =============================================================================

# _step_done N → returns 0 if step N has its required globals set, 1 otherwise
function _step_done() {
    # inputs: step_number / outputs: exit code
    case "$1" in
        1) [[ "$CPU_VENDOR" != "unknown" && -n "${KEYMAP:-}" ]] ;;
        2) [[ -n "${DISK_ROOT:-}" ]] ;;
        3) [[ -n "${STORAGE_STACK:-}" ]] ;;
        4) [[ -n "${ROOT_SIZE:-}" ]] ;;
        5) [[ -n "${HOSTNAME:-}" && -n "${LOCALE:-}" && -n "${TIMEZONE:-}" ]] ;;
        6) [[ -n "${USERNAME:-}" && -n "${USER_PASSWORD:-}" ]] ;;
        7) [[ -n "${KERNEL:-}" && -n "${BOOTLOADER:-}" ]] ;;
        8) [[ "${#DESKTOPS[@]}" -gt 0 || -n "${FIREWALL:-}" ]] ;;
        *) return 1 ;;
    esac
}

# _step_desc N → prints the short human description of step N
function _step_desc() {
    # inputs: step_number / outputs: string to stdout
    case "$1" in
        1) echo "Environment & keyboard" ;;
        2) echo "Disk discovery & selection" ;;
        3) echo "Storage stack" ;;
        4) echo "Partition layout" ;;
        5) echo "System identity" ;;
        6) echo "User accounts" ;;
        7) echo "Kernel & bootloader" ;;
        8) echo "Desktop & extras" ;;
        *) echo "Unknown step" ;;
    esac
}

# _step_summary N → prints one-line choices summary for step N
function _step_summary() {
    # inputs: step_number / outputs: summary string to stdout
    local s=""
    case "$1" in
        1)
            if _step_done 1; then
                printf 'cpu:%s  gpu:%s  kbd:%s  fw:%s' \
                    "$CPU_VENDOR" "$GPU_VENDOR" "$KEYMAP" "$FIRMWARE_MODE"
            else
                printf 'not done'
            fi ;;
        2)
            if _step_done 2; then
                s="$DISK_ROOT"
                if [[ "$DISK_HOME" != "$DISK_ROOT" ]]; then s+="  home:${DISK_HOME}"; fi
                if [[ "$DUAL_BOOT" == true ]]; then s+="  [multi-boot]"; fi
                printf '%s' "$s"
            else
                printf 'not done'
            fi ;;
        3)
            if _step_done 3; then
                s="${STORAGE_STACK}"
                if [[ "${USE_LUKS:-false}" == true ]]; then s+="  [LUKS2]"; fi
                printf '%s' "$s"
            else
                printf 'not done'
            fi ;;
        4)
            if _step_done 4; then
                s="root=${ROOT_SIZE}GB [${ROOT_FS}]"
                if [[ "${SEP_HOME:-false}" == true ]]; then
                    s+="  home=${HOME_SIZE}GB [${HOME_FS}]"
                fi
                s+="  swap=${SWAP_TYPE}"
                printf '%s' "$s"
            else
                printf 'not done'
            fi ;;
        5)
            if _step_done 5; then
                printf '%s  tz:%s  %s' "$HOSTNAME" "$TIMEZONE" "$LOCALE"
            else
                printf 'not done'
            fi ;;
        6)
            if _step_done 6; then
                printf 'user:%s' "$USERNAME"
            else
                printf 'not done'
            fi ;;
        7)
            if _step_done 7; then
                s="${KERNEL}  boot:${BOOTLOADER}"
                if [[ "${SECURE_BOOT:-false}" == true ]]; then s+="  [SecureBoot]"; fi
                printf '%s' "$s"
            else
                printf 'not done'
            fi ;;
        8)
            if _step_done 8; then
                s="${DESKTOPS[*]:-none}"
                s+="  fw:${FIREWALL:-none}"
                if [[ "${USE_PIPEWIRE:-false}" == true ]];  then s+="  pipewire"; fi
                if [[ "${USE_REFLECTOR:-false}" == true ]]; then s+="  reflector"; fi
                printf '%s' "$s"
            else
                printf 'not done'
            fi ;;
        *)
            printf 'unknown' ;;
    esac
}

# _step_prereq N → returns 0 if all prerequisite steps for N are done, 1 otherwise
# Called before menu jumps to avoid running steps out of order.
function _step_prereq() {
    # inputs: step_number / outputs: exit code
    case "$1" in
        1) return 0 ;;                    # No prereqs
        2) return 0 ;;                    # Can always discover disks
        3) _step_done 2 ;;               # Need disk selected for storage stack
        4) _step_done 3 ;;               # Need storage stack for layout
        5) return 0 ;;                    # Identity independent
        6) return 0 ;;                    # Users independent
        7) return 0 ;;                    # Kernel/boot independent
        8) return 0 ;;                    # Extras independent
        *) return 1 ;;
    esac
}

# =============================================================================
#  Menu entry builder
# =============================================================================

# _menu_entry N → prints a formatted menu line with tick and summary
function _menu_entry() {
    # inputs: step_number / outputs: formatted label string
    local n="$1"
    local desc summary tick sum_col

    desc=$(_step_desc "$n")
    summary=$(_step_summary "$n")

    if _step_done "$n"; then
        tick=$(_clr "$GUM_C_OK"  "✔")
        sum_col=$(_clr "$GUM_C_DIM" "$summary")
    else
        tick=$(_clr "$GUM_C_DIM" "·")
        sum_col=$(_clr "$GUM_C_ERR" "not done")
    fi

    printf ' %s  Step %s — %-32s%s' "$tick" "$n" "$desc" "$sum_col"
}

# =============================================================================
#  Step header — shown at the start of each step in both modes
# =============================================================================

function _step_header() {
    # inputs: step_number / side-effects: prints header to stdout
    local n="$1"
    section "Step ${n}/8 — $(_step_desc "$n")"
    if _step_done "$n"; then
        info "Current: $(_step_summary "$n")"
        blank
    fi
}

# =============================================================================
#  Navigation prompt — shown for already-done steps in linear mode
#  Returns 0 (continue/re-run), 1 (go back)
# =============================================================================

function _nav_prompt() {
    # inputs: step_number / outputs: exit code 0=continue 1=back
    local n="$1"
    local current summary choice

    summary=$(_step_summary "$n")

    if [[ "${NO_GUM:-false}" == false ]]; then
        gum style \
            --border        rounded \
            --border-foreground "$GUM_C_DIM" \
            --padding       "0 2" \
            --width         "$GUM_WIDTH" \
            "$(_clr "$GUM_C_OK" "  Already done:")" \
            "$(_clr "$GUM_C_DIM" "  $summary")" 2>/dev/null || true
        blank
    else
        info "Already done: $summary"
    fi

    choice=$(choose_one \
        "Skip — keep current choices" \
        "Skip — keep current choices" \
        "Re-run this step" \
        "$BACK")

    if [[ "$choice" == "$BACK" ]]; then return 1; fi
    if [[ "$choice" == "Skip"* ]]; then return 0; fi
    return 0  # Re-run falls through; caller proceeds to phase functions
}

# =============================================================================
#  Step runner functions — one per questionnaire step
#  Each: shows header, optionally nav prompt, calls phase function(s)
#  Returns 0 (advance) or 1 (go back)
# =============================================================================

function _step_run_1() {
    # inputs: none / side-effects: sets CPU/GPU/KEYMAP/FIRMWARE via phase fns
    _step_header 1
    # Step 1 has no back (no prior step). Re-run is always allowed.
    sanity_checks   || return 0   # die() on fatal — no back
    choose_keyboard || return 0
    return 0
}

function _step_run_2() {
    # inputs: none / side-effects: sets DISK_ROOT DISK_HOME DUAL_BOOT etc
    _step_header 2
    if [[ "$_IN_LINEAR_WIZARD" == true ]] && _step_done 2; then
        _nav_prompt 2 || return 1
    fi
    discover_disks || return 0
    select_disks   || return 0
    return 0
}

function _step_run_3() {
    # inputs: none / side-effects: sets STORAGE_STACK USE_LUKS
    _step_header 3
    if [[ "$_IN_LINEAR_WIZARD" == true ]] && _step_done 3; then
        _nav_prompt 3 || return 1
    fi
    storage_wizard || return 0
    return 0
}

function _step_run_4() {
    # inputs: none / side-effects: sets ROOT_SIZE HOME_SIZE ROOT_FS etc
    _step_header 4
    if [[ "$_IN_LINEAR_WIZARD" == true ]] && _step_done 4; then
        _nav_prompt 4 || return 1
    fi
    partition_wizard || return 0
    return 0
}

function _step_run_5() {
    # inputs: none / side-effects: sets HOSTNAME TIMEZONE LOCALE GRUB_ENTRY_NAME
    _step_header 5
    if [[ "$_IN_LINEAR_WIZARD" == true ]] && _step_done 5; then
        _nav_prompt 5 || return 1
    fi
    configure_system || return 0
    return 0
}

function _step_run_6() {
    # inputs: none / side-effects: sets USERNAME USER_PASSWORD ROOT_PASSWORD
    _step_header 6
    if [[ "$_IN_LINEAR_WIZARD" == true ]] && _step_done 6; then
        _nav_prompt 6 || return 1
    fi
    configure_users || return 0
    return 0
}

function _step_run_7() {
    # inputs: none / side-effects: sets KERNEL BOOTLOADER SECURE_BOOT
    _step_header 7
    if [[ "$_IN_LINEAR_WIZARD" == true ]] && _step_done 7; then
        _nav_prompt 7 || return 1
    fi
    choose_kernel_bootloader || return 0
    return 0
}

function _step_run_8() {
    # inputs: none / side-effects: sets DESKTOPS AUR_HELPER USE_* FIREWALL
    _step_header 8
    if [[ "$_IN_LINEAR_WIZARD" == true ]] && _step_done 8; then
        _nav_prompt 8 || return 1
    fi
    choose_desktop || return 0
    choose_extras  || return 0
    return 0
}

# =============================================================================
#  _exec_install — all destructive phases; called only after Phase 9 confirm
# =============================================================================

function _exec_install() {
    # inputs: all globals from steps 1-8 / side-effects: WRITES TO DISK ⚠

    # Phase 10 — partition execution
    replace_partition
    resize_partitions
    create_partitions

    # Phase 11 — format + mount
    setup_luks
    format_filesystems
    create_subvolumes
    mount_filesystems

    # Phase 12 — base install
    setup_mirrors
    install_base

    # Phase 13 — chroot configuration
    bootloader_pre_chroot       # EFI guard + Secure Boot prep (host-side)
    generate_chroot_script
    run_chroot
    bootloader_post_chroot      # Fallback EFI binary + NVRAM check (host-side)

    # Phase 14 — dotfiles (optional, /mnt still mounted)
    deploy_dotfiles

    # Phase 15 — verify + done
    verify_installation
    finish
}

# =============================================================================
#  _linear_run — sequential wizard with back navigation
#  Finds the first incomplete step and runs forward from there.
#  Back at step 1 = returns to main_menu.
# =============================================================================

function _linear_run() {
    # inputs: none / side-effects: sets STEP global, drives wizard forward
    _IN_LINEAR_WIZARD=true

    # If called fresh or via menu, jump to first incomplete step.
    # If all done, land on summary.
    local found=false
    local s
    for s in 1 2 3 4 5 6 7 8; do
        if ! _step_done "$s"; then
            STEP=$s
            found=true
            break
        fi
    done
    if [[ "$found" == false ]]; then
        STEP=9   # Summary/confirm
    fi

    while true; do
        case "$STEP" in
            1)
                if _step_run_1; then
                    STEP=2
                fi
                # No back from step 1: stay at 1 until it succeeds.
                ;;
            2)
                if _step_run_2; then
                    STEP=3
                else
                    # Back from step 2 → exit linear mode to menu
                    _IN_LINEAR_WIZARD=false
                    return 0
                fi
                ;;
            3|4|5|6|7|8)
                if _step_run_"$STEP"; then
                    STEP=$(( STEP + 1 ))
                else
                    STEP=$(( STEP - 1 ))
                fi
                ;;
            9)
                save_config
                if show_summary; then
                    _exec_install
                    _IN_LINEAR_WIZARD=false
                    return 0
                else
                    STEP=8
                fi
                ;;
            *)
                _IN_LINEAR_WIZARD=false
                return 0
                ;;
        esac
    done
}

# =============================================================================
#  main_menu — jump-to-any-step menu; top-level entry point
# =============================================================================

function main_menu() {
    # inputs: none / side-effects: interactive loop driving all phases
    show_banner

    while true; do
        local entries=()
        local n
        for n in 1 2 3 4 5 6 7 8; do
            entries+=("$(_menu_entry "$n")")
        done
        entries+=("────────────────────────────────────────────────────")
        entries+=("  ▶  Run wizard  (linear, with back navigation)")
        entries+=("  ✗  Quit")

        local choice
        choice=$(choose_one "" "${entries[@]}")

        case "$choice" in
            *"Step 1"*)
                _step_run_1
                ;;
            *"Step 2"*)
                _step_run_2
                ;;
            *"Step 3"*)
                if ! _step_prereq 3; then
                    warn "Complete Step 2 (disk selection) first."
                    _pause_for_menu
                    continue
                fi
                _step_run_3
                ;;
            *"Step 4"*)
                if ! _step_prereq 4; then
                    warn "Complete Step 3 (storage stack) first."
                    _pause_for_menu
                    continue
                fi
                _step_run_4
                ;;
            *"Step 5"*) _step_run_5 ;;
            *"Step 6"*) _step_run_6 ;;
            *"Step 7"*) _step_run_7 ;;
            *"Step 8"*) _step_run_8 ;;
            *"Run wizard"*)
                _linear_run
                ;;
            *"Quit"*|"─"*|"$BACK")
                blank
                info "Quit — no changes made."
                exit 0
                ;;
        esac

        _pause_for_menu
    done
}

# _pause_for_menu — brief pause before redrawing menu
function _pause_for_menu() {
    # inputs: none / side-effects: waits for keypress
    blank
    if [[ "${NO_GUM:-false}" == true ]]; then
        printf ' › Press Enter to return to menu... ' >&2
        read -r _
        return 0
    fi
    gum confirm \
        --affirmative       "Back to menu" \
        --negative          "" \
        --prompt.foreground "$GUM_C_DIM" \
        "  Press Enter to return to menu" 2>/dev/null || true
}

# =============================================================================
#  save_config — serializes all globals to a shell file
#  Uses unquoted heredoc so variables expand at write-time.
# =============================================================================

function save_config() {
    # inputs: all globals / side-effects: writes config file to disk
    blank
    section "Save Configuration"

    if [[ "${NO_GUM:-false}" == false ]]; then
        gum style \
            --border        normal \
            --border-foreground "$GUM_C_DIM" \
            --padding       "0 2" \
            --width         "$GUM_WIDTH" \
            "$(_clr "$GUM_C_INFO" "  Replay this install on another machine.")" \
            "$(_clr "$GUM_C_WARN" "  WARNING: file contains passwords in plaintext.")" \
            2>/dev/null || true
        blank
    fi

    confirm_gum "Save configuration to file?" || return 0

    local default_path="/tmp/archwizard_${HOSTNAME:-config}_$(date +%Y%m%d_%H%M%S).sh"
    local cfg_path
    cfg_path=$(input_gum "Save path" "$default_path")
    [[ -z "$cfg_path" ]] && cfg_path="$default_path"

    # Unquoted EOF: variables expand at write-time (this is intentional).
    cat > "$cfg_path" << EOF
#!/usr/bin/env bash
# ArchWizard saved configuration — $(date '+%Y-%m-%d %H:%M:%S')
# Usage: bash archwizard.sh --load-config $(basename "$cfg_path")
# WARNING: contains passwords in plaintext. chmod 600 or delete when done.

CPU_VENDOR="${CPU_VENDOR:-unknown}"
GPU_VENDOR="${GPU_VENDOR:-unknown}"
FIRMWARE_MODE="${FIRMWARE_MODE:-uefi}"

DISK_ROOT="${DISK_ROOT:-}"
DISK_HOME="${DISK_HOME:-}"
EFI_PART="${EFI_PART:-}"
EFI_SIZE_MB="${EFI_SIZE_MB:-512}"
ROOT_SIZE="${ROOT_SIZE:-}"
HOME_SIZE="${HOME_SIZE:-}"
SEP_HOME=${SEP_HOME:-false}
ROOT_FS="${ROOT_FS:-btrfs}"
HOME_FS="${HOME_FS:-btrfs}"
STORAGE_STACK="${STORAGE_STACK:-plain}"
SWAP_TYPE="${SWAP_TYPE:-zram}"
SWAP_SIZE="${SWAP_SIZE:-8}"
DUAL_BOOT=${DUAL_BOOT:-false}
REUSE_EFI=${REUSE_EFI:-false}
USE_LUKS=${USE_LUKS:-false}
LUKS_PASSWORD="${LUKS_PASSWORD:-}"
LVM_VG="${LVM_VG:-arch_vg}"
LVM_LV_ROOT="${LVM_LV_ROOT:-root}"
LVM_LV_HOME="${LVM_LV_HOME:-home}"
ZFS_POOL="${ZFS_POOL:-zroot}"

FREE_GB_AVAIL=${FREE_GB_AVAIL:-0}
EXISTING_WINDOWS=${EXISTING_WINDOWS:-false}
EXISTING_LINUX=${EXISTING_LINUX:-false}
EXISTING_SYSTEMS=(${EXISTING_SYSTEMS[@]+"${EXISTING_SYSTEMS[@]}"})
PROTECTED_PARTS=(${PROTECTED_PARTS[@]+"${PROTECTED_PARTS[@]}"})
REPLACE_PARTS_ALL=(${REPLACE_PARTS_ALL[@]+"${REPLACE_PARTS_ALL[@]}"})
REPLACE_PART="${REPLACE_PART:-}"
RESIZE_PART="${RESIZE_PART:-}"
RESIZE_NEW_GB=${RESIZE_NEW_GB:-0}

HOSTNAME="${HOSTNAME:-}"
GRUB_ENTRY_NAME="${GRUB_ENTRY_NAME:-}"
USERNAME="${USERNAME:-}"
USER_PASSWORD="${USER_PASSWORD:-}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
TIMEZONE="${TIMEZONE:-UTC}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-us}"

KERNEL="${KERNEL:-linux}"
BOOTLOADER="${BOOTLOADER:-}"
SECURE_BOOT=${SECURE_BOOT:-false}
DESKTOPS=(${DESKTOPS[@]+"${DESKTOPS[@]}"})
AUR_HELPER="${AUR_HELPER:-none}"
USE_REFLECTOR=${USE_REFLECTOR:-false}
REFLECTOR_COUNTRIES="${REFLECTOR_COUNTRIES:-France,Germany}"
REFLECTOR_NUMBER="${REFLECTOR_NUMBER:-10}"
REFLECTOR_AGE="${REFLECTOR_AGE:-12}"
REFLECTOR_PROTOCOL="${REFLECTOR_PROTOCOL:-https}"
USE_MULTILIB=${USE_MULTILIB:-false}
USE_PIPEWIRE=${USE_PIPEWIRE:-false}
USE_NVIDIA=${USE_NVIDIA:-false}
USE_AMD_VULKAN=${USE_AMD_VULKAN:-false}
USE_BLUETOOTH=${USE_BLUETOOTH:-false}
USE_CUPS=${USE_CUPS:-false}
USE_SNAPPER=${USE_SNAPPER:-false}
FIREWALL="${FIREWALL:-none}"
EOF

    chmod 600 "$cfg_path"
    ok "Config saved → ${cfg_path}"
    warn "Delete or encrypt this file when done."
    blank
}

# =============================================================================
#  load_config — loads a config file with subshell validation
# =============================================================================

# Variables that must be non-empty for the config to be usable
readonly _CFG_REQUIRED=(DISK_ROOT ROOT_FS HOME_FS STORAGE_STACK
    HOSTNAME USERNAME TIMEZONE LOCALE KERNEL BOOTLOADER)

# Variables that must be "true" or "false" if set
readonly _CFG_BOOLEANS=(DUAL_BOOT REUSE_EFI USE_LUKS SEP_HOME SECURE_BOOT
    USE_REFLECTOR USE_MULTILIB USE_PIPEWIRE USE_NVIDIA USE_AMD_VULKAN
    USE_BLUETOOTH USE_CUPS USE_SNAPPER EXISTING_WINDOWS EXISTING_LINUX)

function load_config() {
    # inputs: config_file_path / side-effects: sets all globals after validation
    local cfg="$1"
    [[ ! -f "$cfg" ]] && die "Config file not found: ${cfg}"

    # Validate in a subshell first — never pollute globals with a broken config.
    local validation_out
    if ! validation_out=$(
        set -euo pipefail
        # shellcheck source=/dev/null
        source "$cfg"

        for v in "${_CFG_REQUIRED[@]}"; do
            if [[ -z "${!v:-}" ]]; then
                printf 'MISSING:%s\n' "$v"
                exit 1
            fi
        done

        for v in "${_CFG_BOOLEANS[@]}"; do
            local val="${!v:-}"
            if [[ -n "$val" && "$val" != "true" && "$val" != "false" ]]; then
                printf 'BAD_BOOL:%s=%s\n' "$v" "$val"
                exit 1
            fi
        done

        echo "OK"
    ); then
        case "$validation_out" in
            MISSING:*)  die "Config invalid — missing required: ${validation_out#MISSING:}" ;;
            BAD_BOOL:*) die "Config invalid — expected true/false: ${validation_out#BAD_BOOL:}" ;;
            *)          die "Config validation failed: ${cfg}" ;;
        esac
    fi

    # Passed — source for real
    # shellcheck source=/dev/null
    source "$cfg"
    ok "Config loaded: ${cfg}"
    blank
}
