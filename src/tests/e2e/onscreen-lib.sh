#!/bin/bash
# The checks of src/tests/e2e/onscreen.sh that need no Mac screen, VM or app:
# CI runs them with made-up values (src/tests/e2e-onscreen.sh). Source it.
# (Whether someone is at the Mac: person.sh, src/tests/e2e-person.sh.)
#   os_window_problems "X Y W H" "SX SY SW SH"
#                                         what is wrong with the app's window on its display's visible
#                                         frame (points, top left): 800 wide, 500-800 tall, centred;
#                                         nothing printed when it is right
#   os_same_size "X Y W H" "X Y W H"      exit 0 when both are as wide and as tall (within 1 pt)
#   os_cursor_hidden "visible=V empty=E at X,Y"
#                                         exit 0 when the Mac shows no cursor: hidden, or an empty image
#   os_usb_ask_problems "ASK-KEYS WORDS" RC SPACE_BEFORE SPACE_AFTER
#                                         what is wrong with the USB question's first second (the tool's
#                                         ask-keys line and exit code; the Space before the plug-in and
#                                         after): nothing printed when it is right
#   os_usb_keep_json DATE                 usb.json with the made-up test device (1209:0001) remembered as
#                                         Keep on Mac (USBMemory's file, version 1)
#   os_leftovers APP VMDIR VMNAME         reads "PID ARGS" lines (ps -axww -o pid=,args=) and prints
#                                         those of the run: QEMU of VMNAME, anything run from APP
#                                         (not its Helpers: Bridge and Gestures stay), anything on VMDIR
#   os_result_json SUMMARY KIND JSON KEY=VALUE...
#                                         result.json from summary.tsv (time, row, ok|FAIL|BLOCKED|VOID|
#                                         needs-user|skip|info|warn, what): pass = no FAIL, BLOCKED, VOID
#                                         or needs-user, at least one ok. VOID: the row ran but proves
#                                         nothing (present_verdict says why); a release owes it
# For present-locked.sh (the real present on a locked Mac):
#   present_verdict LOG size=WxH guest=WxH locked=1|0 awake=1|0 [damage=1|0]
#                                         the tiles check from that run's qemu.log lines: "ok|FAIL|VOID<TAB>why".
#                                         FAIL: a check differed (a "tiles check N:" line with pixels that
#                                         differ, or N > 0 in any "N of M checks differed"). ok needs the
#                                         check on, the session locked the whole row, a frame in tiles,
#                                         M >= PRESENT_MIN_CHECKS (20), the guest at the size asked (#637
#                                         shows only past 4352 pixels) and the virtual display awake at the
#                                         end. Else VOID, with the first reason; damage=0 (the VM's damage
#                                         does not reach QEMU: no OmacVM damage driver, every frame whole)
#                                         is named when no frame went in tiles
#   e2e_present_guard                     exit 2 when the environment asks for a hidden start
#                                         (OMACVM_COCOA_HIDDEN) with the tiles check
#                                         (OMACVM_GL_PRESENT_TILES=check): a hidden window stops presenting
#                                         after its first frames, so no tile is checked (3.2.15's gate row
#                                         said ok on 0 checks). Hidden starts stay fine for other rows
OS_WIDTH=800 OS_MIN_H=500 OS_MAX_H=800
PRESENT_MIN_CHECKS=20

# Rounded to whole points (AX gives fractions after a resize).
_os_int() { printf '%.0f' "$1"; }

os_window_problems() {
  local x y w h sx sy sw sh dx dy
  read -r x y w h <<<"$1"; read -r sx sy sw sh <<<"$2"
  x=$(_os_int "$x"); y=$(_os_int "$y"); w=$(_os_int "$w"); h=$(_os_int "$h")
  sx=$(_os_int "$sx"); sy=$(_os_int "$sy"); sw=$(_os_int "$sw"); sh=$(_os_int "$sh")
  (( w >= OS_WIDTH - 1 && w <= OS_WIDTH + 1 )) || echo "${w} pt wide, not ${OS_WIDTH}"
  (( h <= OS_MAX_H + 1 )) || echo "${h} pt tall, more than ${OS_MAX_H}"
  (( h >= OS_MIN_H - 1 )) || echo "${h} pt tall, less than ${OS_MIN_H}"
  # Centred on the visible frame: both middles within 2 pt.
  dx=$(( (2 * x + w) - (2 * sx + sw) )); dy=$(( (2 * y + h) - (2 * sy + sh) ))
  (( dx >= -4 && dx <= 4 )) || echo "not centred across: middle $(( x + w / 2 )), the display's $(( sx + sw / 2 ))"
  (( dy >= -4 && dy <= 4 )) || echo "not centred up and down: middle $(( y + h / 2 )), the display's $(( sy + sh / 2 ))"
  (( x >= sx && y >= sy && x + w <= sx + sw && y + h <= sy + sh )) || echo "not inside the display's visible frame"
  return 0
}

