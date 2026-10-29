#!/bin/bash
# The Omarchy shell's restart for new bar widgets (src/guest/restart-shell.sh,
# run by guest/install.sh at the end of an apply) without a VM: restarted at
# once unless the session is locked, then right after the unlock. "Locked" is
# Omarchy's lock status read at the call, not isLocked, which Quickshell 0.3.2
# leaves true after the first unlock (omarchy-mac#738). omarchy-shell,
# omarchy-restart-shell, systemd-run and sleep are stand-ins.
#   src/tests/restart-shell.sh [SCRIPT]   (SCRIPT: another restart-shell.sh to test)
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
K=${1:-$R/src/guest/restart-shell.sh}
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
[[ -f $K ]] || { echo "FAIL $K is missing"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
# omarchy-shell: up while $T/up exists; answers from $T/status and $T/islocked
# (absent: the call is unknown, exit 1 as Omarchy's omarchy-shell says it).
cat > "$T/bin/omarchy-shell" <<'EOF'
#!/bin/bash
echo "omarchy-shell $*" >> "$CALLS"
[[ -e $S/up ]] || exit 1
case "$1 $2" in
  "shell ping") exit 0 ;;
  "lock status") [[ -f $S/status ]] || exit 1; cat "$S/status" ;;
  "lock isLocked") [[ -f $S/islocked ]] || exit 1; cat "$S/islocked" ;;
  *) exit 1 ;;
esac
EOF
cat > "$T/bin/omarchy-restart-shell" <<'EOF'
#!/bin/bash
echo "omarchy-restart-shell" >> "$CALLS"
EOF
cat > "$T/bin/systemd-run" <<'EOF'
#!/bin/bash
echo "systemd-run $*" >> "$CALLS"
EOF
# sleep: counts; $S/after-N runs (a script) after the Nth one
cat > "$T/bin/sleep" <<'EOF'
#!/bin/bash
echo "sleep $*" >> "$CALLS"
n=$(( $(cat "$S/sleeps" 2>/dev/null || echo 0) + 1 )); echo $n > "$S/sleeps"
[[ -f $S/after-$n ]] && bash "$S/after-$n"
exit 0
EOF
chmod +x "$T/bin/"*
export PATH=$T/bin:$PATH CALLS=$T/calls S=$T/s

# Omarchy's lock status as omarchy-mac's shell answers it (JSON.stringify).
status() {   # LOCKED REQUESTED SESSIONLOCKED SECURE
  printf '{"locked":%s,"requested":%s,"pending":false,"sessionLocked":%s,"secure":%s,"realScreens":1,"passwordPam":true,"fingerprint":false,"authenticating":false,"lastEvent":"unlocked","lastEventAt":"2026-10-29T04:33:00.914Z"}\n' "$@"
}
WARN=$'\e[33m  WARN\e[0m: Detected locale "C" with character encoding "ANSI_X3.4-1968", which is not UTF-8.\nQt depends on a UTF-8 locale, and has switched to "C.UTF-8" instead.'
fresh() { rm -rf "$S" "$CALLS"; mkdir -p "$S"; : > "$CALLS"; touch "$S/up"; }
calls() { grep -v '^omarchy-shell' "$CALLS" | paste -sd'|' -; }
SELF=$(cd "$(dirname "$K")" && pwd)/$(basename "$K")
QUEUED="systemd-run --user --quiet --collect --unit=omacvm-restart-shell bash $SELF --after-unlock"

# 1. Unlocked after an earlier lock: isLocked still says true (Quickshell 0.3.2).
fresh; status true false false false > "$S/status"; echo true > "$S/islocked"
out=$(bash "$K"); rc=$?
expect "unlocked after an unlock (isLocked stale): restarted now" "omarchy-restart-shell 0" "$(calls) $rc"
expect "  nothing said" "" "$out"

# 2. Never locked.
fresh; status false false false false > "$S/status"; echo false > "$S/islocked"
bash "$K" >/dev/null
expect "never locked: restarted now" "omarchy-restart-shell" "$(calls)"

# 3. The lock screen is up: a user unit restarts the shell after the unlock.
fresh; status true true false true > "$S/status"; echo true > "$S/islocked"
out=$(bash "$K"); rc=$?
expect "locked: not now, after the unlock" "$QUEUED 0" "$(calls) $rc"
expect "  says so" "the Omarchy shell restarts after the next unlock (new bar widgets)" "$out"

# 4. On its way (asked, the compositor not yet locked) and locked without the
#    request (another path): both wait too.
fresh; status true true false false > "$S/status"
bash "$K" >/dev/null
expect "lock requested: waits" "$QUEUED" "$(calls)"
fresh; status true false true false > "$S/status"
bash "$K" >/dev/null
expect "session locked: waits" "$QUEUED" "$(calls)"

# 5. The waiter: locked for two looks, then unlocked: restarts once, 2 s later.
fresh; status true true true true > "$S/status"
status true false false false > "$S/unlocked"
echo "cp '$S/unlocked' '$S/status'" > "$S/after-2"
bash "$K" --after-unlock >/dev/null; rc=$?
expect "waiter: restarts right after the unlock" "sleep 5|sleep 5|sleep 2|omarchy-restart-shell 0" "$(calls) $rc"

# 6. The waiter while the shell goes away (logout, or a restart by someone
#    else: the next shell loads the widgets anyway): ends without a restart.
fresh; status true true true true > "$S/status"
echo "rm -f '$S/up'" > "$S/after-1"
bash "$K" --after-unlock >/dev/null; rc=$?
expect "waiter: the shell went away: no restart" "sleep 5 0" "$(calls) $rc"

# 7. Not running at all (nobody logged in): nothing.
fresh; rm -f "$S/up"; status true false false false > "$S/status"
out=$(bash "$K"); rc=$?
expect "no shell: nothing" "||0" "$(calls)|$out|$rc"

# 8. An Omarchy without the status call: isLocked as before.
fresh; echo true > "$S/islocked"
bash "$K" >/dev/null
expect "no status call, isLocked true: waits" "$QUEUED" "$(calls)"
fresh; echo false > "$S/islocked"
bash "$K" >/dev/null
expect "no status call, isLocked false: restarted" "omarchy-restart-shell" "$(calls)"

# 9. A C locale: qs prints Qt's warning before each answer.
fresh; { echo "$WARN"; status true false false false; } > "$S/status"; { echo "$WARN"; echo true; } > "$S/islocked"
bash "$K" >/dev/null
expect "C locale, unlocked: restarted" "omarchy-restart-shell" "$(calls)"
fresh; { echo "$WARN"; status true true true true; } > "$S/status"; { echo "$WARN"; echo true; } > "$S/islocked"
bash "$K" >/dev/null
expect "C locale, locked: waits" "$QUEUED" "$(calls)"
fresh; { echo "$WARN"; echo true; } > "$S/islocked"
bash "$K" >/dev/null
expect "C locale, no status call, isLocked true: waits" "$QUEUED" "$(calls)"

# 10. install.sh runs this script, and nothing of OmacVM's asks isLocked
#     first any more.
I=$R/src/guest/install.sh
expect "install.sh runs restart-shell.sh" 1 "$(grep -c 'bash "$R/guest/restart-shell.sh"' "$I")"
expect "no isLocked in install.sh" 0 "$(grep -c 'lock isLocked' "$I")"
expect "copies.py asks status first" 1 "$(grep -c '"omarchy-shell", "lock", "status"' "$R/src/omanotch/guest/copies.py")"

exit $fail
