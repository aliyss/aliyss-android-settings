#!/data/data/com.termux/files/usr/bin/sh
# tests/run.sh — the offline test suite.
#
# Everything here runs without a device and without root:
#
#   * PATH comes first, so the fake `su`/`settings`/`dumpsys` in tests/fake are
#     what the engine and the hooks find;
#   * ANDROID_PATH points at those fakes, so the ROOT shell's PATH pin (lib/su.sh)
#     cannot reach the real /system/bin — without this a test's `settings put`
#     would write to the phone the suite happens to run on;
#   * HOME and PREFIX are sandboxes, so state, logs and runit services are
#     written under $WORK and never near ~/.local or Termux's var/service;
#   * lib/notify.sh is replaced by tests/stub/notify.sh, so a hook's
#     notification path is asserted instead of posted.
#
#   sh tests/run.sh            # run everything (keeps nothing)
#   AS_TEST_KEEP=1 sh tests/run.sh   # keep $WORK for inspection
#
# Exit status is the number of failing assertions, capped at 1 (0 = all good).

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TESTS="$ROOT/tests"
FAKE="$TESTS/fake"
ENGINE="$ROOT/bin/android-settings"

WORK=${AS_TEST_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/android-settings-tests.XXXXXX")}
export HOME="$WORK/home"
export PREFIX="$WORK/prefix"
export AS_TEST_DB="$WORK/settings.db"
export AS_TEST_DUMPSYS_DIR="$WORK/dumpsys"
export NO_QS_RELOAD=1
export ANDROID_PATH="$FAKE"
PATH="$FAKE:$PATH"
export PATH

LIBEXEC="$HOME/.local/libexec/android-settings"
STATE="$HOME/.local/state/aliyss-android-settings"

mkdir -p "$HOME" "$PREFIX" "$AS_TEST_DUMPSYS_DIR"

PASS=0
FAIL=0
OUT=""
ERR=""

ok() {
  PASS=$((PASS + 1))
  printf 'ok   %s\n' "$1"
}

bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL %s: %s\n' "$1" "$2"
}

# run_capture CMD... — capture stdout/stderr and the exit status.
run_capture() {
  "$@" >"$WORK/out" 2>"$WORK/err"
  RC=$?
  OUT=$(cat "$WORK/out" 2>/dev/null || true)
  ERR=$(cat "$WORK/err" 2>/dev/null || true)
}

expect_exit() { # $1 = label, $2 = wanted status, rest = command
  _lbl=$1
  _want=$2
  shift 2
  run_capture "$@"
  if [ "$RC" = "$_want" ]; then
    ok "$_lbl"
  else
    bad "$_lbl" "exit $RC (want $_want) — stderr: $(printf '%s' "$ERR" | head -3 | tr '\n' ' ')"
  fi
}

expect_has() { # $1 = label, $2 = needle  (searches the last captured stdout+stderr)
  case "$OUT$ERR" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "missing [$2] in: $(printf '%s' "$OUT$ERR" | head -5 | tr '\n' ' ')" ;;
  esac
}

expect_hasnt() { # $1 = label, $2 = needle
  case "$OUT$ERR" in
    *"$2"*) bad "$1" "unexpected [$2] in: $(printf '%s' "$OUT$ERR" | head -5 | tr '\n' ' ')" ;;
    *) ok "$1" ;;
  esac
}

# The engine is run through `sh` so the suite tests POSIX shell behaviour, not
# the shebang line.
engine() { sh "$ENGINE" "$@"; }

db_get() { # $1 = "ns.key"
  awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$AS_TEST_DB" 2>/dev/null
}

db_set() { sh "$FAKE/settings" put "$1" "$2" "$3"; }

reset_db() { rm -f "$AS_TEST_DB"; }

echo "== build the test lib dir (real libs + notification stub) =="
mkdir -p "$WORK/lib"
cp "$ROOT/lib/su.sh" "$ROOT/lib/hook.sh" "$ROOT/lib/poll.sh" "$WORK/lib/"
cp "$TESTS/stub/notify.sh" "$WORK/lib/notify.sh"
printf 'lib dir: %s\n\n' "$WORK/lib"

