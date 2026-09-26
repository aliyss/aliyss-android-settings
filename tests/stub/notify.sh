#!/data/data/com.termux/files/usr/bin/sh
# notify.sh — stub used by the test suite in place of lib/notify.sh.
#
# The real helper posts through `cmd notification post` as uid 2000, which on a
# rooted phone means the suite would fire REAL notifications (and on CI would
# need busybox). This stub records the call and returns non-zero, so the hook
# takes its documented fallback path and the assertion is the same everywhere:
#
#   [battery-low] NOTIFICATION: Battery low — Battery at 10% (alert at 15%)

android_notify() { # $1 = title, $2 = body, $3 = tag
  printf 'STUB-NOTIFY %s|%s|%s\n' "${1:-}" "${2:-}" "${3:-}"
  return 1
}
