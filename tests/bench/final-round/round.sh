#!/bin/bash
# The whole final round in one command, on the quiet Mac, inside a time budget.
#   round.sh [--dir DIR] [--budget MINUTES] [--skip STEPS] [--only STEPS] [--no-wait-idle] [--dry-run]
#   round.sh --plan [--budget MINUTES]          the steps, their times and what the budget leaves out
#   round.sh --fullscreen TARGET [--keep]       start that Bench VM in full screen, check its width, stop it (no numbers)
#   round.sh --summary [--dir DIR]              table, chart.json, gpu.svg and gpu.png from what is there
#   round.sh --prepare-rc2                      before the round: the RC2's Bench VM (see below)
# Order: macOS, OmacVM 2.9.1, OmacVM 3.0.0 RC2 (the Vulkan rows), UTM, VMware
# Fusion, Parallels. Each system: its GPU tests 3 times (mac.sh / vm.sh), then
# idle power (idle-power.sh) when the preflight allows it; a refused idle row is
# left out with the reason. One VM at a time, in full screen on the built-in
# display, with the Mac's own wallpaper and no notifications; its app (and
# services) quit before the next.
#
# Resumable: run it again with the same --dir. Finished steps are skipped, a
# failed or refused one runs again, the budget's end stays the first run's
# (--budget sets a new one). Every step writes DIR/<step>.jsonl; a failed
# attempt's file moves to DIR/failed/. At the end: summarize.py -> DIR/table.md
# and DIR/chart.json, chart.py -> DIR/gpu.svg and DIR/gpu.png.
#
# Budget (default 180 min): the GPU steps come first. Idle windows get one
# length for every system, fixed at the start (10 min, down to 5 when the
# budget is short); when the round runs late, idle rows are dropped (noted),
# never shortened. RC2's OpenGL rows run only when there is time to spare.
#
# --prepare-rc2 (RC2_APP and RC2_SRC, the RC2's source tree, set): an APFS clone
# of "Bench OmacVM" as RC2_VM next to it, its Graphics setting on Vulkan, started
# hidden with the RC2 app, the RC2's Venus driver built in the guest (as
# `omacvm graphics vulkan` does), restarted, Vulkan checked, the new versions
# recorded (vm.sh --record), stopped. About 10 minutes.
#
# Env: APP_291 (the 2.9.1 app, default ~/Applications/OmacVM Bench 2.9.1.app),
# APP_VM ("Bench OmacVM"), APP_PORT (52224); RC2_APP (the 3.0.0 RC2 build;
# unset: the RC2 steps are skipped with a note), RC2_VM ("Bench OmacVM RC2",
# its Graphics setting on Vulkan), RC2_PORT, RC2_APP_ENV ("K=V ..." for the
# app's environment), RC2_LABEL (its name in the chart, default from its
# version + " · Vulkan"); UTM_VM, UTM_IP, FUSION_VMX, PARALLELS_VM; WALLPAPER (default:
# the Mac's current desktop picture); GEEKBENCH_SCORES (a {url: score} file;
# default: read from Geekbench's pages at the end, FETCH_GEEKBENCH=0 skips it). The steps' times: EST_<step> (minutes).
set -uo pipefail
FR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$FR/../../.." && pwd)
say() { printf '\033[1;32m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

DIR=~/bench/final-$(date +%Y%m%d) BUDGET="" SKIP="" ONLY="" WAIT_IDLE=1 DRY=0 MODE=round FS_TARGET="" KEEP=0
while [ $# -gt 0 ]; do
  case $1 in
    --dir) DIR=$2; shift 2 ;;
    --budget) BUDGET=$2; shift 2 ;;
    --skip) SKIP=$2; shift 2 ;;
    --only) ONLY=$2; shift 2 ;;
    --no-wait-idle) WAIT_IDLE=0; shift ;;
    --dry-run) DRY=1; shift ;;
    --plan) MODE=plan; shift ;;
    --summary) MODE=summary; shift ;;
    --fullscreen) MODE=fullscreen; FS_TARGET=${2:-}; shift 2 ;;
    --prepare-rc2) MODE=prepare-rc2; shift ;;
    --keep) KEEP=1; shift ;;
    *) sed -n '2,6p' "$0" >&2; exit 2 ;;
  esac
done

APP_291=${APP_291:-$HOME/Applications/OmacVM Bench 2.9.1.app}
APP_VM=${APP_VM:-Bench OmacVM} APP_PORT=${APP_PORT:-52224}
RC2_APP=${RC2_APP:-} RC2_LABEL=${RC2_LABEL:-} RC2_VM=${RC2_VM:-Bench OmacVM RC2} RC2_PORT=${RC2_PORT:-52225} RC2_APP_ENV=${RC2_APP_ENV:-}
UTM_VM=${UTM_VM:-Bench UTM} PARALLELS_VM=${PARALLELS_VM:-Bench Parallels}
FUSION_VMX=${FUSION_VMX:-$HOME/Virtual Machines.localized/Bench Fusion.vmwarevm/Bench Fusion.vmx}
UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl
VMRUN="/Applications/VMware Fusion.app/Contents/Public/vmrun"
FUSION_LEASES=/var/db/vmware/vmnet-dhcpd-vmnet8.leases
KEY=$HOME/.ssh/omacvm
LOCK=$HOME/.omacvm-bench.lock

