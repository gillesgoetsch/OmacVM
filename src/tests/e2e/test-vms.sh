#!/bin/bash
# For e2e harnesses that run the test app (OmacVM Test.app, org.omacvm.app.test)
# on a Mac with a person's own VMs. Source it:
#   source src/tests/e2e/test-vms.sh
#   e2e_settings_save DOMAIN DIR KEY...   the keys as they are now, into DIR
#   e2e_settings_restore DOMAIN DIR KEY... them back; a key with nothing saved
#                                         stays as it is (exit 1), never deleted
#   e2e_vms_root DOMAIN                   the test app's VMs folder; exit 1 when
#                                         it has none or it is one of the installed app's
#   e2e_vm_guard DOMAIN NAME              the folder of test VM NAME; exit 1 unless
#                                         it is there, in that folder, with that name
# 2026-10-07: a harness's clean step saved the VMs folder setting into a path
# with a space without quotes (nothing was saved), then deleted the setting;
# the next harness's `--vm NAME` was not found and the test app fell back to
# the person's VM. Paths are quoted here, and a missing save never deletes.
_E2E_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)
source "$_E2E_LIB/app.sh" || { echo "test-vms.sh: no src/lib/app.sh beside src/tests/e2e: run the harness from the repo" >&2; exit 2; }

_e2e_key_file() { printf '%s/%s' "$1" "$(printf '%s' "$2" | tr -c 'A-Za-z0-9_.-' '_')"; }

e2e_settings_save() {
  local dom=$1 dir=$2 key f p; shift 2
  mkdir -p "$dir" || return 1
  p=$(defaults export "$dom" - 2>/dev/null)
  for key in "$@"; do
    f=$(_e2e_key_file "$dir" "$key")
    # A save from before (a run cut short) is the state to go back to: kept.
    [[ -e $f.plist || -e $f.unset ]] && continue
    if plutil -extract "$key" xml1 -o "$f.plist" - <<<"$p" >/dev/null 2>&1; then :; else rm -f "$f.plist"; : > "$f.unset"; fi
    [[ -e $f.plist || -e $f.unset ]] || { echo "e2e_settings_save: could not write $f" >&2; return 1; }
  done
}

e2e_settings_restore() {
  local dom=$1 dir=$2 key f rc=0; shift 2
  for key in "$@"; do
    f=$(_e2e_key_file "$dir" "$key")
    if [[ -f $f.plist ]]; then
      defaults write "$dom" "$key" "$(cat "$f.plist")" && rm -f "$f.plist" || rc=1
    elif [[ -f $f.unset ]]; then
      defaults delete "$dom" "$key" >/dev/null 2>&1; rm -f "$f.unset"
    else
      echo "e2e_settings_restore: nothing saved for $key in $dir: $dom $key left as it is" >&2; rc=1
    fi
  done
  return $rc
}

e2e_vms_root() {
  local dom=$1 r
  r=$(defaults read "$dom" vmsRoot 2>/dev/null); r=${r%/}
  [[ -n $r ]] || { echo "e2e: $dom has no VMs folder setting (vmsRoot): set it to the test VMs' folder first" >&2; return 1; }
  if app_prod_dir "$r"; then
    echo "e2e: $dom's VMs folder $r is a folder of the installed OmacVM: never for tests" >&2; return 1
  fi
  echo "$r"
}

e2e_vm_guard() {
  local dom=$1 name=$2 r d n
  r=$(e2e_vms_root "$dom") || return 1
  d=$r/$name
  [[ -f $d/vm.env ]] || { echo "e2e: no test VM \"$name\" in $r: not started" >&2; return 1; }
  n=$(sed -n "s/^NAME=//p" "$d/vm.env" | head -1); n=${n#\'}; n=${n%\'}
  [[ $n == "$name" ]] || { echo "e2e: $d/vm.env names \"$n\", not \"$name\": not started" >&2; return 1; }
  app_prod_dir "$d" && { echo "e2e: $d is a VM of the installed OmacVM: not started" >&2; return 1; }
  echo "$d"
}

# A clone's SSH host key. omacvm remembers each VM's host key under its name
# when OmacVM sets the VM up (lib/vm.sh vm_pin); only a VM with one counts as
# set up from this Mac (`omacvm vms` "setup"), and the Bridge refuses the
# control centre of one without it (409 "did not set this VM up"). An APFS
# clone has the disk, and so the host keys, of the VM it was cloned from:
#   e2e_clone_pin FROM NAME   NAME gets FROM's remembered key (FROM without one:
#                             NAME has none either; a key an earlier VM of that
#                             name left would not match this disk)
#   e2e_pin_drop NAME         NAME's remembered key removed (the clone is gone)
# Always the test identity's keys (OMACVM_TEST_IDENTITY=1), never the person's.
# 2026-10-26: the update pass's clone of a base made by the release before got
# no Update VM (same version) and so no key: its first look failed 409.
_e2e_pin() {
  (export OMACVM_TEST_IDENTITY=1; source "$_E2E_LIB/mac.sh" >/dev/null 2>&1; source "$_E2E_LIB/vm.sh" >/dev/null 2>&1
   vm_pin "$1" app; [[ $OMA_PIN == "$HOME/Library/Application Support/omacvm-test/known_hosts/"* ]] && echo "$OMA_PIN")
}
e2e_clone_pin() {
  local from to
  from=$(_e2e_pin "$1") && to=$(_e2e_pin "$2") || { echo "e2e: no test identity key file for $1 or $2" >&2; return 1; }
  rm -f "$to"
  [[ -s $from ]] || return 0
  cp -p "$from" "$to"
}
e2e_pin_drop() {
  local p
  p=$(_e2e_pin "$1") || return 1
  rm -f "$p"
}
