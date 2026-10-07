#!/bin/bash
# OmacVM.app's self-update, the part that runs while the app is closed
# (docs/adr/0033). The app starts it from a copy outside its bundle:
#   update-swap.sh install  APP NEW HOME PID TOKEN [--work DIR] [--quiet]   NEW in place of APP; APP kept as the previous version
#   update-swap.sh rollback APP -   HOME PID TOKEN [--work DIR]             the previous version back in place of APP
# HOME is this copy's update folder (result, launch markers). DIR (default
# HOME) holds previous/ and incoming/ and must lie on APP's volume: every
# move here is a rename, never a copy across disks. With --quiet the new
# app only checks that it starts and opens no window, and nothing is
# opened after a failure either (the user had quit).
# It waits for the app (PID) to quit and never swaps while a process runs
# from APP (a VM's QEMU). Then it starts the swapped-in app with
# --update-check TOKEN; that app writes HOME/launch-TOKEN ("ok" once its
# QEMU starts). No "ok" within 90 s: the app that was there before goes
# back. HOME/result tells the app that runs next what happened.
set -uo pipefail
MODE=${1:-} APP=${2:-} NEW=${3:-} HOME_DIR=${4:-} OLD_PID=${5:-} TOKEN=${6:-}
shift 6 2>/dev/null || set --
WORK_DIR=$HOME_DIR QUIET=0
while (( $# )); do
  case $1 in
    --work) WORK_DIR=${2:-}; shift 2 2>/dev/null || shift ;;
    --quiet) QUIET=1; shift ;;
    *) MODE=bad; break ;;
  esac
