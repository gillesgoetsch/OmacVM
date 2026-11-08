#!/bin/bash
# The built-in display always comes back after display-unplug.sh switched it
# off (D2, 2026-11-08: an M1 Max's built-in stayed off 6 min after the kit
# killed app/scripts/dev/builtin-display.m). The tool in its dry run (no
# display is changed: a made-up built-in that comes back, never comes back,
# or only for the session), stopped by signals; the harness's builtin_back
# and boff_stop with a stand-in tool. Never switches a real display: every
# call of the tool here has --dry-run.
#   src/tests/e2e-builtin-display.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
H=$R/src/tests/e2e/display-unplug.sh
T=$(mktemp -d)
cleanup() { local p; for p in $(LC_ALL=C pgrep -f "$T/"); do kill -9 "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT
fail=0
expect() { if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi; }
has() { if [[ $3 == *"$2"* ]]; then echo "ok   $1"; else echo "FAIL $1: no '$2' in '$(tr '\n' '|' <<<"$3")'"; fail=1; fi; }

# ---- the tool, dry run only
clang -fobjc-arc -framework AppKit -framework CoreGraphics "$R/app/scripts/dev/builtin-display.m" -o "$T/bd" 2> "$T/build.log"
expect "the tool builds" 0 "$?"
dry() { "$T/bd" "$@" 2>&1; }   # the last argument is always a --dry-run
# Never a real display change (CI runs on Macs with a built-in display): the tool must know its dry run,
# and refuses anything else while OMACVM_BDISP_DRY_ONLY is set.
export OMACVM_BDISP_DRY_ONLY=1
out=$(dry mode --dry-run)
if [[ $out != "now builtin=1 mode=1512x982 dry-run active=2" ]]; then
  echo "FAIL the tool has no dry run ('$out'): stopped before any display change"; exit 1
fi
# "off 0" is refused anyway (SECONDS): the variable must refuse it first, so a broken check changes nothing.
out=$("$T/bd" off 0 2>&1); rc=$?
expect "OMACVM_BDISP_DRY_ONLY: off without --dry-run refused first" "9 refused: OMACVM_BDISP_DRY_ONLY is set (a test): only --dry-run" "$rc $out"
out=$(dry off 1 --dry-run); rc=$?
expect "off: rc 0" 0 "$rc"
has "off: goes off for the app only" "display 1 off (app only)" "$out"
has "off: on again at the end" "display 1 on (app only)" "$out"
has "off: the built-in in the list after" "after builtin=1 " "$out"
out=$(dry off 1 --dry-run=session); rc=$?
expect "off, back only for the session: rc 0" 0 "$rc"
has "off, back only for the session: tries the session" "display 1 on (session)" "$out"
for sig in TERM INT HUP; do
  "$T/bd" off 60 --dry-run > "$T/sig.out" 2>&1 & p=$!
  sleep 1; t0=$(date +%s); kill -"$sig" "$p"; wait "$p"; rc=$?
  out=$(cat "$T/sig.out")
  expect "SIG$sig: rc 0 (the built-in on again)" 0 "$rc"
  has "SIG$sig: says it" "stopped (signal" "$out"
  has "SIG$sig: turns it on before it ends" "display 1 on (app only)" "$out"
  expect "SIG$sig: at once, not after the 60 s" yes "$( (( $(date +%s) - t0 < 10 )) && echo yes || echo no)"
done
out=$(dry off 1 --dry-run=stuck); rc=$?
expect "off, never back: rc 7" 7 "$rc"
has "off, never back: says it loudly" "*** THE DISPLAY 1 IS STILL OFF" "$out"
out=$(dry on 1 --dry-run); rc=$?
expect "on ID: rc 0" 0 "$rc"
has "on ID: for the session" "display 1 on (session)" "$out"
out=$(dry on 1 --dry-run=stuck); rc=$?
expect "on ID, never back: rc 7" 7 "$rc"
for a in "off 0" "off 121" "off x" "on x" "on 0" "on" "nothing"; do
  # shellcheck disable=SC2086
  dry $a --dry-run > /dev/null; expect "refused: '$a'" 2 "$?"
done
dry off 1 --dry-run=maybe > /dev/null; expect "refused: --dry-run=maybe" 2 "$?"

# ---- the harness's builtin_back and boff_stop, with a stand-in tool (state in a file)
F=$T/fns.sh
for fn in builtin_back boff_stop; do sed -n "/^$fn() {/,/^}/p" "$H" >> "$F"; done
expect "the harness has builtin_back and boff_stop" 2 "$(grep -c '^[a-z_]*() {' "$F")"
OUT=$T/out; mkdir -p "$OUT"
BDISP=$T/stand-in
cat > "$BDISP" <<EOF
#!/bin/bash
echo "\$*" >> "$T/calls"
case \$1 in
  mode) if [[ \$(cat "$T/state") == on ]]; then echo "now builtin=1 mode=1512x982 px=3024x1964 active=2"; else echo "now builtin=none active=1"; fi ;;
  on) [[ -e $T/stuck ]] || echo on > "$T/state" ;;
  off) trap 'echo on > "$T/state"; exit 0' TERM; echo off > "$T/state"; while :; do sleep 0.2; done ;;
