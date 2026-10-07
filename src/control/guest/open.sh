#!/bin/bash
# Opens the control centre on the VM's desktop, as the Omarchy menu does: one
# window (omarchy-launch-or-focus-tui), brought to the front when it is open
# already. The Mac runs it as root: OmacVM.app's "Features…" (through the
# guest agent) and `omacvm features --vm NAME --in-vm` (SSH). Hyprland starts
# the window (hyprctl dispatch), so it lives in the desktop session like one
# opened from the menu, not under the guest agent or SSH.
#   control/guest/open.sh
# One line on stdout says what happened. Exit codes: 0 open and in front
# (or behind the lock screen: the line says so), 1 failed, 3 nobody is
# logged in to the desktop, 5 the control centre is off in this VM.
set -uo pipefail
ENV=${OMACVM_OPEN_ENV:-/etc/omacvm/env}   # tests: another env file
RUNS=${OMACVM_OPEN_RUN:-/run/user}        # tests: another runtime folder
APP_ID=org.omarchy.omacvm
CMD="omarchy-launch-or-focus-tui omacvm --window"

U=$(sed -n 's/^OMACVM_USER=//p' "$ENV" 2>/dev/null | tail -1)
if [[ -z $U ]] || ! uid=$(id -u "$U" 2>/dev/null) || ! gid=$(id -g "$U" 2>/dev/null); then
  echo "OmacVM is not set up in this VM (on the Mac: omacvm apply)"
  exit 1
fi
if [[ $(sed -n 's/^OMACVM_FEATURE_control_centre=//p' "$ENV" | tail -1) != on ]]; then
  echo "the control centre is off in this VM (on the Mac: omacvm enable control-centre)"
  exit 5
fi
H=$(getent passwd "$U" | cut -d: -f6)
RUN=$RUNS/$uid
sig=""
# hyprctl ARGS... as the desktop user, in the session $sig. setpriv, not
# sudo: no PAM session and no journal lines for each of these calls.
hypr() {
  setpriv --reuid="$uid" --regid="$gid" --init-groups \
    env HOME="$H" XDG_RUNTIME_DIR="$RUN" HYPRLAND_INSTANCE_SIGNATURE="$sig" timeout 3 hyprctl "$@" 2>/dev/null
}

# The desktop session: the newest Hyprland of this user that answers (a
# folder of an earlier login can stay behind).
for d in $(ls -t "$RUN/hypr" 2>/dev/null); do
  [[ -S $RUN/hypr/$d/.socket.sock ]] || continue
  sig=$d
  hypr version >/dev/null && break
  sig=""
done
if [[ -z $sig ]]; then
  echo "nobody is logged in to the VM's desktop: log in there first"
  exit 3
fi

window() {   # the control centre's window: "ADDRESS" or nothing
  hypr clients -j | jq -r --arg c "$APP_ID" 'first(.[] | select(.class == $c) | .address) // empty' 2>/dev/null
}
in_front() { [[ $(hypr activewindow -j | jq -r '.class // empty' 2>/dev/null) == "$APP_ID" ]]; }

# Omarchy 4 takes Lua dispatchers; older Hyprland the classic exec.
out=$(hypr dispatch "hl.dsp.exec_cmd(\"$CMD\")")
if [[ $out != ok ]]; then
  out=$(hypr dispatch exec "$CMD")
  [[ $out == ok ]] || { echo "the desktop did not take the request (hyprctl dispatch: ${out:-no answer})"; exit 1; }
fi
# Its window: within 5 s (a cold start of the terminal and Textual takes ~1 s).
for _ in $(seq 25); do
  if [[ -n $(window) ]]; then
    if in_front; then echo "open"; exit 0; fi
    if pgrep -u "$U" -x hyprlock >/dev/null 2>&1; then
      echo "open, behind the VM's lock screen: unlock it to see it"
      exit 0
    fi
  fi
  sleep 0.2
done
if [[ -n $(window) ]]; then
  echo "open, but another window stays in front"
  exit 0
fi
echo "asked the desktop to open it, but no window came within 5 s"
exit 1
