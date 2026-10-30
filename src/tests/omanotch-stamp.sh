#!/bin/bash
# Update VM installs Omanotch again only when its files changed: guest/install.sh
# sums every file of omanotch/guest and compares the sum with the VM's stamp.
# Python's compiled files are not Omanotch's: in an OmacVM.app VM the same
# apply loads monitor/display-panel.py (monitor-widget/build.py, as root) and
# leaves monitor/__pycache__/*.pyc in the new copy. A .pyc holds its source's
# file time, which every new copy changes, so each update installed Omanotch
# again for nothing. Runs install.sh's own line on a copy of omanotch/guest.
#   src/tests/omanotch-stamp.sh [SRC]   (SRC: another checkout's src/; v3.2.13's fails)
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$(cd "${1:-$R/src}" && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
T=$(mktemp -d "${TMPDIR:-/tmp}/omanotch-stamp.XXXXXX"); trap 'rm -rf "$T"' EXIT

line=$(grep -E '^  sum=\$\(cd "\$R/omanotch/guest" && find ' "$SRC/guest/install.sh")
[[ -n $line ]] || { echo "FAIL install.sh has no Omanotch sum line"; exit 1; }
mkdir -p "$T/src"
cp -R "$SRC/omanotch" "$T/src/"
find "$T/src/omanotch" -name __pycache__ -prune -exec rm -rf {} +
stamp() { ( R=$T/src; eval "$line"; echo "$sum" ); }

a=$(stamp)
expect "a sum" 16 "${#a}"
touch -t 202001010000 "$T/src/omanotch/guest/monitor/display-panel.py"
expect "another file time: the same sum" "$a" "$(stamp)"
mkdir -p "$T/src/omanotch/guest/monitor/__pycache__"
printf 'compiled, with the source file time\n' > "$T/src/omanotch/guest/monitor/__pycache__/display-panel.cpython-314.pyc"
expect "a compiled display-panel.py beside it: the same sum" "$a" "$(stamp)"
mkdir -p "$T/src/omanotch/guest/__pycache__"
printf 'x\n' > "$T/src/omanotch/guest/__pycache__/copies.cpython-314.pyc"
expect "  and one of copies.py" "$a" "$(stamp)"
printf '# changed\n' >> "$T/src/omanotch/guest/monitor/display-panel.py"
b=$(stamp)
expect "a changed file: another sum" yes "$([[ $b != "$a" ]] && echo yes || echo no)"
printf 'new\n' > "$T/src/omanotch/guest/monitor/new.txt"
expect "a new file: another sum" yes "$([[ $(stamp) != "$b" ]] && echo yes || echo no)"

exit $fail
