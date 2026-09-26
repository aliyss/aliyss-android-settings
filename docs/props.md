# The settings library (`props/`)

Two kinds of file live here:

- **`props/default.props`** — the set that is *enforced*: `apply` runs it on
  every `home-manager switch`, and a `props-watch` hook can re-run it whenever
  `verify` reports drift.
- **every other `props/*.props`** — the *library*: a fully commented cookbook.
  Uncomment a line, then `android-settings apply <name>`; or copy it into
  `default.props`; or splice it with `include`.

Activating a library toggle is therefore a deliberate edit, never a side effect
of `update-home`. The first line of each file is its summary (that is what
`list-props` prints).

```
android-settings list-props
android-settings lint all
android-settings apply display
android-settings verify connectivity
```

Run `lint` after editing: it catches a bad namespace, a typo'd key, a missing
include and an unknown QS tile before anything is written.

## Values

Values are the ones the Settings UI writes, so they round-trip with
`settings get` — that is what makes `verify` meaningful. `verify` compares the
stored string **literally**, so what you write is what must come back:

| In the manifest | Written to Android | Notes |
| --- | --- | --- |
| `0.75` | `0.75` | floats are written as spelled (home-manager renders them via JSON, so `1.0` stays `1.0`) |
| `1` / `true` (Nix bool) | `1` | a Nix `false` becomes `0`, not an empty value |
| `com.a,com.b` | `com.a,com.b` | a Nix list is comma-joined, for `qs.add`/`qs.remove` |

## Toggles that are not settings

`settings put` cannot cleanly flip Wi-Fi, Bluetooth, airplane mode, data saver,
hotspot, location, dark theme or DND — the ROM's service owns the transition and
only the service can do it properly. Those are written as `cmd:` lines, which the
engine runs as root:

```
cmd:svc wifi enable
cmd:cmd notification set_dnd off
cmd:cmd uimode night yes
```

The plain `global.*_on` keys are mirrors the framework maintains: useful to read,
risky to write (they look like they worked while the service state does not
follow). `lint` warns about the known ones.

## Files

| File | Covers |
| --- | --- |
| `default.props` | the enforced set (currently the three animation scales) |
| `display.props` | brightness, timeout, dark theme, night light, extra dim, colour correction, screensaver |
| `connectivity.props` | Wi-Fi, mobile data, airplane mode, Bluetooth, NFC, data saver, hotspot, private DNS |
| `sound.props` | DND, vibrate/haptics, touch and charging sounds, adaptive sound, Live Caption |
| `battery.props` | battery saver, adaptive battery, percentage, stay-awake |
| `rotation.props` | auto-rotate, locked orientation, rotate suggestions |
| `privacy.props` | location, scanning, lock-screen privacy |
| `quicksettings.props` | the QS panel itself: `qs.add`/`qs.remove`, tile order, collapsed count |
| `system-ui.props` | status-bar icons, navigation mode, notification LED, immersive policy |
| `developer.props` | developer-options toggles |
| `animation.props` | the three animation scales (same values `default.props` enforces) |
| `notifications.props` | heads-up banners, badge dots, bubbles, notification history, lock-screen content, listeners |
| `apps.props` | per-app appops (background, notifications, wakelocks, location/camera/mic), standby buckets, default-app roles, force-stop |
| `accessibility.props` | font scale, accessibility services, inversion, pointer size, mono audio, autofill, display size |
| `time.props` | 12/24-hour clock, date format, automatic time and time zone, NTP server |
| `input.props` | default/enabled keyboards, autofill, pointer speed, live `ime` control |

### `apps.props`

This one is entirely `cmd:` lines — per-app state lives in appops, the activity
manager and the role manager, not in settings rows:

```
cmd:cmd appops set com.example.app RUN_IN_BACKGROUND ignore
cmd:am set-standby-bucket com.example.app restricted
cmd:cmd role add-role-holder android.app.role.BROWSER com.example.browser
cmd:am force-stop com.example.app
```

`verify` reports them as unverifiable (there is no readable state to compare),
so each section lists the matching read-back command:
`cmd appops get`, `am get-standby-bucket`, `cmd role get-role-holders`.

App *disabling* mostly does not belong here: it has a first-class reversible path
(`android-settings disable-app`, or `aliyss.androidSettings.disabledApps`), and
the raw `pm disable-user` line is only the form underneath it.

## Quick Settings tiles

`secure.sysui_qs_tiles` is one comma-separated list, so a plain settings line
replaces the whole panel and clobbers whatever the phone added since. Prefer the
merge:

```
qs.add = flashlight,screenrecord
qs.remove = cast,nfc
```

Specs are AOSP names (`internet`, `cell`, `wifi`, `bt`, `flashlight`, `dnd`,
`alarm`, `airplane`, `rotation`, `battery`, `cast`, `screenrecord`, `hotspot`,
`nfc`, `night`, `dark`, `saver`, `location`, `datasaver`); Nothing OS uses the
same ones. On Android 12+ the `internet` tile replaces the separate `wifi`/`cell`
tiles. `android-settings qs-list` prints the live list — that is the source of
truth.

```nix
aliyss.androidSettings.props = {
  "qs.add" = [ "flashlight" "screenrecord" ];
  "qs.remove" = [ "cast" ];
};
```
