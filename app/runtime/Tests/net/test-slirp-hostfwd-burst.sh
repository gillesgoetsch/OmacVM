#!/bin/bash
# Two connections at the same moment to a host forward of the user network
# (an ssh port without a window) must both work: libslirp listens with more
# than macOS's backlog of 1 (patches/libslirp-hostfwd-listen-backlog.patch).
# Usage: test-slirp-hostfwd-burst.sh QEMU [--old]
#   QEMU   a runtime's qemu-system-aarch64 (or OmacVM)
#   --old  the runtime has no fix: the reset must reproduce (proof the test
#          sees it).
# One idle QEMU without a guest or CPU; nothing leaves the Mac.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
qemu=${1:?usage: test-slirp-hostfwd-burst.sh QEMU [--old]}
if [[ ${2:-} == --old ]]; then
  python3 "$here/slirp-hostfwd-burst.py" --qemu "$qemu" --case reset
else
  python3 "$here/slirp-hostfwd-burst.py" --qemu "$qemu" --case fixed
fi
