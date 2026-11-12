#!/bin/bash
# apply's copy of OmacVM into the VM (src/cmd/apply.sh, "step copy") without a
# VM: the step as it is in apply.sh, a stand-in gssh that runs the VM's part
# here with /usr/local/share/omacvm in a temp folder. A failed copy names the
# part that failed and shows the VM's tar errors; a copy that works stays quiet
# (#771). The steps in the VM before it (the bridge token, the control
# centre's key) and the copy are tried again when SSH drops for a moment
# (OMACVM_APPLY_SSH_SECONDS, as the move sets it), and a stop with no reason
# of its own says so (apply_exit).
#   src/tests/apply-copy.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); export T
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
ap=$R/src/cmd/apply.sh
blk=$(awk '/^S=\/usr\/local\/share\/omacvm$/ { on = 1 } on { print } on && /^fi$/ { exit }' "$ap")
expect "the copy step is found in apply.sh" "yes" "$([[ $blk == *'gssh "$IP"'* && $blk == *'cps=('* ]] && echo yes)"
expect "the VM's tar errors are no longer thrown away" "0" "$(printf '%s\n' "$blk" | grep -c 'xzf - 2>/dev/null')"

# A small OmacVM to copy, and the VM's folder.
mkdir -p "$T/src/guest" "$T/vm/usr/local/share" "$T/stub"
echo new > "$T/src/VERSION"; echo 'echo hi' > "$T/src/guest/install.sh"
fn() { awk -v f="$1() {" 'index($0, f) == 1 { on = 1 } on { print } on && /^}$/ { exit }' "$2"; }
expect "vm_again, vm_die, apply_exit and vm_user_file are found in apply.sh" "4" \
  "$(for f in vm_again vm_die apply_exit vm_user_file; do [[ -n $(fn "$f" "$ap") ]] && echo "$f"; done | wc -l | tr -d ' ')"
{ fn vm_again "$ap"; fn vm_die "$ap"; fn apply_exit "$ap"; fn ssh_failure_why "$R/src/lib/mac.sh"; } > "$T/fns"
cat > "$T/run.sh" <<'RUN'
#!/bin/bash
# run.sh BLOCK: the copy step with a stand-in gssh and die. MODE: ok, ssh (SSH
# refused every time), drop (ssh ends with 255 and no word for the first DROPS
# calls: the VM closed the connection), rm, tar, mv.
set -euo pipefail
R=$T; IP=127.0.0.1:52998
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '    %s\n' "$*"; }
log() { OMA_LAST=$*; printf '==> %s\n' "$*"; }
source "$T/fns"
gssh() {
  [[ $MODE == ssh ]] && { cat > /dev/null; echo "ssh: connect to host 127.0.0.1 port 52998: Connection refused" >&2; return 255; }
  if [[ $MODE == drop ]]; then
    local n; n=$(cat "$T/calls" 2>/dev/null || echo 0); echo $((n + 1)) > "$T/calls"
    (( n >= ${DROPS:-0} )) || { cat > /dev/null; return 255; }
  fi
  local cmd=${*: -1}
  cmd=${cmd//\/usr\/local\/share\/omacvm/$T/vm/usr/local/share/omacvm}
  PATH="$T/stub/$MODE:$PATH" bash -c "$cmd"
}
eval "$(cat "$1")"
echo "copied"
RUN
chmod +x "$T/run.sh"
printf '%s\n' "$blk" > "$T/blk"
# Stand-ins for the VM's commands in one part each.
for m in rm tar mv; do mkdir -p "$T/stub/$m"; done
printf '#!/bin/bash\necho "rm: cannot remove: Read-only file system" >&2; exit 1\n' > "$T/stub/rm/rm"
cat > "$T/stub/tar/tar" <<'TAR'
#!/bin/bash
cat > /dev/null; echo "tar: ./guest/install.sh: Cannot open: No space left on device" >&2; echo "tar: Exiting with failure status due to previous errors" >&2; exit 2
TAR
printf '#!/bin/bash\necho "mv: cannot move: Device or resource busy" >&2; exit 1\n' > "$T/stub/mv/mv"
mkdir -p "$T/stub/ok" "$T/stub/ssh" "$T/stub/drop"
chmod +x "$T"/stub/*/*
run() {   # MODE: exit code; output in $T/out
  MODE=$1 /bin/bash "$T/run.sh" "$T/blk" > "$T/out" 2>&1
}
vm=$T/vm/usr/local/share/omacvm

run ok; rc=$?
expect "a copy that works: exit 0, OmacVM in the VM" "0 new" "$rc $(cat "$vm/VERSION" 2>/dev/null)"
expect "... and nothing more said than before" "copied" "$(cat "$T/out")"
echo old > "$T/src/VERSION"; run ok
echo new > "$T/src/VERSION"; run ok; rc=$?
expect "a second copy: the one before kept as omacvm.old" "0 new old" "$rc $(cat "$vm/VERSION") $(cat "$vm.old/VERSION" 2>/dev/null)"

run tar; rc=$?
expect "the VM's tar fails: apply fails, says it was the unpacking" "1 1" \
  "$rc $(grep -c '^error: OmacVM did not get into the VM (unpacking it in the VM failed, see above): nothing changed there$' "$T/out")"
expect "... with the VM's tar errors above it" "2" "$(grep -c '^in the VM: tar: ' "$T/out")"
expect "... the copy that was there is still there" "new" "$(cat "$vm/VERSION")"

run ssh; rc=$?
expect "SSH fails: says it was SSH, why, and ssh's own words" "1 1 1" \
  "$rc $(grep -c '^error: OmacVM did not get into the VM (SSH to the VM failed: nothing takes SSH at 127.0.0.1:52998' "$T/out") $(grep -c 'Connection refused' "$T/out")"

# #771: SSH drops for a moment (ssh ends with 255 and says nothing).
rm -f "$T/calls"; echo new2 > "$T/src/VERSION"
MODE=drop DROPS=2 OMACVM_APPLY_SSH_SECONDS=30 OMACVM_SSH_PAUSE=0 /bin/bash "$T/run.sh" "$T/blk" > "$T/out" 2>&1; rc=$?
expect "SSH drops twice during the copy (the move's time): tried again, copied" "0 new2 2 3" \
  "$rc $(cat "$vm/VERSION") $(grep -c 'SSH to the VM dropped during copying OmacVM (SSH at 127.0.0.1:52998 closed the connection' "$T/out") $(cat "$T/calls")"
rm -f "$T/calls"
MODE=drop DROPS=1 /bin/bash "$T/run.sh" "$T/blk" > "$T/out" 2>&1; rc=$?
expect "... without the move's time (one try, as before): fails, says SSH and why" "1 1 0" \
  "$rc $(grep -c '^error: OmacVM did not get into the VM (SSH to the VM failed: SSH at 127.0.0.1:52998 closed the connection' "$T/out") $(grep -c 'trying again' "$T/out")"
expect "... the copy that was there is still there" "new2" "$(cat "$vm/VERSION")"
# A copy cut between its two moves: the one before is omacvm.old, none in place.
rm -rf "$vm.old" "$vm.new"; mv "$vm" "$vm.old"; echo new3 > "$T/src/VERSION"
run ok; rc=$?
expect "a copy cut between its moves, run again: the one before put back first, then swapped" "0 new3 new2" \
  "$rc $(cat "$vm/VERSION" 2>/dev/null) $(cat "$vm.old/VERSION" 2>/dev/null)"

# The steps before the copy (vm_user_file through vm_again, as apply.sh calls them).
fn vm_user_file "$ap" > "$T/vuf"
grep -q '< "\$2"$' "$T/vuf" || { echo "FAIL vm_user_file takes its file as \$2"; fail=1; }
mkdir -p "$T/home/me"; echo tok > "$T/tok"
cat > "$T/steps.sh" <<'STEPS'
#!/bin/bash
# steps.sh: the bridge token as apply writes it, with the stand-in VM (the
# user me, home $T/home/me; setpriv and getent stood in).
set -euo pipefail
IP=127.0.0.1:52998; U=me
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '    %s\n' "$*"; }
source "$T/fns"; source "$T/vuf"
gssh() {
  local n; n=$(cat "$T/calls" 2>/dev/null || echo 0); echo $((n + 1)) > "$T/calls"
  (( n >= ${DROPS:-0} )) || { cat > /dev/null; return 255; }
  PATH="$T/stub/vm:$PATH" bash -c "${*: -1}"
}
vm_again "the bridge token" vm_user_file token "$T/tok" || vm_die "The bridge token"
echo "written"
STEPS
mkdir -p "$T/stub/vm"
printf '#!/bin/bash\n[ "$2" = me ] && echo "me:x:1000:1000::%s:/bin/bash"\n' "$T/home/me" > "$T/stub/vm/getent"
printf '#!/bin/bash\nwhile [ "${1#--}" != "$1" ]; do shift; done; [ "$1" = -- ] && shift; exec "$@"\n' > "$T/stub/vm/setpriv"
chmod +x "$T/stub/vm/"*
steps() { rm -f "$T/calls"; /bin/bash "$T/steps.sh" > "$T/out" 2>&1; }
DROPS=2 OMACVM_APPLY_SSH_SECONDS=30 OMACVM_SSH_PAUSE=0 steps; rc=$?
expect "the bridge token, SSH dropping twice in the move: tried again, written" "0 written 2 tok" \
  "$rc $(tail -1 "$T/out") $(grep -c 'SSH to the VM dropped during the bridge token' "$T/out") $(cat "$T/home/me/.config/omacvm-bridge/token" 2>/dev/null)"
DROPS=1 steps; rc=$?
expect "... one try outside a move: apply ends with the step and SSH's reason, not silently" "1 1" \
  "$rc $(grep -c '^error: The bridge token did not get into the VM: SSH at 127.0.0.1:52998 closed the connection' "$T/out")"
DROPS=9 OMACVM_APPLY_SSH_SECONDS=1 OMACVM_SSH_PAUSE=1 steps; rc=$?
expect "... SSH not back within the time: ends with the reason" "1 1" \
  "$rc $(grep -c '^error: The bridge token did not get into the VM: SSH at' "$T/out")"
mv "$T/home/me" "$T/home/gone"
DROPS=0 OMACVM_APPLY_SSH_SECONDS=30 OMACVM_SSH_PAUSE=0 steps; rc=$?
expect "... no home folder in the VM: not tried again, the VM's own words and the exit" "1 1 1 1" \
  "$rc $(cat "$T/calls") $(grep -c 'the user me has no home folder' "$T/out") $(grep -c '^error: The bridge token did not get into the VM (exit 1 in the VM, see above)' "$T/out")"
mv "$T/home/gone" "$T/home/me"

# A stop with no word of its own (set -e after a silent ssh) says so.
cat > "$T/exit.sh" <<'EXIT'
#!/bin/bash
set -euo pipefail
GI_LOG=""
source "$T/fns"; trap apply_exit EXIT
log() { OMA_LAST=$*; printf '==> %s\n' "$*"; }
log "bridge token -> 127.0.0.1:52998"
silent() { return "$1"; }
silent "$CODE"
EXIT
CODE=255 /bin/bash "$T/exit.sh" > "$T/out" 2>&1; rc=$?
expect "a silent stop (exit 255): exit kept, the last step and the code named" "255 1" \
  "$rc $(grep -c '^.*error:.* apply stopped (exit 255) after "bridge token -> 127.0.0.1:52998" without saying why$' "$T/out")"
CODE=1 /bin/bash "$T/exit.sh" > "$T/out" 2>&1; rc=$?
expect "... apply's own exits (1-4) come with their own message: nothing added" "1 0" "$rc $(grep -c 'without saying why' "$T/out")"
CODE=0 /bin/bash "$T/exit.sh" > "$T/out" 2>&1; rc=$?
expect "... done: nothing added" "0 0" "$rc $(grep -c 'without saying why' "$T/out")"

run rm; rc=$?
expect "the VM cannot clear the last copy: says so" "1 1" "$rc $(grep -c 'clearing the last copy in the VM failed' "$T/out")"

run mv; rc=$?
expect "the swap fails: says so, and where the one before is" "1 1" \
  "$rc $(grep -c 'swapping the new copy in failed, see above): the one before is in ' "$T/out")"

exit $fail
