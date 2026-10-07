#!/bin/bash
# poll.sh (ON the mini, nohup): waits until the mini VM lock is free and av-sync is first in the wait file,
# takes the lock, runs hold.sh (self-cleaning, 45-min watchdog). Gives up after 8 h or when its wait line is gone.
cd /private/tmp/omacvm-avs; exec >> poll.log 2>&1
WF=~/.omacvm-mini-vm.lock.wait; LK=~/.omacvm-mini-vm.lock
echo "$(date +%T) poll start pid $$"
for _ in $(seq 960); do
  grep -q '^av-sync ' "$WF" 2>/dev/null || { echo "$(date +%T) my wait line is gone: stop"; exit 0; }
  if [ ! -d "$LK" ] && [ "$(grep -v '^[[:space:]]*$' "$WF" | head -1 | cut -d' ' -f1)" = av-sync ]; then
    if mkdir "$LK" 2>/dev/null; then
      echo "av-sync $(date '+%F %T') A/V offset matrix, pid $$, one VM (M-avs), until ~$(date -v+60M +%H:%M)" > "$LK/owner"
      grep -v '^av-sync ' "$WF" > "$WF.tmp.$$"; cat "$WF.tmp.$$" > "$WF"; rm -f "$WF.tmp.$$"
      echo "$(date +%T) took the lock"; ./hold.sh; echo "$(date +%T) hold.sh ended"; exit 0
    fi
  fi
  sleep 30
done
echo "$(date +%T) poll timeout"
