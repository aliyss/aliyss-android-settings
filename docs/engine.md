# The engine (`bin/android-settings`)

One POSIX shell script, run natively from Termux and inside the nix chroot
(home-manager activation). It owns the manifest format, the QS tile merge, hook
installation and app disabling; everything privileged goes through `su` (see
[root.md](root.md)).

`android-settings` is wrapped into `~/.local/bin` by the dotfiles
(`ensure-nix-wrappers.sh`), like every other nix-provided tool.

## Manifests

```
# comment (also allowed after leading whitespace)
global.window_animation_scale = 0.75   # namespace.key = value
cmd:wm density 440                     # raw command, run as root
qs.add = flashlight,screenrecord       # ensure QS tiles are present
qs.remove = cast                       # ensure QS tiles are absent
include animation                      # splice another manifest here
```

| Line | Meaning |
| --- | --- |
| `namespace.key = value` | `settings put|get`; namespace is `global`, `system` or `secure` |
| `cmd:<shell command>` | arbitrary command, run as root. **Never apply a manifest you have not read.** |
| `qs.add` / `qs.remove` | merge tiles into / out of `secure.sysui_qs_tiles` (see below) |
| `include <target>` | splice another manifest in place (`include=target` also works) |

### Argument resolution

A manifest argument is:

- a **path**, when it contains a slash or ends in `.props` — used as given;
- a **bare name**, resolved against the settings library (`display` →
  `props/display.props`);
- `all`, which expands to every `props/*.props` in sorted order.

With no argument, `props/default.props` is used — the enforced set.

### `include`

An included file is spliced exactly where the line sits, so file order is
execution order. Targets resolve as:

| Target | Resolves to |
| --- | --- |
| `animation` (bare name) | `props/animation.props` |
| `display.props` | relative to **the file that includes it** |
| `/abs/path.props` | as given |