# ---------- the steps ----------
# id  target  kind  minutes. kind: gpu (must), idle (budget allowing),
# extra (only with time to spare). up/down steps (start, stop) are not listed:
# they run around a target's pending steps.
# Times from the kit's runs: Basemark (3 runs) and glmark2 (3 runs of its 34
# scenes) are most of a VM's; the VMs without Vulkan pass vkpeak, Geekbench
# and vkmark in seconds.
STEPS="mac-gpu mac gpu 25
mac-idle mac idle 6
app-gpu app gpu 27
app-idle app idle 6
rc2-vulkan app-rc2 gpu 10
rc2-gl app-rc2 extra 12
utm-gpu utm gpu 27
utm-idle utm idle 6
fusion-gpu fusion gpu 27
fusion-idle fusion idle 6
parallels-gpu parallels gpu 27
parallels-idle parallels idle 6"
UP_MIN=3 DOWN_MIN=1 IDLE_MAX=600 IDLE_MIN=300 SETTLE=${FINAL_ROUND_SETTLE:-45}
# glmark2's scenes at 5 s instead of 10 (the same for every VM; the score is
# the mean fps, so it barely moves): 3 runs in 9 minutes, not 18.
export GLMARK2_DURATION=${GLMARK2_DURATION:-5}
est() {   # step -> minutes (EST_<step> overrides, "-" as "_")
  local v; v=$(eval echo "\${EST_$(echo "$1" | tr '-' '_'):-}")
  [ -n "$v" ] && { echo "$v"; return; }
  echo "$STEPS" | awk -v s="$1" '$1 == s { print $4 }'
}
field() { echo "$STEPS" | awk -v s="$1" -v f="$2" '$1 == s { print $f }'; }
listed() { case ,$1, in *,$2,*) return 0 ;; esac; return 1; }
wanted() {   # step: in --only (if given), not in --skip, RC2 only with an RC2 app
  [ -n "$ONLY" ] && ! listed "$ONLY" "$1" && ! listed "$ONLY" "$(field "$1" 2)" && return 1
  listed "$SKIP" "$1" || listed "$SKIP" "$(field "$1" 2)" && return 1
  case $1 in rc2-*) [ -n "$RC2_APP" ] || return 1 ;; esac
  return 0
}

STATE=$DIR/steps.state LOG=$DIR/round.log
[ "$MODE" = plan ] || { mkdir -p "$DIR/failed" && touch "$STATE"; } || die "cannot write $DIR"
log() { echo "$(date +%T) $*" | tee -a "$LOG" >&2; }
status() { awk -v s="$1" '$1 == s { v = $2 } END { print v }' "$STATE"; }
mark() { echo "$1 $2 $(date +%FT%T) ${3:-}" >> "$STATE"; }   # step status [why]
pending() { [ "$(status "$1")" != "done" ]; }

# The idle windows: one length for every system, from the budget at the start.
idle_seconds() {   # budget minutes -> seconds per idle window, 5 to 10 min
  local gpu=0 n=0 targets="" s t k
  while read -r s t k _; do
    wanted "$s" || continue
    case $k in gpu) gpu=$((gpu + $(est "$s"))) ;; idle) n=$((n + 1)) ;; esac
    case " $targets " in *" $t "*) ;; *) targets="$targets $t" ;; esac
  done <<<"$STEPS"
  local per=$(( ($1 - gpu - $(echo $targets | wc -w) * (UP_MIN + DOWN_MIN) - 5) * 60 / (n > 0 ? n : 1) - SETTLE - 30 ))
  [ $per -gt $IDLE_MAX ] && per=$IDLE_MAX
  [ $per -lt $IDLE_MIN ] && per=$IDLE_MIN
  echo $(( per / 60 * 60 ))
}

if [ "$MODE" = plan ]; then
  b=${BUDGET:-180}; i=$(idle_seconds "$b")
  echo "budget $b min; idle windows ${i}s each (+$((SETTLE + 30))s settle)"
  while read -r s t k m; do
    if wanted "$s"; then w=run; else w="not run"; fi
    [ "$k" = idle ] && m=$(( (i + SETTLE + 30 + 59) / 60 ))
    printf '  %-15s %-10s %-5s %3s min  %s\n' "$s" "$t" "$k" "$m" "$w"
  done <<<"$STEPS"
  tot=$(while read -r s t k m; do wanted "$s" || continue; [ "$k" = idle ] && m=$(( (i + SETTLE + 30 + 59) / 60 )); [ "$k" = extra ] || echo "$m"; done <<<"$STEPS" | awk '{ t += $1 } END { print t }')
  n=$(for t in app app-rc2 utm fusion parallels; do echo "$STEPS" | awk -v t="$t" '$2 == t { print $1 }' | while read -r s; do wanted "$s" && echo "$t"; done | head -1; done | grep -c .)
  echo "  + ${UP_MIN} min start and ${DOWN_MIN} min stop per VM ($n VMs); RC2 steps need RC2_APP"
  echo "  total about $(( tot + n * (UP_MIN + DOWN_MIN) )) min without the extra step; over the budget, the idle rows of the last systems are dropped first"

  exit 0
