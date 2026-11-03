#!/bin/bash
# This Mac's self-hosted GitHub Actions runners, paused while an on-screen
# gate runs and started again after it. A CI job on the test Mac starts its own
# VMs and loads the Mac (the 3.2.4 gate: QEMU 100 ms late on a key, a job's VM
# in the way of an unplug test).
#   src/tests/e2e/ci-runners.sh pause [--wait SECONDS] [--holder PID]
#   src/tests/e2e/ci-runners.sh resume [--holder PID]
#   src/tests/e2e/ci-runners.sh status
# pause: each runner (a LaunchAgent actions.runner.*.plist in
#   ~/Library/LaunchAgents) is stopped with `launchctl bootout` as soon as it
#   runs no job (no Runner.Worker in its folder); a job that runs is never cut
#   off. Jobs queued meanwhile wait on GitHub. Waits at most --wait seconds
#   (default 3000) for running jobs to end. Exit 0: no runner runs; 4: some
#   still had a job at the end (the ones stopped stay stopped until resume).
# resume: the runners a pause stopped are started again (`launchctl
#   bootstrap`), once no other holder of the pause is alive.
# The holder (default: the calling process) keeps the pause: two gates that
# overlap both pause, and the runners come back after the last one. What is
# stopped is written down in ~/.omacvm-ci-paused (CI_STATE). Call resume from
# the gate's EXIT trap. A gate that dies without it (kill -9, an ssh drop, a
# second Ctrl-C in its cleanup) is covered too: pause starts a guard per holder
# in its own session that runs the resume once the holder is gone (a look every
# CI_GUARD_TICK s, default 10; its log ~/.omacvm-ci-paused.log).
set -uo pipefail
AGENTS=${CI_AGENTS:-$HOME/Library/LaunchAgents}
STATE=${CI_STATE:-$HOME/.omacvm-ci-paused}
GLOG=$STATE.log
TICK=${CI_GUARD_TICK:-10}
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
DOMAIN=gui/$(id -u)
cmd=${1:-}; shift || true
WAIT=3000; HOLDER=$PPID
while (( $# )); do
  case $1 in
    --wait) WAIT=$2; shift 2 ;;
    --holder) HOLDER=$2; shift 2 ;;
    *) cmd=usage; break ;;
  esac
done
log() { echo "ci-runners: $(date +%H:%M:%S) $*"; }

runners() {   # LABEL<TAB>PLIST<TAB>FOLDER per runner
  local p l d
  for p in "$AGENTS"/actions.runner.*.plist; do
    [[ -f $p ]] || continue
    l=$(plutil -extract Label raw -o - "$p" 2>/dev/null) || continue
    d=$(plutil -extract WorkingDirectory raw -o - "$p" 2>/dev/null) || d=""
    printf '%s\t%s\t%s\n' "$l" "$p" "$d"
  done
}
loaded() { launchctl print "$DOMAIN/$1" >/dev/null 2>&1; }
# A runner that updated itself runs its Worker from bin.<version>/ (2.338.2 on 2026-11-03), not bin/.
busy() { [[ -n $1 ]] && LC_ALL=C pgrep -f "$1/bin(\.[0-9.]+)?/Runner\.Worker" >/dev/null 2>&1; }
stopped() { cat "$STATE/stopped" 2>/dev/null; }
# A holder is its pid and its start time (a pid used again by another process is not the holder).
started() { ps -o lstart= -p "$1" 2>/dev/null; }
holder_alive() {   # PID: its file says when it started
  kill -0 "$1" 2>/dev/null || return 1
  local s; s=$(cat "$STATE/holder.$1" 2>/dev/null)
  [[ -z $s || $s == "$(started "$1")" ]]
}
alive_holders() {   # holders whose process still runs (others are dropped)
  local h n=0
  for h in "$STATE"/holder.*; do
    [[ -e $h ]] || continue
    if holder_alive "${h##*.}"; then n=$((n + 1)); else rm -f "$h"; fi
  done
  echo $n
}
# One change of the pause state at a time (a guard's resume and another gate's pause can meet).
lock_state() {
  local i o
  for ((i = 0; i < 600; i++)); do
    if mkdir "$STATE.lock" 2>/dev/null; then echo $$ > "$STATE.lock/pid"; return 0; fi
    o=$(cat "$STATE.lock/pid" 2>/dev/null)
    # Its owner died: take it over.
    [[ -n $o ]] && ! kill -0 "$o" 2>/dev/null && rm -rf "$STATE.lock"
    sleep 0.1
  done
  log "$STATE.lock held for 60 s: going on without it"
}
unlock_state() { [[ $(cat "$STATE.lock/pid" 2>/dev/null) == "$$" ]] && rm -rf "$STATE.lock"; return 0; }
# The holder's guard, in its own session so a hangup or a kill of the gate's group does not reach it.
start_guard() {
  local g; g=$(cat "$STATE/guard.$HOLDER" 2>/dev/null)
  [[ -n $g ]] && kill -0 "$g" 2>/dev/null && return 0
  /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "exec: $!"' /bin/bash "$SELF" guard --holder "$HOLDER" \
    < /dev/null >> "$GLOG" 2>&1 &
  echo $! > "$STATE/guard.$HOLDER"
}

