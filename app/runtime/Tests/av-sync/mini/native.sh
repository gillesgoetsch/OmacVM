#!/bin/bash
# native.sh LABEL SRC (ON the mini, no VM): the same clip in the Mac's own Google Chrome (own throwaway profile,
# kiosk), as the reference for what the capture chain itself shows for a correctly synced player.
set -u
W=/private/tmp/omacvm-avs; cd "$W"; mkdir -p out
L=$1; SRC=$2; DUR=${DUR:-60}
P=$W/avs-chrome-prof; rm -rf "$P"
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --user-data-dir="$P" --no-first-run --no-default-browser-check \
  --kiosk --autoplay-policy=no-user-gesture-required "file://$W/clip/av.html?src=$SRC" >/dev/null 2>&1 &
CP=$!
sleep 12
./avcap "$DUR" "out/$L.csv"
kill "$CP" 2>/dev/null; sleep 2; kill -9 "$CP" 2>/dev/null; rm -rf "$P"
python3 avsync.py "out/$L.csv" --json | python3 -c 'import json,sys; r=json.load(sys.stdin); r["label"]=sys.argv[1]; print(json.dumps(r))' "$L" | tee -a out/results.jsonl
