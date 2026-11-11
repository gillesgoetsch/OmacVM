#!/bin/bash
# apply's copy of OmacVM into the VM (src/cmd/apply.sh, "step copy") without a
# VM: the step as it is in apply.sh, a stand-in gssh that runs the VM's part
# here with /usr/local/share/omacvm in a temp folder. A failed copy names the
# part that failed and shows the VM's tar errors; a copy that works stays quiet
# (#771).
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
cat > "$T/run.sh" <<'RUN'
#!/bin/bash
# run.sh BLOCK: the copy step with a stand-in gssh (MODE: ok, ssh, rm, tar, mv) and die.
set -euo pipefail
R=$T; IP=127.0.0.1:52998
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
gssh() {
  [[ $MODE == ssh ]] && { cat > /dev/null; echo "ssh: connect to host 127.0.0.1 port 52998: Connection refused" >&2; return 255; }
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
mkdir -p "$T/stub/ok" "$T/stub/ssh"
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
expect "SSH fails: says it was SSH, with ssh's own words" "1 1 1" \
  "$rc $(grep -c 'OmacVM did not get into the VM (SSH to the VM failed, see above)' "$T/out") $(grep -c 'Connection refused' "$T/out")"

run rm; rc=$?
expect "the VM cannot clear the last copy: says so" "1 1" "$rc $(grep -c 'clearing the last copy in the VM failed' "$T/out")"

run mv; rc=$?
expect "the swap fails: says so, and where the one before is" "1 1" \
  "$rc $(grep -c 'swapping the new copy in failed, see above): the one before is in ' "$T/out")"

exit $fail
