╔══════════════════════════════════════════════════════════════════════╗
║  ArchWizard — gum style reference  (hard-won, battle-tested)         ║
╚══════════════════════════════════════════════════════════════════════╝

━━━  THE THREE OSC ESCAPE BUG SOURCES  (never use these)  ━━━━━━━━━━━━

  ✗  gum log          → HasDarkBackground() OSC 11 query, always leaks
  ✗  gum join         → same OSC query for layout computation
  ✗  gum format -t template  → OSC sequences, leaks on piped stdout
  ✗  --foreground "#hex"     → adaptive colour triggers OSC query
                               use 256-int always: --foreground 141

━━━  THE _tty() TRAP  (gotcha that looks correct but isn't)  ━━━━━━━━━

  ✗  WRONG:  _tty() { echo 1; }  →  > "$(_tty)"  creates a FILE named "1"
             gum stdout becomes a file → gum falls back to /dev/tty internally
             → OSC query responses land in tty input buffer → printed as garbage

  ✔  RIGHT:  _gum_show() wrapper — no redirect when stdout is already a tty:

      _gum_show() {
          if   [[ -t 1 ]];       then "$@" 2>/dev/null || true
          elif [[ -w /dev/tty ]]; then "$@" > /dev/tty 2>/dev/null || true
          else                        "$@" 2>/dev/null || true; fi
      }

  Rule: wrap every display gum call with _gum_show.
        interactive calls (choose/confirm/input) use </dev/tty 2>/dev/tty instead.

━━━  THEME BLOCK  (paste at top of every script)  ━━━━━━━━━━━━━━━━━━━━

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

━━━  FOUR CORE PATTERNS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  1. Inline colour (never embed $(gum style) inside another gum call):
       _c() { printf '\033[38;5;%sm%s\033[0m' "$1" "$2"; }
       # use: "$(_c $C_WARN "text")" inside gum style args

  2. Display helpers (gum style replaces gum log):
       _ok()   { _gum_show gum style --foreground $C_OK   " ✔  $*"; }
       _info() { _gum_show gum style --foreground $C_INFO " ℹ  $*"; }
       _warn() { _gum_show gum style --foreground $C_WARN " ⚠  $*"; }

  3. Interactive (choose / confirm / input) — always:
       result=$(gum choose … </dev/tty 2>/dev/tty) || true
       [[ -z "$result" ]] && return 1          # Esc/q → empty string, not error
       gum confirm "…?" </dev/tty 2>/dev/tty   # inside if/then/fi (S3)

  4. gum table — use | separator, not comma (French locale: "119,2G" breaks CSV):
       { printf 'COL1|COL2\n'; generate_rows; } \
         | _gum_show gum table --separator '|' --border.foreground $C_ACCENT \
             --widths 16,8 --print

━━━  lsblk RULE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ✗  lsblk -dno SIZE,ROTA,TRAN,MODEL  → space-padded, IFS-read unreliable
  ✔  one call per field:
       size=$(lsblk -dno SIZE  "/dev/$dev")
       tran=$(lsblk -dno TRAN  "/dev/$dev")
       model=$(lsblk -dno MODEL "/dev/$dev" | cut -c1-20)

━━━  SAFETY RULES (S-codes from gumMasterPrompt)  ━━━━━━━━━━━━━━━━━━━━

  S1  set -euo pipefail at top
  S2  traps in main(), not global
  S3  never [[ ]] && cmd — always if/then/fi
  S4  empty array: "${arr[@]+"${arr[@]}"}  not  "${arr[@]}"
  S5  passwords via stdin pipe, never argv
  S7  never pass shell functions through run()/eval()
  S8  gum confirm before every destructive op + # ⚠ DESTRUCTIVE comment

━━━  gum spin  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  gum spin --spinner dot --title " label…" \
      -- bash -c "long_cmd 2>&1 | tee -a $LOG" \
      </dev/tty 2>/dev/tty

━━━  NO_GUM auto-degrade  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  command -v gum &>/dev/null || NO_GUM=true
  Every interactive wrapper needs a plain read path guarded by:
    if [[ "${NO_GUM:-false}" == true ]]; then …plain path…; return; fi
