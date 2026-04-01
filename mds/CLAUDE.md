# CLAUDE.md — ArchWizard
> Canonical reference for all AI agents and contributors.
> Read this file before touching any code.

---

## Role
Senior Arch Linux Systems Engineer. Values: minimalism, correctness, safety.

**Never speculate about code not read.**
Read the relevant source file before answering any question about it.
Read it again if the context window is long and the last read was far back.

---

## Project Description
ArchWizard is a single-file (or modular) Arch Linux installer in Bash + gum.
Goal: the most reliable, user-friendly, and beautiful Arch installer possible.

**Stack:** Bash 5+ + gum. No new runtime dependencies without explicit justification.
**Distribution:** Single `.sh` file, `curl`-able from a live Arch ISO.
**Compatibility:** BIOS/MBR and UEFI/GPT. x86_64 only.

---

## File Map

### Current (single-file)
| File | Role |
|------|------|
| `archwizardGum_X_Y.sh` | Active target — gum UI, all phases |
| `ArchWizard_6_0.sh` | Reference — plain bash, used to validate logic |

### Target (modular — future)
```
archwizard.sh           Entry point, arg parsing, main_menu()
lib/
  ui.sh                 ALL gum wrappers + theme constants. Zero logic.
  log.sh                Structured logging, LOG_FILE, exec tee setup.
  detect.sh             Phase 1: env detection, keyboard
  disk.sh               Phase 2-3: disk survey, OS probe, space planning
  layout.sh             Phase 4-5: partition layout wizard
  storage.sh            Phase 6: storage stack (plain/LUKS/LVM/BTRFS/ZFS)
  partition.sh          Phase 7: destructive partition ops ⚠
  format.sh             Phase 8: mkfs, subvols, mount tree ⚠
  base.sh               Phase 9: pacstrap, fstab, mirrorlist ⚠
  chroot_gen.sh         Phase 10: serialize state, copy template, run chroot ⚠
  bootloader.sh         Phase 11: GRUB / systemd-boot install + config ⚠
  desktop.sh            Phase 12: DE packages, dotfiles deploy
  postinstall.sh        Phase 13: verify, snapshot baseline, cleanup, reboot
  state.sh              Step state machine, save/load config with validation
templates/
  mkinitcpio/
    plain.conf          HOOKS for plain ext4/xfs/f2fs root
    luks.conf           HOOKS for LUKS root
    luks_lvm.conf       HOOKS for LUKS + LVM root (encrypt before lvm2)
    btrfs.conf          HOOKS for btrfs root
  chroot_base.sh        Chroot script body — sources /arch_install_vars.sh
```

**Architectural rule (single-file and modular):**
Logic functions are pure bash — zero gum calls inside them.
UI functions wrap logic functions — all gum calls live here.
Example: `_compute_layout()` sets globals. `_ui_layout_wizard()` collects input via gum, calls `_compute_layout()`.

---

## Phase Map

| # | Phase | Destructive | Gate |
|---|-------|-------------|------|
| 1 | Environment detection | No | — |
| 2 | Disk discovery & OS probe | No | — |
| 3 | Disk selection | No | — |
| 4 | Storage stack selection (LUKS/LVM/plain/BTRFS/ZFS) | No | — |
| 5 | Partition layout wizard | No | — |
| 6 | System identity (hostname/locale/TZ/keymap) | No | — |
| 7 | User accounts | No | — |
| 8 | Software selection (kernel/bootloader/DE/extras) | No | — |
| **9** | **Summary + final confirm** | **No** | **← LAST SAFE EXIT** |
| 10 | Partition execution (sgdisk/fdisk/parted) | **YES** | — |
| 11 | Format + mount (mkfs, LUKS open, LVM create, mount) | **YES** | — |
| 12 | Base install (pacstrap, genfstab) | **YES** | — |
| 13 | Chroot config (state serialize → template → arch-chroot) | **YES** | — |
| 14 | Bootloader install (grub-install / bootctl) | **YES** | — |
| 15 | Post-install (verify, snapper baseline, cleanup, reboot) | **YES** | — |

**Nothing destructive happens before Phase 10.**
Phase 9 is a hard gate: full summary shown, explicit confirmation required, no shortcuts.

