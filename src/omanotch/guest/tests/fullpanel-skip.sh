#!/bin/bash
# notchcast stays off for OmacVM.app's FullPanel start (#339): the unit's
# ExecCondition and the installer, against a made-up /run/omacvm/host.env.
# Exit 0 of the condition starts notchcast, 1 skips it (not a failure, so no
# restart loop). No systemd needed.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
G=$(cd "$here/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=1; }

line=$(sed -n 's/^ExecCondition=//p' "$G/systemd/notchcast.service")
[[ $line == "/bin/sh -c '"*"'" ]] || { echo "FAIL no ExecCondition of the expected form: $line"; exit 1; }
cmd=${line#/bin/sh -c \'}; cmd=${cmd%\'}
[[ $cmd != *%* && $cmd != *'$'* ]] && ok "no systemd specifiers or variables in it" || bad "escape % or \$ for systemd: $cmd"
cond() { /bin/sh -c "${cmd//\/run\/omacvm\/host.env/$T/host.env}"; }

rm -f "$T/host.env"
cond && ok "no host.env (UTM, Fusion, Parallels): notchcast starts" || bad "no host.env: skipped"
printf 'OMACVM_NOTCHPOINTER=1\nOMACVM_VKWINDOWS=1\n' > "$T/host.env"
cond && ok "a native OmacVM.app start: notchcast starts" || bad "native start: skipped"
printf 'OMACVM_NOTCHPOINTER=1\nOMACVM_FULLPANEL=640.5x829.5x37.0x1470.0x956.0\n' > "$T/host.env"
if cond; then bad "FullPanel start: notchcast started"; else rc=$?; [[ $rc == 1 ]] && ok "FullPanel start: skipped (exit 1)" || bad "FullPanel: exit $rc (systemd fails the unit above 254)"; fi
printf 'XOMACVM_FULLPANEL=1\n' > "$T/host.env"
cond && ok "only the key at a line's start counts" || bad "a key inside a line skipped it"

grep -q "grep -qs '^OMACVM_FULLPANEL=' /run/omacvm/host.env" "$G/install.sh" &&
  ok "the installer does not wait for notchcast on a FullPanel start" || bad "install.sh would fail on a FullPanel start"
exit $fails
