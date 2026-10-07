#!/bin/bash
# Put OmacVM onto a running OmacVM.app VM: `omacvm apply` from the copy of
# OmacVM inside the app (the Mac side its features need, the Bridge token,
# the VM side), with the VM's features (its features file; before the first
# apply, vm.env's FEATURES).
#   apply-vm.sh VM_DIR [--no-mac | --image] [--reset-host-key]
# --image: a VM for a prebuilt image (src/prebuilt/make-image.sh app): nothing
# of this Mac, not even the Bridge token.
# --reset-host-key: the VM was rebuilt or reinstalled: forget its old SSH key.
set -euo pipefail
VM_DIR=${1:?usage: apply-vm.sh VM_DIR [--no-mac | --image] [--reset-host-key]}
shift
extra=()
for a in "$@"; do
  case $a in
    --no-mac|--reset-host-key) extra+=("$a") ;;
    --image) extra+=(--no-mac --no-token --no-tools) ;;
    *) echo "apply-vm.sh: unknown option $a (--no-mac, --image, --reset-host-key)" >&2; exit 2 ;;
  esac
done
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vm-common.sh"
vm_load "$VM_DIR"
vssh true < /dev/null 2>/dev/null || die "the VM is not running (or has no SSH yet)"

# A copy of src/ only: the Mac installers build next to their sources, never
# inside the app (or the source tree).
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/omacvm"
cp -R "$OMACVM_SRC" "$tmp/omacvm/src"
# The app's signed Mac helpers (Contents/Helpers): installed instead of
# building them, when made from these sources (src/lib/helpers.sh).
if [[ -d $HERE/../../Helpers ]]; then
  OMACVM_HELPERS=$(cd "$HERE/../../Helpers" && pwd)
  export OMACVM_HELPERS
fi
# The app's complete omacvm (Contents/Resources/omacvm): what the Bridge runs
# for the control centre's Mac jobs when there is no checkout (apply.sh).
if [[ -x $HERE/../omacvm/omacvm ]]; then
  OMACVM_APP_CLI=$(cd "$HERE/../omacvm" && pwd)/omacvm
  export OMACVM_APP_CLI
fi
# This app's runtime: whether it has KosmicKrisp decides Graphics' Automatic
# (src/lib/graphics.sh).
for rt in "$HERE/../runtime/.build/qemu-gpu-runtime" "$HERE/../runtime"; do   # a dev tree, the app
  [[ -d $rt/lib ]] && { OMACVM_APP_RUNTIME=$(cd "$rt" && pwd); export OMACVM_APP_RUNTIME; break; }
done
args=(--vm "$NAME" --vm-type app --ip "127.0.0.1:$SSH_PORT" --user "$VM_USER" --keyboard "$KEYBOARD")
# The VM's features: its record (the features file) once the first apply wrote
# it, else the setup's choice (vm.env FEATURES). The fast network is the
# app's own switch (its fast-network file), which apply reads itself.
feats=${FEATURES:-}
[[ -s $VM_DIR/features ]] && feats=$(cat "$VM_DIR/features")
for f in $feats; do
  [[ $f == fast-network=* ]] || args+=(--feature "$f")
done
# A changed SSH host key: say how to forget it the app's way.
OMA_RESET_HINT="bash '$HERE/apply-vm.sh' '$VM_DIR' --reset-host-key"
export OMA_RESET_HINT
"$tmp/omacvm/src/cmd/apply.sh" "${args[@]}" ${extra[@]+"${extra[@]}"}