os_same_size() {
  local a b w1 h1 w2 h2
  read -r _ _ a b <<<"$1"; w1=$(_os_int "$a"); h1=$(_os_int "$b")
  read -r _ _ a b <<<"$2"; w2=$(_os_int "$a"); h2=$(_os_int "$b")
  (( w1 - w2 <= 1 && w2 - w1 <= 1 && h1 - h2 <= 1 && h2 - h1 <= 1 ))
}

os_cursor_hidden() {
  [[ $1 == visible=0* || $1 == *" empty=1 "* ]]
}

os_usb_ask_problems() {
  local r=$1 rc=$2 sp0=$3 sp=$4
  [[ $r == *"question=none"* ]] && { echo "no question in 5 s"; return 0; }
  [[ $rc == 3 ]] && echo "the question was not in front (no key sent after that)"
  [[ $r == *" early=stays "* ]] || echo "Return or Escape answered it within 0.5 s"
  [[ $r == *" late=answered@"* ]] || echo "Return after 0.5 s did not answer it"
  if [[ $r =~ " alert="([0-9]+)"@layer"([0-9]+) ]]; then
    (( BASH_REMATCH[1] >= 1 && BASH_REMATCH[2] >= 3 )) || echo "no floating question window on screen"
  else echo "no floating question window on screen"; fi
  [[ $r =~ " vm="([0-9]+) ]] && (( BASH_REMATCH[1] >= 1 )) || echo "the VM's window was not on screen with it"
  [[ -n $sp0 && $sp0 != 0 && $sp == "$sp0" && $r == *" space=$sp0 "* ]] || echo "the Space changed or was not read ($sp0, $sp)"
}

os_usb_keep_json() {
  printf '{"devices":[{"choice":"mac","maker":"OmacVM tests","name":"OmacVM Test Device","product":"0001","serial":"","since":"%s","vendor":"1209"}],"version":1}\n' "$1"
}

os_leftovers() {
  local app=$1 vmd=$2 vm=$3
  awk -v app="$app/" -v helpers="$app/Contents/Helpers/" -v vmd="$vmd" -v q=" -name $vm" -v me="$$" '
    # S in A, followed by the end, a space or a slash (so "M-e2e" is not "M-e2e2")
    function has(a, s,   i, c) {
      while ((i = index(a, s)) > 0) {
        c = substr(a, i + length(s), 1)
        if (c == "" || c == " " || c == "/") return 1
        a = substr(a, i + 1)
      }
      return 0
    }
    { pid = $1; a = $0; sub(/^ *[0-9]+ +/, "", a) }
    pid == me { next }
    has(a, q) { print; next }
    index(a, app) == 1 && index(a, helpers) != 1 { print; next }
    has(a, vmd) && a !~ /^(\/usr\/bin\/|\/bin\/)?(ps|awk|grep|pgrep|tail|cat|less) / { print; next }'
}

os_result_json() {
  local summary=$1 kind=$2 json=$3; shift 3
  /usr/bin/python3 - "$summary" "$kind" "$json" "$@" <<'PY'
import json, sys
summary, kind, out, extra = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
rows, counts = [], {}
for line in open(summary, encoding="utf-8", errors="replace"):
    f = line.rstrip("\n").split("\t")
    if len(f) < 4:
        continue
    rows.append({"time": f[0], "row": f[1], "result": f[2], "what": f[3]})
    counts[f[2]] = counts.get(f[2], 0) + 1
o = {"kind": kind, "counts": counts, "rows": rows,
     "pass": counts.get("ok", 0) > 0 and not any(counts.get(k) for k in ("FAIL", "BLOCKED", "VOID", "needs-user"))}
for kv in extra:
    k, _, v = kv.partition("=")
    o[k] = int(v) if v.isdigit() else v
json.dump(o, open(out, "w"), indent=1)
print("pass" if o["pass"] else "NOT passed", counts)
PY
}

