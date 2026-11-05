# The move of an OmacVM.app VM to Omarchy 4.5 (app/scripts/move-vm.sh, the
# app's "Move to Omarchy 4.5" card). While the VM folder's journal says the
# move is not over (running, failed or interrupted), apply and update leave
# the VM alone: the app's Resume or Undo comes first. The move's own apply
# runs with OMACVM_MOVE_RUN=1.

# move_open DIR: 0 when the folder's move is running, failed or interrupted.
move_open() {
  [[ -z ${OMACVM_MOVE_RUN:-} && -f $1/move-4.5 ]] || return 1
  case $(sed -n 's/^state=//p' "$1/move-4.5" | head -1) in running|failed|interrupted) return 0 ;; esac
  return 1
}

move_open_text() { printf "'%s' is in the middle of its move to Omarchy 4.5: resume or undo it in OmacVM.app first" "$1"; }

# move_record LINE: the guest's `omarchy-move.sh record` answer as the VM
# folder's omarchy file takes it ("4.5.0 aarch64 stable", "none"); exit 1 for
# anything else (the guest is untrusted: one short line of plain words).
move_record() {
  local r
  r=$(printf '%s' "$1" | head -1 | LC_ALL=C sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g' | LC_ALL=C tr -cd 'A-Za-z0-9.+_ -' | cut -c1-80)
  [[ $r =~ ^(none|[0-9][A-Za-z0-9.+_-]*( [a-z0-9-]+)?( [a-z0-9-]+)?)$ ]] || return 1
  printf '%s\n' "$r"
}
