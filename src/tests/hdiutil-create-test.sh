#!/bin/bash
# src/tests/hdiutil-create.sh: hdiutil create's exit code passed through; a create that hangs ends after the time
# limit, says so, leaves no process of it behind and is tried once more (with -ov); a second hang exits 124.
# A failure that is not a hang is not tried again. A stand-in for hdiutil (no disk image made).
#   src/tests/hdiutil-create-test.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
expect() { if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: wanted '$2', got '$3'"; fail=1; fi; }
# The stand-in: "create ... IMAGE" -> the Nth word of STUB_MODE for its Nth call (the last word after that):
# ok, exit7, or hang (a child sleeps, it waits).
cat > "$T/hdi" <<'STUB'
#!/bin/bash
echo "$$ $*" >> "$STUB_LOG"
read -r -a modes <<< "$STUB_MODE"
n=$(wc -l < "$STUB_LOG"); n=$((n - $(cat "$STUB_BASE")))
(( n > ${#modes[@]} )) && n=${#modes[@]}
case ${modes[n-1]} in
  ok) exit 0 ;;
  exit7) exit 7 ;;
  hang) sleep 300 & echo "$!" >> "$STUB_KIDS"; wait ;;
esac
STUB
chmod +x "$T/hdi"
export HDIUTIL_CREATE_BIN=$T/hdi STUB_LOG=$T/log STUB_KIDS=$T/kids STUB_BASE=$T/base HDIUTIL_HANG_DIR=$T
: > "$T/log"; : > "$T/kids"
# hc MODES ARGS...: one run of hdiutil-create.sh, the stand-in counting its calls from 1; never as on GitHub Actions
# (the test's own retries are no warning on the run)
hc() { STUB_MODE=$1; shift; wc -l < "$T/log" > "$T/base"; STUB_MODE=$STUB_MODE env -u GITHUB_ACTIONS "$R/src/tests/hdiutil-create.sh" "$@" > "$T/out" 2>&1; }
calls() { echo $(( $(wc -l < "$T/log") - $(cat "$T/base") )); }

hc ok 5 -quiet -size 40m -fs HFS+ -volname t-ok "$T/ok.dmg"
expect "a create that ends: its exit code" 0 $?
expect "the arguments reach hdiutil create" "create -quiet -size 40m -fs HFS+ -volname t-ok $T/ok.dmg" "$(tail -1 "$T/log" | cut -d' ' -f2-)"
expect "a create that ends: one call" 1 "$(calls)"
hc exit7 5 -fs JHFS+ "$T/e.dmg"
expect "a create that fails: its exit code" 7 $?
expect "a create that fails: not tried again" 1 "$(calls)"

t0=$SECONDS
hc "hang ok" 3 -quiet -size 40m -fs HFS+ -volname t-once "$T/once.dmg"
rc=$?
expect "a create that hangs once: the second try's exit code" 0 "$rc"
expect "it ends at the limit (3 s, not 300)" 1 "$(( SECONDS - t0 <= 12 ))"
expect "a create that hangs once: two calls" 2 "$(calls)"
expect "the second try writes over the half-made image (-ov)" "create -ov -quiet -size 40m -fs HFS+ -volname t-once $T/once.dmg" "$(tail -1 "$T/log" | cut -d' ' -f2-)"
expect "it says what hung" 1 "$(grep -c 'hdiutil create hung for 3 s' "$T/out")"
expect "it says it tries again" 1 "$(grep -c 'try 2 of 2' "$T/out")"
stub=$(tail -2 "$T/log" | head -1 | cut -d' ' -f1); kid=$(tail -1 "$T/kids")
sleep 1
expect "the hung create is gone" "" "$(ps -o pid= -p "$stub" 2>/dev/null | tr -d ' ')"
expect "its child is gone" "" "$(ps -o pid= -p "$kid" 2>/dev/null | tr -d ' ')"
wc -l < "$T/log" > "$T/base"
STUB_MODE="hang ok" GITHUB_ACTIONS=true "$R/src/tests/hdiutil-create.sh" 3 -quiet "$T/gh.dmg" > "$T/gh-out" 2>&1
expect "on GitHub Actions the retry is a warning on the run" 1 "$(grep -c '^::warning title=hdiutil create hung::' "$T/gh-out")"

t0=$SECONDS
hc "hang hang ok" 3 -quiet -size 40m -fs HFS+ -volname t-hang "$T/hang.dmg"
rc=$?
expect "a create that hangs twice: exit 124" 124 "$rc"
expect "a create that hangs twice: two calls, no third" 2 "$(calls)"
expect "it ends after two limits (2 x 3 s)" 1 "$(( SECONDS - t0 <= 20 ))"
expect "it says both tries hung" 1 "$(grep -c 'hung on all 2 tries' "$T/out")"
HDIUTIL_CREATE_TRIES=1 hc "hang ok" 3 -quiet "$T/one.dmg"
expect "HDIUTIL_CREATE_TRIES=1: a hang exits 124" 124 $?
expect "HDIUTIL_CREATE_TRIES=1: one call" 1 "$(calls)"
sleep 1
left=""
while read -r k; do [[ -n $(ps -o pid= -p "$k" 2>/dev/null) ]] && left+=" $k"; done < "$T/kids"
expect "no hung create's child is left" "" "$left"
exit $fail
