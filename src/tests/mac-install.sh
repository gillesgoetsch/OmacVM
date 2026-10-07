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
cp "$R/src/mac/install.sh" "$T/src/mac/"; cp "$R/src/lib/mac.sh" "$R/src/lib/tools.sh" "$R/src/lib/sign.sh" "$R/src/lib/app.sh" "$R/src/lib/version.sh" "$R/src/lib/helpers.sh" "$T/src/lib/"
for h in bridge gestures clipboard omanotch; do
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
expect "the others go on" "1 1" "$(runs gestures) $(runs clipboard)"
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
eval "$(sed -n '/^helper_of() {/,/^}/p' "$R/src/cmd/apply.sh")"
TYPE=parallels
expect "helper of bridge" "OmacVM Bridge" "$(helper_of bridge)"
expect "helper of control-centre" "OmacVM Bridge" "$(helper_of control-centre)"
expect "helper of camera on Parallels: none" "" "$(helper_of camera)"
TYPE=utm
expect "helper of camera on UTM" "OmacVM Bridge" "$(helper_of camera)"
expect "helper of scroll-momentum" "OmacVM Gestures" "$(helper_of scroll-momentum)"
exit $fail