case $cmd in
  pause)
    [[ $WAIT =~ ^[0-9]+$ && $HOLDER =~ ^[0-9]+$ ]] || { echo "ci-runners: --wait SECONDS, --holder PID" >&2; exit 2; }
    kill -0 "$HOLDER" 2>/dev/null || { echo "ci-runners: holder $HOLDER does not run" >&2; exit 2; }
    lock_state
    mkdir -p "$STATE"; started "$HOLDER" > "$STATE/holder.$HOLDER"; touch "$STATE/stopped"
    start_guard
    unlock_state
    t0=$(date +%s)
    while :; do
      # The holder gone (killed): its guard resumes; this pause waits for nothing more.
      [[ -e $STATE/holder.$HOLDER ]] && holder_alive "$HOLDER" || { log "holder $HOLDER gone: pause ends"; exit 4; }
      left=0
      while IFS=$'\t' read -r l p d; do
        loaded "$l" || continue
        if busy "$d"; then left=$((left + 1)); continue; fi
        lock_state
        # The holder gone (its guard may have resumed already): stop nothing more.
        if [[ ! -e $STATE/holder.$HOLDER ]] || ! holder_alive "$HOLDER"; then
          unlock_state; log "holder $HOLDER gone: no more runners stopped"; exit 4
        fi
        # Written down before it goes: a resume finds it even if this gate dies right here.
        grep -qxF "$l	$p" "$STATE/stopped" || printf '%s\t%s\n' "$l" "$p" >> "$STATE/stopped"
        launchctl bootout "$DOMAIN/$l" 2>/dev/null
        # bootout returns while launchd still tears the service down: until it is gone (<= 15 s).
        for ((i = 0; i < 15; i++)); do loaded "$l" || break; sleep 1; done
        unlock_state
        if ! loaded "$l"; then log "$l stopped (no job)"
        else log "$l: still loaded after bootout"; left=$((left + 1)); fi
      done < <(runners)
      (( left == 0 )) && { log "no runner runs (paused for $HOLDER)"; exit 0; }
      (( $(date +%s) - t0 >= WAIT )) && { log "$left runner(s) still on a job after $WAIT s"; exit 4; }
      sleep "${CI_POLL:-10}"
    done ;;
  resume)
    lock_state
    rm -f "$STATE/holder.$HOLDER"
    n=$(alive_holders)
    (( n > 0 )) && { unlock_state; log "still paused for $n other holder(s)"; exit 0; }
    rc=0
    while IFS=$'\t' read -r l p; do
      [[ -n $l ]] || continue
      if loaded "$l"; then log "$l runs already"
      elif launchctl bootstrap "$DOMAIN" "$p" 2>/dev/null; then log "$l started again"
      else log "$l: bootstrap failed ($p)"; rc=1; continue; fi
      grep -vxF "$l	$p" "$STATE/stopped" > "$STATE/stopped.new"; mv "$STATE/stopped.new" "$STATE/stopped"
    done < <(stopped)
    (( rc == 0 )) && rm -rf "$STATE"
    unlock_state
    exit $rc ;;
  guard)   # started by pause: waits while the holder runs and still holds the pause, then resumes for it
    trap '' INT TERM HUP PIPE
    while [[ -e $STATE/holder.$HOLDER ]] && holder_alive "$HOLDER"; do sleep "$TICK"; done
    [[ -e $STATE/holder.$HOLDER ]] || exit 0
    log "holder $HOLDER ended without a resume: resuming for it"
    exec /bin/bash "$SELF" resume --holder "$HOLDER" ;;
  status)
    while IFS=$'\t' read -r l p d; do
      printf '%s\t%s\t%s\n' "$l" "$(loaded "$l" && echo running || echo stopped)" "$(busy "$d" && echo job || echo idle)"
    done < <(runners)
    [[ -s $STATE/stopped ]] && echo "paused by: $(cd "$STATE" && ls holder.* 2>/dev/null | sed 's/holder\.//' | tr '\n' ' ')"
    exit 0 ;;
  *) sed -n '6,8s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
esac
