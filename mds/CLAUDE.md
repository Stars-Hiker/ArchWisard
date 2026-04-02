# CLAUDE.md — ArchWizard
> Read this before touching any code. Never speculate — read the relevant file first.

## Role
Senior Arch Linux Systems Engineer. Minimalism, correctness, safety first.
Never modify beyond what's explicitly asked. No abstractions for one-time ops.
For any non-trivial change: state what/why/risk, wait for confirmation, then code.

---

## File Map (current — files live flat in project root)
```
archwizard.sh          Entry point, globals, arg parsing, main()
ui.sh                  All gum wrappers + NO_GUM fallbacks. Zero logic.
state.sh               Step machine, main_menu, _exec_install, save/load config
detect.sh              Env detection, keyboard, part_name(), probe_os_from_part(), _refresh_partitions()
disk.sh                Disk survey, OS probe, space planning, disk selection
storage.sh             Storage stack wizard (Step 3)
layout.sh              Partition sizing, swap, layout preview (Step 4)
identity.sh            Identity/users/kernel/DE/summary (Steps 5-8+9)
partition.sh           Destructive partition ops ⚠
format.sh              mkfs, btrfs subvols, mount tree ⚠
base.sh                pacstrap, genfstab, mirrorlist ⚠
chroot_gen.sh          Serialize vars, deploy template, run chroot ⚠
bootloader.sh          EFI guard, fallback EFI copy, NVRAM check (host-side)
desktop.sh             Dotfiles deploy (post-chroot, /mnt still mounted)
postinstall.sh         Verification, cleanup, reboot
chroot_base.sh         Chroot script body — sources /arch_install_vars.sh at runtime
```
> archwizard.sh sources libs from `${SCRIPT_DIR}/lib/` and `${SCRIPT_DIR}/chroot/` — deploy into those subdirs.

---

## Architecture Invariants
- **Logic functions**: pure bash, zero gum calls, return 0 (done) / 1 (back)
- **UI functions**: gum wraps logic. All gum calls live here only.
- **Phase 9 (show_summary)** = last safe exit. Nothing destructive before `_exec_install`.
- **Chroot**: `_serialize_chroot_vars()` → `/mnt/arch_install_vars.sh` → `cp chroot_base.sh /mnt/arch_configure.sh` → `arch-chroot` → cleanup. Never build chroot script via heredoc embedding.

---

## Hard Crash Rules — never work around these

### Bash
1. `[[ ]] && cmd` kills script under `set -e` → always `if [[ ]]; then cmd; fi`
2. Empty array `"${A[@]}"` under `set -u` → always `"${A[@]+"${A[@]}"}"`
3. `eval "$@"` preserves arg boundaries; `eval "$*"` does not
4. Passwords never in argv → pipe always: `echo -n "$P" | cryptsetup ... -`; `echo "u:p" | chpasswd`
5. Validate config in subshell before sourcing into live globals

### Partitioning
6. Batch all `sgdisk -d` deletions → single `_refresh_partitions` after the batch
7. Delete partitions in **reverse** numeric order (prevents GPT renumbering mid-loop)
8. Call `_refresh_partitions` **directly** — never via `run()` or `eval` (shell fn lost in subshell)
9. `parted resize` is interactive → `run_interactive`, not `run`

### Chroot Script Generation
10. UUIDs contain `-` → sed treats it as a range → use template files + var serialization, never sed placeholders
11. `'EOF'` (quoted heredoc) = literal bash (use for script body)
12. `EOF` (unquoted heredoc) = variables expand at write-time (use for `arch_install_vars.sh` only)
13. Every global the chroot script needs must be listed in `_serialize_chroot_vars()` — missing = silent empty string

### Gum
14. `$(gum style …)` inside `--title`/`--header` crashes when stdout is piped → use `_clr "$GUM_C_X" "text"` inline
15. `gum choose --selected ""` exits non-zero → never pass empty string to `--selected`
16. No gum calls inside logic functions

### Storage / mkinitcpio
17. Hook order is fixed: `encrypt` **before** `lvm2` — always
18. BTRFS + LUKS: mount `subvol=@` **after** `cryptsetup open`, never before
19. ZFS: `zpool import -d /dev/disk/by-id -R /mnt POOLNAME` before any bind mounts

---

## Storage Stack Matrix
| STORAGE_STACK | Extra pkgs | crypttab |
|---|---|---|
| `plain` | — | No |
| `luks` | `cryptsetup` | Yes |
| `lvm` | `lvm2` | No |
| `luks_lvm` | `cryptsetup lvm2` | Yes |
| `btrfs` | `btrfs-progs` | No |
| `luks_btrfs` | `cryptsetup btrfs-progs` | Yes |
| `zfs` | `zfs-dkms zfs-utils` (AUR) | No |

mkinitcpio HOOKS suffix (all start with `base udev autodetect microcode modconf kms keyboard keymap consolefont block`):
- plain / btrfs / zfs: `… block [zfs] filesystems fsck`
- luks / luks_btrfs: `… block encrypt filesystems fsck`
- lvm: `… block lvm2 filesystems fsck`
- luks_lvm: `… block encrypt lvm2 filesystems fsck`

---

## Key Globals (valid values)
```bash
STORAGE_STACK  plain|luks|lvm|luks_lvm|btrfs|luks_btrfs|zfs
ROOT_FS        btrfs|ext4|xfs|f2fs|zfs
SWAP_TYPE      zram|file|partition|none
BOOTLOADER     grub|systemd-boot
KERNEL         linux|linux-lts|linux-zen|linux-hardened
FIREWALL       nftables|ufw|none
AUR_HELPER     paru-bin|paru|yay|none
DESKTOPS       (array) kde|gnome|hyprland|sway|cosmic|xfce|none
FIRMWARE_MODE  uefi|bios  (detected, never set from user input)
```
Passwords (`LUKS_PASSWORD USER_PASSWORD ROOT_PASSWORD`) — in globals only; never in argv or log.

---

## Gum Theme (never hardcode numbers)
```bash
GUM_C_TITLE=99  GUM_C_OK=46  GUM_C_WARN=214  GUM_C_ERR=196
GUM_C_INFO=51   GUM_C_DIM=242  GUM_C_ACCENT=141  GUM_WIDTH=70
_clr "$GUM_C_X" "text"   →   printf '\033[38;5;%sm%s\033[0m' "$1" "$2"
```

---

## Testing Flags
```bash
--dry-run        No disk writes; all commands printed
--verbose        set -x tracing
--no-gum         Plain read/echo (CI / SSH)
--load-config F  Skip wizard, go to summary+confirm
```
