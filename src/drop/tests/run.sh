#!/bin/bash
# drag-drop, VM side, without a VM: omacvm-drop's lines, uri-list and where a
# drop goes (test_omacvm_drop.py), and the VM step (install-test.sh).
#   src/drop/tests/run.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
python3 "$here/test_omacvm_drop.py"
"$here/install-test.sh"
