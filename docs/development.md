# Developing

## Repo layout

```
bin/android-settings        engine CLI (apply / verify / lint / get / set / qs-* /
                            hook management / logs / status / notify / apps)
hooks/<name>/run            hook loops (runit-managed)
hooks/<name>/defaults       default env, overridden by hookConfig
lib/su.sh                   root resolution + as_root / as_root_out / as_root_detached
lib/hook.sh                 log, state, quoting, event + notification helpers, time windows
lib/poll.sh                 poll loop, adopt-on-first-run, stable-state confirmation
lib/notify.sh               android_notify via `cmd notification post`
modules/home-manager.nix    the flake's home-manager module (exports homeModules.default)
modules/render.nix          the module's pure text rendering (golden-tested)
props/*.props               default.props = enforced set; the rest is the library
tests/                      the offline suite (run.sh, unit-lib.sh, fake/, fixtures/, stub/)
```

The flake's package output is the engine plus `hooks/`, `props/` and `lib/`.
Shebangs are native Termux paths (`/data/data/com.termux/files/usr/bin/sh`)
because the engine runs both natively and inside the chroot — which is also why
the derivation uses `dontFixup`.

## Authoring a hook

1. `mkdir hooks/<name>/`, add `run` (executable) and `defaults`.
2. Start `run` from the shared libs and take the loop from `poll.sh`:

```sh
#!/data/data/com.termux/files/usr/bin/sh
# <name> — one line, then what it does and which env it reads.
HOOK_LIB_DIR="${HOOK_LIB_DIR:-$HOME/.local/libexec/android-settings/lib}"
. "$HOOK_LIB_DIR/hook.sh"
. "$HOOK_LIB_DIR/poll.sh"
hook_log_init <name>

CHECK_INTERVAL=${CHECK_INTERVAL:-60}
THING_ACTION=${THING_ACTION:-}

step() {
  value=$(as_root_out 'dumpsys something | grep -m1 thing=')
  if poll_is_first_run <name>; then
    poll_mark_adopted <name>
    state_set <name> "$value"
    log "starting from $value"
    return 0
  fi
  [ "$value" = "$(state_get <name>)" ] && return 0
  log "changed: $value"
  ev_run EVENT changed VALUE "$value" "$THING_ACTION"
  state_set <name> "$value"
}

poll_start step
```

3. Rules that keep a hook healthy on a phone:
   - **native Termux only** — sh, sed, sleep, `su`. No nix store paths.
   - **one `su` per poll**: spawning su is the expensive part, so batch the reads
     into a single `as_root_out` string and split it locally.
   - **adopt on first run**, so a restart does not replay the current state as a
     fresh event.
   - **log on change, not every tick** — a 60s hook that logs each pass buries
     its own history (`watchdog` is the model here).
   - **detach actions** (`ev_run`, not `ev_run_sync`) so a slow command cannot
     stall the loop.
   - prefer the platform over Termux:API (`dumpsys`/`cmd` instead of
     `termux-battery-status`, `hook_notify` instead of `termux-notification`).
4. Test it: `sh tests/run.sh`, and
   `android-settings test-hook <name> 5` on the phone for the real thing.

Run shellcheck before committing — CI does, with the flags in `.github/workflows/ci.yml`:

```sh
shellcheck --severity=warning -s sh bin/android-settings lib/*.sh $(ls hooks/*/run | grep -v key-remap)
shellcheck --severity=warning -s bash hooks/key-remap/run
```

## The test suite

```sh
sh tests/run.sh                 # everything
AS_TEST_KEEP=1 sh tests/run.sh  # keep the sandbox for inspection
```

It needs no device and no root. Three pieces make that possible:

- **`tests/fake/su`** sits first on `PATH`. It answers the engine's root probe
  (`su -c 'id -u'` → `0`, which is what `resolve_su` checks) and runs everything
  else with `sh -c`, so the PATH pin, the quoting and the actual commands all
  execute unprivileged.
- **`tests/fake/settings`** and **`tests/fake/dumpsys`** serve `$AS_TEST_DB` and
  `$AS_TEST_DUMPSYS_DIR`, so `apply`/`verify` and the hooks work against a
  controlled device.
- **`ANDROID_PATH`** points at those fakes. Without it the *root* shell's PATH
  pin would reach the real `/system/bin` — and a test's `settings put` would write
  to whatever phone the suite is running on.

`HOME` and `PREFIX` are sandboxed too, so state, logs and runit services land
under a temp dir, and `lib/notify.sh` is swapped for `tests/stub/notify.sh` so
the notification path is *asserted* instead of posted.

It covers: manifest lint (errors and warnings), apply/verify/`--json`/
`--only-changed`/`--dry-run` against the fake DB, include resolution from an
unrelated cwd, `get`/`set`, hook install/sync/remove and the generated service
script, two hooks end-to-end (`battery-low` driven by a fake `dumpsys`,
`key-remap` replaying a captured `getevent` log through `DEVICE_CMD`), and unit
assertions for the `lib/hook.sh` helpers in `tests/unit-lib.sh`.

## Checks

```sh
nix flake check
```

Three checks, all device-free:

| Check | What it asserts |
| --- | --- |
| `shell` | shellcheck (warning and above) and `-n` parse checks over every shell file, with dash and bash |
| `tests` | `tests/run.sh` inside the nix sandbox |
| `render` | golden files for `modules/render.nix`: float/bool/int/list rendering, `cmd:` lines, and the shell-quoting of a hook env value with spaces |

`render` is the one worth knowing about: the module is the only place where a
float, a bool or a `ACTION` with spaces becomes text, and getting it wrong is
silent (Android stores whatever string it is handed). It compares against
expected files, so a change in that rendering fails the check with a diff.

CI (`.github/workflows/ci.yml`) runs the shell/parse/suite job **without** nix —
on the runner `/bin/sh` is dash, which is what Termux uses too — and the flake
check in a second job.
