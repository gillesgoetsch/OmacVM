#!/bin/bash
# An OmacVM.app VM folder carries its own SSH key (ssh-key, ssh-key.pub), so a
# VM copied to another Mac is still reached there: on 2026-10-09 a VM copied
# from a MacBook Pro to a MacBook Air trusted only the MacBook Pro's
# ~/.ssh/omacvm, and Update VM waited for SSH. app_ssh_key makes it, vm_pin
# finds it, gssh (the omacvm command) and vssh (the app's scripts) offer it
# before the Mac's key. A stand-in ssh prints what it gets; fixture home only.
#   src/tests/vm-ssh-key.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
export OMACVM_APP_ID=org.omacvm.test.vm-ssh-key.$$
trap 'defaults delete "$OMACVM_APP_ID" >/dev/null 2>&1; rm -rf "$T" "$HOME/Library/Preferences/$OMACVM_APP_ID.plist"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
H=$T/home; B=$T/bin; mkdir -p "$H/.ssh" "$B"
printf '#!/bin/bash\nfor a; do [[ $a == -i ]] && n=1 && continue; [[ ${n:-} == 1 ]] && printf "%%s " "$a"; n=; done; echo\n' > "$B/ssh"
chmod +x "$B/ssh"
: > "$H/.ssh/omacvm"
V="$H/VMs/Copied VM"; mkdir -p "$V"
printf "NAME='Copied VM'\nCPUS=2\nMEM_MB=4096\nDISK_GB=64\nSSH_PORT=52998\nVM_USER='me'\n" > "$V/vm.env"
defaults write "$OMACVM_APP_ID" vmsRoot "$H/VMs"
lib() {   # CODE [ARG...]: CODE with the Mac libraries, ARGs as $1...
  env HOME="$H" PATH="$B:$PATH" bash -c 'source "$1/src/lib/mac.sh"; source "$1/src/lib/vm.sh"; c=$2; shift 2; eval "$c"' _ "$R" "$@"
}

k=$(lib 'app_ssh_key "$1"' "$V" 2>&1)
expect "app_ssh_key makes the folder's key" "$V/ssh-key" "$k"
expect "... private key 0600" "-rw-------" "$(stat -f %Sp "$V/ssh-key")"
expect "... an ed25519 key" "yes" "$(grep -q '^ssh-ed25519 ' "$V/ssh-key.pub" && echo yes)"
before=$(cat "$V/ssh-key.pub")
lib 'app_ssh_key "$1"' "$V" >/dev/null
expect "... kept as it is when there" "$before" "$(cat "$V/ssh-key.pub")"
priv=$(cat "$V/ssh-key"); rm -f "$V/ssh-key.pub"; chmod 644 "$V/ssh-key"; lib 'app_ssh_key "$1"' "$V" >/dev/null
expect "... .pub gone: made again from the key, the key kept (the VM may know it)" "yes yes -rw-------" \
  "$([[ $(cat "$V/ssh-key.pub") == "$before" ]] && echo yes) $([[ $(cat "$V/ssh-key") == "$priv" ]] && echo yes) $(stat -f %Sp "$V/ssh-key")"
rm -f "$V/ssh-key"; lib 'app_ssh_key "$1"' "$V" >/dev/null
expect "... the key gone: a new one" "yes" "$([[ -f $V/ssh-key && $(cat "$V/ssh-key.pub") != "$before" ]] && echo yes)"

expect "gssh to an app VM: the folder's key first, then the Mac's" "$V/ssh-key $H/.ssh/omacvm " \
  "$(lib 'vm_pin "Copied VM" app; gssh 127.0.0.1:52998 true')"
expect "gssh to a VM of another app: the Mac's key only" "$H/.ssh/omacvm " \
  "$(lib 'vm_pin "Copied VM" app; vm_pin "Copied VM" other; gssh 10.0.2.9 true')"
mkdir -p "$H/VMs/Old VM"; printf "NAME='Old VM'\n" > "$H/VMs/Old VM/vm.env"
expect "an app VM without its own key (set up before): the Mac's key only" "$H/.ssh/omacvm " \
  "$(lib 'vm_pin "Copied VM" app; vm_pin "Old VM" app; gssh 127.0.0.1:52997 true')"

# The app's scripts (app/scripts/vm-common.sh): vm_load makes the key, vssh offers it first.
got=$(env HOME="$H" PATH="$B:$PATH" OMACVM_KEY="$H/.ssh/omacvm" bash -c 'die() { echo "die: $*"; exit 1; }; qe() { printf "%s" "$1"; }
  eval "$(sed -n -e "/^vm_load()/,/^}/p" -e "/^vssh()/,/^}/p" "$1")"; KEY=$OMACVM_KEY
  rm -f "$2/ssh-key" "$2/ssh-key.pub"; vm_load "$2" >/dev/null; vssh true' _ "$R/app/scripts/vm-common.sh" "$V")
expect "vssh: the folder's key first, then the Mac's" "$V/ssh-key $H/.ssh/omacvm " "$got"
expect "vm_load made the folder's key" "yes" "$([[ -f $V/ssh-key && -f $V/ssh-key.pub ]] && echo yes)"
exit $fail
