#!/bin/bash
# Is someone at this Mac? For the e2e harnesses (cc-switches.sh,
# modifier-keys.sh, display-unplug.sh, onscreen.sh) and the release kits that
# run them: they ask between rows, not only at the start, wait while someone
# is there and go on once the Mac is quiet again. Source it (bash 3.2).
#
# Someone is there when:
#   - a remote session is open: macOS Screen Sharing (screensharingd's "Remote
#     user is connected", screensharingd or ScreensharingAgent running, an
#     established connection on port 5900, which Apple Remote Desktop uses too)
#     or Jump Desktop (its rtcproxy / desktopproxy). Also a session left alone:
#     a remote viewer may be watching the screen without touching it.
#   - HID input that was not ours came in the last PERSON_IDLE_MIN seconds
#     (default 300). Our own events (CGEventPostToPid, HID moves and clicks)
#     reset HIDIdleTime too, so a harness stamps them with person_posted.
# person_watch_start samples in the background (every PERSON_TICK s, default 2)
# and writes each foreign input and each change of the remote sessions with its
# time to $PERSON_DIR/watch.log, so a visit between two rows is seen as well.
# A harness started by another one (modifier-keys.sh by cc-switches.sh) uses
# the caller's watcher through the exported PERSON_DIR.
#
#   person_remote             the open remote sessions, a comma list ("" for none)
#   person_hid_idle           seconds since the last HID input
#   person_posted [SECONDS]   our own input now, and for SECONDS more (default 2)
#   person_verdict IDLE REMOTE OWN FOREIGN NOW
#                             why the Mac is not quiet ("" when it is): OWN = our
#                             own input until (epoch s, 0 never), FOREIGN = the
#                             watcher's last foreign input (epoch s, 0 none)
#   person_check              the verdict now
#   person_locked             exit 0 while the session is locked (the console's screen lock in
#                             the IORegistry); present-locked.sh runs only then
#   person_watch_start, person_watch_stop
#   person_gate ROW           between two rows: what the watcher saw since the last
#                             gate goes to person_overlap (a hook, if the harness
#                             defines it); while someone is there it waits (at most
#                             PERSON_WAIT s, default 1800, a look every PERSON_POLL
#                             s, default 10); exit 0 quiet, 1 gave up (PERSON_WHY
#                             says why)
# OMACVM_E2E_IGNORE_IDLE=1: never someone (working on a harness at the Mac).

PERSON_IDLE_MIN=${PERSON_IDLE_MIN:-300}
PERSON_WAIT=${PERSON_WAIT:-1800}
PERSON_POLL=${PERSON_POLL:-10}
PERSON_TICK=${PERSON_TICK:-2}
# Shared with onscreen.sh's runs before (its LASTF): our last own input, epoch s.
PERSON_OWN=${PERSON_OWN:-$HOME/Library/Caches/omacvm-e2e-last-input}
PERSON_WHY=""

# The sources (tests replace these functions with made-up ones).
_person_pmset() { pmset -g assertions 2>/dev/null; }
# One line per process: its executable (comm), a tab, its command line (args).
_person_ps() {
  local c a
  c=$(ps -axww -o pid=,comm= 2>/dev/null); a=$(ps -axww -o pid=,args= 2>/dev/null)
  awk 'NR == FNR { p = $1; sub(/^ *[0-9]+ /, ""); comm[p] = $0; next }
       { p = $1; sub(/^ *[0-9]+ /, ""); if (p in comm) print comm[p] "\t" $0 }' <(echo "$c") <(echo "$a")
}
# TCP connections with their state, CSV ("time,tcp4 A.5900<->B.port,iface,Established,..."): netstat
# shows no TCP sockets on macOS 27, lsof only this user's (screensharingd's are root's); nettop shows all.
_person_tcp() { nettop -m tcp -l 1 -L 1 -n 2>/dev/null; }
_person_idle_raw() { ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print int($NF / 1000000000); exit}'; }
_person_now() { date +%s; }
_person_lock_raw() { ioreg -n Root -d1 -k IOConsoleUsers 2>/dev/null; }

