# aliyss-android-settings

Declarative **Android settings** and **hook services** for the aliyss phone.
Sibling repo to [aliyss/aliyss-android-pkgs](https://github.com/aliyss/aliyss-android-pkgs):
the **engine lives here**, and home-manager (dotfiles flake,
`aliyss-termux`) consumes it — the phone applies everything on every
`update-home`.

Two surfaces:

1. **Settings manifest** (`props/`) — applied with Android's `settings put`
   (namespace `global|system|secure`). `apply` writes every line (re-running is
   harmless: the same value is written again) and `verify` reads each key back
   and reports the ones that drifted. Raw root commands are also allowed via
   `cmd:` lines. `props/` is a
   **library**: `default.props` is the enforced set, the other files are
   commented cookbooks covering the Quick Settings surface (display,
   connectivity, sound, battery, rotation, privacy, the QS tile layout itself,
   status bar, developer options).
2. **Hooks** (`hooks/`) — long-running loops supervised by termux-services
   (runit), one service per hook: `android-settings-<hook>`. Autostart at
   Termux boot; env-tunable via the dotfiles' `hookConfig`.

Nothing in this repo starts a hook: each one ships as *available* and only
becomes a service once the dotfiles declare it (home-manager calls
`install-hook`), so the flake can carry hooks the phone does not use without
them running.

## Usage (on the phone)

```fish
android-settings apply                 # apply props/default.props
android-settings verify                # diff current vs wanted (read-only)
android-settings list-props            # list the props/ library
android-settings notify "Build done" "update-home finished"   # root, no Termux:API
android-settings qs-list               # current Quick Settings tiles
android-settings qs-add flashlight     # merge a tile into the QS panel
android-settings qs-remove cast        # drop a tile from the QS panel
android-settings apply display         # apply props/display.props
android-settings verify connectivity   # dry-check props/connectivity.props
android-settings apply all             # every props/ manifest, sorted
android-settings apply --dry-run       # show what default.props would write
android-settings disable-app com.nothing.ntessentialspace   # pm disable-user --user 0
android-settings enable-app com.nothing.ntessentialspace    # undo
android-settings list-disabled         # all disabled packages on the device
android-settings list-hooks            # available + installed hooks
android-settings install-hook battery-low
android-settings remove-hook battery-low
```

Manifest arguments are resolved as a path (anything with a slash or a `.props`
suffix), a bare name against `props/` (`display` → `props/display.props`), or
`all`. With no argument, `default.props` is applied.

App disabling is the generic, reversible mechanism (`pm disable-user
--user 0`) — it works for any user app and most system apps on any Android
version; `pm hide` needs system perms and `pm suspend` is device-policy
territory. Declaratively: `aliyss.androidSettings.disabledApps` in the
dotfiles (ids removed from the list are re-enabled on the next switch).

`android-settings` is wrapped into `~/.local/bin` by the dotfiles
(`ensure-nix-wrappers.sh`), like every other nix-provided tool.

## Wiring (dotfiles side)

The flake ships **two outputs**, like mako does upstream: the **package**
(`packages.<system>.android-settings` — engine + `hooks/` + `props/` + `lib/`)
and the **home-manager module** (`homeModules.default`). The module is only
glue: on every switch it
renders your options into a manifest, runs the engine, and diff-installs the
declared hooks. It pulls no package of its own — `package` defaults to this
flake's build, so pointing it elsewhere is optional.

```nix
# flake/hosts/termux/home.nix
imports = [ inputs.aliyss-android-settings.homeModules.default ];

aliyss.androidSettings = {
  enable = true;
  props = {
    "global.window_animation_scale" = 0.75;        # float → written as 0.75
    "secure.night_display_enabled" = true;         # bool  → written as 1
    "system.screen_brightness" = 128;
    "qs.add" = [ "flashlight" "screenrecord" ];     # list  → comma-joined
    "cmd:" = [ "svc wifi enable" ];                 # root commands, one line each
  };
  hooks = [ "battery-low" "net-watch" "night-dnd" "night-dark" ];
  hookConfig = {
    "battery-low" = { THRESHOLD = "15"; };
    "night-dnd" = { NIGHT_START = "23:00"; NIGHT_END = "07:00"; DND_MODE = "alarms"; };
  };
};
```

On every `home-manager switch`:

- `props` is rendered to a manifest and applied with root — **every line is
  written**, so a re-run is harmless; `android-settings verify` is what reads
  the keys back and reports the ones that drifted;
- hooks are diff-installed: new ones become runit services, removed ones are
  uninstalled (previous declaration tracked in
  `~/.local/state/aliyss-android-settings/hooks`);
- `hookConfig` becomes each hook's env file; changing it restarts the service
  on the next switch.

A failing engine call is a **warning, not a switch failure** — no root grant or
a typo'd hook name should cost you a generation — so re-run it by hand
(`android-settings verify`, `android-settings list-hooks`) to see the detail.

This module declares `enable`, `package`, `props`, `hooks` and `hookConfig`. Any
other `aliyss.androidSettings.*` option the dotfiles declare (e.g.
`disabledApps`) keeps living there — separate modules under the same option
namespace merge, so importing this one does not disturb them.

Logs: `~/.local/state/aliyss-android-settings/logs/<hook>.log`
(hook stdout/stderr, with a marker line per runit spawn).

## Authoring a hook

A hook is a directory under `hooks/<name>/`:

- `run` (executable) — the loop. Contract: it is sourced with env, then
  executed under `#!/data/data/com.termux/files/usr/bin/sh`; it must loop
  forever and sleep between checks. Keep it **native Termux only** (sh, sed,
  sleep, `su -c` for privileged bits) — no nix store paths (invisible to native
  Termux). Prefer the platform over Termux:API: `dumpsys`/`cmd` as root instead
  of `termux-battery-status`, `lib/notify.sh` instead of `termux-notification`.
  A per-hook state file can live under
  `~/.local/state/aliyss-android-settings/state/<name>`.
- `defaults` — `KEY=value` lines, sourced before the home-manager env file
  (so `hookConfig` overrides).

Need to notify the user? Source the shared helper and call it — it goes through
`cmd notification post`, so it needs **no Termux:API app**:

```sh
NOTIFY_LIB="$HOME/.local/libexec/android-settings/lib/notify.sh"
[ -f "$NOTIFY_LIB" ] && . "$NOTIFY_LIB"

android_notify 'Battery low' 'Battery at 12% (alert at 15%)' battery-low ||
  log "NOTIFICATION: ..."        # returns non-zero when it could not post
```

The tag keeps re-posts of the same alert from stacking. `install-hook` copies
`lib/notify.sh` next to the hooks (`~/.local/libexec/android-settings/lib/`)
because a runit-spawned hook runs natively in Termux, where the nix store is
invisible. The same helper backs `android-settings notify TITLE [BODY] [TAG]`.

#### Why the helper runs `setuidgid 2000`

`cmd notification post` **is dropped when run as root**: NotificationManager
resolves uid 0 to the package `root`, which is not installed, so it logs
`Cannot fix notification / NameNotFoundException: root` and enqueues nothing.
The notification has to be posted as the ADB shell identity — uid 2000,
`com.android.shell` — which is exactly what `adb shell cmd notification post`
does. KernelSU's `su` cannot target a uid, so `android_notify` drops to it with
busybox's `setuidgid` (Termux package `busybox`).

Fallback order if that is unavailable: root `cmd notification post` (a few ROMs
accept it) → `termux-notification` if the Termux:API app happens to be installed
→ return non-zero so the caller logs the alert instead. So a missing busybox
degrades to the Termux:API path rather than dropping notifications silently.

See `hooks/battery-low` (native root: `dumpsys battery` plus `cmd notification
post`), `hooks/net-watch` (state change + notification, with a debounce),
`hooks/brightness` and `hooks/notification` (event sources that run a
configured action), `hooks/night-dnd` and `hooks/night-dark` (`su -c cmd ...`)
as templates.

### net-watch

Notifies when the active network changes — Wi-Fi → mobile → offline → VPN —
once the new state has held for `MIN_STABLE` seconds, so a quick Wi-Fi/mobile
flip never reaches you. It asks the kernel which interface a packet to
`PROBE_TARGET` would actually leave through (`ip route get`), which respects
Android's per-network routing and VPNs; note `/proc/net/route` is useless here,
since the main table holds only the on-link peer routes and no default entry.
The interface is labelled (`wlan0` → Wi-Fi, `rmnet*`/`ccmni*`/`pdp*` → mobile,
`tun*`/`ppp*` → VPN) and, on Wi-Fi, the SSID is read from the `mWifiInfo` dump.

```nix
aliyss.androidSettings.hookConfig."net-watch" = {
  CHECK_INTERVAL = "60";     # seconds between checks
  MIN_STABLE = "30";         # seconds a state must hold before notifying
  PROBE_TARGET = "1.1.1.1";  # address used for the route lookup
};
```

The first run adopts whatever is current instead of alerting on boot; the last
notified state lives in `~/.local/state/aliyss-android-settings/state/net-watch`,
so restarts stay quiet. Needs root (`ip`, `dumpsys wifi`) and the notify helper
— without it the alert degrades to a log line.

### brightness (event source)

Polls the screen brightness and runs `MODE_ACTION` / `LEVEL_ACTION` as root; it
publishes events rather than notifying, so the dotfiles decide what happens. The
interesting event is the mode flip — ROMs (Nothing OS included) drop
auto-brightness to manual the moment you drag the slider, so turning it back on
is a one-liner:

```nix
aliyss.androidSettings.hookConfig."brightness" = {
  MODE_ACTION  = "settings put system screen_brightness_mode 1";
  STEP         = "15";     # 0-255 change that counts as a level event
  LEVEL_IN_AUTO = "0";     # auto ramps with ambient light: off by default
  MIN_INTERVAL = "60";     # rate limit for level events (slider drags)
};
```

The action environment carries `EVENT` (`mode`|`level`), `MODE`/`PREV_MODE`
(`auto`|`manual`), `BRIGHTNESS`/`PREV_BRIGHTNESS` (0-255) and
`PERCENT`/`PREV_PERCENT` (0-100). Both settings are read in a single root shell
per poll, and the first run adopts the current state instead of firing on boot.

### notification (event source)

Runs `ACTION` for each new notification, with `EVENT=posted`, `PACKAGE`, `UID`,
`USER`, `ID`, `TAG`, `KEY`, `TITLE`, `TEXT`, `CHANNEL` and `IMPORTANCE` in its
environment. It polls as root — `cmd notification list` for the keys, and
`cmd notification get <key>` for a new one only — so no NotificationListener app
is needed:

```nix
aliyss.androidSettings.hookConfig."notification" = {
  WATCH_PACKAGES = "com.eveningoutpost.dexdrip,tk.glucodata";
  ACTION = "…";
};
```

"New" means a key that was not in the previous poll, so a notification updating
in place (same id+tag) does not fire twice. `IGNORE_PACKAGES` defaults to
`com.android.shell` (also what `android-settings notify` posts as, which keeps a
mirroring `NOTIFY=1` from looping); set it to `""` to watch everything.

Both actions run as root through `su`, whose shell gets the Android PATH
(`/system/bin`, …) with no Termux entries — `$HOME` and `$PREFIX` are inherited,
but reference Termux tools by absolute path, or use the notify helper directly:

```sh
. "$HOME/.local/libexec/android-settings/lib/notify.sh"
android_notify "$TITLE" "$TEXT"
```

### key-remap (replaces the Keymapper app)

Listens as root on the **one** input node that carries the key
(`getevent -t`, default `/dev/input/event0` = the gpio-keys node where the
Nothing Essential Key appears as scancode `00fa`) and detects short / double /
long presses, firing a root shell command per gesture:

```nix
aliyss.androidSettings.hookConfig."key-remap" = {
  SCANCODE = "00fa";
  KEY_DEVICE = "/dev/input/event0";            # gpio-keys; getevent -pl lists it
  SINGLE_ACTION = "am startservice ...";   # interactive actions via RUN_COMMAND
  DOUBLE_ACTION = "monkey -p <pkg> -c android.intent.category.LAUNCHER 1";
  LONG_ACTION   = "monkey -p <pkg> -c android.intent.category.LAUNCHER 1";
};
```

Gesture semantics mirror Keymapper: short = released < `LONG_PRESS_MS` (500),
double = second press within `DOUBLE_PRESS_MS` (350) of the first release,
long = held ≥ `LONG_PRESS_MS` (fires while held).

Implementation (`hooks/key-remap/run`, bash): a single-threaded state machine.
Press durations and the double gap come from the kernel's monotonic event
timestamps (exact, immune to wall-clock jumps); a 50 ms `read -t` timeout
drives the two real-time decisions (fire long while held, resolve a pending
single after the double window). No shared state files and no timer subshells,
so there is nothing to race. Listening to a single device also avoids the
touchscreen event flood, which previously caused dropped key-up events.

`DEVICE_CMD`/`NO_CLEANUP` can replay a captured `getevent` log offline for
testing (see the header of `run`).

### chroot-dns (keeps the Nix chroot resolving)

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
fallback), the result is checked with `sh -n` before it replaces anything, and
the transition is reported instead of silently costing you DNS. It also catches
the other quiet way resolution dies — `setpriv` collected out of the store by
`nix-collect-garbage`.

