# AGENTS.md — ArchWizard

## Context
act as a "Senior Arch Systems Engineer" who values minimalism. 

## Files
| File | Status |
|------|--------|
| `ArchWizard_5_5.sh` | Complete reference (all 6 phases) — do not break |
| `archwizardGum_X_Y.sh` | Active target — Phase 1 done, Phases 2–6 pending |

**Gum script = UI layer only.** Logic is copy-identical to 5.5.
When porting phases 2–6: copy logic verbatim, replace only UI calls.

## Phase Model
| # | What | Disk? |
|---|------|-------|
| 1 | Questionnaire — all user choices | ✗ |
| 2 | Summary + **confirmation gate** | ✗ |
| 3 | Resize / partition / LUKS / format / mount | ✔ |
| 4 | pacstrap + genfstab | ✔ |
| 5 | Generate + run arch-chroot config script | ✔ |
| 6 | Verify + cleanup + reboot | ✔ |

**Nothing touches disk before explicit Phase 2 confirmation. This is inviolable.**

## Key Globals
```
DISK_ROOT  DISK_HOME  EFI_PART  ROOT_PART  ROOT_PART_MAPPED  HOME_PART  SWAP_PART
DUAL_BOOT  REUSE_EFI  PROTECTED_PARTS[]  REPLACE_PARTS_ALL[]
RESIZE_PART  RESIZE_NEW_GB  FREE_GB_AVAIL
ROOT_FS  HOME_FS  SWAP_TYPE  USE_LUKS  LUKS_PASSWORD
DESKTOPS[]  KERNEL  BOOTLOADER  FIRMWARE_MODE  # FIRMWARE_MODE detected, never set by user
```

## Critical Functions
- **Functions:** Use `function name() { ... }`. Document inputs/outputs in one line.
- **`run()`** — wraps ALL destructive commands. Dry-run safe. Uses `eval` (handles dynamic strings).
- **`run_interactive()`** — parted resize only. Redirects all streams to `/dev/tty`. Required because top-level `exec > >(tee ...)` breaks interactive `read()` in child processes.
- **`_refresh_partitions(disk)`** — call DIRECTLY, never via `run()`/`eval`. Retries `partprobe`×3 → `partx -u`.
- **`probe_os_from_part(part)`** — sets `PROBE_OS_RESULT`. Order: LUKS → NTFS → mount → btrfs subvols → label.
- **`part_name(disk, num)`** — NVMe/MMC use `p` separator (`nvme0n1p1`), SATA don't (`sda1`).

## Hard Rules — Known Crash Patterns

1. **`[[ ]] &&` kills script under `set -e`** — always use `if/then/fi`.
2. **Empty array crashes under `set -u`** — use `"${A[@]+"${A[@]}"}"` not `"${A[@]}"`.
3. **Gum nested subshells in `--title`/`--header` crash when stdout is piped** — use `_clr N "text"` for inline color.
4. **`gum choose --selected ""`** exits non-zero — never pass empty `--selected`.
5. **Passwords never in argv** — always pipe via stdin to `cryptsetup`/`chpasswd`.
6. **Batch all `sgdisk -d` calls, then one `_refresh_partitions`** — udev can't handle partprobe after each individual deletion.
7. **Delete partitions in reverse number order** — prevents GPT slot renumbering mid-loop.
8. **Chroot script uses `cat >> $S` sections** — never sed placeholders (corrupts UUIDs). Quoted `'EOF'` blocks expansion, unquoted `EOF` allows it.

## Gum UI Map
| Plain | Gum |
|-------|-----|
| `confirm "msg"` | `confirm_gum "msg"` |
| `select_option "p" items` | `choose_one "default" items` |
| `get_input "p" "default"` | `input_gum "p" "default"` |
| `get_password "p"` | `password_gum "p"` |
| slow `run "cmd"` | `run_spin "label" "cmd"` |

## Gum Theme Constants
```bash
GUM_C_TITLE=99  GUM_C_OK=46  GUM_C_WARN=214  GUM_C_ERR=196
GUM_C_INFO=51   GUM_C_DIM=242  GUM_C_ACCENT=141  GUM_WIDTH=70
```
Never hardcode color numbers. Use `_clr "$GUM_C_X" "text"` for inline coloring.

## Remaining Work (gum script)
- [ ] `show_summary()` — Phase 2 confirmation gate
- [ ] `replace_partition()` `resize_partitions()` `create_partitions()`
- [ ] `setup_luks()` `format_filesystems()` `create_subvolumes()` `mount_filesystems()`
- [ ] `setup_mirrors()` `install_base()`
- [ ] `generate_chroot_script()` `run_chroot()`
- [ ] `verify_installation()` `finish()`
- [ ] `save_config()` `load_config()` + `--load-config FILE` arg