fi

# ---------- the Mac and its desktop ----------
hid_idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ { print int($NF / 1000000000); exit }'; }
displays() { system_profiler SPDisplaysDataType 2>/dev/null | grep -c 'Resolution:'; }
builtin_only() { [ "$(displays)" = 1 ] && system_profiler SPDisplaysDataType 2>/dev/null | grep -q 'Built-in'; }
picture() {   # the Mac's desktop picture (the round's wallpaper everywhere)
  [ -n "${WALLPAPER:-}" ] && { echo "$WALLPAPER"; return; }
  osascript -e 'tell application "System Events" to get picture of current desktop' 2>/dev/null
}
hide_apps() {   # the Mac's desktop for its idle row: every app hidden (not quit)
  osascript -e 'tell application "System Events" to set visible of every process whose visible is true and name is not "Finder" to false' >/dev/null 2>&1
}

# ---------- the VMs ----------
K=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
gsi() { local d=$1 p=22; shift; case $d in *:*) p=${d##*:}; d=${d%:*} ;; esac; ssh "${K[@]}" -p "$p" "root@$d" "$@"; }   # stdin passed on
gs() { gsi "$@" </dev/null; }
# The guest's monitor widths (Hyprland, as the desktop user).
widths() { gs "$1" 'U=$(id -nu 1000); sig=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
  sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 HYPRLAND_INSTANCE_SIGNATURE=$sig hyprctl monitors -j 2>/dev/null |
  python3 -c "import json,sys; print(\" \".join(str(m[\"width\"]) for m in json.load(sys.stdin)))"' 2>/dev/null; }
wide() { local w x; w=$(widths "$1"); [ -n "$w" ] || return 1; for x in $w; do [ "$x" -ge 3000 ] || return 1; done; }
wait_desktop() {   # host [seconds]: SSH and the user's Hyprland session
  local i n=$(( ${2:-300} / 5 ))
  for ((i = 0; i < n; i++)); do gs "$1" 'ls /run/user/1000/hypr' >/dev/null 2>&1 && return 0; sleep 5; done
  return 1
}
fusion_ip() {
  local mac; mac=$(sed -n 's/^ethernet0\.generatedAddress = "\(.*\)"$/\1/p; s/^ethernet0\.address = "\(.*\)"$/\1/p' "$FUSION_VMX" | head -1 | tr 'A-F' 'a-f')
  awk -v m="$mac" '$1 == "lease" { ip = $2 } $1 == "hardware" && tolower($3) == m ";" { last = ip } END { print last }' "$FUSION_LEASES" 2>/dev/null
}
# The VM app's process (System Events' name) for the View menu, and its name.
proc_of() { case $1 in app|app-rc2) echo OmacVM ;; utm) echo UTM ;; fusion) echo "VMware Fusion" ;; parallels) echo "Parallels Desktop" ;; esac; }
name_of() { case $1 in app) echo "$APP_VM" ;; app-rc2) echo "$RC2_VM" ;; utm) echo "$UTM_VM" ;; fusion) echo "Bench Fusion" ;; parallels) echo "$PARALLELS_VM" ;; esac; }
app_of() { case $1 in app) echo "$APP_291" ;; app-rc2) echo "$RC2_APP" ;; esac; }
menu_fullscreen() {   # process: View > Enter Full Screen (no keys or clicks injected: a menu action)
  osascript -e "tell application \"System Events\" to tell process \"$1\" to set frontmost to true" -e 'delay 1' \
    -e "tell application \"System Events\" to tell process \"$1\" to click (first menu item of menu \"View\" of menu bar 1 whose name contains \"Full Screen\" and name does not contain \"Use\" and name does not contain \"Exit\")" >/dev/null 2>&1
}
# Running VMs that are not Bench VMs (the user's): the round stops rather than touch them.
foreign_vms() {
  { prlctl list 2>/dev/null | awk 'NR > 1 { $1 = $2 = $3 = ""; print }'
    [ -x "$UTMCTL" ] && pgrep -x UTM >/dev/null && "$UTMCTL" list 2>/dev/null | awk '$2 == "started" { $1 = $2 = ""; print }'
    "$VMRUN" list 2>/dev/null | grep '\.vmx$' | sed 's|.*/||; s|\.vmx$||'
    ps -axww -o args= | grep -E '(qemu-system-aarch64|/runtime/bin/OmacVM|/MacOS/OmacVM-VM) .*-name ' | grep -v grep | sed 's/.* -name \(.*\) -machine.*/\1/'
  } | sed 's/^ *//' | grep -v '^Bench ' | grep . | paste -sd, - | sed 's/,/, /g'
}
HOST=""
vm_up() {   # target: start it in full screen, wait for its desktop, check the width; sets HOST
  local t=$1 name app i e envs=()
  name=$(name_of "$t") HOST=""
  [ -e "$HOME/.omacvm-user-testing" ] && { log "$t: the user is testing (~/.omacvm-user-testing): no VM starts"; return 1; }
  case $t in
    app|app-rc2)
      app=$(app_of "$t"); [ -d "$app" ] || { log "$t: no app at $app"; return 1; }
      [ "$t" = app-rc2 ] && for e in $RC2_APP_ENV; do envs+=(--env "$e"); done
      # A private pasteboard: the Bench VM never reaches the Mac's clipboard (STANDARDS 25).
      # -startFullScreen YES: full screen for this start only (the argument domain; the app's settings stay).
      open -n --env OMACVM_TEST_PASTEBOARD=org.omacvm.bench-test ${envs[@]+"${envs[@]}"} "$app" --args --start --vm "$name" -startFullScreen YES || return 1
      HOST=127.0.0.1:$([ "$t" = app ] && echo "$APP_PORT" || echo "$RC2_PORT") ;;
    utm)
      open -a UTM; sleep 5
      "$UTMCTL" start "$name" >/dev/null 2>&1 || { log "utm: utmctl start failed"; return 1; }
      for ((i = 0; i < 60; i++)); do HOST=$("$UTMCTL" ip-address "$name" 2>/dev/null | grep -E '^[0-9]+\.' | head -1); [ -n "$HOST" ] && break; sleep 5; done
      [ -n "$HOST" ] || HOST=${UTM_IP:-} ;;
    fusion)
      open -a "VMware Fusion"; sleep 5
      "$VMRUN" -T fusion start "$FUSION_VMX" gui >/dev/null 2>&1 || { log "fusion: vmrun start failed"; return 1; }
      for ((i = 0; i < 60; i++)); do HOST=$(fusion_ip); [ -n "$HOST" ] && gs "$HOST" true 2>/dev/null && break; sleep 5; done ;;
    parallels)
      prlctl set "$name" --startup-view fullscreen >/dev/null 2>&1
      open -a "Parallels Desktop"; sleep 5
      prlctl start "$name" >/dev/null 2>&1 || { log "parallels: prlctl start failed"; return 1; }
      for ((i = 0; i < 60; i++)); do HOST=$(prlctl list -f -o name,ip 2>/dev/null | awk -v n="$name" 'index($0, n) == 1 { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9.]+$/) { print $i; exit } }'); [ -n "$HOST" ] && break; sleep 5; done ;;
  esac
  [ -n "$HOST" ] || { log "$t: no address"; return 1; }
  wait_desktop "$HOST" 300 || { log "$t: no desktop session at $HOST"; return 1; }
  sleep 15
  for ((i = 0; i < 4; i++)); do
    wide "$HOST" && break
    log "$t: guest $(widths "$HOST") px wide, not full screen yet: View > Full Screen"
    menu_fullscreen "$(proc_of "$t")"
    sleep 20
  done
  wide "$HOST" || { log "$t: not full screen on the built-in display ($(widths "$HOST") px)"; return 1; }
  # The quiet desktop: the Mac's wallpaper (same image), no notifications, no Chrome.
  bash "$FR/vm.sh" "$t" --vm "$name" "root@$HOST" --desktop "$PIC" >> "$LOG" 2>&1 || log "$t: desktop not prepared (see $LOG)"
  # What the guest shows, small, as the record of full screen and wallpaper.
  gs "$HOST" 'U=$(id -nu 1000); sig=$(ls -t /run/user/1000/hypr | head -1); sleep 2
    sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=$sig grim -s 0.2 -' > "$DIR/screen-$t.png" 2>/dev/null
  log "$t: up at $HOST, guest $(widths "$HOST") px wide (screen-$t.png)"
}
vm_down() {   # target: shut the VM down, quit its app and services
  local t=$1 name i app
  name=$(name_of "$t")
  case $t in
    app|app-rc2)
      app=$(app_of "$t")
      [ -n "$HOST" ] && gs "$HOST" 'systemctl poweroff' >/dev/null 2>&1
      for ((i = 0; i < 24; i++)); do pgrep -f -- "-name $name -" >/dev/null || break; sleep 5; done
      [ -n "$app" ] && pkill -f "$app/Contents/MacOS/" 2>/dev/null ;;
    utm)
      "$UTMCTL" stop "$name" >/dev/null 2>&1; sleep 10
      osascript -e 'quit app "UTM"' >/dev/null 2>&1; sleep 5 ;;
    fusion)
      [ -n "$HOST" ] && gs "$HOST" 'systemctl poweroff' >/dev/null 2>&1
      for ((i = 0; i < 12; i++)); do "$VMRUN" list 2>/dev/null | grep -qF "$FUSION_VMX" || break; sleep 5; done
      "$VMRUN" list 2>/dev/null | grep -qF "$FUSION_VMX" && "$VMRUN" -T fusion stop "$FUSION_VMX" hard >/dev/null 2>&1
      osascript -e 'quit app "VMware Fusion"' >/dev/null 2>&1; sleep 5 ;;
    parallels)
      prlctl stop "$name" >/dev/null 2>&1
      prlctl set "$name" --startup-view window >/dev/null 2>&1
      osascript -e 'quit app "Parallels Desktop"' >/dev/null 2>&1; sleep 5 ;;
  esac
  quiet_services
  HOST=""
}
# Parallels' service and UTM's helper outlive their apps; the preflight counts them.
quiet_services() {
  pkill -u "$USER" -x prl_client_app 2>/dev/null
  pkill -u "$USER" -f 'Parallels Desktop.app/Contents/MacOS/launchd_user_wrapper' 2>/dev/null
  pgrep -x UTM >/dev/null || pkill -u "$USER" -f 'UTM.app/Contents/XPCServices/' 2>/dev/null
  sleep 3
}

