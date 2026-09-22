#!/data/data/com.termux/files/usr/bin/sh
# notify.sh — post an Android notification from a root shell.
#
# Uses the platform's own notification service (`cmd notification post`), so it
# needs neither the Termux:API app nor `termux-notification`. The same helper
# works when the engine runs on the phone, during a home-manager activation, and
# from a hook under runit.
#
# Sourced, never executed:
#   . notify.sh
#   android_notify 'Battery low' 'Battery at 12% (alert at 15%)' [TAG]
#
# TAG defaults to android-settings. Posting again with the same tag replaces the
# previous notification instead of stacking.
#
# Why not just `su -c 'cmd notification post ...'`? As uid 0 the notification's
# package resolves to "root", which is not an installed package, so
# NotificationManagerService drops it:
#
#   E NotificationService: Cannot fix notification
#   E NotificationService: android.content.pm.PackageManager$NameNotFoundException: root
#
# It has to be posted as the ADB shell identity (uid 2000, com.android.shell).
# su here is KernelSU and cannot target a uid, so we drop to it with busybox's
# setuidgid — the same identity `adb shell cmd notification post` uses.
#
# Fallback order: shell uid -> root -> termux-notification -> caller's log line.
#
# Returns 0 when the notification was posted, non-zero otherwise:
#   android_notify 'Title' 'Body' battery-low || log "NOTIFICATION: Title"

# Single-quote escaping for the shell that `su -c` spawns.
_notify_esc() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }

_notify_su() {
  # The engine already resolved su (with retries) — reuse it when sourced there.
  if command -v resolve_su >/dev/null 2>&1; then
    resolve_su || return 1
    printf '%s' "$SU_BIN"
    return 0
  fi
  # Hooks resolve it themselves: KernelSU ships su in the Termux prefix here,
  # Magisk puts it on /system.
  for _n_c in su /system/bin/su /system/xbin/su /sbin/su; do
    if command -v "$_n_c" >/dev/null 2>&1; then
      command -v "$_n_c"
      return 0
    fi
  done
  return 1
}

# busybox with setuidgid, by absolute path (a root shell's PATH does not include
# the Termux prefix, so `command -v busybox` is useless inside su).
_notify_busybox() {
  for _n_bb in "${PREFIX:-/data/data/com.termux/files/usr}/bin/busybox" \
    /data/data/com.termux/files/usr/bin/busybox; do
    if [ -x "$_n_bb" ] && "$_n_bb" --list 2>/dev/null | grep -qx setuidgid; then
      printf '%s' "$_n_bb"
      return 0
    fi
  done
  return 1
}

android_notify() { # $1 = title, $2 = body, $3 = tag
  _n_title=${1:-android-settings}
  _n_body=${2:-}
  _n_tag=${3:-android-settings}

  _n_su=$(_notify_su) || return 1

  # bigtext keeps multi-line bodies readable.
  _n_post=$(printf "cmd notification post -S bigtext -t '%s' '%s' '%s'" \
    "$(_notify_esc "$_n_title")" "$(_notify_esc "$_n_tag")" "$(_notify_esc "$_n_body")")

  # The PATH pin matches as_root() and the hooks: the root shell's PATH is not
  # guaranteed to include /system/bin. It has to precede setuidgid, which takes
  # the command to run as its argument.
  _n_pin="PATH=/system/bin:/system/xbin:\$PATH; export PATH"

  _n_bb=$(_notify_busybox || true)
  if [ -n "$_n_bb" ]; then
    # The identity that actually works: uid 2000, like `adb shell`.
    "$_n_su" -c "$_n_pin; $_n_bb setuidgid 2000 $_n_post" >/dev/null 2>&1 && return 0
  fi

  # Some ROMs accept a root post; try it before giving up on `cmd notification`.
  "$_n_su" -c "$_n_pin; $_n_post" >/dev/null 2>&1 && return 0

  # Last resort: the Termux:API app, if it happens to be installed.
  if command -v termux-notification >/dev/null 2>&1; then
    termux-notification --title "$_n_title" --content "$_n_body" >/dev/null 2>&1 && return 0
  fi

  return 1
}
