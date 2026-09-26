# Root and trust

## Trust model

Manifests and hooks run **as root** (`su`) where needed — this repo is part of
the trusted flake, same as the android-pkgs installer.

**Never apply a manifest you did not read.** `cmd:` lines are arbitrary root
commands, and `lint` deliberately names every one of them. A hook's `*_ACTION` is
the same thing in env-var form.

The engine, the hooks and `install-hook` all run as the Termux user; only the
individual privileged commands go through `su`. That keeps the process in the
app's SELinux domain, which is what lets runit keep supervising it.

## Root when `su` is not reachable

`lib/su.sh` resolves `su` from `PATH` and the usual locations, but it **probes**
each candidate (`su -c 'id -u'`) rather than trusting the name: inside the Nix
chroot the Termux `su` stub sits on `PATH` and always fails, while the real
`/system/bin/su` and `/data/adb` are not mounted. A candidate is accepted only
when the probe comes back `0`.

When no candidate elevates, it falls back to KernelSU's ksud CLI through a
generated `su -c` shim (`~/.local/state/aliyss-android-settings/su-ksud`): that
is the same route the interactive fish `su`/`sudo` functions take, and it is what
lets a home-manager activation get root inside the chroot. The shim keeps the
`su -c` contract, so `$SU_BIN` means the same thing everywhere — including
`lib/notify.sh`, which calls it directly.

The shim is regenerated when it is missing, when the shim body changes
(`SHIM_REV`), or when it points at a different `libksud.so` (that path can move
with a SukiSU update).

Three ready-made call shapes:

| Function | Use |
| --- | --- |
| `as_root CMD` | retries up to three times, warns on failure — the default |
| `as_root_out CMD` | one call, stdout only, failure is the caller's business — poll loops |
| `as_root_detached CMD` | background — actions, so a slow command cannot stall a loop |

All three prepend `$ANDROID_PATH` (`/system/bin:/system/xbin:/vendor/bin`) inside
the root shell. The root shell's `PATH` is not guaranteed to include them — the
engine has been seen failing with `settings: inaccessible or not found` during a
home-manager switch — and the variable is overridable mainly so the test suite
can point it at its fakes and never reach the real `/system/bin`.

## Why notifications drop as root

`cmd notification post` **is dropped when run as root**: NotificationManager
resolves uid 0 to the package `root`, which is not installed, so it logs

```
E NotificationService: Cannot fix notification
E NotificationService: NameNotFoundException: root
```

and enqueues nothing.

The notification has to be posted as the ADB shell identity — uid 2000,
`com.android.shell` — which is exactly what `adb shell cmd notification post`
does. KernelSU's `su` cannot target a uid, so `android_notify` drops to it with
busybox's `setuidgid` (the Termux `busybox` package).

Fallback order if that is unavailable: root `cmd notification post` (a few ROMs
accept it) → `termux-notification` if the Termux:API app happens to be installed
→ return non-zero so the caller logs the alert instead. A missing busybox
therefore degrades to the Termux:API path rather than dropping notifications
silently.

`android-settings notify TITLE [BODY] [TAG]` uses the same helper, as does every
hook through `hook_notify`.

## The Nix chroot

Two things inside the chroot repeatedly bite, and both have a hook guarding them:

- **DNS**: `busybox setuidgid` clears the supplementary group `inet` (3003), which
  owns netd's DNS proxy socket, so every lookup fails with EAI_NODATA while raw
  IPs keep working — see [chroot-dns](hooks.md#chroot-dns).
- **Root**: the real `su` is not mounted, hence the ksud shim above.

## State layout

```
~/.local/state/aliyss-android-settings/
  hooks/                 the declared hook ledger (written by sync-hooks)
  logs/<hook>.log        hook stdout/stderr, one marker line per runit spawn
  state/<name>           per-hook state (last seen value, re-arm flags, ...)
  state/<name>.pending   poll_confirm's candidate state
  su.err                 stderr of the last failed root call
  su-ksud                the generated ksud shim

~/.local/libexec/android-settings/
  hooks/<hook>/{run,defaults,env}   installed copies (real files, not store paths)
  lib/{su,hook,poll,notify}.sh      shared helpers, copied next to the hooks

$PREFIX/var/service/android-settings-<hook>/run
```

The `hooks/` ledger is what lets `sync-hooks` remove what the previous
declaration had and this one does not — it is the only piece of history the
engine keeps.