```nix
aliyss.androidSettings.hookConfig."chroot-dns" = {
  CHECK_INTERVAL = "300";
  INET_GID = "3003";      # Android's inet group
  TERMUX_UID = "10393";   # the user the chroot drops to
};
```

## Trust model

Manifests and hooks run **as root** (`su`) where needed — this repo is part
of the trusted flake, same as the android-pkgs installer. Never apply a
manifest you did not read (`cmd:` lines are arbitrary root commands).

### Root when `su` is not reachable

The engine resolves `su` from `PATH` and the usual locations, but it **probes**
each candidate (`su -c 'id -u'`) rather than trusting the name: inside the Nix
chroot the Termux `su` stub sits on `PATH` and always fails, while the real
`/system/bin/su` and `/data/adb` are not mounted. When no candidate elevates, it
falls back to KernelSU's ksud CLI through a generated `su -c` shim
(`~/.local/state/aliyss-android-settings/su-ksud`) — the same route the
interactive fish `su`/`sudo` functions take. That is what lets a home-manager
activation get root inside the chroot; `$SU_BIN` keeps its `su -c` contract
either way, so `lib/notify.sh` and friends need no special case.

## Repo layout

```
bin/android-settings   engine CLI (apply / verify / list-props / notify / install-hook / remove-hook / list-hooks)
hooks/<name>/run       hook loops (runit-managed)
hooks/<name>/defaults  default env
lib/notify.sh          shared helper: android_notify via `cmd notification post`
modules/home-manager.nix  the flake's home-manager module (exports `homeModules.default`);
                       the package output is the engine + hooks/ + props/ + lib/
props/default.props    the manifest enforced on every switch
props/<area>.props     commented reference library, one file per Quick Settings area
                       (display, connectivity, sound, battery, rotation, privacy,
                        quicksettings, system-ui, developer, animation)
```

### props/ library

Every file's first line is its one-line summary (that is what `list-props`
prints). Library files are fully commented out — uncomment a line, then
`android-settings apply <name>`, or copy it into `default.props`. Toggles that a
plain `settings put` cannot flip cleanly (Wi-Fi, Bluetooth, airplane mode, data
saver, hotspot, location, dark theme, DND) are given as `cmd:` lines, which the
engine runs as root; `global.*_on` mirrors are documented as read-only.
However `default.props` itself stays the enforced set, so activating a library
toggle is a deliberate edit rather than a side effect of `update-home`.

Quick Settings tiles are a single comma-separated list
(`secure.sysui_qs_tiles`), so plain settings lines can only replace the whole
panel. `qs.add = flashlight` / `qs.remove = cast` in a manifest — or the
`qs-add` / `qs-remove` commands — merge instead: they read the live list, patch
only the named tiles, write it back and restart SystemUI, which makes them
idempotent and verifiable (`android-settings verify quicksettings`). Set
`NO_QS_RELOAD=1` to skip the SystemUI restart.