done
[[ $MODE == install || $MODE == rollback ]] && [[ $APP == /*.app && -d $APP && -d $HOME_DIR && $WORK_DIR == /* ]] &&
  [[ $OLD_PID =~ ^[0-9]+$ && $TOKEN =~ ^[0-9a-f]{32}$ ]] ||
  { echo "usage: update-swap.sh install|rollback APP NEW|- HOME PID TOKEN [--work DIR] [--quiet]" >&2; exit 2; }
BASE=$(basename "$APP")
PREV=$WORK_DIR/previous/$BASE
INCOMING=$WORK_DIR/incoming/$BASE
FAILED=$WORK_DIR/failed
MARKER=$HOME_DIR/launch-$TOKEN
# 90 s: a first launch can be slow (XProtect scans the new bundle, an 8 GB
# Mac under memory pressure); a false rollback skips a good version.
WAIT=${OMACVM_UPDATE_WAIT:-90}
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

log() { printf '%s swap: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
result() { printf '%s\n' "$*" > "$HOME_DIR/result"; log "result: $*"; }
version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || echo unknown; }
# Processes started from inside the bundle (its QEMU, the launcher).
running_from() { ps -axww -o pid=,args= | grep -F -- "$1/Contents/" | grep -v -e grep -e update-swap.sh | awk '{ print $1 }'; }

# The test hooks travel with a test build across the restart; a release
# build (org.omacvm.app) ignores them, so they are not passed on to it.
HOOKS=(OMACVM_COCOA_HIDDEN)
APP_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null)
[[ -z $APP_ID || $APP_ID == org.omacvm.app ]] || HOOKS+=(OMACVM_APPCAST_URL OMACVM_APPCAST_KEY OMACVM_SETTINGS_DIR)
OPEN_ENV=()
for v in "${HOOKS[@]}"; do
  [[ -n ${!v:-} ]] && OPEN_ENV+=(--env "$v=${!v}")
done
# Quiet: in the background (-g), not brought to the front.
OPEN=(open -n)
(( QUIET )) && OPEN+=(-g)
launch() { "${OPEN[@]}" ${OPEN_ENV[@]+"${OPEN_ENV[@]}"} "$APP" --args "$@"; }
# After a failure: the app that is there, unless the user had quit.
reopen() { (( QUIET )) || launch; }

# Nothing swapped: say why and open the app that is there.
abort() {
  [[ $MODE == rollback && -d $INCOMING && ! -e $PREV ]] && mkdir -p "$WORK_DIR/previous" && mv "$INCOMING" "$PREV"
  result "aborted $*"
  reopen
  exit 1
}

# The volume a path lies on.
volume() { stat -f %d "$1" 2>/dev/null; }

log "$MODE $APP (now $(version "$APP"))"
for ((i = 0; i < 600; i++)); do kill -0 "$OLD_PID" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$OLD_PID" 2>/dev/null; then
  result "aborted the app did not quit"
  exit 1
fi
# A VM that was just stopped (forced off) can take a few seconds to go
# with its helper processes: wait up to 10 s.
for ((i = 0; i < 20; i++)); do [[ -z $(running_from "$APP") ]] && break; sleep 0.5; done
if [[ -n $(running_from "$APP") ]]; then
  log "still running from $BASE: $(ps -o pid=,comm= -p "$(running_from "$APP" | paste -sd, -)" | tr '\n' ' ')"
  abort "a VM runs from $BASE: the update waits until it is shut down"
fi
# Renames only: the work folder (and the new app in it) on APP's volume.
mkdir -p "$WORK_DIR" || abort "could not make $WORK_DIR"
[[ -n $(volume "$WORK_DIR") && $(volume "$WORK_DIR") == "$(volume "$(dirname "$APP")")" ]] ||
  abort "$WORK_DIR is on another disk than $BASE: nothing moved"

if [[ $MODE == rollback ]]; then
  [[ -d $PREV ]] || abort "there is no previous version"
  rm -rf "$WORK_DIR/incoming"; mkdir -p "$WORK_DIR/incoming"
  mv "$PREV" "$INCOMING" || abort "could not take out the previous version"
  NEW=$INCOMING
fi
[[ -d $NEW ]] || abort "the new app is missing"
[[ $(volume "$NEW") == "$(volume "$(dirname "$APP")")" ]] || abort "the new app is on another disk than $BASE: nothing moved"
OLD_V=$(version "$APP") NEW_V=$(version "$NEW")

# Old aside, new in: renames on one volume, each checked. The version kept
# from before stays in previous.old until the new one has started.
rm -rf "$WORK_DIR/previous.old"
[[ ! -e $WORK_DIR/previous ]] || mv "$WORK_DIR/previous" "$WORK_DIR/previous.old" || abort "could not move the kept version aside"
keep_old() { rm -rf "$WORK_DIR/previous"; [[ ! -e $WORK_DIR/previous.old ]] || mv "$WORK_DIR/previous.old" "$WORK_DIR/previous"; }
mkdir -p "$WORK_DIR/previous"
if ! mv "$APP" "$PREV"; then keep_old; abort "could not move $BASE aside"; fi
# The check above and the moves are not one step: something started from
# APP just before the move now runs from PREV, and one started from the
# kept version (previous/, by its path) would be deleted with previous.old.
# Look again; on a hit, everything goes back where it was.
if [[ -n $(running_from "$APP") || -n $(running_from "$PREV") ]]; then
  mv "$PREV" "$APP" || log "the old app is at $PREV"
  keep_old
  abort "$BASE was started during the update: it waits until nothing runs from it"
fi
if ! mv "$NEW" "$APP"; then
  mv "$PREV" "$APP" || log "the old app is at $PREV"
  keep_old
  abort "could not put $NEW_V in place"
fi
"$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
log "swapped $OLD_V -> $NEW_V, starting it"

# The result goes first: the new app reads it right after its check, while
# this script may not have seen the marker yet. A failure overwrites it.
if [[ $MODE == install ]]; then result "installed $OLD_V $NEW_V"; else result "went-back $OLD_V"; fi
rm -f "$MARKER" "$HOME_DIR/restart-vm.taken"
why="no answer within ${WAIT} s"
CHECK=(--update-check "$TOKEN")
(( QUIET )) && CHECK+=(--update-quiet)
if launch "${CHECK[@]}"; then
  for ((i = 0; i < WAIT * 4; i++)); do
    [[ -s $MARKER ]] && break
    sleep 0.25
  done
  answer=$(head -1 "$MARKER" 2>/dev/null)
  rm -f "$MARKER"
  if [[ $answer == ok ]]; then
    log "$NEW_V started"
    rm -rf "$WORK_DIR/incoming" "$FAILED" "$WORK_DIR/previous.old"
    exit 0
  fi
  [[ -n $answer ]] && why=${answer#fail: }
else
  why="it did not open"
fi

# It did not start: stop what runs of it and put the old app back.
log "$NEW_V did not start ($why): putting $OLD_V back"
pids=$(running_from "$APP")
if [[ -n $pids ]]; then
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null; sleep 2
  pids=$(running_from "$APP")
  # shellcheck disable=SC2086
  [[ -z $pids ]] || kill -9 $pids 2>/dev/null
fi
rm -rf "$FAILED"; mkdir -p "$FAILED"
if ! mv "$APP" "$FAILED/$BASE" || ! mv "$PREV" "$APP"; then
  result "rolled-back $NEW_V $why; putting $OLD_V back failed too: it is at $PREV"
  exit 1
fi
"$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
keep_old
rm -rf "$FAILED" "$WORK_DIR/incoming"
# An update with a VM restart: the new app may have taken the VM to start
# before it was stopped (its copy restart-vm.taken, from this launch: the
# old one was removed before it). The old app starts the VM instead.
[[ -f $HOME_DIR/restart-vm.taken && ! -e $HOME_DIR/restart-vm ]] && mv "$HOME_DIR/restart-vm.taken" "$HOME_DIR/restart-vm"
result "rolled-back $NEW_V $why"
reopen
exit 1