# ---------- one step ----------
run_step() {   # step
  local s=$1 t k out rc why
  t=$(field "$s" 2) k=$(field "$s" 3) out=$DIR/$s.jsonl
  [ -f "$out" ] && mv "$out" "$DIR/failed/$s.$(date +%H%M%S).jsonl"
  # Settle: nothing from the start or the last test still warm in the numbers.
  sleep $SETTLE
  case $s in
    mac-gpu) bash "$FR/mac.sh" "$out" ;;
    mac-idle) hide_apps; bash "$FR/idle-power.sh" mac --seconds "$IDLE_S" --settle 30 \
                --desktop "macOS desktop, $(basename "$PIC") (the same picture as in the VMs), apps hidden" "$out" ;;
    *-gpu|rc2-vulkan|rc2-gl)
      local only=throughput,vkpeak,geekbench,vkmark,glmark2,browser
      [ "$s" = rc2-vulkan ] && only=vkpeak,geekbench,vkmark
      [ "$s" = rc2-gl ] && only=throughput,glmark2
      OMACVM_APP=$(app_of "$t") bash "$FR/vm.sh" "$t" --vm "$(name_of "$t")" "root@$HOST" --only "$only" "$out" ;;
    *-idle)
      bash "$FR/vm.sh" "$t" --vm "$(name_of "$t")" "root@$HOST" --desktop "$PIC" >/dev/null &&
        bash "$FR/idle-power.sh" "$t" --seconds "$IDLE_S" --settle 30 --ssh "root@$HOST" \
          --desktop "Omarchy desktop, $(basename "$PIC") (the Mac's picture), full screen" "$out" ;;
  esac
  rc=$?
  if [ $rc = 0 ] && [ -s "$out" ]; then mark "$s" "done"; return 0; fi
  why="exit $rc"; [ -s "$out" ] || why="$why, no results"
  [ -f "$out" ] && mv "$out" "$DIR/failed/$s.$(date +%H%M%S).jsonl"
  mark "$s" failed "$why"; log "$s: FAILED ($why); the round goes on, run it again to retry"
  return 1
}

