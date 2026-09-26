# aliyss-android-settings

Declarative **Android settings** and **hook services** for the aliyss phone.
Sibling repo to [aliyss/aliyss-android-pkgs](https://github.com/aliyss/aliyss-android-pkgs):
the **engine lives here**, and home-manager (dotfiles flake, `aliyss-termux`)
consumes it — the phone applies everything on every `update-home`.

Two surfaces:

1. **Settings manifest** (`props/`) — applied with Android's `settings put`
   (namespace `global|system|secure`). `apply` writes every line (re-running is
   harmless); `verify` reads each key back and reports the ones that drifted;
   `lint` checks a manifest offline before it ever touches the phone. Raw root
   commands are allowed via `cmd:` lines, and other manifests can be spliced in
   with `include`. `props/default.props` is the enforced set; the other files are
   a commented cookbook of the Quick Settings surface — see
   [docs/props.md](docs/props.md).
2. **Hooks** (`hooks/`) — long-running loops supervised by termux-services
   (runit), one service per hook: `android-settings-<hook>`. Autostart at Termux
   boot; env-tunable via the dotfiles' `hookConfig`. Seventeen of them, from
   battery and thermal alerts to network/screen/lock events, key remapping, a
   boot action, a props drift guard and a service watchdog — see
   [docs/hooks.md](docs/hooks.md).

Nothing in this repo starts a hook: each one ships as *available* and only
becomes a service once the dotfiles declare it (home-manager calls
`install-hook`), so the flake can carry hooks the phone does not use without them
running.

## Usage (on the phone)

```fish
android-settings apply                 # apply props/default.props
android-settings verify                # diff current vs wanted (read-only, exit 1 on drift)
android-settings verify --json         # the same, for scripts
android-settings lint all              # offline: namespaces, keys, includes, QS tiles
android-settings list-props            # list the props/ library
android-settings get secure sysui_qs_tiles     # one-off settings read/write
android-settings set global window_animation_scale 1.0
android-settings notify "Build done" "update-home finished"   # root, no Termux:API

android-settings qs-list               # current Quick Settings tiles
android-settings qs-add flashlight     # merge a tile into the QS panel
android-settings qs-remove cast        # drop a tile from the QS panel

android-settings apply display         # apply props/display.props
android-settings verify connectivity   # dry-check props/connectivity.props
android-settings apply all             # every props/ manifest, sorted
android-settings apply --dry-run       # show what default.props would write
android-settings apply --only-changed  # skip keys that already match

android-settings disable-app com.nothing.ntessentialspace   # pm disable-user --user 0
android-settings enable-app com.nothing.ntessentialspace    # undo
android-settings list-disabled         # all disabled packages on the device

android-settings list-hooks            # available + installed hooks
android-settings install-hook battery-low
android-settings test-hook battery-low 10   # run it in the foreground, once
android-settings status                # services, runit state, last log line
android-settings log battery-low -f    # follow one hook's log
android-settings remove-hook battery-low
```

Manifest arguments are resolved as a path (anything with a slash or a `.props`
suffix), a bare name against `props/` (`display` → `props/display.props`), or
`all`. With no argument, `default.props` is applied. Every command and every
manifest line form is documented in [docs/engine.md](docs/engine.md).

## Wiring (dotfiles side)

The flake ships **two outputs**, like mako does upstream: the **package**
(`packages.<system>.android-settings` — engine + `hooks/` + `props/` + `lib/`)
and the **home-manager module** (`homeModules.default`). The module is only
glue: on every switch it renders your options into a manifest, runs the engine,
and diff-installs the declared hooks. It pulls no package of its own — `package`
defaults to this flake's build, so pointing it elsewhere is optional.

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
  hooks = [ "battery-low" "net-watch" "night-dnd" "night-dark" "props-watch" ];
  hookConfig = {
    "battery-low" = { THRESHOLD = "15"; };
    "night-dnd" = { NIGHT_START = "23:00"; NIGHT_END = "07:00"; DND_MODE = "alarms"; };
    "schedule" = { SCHEDULES = "07:30|cmd uimode night no;22:00|cmd uimode night yes"; };
  };
};
```

On every `home-manager switch`:

- `props` is rendered to a manifest and applied with root — every line is written,
  so a re-run is harmless; `verify` is what reads the keys back;
- hooks are diff-installed: new ones become runit services, removed ones are
  uninstalled (previous declaration tracked in
  `~/.local/state/aliyss-android-settings/hooks`);
- `hookConfig` becomes each hook's env file; changing it restarts the service on
  the next switch.

A failing engine call is a **warning, not a switch failure** — no root grant or a
typo'd hook name should cost you a generation — so re-run it by hand
(`android-settings verify`, `android-settings lint`, `android-settings status`) to
see the detail.

The module declares `enable`, `package`, `props`, `hooks` and `hookConfig`. Any
other `aliyss.androidSettings.*` option the dotfiles declare (e.g.
`disabledApps`) keeps living there — separate modules under the same option
namespace merge, so importing this one does not disturb them.

`props-watch` closes the loop the module opens: with it declared, a key that a
reboot or a stray Settings tap changes afterwards is re-applied without waiting
for the next switch.

## Root, trust and the chroot

Manifests and hooks run **as root** where needed, so never apply a manifest you
have not read. The engine probes `su` before trusting it and falls back to
KernelSU's ksud CLI when the real `su` is hidden inside the nix chroot;
notifications have to be posted as uid 2000 or NotificationManager drops them.
All of that — plus the state layout — is in [docs/root.md](docs/root.md).

## Testing

The suite is offline: it fakes `su`, `settings` and `dumpsys`, sandboxes `HOME`
and `PREFIX`, and asserts the notification path instead of posting, so it can run
on the phone, in CI, or in a nix build without touching a device.

```sh
sh tests/run.sh          # 86 assertions
nix flake check          # shellcheck + the suite + module golden files
```

Authoring a hook, the shared `lib/` helpers and what CI runs:
[docs/development.md](docs/development.md).

## Repo layout

```
bin/android-settings     engine CLI
hooks/<name>/{run,defaults}  hook loops (runit-managed)
lib/{su,hook,poll,notify}.sh shared helpers for the engine and the hooks
modules/home-manager.nix     the flake's home-manager module
modules/render.nix           its pure text rendering (golden-tested)
props/default.props          the manifest enforced on every switch
props/<area>.props           commented reference library, one file per area
tests/                       offline suite (fake su/settings/dumpsys + fixtures)
docs/                        engine, hooks, props, root and development docs
```

## License

MIT — see [LICENSE](LICENSE).
