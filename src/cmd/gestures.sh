#!/bin/bash
# omacvm gestures: the Mac's gesture settings, for every route (OmacVM Gestures'
# own, the same as OmacVM.app's window and the control centre):
#   omacvm gestures                       what they are now
#   omacvm gestures escape pointer|all    ⌃⌥ Esc moves the focused monitor (the default) or
#                                         every monitor that shows the VM (all)
#   omacvm gestures swipe-out on|off      Swipe out to macOS: past the first or last workspace to the
#                                         macOS Space beside the VM (off by default)
#   omacvm gestures mouse-swipe 3|4       a Magic Mouse's two-finger swipe is this many fingers (4)
#   --json   the settings as JSON (after a change: "changed": true)
# Several at once: omacvm gestures escape all swipe-out on. They count from the next use.
# Exit codes: 0 done, 2 usage.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
# The test identity's Gestures has its own settings (OMACVM_GESTURES_DOMAIN: tests).
if [[ ${OMACVM_TEST_IDENTITY:-} == 1 ]]; then D=${OMACVM_GESTURES_DOMAIN:-org.omacvm.test.gestures}
else D=${OMACVM_GESTURES_DOMAIN:-org.omacvm.gestures}; fi
JSON=0; SETS=()
usage() { echo "omacvm gestures: $*" >&2; exit 2; }
while (( $# )); do
  case $1 in
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,13s/^# \{0,1\}//p' "$0"; exit 0 ;;
    escape) case ${2:-} in pointer|display|focused) SETS+=("escape=pointer") ;; all) SETS+=("escape=all") ;; *) usage "escape pointer|all" ;; esac; shift 2 ;;
    swipe-out) [[ ${2:-} == on || ${2:-} == off ]] || usage "swipe-out on|off"; SETS+=("swipe-out=$2"); shift 2 ;;
    mouse-swipe) [[ ${2:-} == 3 || ${2:-} == 4 ]] || usage "mouse-swipe 3|4"; SETS+=("mouse-swipe=$2"); shift 2 ;;
    *) usage "unknown option $1 (see --help)" ;;
  esac
done

# As Gestures reads them (escapeAll, swipeOutSetting, mouseFingersOf in omacvm-gestures.c).
escape_now() { local v; v=$(defaults read "$D" EscapeSwipe 2>/dev/null || true); [[ $(tr '[:upper:]' '[:lower:]' <<<"$v") == all ]] && echo all || echo pointer; }
swipe_out_now() { case $(defaults read "$D" SwipeOut 2>/dev/null | tr '[:upper:]' '[:lower:]') in 1|yes|true) echo on ;; *) echo off ;; esac; }
mouse_now() { [[ $(defaults read "$D" MouseSwipeFingers 2>/dev/null) == 3 ]] && echo 3 || echo 4; }

CHANGED=false
for s in ${SETS[@]+"${SETS[@]}"}; do
  case $s in
    escape=*) [[ $(escape_now) == "${s#*=}" ]] && continue
      [[ ${s#*=} == all ]] && defaults write "$D" EscapeSwipe all || defaults write "$D" EscapeSwipe pointer ;;
    swipe-out=*) [[ $(swipe_out_now) == "${s#*=}" ]] && continue
      [[ ${s#*=} == on ]] && defaults write "$D" SwipeOut -bool true || defaults write "$D" SwipeOut -bool false ;;
    mouse-swipe=*) [[ $(mouse_now) == "${s#*=}" ]] && continue
      defaults write "$D" MouseSwipeFingers -int "${s#*=}" ;;
  esac
  CHANGED=true
done

if (( JSON )); then
  printf '{"escape": "%s", "swipe_out": %s, "mouse_swipe": %s, "changed": %s}\n' \
    "$(escape_now)" "$([[ $(swipe_out_now) == on ]] && echo true || echo false)" "$(mouse_now)" "$CHANGED"
  exit 0
fi
echo "Escape combo (⌃⌥ Esc): $([[ $(escape_now) == all ]] && echo "all monitors" || echo "focused monitor")"
echo "Swipe out to macOS: $(swipe_out_now)"
echo "Magic Mouse swipe: $(mouse_now) fingers"
[[ $CHANGED == true ]] && echo "(from the next use)"
exit 0
