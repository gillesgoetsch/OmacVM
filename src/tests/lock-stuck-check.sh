#!/bin/bash
# omacvm check's "Omarchy's lock" warning (guest/check.sh) without a VM.
# omarchy-mac 4.0.x with Quickshell 0.3.2 keeps "locked" true after the first
# unlock, and its lock call then does nothing (lock key, idle lock) until the
# shell restarts (omacom/omarchy-mac#738). Its lock status shows it: locked,
# but not requested, sessionLocked or secure. The row is cut out of
# guest/check.sh and run with a stand-in for the shell's answer.
#   src/tests/lock-stuck-check.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
expect() { if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi; }
part() {   # FILE FIRST-LINE-REGEX LAST-LINE-REGEX: the lines from the first to the last (excluded)
  awk -v a="$2" -v b="$3" '$0 ~ a { on = 1 } on && $0 ~ b { exit } on { print }' "$1"
}
gk=$(part "$R/src/guest/check.sh" "^# Omarchy's lock after an unlock" '^FEATURE=autologin')
[[ $gk == *'"Omarchy'"'"'s lock"'* ]] || { echo "FAIL guest/check.sh: no \"Omarchy's lock\" row"; exit 1; }

# Omarchy's lock status as omarchy-mac's shell answers it (JSON.stringify).
status() {   # LOCKED REQUESTED SESSIONLOCKED SECURE
  printf '{"locked":%s,"requested":%s,"pending":false,"sessionLocked":%s,"secure":%s,"realScreens":1,"passwordPam":true,"fingerprint":false,"authenticating":false,"lastEvent":"unlocked","lastEventAt":"2026-10-29T06:07:48.229Z"}' "$@"
}
WARN=$'\e[33m  WARN\e[0m: Detected locale "C" with character encoding "ANSI_X3.4-1968", which is not UTF-8.\nQt depends on a UTF-8 locale, and has switched to "C.UTF-8" instead.'
row() {   # ANSWER: what `omarchy-shell lock status` prints ("" = no answer)
  ( ANSWER=$1
    as_user() { [[ "$*" == "omarchy-shell lock status" && -n $ANSWER ]] && printf '%s\n' "$ANSWER"; }
    ok() { echo "ok: $1: $2"; }
    bad() { echo "fail: $1: $2"; }
    warn() { echo "warn: $1: $2${3:+ (person)}"; }
    eval "$gk" )
}
STUCK="warn: Omarchy's lock: does not lock again since the last unlock (lock key, idle lock), Omarchy's bug (omacom/omarchy-mac#738): run omarchy-restart-shell in a terminal (person)"

expect "stuck after an unlock: warns" "$STUCK" "$(row "$(status true false false false)")"
expect "stuck, Qt's locale warning first (check runs without a locale): warns" "$STUCK" "$(row "$WARN"$'\n'"$(status true false false false)")"
expect "locked now: nothing" "" "$(row "$(status true true true true)")"
expect "lock on its way: nothing" "" "$(row "$(status true true false false)")"
expect "locked without the request (another path): nothing" "" "$(row "$(status true false true false)")"
expect "never locked, or Omarchy's fix (locked read at the call): nothing" "" "$(row "$(status false false false false)")"
expect "an Omarchy without the status call: nothing" "" "$(row "$WARN")"
expect "the shell does not answer: nothing" "" "$(row "")"
exit $fail