present_verdict() {
  local log=$1 kv size="" guest="" locked="" awake="" damage="" a on first bad what m tiles whole sofar nb lt lw off
  shift
  for kv in "$@"; do
    case $kv in size=*) size=${kv#*=} ;; guest=*) guest=${kv#*=} ;; locked=*) locked=${kv#*=} ;;
      awake=*) awake=${kv#*=} ;; damage=*) damage=${kv#*=} ;; esac
  done
  # on first bad M tiles whole sofar <TAB> the first differing line <TAB> the tiles-off line
  a=$(LC_ALL=C awk '
    /tiled present: on, checked against whole frames/ { on++ }
    /tiled present: off/ && off == "" { off = $0; sub(/.*tiled present: /, "", off) }
    /tiled present: first frame in tiles/ { first++ }
    /tiles check [0-9]+: .* pixels differ \([0-9]+ of [0-9]+ checks differed\)/ {
      s = $0; sub(/.*tiles check [0-9]+: /, "", s); split(s, f, " ")
      p = f[3] + 0; t = s; sub(/.*\(/, "", t); split(t, g, " ")
      if (g[3] + 0 > m) m = g[3] + 0
      if (g[1] + 0 > nb) nb = g[1] + 0
      if ((p > 0 || g[1] + 0 > 0) && !bad) { bad = 1; w = $0; sub(/.*tiles check/, "tiles check", w) }
    }
    /tiles check, so far: [0-9]+ of [0-9]+ checks differed/ {
      s = $0; sub(/.*so far: /, "", s); split(s, g, " "); sofar++
      if (g[3] + 0 > m) m = g[3] + 0
      if (g[1] + 0 > 0 && !bad) { bad = 1; w = $0; sub(/.*tiles check/, "tiles check", w) }
      if (g[1] + 0 > nb) nb = g[1] + 0
    }
    /tiled present, last minute: [0-9]+ frames in tiles, [0-9]+ whole/ {
      s = $0; sub(/.*last minute: /, "", s); split(s, f, " "); tiles += f[1]; whole += f[5]; lt = f[1]; lw = f[5]
    }
    END { printf "%d %d %d %d %d %d %d %d %d %d\t%s\t%s\n", on, first, bad, m, tiles, whole, sofar, nb, lt, lw, w, off }' "$log" 2>/dev/null)
  read -r on first bad m tiles whole sofar nb lt lw <<<"${a%%$'\t'*}"
  what=${a#*$'\t'}; off=${what#*$'\t'}; what=${what%%$'\t'*}
  : "${on:=0}" "${first:=0}" "${bad:=0}" "${m:=0}" "${tiles:=0}" "${whole:=0}" "${nb:=0}"
  if (( bad )); then
    printf 'FAIL\t%s of %s checks differed (first: %s)\n' "$nb" "$m" "$what"; return 0
  fi
  if (( on == 0 )); then
    printf 'VOID\tthe tiles check was not on (no "tiled present: on, checked against whole frames" line%s)\n' "${off:+; tiled present: $off}"; return 0
  fi
  [[ $locked == 1 ]] || { printf 'VOID\tthe row did not run locked to its end\n'; return 0; }
  if (( first == 0 && tiles == 0 )); then
    printf 'VOID\tno frame went in tiles%s%s\n' "$( (( whole > 0 )) && echo " ($whole whole frames in the minute lines)")" \
      "$( [[ $damage == 0 ]] && echo ": the VM sends no damage (without OmacVM's damage driver every frame is whole)")"; return 0
  fi
  (( m > 0 )) || { printf 'VOID\t0 checks ran\n'; return 0; }
  (( m >= PRESENT_MIN_CHECKS )) || { printf 'VOID\tonly %s checks ran (want at least %s)\n' "$m" "$PRESENT_MIN_CHECKS"; return 0; }
  [[ -n $size && $guest == "$size" ]] || { printf 'VOID\tthe guest ran at %s, not at the size asked, %s\n' "${guest:-an unknown size}" "${size:-none}"; return 0; }
  [[ $awake == 1 ]] || { printf 'VOID\tthe virtual display was not awake at the end\n'; return 0; }
  printf 'ok\t0 of %s checks differed; the last minute line: %s frames in tiles, %s whole (%s minute lines)\n' "$m" "${lt:-0}" "${lw:-0}" "${sofar:-0}"
}

e2e_present_guard() {
  local h=${OMACVM_COCOA_HIDDEN:-}
  [[ -n $h && $h != 0 && ${OMACVM_GL_PRESENT_TILES:-} == check ]] || return 0
  echo "e2e: OMACVM_COCOA_HIDDEN with OMACVM_GL_PRESENT_TILES=check: a hidden window stops presenting after its first frames, so no tile would be checked (present rows order the window in on a virtual display: present-locked.sh)" >&2
  return 2
}