# Wait (bounded) until the Mac is as agreed; prints the reasons when it is not.
gate() {   # target pattern, seconds
  local why i
  for ((i = 0; i <= $2; i += 30)); do
    why=$(OUT=$DIR/x bash -c ". '$FR/common.sh'; preflight_why '$1'" 2>/dev/null)
    builtin_only || why="${why:+$why; }an external display is connected (the round uses the built-in display only)"
    [ -z "$why" ] && return 0
    [ $i -lt "$2" ] && sleep 30
  done
  echo "$why"; return 1
}
keep_of() { case $1 in mac) echo NONE ;; app|app-rc2) echo 'OmacVM[^/]*\.app/' ;; utm) echo 'UTM\.app/|com\.apple\.Virtualization' ;; fusion) echo 'VMware Fusion\.app/' ;; parallels) echo 'Parallels Desktop\.app/|/prl_' ;; esac; }

summary() {
  local fl=()
  for f in "$DIR"/*.jsonl; do [ -s "$f" ] && fl+=("$f"); done
  [ ${#fl[@]} -gt 0 ] || { log "summary: no results yet"; return 1; }
  # Geekbench prints a link: its scores come from GEEKBENCH_SCORES, else from its pages (a Chrome window, after the tests).
  local gb=(--fetch-geekbench) lb=()
  [ -n "${GEEKBENCH_SCORES:-}" ] && gb=(--geekbench-scores "$GEEKBENCH_SCORES")
  [ "${FETCH_GEEKBENCH:-1}" = 0 ] && [ -z "${GEEKBENCH_SCORES:-}" ] && gb=()
  [ -n "$RC2_LABEL" ] && lb=(--label "app-rc2=$RC2_LABEL")
  python3 "$FR/summarize.py" "${fl[@]}" ${gb[@]+"${gb[@]}"} ${lb[@]+"${lb[@]}"} --json "$DIR/chart.json" > "$DIR/table.md" ||
    { log "summary: Geekbench scores not read, without them"; python3 "$FR/summarize.py" "${fl[@]}" ${lb[@]+"${lb[@]}"} --json "$DIR/chart.json" > "$DIR/table.md"; } ||
    { log "summary: summarize.py failed"; return 1; }
  python3 - "$DIR/chart.json" "$STATE" <<'EOF'
import json, sys
c = json.load(open(sys.argv[1]))
notes = [l.split(None, 3) for l in open(sys.argv[2]) if l.strip()]
last = {}
for n in notes:
    last[n[0]] = n
c["round"] = {s: {"status": n[1], "at": n[2], "why": n[3].strip() if len(n) > 3 else None} for s, n in last.items()}
json.dump(c, open(sys.argv[1], "w"), indent=1)
EOF
  local sub
  sub="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name/ { m = $2 } /Chip/ { c = $2 } END { sub(/^Apple /, "", c); print m " " c }') · macOS $(sw_vers -productVersion) · Google Chrome $(/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --version 2>/dev/null | awk '{print $3}' | cut -d. -f1) · $(date '+%B %Y')"
  { echo; echo "## Round steps"; awk '{ v[$1] = $0 } END { for (s in v) print "- " v[s] }' "$STATE" | sort; } >> "$DIR/table.md"
  python3 "$REPO/src/bench/chart.py" --panel gpu "$DIR/chart.json" "$DIR/gpu.svg" "$sub" || { log "summary: chart.py failed"; return 1; }
  svg_png "$DIR/gpu.svg" "$DIR/gpu.png"
  log "summary: $DIR/table.md, chart.json, gpu.svg$([ -s "$DIR/gpu.png" ] && echo ', gpu.png')"
}
svg_png() {   # the chart as PNG (2x) for places that show no SVG, via headless Chrome
  local w h c="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  read -r w h < <(sed -n 's/.*<svg[^>]* width="\([0-9]*\)" height="\([0-9]*\)".*/\1 \2/p' "$1" | head -1)
  [ -n "$w" ] && [ -x "$c" ] || return 1
  "$c" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --window-size="$w,$h" \
    --screenshot="$2" "file://$1" >/dev/null 2>&1
}

