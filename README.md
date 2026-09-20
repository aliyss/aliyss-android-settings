# aliyss-android-settings

Declarative **Android settings** and **hook services** for the aliyss phone.
Sibling repo to [aliyss/aliyss-android-pkgs](https://github.com/aliyss/aliyss-android-pkgs):
the **engine lives here**, and home-manager (dotfiles flake,
`aliyss-termux`) consumes it — the phone applies everything on every
`update-home`.

Two surfaces:

1. **Settings manifest** (`props/`) — applied with Android's `settings put`
   (namespace `global|system|secure`), idempotent: only differing values are
   written. Raw root commands are also allowed via `cmd:` lines.
2. **Hooks** (`hooks/`) — long-running loops supervised by termux-services
   (runit), one service per hook: `android-settings-<hook>`. Autostart at
   Termux boot; env-tunable via the dotfiles' `hookConfig`.

## Usage (on the phone)

```fish
android-settings apply                 # apply the reference manifest
android-settings verify                # diff current vs wanted (read-only)
android-settings disable-app com.nothing.ntessentialspace   # pm disable-user --user 0
android-settings enable-app com.nothing.ntessentialspace    # undo
android-settings list-disabled         # all disabled packages on the device
android-settings list-hooks            # available + installed hooks
android-settings install-hook battery-low
android-settings remove-hook battery-low
```

App disabling is the generic, reversible mechanism (`pm disable-user
--user 0`) — it works for any user app and most system apps on any Android
version; `pm hide` needs system perms and `pm suspend` is device-policy
territory. Declaratively: `aliyss.androidSettings.disabledApps` in the
dotfiles (ids removed from the list are re-enabled on the next switch).

`android-settings` is wrapped into `~/.local/bin` by the dotfiles
(`ensure-nix-wrappers.sh`), like every other nix-provided tool.

## Wiring (dotfiles side)

```nix
# flake/hosts/termux/home.nix
aliyss.androidSettings = {
  enable = true;
  props = {
    "global.window_animation_scale" = "0.75";
  };
  hooks = [ "battery-low" "night-dnd" "night-dark" ];
  hookConfig = {
    "battery-low" = { THRESHOLD = "15"; };
    "night-dnd" = { NIGHT_START = "23:00"; NIGHT_END = "07:00"; DND_MODE = "alarms"; };
  };
};
```

On every `home-manager switch`:

- `props` is rendered to a manifest and `android-settings apply`d (root);
- hooks are diff-installed: new ones become runit services, removed ones are
  uninstalled (previous declaration tracked in
  `~/.local/state/aliyss-android-settings/hooks`);
- `hookConfig` becomes each hook's env file; changing it restarts the service
  on the next switch.

Logs: `~/.local/state/aliyss-android-settings/logs/<hook>.log`
(hook stdout/stderr, with a marker line per runit spawn).

## Authoring a hook

A hook is a directory under `hooks/<name>/`:

- `run` (executable) — the loop. Contract: it is sourced with env, then
  executed under `#!/data/data/com.termux/files/usr/bin/sh`; it must loop
  forever and sleep between checks. Keep it **native Termux only** (sh, sed,
  sleep, termux-api, `su -c` for privileged bits) — no nix store paths
  (invisible to native Termux). A per-hook state file can live under
  `~/.local/state/aliyss-android-settings/state/<name>`.
- `defaults` — `KEY=value` lines, sourced before the home-manager env file
  (so `hookConfig` overrides).

See `hooks/battery-low` (termux-api, no root), `hooks/night-dnd` and
`hooks/night-dark` (`su -c cmd ...`, root) as templates.

### key-remap (replaces the Keymapper app)

Listens on all input devices as root (`getevent -t`) and detects short /
double / long presses of one scancode (default `00fa` = the Nothing Essential
Key), firing a root shell command per gesture:

```nix
aliyss.androidSettings.hookConfig."key-remap" = {
  SCANCODE = "00fa";
  SINGLE_ACTION = "am startservice ...";   # interactive actions via RUN_COMMAND
  DOUBLE_ACTION = "monkey -p <pkg> -c android.intent.category.LAUNCHER 1";
  LONG_ACTION   = "monkey -p <pkg> -c android.intent.category.LAUNCHER 1";
};
```

Gesture semantics mirror Keymapper: short = released < `LONG_PRESS_MS` (500),
double = second press within `DOUBLE_PRESS_MS` (350) of the first release,
long = held ≥ `LONG_PRESS_MS` (fires while held). Event timing uses the
kernel's monotonic timestamps, so it is immune to wall-clock jumps.

## Trust model

Manifests and hooks run **as root** (`su`) where needed — this repo is part
of the trusted flake, same as the android-pkgs installer. Never apply a
manifest you did not read (`cmd:` lines are arbitrary root commands).

## Repo layout

```
bin/android-settings   engine CLI (apply / verify / install-hook / remove-hook / list-hooks)
hooks/<name>/run       hook loops (runit-managed)
hooks/<name>/defaults  default env
props/default.props    reference settings manifest
```