Resolving a path relative to the including file (rather than the shell's cwd) is
what lets a manifest live anywhere and still be applied from a switch, a hook or
a manual run. An include cycle is refused with a warning rather than followed.

## Commands

### Applying and checking

```
android-settings apply [--dry-run] [--only-changed] [NAME|FILE...]
android-settings verify [--json] [NAME|FILE...]
android-settings lint [NAME|FILE...]
```

- **`apply`** writes every line; re-running is harmless. `--dry-run` prints what
  it would do. `--only-changed` reads each key first and skips the write when it
  already matches — one extra root call per key, but a no-op switch stops
  rewriting everything (and stops churning the keys SystemUI watches).
- **`verify`** reads each key back and reports drift. Exit status **1** means at
  least one key does not match — that is what `props-watch` and any CI-ish
  caller keys off. `cmd:` lines have no readable state, so they are counted as
  *unverifiable* and do **not** fail the run (otherwise a manifest containing a
  `cmd:` line could never verify clean, and a re-applying hook would loop).
- **`lint`** is the offline one: no root, no device, no state. It validates
  namespaces, keys, include targets and QS tile names before anything touches
  the phone.

`verify --json` prints one object, for scripts:

```json
{"ok":3,"bad":1,"unverifiable":1,"items":[
  {"key":"global.window_animation_scale","status":"drift","current":"1.0","wanted":"0.75"},
  {"key":"cmd:svc wifi enable","status":"unverifiable","current":"","wanted":"svc wifi enable"}
]}
```

`status` is `ok`, `drift` or `unverifiable`. The exit status still follows
`bad`.

### Lint

Errors (exit 1):

- a namespace that is not `global`/`system`/`secure`;
- a key that is empty or contains a second dot;
- a line that is neither a manifest line, a `cmd:` line, a `qs.*` line, nor an
  include;
- an `qs.add`/`qs.remove` line with no tiles, or an unknown `qs.*` op;
- an include target that does not exist, or an empty include.

Warnings (reported, exit 0):

- a `cmd:` line at all — it is the one line class that runs arbitrary root
  commands, so lint names each one;
- a QS tile that is not in the AOSP/Nothing set (tiles are ROM-extensible, so
  this is a hint, not a verdict);
- a known read-only mirror (`global.wifi_on`, `global.bluetooth_on`,
  `global.airplane_mode_on`, `global.mobile_data`,
  `global.wifi_scan_always_enabled`, `secure.ui_night_mode`,
  `secure.location_providers_allowed`) — writing it looks like it worked;
- an empty value, or a key with characters Android does not use.

```
$ android-settings lint all
[android-settings] lint: clean (6 lines, 0 warning(s))
```

### One-off settings access

```
android-settings get NS KEY
android-settings set NS KEY VALUE
```

A validated passthrough over `settings get|put`, so reading one key does not
mean reaching for `adb`. `get` prints the raw value (`null` when unset).

### The settings library

```
android-settings list-props
```

Prints each `props/*.props` with its first line (the file's own summary).

## Quick Settings tiles

`Settings.Secure.sysui_qs_tiles` is the whole panel as **one** comma-separated
list, so a plain settings line can only replace it wholesale. `qs.add` /
`qs.remove` merge instead: read the live list, patch only the named tiles, write
it back, restart SystemUI. That makes them idempotent and verifiable.

```
android-settings qs-list
android-settings qs-add flashlight screenrecord
android-settings qs-remove cast nfc
```

SystemUI is restarted after a write so the panel actually changes. Set
`NO_QS_RELOAD=1` to skip that (headless applies, tests).

## Apps

```
android-settings disable-app PKG...
android-settings enable-app PKG...
android-settings list-disabled
```

`pm disable-user --user 0` is the generic, reversible mechanism — it works for
any user app and most system apps on any Android; `pm hide` needs system perms
and `pm suspend` is device-policy territory. Declaratively:
`aliyss.androidSettings.disabledApps` in the dotfiles (ids removed from the list
are re-enabled on the next switch). Per-app appops/roles/standby-buckets live in
[props.md](props.md#appsprops).

## Hooks

```
android-settings install-hook NAME [--env-file FILE]
android-settings sync-hooks [--env-dir DIR] [--dry-run] NAME...
android-settings remove-hook NAME
android-settings list-hooks
android-settings restart-hook NAME
android-settings reinstall-hooks [NAME...]
android-settings test-hook NAME [SECONDS]
android-settings log NAME [-f] [-n LINES]
android-settings logs
android-settings status
```

- **`install-hook`** copies the hook and the shared libs out of the package into
  `~/.local/libexec/android-settings/` (the nix store is invisible to a
  runit-spawned process) and writes the service run script. Installing *is* what
  creates the runit service; nothing here starts a hook by itself.
- **`sync-hooks`** is the declarative path home-manager calls: it receives the
  full list the dotfiles want, installs or refreshes those, removes what the
  previous declaration had and this one does not (tracked in
  `~/.local/state/aliyss-android-settings/hooks`), and leaves an unchanged hook
  alone — no restart.
- **`reinstall-hooks`** re-copies installed hooks from the package, keeping each
  hook's own env file. This is the "I edited the hook and want it live now" path
  that would otherwise mean waiting for the next switch.
- **`restart-hook`** bounces one service.
- **`test-hook NAME [SECONDS]`** runs a hook once in the foreground with its real
  env (default 5s timeout, `0` = no timeout, Ctrl-C to stop). It uses the
  installed env file when there is one and the package defaults otherwise, so a
  test matches the service as closely as possible.
- **`log` / `logs`** tail one hook's log or list every installed hook's log with
  its size and last write. A hook that has gone quiet is usually the first
  symptom of a wedged service — `watchdog` exists for that.
- **`status`** prints the declared hook ledger, each installed service's runit
  status and last log line, and which root route is in use.

## Notifications

```
android-settings notify TITLE [BODY] [TAG]
```

Posts through `cmd notification post` as the shell identity — no Termux:API
app. The tag keeps re-posts of the same alert from stacking. See
[root.md](root.md#why-notifications-drop-as-root) for why the identity matters.

## Environment

| Variable | Effect |
| --- | --- |
| `NO_QS_RELOAD=1` | do not restart SystemUI after a tile change |
| `ANDROID_PATH` | the PATH pinned inside the root shell (default `/system/bin:/system/xbin:/vendor/bin`); the test suite points it at its fakes |
| `KSUD_LIB`, `KSUD_LINKER` | where KernelSU's `libksud.so` and the dynamic linker live, for the chroot root route |
| `AS_STATE_BASE` | state root (default `~/.local/state/aliyss-android-settings`) |