# ------------------------------------------------------------------ lint
echo "== lint =="
expect_exit "lint clean fixture exits 0" 0 engine lint "$TESTS/fixtures/clean.props"
expect_has "lint clean says clean" "lint: clean"

expect_exit "lint messy fixture exits 1" 1 engine lint "$TESTS/fixtures/messy.props"
expect_has "lint flags a bad namespace" "bad namespace: badns.key"
expect_has "lint flags a non-manifest line" "not a manifest line"
expect_has "lint flags a missing include target" "include target not found"
expect_has "lint warns about an unknown QS tile" "unknown QS tile (ROM-dependent): nosuchtile"
expect_hasnt "lint does not flag a real QS tile" "unknown QS tile (ROM-dependent): flashlight"
expect_has "lint warns about a mirror key" "read-only mirror"
expect_has "lint warns about a root command" "root command (verify cannot check it)"
expect_has "lint warns about an empty value" "empty value"

expect_exit "lint survives an include cycle" 0 engine lint "$TESTS/fixtures/cycle.props"
expect_exit "lint rejects a missing manifest" 1 engine lint "$TESTS/fixtures/no-such-file.props"
expect_has "lint names the missing manifest" "manifest not found"

# An include path belongs to the file that writes it, not to the shell that
# happens to invoke the engine: run the same lint from an unrelated cwd.
(
  cd "$WORK" || exit 1
  sh "$ENGINE" lint "$TESTS/fixtures/clean.props"
) >"$WORK/out" 2>"$WORK/err"
RC=$?
OUT=$(cat "$WORK/out" 2>/dev/null || true)
ERR=$(cat "$WORK/err" 2>/dev/null || true)
if [ "$RC" = 0 ]; then
  ok "include paths resolve relative to the including file"
else
  bad "include paths resolve relative to the including file" "exit $RC — $ERR"
fi

# ---------------------------------------------------------- apply / verify
echo
echo "== apply / verify (fake settings db) =="
reset_db
expect_exit "apply writes the manifest" 0 engine apply "$TESTS/fixtures/clean.props"
expect_has "apply logs the write" "set: global.window_animation_scale = 0.75"
if [ "$(db_get global.window_animation_scale)" = 0.75 ]; then
  ok "apply stored the float verbatim"
else
  bad "apply stored the float verbatim" "got [$(db_get global.window_animation_scale)]"
fi
if [ "$(db_get system.screen_brightness)" = 128 ]; then
  ok "apply stored an int"
else
  bad "apply stored an int" "got [$(db_get system.screen_brightness)]"
fi
if [ "$(db_get global.transition_animation_scale)" = 0.75 ]; then
  ok "include spliced the other manifest"
else
  bad "include spliced the other manifest" "got [$(db_get global.transition_animation_scale)]"
fi

expect_exit "verify is clean right after apply" 0 engine verify "$TESTS/fixtures/clean.props"
expect_has "verify reports the count" "verify: 4 ok, 0 not matching"
expect_has "verify counts the include" "verify: 4 ok"

expect_exit "verify --json exits 0 when clean" 0 engine verify --json "$TESTS/fixtures/clean.props"
expect_has "verify --json emits json" '{"ok":'
expect_hasnt "verify --json has no drift when clean" '"status":"drift"'

# Drift the DB, then check both the exit status and the JSON payload.
db_set system screen_brightness 99
expect_exit "verify exits 1 on drift" 1 engine verify "$TESTS/fixtures/clean.props"
expect_has "verify names the drifted key" "diff: system.screen_brightness"
expect_exit "verify --json exits 1 on drift" 1 engine verify --json "$TESTS/fixtures/clean.props"
expect_has "verify --json reports drift" '"status":"drift"'
expect_has "verify --json carries current and wanted" '"current":"99"'
expect_has "verify --json carries wanted" '"wanted":"128"'