---

## Key Globals

### Disk & Partition
```bash
DISK_ROOT=""            # /dev/nvme0n1 — disk for root
DISK_HOME=""            # /dev/sdb — disk for /home (may equal DISK_ROOT)
EFI_PART=""             # /dev/nvme0n1p1
ROOT_PART=""            # raw partition device
ROOT_PART_MAPPED=""     # /dev/mapper/cryptroot when LUKS active
HOME_PART=""
SWAP_PART=""
EFI_SIZE_MB=512
ROOT_SIZE=""            # GB integer or "rest"
HOME_SIZE=""            # GB integer or "rest"
SEP_HOME=false
```

### Multi-boot
```bash
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
EXISTING_SYSTEMS=()     # OS names detected
```

### Storage Stack
```bash
STORAGE_STACK="plain"   # plain | luks | lvm | luks_lvm | btrfs | luks_btrfs | zfs
ROOT_FS="btrfs"         # btrfs | ext4 | xfs | f2fs | zfs
HOME_FS="btrfs"
SWAP_TYPE="zram"        # zram | file | partition | none
SWAP_SIZE="8"
USE_LUKS=false
LUKS_PASSWORD=""        # NEVER in argv — always piped via stdin
LVM_VG=""               # volume group name (LVM only)
LVM_LV_ROOT=""          # logical volume for root
LVM_LV_HOME=""          # logical volume for home
ZFS_POOL=""             # pool name (ZFS only)
```

### System Identity
```bash
HOSTNAME=""
GRUB_ENTRY_NAME=""
USERNAME=""
USER_PASSWORD=""        # NEVER in argv
ROOT_PASSWORD=""        # NEVER in argv
TIMEZONE="UTC"
LOCALE="en_US.UTF-8"
KEYMAP="us"
```

### Software
```bash
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
```

### Runtime
```bash
DRY_RUN=false           # --dry-run flag: no disk writes, print commands
VERBOSE=false           # --verbose flag: set -x
NO_GUM=false            # --no-gum flag: plain read/echo fallback
CONFIG_FILE=""          # --load-config FILE
FIRMWARE_MODE="uefi"    # detected, NEVER set by user input
CPU_VENDOR="unknown"    # detected
GPU_VENDOR="unknown"    # detected
LOG_FILE="/tmp/archwizard.log"
SCRIPT_DIR=""           # dirname of archwizard.sh (for template lookup)
```

---

## Critical Functions

### Conventions
- All functions: `function name() { ... }` syntax.
- First line of function body: one-line comment `# inputs: X / outputs: Y / side-effects: Z`.
- Pure logic functions: set globals, return 0/1. No gum calls.
- UI wrapper functions: collect input via gum, call logic functions.

### Core Helpers (never modify without review)
```
part_name(disk, num)
  → Returns /dev/nvme0n1p1 (NVMe/MMC) or /dev/sda1 (SATA/other)
  → Rule: [[ "$disk" == *"nvme"* || "$disk" == *"mmcblk"* ]] → append "p"

_refresh_partitions(disk)
  → Call DIRECTLY — never via run()/eval (shell fn lost in eval subshell)
  → partprobe ×3 with 2s retry → partx -u → udevadm settle
  → Call ONCE after batching all sgdisk -d deletions, not after each

probe_os_from_part(part)
  → Sets PROBE_OS_RESULT
  → Detection order: crypto_LUKS → ntfs → mount → btrfs subvols → label fallback

_is_protected(part)
  → Returns 0 if part is in PROTECTED_PARTS[], 1 otherwise
  → Uses array guard: "${PROTECTED_PARTS[@]+"${PROTECTED_PARTS[@]}"}"

run(cmd...)
  → Wraps ALL destructive commands. DRY_RUN=true → prints, no exec.
  → Uses eval "$@" — handles dynamic strings, preserves $@ boundaries.

run_interactive(cmd...)
  → parted resize ONLY. Redirects all streams to /dev/tty.
  → Required because top-level exec > >(tee ...) breaks interactive read()

run_spin(label, cmd...)
  → Gum spinner wrapper. DRY_RUN=true → prints, no exec.
  → Never nest $(gum style) in --title (crashes when stdout piped)

_serialize_chroot_vars()
  → Prints all chroot-needed globals as bash variable assignments
  → Use unquoted heredoc (EOF) to expand variables at write-time
  → Consumed by: cat > /mnt/arch_install_vars.sh < <(_serialize_chroot_vars)
```