[ "$MODE" = summary ] && { summary; exit $?; }

# ---------- the round ----------
cleanup() {
  [ -n "${CUR:-}" ] && { log "stopping $CUR"; vm_down "$CUR"; }
  [ -n "${CAF:-}" ] && kill "$CAF" 2>/dev/null
  [ "${LOCKED:-0}" = 1 ] && rm -rf "$LOCK"
}
trap cleanup EXIT
trap 'log "interrupted"; exit 130' INT TERM

if [ "$MODE" = prepare-rc2 ]; then
  [ -d "$RC2_APP" ] || die "RC2_APP: the 3.0.0 RC2 app"
  RC2_SRC=${RC2_SRC:-}; [ -f "$RC2_SRC/src/app/guest/venus/vulkan-virtio.sh" ] || die "RC2_SRC: the RC2's source tree (with src/app/guest/venus)"
  [ -e "$HOME/.omacvm-user-testing" ] && die "the user is testing (~/.omacvm-user-testing): no VM starts"
  root="$HOME/Library/Application Support/OmacVM/VMs"; dst="$root/$RC2_VM" h=127.0.0.1:$RC2_PORT
  pgrep -f -- "-name $APP_VM -" >/dev/null && die "\"$APP_VM\" runs: stop it first (its disk is cloned)"
  pgrep -f -- "-name $RC2_VM -" >/dev/null && die "\"$RC2_VM\" runs: stop it first"
  if [ ! -d "$dst" ]; then
    say "\"$RC2_VM\": an APFS clone of \"$APP_VM\" (prepared, the same wallpaper)"
    cp -c -R "$root/$APP_VM" "$dst" || die "clone failed"
    rm -f "$dst/venus-ready"
    sed -i '' -e "s/^NAME=.*/NAME='$RC2_VM'/" -e "s/^SSH_PORT=.*/SSH_PORT='$RC2_PORT'/" -e "s/^VM_HOSTNAME=.*/VM_HOSTNAME='bench-omacvm-rc2'/" "$dst/vm.env"
  fi
  echo vulkan > "$dst/graphics"
  # The driver build is load: under the bench lock (waits up to 20 min for another holder).
  for ((i = 0; i < 40; i++)); do mkdir "$LOCK" 2>/dev/null && break; sleep 30; done
  [ $i -lt 40 ] || die "the bench lock is held: $(cat "$LOCK/owner" 2>/dev/null)"
  echo "gpu-bench prepare-rc2 $$ $(date +%T)" > "$LOCK/owner"; LOCKED=1
  rc2_start() {
    local e envs=(); for e in $RC2_APP_ENV; do envs+=(--env "$e"); done
    open -n --env OMACVM_COCOA_HIDDEN=1 --env OMACVM_TEST_PASTEBOARD=org.omacvm.bench-test ${envs[@]+"${envs[@]}"} \
      "$RC2_APP" --args --start --vm "$RC2_VM" && wait_desktop "$h" 300
  }
  rc2_stop() { gs "$h" 'systemctl poweroff' >/dev/null 2>&1; for ((i = 0; i < 24; i++)); do pgrep -f -- "-name $RC2_VM -" >/dev/null || break; sleep 5; done; pkill -f "$RC2_APP/Contents/MacOS/" 2>/dev/null; }
  say "\"$RC2_VM\": start (hidden), OmacVM's Venus driver from $RC2_SRC"
  rc2_start || die "\"$RC2_VM\" did not start"
  # What `omacvm graphics --vm NAME vulkan` does on a running VM, with the RC2 tree's guest files (the
  # Bench VM keeps its 2.9.1 guest otherwise). Not through the CLI: it looks for the VM's QEMU by the
  # folder name it expects, and the app may start QEMU with the folder's on-disk case
  # ("Application Support/omacvm/VMs"): the CLI then sees the VM stopped and starts it again.
  # The Vulkan present mode needs no file: the RC2 app tells the guest (omacvm.vkwindows); an older
  # tree still has 90-omacvm-vulkan.conf (software WSI), installed when it is there.
  # shellcheck disable=SC2046  # zero or one file name
  ( cd "$RC2_SRC/src/app/guest" && COPYFILE_DISABLE=1 tar --no-xattrs -cf - venus $(ls 90-omacvm-vulkan.conf 2>/dev/null) ) |
    gsi "$h" 'rm -rf /opt/omacvm-final-round/venus && mkdir -p /opt/omacvm-final-round && tar --no-same-owner -C /opt/omacvm-final-round -xf - &&
      { [ ! -f /opt/omacvm-final-round/90-omacvm-vulkan.conf ] || install -m644 /opt/omacvm-final-round/90-omacvm-vulkan.conf /etc/environment.d/90-omacvm-vulkan.conf; }' ||
    { rc2_stop; die "copying the Venus driver files failed"; }
  gs "$h" 'sed -i "/^OMACVM_GRAPHICS=/d" /etc/omacvm/env && echo OMACVM_GRAPHICS=vulkan >> /etc/omacvm/env &&
    OMARCHY_ALLOW_DIRECT_PACMAN=1 /opt/omacvm-final-round/venus/vulkan-virtio.sh --want' ||
    { rc2_stop; die "the Venus driver did not build (see /var/log/omacvm-vulkan-virtio.log in the VM)"; }
  : > "$dst/venus-ready"
  rc2_stop; sleep 5
  say "\"$RC2_VM\": restart with Venus"
  rc2_start || die "\"$RC2_VM\" did not start again"
  vk=$(gs "$h" "vulkaninfo --summary 2>/dev/null | sed -n 's/.*deviceName *= *//p' | paste -sd, -")
  case $vk in *Venus*|*Apple*) say "Vulkan: $vk" ;; *) rc2_stop; die "no Venus device in \"$RC2_VM\" ($vk)" ;; esac
  bash "$FR/vm.sh" app-rc2 --vm "$RC2_VM" "root@$h" --record || { rc2_stop; die "record failed"; }
  rc2_stop
  say "\"$RC2_VM\" ready for the round (RC2_APP, RC2_VM=\"$RC2_VM\", RC2_PORT=$RC2_PORT)"
  exit 0
