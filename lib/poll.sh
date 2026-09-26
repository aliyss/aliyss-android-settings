#!/data/data/com.termux/files/usr/bin/sh
# poll.sh — the loop shape every polling hook reimplemented: run a step function
# on a fixed interval, adopt the current state on the very first run instead of
# firing on boot, and only act on a state that has held for a while.
#
# Sourced after hook.sh (it uses log/state_set). A hook's whole loop becomes:
#
#   step() {
#     have=$(read_something)
#     if poll_is_first_run net-watch; then
#       poll_mark_adopted net-watch
#       state_set net-watch "$have"
#       log "starting from $have"
#     elif [ "$have" != "$(state_get net-watch)" ]; then
#       ...
#     fi
#   }
#   poll_start step
#
# API:
#   poll_start STEP_FN            call STEP_FN every $CHECK_INTERVAL seconds
#   poll_sleep SECONDS            plain sleep (steps that manage their own loop)
#   poll_is_first_run NAME        1 until poll_mark_adopted NAME
#   poll_mark_adopted NAME
#   poll_confirm NAME KIND SECS   0 once KIND has held for SECS (debounce)
#   poll_clear NAME               forget a pending confirmation

# Fix the interval from the hook's env once, so a step that exports
# CHECK_INTERVAL cannot change the loop under itself.
poll_start() { # $1 = step function name
  _poll_step=$1
  _poll_interval=${CHECK_INTERVAL:-60}
  [ "$_poll_interval" -ge 1 ] 2>/dev/null || _poll_interval=60
  while :; do
    # Time the interval from the START of the step, not from the end of it, so
    # a slow step (a `su` spawn, a dumpsys sweep) does not silently stretch the
    # period.
    _poll_t0=$(date +%s)
    "$_poll_step" || true
    _poll_spent=$(( $(date +%s) - _poll_t0 ))
    _poll_wait=$((_poll_interval - _poll_spent))
    [ "$_poll_wait" -ge 1 ] || _poll_wait=1
    poll_sleep "$_poll_wait"
  done
}

poll_sleep() { sleep "$1"; }

# The first run adopts whatever is already true (the phone is on 40% battery,
# the network is up) instead of replaying it as a fresh event on boot. One
# marker per hook, so it survives restarts and only ever happens once.
poll_is_first_run() { [ ! -f "$(state_path "$1.adopted")" ]; }

poll_mark_adopted() { state_set "$1.adopted" "adopted $(date '+%Y-%m-%d %H:%M:%S')"; }

# Only report a change that has held for SECS, so a fast Wi-Fi/mobile flap never
# reaches the user. The candidate lives in state/<name>.pending as "<kind>
# <epoch>".
poll_confirm() { # $1 = name, $2 = observed kind, $3 = min stable seconds
  _pc_now=$(date +%s)
  _pc_read=$(cat "$(state_path "$1.pending")" 2>/dev/null || true)
  _pc_kind=${_pc_read%% *}
  _pc_since=${_pc_read##* }
  if [ -z "$_pc_read" ] || [ "$_pc_kind" != "$2" ]; then
    state_set "$1.pending" "$2 $_pc_now"
    log "candidate: $2 (confirming for ${3}s)"
    return 1
  fi
  [ $((_pc_now - _pc_since)) -ge "$3" ] || return 1
  log "held ${3}s: $2"
  return 0
}

poll_clear() { rm -f "$(state_path "$1.pending")" 2>/dev/null || true; }