---

## Hard Rules — Known Crash Patterns

These are crashes that have been hit in production. Do not "improve" around them.

### Bash
1. **`[[ ]] && cmd` kills script under `set -e`** → always `if [[ ]]; then cmd; fi`
2. **Empty array under `set -u`** → always `"${A[@]+"${A[@]}"}"` not `"${A[@]}"`
3. **`eval` with `$*` loses argument boundaries** → always `eval "$@"` not `eval "$*"`
4. **Passwords never in argv** → always pipe: `echo -n "$PASS" | cryptsetup ... -`; `echo "user:pass" | chpasswd`
5. **`source` of untrusted config without validation** → validate all expected variables exist and have correct types before use

### Partitioning
6. **Batch `sgdisk -d` calls, one `_refresh_partitions`** → udev serializes poorly across rapid partition ops
7. **Delete partitions in reverse number order** → GPT slot renumbering shifts all higher-numbered partitions mid-loop
8. **`_refresh_partitions` via run()/eval → function lost** → call directly, always
9. **parted resize is interactive** → use `run_interactive`, not `run`

### Chroot Script Generation
10. **Chroot script via heredoc sed placeholders corrupts UUIDs** → UUID contains `-` which sed interprets as range. Use template files + variable serialization instead.
11. **Quoted `'EOF'` prevents variable expansion** → use for script body (literal bash code)
12. **Unquoted `EOF` expands variables at write-time** → use for `_serialize_chroot_vars()` section only
13. **Variables not serialized = silent empty string in chroot** → every global the chroot needs must appear in `_serialize_chroot_vars()`

### Gum
14. **`$(gum style)` in `--title`/`--header` crashes when stdout is piped** → use `_clr "$GUM_C_X" "text"` for inline color in titles
15. **`gum choose --selected ""`  exits non-zero** → never pass empty string to `--selected`
16. **`gum` calls inside logic functions** → logic functions must be pure bash; gum lives in UI wrappers only

### Storage Stack
17. **mkinitcpio hook order: `encrypt` before `lvm2`** → always: `... block encrypt lvm2 filesystems fsck`
18. **LUKS on LVM: `pvcreate` on raw partition, `lvcreate` inside VG, `cryptsetup` on LV** → order matters; inverse order breaks boot
19. **BTRFS root with LUKS: mount with `subvol=@` after LUKS open, not before** → device not available before `cryptsetup open`
20. **ZFS: pool must be imported before chroot `mount --bind`** → `zpool import -d /dev/disk/by-id -R /mnt POOLNAME`

---

## Storage Stack Matrix

Maps `STORAGE_STACK` to required packages, mkinitcpio template, and crypttab entries:

| STORAGE_STACK | Extra packages | mkinitcpio template | crypttab needed |
|---|---|---|---|
| `plain` | — | `plain.conf` | No |
| `luks` | `cryptsetup` | `luks.conf` | Yes (root) |
| `lvm` | `lvm2` | `plain.conf` | No |
| `luks_lvm` | `cryptsetup lvm2` | `luks_lvm.conf` | Yes (root) |
| `btrfs` | `btrfs-progs` | `btrfs.conf` | No |
| `luks_btrfs` | `cryptsetup btrfs-progs` | `luks.conf` | Yes (root) |
| `zfs` | `zfs-dkms zfs-utils` (AUR) | `plain.conf` + zfs hook | No (zpool cache) |

---

## Gum UI Map

| Plain bash | Gum wrapper | Notes |
|---|---|---|
| `read` confirm | `confirm_gum "msg"` | returns 0/1 |
| `select` from list | `choose_one "default" items...` | single select |
| multi-select | `choose_many "defaults" items...` | space to toggle |
| `read` text input | `input_gum "prompt" "placeholder"` | |
| `read -s` password | `password_gum "prompt"` | loops until match |
| slow command | `run_spin "label" "cmd"` | spinner overlay |
| fatal error | `die "msg"` | gum box + exit 1 |
| section header | `section "title"` | gum border box |
| status messages | `ok` `warn` `info` `error` | colored prefix |

