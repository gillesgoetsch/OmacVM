#!/bin/bash
# confirm.sh (ON the mini, nohup): waits for the mini lock like poll.sh, then the fix with QEMU's part 115 ms,
# twice (VM restarted in between), watchdog 35 min, releases on exit.
cd /private/tmp/omacvm-avs; exec >> confirm.log 2>&1
WF=~/.omacvm-mini-vm.lock.wait; LK=~/.omacvm-mini-vm.lock
echo "$(date +%T) confirm wait pid $$"
for _ in $(seq 720); do
  grep -q '^av-sync ' "$WF" 2>/dev/null || { echo "$(date +%T) my wait line is gone: stop"; exit 0; }
  if [ ! -d "$LK" ] && [ "$(grep -v '^[[:space:]]*$' "$WF" | head -1 | cut -d' ' -f1)" = av-sync ]; then
    if mkdir "$LK" 2>/dev/null; then
      echo "av-sync $(date '+%F %T') fix re-measure (QEMU part 115), pid $$, one VM (M-avs), until ~$(date -v+35M +%H:%M)" > "$LK/owner"
      grep -v '^av-sync ' "$WF" > "$WF.tmp.$$"; cat "$WF.tmp.$$" > "$WF"; rm -f "$WF.tmp.$$"
      echo "$(date +%T) took the lock"
      release() { ./vm.sh stop; grep -q '^av-sync ' "$LK/owner" 2>/dev/null && rm -rf "$LK"; echo "$(date +%T) released"; }
      trap release EXIT
      ( sleep 2100; echo "$(date +%T) watchdog"; kill $$ ) &
      for t in a b; do
        grep -qE '^(release|fs-own-space)' "$WF" 2>/dev/null && { echo "release lane waits: stop"; exit 0; }
        QPART=115 CAL=0 TAG=115$t ./fix.sh
      done
      echo "$(date +%T) confirm done"; exit 0
    fi
  fi
  sleep 30
done
