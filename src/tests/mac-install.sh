#!/bin/bash
# src/mac/install.sh when a Mac helper does not build: it is named, the one
# installed before stays, the others go on, exit 5; --skip-failed does not
# build it again with the same sources (--retry-app does). No real helper is
# built or started: the helpers are fakes in a copy, HOME is a temp folder.
#   src/tests/mac-install.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src/mac" "$T/src/lib" "$T/src/icon" "$T/home"
cp "$R/src/mac/install.sh" "$T/src/mac/"; cp "$R/src/lib/mac.sh" "$R/src/lib/tools.sh" "$R/src/lib/sign.sh" "$R/src/lib/app.sh" "$R/src/lib/version.sh" "$R/src/lib/labels.sh" "$R/src/lib/helpers.sh" "$T/src/lib/"
for h in bridge gestures omanotch; do
  mkdir -p "$T/src/$h/mac"
  printf '#!/bin/bash\necho run >> "%s/ran-%s"\n[[ ! -e "%s/fail-%s" ]]\n' "$T" "$h" "$T" "$h" > "$T/src/$h/mac/install.sh"
  chmod +x "$T/src/$h/mac/install.sh"
done
export HOME=$T/home OMACVM_CLI_LINKS="" OMACVM_MAC_FAILED_FILE=$T/failed
STAMPS="$T/home/Library/Application Support/omacvm/installed"
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
runs() { [[ -f $T/ran-$1 ]] && wc -l < "$T/ran-$1" | tr -d ' ' || echo 0; }
inst() { rm -f "$T/failed"; "$T/src/mac/install.sh" --quiet "$@" > "$T/out" 2>&1; echo $?; }

touch "$T/fail-bridge"
expect "a helper fails: exit 5" 5 "$(inst)"
expect "it is named" "OmacVM Bridge" "$(cat "$T/failed" 2>/dev/null)"
expect "the others go on" "1" "$(runs gestures)"
expect "no stamp, a failed one" "no yes" "$([[ -e "$STAMPS/OmacVM Bridge" ]] && echo yes || echo no) $([[ -s "$STAMPS/OmacVM Bridge.failed" ]] && echo yes || echo no)"
expect "says so" yes "$(grep -q "OmacVM Bridge did not build or install" "$T/out" && echo yes || cat "$T/out")"

expect "--skip-failed: exit 5 again" 5 "$(inst --skip-failed)"
expect "--skip-failed: not built again" 1 "$(runs bridge)"
expect "--skip-failed: still named" "OmacVM Bridge" "$(cat "$T/failed" 2>/dev/null)"
expect "--skip-failed --retry-app: built again" "5 2" "$(inst --skip-failed --retry-app "OmacVM Bridge") $(runs bridge)"
expect "--force-app overrides --skip-failed" "5 3" "$(inst --skip-failed --force-app "OmacVM Bridge") $(runs bridge)"
expect "without --skip-failed (omacvm update): built again" "5 4" "$(inst) $(runs bridge)"

rm -f "$T/fail-bridge"
expect "fixed: exit 0" 0 "$(inst --skip-failed --retry-app "OmacVM Bridge")"
expect "fixed: stamp, no failed one" "yes no" "$([[ -s "$STAMPS/OmacVM Bridge" ]] && echo yes || echo no) $([[ -e "$STAMPS/OmacVM Bridge.failed" ]] && echo yes || echo no)"
expect "fixed: no failed file" no "$([[ -e $T/failed ]] && echo yes || echo no)"

