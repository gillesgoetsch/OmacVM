#!/bin/bash
# OmacVM.app: an app in the VM lost its GPU context on the Mac (the memory
# guard, or macOS short of memory). The VM's Mesa cannot tell the app, so
# Chrome kept drawing into the lost context: blank or flickering windows
# until it was restarted. `omacvm-desktop-recover app NAME guard|pressure`
# now ends NAME's GPU process, and Chrome or Chromium starts a new one by
# itself (other Chromium-based apps such as Electron's have the same GPU
# process). Real processes stand in for an app's processes
# (their /proc name and command line as Chrome's), so this runs on Linux only,
# as in the VM (CI's guest job):
# - only the GPU process of the app named, the user's own: a process named
#   exactly NAME with the argument --type=gpu-process (exactly that argument,
#   or that word in a command line of one string: Chrome's process title);
#   not its browser or renderer, not another app's, not a name that only
#   looks alike, not "--type=gpu-processX" or "--x=--type=gpu-process", not
#   the word after a space inside one of several arguments, never Hyprland's;
# - at most once per app in 6 minutes and 3 times in an hour (Chrome turns
#   its GPU off after 3 recent crashes and forgives one per 5 minutes);
# - the times are kept in a folder of root's own (0700), never followed
#   through a link; anything else there and nothing restarts;
# - an app without a GPU process (Firefox): the note only, as before;
# - the note says what happened and what to do if it goes blank again.
# - a lost Vulkan (Venus) context (venus NAME venus|guard): nothing is ended; for
#   ghostty the state file that sends the next Ghostty to the CPU, never through a link.
# - the full name (3.4.5, #624): QEMU knows only the 15 bytes the VM's kernel keeps
#   (cleanup-worker-); the note and the journal name the full one from the desktop
#   user's processes of that name (executable, else first argument), only when one
#   name fits; what is ended and its times stay keyed by the 15 bytes.
#   src/tests/desktop-recover-gpu.sh [SCRIPT]   (another copy of the script, e.g. an older one)
set -uo pipefail
[[ $(uname -s) == Linux ]] || { echo "skip: Linux only (it reads /proc)"; exit 0; }
command -v python3 >/dev/null || { echo "skip: no python3"; exit 0; }
R=$(cd "$(dirname "$0")/../.." && pwd)
G=${1:-$R/src/app/guest/omacvm-desktop-recover}
T=$(mktemp -d)
PIDS=()
cleanup() {
  (( ${#PIDS[@]} )) && kill -KILL "${PIDS[@]}" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# A process named COMM (its /proc comm) with the command line ARG0 ARGS...;
# its pid in P. Python's main thread names the process itself (PR_SET_NAME).
# titled COMM TITLE: the same, with a command line of one string, TITLE, as
# Chrome's children set it (setproctitle): Python writes TITLE over its own
# arguments' memory (arg_start/arg_end in /proc/self/stat), padded with NULs.
NAMER='import ctypes, sys, time
ctypes.CDLL(None).prctl(15, sys.argv[1].encode(), 0, 0, 0)
if sys.argv[2:3] == ["--title"]:
    f = open("/proc/self/stat").read().rsplit(")", 1)[1].split()
    a, e = int(f[45]), int(f[46])
    t = sys.argv[3].encode()[:e - a - 1]
    ctypes.memmove(a, t + bytes(e - a - len(t)), e - a)
time.sleep(600)'
titled() {
  proc "$1" python3 --title "$2"
  for _ in $(seq 100); do
    [[ $(tr '\0' '\n' < "/proc/$P/cmdline" 2>/dev/null | grep -c .) == 1 ]] && return 0
    sleep 0.05
  done
  echo "FAIL the stand-in for \"$2\" has no command line of one string"; fail=1
}
proc() {
  local comm=$1 arg0=$2 c
  shift 2
  (exec -a "$arg0" python3 -c "$NAMER" "$comm" "$@") > /dev/null 2>&1 &
  P=$!
  disown "$P"   # no "Killed" job notices when the script under test ends it
  PIDS+=("$P")
  for _ in $(seq 100); do
    IFS= read -r c 2>/dev/null < "/proc/$P/comm" && [[ $c == "$comm" ]] && return 0
    sleep 0.05
  done
  echo "FAIL could not start a stand-in named $comm"; fail=1
}
# Running (an ended stand-in stays a zombie until this script ends: not running).
alive() {
  local key state
  while read -r key state _; do [[ $key == State: ]] && break; done 2>/dev/null < "/proc/$1/status"
  [[ -n ${state:-} && $state != Z && $state != X ]]
}
state() { alive "$1" && echo running || echo ended; }

# Stand-ins for what reaches the desktop session (sudo -u USER ... _ CMD) and the journal.
S=$T/bin; mkdir -p "$S"
export CALLS=$T/calls
cat > "$S/sudo" <<'STUB'
#!/bin/bash
shift 2
if [[ $1 == sh && $2 == -c ]]; then exec sh -c "$3" "${@:4}"; fi
while [[ $# -gt 0 && $1 != _ ]]; do shift; done; shift; "$@"
STUB
printf '#!/bin/bash\necho "logger $*" >> "$CALLS"\n' > "$S/logger"
printf '#!/bin/bash\nprintf "%%s|" "notify-send" "$@" >> "$CALLS"; echo >> "$CALLS"\n' > "$S/notify-send"
chmod +x "$S"/*
export PATH="$S:$PATH"
export OMACVM_RECOVER_ENV=$T/env OMACVM_RECOVER_STAMPS=$T/stamps OMACVM_RECOVER_NOTE=$T/run/desktop/restarted
printf 'OMACVM_VM_TYPE=app\nOMACVM_USER=%s\n' "$(id -un)" > "$T/env"
NOW=$(date +%s)
run() { : > "$CALLS"; OMACVM_RECOVER_NOW=$1 "$G" app "${@:2}" > /dev/null 2>&1; }
note() { grep '^notify-send' "$CALLS" | cut -d'|' -f6; }
body() { grep '^notify-send' "$CALLS" | cut -d'|' -f7; }

# Chrome as it runs in the VM: its browser, a renderer and its GPU process,
# the children with Chrome's process title (one string, words joined by spaces).
proc chrome /opt/google/chrome/chrome; browser=$P
titled chrome "/opt/google/chrome/chrome --type=renderer --crashpad-handler-pid=7 --lang=en-US"; renderer=$P
titled chrome "/opt/google/chrome/chrome --type=gpu-process --crashpad-handler-pid=7 --gpu-preferences=WAAAAAAAAAAg"; gpu=$P
[[ $(tr '\0' '\n' < "/proc/$gpu/cmdline" | grep -c .) == 1 ]] && expect "a titled stand-in has a command line of one string" yes yes \
  || expect "a titled stand-in has a command line of one string" yes "$(tr '\0' '|' < "/proc/$gpu/cmdline" | cut -c1-120)"
# Arch's Chromium and an Electron app, arguments NUL-separated.
proc chromium /usr/lib/chromium/chromium --type=gpu-process --field-trial-handle=3; chromium=$P
proc code /usr/lib/code/code --type=gpu-process; code=$P
# Look-alikes that are not chrome's GPU process.
proc chrome /opt/google/chrome/chrome --type=gpu-processX; nearly=$P
proc chrome /opt/google/chrome/chrome "--enable-features=x --x=--type=gpu-process"; inside=$P
proc chrome /opt/google/chrome/chrome "--enable-features=x --type=gpu-process"; spaced=$P
titled chrome "/opt/google/chrome/chrome --type=gpu-processX"; nearlyt=$P
proc chromex /opt/chromex/chromex --type=gpu-process; chromex=$P
proc Hyprland Hyprland --type=gpu-process; hypr=$P
proc firefox /usr/lib/firefox/firefox -contentproc; firefox=$P

run "$NOW" chrome pressure
expect "chrome lost: its GPU process is ended"                ended   "$(state "$gpu")"
expect "its browser keeps running (tabs stay)"                running "$(state "$browser")"
expect "its renderer keeps running"                           running "$(state "$renderer")"
expect "Chromium's GPU process is not chrome's"               running "$(state "$chromium")"
expect "an Electron app's GPU process is not chrome's"        running "$(state "$code")"
expect "--type=gpu-processX is not a GPU process"             running "$(state "$nearly")"
expect "the word inside another argument does not count"      running "$(state "$inside")"
expect "nor after a space inside one of several arguments"    running "$(state "$spaced")"
expect "a title with --type=gpu-processX is not a GPU process" running "$(state "$nearlyt")"
expect "a name that starts the same (chromex) is not chrome"  running "$(state "$chromex")"
expect "the note says chrome's graphics were restarted"       "chrome's graphics were restarted" "$(note)"
expect "and why, what stays, and what to do if it goes blank again" \
  "macOS ran short of memory, so chrome lost its graphics on the Mac. OmacVM restarted chrome's GPU process: its windows draw again in a few seconds and open tabs stay; pages with WebGL may need a reload. Close something on the Mac or in the VM. If chrome goes blank again, quit it and open it again." \
  "$(body)"
grep -q "^logger -t omacvm-desktop-recover -- ended chrome's GPU process (pid $gpu)" "$CALLS" \
  && expect "the journal names the process ended" yes yes || expect "the journal names the process ended" yes no
expect "the times' folder: made 0700, the script's own"       "$(id -u) 700" "$(stat -c '%u %a' "$T/stamps" 2>/dev/null)"
expect "one restart noted for chrome"                         1 "$(grep -c . "$T/stamps/gpu-chrome" 2>/dev/null)"

# Chrome starts a new GPU process, which is lost again at once: not restarted again so soon.
titled chrome "/opt/google/chrome/chrome --type=gpu-process --crashpad-handler-pid=7"; gpu=$P
run $((NOW + 30)) chrome pressure
expect "lost again 30 s later: the new GPU process is left alone" running "$(state "$gpu")"
expect "the note says chrome stopped drawing (as before)"     "chrome stopped drawing" "$(note)"
grep -q "chrome's GPU process was not restarted: restarted 0 min ago" "$CALLS" \
  && expect "the journal says why not" yes yes || expect "the journal says why not" yes no
run $((NOW + 359)) chrome pressure
expect "5 min 59 s after: still left alone"                   running "$(state "$gpu")"
run $((NOW + 360)) chrome pressure
expect "6 min after: restarted (Chrome forgave the first)"    ended   "$(state "$gpu")"
titled chrome "/opt/google/chrome/chrome --type=gpu-process"; gpu=$P
run $((NOW + 720)) chrome pressure
expect "12 min after: restarted (the third in the hour)"      ended   "$(state "$gpu")"
titled chrome "/opt/google/chrome/chrome --type=gpu-process"; gpu=$P
run $((NOW + 1100)) chrome pressure
expect "a fourth within the hour: left alone"                 running "$(state "$gpu")"
grep -q "restarted 3 times in the last hour" "$CALLS" \
  && expect "the journal says 3 times in the hour" yes yes || expect "the journal says 3 times in the hour" yes no
run $((NOW + 3601)) chrome pressure
expect "an hour after the first: restarted again"             ended   "$(state "$gpu")"
expect "the times older than an hour are dropped"             3 "$(grep -c . "$T/stamps/gpu-chrome")"

# Each app has its own times; the guard's note has its own words.
run "$NOW" chromium guard
expect "Chromium lost to the guard: its GPU process is ended" ended   "$(state "$chromium")"
case $(body) in
"chromium used all the graphics memory apps may have on this Mac (the rest is kept for the desktop), so it lost its graphics. OmacVM restarted chromium's GPU process"*"Close some of its tabs or windows."*)
  expect "the guard's note names the apps' share" yes yes ;;
*) expect "the guard's note names the apps' share" yes "$(body)" ;;
esac

# No regex: a "." in the name is a dot, and nothing is ended for it.
titled chrome "/opt/google/chrome/chrome --type=gpu-process"; gpu=$P
run "$NOW" chr.me pressure
expect "chr.me is not chrome"                                 running "$(state "$gpu")"
# An app without a GPU process: the note only.
run "$NOW" firefox pressure
expect "Firefox: nothing ended"                               running "$(state "$firefox")"
expect "Firefox: the note says it stopped drawing"            "firefox stopped drawing" "$(note)"
expect "and what helps" \
  "macOS ran short of memory, so firefox lost its graphics on the Mac. The desktop keeps running. Close something on the Mac or in the VM. Then reload or restart firefox." \
  "$(body)"
# Never the desktop.
run "$NOW" Hyprland pressure
expect "a process named Hyprland is never ended"              running "$(state "$hypr")"
# Only the desktop user's processes.
printf 'OMACVM_VM_TYPE=app\nOMACVM_USER=nobody\n' > "$T/env"
run "$NOW" code pressure
expect "another user's app: its GPU process is left alone"    running "$(state "$code")"
printf 'OMACVM_VM_TYPE=app\nOMACVM_USER=%s\n' "$(id -un)" > "$T/env"
# The times' folder: a link there, or a folder anyone else could write, and nothing restarts.
rm -rf "$T/stamps"; mkdir -m 700 "$T/elsewhere"; ln -s "$T/elsewhere" "$T/stamps"
run "$NOW" code pressure
expect "the times' folder is a link: nothing ended"           running "$(state "$code")"
expect "and nothing written where it points"                  "" "$(ls -A "$T/elsewhere")"
grep -q "is not a folder of its own" "$CALLS" \
  && expect "the journal says why" yes yes || expect "the journal says why" yes no
rm -f "$T/stamps"; mkdir -m 755 "$T/stamps"
run "$NOW" code pressure
expect "the times' folder is open to others: nothing ended"   running "$(state "$code")"
chmod 700 "$T/stamps"
run "$NOW" code pressure
expect "a folder of its own: the Electron app's GPU process is ended" ended "$(state "$code")"

# A lost Vulkan (Venus) context (3.2.18): `venus NAME venus|guard` ends nothing, not even
# a GPU process; for ghostty it writes the state file that sends the next Ghostty to the
# CPU (root's file in root's folder, one line "lost TIME WHY"), never through a link.
export OMACVM_RECOVER_ZINK_OFF=$T/run-omacvm/gl-zink-off
venus() { : > "$CALLS"; "$G" venus "$@" > /dev/null 2>&1; }
titled chrome "/opt/google/chrome/chrome --type=gpu-process"; gpu=$P
proc ghostty /usr/bin/ghostty --gtk-single-instance=true; ghostty=$P
venus chrome venus
expect "venus chrome: its GPU process is not ended"           running "$(state "$gpu")"
expect "venus chrome: no state file (not ghostty)"            no "$([[ -e $OMACVM_RECOVER_ZINK_OFF ]] && echo yes || echo no)"
expect "venus chrome: the note" "chrome stopped drawing" "$(note)"
expect "venus chrome: says why and what helps" \
  "The Mac refused chrome's Vulkan commands, so its Vulkan graphics ended. The desktop keeps running. Restart chrome; if it closed by itself, open it again." \
  "$(body)"
venus ghostty venus
expect "venus ghostty: Ghostty is not ended"                  running "$(state "$ghostty")"
line=$(cat "$OMACVM_RECOVER_ZINK_OFF" 2>/dev/null)
case $line in
"lost "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*" venus") expect "the state file: one line lost TIME venus" yes yes ;;
*) expect "the state file: one line lost TIME venus" "lost TIME venus" "$line" ;;
esac
expect "the state file: one line, the folder made 0755, the file 0644, the script's own" \
  "1 755 644 $(id -u)" \
  "$(grep -c . "$OMACVM_RECOVER_ZINK_OFF") $(stat -c '%a' "$T/run-omacvm") $(stat -c '%a %u' "$OMACVM_RECOVER_ZINK_OFF")"
expect "the note says Ghostty stopped drawing"                "Ghostty stopped drawing" "$(note)"
expect "first to close it (what ends, that no new window opens until then), then why, and the CPU next time" \
  "Close it first: Terminate in the window that says it is not responding (programs running in it end); until then no new Ghostty window opens. The Mac refused its Vulkan commands. Its windows no longer draw or take typing. The next Ghostty starts on the CPU until the VM restarts, unless Zink is set for it by hand." \
  "$(body)"
venus ghostty guard
expect "a second loss keeps the first line"                   "$line" "$(cat "$OMACVM_RECOVER_ZINK_OFF")"
case $(body) in
"Close it first: "*" It used all the graphics memory apps may have on this Mac. Its windows"*)
  expect "the guard's note names the memory" yes yes ;;
*) expect "the guard's note names the memory" yes "$(body)" ;;
esac
venus 'ghost;ty$(id)' 'x;y'
expect "the name keeps only letters, digits, . _ -; any other cause is venus" 1 \
  "$(grep -c 'ghosttyid lost its Vulkan (Venus) context on the Mac (venus)' "$CALLS")"
# Never through a link: the file a link points to stays as it was.
rm -f "$OMACVM_RECOVER_ZINK_OFF"; echo keep > "$T/target"; ln -s "$T/target" "$OMACVM_RECOVER_ZINK_OFF"
venus ghostty venus
expect "a link where the state file goes: not followed"       keep "$(cat "$T/target")"
grep -q "is not a plain file" "$CALLS" && expect "the journal says so" yes yes || expect "the journal says so" yes no
rm -f "$OMACVM_RECOVER_ZINK_OFF"; rm -rf "$T/run-omacvm"; ln -s "$T/elsewhere" "$T/run-omacvm"
venus ghostty venus
expect "a link where the folder goes: nothing written there"  "" "$(ls -A "$T/elsewhere")"
grep -q "is not root's own folder" "$CALLS" && expect "the journal says so (folder)" yes yes \
  || expect "the journal says so (folder)" yes no
# The full name (3.4.5, #624): the VM's kernel names a context by its process's comm,
# 15 bytes (cleanup-worker-vulkan -> cleanup-worker-), and that is all QEMU sends.
# These stand-ins are not this shell's children (their subshell ends at once): one
# that is ended is gone from /proc, not left a zombie with the same comm.
standin() {   # COMM ARG0 FILE ARGS...: FILE runs with ARG0 as argv[0]; its pid in P
  local comm=$1 arg0=$2 c
  shift 2
  P=$( { (exec -a "$arg0" "$@") > /dev/null 2>&1 < /dev/null & } ; echo $! )
  PIDS+=("$P")
  for _ in $(seq 100); do
    IFS= read -r c 2>/dev/null < "/proc/$P/comm" && [[ $c == "$comm" ]] && return 0
    sleep 0.05
  done
  echo "FAIL could not start a stand-in named $comm"; fail=1
}
stop() {   # PID...: ended and gone from /proc
  local p
  kill -KILL "$@" 2>/dev/null
  for p in "$@"; do
    for _ in $(seq 100); do [[ -e /proc/$p ]] || break; sleep 0.05; done
  done
}
journal() { grep '^logger' "$CALLS" | sed 's/^logger -t omacvm-desktop-recover -- //'; }
# readlink, counted (the scan's only fork): RL=1 venus ... puts this one first.
RL_REAL=$(command -v readlink)
mkdir -p "$T/rl"
printf '#!/bin/bash\necho x >> "%s"\nexec "%s" "$@"\n' "$T/readlinks" "$RL_REAL" > "$T/rl/readlink"
chmod +x "$T/rl/readlink"
counted() { : > "$T/readlinks"; PATH="$T/rl:$PATH" "$@"; }
reads() { grep -c . "$T/readlinks"; }

# A copy of sleep under the app's file name: the kernel takes the comm from it.
# Only a real sleep: a multi-call binary (busybox, uutils) acts on its argv[0].
SLEEP=$(readlink -f "$(command -v sleep)")
mkdir -p "$T/w"
if [[ ${SLEEP##*/} != sleep ]]; then
  echo "skip: sleep is ${SLEEP:-missing} (a multi-call binary), no rows with a copied executable"
else
  cp "$SLEEP" "$T/w/cleanup-worker-vulkan"
  # argv[0] "sleep": the name comes from the executable.
  standin cleanup-worker- sleep "$T/w/cleanup-worker-vulkan" 600; w=$P
  venus cleanup-worker- venus
  expect "a 15-byte name: the note names the executable's full name" \
    "cleanup-worker-vulkan stopped drawing" "$(note)"
  expect "and so does its text" \
    "The Mac refused cleanup-worker-vulkan's Vulkan commands, so its Vulkan graphics ended. The desktop keeps running. Restart cleanup-worker-vulkan; if it closed by itself, open it again." \
    "$(body)"
  expect "the journal names both (QEMU's to match qemu.log)" \
    "cleanup-worker-vulkan (QEMU: cleanup-worker-) lost its Vulkan (Venus) context on the Mac (venus); nothing is ended, the desktop keeps drawing" \
    "$(journal)"
  expect "nothing is ended"                                    running "$(state "$w")"
  venus cleanup-worker- guard
  expect "guard: the note names the full name" \
    "cleanup-worker-vulkan used all the graphics memory apps may have on this Mac, so its Vulkan graphics ended. The desktop keeps running. Restart cleanup-worker-vulkan; if it closed by itself, open it again." \
    "$(body)"
  stop "$w"
  # The executable deleted while it runs (an update replaced it): still its name.
  cp "$SLEEP" "$T/w/cleanup-worker-gone"
  standin cleanup-worker- sleep "$T/w/cleanup-worker-gone" 600; w=$P
  rm -f "$T/w/cleanup-worker-gone"
  venus cleanup-worker- venus
  expect "the executable deleted: its name without (deleted)"  "cleanup-worker-gone stopped drawing" "$(note)"
  stop "$w"
  # Both fit but differ: the executable's name wins (argv[0] is anyone's to set).
  standin cleanup-worker- cleanup-worker-metal "$T/w/cleanup-worker-vulkan" 600; w=$P
  venus cleanup-worker- venus
  expect "executable and first argument differ: the executable's" "cleanup-worker-vulkan stopped drawing" "$(note)"
  stop "$w"
  # Two processes of that comm with different names: which one lost it is not known.
  cp "$SLEEP" "$T/w/cleanup-worker-metal"
  standin cleanup-worker- sleep "$T/w/cleanup-worker-vulkan" 600; w=$P
  standin cleanup-worker- sleep "$T/w/cleanup-worker-metal" 600; w2=$P
  venus cleanup-worker- venus
  expect "two different full names: the 15 bytes, as before"   "cleanup-worker- stopped drawing" "$(note)"
  expect "and the journal line as before (no QEMU name)" \
    "cleanup-worker- lost its Vulkan (Venus) context on the Mac (venus); nothing is ended, the desktop keeps drawing" \
    "$(journal)"
  stop "$w2"
  # Two of the same app agree.
  standin cleanup-worker- sleep "$T/w/cleanup-worker-vulkan" 600; w2=$P
  venus cleanup-worker- venus
  expect "two processes of one app: its full name"             "cleanup-worker-vulkan stopped drawing" "$(note)"
  stop "$w2"
  # Only the desktop user's processes.
  printf 'OMACVM_VM_TYPE=app\nOMACVM_USER=nobody\n' > "$T/env"
  venus cleanup-worker- venus
  expect "another user's process only: the 15 bytes"           "cleanup-worker- stopped drawing" "$(note)"
  printf 'OMACVM_VM_TYPE=app\nOMACVM_USER=%s\n' "$(id -un)" > "$T/env"
  stop "$w"
  # A file name with a byte outside letters, digits, . _ -: not shown.
  cp "$SLEEP" "$T/w/cleanup-worker-v;x"
  standin cleanup-worker- sleep "$T/w/cleanup-worker-v;x" 600; w=$P
  venus cleanup-worker- venus
  expect "a ; in the executable's name: the 15 bytes"          "cleanup-worker- stopped drawing" "$(note)"
  stop "$w"

  # Many processes of that comm (anyone can start them): at most 32 are looked at,
  # one readlink each, and the scan stays well within the Mac's 2 s.
  many=()
  for i in $(seq 50); do standin cleanup-worker- "x$i" "$T/w/cleanup-worker-vulkan" 600; many+=("$P"); done
  t0=$(date +%s%N); venus cleanup-worker- venus; t1=$(date +%s%N)
  ms=$(( (t1 - t0) / 1000000 ))
  (( ms < 1000 )) && expect "50 processes of that comm: done in under 1 s" yes yes \
    || expect "50 processes of that comm: done in under 1 s" "< 1000 ms" "$ms ms"
  echo "     ($ms ms with $(ls -d /proc/[0-9]* | wc -l) processes)"
  expect "and the full name"                                   "cleanup-worker-vulkan stopped drawing" "$(note)"
  counted venus cleanup-worker- venus
  expect "at most 32 of them looked at (one readlink each)"    32 "$(reads)"
  stop "${many[@]}"
fi

# The first argument when the executable says nothing (python3 here): as several
# arguments, or as one string (a process title).
standin asr-transcriber /opt/x/asr-transcriber-cuda python3 -c "$NAMER" asr-transcriber --model x; a=$P
venus asr-transcriber venus
expect "the first argument's file name"                      "asr-transcriber-cuda stopped drawing" "$(note)"
stop "$a"
standin asr-transcriber python3 python3 -c "$NAMER" asr-transcriber --title "/opt/x/asr-transcriber-cuda --model x"; a=$P
for _ in $(seq 100); do [[ $(tr '\0' '\n' < "/proc/$a/cmdline" 2>/dev/null | grep -c .) == 1 ]] && break; sleep 0.05; done
venus asr-transcriber venus
expect "a process title (one string): its first word's file name" "asr-transcriber-cuda stopped drawing" "$(note)"
stop "$a"
# A ; in it, or more than 64 bytes: not shown; 64 bytes are.
standin asr-transcriber "/opt/x/asr-transcriber-c;d" python3 -c "$NAMER" asr-transcriber; a=$P
venus asr-transcriber venus
expect "a ; in the first argument: the 15 bytes"             "asr-transcriber stopped drawing" "$(note)"
stop "$a"
long=asr-transcriber-$(printf 'x%.0s' $(seq 48))   # 64 bytes
standin asr-transcriber "/opt/x/$long" python3 -c "$NAMER" asr-transcriber; a=$P
venus asr-transcriber venus
expect "64 bytes: shown"                                     "$long stopped drawing" "$(note)"
stop "$a"
standin asr-transcriber "/opt/x/${long}x" python3 -c "$NAMER" asr-transcriber; a=$P
venus asr-transcriber venus
expect "65 bytes: the 15 bytes"                              "asr-transcriber stopped drawing" "$(note)"
stop "$a"
# Nothing of that name runs (it already ended): the 15 bytes, nothing looked up.
counted venus asr-transcriber venus
expect "nothing of that name runs: the 15 bytes"             "asr-transcriber stopped drawing" "$(note)"
expect "and no readlink"                                     0 "$(reads)"
# A name of 14 bytes was not cut: never looked up.
standin cleanup-worker /opt/x/cleanup-worker-vulkan python3 -c "$NAMER" cleanup-worker; a=$P
counted venus cleanup-worker venus
expect "a 14-byte name: as it is"                            "cleanup-worker stopped drawing" "$(note)"
expect "and nothing looked up"                               0 "$(reads)"
stop "$a"

# app: the note and the journal show the full name; the GPU process ended and its
# times stay keyed by QEMU's 15 bytes.
standin electron-app-wi /opt/x/electron-app-window python3 -c "$NAMER" electron-app-wi; ebrowser=$P
standin electron-app-wi /opt/x/electron-app-window python3 -c "$NAMER" electron-app-wi --type=gpu-process; egpu=$P
rm -rf "$T/stamps"
run "$NOW" electron-app-wi pressure
expect "app with a cut name: its GPU process is ended"       ended   "$(state "$egpu")"
expect "its browser keeps running"                           running "$(state "$ebrowser")"
expect "the note names the full name" "electron-app-window's graphics were restarted" "$(note)"
expect "and so does its text" \
  "macOS ran short of memory, so electron-app-window lost its graphics on the Mac. OmacVM restarted electron-app-window's GPU process: its windows draw again in a few seconds and open tabs stay; pages with WebGL may need a reload. Close something on the Mac or in the VM. If electron-app-window goes blank again, quit it and open it again." \
  "$(body)"
expect "the journal: both names, then the process ended by QEMU's" \
  "electron-app-window (QEMU: electron-app-wi) lost its GPU context on the Mac (pressure); the desktop keeps drawing|ended electron-app-wi's GPU process (pid $egpu): electron-app-wi starts a new one" \
  "$(journal | paste -sd'|')"
expect "the times are kept under QEMU's name"                "1 no" \
  "$(grep -c . "$T/stamps/gpu-electron-app-wi" 2>/dev/null) $([[ -e $T/stamps/gpu-electron-app-window ]] && echo yes || echo no)"
standin electron-app-wi /opt/x/electron-app-window python3 -c "$NAMER" electron-app-wi --type=gpu-process; egpu=$P
run $((NOW + 60)) electron-app-wi guard
expect "lost again a minute later: left alone (keyed by the 15 bytes)" running "$(state "$egpu")"
expect "the note names the full name"                        "electron-app-window stopped drawing" "$(note)"
expect "guard: the text too" \
  "electron-app-window used all the graphics memory apps may have on this Mac (the rest is kept for the desktop), so it lost its graphics. The desktop keeps running. Close some of its tabs or windows. Then reload or restart electron-app-window." \
  "$(body)"
journal | grep -q "^electron-app-window's GPU process was not restarted: restarted 1 min ago" \
  && expect "the journal says why not" yes yes || expect "the journal says why not" yes "$(journal | paste -sd'|')"
stop "$ebrowser" "$egpu"
exit $fail