fi

PIC=$(picture); [ -f "$PIC" ] || die "no wallpaper picture (the Mac's desktop picture, or WALLPAPER=FILE)"
if [ "$MODE" = fullscreen ]; then   # a check, no numbers: start, full screen, width, stop
  case $FS_TARGET in app|app-rc2|utm|fusion|parallels) ;; *) die "--fullscreen app|app-rc2|utm|fusion|parallels" ;; esac
  CUR=$FS_TARGET
  if vm_up "$FS_TARGET"; then r=0; log "$FS_TARGET: full screen ok ($(widths "$HOST") px)"; else r=1; fi
  [ "$KEEP" = 1 ] && { CUR=""; log "$FS_TARGET: left running (--keep)"; }
  exit $r
fi

# The end of the budget: kept from the first run, unless --budget is given.
if [ -n "$BUDGET" ] || [ ! -f "$DIR/deadline" ]; then
  echo $(( $(date +%s) + ${BUDGET:-180} * 60 )) > "$DIR/deadline"
  idle_seconds "${BUDGET:-180}" > "$DIR/idle-seconds"
fi
DEADLINE=$(cat "$DIR/deadline") IDLE_S=$(cat "$DIR/idle-seconds")
SIM=""   # the dry run's clock: each step takes its estimate
now() { if [ -n "$SIM" ]; then echo "$SIM"; else date +%s; fi; }
left() { echo $(( (DEADLINE - $(now)) / 60 )); }
log "round in $DIR: budget until $(date -r "$DEADLINE" +%H:%M) ($(left) min), idle windows ${IDLE_S}s, wallpaper $PIC"
if [ -z "$RC2_APP" ]; then
  log "RC2_APP not set: the OmacVM 3.0.0 RC2 rows are skipped"
  for s in rc2-vulkan rc2-gl; do pending "$s" && mark "$s" skipped "RC2_APP not set"; done
fi