### NO_GUM Fallback
When `NO_GUM=true`, all wrappers above fall back to plain `read`/`echo`.
Implementation: each wrapper checks `[[ "$NO_GUM" == true ]]` at the top.

---

## Gum Theme Constants

```bash
readonly GUM_C_TITLE=99
readonly GUM_C_OK=46
readonly GUM_C_WARN=214
readonly GUM_C_ERR=196
readonly GUM_C_INFO=51
readonly GUM_C_DIM=242
readonly GUM_C_ACCENT=141
readonly GUM_WIDTH=70
```

- Never hardcode color numbers. Always `_clr "$GUM_C_X" "text"`.
- `_clr()` → `printf '\033[38;5;%sm%s\033[0m' "$1" "$2"`
- `readonly` on all theme constants — they must not drift during execution.

---

## Step State Machine

The installer uses a loop-based wizard. Each step function returns 0 (advance) or 1 (go back).
The user always has a "← Back" option in every `choose_one` / `confirm_gum`.

```bash
STEP=1
while true; do
  case $STEP in
    1) step_detect    && STEP=2 || true          ;;  # no back from step 1
    2) step_disk      && STEP=3 || STEP=1        ;;
    3) step_layout    && STEP=4 || STEP=2        ;;
    4) step_storage   && STEP=5 || STEP=3        ;;
    5) step_identity  && STEP=6 || STEP=4        ;;
    6) step_users     && STEP=7 || STEP=5        ;;
    7) step_software  && STEP=8 || STEP=6        ;;
    8) step_summary   && STEP=9 || STEP=7        ;;
    9) exec_install; break                        ;;  # no back after confirm
    *) break ;;
  esac
done
```

`_step_done(n)` — returns 0 if step n has been completed (all required globals set).
`_step_summary(n)` — returns a one-line human-readable summary of step n's choices.

---

## Chroot Script Architecture

The chroot script is NOT built inline via heredoc. It is:
1. State serialized to `/mnt/arch_install_vars.sh` by `_serialize_chroot_vars()`
2. Template copied: `cp templates/chroot_base.sh /mnt/arch_configure.sh`
3. Executed: `arch-chroot /mnt /arch_configure.sh`
4. Cleaned up: `rm /mnt/arch_configure.sh /mnt/arch_install_vars.sh`

`arch_install_vars.sh` is unquoted-EOF bash: all variables expanded at write-time.
`chroot_base.sh` is `'quoted-EOF'` bash: real logic, no string embedding. First line: `source /arch_install_vars.sh`.

---

## Testing

```bash
# Dry run — no disk writes, all commands printed
bash archwizard.sh --dry-run

# Verbose — set -x, all commands traced
bash archwizard.sh --verbose

# No gum — plain read/echo fallback (CI / SSH)
bash archwizard.sh --no-gum

# Load saved config — skip Phase 1-8, go straight to confirm
bash archwizard.sh --load-config /tmp/saved_config.sh

# Combinations
bash archwizard.sh --dry-run --no-gum --load-config /tmp/cfg.sh
```

---

## Versioning Convention

`MAJOR.MINOR.PATCH[-variant]`
- `MAJOR` bumps on phase map changes or breaking config format changes
- `MINOR` bumps on new features (LVM support, ZFS support, new DE)
- `PATCH` bumps on bug fixes
- `-gum` suffix on the gum variant until merged into single file

Current: `6.0` (plain) / `5.5.0-gum-2.0.0` (gum) → target: `7.0.0-gum`

---

## What NOT to do

- Do not add abstractions for one-time operations.
- Do not add error handling for impossible scenarios.
- Do not refactor, rename, or reorganize code beyond what was asked.
- Do not add new dependencies without explicit justification and user approval.
- Do not write gum calls inside logic functions.
- Do not build the chroot script via multi-level heredoc string embedding.
- Do not pass passwords via command-line arguments — ever.
- Do not call `_refresh_partitions` via `run()` or `eval`.
- Do not guess what a function does — read it first.
