#!/bin/bash
# OmacVM is OmacVM.app only since 3.4.0: Parallels, UTM and VMware Fusion are
# retired and come back only with the owner's explicit consent (AGENTS.md).
# This keeps them out: no tracked file names them (whole words), except a
# line that says they are retired, and the files below, each with its reason.
# Changing this list is changing that rule: say so in the PR.
#   src/tests/no-retired-routes.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
cd "$R" || exit 1
WORDS='\b(parallels|prlctl|prl_[a-z]+|utm|utmctl|vmware|vmrun|vmwgfx|vmx|open-vm-tools|spice-vdagent|vdagent|fusion)\b'
ALLOW=(
  ':!CHANGELOG.md'                     # the history
  ':!docs/adr'                         # decisions as they were made
  ':!THIRD_PARTY_NOTICES.md' ':!app/THIRD_PARTY_NOTICES.md'   # QEMU's cocoa code adapted from UTM (Apache-2.0)
  ':!app'                              # OmacVM.app: no change for the sunset (patches, cache marks, UTM credits)
  ':!src/control/omacvm_cc/report.py' ':!src/control/tests/test_report.py'   # report redaction of old addresses and names
  ':!src/control/vendor'               # third-party wheels
  ':!src/bridge' ':!src/gestures' ':!src/omanotch'   # the Mac helpers and their guest parts: their old listeners wait for the owner's call (3.4.0 sunset, R1)
  ':!src/net/mac'                      # notes on other vmnet users
  ':!src/guest/omacvm_vm.lua' ':!src/memory/guest/90-omacvm.sysctl' ':!src/memory/guest/90-omacvm-zram.conf'
  ':!src/keyboard/guest/mac-paste.lua' ':!src/workspaces/guest/monitor_workspaces.lua'   # files in the VM: a change would reload or restart them
  ':!tests/bench' ':!src/bench/chart.py'   # the benchmark rounds with every app (docs/benchmarks)
  ':!README.md' ':!docs'               # the docs' own wording (the retired-routes section)
)
hits=$(git grep -n -I -i -P "$WORDS" -- . "${ALLOW[@]}" | grep -v -i 'retire')
if [[ -n $hits ]]; then
  echo "FAIL Parallels, UTM or VMware Fusion named outside the retired notes:"
  echo "$hits" | cut -c1-200 | head -400
  exit 1
fi
echo "ok   no retired route named in the code"