# Changed sources: a failure from before does not count (it is tried).
touch "$T/fail-omanotch"
inst --omanotch > /dev/null
echo "// changed" >> "$T/src/omanotch/mac/install.sh"
n=$(runs omanotch)
expect "changed sources: tried again with --skip-failed" "5 $((n + 1))" "$(inst --omanotch --skip-failed) $(runs omanotch)"
# The stamp does not depend on the caller's locale: the control centre's jobs
# run with LANG=en_US.UTF-8, a terminal maybe without. A different sum means
# "changed sources", and every switch between the two built and restarted the
# helpers again (the Bridge restarted on each Touch ID switch, 3.0.3).
touch "$T/src/bridge/mac/touchid.swift" "$T/src/bridge/mac/touchid_policy.swift" "$T/src/bridge/mac/Touch.swift"
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 inst > /dev/null; a=$(cat "$STAMPS/OmacVM Bridge")
env -u LANG -u LC_ALL -u LC_COLLATE "$T/src/mac/install.sh" --quiet > /dev/null 2>&1; b=$(cat "$STAMPS/OmacVM Bridge")
expect "the stamp is the same in any locale" "$a" "$b"
expect "a helpers' sum is the same in any locale" "$(LC_ALL=en_US.UTF-8 bash -c "source '$T/src/lib/helpers.sh'; helpers_src_sum '$T/src' bridge/mac")" \
  "$(env -u LANG -u LC_ALL bash -c "source '$T/src/lib/helpers.sh'; helpers_src_sum '$T/src' bridge/mac")"
# apply: the helper each feature needs (a run that turns it on stops when
# that helper did not build).
# One map for apply, check and the app (src/lib/mac-setup.sh).
source "$R/src/lib/mac-setup.sh"
eval "$(grep '^helper_of() {' "$R/src/cmd/apply.sh")"
TYPE=app
expect "helper of bridge" "OmacVM Bridge" "$(helper_of bridge)"
expect "helper of control-centre" "OmacVM Bridge" "$(helper_of control-centre)"
expect "helper of camera: none (the app's own port)" "" "$(helper_of camera)"
expect "helper of scroll-momentum" "OmacVM Gestures" "$(helper_of scroll-momentum)"
# A repair forces its helper's build, but the control centre's does not force
# the Bridge (it restarted the Bridge under the job, 2026-10-08): it is built
# only when missing, stopped or out of date.
eval "$(sed -n '/^repair_forces() {/,/^}/p' "$R/src/cmd/apply.sh")"
expect "repair of control-centre: no forced Bridge" "" "$(repair_forces control-centre)"
expect "repair of bridge: the Bridge" "OmacVM Bridge" "$(repair_forces bridge)"
expect "repair of scroll-momentum: Gestures" "OmacVM Gestures" "$(repair_forces scroll-momentum)"
grep -q 'h=$(repair_forces "$f"); \[\[ -n $h \]\] && args+=(--force-app "$h")' "$R/src/cmd/apply.sh" ||
  { echo "FAIL apply.sh forces helpers through repair_forces"; fail=1; }
# The test identity starts its helpers only when they do not run, also when
# "OmacVM Test.app" is a link to a copy elsewhere (the running helper shows
# the copy's real path). A stand-in open counts the starts.
TA="$T/drive/OmacVM Test.app"
mkdir -p "$TA/Contents/Helpers/OmacVM Test Bridge.app/Contents/MacOS" "$TA/Contents/Helpers/OmacVM Test Gestures.app/Contents/MacOS" \
  "$T/home/Applications" "$T/bin"
ln -s "$TA" "$T/home/Applications/OmacVM Test.app"
REAL=$(cd -P "$TA/Contents/Helpers" && pwd)
printf '#!/bin/bash\nwhile :; do sleep 1; done\n' > "$REAL/OmacVM Test Bridge.app/Contents/MacOS/omacvm-bridge"
chmod +x "$REAL/OmacVM Test Bridge.app/Contents/MacOS/omacvm-bridge"
"$REAL/OmacVM Test Bridge.app/Contents/MacOS/omacvm-bridge" & SP=$!
printf '#!/bin/bash\necho "$*" >> "%s/opened"\n' "$T" > "$T/bin/open"; chmod +x "$T/bin/open"
PATH=$T/bin:$PATH OMACVM_TEST_IDENTITY=1 "$T/src/mac/install.sh" --quiet > "$T/out" 2>&1
expect "test identity through a link: the running Bridge is not started again" 0 "$(grep -c "Test Bridge" "$T/opened")"
expect "... Gestures (not running) is" 1 "$(grep -c "Test Gestures" "$T/opened")"
kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
exit $fail
