#!/usr/bin/env bash
# =============================================================================
#  ArchWizard 7.0 — Arch Linux Installer
#  Usage: bash archwizard.sh [--dry-run] [--verbose] [--no-gum] [--load-config FILE]
# =============================================================================

set -euo pipefail

# Crash handler — writes to LOG_FILE before the tee pipe is set up
# so we always have a record even if the early setup crashes.
trap 'RC=$?
      echo "CRASH line=$LINENO exit=$RC cmd=${BASH_COMMAND}" \
          >> "${LOG_FILE:-/tmp/archwizard.log}"
      printf "\n\033[1;31m[FATAL]\033[0m line=%s exit=%s cmd=%s\n" \
          "$LINENO" "$RC" "${BASH_COMMAND}" >&2
      printf "        log: %s\n\n" "${LOG_FILE:-/tmp/archwizard.log}" >&2' ERR

LOG_FILE="/tmp/archwizard.log"
: > "$LOG_FILE"

# SCRIPT_DIR — used by chroot_gen.sh for template lookups
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
#  GLOBALS — all defaults; load_config or user input overrides these
# =============================================================================

# Runtime flags
DRY_RUN=false
VERBOSE=false
NO_GUM=false
CONFIG_FILE=""

# Detection (FIRMWARE_MODE, CPU_VENDOR, GPU_VENDOR are detected — never set by user)
FIRMWARE_MODE="uefi"
CPU_VENDOR="unknown"
GPU_VENDOR="unknown"

# Disk & partition
DISK_ROOT=""
DISK_HOME=""
EFI_PART=""
ROOT_PART=""
ROOT_PART_MAPPED=""
HOME_PART=""
SWAP_PART=""
EFI_SIZE_MB=512
ROOT_SIZE=""
HOME_SIZE=""
SEP_HOME=false

# Multi-boot
DUAL_BOOT=false
REUSE_EFI=false
PROTECTED_PARTS=()
REPLACE_PARTS_ALL=()
REPLACE_PART=""
RESIZE_PART=""
RESIZE_NEW_GB=0
FREE_GB_AVAIL=0
EXISTING_WINDOWS=false
EXISTING_LINUX=false
EXISTING_SYSTEMS=()

# Storage stack
STORAGE_STACK="plain"    # plain | luks | lvm | luks_lvm | btrfs | luks_btrfs | zfs
ROOT_FS="btrfs"
HOME_FS="btrfs"
SWAP_TYPE="zram"
SWAP_SIZE="8"
USE_LUKS=false
LUKS_PASSWORD=""         # NEVER in argv — always piped via stdin
LVM_VG="arch_vg"
LVM_LV_ROOT="root"
LVM_LV_HOME="home"
ZFS_POOL="zroot"

# System identity
HOSTNAME=""
GRUB_ENTRY_NAME=""
USERNAME=""
USER_PASSWORD=""         # NEVER in argv
ROOT_PASSWORD=""         # NEVER in argv
TIMEZONE="UTC"
LOCALE="en_US.UTF-8"
KEYMAP="us"

# Software
KERNEL="linux"
BOOTLOADER=""
SECURE_BOOT=false
DESKTOPS=()
AUR_HELPER="none"
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
FIREWALL="none"

# Step state — owned by lib/state.sh
STEP=1

# =============================================================================
#  SOURCE ORDER
#  Each lib file depends only on globals above and functions from earlier files.
# =============================================================================

# For single-file usage: replace these sources with direct inclusion.
# For modular usage: source from SCRIPT_DIR/lib/.
_source_lib() {
    local name="$1"
    local path="${SCRIPT_DIR}/lib/${name}.sh"
    if [[ ! -f "$path" ]]; then
        printf '\033[1;31m[FATAL]\033[0m Cannot find lib/%s.sh\n' "$name" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$path"
}

_source_chroot() {
    local name="$1"
    local path="${SCRIPT_DIR}/chroot/${name}.sh"
    if [[ ! -f "$path" ]]; then
        printf '\033[1;31m[FATAL]\033[0m Cannot find chroot/%s.sh\n' "$name" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$path"
}