expect_exit "apply --only-changed repairs" 0 engine apply --only-changed "$TESTS/fixtures/clean.props"
expect_has "only-changed skips matching keys" "unchanged: global.window_animation_scale"
expect_has "only-changed writes the drifted key" "set: system.screen_brightness = 128"
expect_exit "verify is clean after the repair" 0 engine verify "$TESTS/fixtures/clean.props"

# cmd: lines have no readable state, so verify marks them unverifiable — and
# still exits 0, or props-watch could never see a clean manifest.
reset_db
expect_exit "apply mixed manifest" 0 engine apply "$TESTS/fixtures/mixed.props"
expect_exit "verify mixed manifest still exits 0" 0 engine verify --json "$TESTS/fixtures/mixed.props"
expect_has "verify marks cmd: lines unverifiable" '"status":"unverifiable"'
expect_has "verify counts unverifiable lines" '"unverifiable":1'
expect_has "verify has no drift" '"bad":0'
expect_has "verify merges qs tiles" "qs.add flashlight"

expect_exit "apply --dry-run changes nothing" 0 engine apply --dry-run "$TESTS/fixtures/clean.props"
expect_has "dry-run says what it would do" "would set: global.window_animation_scale = 0.75"

expect_exit "verify rejects an unknown option" 1 engine verify --bogus
expect_exit "apply rejects --json" 1 engine apply --json

# ------------------------------------------------------------- get / set
echo
echo "== get / set =="
expect_exit "set writes a value" 0 engine set global test.key 42
expect_has "set logs the write" "set: global.test.key = 42"
expect_exit "get reads it back" 0 engine get global test.key
expect_has "get printed the value" "42"
expect_exit "get rejects a bad namespace" 1 engine get nonsense key
expect_has "get explains the namespace" "bad namespace"
expect_exit "set needs a value" 1 engine set global key

# ---------------------------------------------------------------- hooks
echo
echo "== hook install / sync / remove (sandboxed PREFIX) =="
expect_exit "install-hook battery-low" 0 engine install-hook battery-low
if [ -x "$LIBEXEC/hooks/battery-low/run" ]; then
  ok "install-hook copied the run script"
else
  bad "install-hook copied the run script" "$LIBEXEC/hooks/battery-low/run is missing"
fi
for lib in su.sh hook.sh poll.sh notify.sh; do
  if [ -f "$LIBEXEC/lib/$lib" ]; then
    ok "install-hook copied lib/$lib"
  else
    bad "install-hook copied lib/$lib" "$LIBEXEC/lib/$lib is missing"
  fi
done
if grep -q 'HOOK_LIB_DIR=' "$PREFIX/var/service/android-settings-battery-low/run" 2>/dev/null; then
  ok "service run script exports HOOK_LIB_DIR"
else
  bad "service run script exports HOOK_LIB_DIR" "not found in the generated service script"
fi

expect_exit "list-hooks shows it installed" 0 engine list-hooks
expect_has "list-hooks marks battery-low installed" "battery-low"

expect_exit "sync-hooks --dry-run" 0 engine sync-hooks --dry-run battery-low net-watch
expect_has "sync-hooks reports the unchanged hook" "unchanged: battery-low"
expect_has "sync-hooks would install the new one" "would install: net-watch"
expect_exit "sync-hooks rejects a bad name" 1 engine sync-hooks 'bad name'

expect_exit "test-hook rejects an unknown hook" 1 engine test-hook no-such-hook
expect_has "test-hook explains why" "no such hook"

expect_exit "remove-hook battery-low" 0 engine remove-hook battery-low
if [ -d "$LIBEXEC/hooks/battery-low" ]; then
  bad "remove-hook deleted the copy" "$LIBEXEC/hooks/battery-low still exists"
else
  ok "remove-hook deleted the copy"
fi

echo
echo "== hook behaviour (fake dumpsys + stub notify) =="
# battery-low at 10% with a 15% threshold must try to notify and remember it.
cp "$TESTS/fixtures/dumpsys/battery" "$AS_TEST_DUMPSYS_DIR/battery"
rm -f "$STATE/state/battery-low.notified"
HOOK_LIB_DIR="$WORK/lib" CHECK_INTERVAL=1 THRESHOLD=15 sh "$ROOT/hooks/battery-low/run" \
  >"$WORK/battery-low.log" 2>&1 &
