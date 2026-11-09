#!/bin/bash
# src/tests/hdiutil-create.sh: hdiutil create's exit code passed through; a create that hangs ends after the time
# limit with exit 124, says so, and leaves no process of it behind. A stand-in for hdiutil (no disk image made).
#   src/tests/hdiutil-create-test.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
expect() { if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: wanted '$2', got '$3'"; fail=1; fi; }
# The stand-in: "create ... IMAGE" -> MODE from the environment: ok, exit7, or hang (a child sleeps, it waits).
cat > "$T/hdi" <<'STUB'
#!/bin/bash
echo "$$ $*" >> "$STUB_LOG"
case $STUB_MODE in
  ok) exit 0 ;;
  exit7) exit 7 ;;
  hang) sleep 300 & echo "$!" >> "$STUB_KIDS"; wait ;;
esac
STUB
chmod +x "$T/hdi"
export HDIUTIL_CREATE_BIN=$T/hdi STUB_LOG=$T/log STUB_KIDS=$T/kids HDIUTIL_HANG_DIR=$T

STUB_MODE=ok "$R/src/tests/hdiutil-create.sh" 5 -quiet -size 40m -fs HFS+ -volname t-ok "$T/ok.dmg" > "$T/out" 2>&1
expect "a create that ends: its exit code" 0 $?
expect "the arguments reach hdiutil create" "create -quiet -size 40m -fs HFS+ -volname t-ok $T/ok.dmg" "$(tail -1 "$T/log" | cut -d' ' -f2-)"
STUB_MODE=exit7 "$R/src/tests/hdiutil-create.sh" 5 -fs JHFS+ "$T/e.dmg" > "$T/out" 2>&1
expect "a create that fails: its exit code" 7 $?

t0=$SECONDS
STUB_MODE=hang "$R/src/tests/hdiutil-create.sh" 3 -quiet -size 40m -fs HFS+ -volname t-hang "$T/hang.dmg" > "$T/out" 2>&1
rc=$?
expect "a create that hangs: exit 124" 124 "$rc"
expect "it ends at the limit (3 s, not 300)" 1 "$(( SECONDS - t0 <= 10 ))"
expect "it says what hung" 1 "$(grep -c 'hdiutil create hung for 3 s' "$T/out")"
stub=$(tail -1 "$T/log" | cut -d' ' -f1); kid=$(cat "$T/kids")
sleep 1
expect "the hung create is gone" "" "$(ps -o pid= -p "$stub" 2>/dev/null | tr -d ' ')"
expect "its child is gone" "" "$(ps -o pid= -p "$kid" 2>/dev/null | tr -d ' ')"
exit $fail