_source_templates() {
    local name="$1"
    local path="${SCRIPT_DIR}/templates/${name}.sh"
    if [[ ! -f "$path" ]]; then
        printf '\033[1;31m[FATAL]\033[0m Cannot find templates/%s.sh\n' "$name" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$path"
}


_source_lib ui           # 1 — wrappers + theme; no deps
_source_lib state        # 2 — step machine, menu; needs ui
_source_lib detect       # 3 — env detection, keyboard, shared helpers; needs ui
_source_lib disk         # 4 — disk survey, OS probe, space planning; needs detect
_source_lib storage      # 5 — storage stack wizard (step 3); needs ui
_source_lib layout       # 6 — partition sizing (step 4); needs storage
_source_lib identity     # 7 — steps 5-8 + summary gate; needs ui
_source_lib partition    # 8 — destructive ops; needs detect (_refresh_partitions)
_source_lib format       # 9 — mkfs, subvols, mount; needs partition globals
_source_lib base         # 10 — pacstrap, fstab; needs format
_source_lib chroot_gen   # 11 — serialize + deploy chroot; needs storage
_source_chroot bootloader   # 12 — host-side EFI helpers; needs chroot_gen
_source_chroot desktop      # 13 — dotfiles deploy; needs ui
_source_chroot postinstall  # 14 — verify, cleanup, reboot; needs ui
#_source_templates chroot_base # 15 - real bash chroot script (not heredoc)

# =============================================================================
#  ENTRY POINT
# =============================================================================

function parse_args() {
    # inputs: "$@" / side-effects: sets DRY_RUN VERBOSE NO_GUM CONFIG_FILE
    local prev=""
    for arg in "$@"; do
        case "$arg" in
            --dry-run)
                DRY_RUN=true ;;
            --verbose)
                VERBOSE=true ;;
            --no-gum)
                NO_GUM=true ;;
            --load-config)
                : ;;
            --help|-h)
                # Help must not call any gum wrapper — gum may not be set up yet.
                cat << 'USAGE'

  ArchWizard 7.0 — Arch Linux Installer

  Usage: bash archwizard.sh [OPTIONS]

  --dry-run           Print all commands without executing (safe everywhere)
  --verbose           Enable set -x tracing
  --no-gum            Plain read/echo fallback — no gum required
  --load-config FILE  Load saved config, skip questionnaire
  --help              This message

USAGE
                exit 0 ;;
            *)
                if [[ "$prev" == "--load-config" ]]; then
                    CONFIG_FILE="$arg"
                fi
                ;;
        esac
        prev="$arg"
    done
}

function main() {
    # inputs: "$@" / side-effects: drives the entire installer
    parse_args "$@"

    # Auto-detect NO_GUM if gum is missing — degrade gracefully rather than die.
    if [[ "$NO_GUM" == false ]] && ! command -v gum &>/dev/null; then
        NO_GUM=true
        # Can't use warn() yet (ui.sh not loaded or LOG_FILE not tee'd).
        printf ' ⚠  gum not found — using plain mode. Install: pacman -Sy gum\n' >&2
    fi

    # Verbose MUST be set before exec tee so set -x output goes to log.
    if [[ "$VERBOSE" == true ]]; then set -x; fi

    # Redirect all stdout+stderr through tee into the log file.
    # This runs for the rest of the process — everything from here is logged.
    exec > >(tee -a "$LOG_FILE") 2>&1

    if [[ "$DRY_RUN" == true ]]; then warn "DRY-RUN: no disk writes."; fi

    if [[ -n "$CONFIG_FILE" ]]; then
        # Load-config path: skip questionnaire, go straight to confirmation.
        sanity_checks
        load_config "$CONFIG_FILE"
        if show_summary; then
            _exec_install
        else
            info "Aborted — no changes made."
            exit 0
        fi
    else
        main_menu
    fi
}

main "$@"
