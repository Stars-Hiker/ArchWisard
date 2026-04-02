# ArchWizard — gum Style Reference
> Hard-won, battle-tested. Read this before touching any UI code.

---

## The Three OSC Escape Bug Sources — never use these

| ✗ Banned | Why |
|---|---|
| `gum log` | Triggers `HasDarkBackground()` OSC 11 query, always leaks |
| `gum join` | Same OSC query for layout computation |
| `gum format -t template` | Leaks OSC sequences on piped stdout |
| `--foreground "#hex"` | Adaptive colour triggers OSC query — use 256-int: `--foreground 141` |

---

## The `_tty()` Trap

```bash
# ✗ WRONG — looks correct, isn't
_tty() { echo 1; }
gum style "…" > "$(_tty)"   # creates a FILE named "1", not fd 1
# gum stdout becomes a file → falls back to /dev/tty internally
# → OSC responses land in tty input buffer → printed as garbage

# ✔ RIGHT — _gum_show wrapper
_gum_show() {
    if   [[ -t 1 ]];        then "$@" 2>/dev/null || true
    elif [[ -w /dev/tty ]]; then "$@" > /dev/tty 2>/dev/null || true
    else                         "$@" 2>/dev/null || true; fi
}
```

**Rule:** wrap every *display* gum call with `_gum_show`.
Interactive calls (`choose`/`confirm`/`input`) use `</dev/tty 2>/dev/tty` instead.

---

## Theme Block — paste at top of every script

```bash
# Hex: env-driven defaults for choose/confirm/input/spin
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

# 256-int: for gum style --foreground and _c() inline colour
readonly C_TITLE=141  C_OK=114  C_WARN=215  C_ERR=203
readonly C_INFO=117   C_DIM=242 C_ACCENT=183  WIDTH=72
```

---

## Four Core Patterns

### 1. Inline colour — never embed `$(gum style)` inside another gum call
```bash
_c() { printf '\033[38;5;%sm%s\033[0m' "$1" "$2"; }
# usage: "$(_c $C_WARN "text")" as an argument to gum style
```

### 2. Display helpers — `gum style` replaces `gum log`
```bash
_ok()   { _gum_show gum style --foreground $C_OK   " ✔  $*"; }
_info() { _gum_show gum style --foreground $C_INFO " ℹ  $*"; }
_warn() { _gum_show gum style --foreground $C_WARN " ⚠  $*"; }
```

### 3. Interactive calls — always `/dev/tty` both ends
```bash
result=$(gum choose … </dev/tty 2>/dev/tty) || true
[[ -z "$result" ]] && return 1          # Esc/q → empty string, not error

if gum confirm "…?" </dev/tty 2>/dev/tty; then   # S3: if/then/fi, never && under set -e
    …
fi
```

### 4. `gum table` — pipe separator, not comma
```bash
# French locale formats sizes as "119,2G" → breaks comma CSV parsing
{ printf 'COL1|COL2\n'; generate_rows; } \
  | _gum_show gum table --separator '|' --border.foreground $C_ACCENT \
      --widths 16,8 --print
```

---

## `lsblk` Rule

```bash
# ✗ WRONG — space-padded multi-column output, IFS-read unreliable
lsblk -dno SIZE,ROTA,TRAN,MODEL

# ✔ RIGHT — one call per field
size=$(lsblk  -dno SIZE  "/dev/$dev")
tran=$(lsblk  -dno TRAN  "/dev/$dev")
model=$(lsblk -dno MODEL "/dev/$dev" | cut -c1-20)
```

---

## `gum spin`

```bash
gum spin --spinner dot --title " label…" \
    -- bash -c "long_cmd 2>&1 | tee -a $LOG" \
    </dev/tty 2>/dev/tty
```

---

## Safety Rules (from gumMasterPrompt)

| Code | Rule |
|---|---|
| S1 | `set -euo pipefail` at top |
| S2 | Traps in `main()`, not global |
| S3 | Never `[[ ]] && cmd` — always `if/then/fi` |
| S4 | Empty array: `"${arr[@]+"${arr[@]}"}"`  not  `"${arr[@]}"` |
| S5 | Passwords via stdin pipe, never argv |
| S7 | Never pass shell functions through `run()`/`eval()` |
| S8 | `gum confirm` before every destructive op + `# ⚠ DESTRUCTIVE` comment |

---

## `NO_GUM` Auto-degrade

```bash
command -v gum &>/dev/null || NO_GUM=true

# Every interactive wrapper needs a plain read path:
if [[ "${NO_GUM:-false}" == true ]]; then
    …plain read/printf path…
    return
fi
```