person_remote() {
  local r="" a ps
  # No `pmset | grep -q` under pipefail (SIGPIPE): count instead.
  a=$(_person_pmset | grep -c 'screensharingd.*Remote user is connected')
  (( a > 0 )) && r+="screen-sharing,"
  # By the executable, never by words in a command line (a script that greps for them would count).
  ps=$(_person_ps)
  a=$(echo "$ps" | awk -F'\t' '{ n = $1; sub(/.*\//, "", n) } n == "screensharingd" || n == "ScreensharingAgent" { c++ } END { print c + 0 }')
  (( a > 0 )) && [[ $r != *screen-sharing,* ]] && r+="screen-sharing,"
  a=$(_person_tcp | awk -F, '$2 ~ /[.:]5900<->/ && $4 == "Established" { c++ } END { print c + 0 }')
  (( a > 0 )) && r+="vnc-5900,"
  a=$(echo "$ps" | awk -F'\t' '{ n = $1; sub(/.*\//, "", n) }
    n == "rtcproxy" || n == "desktopproxy" || ($1 ~ /Jump/ && $2 ~ /(rtcproxy|desktopproxy)/) { c++ } END { print c + 0 }')
  (( a > 0 )) && r+="jump-desktop,"
  echo "${r%,}"
}

person_hid_idle() { local i; i=$(_person_idle_raw); echo "${i:-0}"; }

# No `ioreg | grep -q`: grep ends ioreg early, and under pipefail its SIGPIPE always made it No.
person_locked() { [[ $(_person_lock_raw) == *'"CGSSessionScreenIsLocked"=Yes'* ]]; }

person_posted() {   # [SECONDS]: our input from now until SECONDS from now
  local until=$(( $(_person_now) + ${1:-2} )) old
  old=$(cat "$PERSON_OWN" 2>/dev/null)
  [[ $old =~ ^[0-9]+$ ]] && (( old > until )) && return 0
  mkdir -p "$(dirname "$PERSON_OWN")" 2>/dev/null
  echo "$until" > "$PERSON_OWN" 2>/dev/null
  return 0
}
_person_own() { local o; o=$(cat "$PERSON_OWN" 2>/dev/null); [[ $o =~ ^[0-9]+$ ]] && echo "$o" || echo 0; }

person_verdict() {   # IDLE REMOTE OWN FOREIGN NOW
  local idle=$1 remote=$2 own=$3 foreign=$4 now=$5 last
  [[ ${OMACVM_E2E_IGNORE_IDLE:-0} == 1 ]] && return 0
  [[ -n $remote ]] && { echo "remote session: $remote"; return 0; }
  # The watcher saw input that was not ours not long ago (it may have been
  # followed by ours, which hides it from HIDIdleTime).
  (( foreign > 0 && now - foreign < PERSON_IDLE_MIN )) && { echo "input at $(_person_hm "$foreign"), not ours"; return 0; }
  (( idle >= PERSON_IDLE_MIN )) && return 0
  last=$(( now - idle ))
  # The last input was ours (2 s slack: whole seconds on both sides).
  (( own > 0 && last <= own + 2 )) && return 0
  echo "input ${idle} s ago, not ours"
}
_person_hm() { date -r "$1" +%H:%M:%S 2>/dev/null || echo "$1"; }

# The watcher's last foreign input (epoch s), 0 for none.
_person_foreign() {
  [[ -n ${PERSON_DIR:-} && -s $PERSON_DIR/watch.log ]] || { echo 0; return; }
  awk -F'\t' '$2 == "input" { t = $1 } END { print t + 0 }' "$PERSON_DIR/watch.log"
}

person_check() {
  local now; now=$(_person_now)
  person_verdict "$(person_hid_idle)" "$(person_remote)" "$(_person_own)" "$(_person_foreign)" "$now"
}

# The watcher: one line per event, "EPOCH<TAB>input|remote<TAB>what".
_person_watch_loop() {
  local prev_last=-1 idle now last own logged=0 r prev_r=${PERSON_R0:-} n=0
  # Ends with the harness that started it ($$ in this subshell is the harness), or its folder.
  while kill -0 $$ 2>/dev/null && [[ -d $PERSON_DIR ]]; do
    now=$(_person_now); idle=$(person_hid_idle); last=$(( now - idle ))
    if (( prev_last >= 0 && last > prev_last + 1 )); then
      own=$(_person_own)
      # Ours when it came before our stamp's end (2 s slack); one line per 10 s of input.
      if (( last > own + 2 && last > logged + 10 )); then
        printf '%s\tinput\tHID input at %s (HID idle %s s), not ours (ours until %s)\n' "$last" "$(_person_hm "$last")" "$idle" \
          "$( (( own > 0 )) && _person_hm "$own" || echo never)" >> "$PERSON_DIR/watch.log"
        logged=$last
      fi
    fi
    prev_last=$last
    # The remote sessions every third tick (ps and nettop cost more than ioreg: ~0.1 s against 0.03).
    if (( n % 3 == 0 )); then
      r=$(person_remote)
      [[ $r != "$prev_r" ]] && printf '%s\tremote\t%s\n' "$now" "${r:-none}" >> "$PERSON_DIR/watch.log"
      prev_r=$r
    fi
    n=$(( n + 1 ))
    sleep "$PERSON_TICK"
  done
}

PERSON_WATCHER=""
person_watch_start() {
  # A caller's watcher (exported PERSON_DIR, its pid alive): use that one.
  if [[ -n ${PERSON_DIR:-} && -n ${PERSON_WATCH_PID:-} ]] && kill -0 "$PERSON_WATCH_PID" 2>/dev/null; then return 0; fi
  PERSON_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-person.XXXXXX") || return 1
  : > "$PERSON_DIR/watch.log"; echo 0 > "$PERSON_DIR/seen"
  # Sessions open at the start are the harness's own start check's business: lines only for changes.
  PERSON_R0=$(person_remote)
  _person_watch_loop </dev/null >/dev/null 2>&1 &
  PERSON_WATCHER=$!; PERSON_WATCH_PID=$PERSON_WATCHER
  export PERSON_DIR PERSON_WATCH_PID
}
person_watch_stop() {   # only the watcher this shell started
  [[ -n $PERSON_WATCHER ]] || return 0
  kill "$PERSON_WATCHER" 2>/dev/null; wait "$PERSON_WATCHER" 2>/dev/null
  PERSON_WATCHER=""
  [[ -n ${PERSON_KEEP_LOG:-} && -s $PERSON_DIR/watch.log ]] && cp "$PERSON_DIR/watch.log" "$PERSON_KEEP_LOG"
  rm -rf "$PERSON_DIR"; unset PERSON_DIR PERSON_WATCH_PID
}

# The watcher's lines since the last gate (of any harness sharing PERSON_DIR).
_person_new() {
  [[ -n ${PERSON_DIR:-} && -f $PERSON_DIR/watch.log ]] || return 0
  local seen size
  seen=$(cat "$PERSON_DIR/seen" 2>/dev/null); [[ $seen =~ ^[0-9]+$ ]] || seen=0
  size=$(wc -c < "$PERSON_DIR/watch.log" | tr -d ' ')
  (( size > seen )) || return 0
  tail -c +$(( seen + 1 )) "$PERSON_DIR/watch.log" | head -c $(( size - seen ))
  echo "$size" > "$PERSON_DIR/seen"
}
# What counts: a foreign input, or a remote session that is not "none".
_person_events() { awk -F'\t' '$2 == "input" || ($2 == "remote" && $3 != "none") { printf "%s%s", (n++ ? "; " : ""), $3 }'; }

person_gate() {   # ROW: the row about to run
  local row=${1:-next} ev why t0 now
  [[ ${OMACVM_E2E_IGNORE_IDLE:-0} == 1 ]] && return 0
  ev=$(_person_new | _person_events)
  [[ -n $ev ]] && declare -F person_overlap >/dev/null && person_overlap "$ev" "$row"
  why=$(person_check)
  [[ -z $why ]] && return 0
  t0=$(_person_now)
  echo "== $(date +%H:%M:%S) PAUSE before $row: $why (waiting up to $(( PERSON_WAIT / 60 )) min for a quiet Mac)"
  declare -F person_paused >/dev/null && person_paused "$why" "$row"
  while :; do
    now=$(_person_now)
    (( now - t0 >= PERSON_WAIT )) && break
    sleep "$PERSON_POLL"
    _person_new >/dev/null   # seen while waiting: not an overlap of the next row
    why=$(person_check)
    if [[ -z $why ]]; then
      echo "== $(date +%H:%M:%S) RESUME before $row after $(( $(_person_now) - t0 )) s"
      declare -F person_resumed >/dev/null && person_resumed "$(( $(_person_now) - t0 ))" "$row"
      return 0
    fi
  done
  PERSON_WHY="someone at the Mac since $(_person_hm "$t0") ($why), waited $(( PERSON_WAIT / 60 )) min"
  echo "== $(date +%H:%M:%S) GIVE UP before $row: $PERSON_WHY"
  return 1
}

# For a person_overlap hook: the rows of SUMMARY after line FROM, as "ROWS<TAB>FAILED" (space lists).
person_span() {   # SUMMARY FROM NAMECOL RESULTCOL
  tail -n +$(( $2 + 1 )) "$1" 2>/dev/null | awk -F'\t' -v n="$3" -v r="$4" \
    '{ a = a (a != "" ? " " : "") $n; if ($r == "FAIL") f = f (f != "" ? " " : "") $n } END { printf "%s\t%s\n", a, f }'
}
# The row a harness adds for a visit: "RESULT<TAB>WHAT". A row that failed while someone was
# there says nothing about the product: BLOCKED (run it again); rows that passed stay passed.
person_overlap_row() {   # EVENTS ROWS FAILED
  if [[ -n $3 ]]; then printf 'BLOCKED\tFAIL rows %s ran while someone was at the Mac (%s): run them again on a quiet Mac\n' "$3" "$1"
  elif [[ -n $2 ]]; then printf 'skip\trows %s ran while someone was at the Mac (%s); they passed\n' "$2" "$1"
  else printf 'skip\tsomeone at the Mac between rows (%s)\n' "$1"; fi
}