_battery_pid=$!
sleep 2
kill "$_battery_pid" 2>/dev/null || true
wait "$_battery_pid" 2>/dev/null || true
case "$(cat "$WORK/battery-low.log" 2>/dev/null)" in
  *"watching battery (notify <= 15%"*) ok "battery-low logs its configuration" ;;
  *) bad "battery-low logs its configuration" "$(head -3 "$WORK/battery-low.log" 2>/dev/null | tr '\n' ' ')" ;;
esac
case "$(cat "$WORK/battery-low.log" 2>/dev/null)" in
  *"NOTIFICATION: Battery low"*) ok "battery-low falls back to a log line" ;;
  *) bad "battery-low falls back to a log line" "$(head -5 "$WORK/battery-low.log" 2>/dev/null | tr '\n' ' ')" ;;
esac
case "$(cat "$WORK/battery-low.log" 2>/dev/null)" in
  *"dumpsys battery failed"*) bad "battery-low read the fake dumpsys" "it reported a read failure" ;;
  *) ok "battery-low read the fake dumpsys" ;;
esac
if [ "$(cat "$STATE/state/battery-low.notified" 2>/dev/null)" = 1 ]; then
  ok "battery-low remembered that it fired"
else
  bad "battery-low remembered that it fired" "state is [$(cat "$STATE/state/battery-low.notified" 2>/dev/null)]"
fi

# key-remap replays a captured getevent log: a short press must fire
# SINGLE_ACTION. DEVICE_CMD keeps the pipe open (the `sleep`) so the loop gets
# the tick that resolves the pending single press.
echo
rm -f "$WORK/fired"
# key-remap is the one bash hook, so it is run with bash.
HOOK_LIB_DIR="$WORK/lib" NO_CLEANUP=1 \
  DEVICE_CMD="cat $TESTS/fixtures/getevent/short.log; sleep 2" \
  SINGLE_ACTION="printf short >> $WORK/fired" \
  bash "$ROOT/hooks/key-remap/run" >"$WORK/key-remap.log" 2>&1 &
_key_pid=$!
sleep 2
kill "$_key_pid" 2>/dev/null || true
wait "$_key_pid" 2>/dev/null || true
case "$(cat "$WORK/fired" 2>/dev/null)" in
  *short*) ok "key-remap fires the short-press action on a replayed log" ;;
  *) bad "key-remap fires the short-press action on a replayed log" \
    "fired=[$(cat "$WORK/fired" 2>/dev/null)] log=$(head -3 "$WORK/key-remap.log" 2>/dev/null | tr '\n' ' ')" ;;
esac

# ------------------------------------------------------------------ status
echo
echo "== status / logs / list =="
expect_exit "status runs with no hooks installed" 0 engine status
expect_has "status reports the empty ledger" "no hooks installed"
expect_exit "log rejects an unknown hook log" 1 engine log no-such-hook
expect_has "log explains the missing log" "no log for hook"
expect_exit "logs runs with no logs" 1 engine logs
expect_exit "list-props lists the library" 0 engine list-props
expect_has "list-props includes the new cookbooks" "notifications"
expect_has "list-props includes apps" "apps"
expect_exit "no arguments prints usage" 1 engine
expect_exit "unknown command exits 1" 1 engine frobnicate

# ------------------------------------------------------------- unit libs
echo
echo "== lib/hook.sh units =="
HOOK_LIB_DIR="$WORK/lib" sh "$TESTS/unit-lib.sh"
if [ $? -eq 0 ]; then
  ok "lib unit assertions"
else
  bad "lib unit assertions" "see the FAIL lines above"
fi

# ------------------------------------------------------------------ report
echo
printf '== %s passed, %s failed ==\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'work dir kept for inspection: %s\n' "$WORK"
  exit 1
fi
if [ "${AS_TEST_KEEP:-0}" != 1 ]; then
  rm -rf "$WORK"
fi
exit 0
