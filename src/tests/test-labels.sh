#!/bin/bash
# The Mac helpers' LaunchAgent labels (src/lib/labels.sh): the production ones
# only for the user's own HOME; the test identity or another HOME gets
# org.omacvm.test.*, so a test never replaces the user's own helpers in their
# GUI session (launchd has one per user, whatever HOME says). launchctl is a
# fake here: nothing is loaded.
#   src/tests/test-labels.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
own=$(id -P | cut -d: -f9)
[[ -d $own ]] || { echo "FAIL no home for $(id -un) in the user database"; exit 1; }
labels() {   # HOME TEST_IDENTITY: the four labels
  HOME=$1 OMACVM_TEST_IDENTITY=$2 bash -c 'source "$0/src/lib/labels.sh"
    echo $(omacvm_label bridge) $(omacvm_label gestures) $(omacvm_label clip-in) $(omacvm_label omanotch)' "$R"
}
PROD="org.omacvm.bridge org.omacvm.gestures org.omacvm.clip-in ch.gillesgoetsch.omanotch"
TEST="org.omacvm.test.bridge org.omacvm.test.gestures org.omacvm.test.clip-in org.omacvm.test.omanotch"
expect "the user's own HOME: production labels" "$PROD" "$(labels "$own" "")"
expect "own HOME with a trailing slash: production" "$PROD" "$(labels "$own/" "")"
ln -s "$own" "$T/link"
expect "own HOME through a link: production" "$PROD" "$(labels "$T/link" "")"
mkdir -p "$T/home"
expect "another HOME: test labels" "$TEST" "$(labels "$T/home" "")"
expect "the test identity in the own HOME: test labels" "$TEST" "$(labels "$own" 1)"

# The retired clipboard helper (the one seen under the production label,
# 2026-10-08): uninstall.sh's lines for it, run alone with another HOME (the
# whole uninstall would reset real permissions): launchctl only hears the test label.
mkdir -p "$T/bin" "$T/home/Library/LaunchAgents"
printf '#!/bin/bash\necho "$*" >> "%s/launchctl.log"\n' "$T" > "$T/bin/launchctl"; chmod +x "$T/bin/launchctl"
sed -n '/^# The clipboard helper of the retired/,/omacvm-clip-in"$/p' "$R/src/mac/uninstall.sh" > "$T/clip.sh"
HOME=$T/home PATH="$T/bin:$PATH" OMACVM_TEST_IDENTITY="" R="$R/src" bash "$T/clip.sh"
expect "clipboard, another HOME: launchctl calls" "bootout gui/$(id -u)/org.omacvm.test.clip-in" "$(paste -sd'|' "$T/launchctl.log")"
expect "clipboard, another HOME: no production label anywhere" 0 "$(grep -c 'org\.omacvm\.clip-in' "$T/launchctl.log")"

# Every script that loads, removes or asks about a helper's LaunchAgent takes
# its label from omacvm_label, none spells a production one out.
cd "$R/src"
hard=$(grep -nE '^LABEL=(org\.omacvm\.(bridge|gestures|clip-in)|ch\.gillesgoetsch\.omanotch)|gui/\$\(id -u\)/(org\.omacvm\.(bridge|gestures|clip-in)|ch\.gillesgoetsch\.omanotch)|install_app "[^"]*" (org\.omacvm|ch\.gillesgoetsch)|running (org\.omacvm|ch\.gillesgoetsch)' \
  bridge/mac/*.sh gestures/mac/*.sh omanotch/mac/*.sh mac/*.sh cmd/*.sh lib/*.sh)
expect "no production label spelled out" "" "$hard"
exit $fail
