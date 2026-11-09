#!/bin/bash
# move-45.sh's app rows quit the test app copy they started, also the one
# the app's self-update starts: update-swap.sh opens the swapped-in app with
# --update-check after the version in its Info.plist changed, so a sweep
# right after the version check missed it (3.4.1's app-guards run left it
# open and the next app row was BLOCKED). Stand-ins: a looping script as the
# copy's launcher, a script named update-swap.sh that starts it late. No VM,
# no app, no lock of the Mac.
#   src/tests/move-45-app-quit.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
K=$R/src/tests/e2e/move-45.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/move45 app quit.XXXXXX")
fail=0
expect() { if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi; }

# The functions under test, from the kit itself.
F=$T/fns.sh
for fn in ua_re ua_launchers ua_swaps ua_settle app_clean; do
  awk -v f="$fn() {" 'index($0, f) == 1 { on = 1; print; if ($0 ~ /}$/) exit; next } on { print } on && /^}/ { exit }' "$K" >> "$F"
done
expect "the kit has the five functions" 5 "$(grep -c '^[a-z_]*() {' "$F")"
source "$F"

# A copy with a space and dots in its path, as ~/omacvm-work/move45-app/OmacVM Test.app.
UA="$T/move45 app/OmacVM Test.app"; mkdir -p "$UA/Contents/MacOS" "$T/upd"
printf '#!/bin/bash\n[[ ${STUBBORN:-0} == 1 ]] && trap "" TERM\nwhile :; do sleep 0.2; done\n' > "$UA/Contents/MacOS/OmacVM"
chmod +x "$UA/Contents/MacOS/OmacVM"
# Another copy whose name starts the same: never touched.
UB="$T/move45 app/OmacVM Test.app.old"; mkdir -p "$UB/Contents/MacOS"; cp "$UA/Contents/MacOS/OmacVM" "$UB/Contents/MacOS/"
# update-swap.sh: DELAY s, then the swapped-in app with --update-check (left running), then a bit more.
printf '#!/bin/bash\nsleep "$DELAY"\n"$2/Contents/MacOS/OmacVM" --update-check 0123 >/dev/null 2>&1 &\nsleep 1\n' > "$T/upd/update-swap.sh"
cleanup() {   # everything the stand-ins started
  local p; for p in $(LC_ALL=C pgrep -f "$T/"); do kill -9 "$p" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT
n_ua() { ua_launchers | grep -c .; }
swap() { ( DELAY=$1 bash "$T/upd/update-swap.sh" install "$UA" "$T/upd/new.app" "$T/upd" 1 0123 >/dev/null 2>&1 & ) }

expect "the pattern: dots and brackets literal" 'a\.b \(c\)\[1\]' "$(UA='a.b (c)[1]' ua_re)"
UA_SAVE=$UA; UA=""
expect "no copy yet: nothing found" "" "$(ua_launchers; ua_swaps)"
ua_settle 5; expect "no copy yet: settle is done at once" 0 "$?"
UA=$UA_SAVE

# The way before (3.4.1): 5 s after the version changed, the launchers then; the swap opens the app later.
( "$UB/Contents/MacOS/OmacVM" & )
swap 7; sleep 5
for p in $(ua_launchers); do kill "$p" 2>/dev/null; done
sleep 4
expect "before: a sweep 5 s after the version check leaves the swapped-in app open" 1 "$(n_ua)"
ua_settle 20 >/dev/null

# Now: settle waits for update-swap.sh, then quits the app it opened.
swap 4; sleep 0.5
expect "update-swap.sh of the copy is seen" 1 "$(ua_swaps | grep -c .)"
t0=$(date +%s); ua_settle 30; rc=$?
expect "settle: rc 0" 0 "$rc"
expect "settle: no launcher of the copy left" 0 "$(n_ua)"
expect "settle: update-swap.sh had ended" "" "$(ua_swaps)"
expect "settle: waited for the swap (>= 3 s)" yes "$( (( $(date +%s) - t0 >= 3 )) && echo yes || echo no)"
expect "the other copy still runs" 1 "$(LC_ALL=C pgrep -f "$UB/Contents/MacOS/OmacVM" | grep -c .)"

# A launcher that ignores SIGTERM: killed after 15 s.
( STUBBORN=1 "$UA/Contents/MacOS/OmacVM" --vm x & )
sleep 0.5
ua_settle 5; expect "a launcher that ignores SIGTERM: rc 0" 0 "$?"
expect "a launcher that ignores SIGTERM: gone" 0 "$(n_ua)"

# app_clean: only while this run holds the test identity's lock.
ULOCK=$T/lock; UPID=""; FEED_PID=""; USAVED=""
( "$UA/Contents/MacOS/OmacVM" --vm y & )
sleep 0.5
ULOCK_MINE=0; app_clean
expect "app_clean without the lock: the copy's launcher stays" 1 "$(n_ua)"
mkdir "$ULOCK"; ULOCK_MINE=1; app_clean
expect "app_clean with the lock: no launcher left" 0 "$(n_ua)"
expect "app_clean with the lock: the lock released" no "$([[ -d $ULOCK ]] && echo yes || echo no)"
expect "app_clean with the lock: done in the queue" 1 "$(grep -c 'move-45 .* done' "$ULOCK.wait")"

# The row uses it, the old sweep is gone.
row=$(sed -n '/^row_app_guards() {/,/^}/p' "$K")
expect "app-guards: the check after the update" 1 "$(grep -c 'check "after the move: the updated app quit, no launcher of the copy left" $(ua_settle 150' <<<"$row")"
expect "app-guards: no sweep 5 s after the version check" 0 "$(grep -c '^  sleep 5$' <<<"$row")"
expect "app-guards: update.log marked before the app opens after the move" 1 "$(grep -cF 'local umark; umark=$(upd_mark)' <<<"$row")"
expect "app-guards: the swapped-in app answered its start check (update.log), not put back" 1 \
  "$(grep -cF '$([[ $ul == *"swap: $cv started"* && $ul != *"swap: $cv did not start"* &&' <<<"$row")"
expect "app-guards: that check comes after the settle" yes \
  "$(awk '/ua_settle 150 &&/ { s = NR } /swap: \$cv started"\* &&/ { c = NR } END { print (s && c > s) ? "yes" : "no" }' <<<"$row")"
expect "app_clean settles while it holds the lock" 1 "$(sed -n '/^app_clean() {/,/^}/p' "$K" | grep -c '(( ULOCK_MINE )) && ua_settle 150')"
expect "kit syntax" 0 "$(bash -n "$K" >/dev/null 2>&1; echo $?)"
exit $fail
