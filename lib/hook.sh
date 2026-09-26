#!/data/data/com.termux/files/usr/bin/sh
# hook.sh — the plumbing every hook used to copy-paste: logging, state files,
# event dispatch, notifications and the HH:MM window helpers.
#
# Sourced, never executed. A runit-spawned hook gets it from the copy that
# install-hook drops in ~/.local/libexec/android-settings/lib/ — a hook runs
# natively in Termux, where the nix store is invisible, so it cannot source the
# repo directly. install-hook's service run script sets HOOK_LIB_DIR; test-hook
# sets it to the in-tree lib/ for the same reason.
#
# Typical hook preamble:
#
#   #!/data/data/com.termux/files/usr/bin/sh
#   HOOK_LIB_DIR="${HOOK_LIB_DIR:-$HOME/.local/libexec/android-settings/lib}"
#   . "$HOOK_LIB_DIR/hook.sh"
#   hook_log_init battery-low          # defines log() with a [battery-low] tag
#   THRESHOLD=${THRESHOLD:-15}
#
# API:
#   log MSG...                     hook-tagged line, as before
#   state_get NAME                 contents of state/<name>, or empty
#   state_set NAME VALUE           write state/<name>
#   as_quote STR                   single-quote STR for a root shell
#   ev_reset / ev_set N V          build the action environment
#   ev_run [N V]...                run $ACTION detached as root, env in scope
#   ev_run_sync [N V]...           ... and wait for it
#   hook_notify TITLE BODY [TAG]   android_notify, or a log line as fallback
#   time_hhmm_ge/lt A B            zero-padded HH:MM compare (lexicographic)
#   time_in_window NOW START END   window test that may cross midnight

[ -n "${AS_HOOK_SH:-}" ] && return 0
AS_HOOK_SH=1

HOOK_LIB_DIR=${HOOK_LIB_DIR:-$HOME/.local/libexec/android-settings/lib}

# Root handling + the notification helper. Both only define functions, so a
# hook that never elevates or never notifies pays nothing for them.
# shellcheck disable=SC1090,SC1091
. "$HOOK_LIB_DIR/su.sh"
# shellcheck disable=SC1090,SC1091
[ -f "$HOOK_LIB_DIR/notify.sh" ] && . "$HOOK_LIB_DIR/notify.sh"

# STATE_DIR is the shared state root (su.sh defines it as AS_STATE_BASE, and the
# name the hooks already use). Per-hook files live in state/ next to it.
STATE_DIR=${STATE_DIR:-$AS_STATE_BASE}
STATE_SUBDIR="$STATE_DIR/state"

# log MSG... — replaces the per-hook `log() { printf '[name] %s\n' ...; }`.
hook_log_init() { # $1 = hook name
  HOOK_NAME=$1
  eval "log() { printf '[$HOOK_NAME] %s\\\\n' \"\$(date +%H:%M:%S) \$*\"; }"
}

# ------------------------------------------------------------- state
# One file per concern under state/, so hooks do not fight over one blob.
state_path() { printf '%s/%s' "$STATE_SUBDIR" "$1"; }

state_get() { # $1 = name
  _st_file=$(state_path "$1")
  [ -f "$_st_file" ] || return 0
  cat "$_st_file" 2>/dev/null
}

state_set() { # $1 = name, $2 = value
  mkdir -p "$STATE_SUBDIR" 2>/dev/null || return 1
  printf '%s' "$2" >"$(state_path "$1")"
}

# Single-quote escaping for the inner shell `su -c` spawns.
as_quote() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }

# Strip leading and trailing whitespace. Config lists (`SCHEDULES`, `WATCH`) are
# hand-written, so every field goes through this before it is compared.
trim_ws() {
  _tw=$1
  _tw=${_tw#"${_tw%%[![:space:]]*}"}
  _tw=${_tw%"${_tw##*[![:space:]]}"}
  printf '%s' "$_tw"
}

# ------------------------------------------------------- event dispatch
# Observed values reach an action through the root shell's ENVIRONMENT: a plain
# export would not survive `su`, which may reset the environment, so they are
# re-set on the root command line.
EV_ENV=''

ev_reset() { EV_ENV=''; }

ev_set() { # $1 = name, $2 = value
  EV_ENV="$EV_ENV$1='$(as_quote "$2")'; export $1; "
}

_ev_run() { # $1 = 1 to wait, then the pairs; command comes from $ACTION
  _ev_wait=$1
  shift
  ev_reset
  # Pairs are passed as separate args; the last one is the action command.
  while [ $# -gt 1 ]; do
    ev_set "$1" "$2"
    shift 2
  done
  [ $# -ge 1 ] || return 0
  [ -n "$1" ] || return 0
  log "action: $1"
  if [ "$_ev_wait" = 1 ]; then
    as_root "$EV_ENV$1"
  else
    # Detached, like key-remap's gestures: a slow action must not stall the
    # poll loop.
    as_root_detached "$EV_ENV$1"
  fi
}

ev_run() { _ev_run 0 "$@"; }
ev_run_sync() { _ev_run 1 "$@"; }

# ------------------------------------------------------- notifications
# Returns non-zero when nothing could be posted, so the caller can decide (the
# engine's `notify` subcommand turns that into a hard error; a hook usually just
# keeps the log line).
hook_notify() { # $1 = title, $2 = body, $3 = tag (default: hook name)
  if command -v android_notify >/dev/null 2>&1; then
    android_notify "$1" "$2" "${3:-${HOOK_NAME:-android-settings}}" && return 0
  fi
  log "NOTIFICATION: $1 — $2"
  return 1
}

# ------------------------------------------------------------- time
# Zero-padded HH:MM is turned into minutes since midnight and compared
# numerically. The obvious `[ "$a" \> "$b" ]` is not portable (POSIX only
# defines = and != for test), and a raw $((08 * 60)) reads 08 as invalid octal —
# hence the leading-zero strip before the arithmetic.
time_trim_zero() { # "08" -> "8", "00" -> "0"
  _tz=$1
  while [ "${_tz#0}" != "$_tz" ]; do _tz=${_tz#0}; done
  printf '%s' "${_tz:-0}"
}

# Minutes since midnight, or empty when the value is not a padded HH:MM.
time_minutes() { # $1 = HH:MM
  case "$1" in
    [0-9][0-9]:[0-9][0-9]) : ;;
    *) return 0 ;;
  esac
  _tt_h=$(time_trim_zero "${1%%:*}")
  _tt_m=$(time_trim_zero "${1#*:}")
  printf '%s' "$((_tt_h * 60 + _tt_m))"
}

time_hhmm_ge() { # $1 >= $2
  _tg_a=$(time_minutes "$1")
  _tg_b=$(time_minutes "$2")
  [ -n "$_tg_a" ] && [ -n "$_tg_b" ] && [ "$_tg_a" -ge "$_tg_b" ]
}

time_hhmm_lt() { # $1 < $2
  _tl_a=$(time_minutes "$1")
  _tl_b=$(time_minutes "$2")
  [ -n "$_tl_a" ] && [ -n "$_tl_b" ] && [ "$_tl_a" -lt "$_tl_b" ]
}

time_in_window() { # $1 = now, $2 = start, $3 = end (crossing midnight is fine)
  if time_hhmm_lt "$2" "$3"; then
    time_hhmm_ge "$1" "$2" && time_hhmm_lt "$1" "$3"
  else
    time_hhmm_ge "$1" "$2" || time_hhmm_lt "$1" "$3"
  fi
}
