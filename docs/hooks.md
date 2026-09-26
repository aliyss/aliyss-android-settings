# Hooks (`hooks/`)

Long-running loops supervised by termux-services (runit), one service per hook:
`android-settings-<hook>`. They autostart at Termux boot and are env-tuned from
the dotfiles' `hookConfig`.

Nothing in this repo starts a hook: each one ships as *available* and only
becomes a service once the dotfiles declare it (home-manager calls
`install-hook`), so the flake can carry hooks the phone does not use without
them running.

## The contract

A hook is a directory `hooks/<name>/`:

- **`run`** (executable) — the loop. It is sourced with env, then executed under
  `#!/data/data/com.termux/files/usr/bin/sh`; it must loop forever and sleep
  between checks. **Native Termux only** (sh, sed, sleep, `su -c`) — no nix store
  paths, which are invisible to native Termux. Prefer the platform over
  Termux:API: `dumpsys`/`cmd` as root instead of `termux-battery-status`.
- **`defaults`** — `KEY=value` lines, sourced before the home-manager env file
  (so `hookConfig` overrides). Every hook ships its defaults here, and an empty
  action (`ACTION=`) means "configured to do nothing yet".

Installed copies live in `~/.local/libexec/android-settings/hooks/<name>/`
(`run`, `defaults`, and `env` when `hookConfig` set one), with the shared libs in
`../lib/`. Logs: `~/.local/state/aliyss-android-settings/logs/<hook>.log`, with a
marker line per runit spawn. Per-hook state lives in
`~/.local/state/aliyss-android-settings/state/`.

## The shared libraries

Every hook used to carry its own copy of `log()`, the su resolution, the state
file handling and the notification fallback. Those now live in `lib/` and are
sourced through one line:

```sh
HOOK_LIB_DIR="${HOOK_LIB_DIR:-$HOME/.local/libexec/android-settings/lib}"
. "$HOOK_LIB_DIR/hook.sh"
. "$HOOK_LIB_DIR/poll.sh"
hook_log_init battery-low          # defines log() with a [battery-low] tag
```

