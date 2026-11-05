#!/bin/bash
# omacvm report [--vm NAME [--vm-type TYPE]] [--print | --save FILE]: report a problem. Collects
# omacvm check, versions (OmacVM, OmacVM.app, macOS, chip) and the
# last lines of OmacVM's logs on this Mac, takes out personal data (user and
# host names, VM names, addresses, Wi-Fi and Bluetooth names, tokens, keys,
# serial numbers), shows exactly what would be sent, then opens a pre-filled
# GitHub issue in the browser (you submit it there). In the VM, the control
# centre's "Report a problem" (omacvm, then !) adds the VM's side.
# --print: only print the report; --save FILE: write it to FILE.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
case ${1:-} in -h|--help) sed -n '2,9s/^# \{0,1\}//p' "$0"; exit 0 ;; esac
# macOS's python3 with Xcode's Command Line Tools, else OmacVM.app's (never
# the stub that asks to install them: src/lib/tools.sh).
source "$R/src/lib/tools.sh"
export PYTHONDONTWRITEBYTECODE=1   # nothing written into OmacVM.app's copy
PY=$(tools_python) || { echo "omacvm report needs python3: install Xcode's Command Line Tools (xcode-select --install) or OmacVM.app" >&2; exit 3; }
exec "$PY" "$R/src/control/omacvm" report --mac --root "$R" "$@"
