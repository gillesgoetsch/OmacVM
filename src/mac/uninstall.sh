#!/bin/bash
# Remove everything OmacVM installed on the Mac (the VM is left alone).
# --purge also deletes the bridge token, config and logs.
R=$(cd "$(dirname "$0")/.." && pwd)
PURGE=""
for a in "$@"; do
  case $a in
    --purge) PURGE=--purge ;;
    -h|--help) sed -n '2,3s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "omacvm uninstall: unknown option $a (see --help)" >&2; exit 2 ;;
  esac
done
"$R/bridge/mac/uninstall.sh" $PURGE
"$R/gestures/mac/uninstall.sh"
"$R/clipboard/mac/uninstall.sh"
"$R/omanotch/mac/uninstall.sh"
tccutil reset Accessibility org.omacvm.gestures >/dev/null 2>&1 || true
tccutil reset ListenEvent org.omacvm.gestures >/dev/null 2>&1 || true
S="$HOME/Library/Application Support/omacvm"
rm -rf "$S/installed"
# Only OmacVM's own files: on macOS's usual case-insensitive disk this is the
# same folder as OmacVM.app's "Application Support/OmacVM", which holds the
# app's VMs.
if [[ -n $PURGE ]]; then
  rm -rf "$HOME/.local/share/omacvm" "$S/known_hosts" "$S/gestures-legacy"   # known_hosts: the VMs' SSH host keys
  rmdir "$S" 2>/dev/null || true
fi
echo "OmacVM removed from this Mac"
# What stays: the omacvm command itself and OmacVM.app (which may hold VMs).
top=$(cd "$R/.." && pwd)
link=$(command -v omacvm 2>/dev/null) || link=""
echo "Still here: the omacvm command ($top${link:+ and $link}); delete ${link:+them}${link:-it} to remove it."
echo "OmacVM.app, if installed, stays too: drag it to the Bin (its VMs stay in ~/Library/Application Support/OmacVM)."