| File | Provides |
| --- | --- |
| `lib/su.sh` | `resolve_su` (probe + the ksud shim route), `need_root`, `as_root` (with retries), `as_root_out` (single call, stdout only — the poll-loop workhorse), `as_root_detached` (actions) |
| `lib/hook.sh` | `log`, `state_get`/`state_set`, `as_quote`, `trim_ws`, `EV_ENV`/`ev_reset`/`ev_set`, `ev_run`/`ev_run_sync`, `hook_notify`, `time_minutes`/`time_hhmm_ge`/`time_hhmm_lt`/`time_in_window` |
| `lib/poll.sh` | `poll_start STEP_FN` (interval loop, timed from the start of each step so a slow step does not stretch the period), `poll_is_first_run`/`poll_mark_adopted`, `poll_confirm` (only act on a state that has held for N seconds), `poll_clear` |
| `lib/notify.sh` | `android_notify TITLE BODY [TAG]` — see [root.md](root.md#why-notifications-drop-as-root) |

`install-hook` copies all four next to the hooks and exports `HOOK_LIB_DIR`, so a
hook never needs a store path. `test-hook` points `HOOK_LIB_DIR` at the in-tree
`lib/` for the same reason.

Need to notify the user? Source the helper and call it — it returns non-zero when
it could not post, so the caller decides what to log:

```sh
hook_notify 'Battery low' 'Battery at 12% (alert at 15%)' battery-low ||
  log "NOTIFICATION: ..."
```

## Event sources vs actors

Some hooks *do* one thing (night-dnd, night-dark, battery-low, thermal-watch,
chroot-dns, watchdog). Others are **event sources**: they publish what they see
and the dotfiles decide what happens, through `*_ACTION` env vars. A slow action
is run detached as root, so it cannot stall the poll loop.

| Event source | Event | Action env |
| --- | --- | --- |
| `brightness` | `mode` / `level` | `EVENT`, `MODE`/`PREV_MODE`, `BRIGHTNESS`/`PREV_BRIGHTNESS`, `PERCENT`/`PREV_PERCENT` |
| `notification` | `posted` | `PACKAGE` `UID` `USER` `ID` `TAG` `KEY` `TITLE` `TEXT` `CHANNEL` `IMPORTANCE` |
| `screen-state` | `screen_on` / `screen_off` | `WAKE`/`PREV_WAKE` |
| `power-watch` | `plugged` / `unplugged` / `full` | `PLUGGED`/`PLUG_LABEL`, `STATUS`/`STATUS_LABEL`, `LEVEL` |
| `lock-watch` | `locked` / `unlocked` | `PREV_EVENT` |
| `media-watch` | `playing` / `paused` / `stopped` / `buffering` | `STATE`, `TITLE`, `ARTIST` |
| `boot-hook` | `boot` | `BOOT_ID`, `PREV_BOOT_ID` |

Every polling hook adopts the current state on its first run instead of firing on
boot, and remembers what it last saw in `state/<name>`, so a restart stays quiet.

## Catalogue

| Hook | What it does | Root? |
| --- | --- | --- |
| [`battery-low`](#battery-low) | notify at a battery threshold, re-arm when charging | yes (`dumpsys`) |
| [`thermal-watch`](#thermal-watch) | notify when the battery gets hot; follow the thermal throttle | yes (`dumpsys`) |
| [`power-watch`](#power-watch) | events for charger plug / unplug / full | yes (`dumpsys`) |
| [`net-watch`](#net-watch) | notify when the active network changes | yes (`ip`, `dumpsys`) |
| [`screen-state`](#screen-state) | events for screen on / off | yes (`dumpsys`) |
| [`lock-watch`](#lock-watch) | events for device lock / unlock | yes (`dumpsys`) |
| [`media-watch`](#media-watch) | events for playback changes | yes (`dumpsys`) |
| [`notification`](#notification) | run an action per new notification | yes (`cmd notification`) |
| [`brightness`](#brightness) | events for auto/manual flips and level moves | yes (`settings`) |
| [`night-dnd`](#night-dnd) | DND on a daily window | yes (`cmd notification`) |
| [`night-dark`](#night-dark) | dark theme on a daily window | yes (`cmd uimode`) |
| [`schedule`](#schedule) | run commands at `HH:MM` | yes |
| [`key-remap`](#key-remap) | short / double / long press remapping at the evdev layer | yes (`getevent`) |
| [`boot-hook`](#boot-hook) | run an action once per device boot | yes |
| [`props-watch`](#props-watch) | re-apply a manifest when `verify` reports drift | via the engine |
| [`watchdog`](#watchdog) | bring back any service that is not running | no |
| [`chroot-dns`](#chroot-dns) | keep name resolution working inside the Nix chroot | no |

---

### battery-low

Notify when the battery crosses the threshold, with hysteresis: once fired it
stays quiet until the phone is charging again or the level reaches `REARM_AT`.

| Env | Default | Meaning |
| --- | --- | --- |
| `THRESHOLD` | `15` | notify at/below this percentage |
| `REARM_AT` | `THRESHOLD+5` | re-arm at/above this percentage |
| `CHECK_INTERVAL` | `300` | seconds between polls |

`dumpsys battery` as root; the notification goes through the shared helper (no
Termux:API).

### thermal-watch

Two signals from one root shell per poll: battery temperature (`dumpsys battery`,
tenths of a degree) and the platform thermal status (`dumpsys thermalservice`).

| Env | Default | Meaning |
| --- | --- | --- |
| `MAX_TEMP` | `42` | notify at/above this battery temperature (°C) |
| `REARM_TEMP` | `40` | re-arm at/below this temperature |
| `STATUS_ALERT` | `2` | notify when thermal status reaches this level (2 = moderate) |
| `HOT_ACTION` / `ACTION` | — | command run as root when hot, with `EVENT=hot`, `TEMP`, `PERCENT_TEMP`, `STATUS` |
| `NOTIFY` | `1` | post a notification |

Temperature uses the same hysteresis as `battery-low`, so a phone hovering on the
threshold does not notify every poll. A rising thermal status is reported once on
the transition into an at-or-above-`STATUS_ALERT` level.

### power-watch

The other half of the charging story: events for plugging in, unplugging and
reaching full. Same source as `battery-low` (`dumpsys battery`), so a device with
both hooks reads it twice per interval — they are cheap and independent, but
`CHECK_INTERVAL` on each is worth thinking about together.

| Env | Default | Meaning |
| --- | --- | --- |
| `PLUG_ACTION` / `UNPLUG_ACTION` / `FULL_ACTION` | — | commands run as root per event |
| `ACTION` | — | shared fallback |
| `NOTIFY` | `0` | notify on plug/unplug |
| `NOTIFY_FULL` | `1` | notify when full (also implied by `NOTIFY`) |

### net-watch

Notifies when the active network changes — Wi-Fi → mobile → offline → VPN — once
the new state has held for `MIN_STABLE` seconds, so a quick Wi-Fi/mobile flip
never reaches you (`poll_confirm` does the debounce).

It asks the kernel which interface a packet to `PROBE_TARGET` would actually
leave through (`ip route get`), which respects Android's per-network routing and
VPNs. Note `/proc/net/route` is useless here: the main table holds only the
on-link peer routes and no default entry. The interface is labelled (`wlan0` →
Wi-Fi, `rmnet*`/`ccmni*`/`pdp*` → mobile, `tun*`/`ppp*` → VPN) and, on Wi-Fi, the
SSID is read from the `mWifiInfo` dump.

```nix
aliyss.androidSettings.hookConfig."net-watch" = {
  CHECK_INTERVAL = "60";     # seconds between checks
  MIN_STABLE = "30";         # seconds a state must hold before notifying
  PROBE_TARGET = "1.1.1.1";  # address used for the route lookup
};
```

### screen-state

Publishes screen wake/sleep. Detection is `dumpsys power`'s wakefulness
(`Awake` / `Asleep` / `Dozing`), falling back to `dumpsys display`'s
`mScreenState`; both greps run in one root shell.

| Env | Default | Meaning |
| --- | --- | --- |
| `CHECK_INTERVAL` | `15` | seconds between polls |
| `SCREEN_ON_ACTION` / `SCREEN_OFF_ACTION` | — | commands run as root per event |
| `ACTION` | — | shared fallback |
| `NOTIFY` | `0` | post a notification per event |

### lock-watch

Publishes device lock/unlock from the window manager's keyguard flags. ROMs
disagree about which of `mDreamingLockscreen`, `mShowingLockscreen`,
`mKeyguardShowing` they print (Android 15 renamed some), so it greps several and
takes any `true` as locked. A ROM that prints none of them yields `unknown` and
the hook does nothing rather than guessing.

| Env | Default | Meaning |
| --- | --- | --- |
| `CHECK_INTERVAL` | `10` | seconds between polls |
| `LOCK_ACTION` / `UNLOCK_ACTION` | — | commands run as root per event |
| `ACTION` | — | shared fallback |
| `NOTIFY` | `0` | post a notification per event |

### media-watch

Publishes playback changes from `dumpsys media_session`. **The record layout is
not a stable API**: the state field is parsed defensively (a missing state
produces no event), and the title/artist are best-effort — a ROM that phrases the
metadata differently yields an empty `TITLE` rather than a wrong one.

| Env | Default | Meaning |
| --- | --- | --- |
| `CHECK_INTERVAL` | `10` | seconds between polls |
| `PLAY_ACTION` / `PAUSE_ACTION` | — | commands run as root per event |
| `ACTION` | — | shared fallback |

### notification

Runs `ACTION` for each new notification, with `EVENT=posted` and the fields in
the table above. It polls as root — `cmd notification list` for the keys, and
`cmd notification get <key>` for a new one only — so no NotificationListener app
is needed and the full `dumpsys` never enters the loop.

```nix
aliyss.androidSettings.hookConfig."notification" = {
  WATCH_PACKAGES = "com.eveningoutpost.dexdrip,tk.glucodata";
  ACTION = "…";
};
```

| Env | Default | Meaning |
| --- | --- | --- |
| `CHECK_INTERVAL` | `15` | seconds between polls |
| `WATCH_PACKAGES` | empty | comma list to limit to (empty = every package) |
| `IGNORE_PACKAGES` | `com.android.shell` | comma list to skip |
| `ACTION` | — | command run as root per new notification |
| `NOTIFY` | `0` | also post a mirror notification |

"New" means a key that was not in the previous poll, so a notification updating
in place (same id+tag) does not fire twice. `IGNORE_PACKAGES` defaults to
`com.android.shell` — also what `android-settings notify` posts as, which keeps a
mirroring `NOTIFY=1` from looping; set it to `""` to watch everything.

Actions run as root through `su`, whose shell gets the Android PATH
(`/system/bin`, …) with no Termux entries — `$HOME` and `$PREFIX` are inherited,
but reference Termux tools by absolute path, or use the notify helper directly.

### brightness

The interesting event is the mode flip: ROMs (Nothing OS included) drop
auto-brightness to manual the moment you drag the slider, so turning it back on
is a one-liner. Level events cover things like warning at 100%.

```nix
aliyss.androidSettings.hookConfig."brightness" = {
  MODE_ACTION  = "settings put system screen_brightness_mode 1";
  STEP         = "15";     # 0-255 change that counts as a level event
  LEVEL_IN_AUTO = "0";     # auto ramps with ambient light: off by default
  MIN_INTERVAL = "60";     # rate limit for level events (slider drags)
};
```

Both settings are read in a single root shell per poll (spawning `su` is the
expensive part of a 30s loop), and the first run adopts the current state instead
of firing on boot.

### night-dnd

Enables DND during a daily window and disables it after. `NIGHT_START`,
`NIGHT_END` (may cross midnight), `DND_MODE` (`on`|`none`|`priority`|`alarms`,
default `alarms`), `CHECK_INTERVAL`.

### night-dark

The same window shape for the system dark theme, via `cmd uimode night yes|no`.
`NIGHT_START` (default `22:00`), `NIGHT_END`, `CHECK_INTERVAL`.

### schedule

A generic "run this at HH:MM" hook, for the time-based jobs that do not need a
hook of their own. Entries are separated by `;` and written `HH:MM|command`:

```nix
aliyss.androidSettings.hookConfig."schedule" = {
  SCHEDULES = "07:30|cmd uimode night no;22:00|cmd uimode night yes;23:30|settings put global low_power 1";
  GRACE = "2";   # minutes after HH:MM an entry may still fire
};
```

Firing is grace-based rather than exact-minute: a tick records what it ran (entry
index + date, in `state/schedule.fired`), so a missed minute (Doze, a restart, a
busy device) still fires while the clock is within `GRACE` minutes. Nothing is
replayed for an earlier day. A command containing `;` cannot be expressed — put
it in a small script and schedule that instead.

### key-remap

Replaces the Keymapper app: listens as root on the **one** input node that carries
the key (`getevent -t`, default `/dev/input/event0` = the gpio-keys node where the
Nothing Essential Key appears as scancode `00fa`) and detects short / double /
long presses, firing a root shell command per gesture.

```nix
aliyss.androidSettings.hookConfig."key-remap" = {
  SCANCODE = "00fa";
  KEY_DEVICE = "/dev/input/event0";            # gpio-keys; getevent -pl lists it
  SINGLE_ACTION = "am startservice ...";
  DOUBLE_ACTION = "monkey -p <pkg> -c android.intent.category.LAUNCHER 1";
  LONG_ACTION   = "monkey -p <pkg> -c android.intent.category.LAUNCHER 1";
};
```

Gesture semantics mirror Keymapper: short = released before `LONG_PRESS_MS`
(500), double = second press within `DOUBLE_PRESS_MS` (350) of the first release,
long = held ≥ `LONG_PRESS_MS` (fires while held). A double consumes both clicks;
a long press is never followed by a short.

Implementation (`hooks/key-remap/run`, the one bash hook): a single-threaded state
machine. Press durations and the double gap come from the kernel's monotonic
event timestamps (exact, immune to wall-clock jumps); a 50 ms `read -t` timeout
drives the two real-time decisions (fire long while held, resolve a pending
single after the double window). No shared state files and no timer subshells, so
there is nothing to race. Listening to a single device also avoids the
touchscreen event flood, which used to drop key-up events.

`DEVICE_CMD`/`NO_CLEANUP` replay a captured `getevent` log offline instead of
starting `getevent` — the test suite uses exactly that (see
[development.md](development.md)).

### boot-hook

Runs an action once per **device boot**. "Started by runit" is not the same as
"the device just booted": a service restarted by hand, or after a crash, must not
re-run boot work. The boot session is identified by
`/proc/sys/kernel/random/boot_id`, which changes on every boot and never within
one, so the action runs exactly once per boot however often the service restarts.
If that file is unreadable the hook falls back to its first start since the
marker was written and says so in the log.

| Env | Default | Meaning |
| --- | --- | --- |
| `BOOT_ACTION` | — | command run as root once per boot |
| `DELAY` | `20` | seconds to wait first, so the network and storage settle |
| `CHECK_INTERVAL` | `300` | how often to look for a new boot id |
| `NOTIFY` | `0` | notify when the action ran |

It does **not** re-apply props: that is `props-watch`'s job. One hook owns each
concern.

### props-watch

Keeps a manifest *applied*, not just applied once. Props are written during a
switch, but a reboot, a ROM reset or a manual trip through Settings can silently
change a key afterwards, and nothing notices until the next switch.

| Env | Default | Meaning |
| --- | --- | --- |
| `MANIFEST` | `default` | manifest name or path the engine resolves |
| `CHECK_INTERVAL` | `300` | seconds between checks |
| `REAPPLY` | `1` | apply the manifest when drift is found |
| `NOTIFY` | `1` | notify on a clean → drift transition |
| `ENGINE` | `~/.local/bin/android-settings`, then `PATH` | engine binary |
| `QUIET` | `0` | never notify |

It is a thin wrapper around the engine on purpose: `verify` decides what "drift"
means (including the QS tile merge), so there is no second implementation of the
manifest format. The repair runs `apply --only-changed`, so keys that still match
are left alone. Drift found on the first run after a boot is repaired silently
and logged — that is the expected case, not news.

### watchdog

run-it restarts a hook that exits, but its *supervision* can stop: runsvdir dies,
a `supervise/` directory is left behind without a runsv, a service is `sv down`-ed
by hand or by a half-finished removal. Those cases are silent — the hook simply
stops producing log lines.

This hook asks `sv status` for every android-settings service on an interval,
brings back anything that is not `run`, and reports the transitions. It is
deliberately quiet: healthy ticks produce no log line, so its own log stays a
short history of actual incidents.

| Env | Default | Meaning |
| --- | --- | --- |
| `CHECK_INTERVAL` | `60` | seconds between checks |
| `WATCH` | empty (all) | comma/space list; names may omit the `android-settings-` prefix |
| `RESTART` | `1` | `sv up` anything not running |
| `NOTIFY` | `0` | notify when a service goes down or comes back |

### chroot-dns

A guard, not a service. When the dotfiles run a nix-provided tool, `nix-chroot`
enters a kernel chroot and drops to the Termux user with `busybox setuidgid`,
which clears every supplementary group — including Android's `inet` (3003), the
group that owns the DNS proxy socket of netd (`/dev/socket/dnsproxyd`, mode 660
`root:inet`). Bionic resolves through that socket, so **every** lookup inside the
chroot failed with "No address associated with hostname" (EAI_NODATA) while
raw-IP connections kept working. That is what makes git/ssh/curl to any host —
not just GitHub — look broken.

The fix belongs to the chroot runner itself (it execs the command through
util-linux `setpriv --groups 3003` instead of `setuidgid`), but that runner is
generated by `aliyss-phone/nix-install.sh`, so this hook watches it: a runner
without the inet-group drop line is patched back (the `setuidgid` line stays as
fallback), the result is checked with `sh -n` before it replaces anything, and the
transition is reported instead of silently costing you DNS. It also catches the
other quiet way resolution dies — `setpriv` collected out of the store by
`nix-collect-garbage`.

| Env | Default | Meaning |
| --- | --- | --- |
| `CHECK_INTERVAL` | `300` | seconds between checks |
| `INET_GID` | `3003` | Android's inet group |
| `TERMUX_UID` / `TERMUX_GID` | `10393` | the user the chroot drops to |
| `LAUNCHER` | `~/.nix/bin/nix-chroot-run` | runner to guard |
| `NOTIFY` | `1` | notify when the state changes |
