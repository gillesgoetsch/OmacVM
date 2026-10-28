#!/bin/bash
# OmacVM.app's VM reports freed memory (it leaves QEMU's footprint) in 256 KiB blocks
# (src/memory/guest/90-omacvm-mm.tmpfiles), without a VM: the tmpfiles lines
# applied to a stand-in /sys set page_reporting_order from the kernel's 9 to 6
# and leave a kernel built without free page reporting alone (tmpfiles' "w"
# writes only to a file that is there; Arch's kernel has it, so on Parallels,
# UTM and Fusion 6 is written too and does nothing there: no balloon reports); install.sh installs the file and applies it
# at once; omacvm check has its line on the app route.
#   src/tests/memory-report-order.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
F=$R/src/memory/guest/90-omacvm-mm.tmpfiles
I=$R/src/memory/guest/install.sh
C=$R/src/guest/check.sh
P=/sys/module/page_reporting/parameters/page_reporting_order
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
apply() {   # ROOT: the file's "w" lines as systemd-tmpfiles does them (only into files that exist)
  local t p m u g a arg
  while read -r t p m u g a arg; do
    [[ $t == w && -f $1$p ]] && printf '%s' "$arg" > "$1$p"
  done < <(grep -v '^[[:space:]]*\(#\|$\)' "$F")
}
expect "one line for the order" 1 "$(grep -c "^w $P " "$F")"
mkdir -p "$T/a$(dirname "$P")" "$T/a/sys/kernel/mm/transparent_hugepage" "$T/a/sys/kernel/mm/lru_gen"
echo 9 > "$T/a$P"; echo always > "$T/a/sys/kernel/mm/transparent_hugepage/defrag"; echo 0 > "$T/a/sys/kernel/mm/lru_gen/min_ttl_ms"
apply "$T/a"
expect "order 9 (kernel default) becomes 6" 6 "$(cat "$T/a$P")"
expect "the other lines still apply" "defer+madvise 1000" "$(cat "$T/a/sys/kernel/mm/transparent_hugepage/defrag") $(cat "$T/a/sys/kernel/mm/lru_gen/min_ttl_ms")"
mkdir -p "$T/b/sys/kernel/mm"
apply "$T/b"
expect "kernel without free page reporting: nothing made" no "$([[ -e $T/b$P || -d $T/b/sys/module ]] && echo yes || echo no)"
o=$(sed -n "s|^w $P - - - - \([0-9]*\)$|\1|p" "$F")
expect "the order is 2 (16 KiB, the Mac's page) to 8 (1 MiB)" yes "$([[ -n $o ]] && (( o >= 2 && o < 9 )) && echo yes)"
expect "install.sh installs the file" 1 "$(grep -c 'install -m644 90-omacvm-mm.tmpfiles /etc/tmpfiles.d/90-omacvm-mm.conf' "$I")"
expect "install.sh applies it at once" 1 "$(grep -c 'systemd-tmpfiles --create /etc/tmpfiles.d/90-omacvm-mm.conf' "$I")"
expect "omacvm check reads the order on the app route" 1 "$(grep -c "cat $P" "$C")"
expect "the check row is \"free page reporting\", never memory back to the Mac" "5 0" \
  "$(grep -c '"free page reporting" "' "$C") $(grep -ci 'memory back to the Mac"' "$C")"
exit $fail
