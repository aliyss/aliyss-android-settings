#!/data/data/com.termux/files/usr/bin/sh
# unit-lib.sh — assertions for the shared hook helpers (lib/hook.sh).
#
# Run by tests/run.sh with HOOK_LIB_DIR pointing at the throwaway lib dir it
# builds (the real su.sh/hook.sh/poll.sh + the notification stub), and HOME in a
# sandbox, so this file exercises the helpers and the state files they own.
#
# Exits non-zero when any assertion fails; the per-case lines are the report.

. "$HOOK_LIB_DIR/hook.sh"
. "$HOOK_LIB_DIR/poll.sh"
# poll_confirm logs through log(), which hook_log_init defines — the same as a
# real hook, so this also covers that path.
hook_log_init unit-lib

fails=0
t() { # $1 = label, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s: expected [%s] got [%s]\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}

# --- time helpers: leading zeros are the trap ($((08)) is invalid octal) ---
t "time_minutes 00:00" 0 "$(time_minutes 00:00)"
t "time_minutes 08:30" 510 "$(time_minutes 08:30)"
t "time_minutes 09:05" 545 "$(time_minutes 09:05)"
t "time_minutes 23:59" 1439 "$(time_minutes 23:59)"
t "time_minutes 7:30 (unpadded) is rejected" '' "$(time_minutes 7:30)"
t "time_minutes nonsense is rejected" '' "$(time_minutes nope)"

if time_in_window 10:00 09:00 11:00; then r=yes; else r=no; fi
t "window 09:00-11:00 contains 10:00" yes "$r"
if time_in_window 08:30 09:00 11:00; then r=yes; else r=no; fi
t "window 09:00-11:00 excludes 08:30" no "$r"
if time_in_window 23:30 23:00 07:00; then r=yes; else r=no; fi
t "window crossing midnight contains 23:30" yes "$r"
if time_in_window 03:00 23:00 07:00; then r=yes; else r=no; fi
t "window crossing midnight contains 03:00" yes "$r"
if time_in_window 12:00 23:00 07:00; then r=yes; else r=no; fi
t "window crossing midnight excludes 12:00" no "$r"
if time_in_window 08:00 23:00 07:00; then r=yes; else r=no; fi
t "window crossing midnight excludes the end minute" no "$r"

# --- text helpers ---
t "trim_ws removes both ends" "a b" "$(trim_ws '   a b   ')"
t "trim_ws leaves inner spacing" "a  b" "$(trim_ws 'a  b')"
t "trim_ws on an empty string" "" "$(trim_ws '')"

# as_quote turns one single quote into the '\'' dance the root shell needs.
# (`it'\''s` written in double quotes: \\ -> \ and \' -> ', so the expected
# value is literally the escaped form.)
expected="it'\\''s"
t "as_quote escapes a single quote" "$expected" "$(as_quote "it's")"
t "as_quote leaves plain text alone" "plain" "$(as_quote plain)"

# --- state files ---
state_set unit-lib "hello"
t "state_set/state_get round-trip" "hello" "$(state_get unit-lib)"
state_set unit-lib "two
lines"
t "state_set keeps newlines" "two
lines" "$(state_get unit-lib)"
t "state_get on a missing name is empty" "" "$(state_get no-such-state)"

# --- poll helpers ---
if poll_is_first_run unit-lib; then r=yes; else r=no; fi
t "poll_is_first_run is true before the marker" yes "$r"
poll_mark_adopted unit-lib
if poll_is_first_run unit-lib; then r=yes; else r=no; fi
t "poll_is_first_run is false after the marker" no "$r"

# poll_confirm needs two calls for the same candidate before it can confirm (the
# first one records when the candidate was first seen).
poll_clear unit-confirm
if poll_confirm unit-confirm playing 0; then r=yes; else r=no; fi
t "poll_confirm does not confirm on first sight" no "$r"
if poll_confirm unit-confirm playing 0; then r=yes; else r=no; fi
t "poll_confirm confirms once it has held" yes "$r"
if poll_confirm unit-confirm paused 0; then r=yes; else r=no; fi
t "poll_confirm restarts on a new candidate" no "$r"
poll_clear unit-confirm
if poll_confirm unit-confirm paused 0; then r=yes; else r=no; fi
t "poll_clear forces a fresh confirmation" no "$r"

exit $((fails > 0))