if [ "$DRY" = 1 ]; then
  SIM=$(date +%s)
  if [ -n "${DRY_FAIL:-}" ]; then echo "$DRY_FAIL" > "$DIR/dry-fail"; fi
  run_step() {
    local m; m=$(est "$1"); [ "$(field "$1" 3)" = idle ] && m=$(( (IDLE_S + SETTLE + 30 + 59) / 60 ))
    SIM=$(( SIM + m * 60 + SETTLE ))
    if listed "$(cat "$DIR/dry-fail" 2>/dev/null)" "$1"; then log "dry run: $1 fails"; mark "$1" failed "dry run"; return 1; fi
    log "dry run: $1 ($(field "$1" 2), $m min)"; mark "$1" dry
  }
  vm_up() { log "dry run: start $1 in full screen"; HOST=dry; SIM=$(( SIM + UP_MIN * 60 )); }
  vm_down() { log "dry run: stop $1"; HOST=""; SIM=$(( SIM + DOWN_MIN * 60 )); }
  gate() { return 0; }
  sleep() { :; }
fi

if [ "$DRY" = 0 ]; then
  # The bench lock for the whole round (STANDARDS 30: the Mac is the round's), and the display awake.
  # A lock left by an earlier round.sh that is gone is ours to take over; anyone else's: wait up to 20 min.
  case $(cat "$LOCK/owner" 2>/dev/null) in
    "final-round "*) p=$(awk '{ print $2 }' "$LOCK/owner"); kill -0 "$p" 2>/dev/null || rm -rf "$LOCK" ;;
  esac
  for ((i = 0; i < 40; i++)); do mkdir "$LOCK" 2>/dev/null && break; [ $i = 0 ] && log "waiting for the bench lock: $(cat "$LOCK/owner" 2>/dev/null)"; sleep 30; done
  mkdir "$LOCK" 2>/dev/null || [ -z "$(ls -A "$LOCK" 2>/dev/null)" ] || die "the bench lock is still held: $(cat "$LOCK/owner" 2>/dev/null)"
  echo "final-round $$ $(date +%T), until $(date -r "$DEADLINE" +%H:%M)" > "$LOCK/owner" && LOCKED=1
  foreign=$(foreign_vms)
  [ -z "$foreign" ] || die "not a Bench VM, running: $foreign. The round never touches the user's VMs: wait until it is stopped"
  caffeinate -d -i -w $$ & CAF=$!
  if [ "$WAIT_IDLE" = 1 ]; then   # the user's go: if someone uses the Mac, 10 idle minutes first
    while [ "$(hid_idle)" -lt 600 ]; do log "the Mac was used $(hid_idle)s ago: waiting for 10 idle minutes"; sleep 60; done
  fi
  quiet_services
  for a in UTM "VMware Fusion" "Parallels Desktop"; do osascript -e "quit app \"$a\"" >/dev/null 2>&1; done
  quiet_services
fi

CUR=""
for t in mac app app-rc2 utm fusion parallels; do
  steps=$(echo "$STEPS" | awk -v t="$t" '$2 == t { print $1 }')
  todo=""
  for s in $steps; do wanted "$s" && pending "$s" && todo="$todo $s"; done
  [ -n "$todo" ] || continue
  if [ "$t" != mac ]; then
    CUR=$t
    if ! vm_up "$t"; then
      for s in $todo; do mark "$s" failed "the VM did not come up in full screen"; done
      vm_down "$t"; CUR=""; continue
    fi
  fi
  for s in $todo; do
    k=$(field "$s" 3) m=$(est "$s")
    # What the later GPU steps need (with their start and stop), kept free.
    need=$(echo "$STEPS" | awk -v s="$s" 'f && $3 == "gpu" { print $1 } $1 == s { f = 1 }' | while read -r n; do wanted "$n" && pending "$n" && est "$n"; done | awk '{ t += $1 + 5 } END { print t + 0 }')
    case $k in
      idle) [ "$IDLE_S" -gt 0 ] || { mark "$s" skipped "no time for idle rows in the budget"; log "$s: skipped (budget)"; continue; }
            m=$(( (IDLE_S + SETTLE + 30 + 59) / 60 ))
            [ $(( $(left) - need )) -ge "$m" ] || { mark "$s" skipped "the round ran late: no time left"; log "$s: skipped (time)"; continue; } ;;
      extra) [ $(( $(left) - need - 10 )) -ge "$m" ] || { mark "$s" skipped "no time to spare"; log "$s: skipped (no time to spare)"; continue; } ;;
      gpu) [ "$(left)" -ge "$m" ] || { mark "$s" skipped "out of time"; log "$s: skipped: out of time ($(left) min left)"; continue; } ;;
    esac
    if ! why=$(gate "$(keep_of "$t")" 600); then
      mark "$s" refused "$why"; log "$s: refused by the preflight: $why"; continue
    fi
    log "$s: start ($m min, $(left) min left)"
    t0=$(now)
    run_step "$s" && log "$s: done in $(( ($(now) - t0) / 60 )) min"
  done
  [ "$t" != mac ] && { vm_down "$t"; CUR=""; }
done

if [ "$DRY" = 1 ]; then log "dry run: summary"; else summary; fi
log "round finished: $(awk '{ v[$1] = $2 } END { for (s in v) printf "%s=%s ", s, v[s] }' "$STATE")"
grep -Eq ' (failed|refused) ' <(awk '{ v[$1] = $0 } END { for (s in v) print v[s] }' "$STATE") && {
  log "some steps failed or were refused: fix the cause and run the same command again (it resumes)"; exit 1; }
exit 0