esac
EOF
chmod +x "$BDISP"
rows=""
res() { rows+="$1 $2 $3"$'\n'; }
source "$F"
BDISP_ID=1 BOFF_PID=""
calls() { cat "$T/calls" 2>/dev/null | grep -v '^mode' | tr '\n' ';'; }
reset() { echo "$1" > "$T/state"; rm -f "$T/calls" "$T/stuck"; rows=""; BDISP_LOST=0; BDISP_USED=${2:-1}; }

reset off 0; builtin_back x; rc=$?
expect "never switched off by the run: nothing done" "0 " "$rc $(calls)"
reset on; builtin_back x; rc=$?
expect "back after the tool: rc 0, no row, no call" "0  " "$rc $rows $(calls)"
reset off; builtin_back x 2> "$T/err"; rc=$?
expect "not back, on by its id: rc 0, BDISP_LOST 0" "0 0" "$rc $BDISP_LOST"
expect "not back, on by its id: the call" "on 1;" "$(calls)"
has "not back, on by its id: a FAIL row" "builtin-back-x FAIL the built-in display stayed off after the tool" "$rows"
reset off; touch "$T/stuck"; builtin_back y 2> "$T/err"; rc=$?
expect "still off: rc 1, BDISP_LOST 1" "1 1" "$rc $BDISP_LOST"
has "still off: a FAIL row that says so" "builtin-back-y FAIL THE BUILT-IN DISPLAY 1 IS STILL OFF" "$rows"
has "still off: a loud line" "*** display-unplug: THE BUILT-IN DISPLAY 1 IS STILL OFF" "$(cat "$T/err")"
reset on; "$BDISP" off 120 & BOFF_PID=$!
p=$BOFF_PID; sleep 0.5; boff_stop c; rc=$?
expect "boff_stop: the tool stopped, the built-in back: rc 0, no row" "0 " "$rc $rows"
expect "boff_stop: the tool's process gone, BOFF_PID empty" "no " "$(kill -0 "$p" 2>/dev/null && echo yes || echo no) $BOFF_PID"
reset off; touch "$T/stuck"
( boff_stop d 2>/dev/null; echo "went on" ); rc=$?
expect "boff_stop with the built-in still off: the run ends with 6" 6 "$rc"

# ---- where the harness uses them
rest=$(sed -n '/^restore() {/,/^}/p' "$H")
has "restore: checks the built-in after stopping the tool" '(( BDISP_LOST )) || builtin_back end' "$rest"
has "restore: exit 6 when it is still off" '(( BDISP_LOST )) && exit 6' "$rest"
expect "the tool is stopped only by boff_stop and restore" 2 "$(grep -c 'kill "$BOFF_PID"' "$H")"
expect "fullpanel-builtin: checked after off 10 (both ways)" 2 "$(grep -c 'builtin_back off || exit 6' "$H")"
expect "fullpanel-clamshell: every stop of the tool through boff_stop" 4 "$(grep -c 'boff_stop clamshell' "$H")"
expect "BDISP_USED set before each off" 2 "$(grep -c '^ *BDISP_USED=1$' "$H")"
has "a MacBook with its built-in off at the start is refused" 'OMACVM_E2E_BUILTIN_OFF_OK' "$(cat "$H")"
expect "harness syntax" 0 "$(bash -n "$H" > /dev/null 2>&1; echo $?)"
exit $fail
