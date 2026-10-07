#!/bin/bash
# The control centre opened from the Mac (src/control/guest/open.sh), offline:
# a made-up Hyprland (hyprctl, setpriv, id ... as stand-ins on the PATH) for the
# cases the Mac's two routes report: not set up, the control centre off,
# nobody logged in (also with a folder an earlier login left), opened with
# Omarchy 4's Lua dispatcher or the classic exec, behind the lock screen, and
# no window coming.
#   src/tests/cc-open.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
OPEN=$R/src/control/guest/open.sh
command -v jq >/dev/null || { echo "cc-open: needs jq"; exit 1; }
W=$(mktemp -d /tmp/cc-open.XXXXXX)   # short: Unix socket paths have a limit
trap 'rm -rf "$W"' EXIT
S=$W/state; B=$W/bin; mkdir -p "$S" "$B" "$W/run/1000/hypr"
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

stub() { printf '#!/bin/bash\n%s\n' "$2" > "$B/$1"; chmod +x "$B/$1"; }
stub setpriv 'while [[ $1 == --* ]]; do shift; done; exec "$@"'   # setpriv --reuid=.. CMD...
stub timeout 'shift; exec "$@"'
stub sleep ':'
stub id '[[ $1 == -[ug] && $2 == zorro ]] && echo 1000'
stub getent 'echo "zorro:x:1000:1000:Zorro:/home/zorro:/bin/bash"'
stub pgrep "[[ -e $S/locked ]]"
# hyprctl: alive only for the session named in $S/live; a window comes when
# the dispatch is taken and $S/opens is there.
stub hyprctl "S=$S"'
[[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} && $HYPRLAND_INSTANCE_SIGNATURE == "$(cat "$S/live" 2>/dev/null)" ]] || exit 1
echo "$HYPRLAND_INSTANCE_SIGNATURE" > "$S/used"
case $1 in
  version) echo "Hyprland 0.52" ;;
  dispatch)
    if [[ $2 == hl.dsp.exec_cmd* ]]; then
      [[ -e $S/lua ]] || { echo "invalid dispatcher"; exit 0; }
      printf "%s\n" "$2" > "$S/dispatched"
    elif [[ $2 == exec ]]; then printf "exec %s\n" "$3" > "$S/dispatched"
    else echo "invalid dispatcher"; exit 0; fi
    echo ok
    if [[ -e $S/opens ]]; then touch "$S/window"; [[ -e $S/locked ]] || echo org.omarchy.omacvm > "$S/active"; fi ;;
  clients) [[ -e $S/window ]] && echo "[{\"class\":\"org.omarchy.omacvm\",\"address\":\"0xa1\"}]" || echo "[]" ;;
  activewindow) echo "{\"class\":\"$(cat "$S/active" 2>/dev/null)\"}" ;;
esac'
sock() { python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"; }

env_file() {   # USER CONTROL_CENTRE
  { [[ -z $1 ]] || echo "OMACVM_USER=$1"; echo "OMACVM_FEATURE_control_centre=$2"; } > "$W/env"
}
run() {   # -> OUT, RC
  OUT=$(PATH="$B:$PATH" OMACVM_OPEN_ENV=$W/env OMACVM_OPEN_RUN=$W/run "$OPEN" 2>&1); RC=$?
}
expect() {   # NAME RC TEXT
  if [[ $RC == "$2" && $OUT == *"$3"* ]]; then ok "$1: exit $RC, \"$OUT\""
  else bad "$1: exit $RC, \"$OUT\" (wanted exit $2 and \"$3\")"; fi
}
reset() { rm -f "$S"/*; }

env_file "" on; run; expect "not set up" 1 "omacvm apply"
env_file zorro off; run; expect "control centre off" 5 "omacvm enable control-centre"
env_file zorro on; run; expect "nobody logged in (no session folder)" 3 "log in"

# An earlier login's folder (newer, its socket dead) and the live session.
mkdir -p "$W/run/1000/hypr/live1"; sock "$W/run/1000/hypr/live1/.socket.sock"
sleep 1
mkdir -p "$W/run/1000/hypr/stale2"; sock "$W/run/1000/hypr/stale2/.socket.sock"
run; expect "nobody logged in (a stale session only)" 3 "log in"

reset; echo live1 > "$S/live"; touch "$S/lua" "$S/opens"
run; expect "opened (Lua dispatcher)" 0 "open"
[[ $(cat "$S/used" 2>/dev/null) == live1 ]] && ok "the live session, not the newer stale one" || bad "session used: $(cat "$S/used" 2>/dev/null)"
want='hl.dsp.exec_cmd("omarchy-launch-or-focus-tui omacvm --window")'
[[ $(cat "$S/dispatched" 2>/dev/null) == "$want" ]] && ok "dispatched: $want" || bad "dispatched: $(cat "$S/dispatched" 2>/dev/null)"

reset; echo live1 > "$S/live"; touch "$S/opens"
run; expect "opened (classic exec)" 0 "open"
[[ $(cat "$S/dispatched" 2>/dev/null) == "exec omarchy-launch-or-focus-tui omacvm --window" ]] && ok "classic exec" || bad "dispatched: $(cat "$S/dispatched" 2>/dev/null)"

reset; echo live1 > "$S/live"; touch "$S/lua" "$S/opens" "$S/locked"
run; expect "behind the lock screen" 0 "unlock"

reset; echo live1 > "$S/live"; touch "$S/lua"
run; expect "no window comes" 1 "no window"

echo "live1" > "$S/live"; rm -f "$S/lua"; stub hyprctl "[[ \$1 == version ]] && exit 0; echo 'no such dispatcher'"
run; expect "dispatch refused" 1 "did not take the request"

(( fail )) && { echo "cc-open: FAILED"; exit 1; }
echo "cc-open: all passed"
