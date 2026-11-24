#!/bin/bash
# Input latency, end to end: a Mac key or pointer event -> the first changed
# picture of the VM's window on screen. A throwaway OmacVM.app VM runs on a
# virtual Mac display of its own (never the user's screens, never the focus);
# tests/graphics/pacing/inputlat.swift posts the events into QEMU's own event
# queue (AppKit, QEMU's window code, the guest) and times the change with
# ScreenCaptureKit. QEMU's trace (-msg timestamp=on) splits each event into
# Mac -> QEMU input, QEMU input -> the guest's next flush, flush -> screen.
#   src/tests/input-latency-vm.sh --runtime DIR --vm DIR --ssh-port PORT [--hz 60|120]
#        [--count N] [--modes MODES] [--env K=V]... [--hw-cursor] [--native] [--pause S] [--out DIR]
#        [--app] [--venus MB] [--cpus N] [--memory-mb N] [--smbios omacvm.KEY=VALUE]...
#        [--display virtual|builtin] [--no-breakdown]     |  --parse OUT
# MODES (default all; spaces or commas): key pointer keymove (AppKit), qmpkey qmppointer (QMP:
# no AppKit), qmpkeymove (keys AppKit, the moving pointer QMP); keybusy and qmpbusypointer: a key
# or a pointer jump while the terminal's lower right corner changes 125 times a second (frames
# come steadily without the pointer moving; the change there is not counted). Not in the default.
# DIR (vm): a COPY of an OmacVM.app VM made by omacvm apply (disk.img,
# efi-vars.fd); the test writes to it. --runtime: a built runtime or an
# app's Contents/Resources/runtime (with --firmware: its firmware's
# edk2-aarch64-code.fd). --env passes settings to QEMU for an A/B run
# (e.g. OMACVM_GL_VSYNC=0), --smbios a string to the guest as the app sends it
# (e.g. omacvm.pointerplane=1). --display builtin: the MacBook's own panel (its
# own refresh, ProMotion) instead of a virtual display: the window shows there,
# so only while nobody uses that Mac. --no-breakdown: no python3 here (the M1
# Max's opens an install dialog); --parse OUT on another Mac does it later.
# OMACVM_GUEST_KEY: the VM's SSH key (default
# ~/.ssh/omacvm). --hw-cursor: the guest's pointer on
# virtio-gpu's cursor plane (OMACVM_HW_CURSOR=1, omacvm.hwcursor=1).
# --app: QEMU's GPU and display settings as OmacVM.app gives them by default
# (GPU work without the BQL and the present's trim, Vulkan windows as
# IOSurfaces, the app's SMBIOS strings); still no sound card, balloon or
# vmnet, and one output; --venus MB adds Venus with that host memory window
# (a VM whose Graphics is Vulkan). Each mode prints a JSON summary; --out keeps
# the raw rows, QEMU's log and the breakdown (breakdown.json): per event the
# stages Mac -> QEMU input, input -> the guest app's first GPU work, -> the
# compositor's, -> its flush, -> QEMU's present, -> on screen; with --native
# the macOS app's own stages (event -> the app, -> drawn, -> on screen).
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
RT=""; VMD=""; PORT=""; HZ=60; COUNT=40; MODES="key pointer keymove qmpkey qmppointer qmpkeymove"; OUT=""; HWC=0; NATIVE=0; PAUSE=0
APP=0; VENUS=""; CPUS=4; MEM=8192; ONDISP=virtual; NOBD=0; PARSE=""
FW=$R/app/runtime/.build/firmware/edk2-aarch64-code.fd
QENV=(); XSMB=()
while (( $# )); do
  case $1 in
    --runtime) RT=$2; shift 2 ;;
    --vm) VMD=$2; shift 2 ;;
    --ssh-port) PORT=$2; shift 2 ;;
    --firmware) FW=$2; shift 2 ;;
    --hz) HZ=$2; shift 2 ;;
    --count) COUNT=$2; shift 2 ;;
    --modes) MODES=${2//,/ }; shift 2 ;;
    --env) QENV+=("$2"); shift 2 ;;
    --smbios) [[ $2 =~ ^omacvm\.[a-z0-9_]+=[0-9x.]+$ ]] || { echo "input-latency-vm: --smbios omacvm.KEY=VALUE" >&2; exit 2; }
              XSMB+=(-smbios "type=11,value=$2"); shift 2 ;;
    --hw-cursor) HWC=1; shift ;;
    --native) NATIVE=1; shift ;;
    --pause) PAUSE=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --app) APP=1; shift ;;
    --venus) VENUS=$2; shift 2 ;;
    --cpus) CPUS=$2; shift 2 ;;
    --memory-mb) MEM=$2; shift 2 ;;
    --display) ONDISP=$2; shift 2 ;;
    --no-breakdown) NOBD=1; shift ;;
    --parse) PARSE=$2; shift 2 ;;
    *) sed -n '9,13s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
  esac
done
# The stages from QEMU's trace (see the comment where it is called).
breakdown() {   # OUT MODES
python3 - "$1" "$2" <<'PY'
import datetime, json, os, re, statistics, sys
out, modes = sys.argv[1], sys.argv[2].split()
ev, names, sec, fences = [], {}, [], []
for line in open(os.path.join(out, "qemu.log"), errors="replace"):
    m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?)Z? (\w+)(.*)", line)
    if not m:
        continue
    t = datetime.datetime.fromisoformat(m.group(1)).replace(tzinfo=datetime.timezone.utc).timestamp() * 1e6
    name, rest = m.group(2), m.group(3)
    if name == "input_event_key_qcode" and "down 1" not in rest:
        continue
    if name == "virtio_gpu_cmd_ctx_create":
        c = re.search(r"ctx (0x[0-9a-f]+), name (\S*)", rest)
        if c:
            names[c.group(1)] = c.group(2)
        continue
    if name == "virtio_gpu_cmd_ctx_submit":
        c = re.search(r"ctx (0x[0-9a-f]+)", rest)
        n = names.get(c.group(1), "") if c else ""
        name = "submit_comp" if n.lower().startswith("hypr") else \
               "submit_term" if re.match(r"(alacritty|ghostty|foot)", n) else "submit_other"
    if name in ("cocoa_present_direct", "cocoa_present_frame"):
        name = "present"
    if name in ("virtio_gpu_fence_ctrl", "virtio_gpu_fence_resp"):
        c = re.search(r"fence (0x[0-9a-f]+)", rest)
        if c:
            fences.append((t, name.rsplit("_", 1)[1], c.group(1)))
        continue
    if name in ("cocoa_present_second", "cocoa_present_skips"):
        sec.append((t, name, [int(x) for x in re.findall(r"-?\d+", rest)]))
        continue
    ev.append((t, name))
ev.sort()
fences.sort()
resp = {}
for t, kind, fid in fences:
    if kind == "resp":
        resp.setdefault(fid, []).append(t)   # in time order
def fence_after(after, within=50e3):
    """The first fence any context asked for within 50 us after this time (the trace does not
    say whose), and when QEMU first answered that id after it was asked."""
    for t, kind, fid in fences:
        if t > after + within:
            return None
        if t >= after and kind == "ctrl":
            return next((r for r in resp.get(fid, ()) if r >= t), None)
    return None
def first(name, after, within=300e3):
    for t, n in ev:
        if t > after + within:
            return None
        if t >= after and n == name:
            return t
    return None
res = {"contexts": sorted(set(names.values()))}
med = lambda a: round(statistics.median(a), 2) if a else None
p90 = lambda a: round(sorted(a)[min(len(a) - 1, int(0.9 * len(a)))], 2) if a else None
for m in modes:
    p = os.path.join(out, m + ".jsonl")
    if not os.path.exists(p):
        continue
    st = {k: [] for k in ("total", "mac_to_qemu", "qemu_to_compositor", "qemu_to_client",
                          "client_to_compositor", "compositor_to_flush", "compositor_fence",
                          "flush_to_present", "present_to_screen")}
    cur = []
    pointer = m.endswith("pointer")
    for row in map(json.loads, open(p)):
        if row["lat_ms"] is None:
            continue
        post, screen = row["post_us"], row["post_us"] + row["lat_ms"] * 1e3
        q = first("input_event_abs" if pointer else "input_event_key_qcode", post)
        # (keymove: the pointer's own moves are in the trace too; keys are what is timed)
        if q is None or q > screen:
            continue
        st["total"].append(row["lat_ms"])
        st["mac_to_qemu"].append((q - post) / 1e3)
        c = first("virtio_gpu_update_cursor", q)
        if pointer and c is not None and c < screen:
            cur.append((c - q) / 1e3)
        cl = None if pointer else first("submit_term", q)
        co = first("submit_comp", cl if cl is not None and cl < screen else q)
        f = first("virtio_gpu_cmd_res_flush", co) if co is not None else None
        pr = first("present", f) if f is not None else None
        if co is None or f is None or pr is None or pr > screen:
            continue
        st["qemu_to_compositor"].append((co - q) / 1e3)
        if cl is not None and cl < co:
            st["qemu_to_client"].append((cl - q) / 1e3)
            st["client_to_compositor"].append((co - cl) / 1e3)
        st["compositor_to_flush"].append((f - co) / 1e3)
        # Of that: Hyprland's first submit -> the answer to the next fence (its GPU work done on the Mac).
        fr = fence_after(co)
        if fr is not None and fr <= f:
            st["compositor_fence"].append((fr - co) / 1e3)
        st["flush_to_present"].append((pr - f) / 1e3)
        st["present_to_screen"].append((screen - pr) / 1e3)
    r = {"n": len(st["total"]), "split_n": len(st["present_to_screen"])}
    for k, v in st.items():
        r[k + "_ms"] = med(v)
    r["total_p90_ms"] = p90(st["total"])
    r["qemu_to_cursor_cmd_ms"] = med(cur)
    # The present's own counters while this mode ran (one line a second while the link runs):
    # frames shown on ticks, shown when ready, the mean wait from flush to tick, repeats/merged/dropped.
    rows = [json.loads(x) for x in open(p)]
    if rows:
        a, b = rows[0]["post_us"], rows[-1]["post_us"] + 1e6
        on = [v for t, n, v in sec if a <= t <= b and n == "cocoa_present_second"]
        sk = [v for t, n, v in sec if a <= t <= b and n == "cocoa_present_skips"]
        if on:
            shown = sum(v[4] for v in on)
            r["link_s"] = len(on)
            r["shown_on_ticks"] = shown
            r["shown_when_ready"] = sum(v[5] for v in on)
            r["flush_to_tick_ms"] = round(sum(v[4] * v[6] for v in on) / shown / 1e3, 2) if shown else None
        if sk:
            r["repeats_merged_dropped"] = [sum(v[i] for v in sk) for i in range(3)]
    res[m] = r
# The macOS app (--native): its own times of each key and move it took and drew.
nat = os.path.join(out, "native-times.txt")
if os.path.exists(nat):
    marks = []
    for line in open(nat):
        k = line.split()
        if len(k) == 2 and k[0] in ("key", "move", "drew"):
            marks.append((float(k[1]), k[0]))
    marks.sort()
    def nfirst(kind, after, within=300e3):
        for t, n in marks:
            if t > after + within:
                return None
            if t >= after and n == kind:
                return t
        return None
    for m in ("key", "pointer", "keymove"):
        p = os.path.join(out, "native-" + m + ".jsonl")
        if not os.path.exists(p):
            continue
        st = {"total": [], "mac_to_app": [], "app_to_drawn": [], "drawn_to_screen": []}
        for row in map(json.loads, open(p)):
            if row["lat_ms"] is None:
                continue
            post, screen = row["post_us"], row["post_us"] + row["lat_ms"] * 1e3
            a = nfirst("move" if m == "pointer" else "key", post)
            d = nfirst("drew", a) if a is not None else None
            if a is None or d is None or d > screen:
                continue
            st["total"].append(row["lat_ms"])
            st["mac_to_app"].append((a - post) / 1e3)
            st["app_to_drawn"].append((d - a) / 1e3)
            st["drawn_to_screen"].append((screen - d) / 1e3)
        r = {"n": len(st["total"])}
        for k, v in st.items():
            r[k + "_ms"] = med(v)
        r["total_p90_ms"] = p90(st["total"])
        res["native-" + m] = r
print(json.dumps(res))
PY
}
# --parse DIR: only the breakdown of an earlier run's --out (from a Mac without python3).
if [[ -n $PARSE ]]; then
  m=$(cd "$PARSE" && ls *.jsonl 2>/dev/null | sed -n 's/\.jsonl$//p' | grep -v '^native-' | tr '\n' ' ')
  breakdown "$PARSE" "$m" | tee "$PARSE/breakdown.json"
  exit 0
fi
# Never the person's own VMs (~/OmacVM/<name>): a run writes the VM's disk and EFI variables and
# switches its Mac links off in the guest for good.
own=$(cd "$HOME/OmacVM" 2>/dev/null && pwd -P)
vmr=$(cd "$VMD" 2>/dev/null && pwd -P)
if [[ $VMD == "$HOME/OmacVM" || $VMD == "$HOME/OmacVM/"* ]] ||
   [[ -n $own && -n $vmr && ( $vmr == "$own" || $vmr == "$own/"* ) ]]; then
  echo "input-latency-vm: $VMD is one of your own VMs (~/OmacVM): use a copy of a test VM" >&2
  exit 1
fi
# A runtime from the build (qemu-system-aarch64) or from an app bundle (named OmacVM there).
QEMU=$RT/bin/qemu-system-aarch64
[[ -x $QEMU ]] || QEMU=$RT/bin/OmacVM
[[ -x $QEMU && -f $VMD/disk.img && -f $VMD/efi-vars.fd && $PORT =~ ^[0-9]+$ && -f $FW &&
   $HZ =~ ^(60|120)$ && $ONDISP =~ ^(virtual|builtin)$ && $COUNT =~ ^[0-9]+$ && $VENUS =~ ^[0-9]*$ && $CPUS =~ ^[1-9][0-9]?$ &&
   $MEM =~ ^[0-9]+$ ]] || { sed -n '9,13s/^# \{0,1\}//p' "$0" >&2; exit 2; }
[[ -e $HOME/.omacvm-user-testing ]] && { echo "input-latency-vm: the user is testing: no VM (STANDARDS 18)" >&2; exit 1; }
# The built-in panel's mode ("" without one): read before and after the virtual display (STANDARDS 32).
panel_mode() {
  swift -e 'import CoreGraphics
var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
CGGetOnlineDisplayList(16, &ids, &n)
for d in ids[0..<Int(n)] where CGDisplayIsBuiltin(d) != 0 {
  if let m = CGDisplayCopyDisplayMode(d) { print("\(m.width)x\(m.height) \(m.pixelWidth)x\(m.pixelHeight) \(m.refreshRate)") }
}' 2>/dev/null
}
# Posted events and screen capture: never on a MacBook the user works on (STANDARDS 33/34).
# OMACVM_LATENCY_ON_MACBOOK=1 overrides it (only when nobody uses that Mac).
PANEL=$(panel_mode)
if [[ ${OMACVM_LATENCY_ON_MACBOOK:-} != 1 ]] &&
   { [[ -n $PANEL ]] || pmset -g batt 2>/dev/null | grep -q InternalBattery; }; then
  echo "input-latency-vm: this Mac has a built-in panel or a battery: run it on the Mac mini" \
       "(OMACVM_LATENCY_ON_MACBOOK=1 overrides, STANDARDS 33/34)" >&2
  exit 1
fi
panel_same() {
  local now
  [[ -n $PANEL ]] || return 0
  now=$(panel_mode)
  [[ $now == "$PANEL" ]] && return 0
  echo "input-latency-vm: the built-in panel changed ($PANEL -> $now) $1; not set back (STANDARDS 32)" >&2
  return 1
}
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && { echo "input-latency-vm: port $PORT is in use" >&2; exit 1; }

NAME="OmacVM T-input-latency"
PAT="-name $NAME -machine"
W=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-input-latency.XXXXXX")
[[ -n $OUT ]] || OUT=$W/out
mkdir -p "$OUT"
LOG=$OUT/qemu.log
VD_PID=""
cleanup() {
  pgrep -f -- "$PAT" >/dev/null && gssh "sync; systemctl poweroff" >/dev/null 2>&1
  for _ in $(seq 40); do pgrep -f -- "$PAT" >/dev/null || break; sleep 1; done
  pkill -f -- "$PAT" 2>/dev/null
  [[ -n $VD_PID ]] && { kill "$VD_PID" 2>/dev/null; sleep 2; panel_same "after the virtual display went"; }
  [[ -n ${NPID:-} ]] && kill "$NPID" 2>/dev/null
  rm -rf "$W/run" "$W/inputlat" "$W/vdisplay" "$W/nativelat" "$W/vd.out"
  rmdir "$W" 2>/dev/null   # kept when the raw rows are in it (no --out)
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

gssh() {
  ssh -i "${OMACVM_GUEST_KEY:-$HOME/.ssh/omacvm}" -o IdentitiesOnly=yes -p "$PORT" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 "$@"
}

swiftc -O "$R/tests/graphics/pacing/inputlat.swift" -o "$W/inputlat" || exit 1
clang -fobjc-arc -framework Foundation -framework CoreGraphics -framework AppKit \
  "$R/tests/graphics/pacing/vdisplay.m" -o "$W/vdisplay" || exit 1

if [[ $ONDISP == builtin ]]; then
  # The MacBook's panel at its own rate (ProMotion follows the window's frames).
  VD=$(swift -e 'import CoreGraphics
var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
CGGetActiveDisplayList(16, &ids, &n)
for d in ids[0..<Int(n)] where CGDisplayIsBuiltin(d) != 0 { print(d) }' 2>/dev/null | head -1)
  [[ -n $VD && -n $PANEL ]] || { echo "input-latency-vm: --display builtin: no built-in panel" >&2; exit 1; }
  HZ="panel ($PANEL)"
else
# One virtual display of our own for the whole run (STANDARDS 32: created once, own serial).
"$W/vdisplay" 1440 900 "$HZ" 3600 > "$W/vd.out" 2>&1 &
VD_PID=$!
for _ in $(seq 40); do grep -qE '^(id=|display )[0-9]+' "$W/vd.out" && break; sleep 0.25; done
VD=$(grep -oE '[0-9]+' <<<"$(grep -E '^(id=|display )' "$W/vd.out" | head -1)" | head -1)
[[ -n $VD ]] || { echo "input-latency-vm: no virtual display: $(cat "$W/vd.out")" >&2; exit 1; }
sleep 2
panel_same "with the virtual display" || exit 1
fi
SKIP=$(swift -e 'import CoreGraphics
var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
CGGetActiveDisplayList(16, &ids, &n)
print(ids[0..<Int(n)].map(String.init).joined(separator: ","))' 2>/dev/null | tr ',' '\n' | grep -vx "$VD" | paste -sd, -)
[[ -n $SKIP ]] || { echo "input-latency-vm: could not list the Mac's displays" >&2; exit 1; }
echo "display $VD ($ONDISP) at $HZ Hz; left alone: $SKIP; settings: ${QENV[*]:-none}; hardware cursor: $HWC"

# --native: the macOS floor first, a plain AppKit window on the same display (nativelat.swift).
if ((NATIVE)); then
  swiftc -O "$R/tests/graphics/pacing/nativelat.swift" -o "$W/nativelat" || exit 1
  "$W/nativelat" "$VD" 60 > "$OUT/native-times.txt" 2>&1 &
  NPID=$!
  sleep 2
  for m in key pointer keymove; do
    "$W/inputlat" "$NPID" "$m" "$COUNT" "$OUT/native-$m.jsonl" | sed 's/^{/{"app":"native",/' | tee "$OUT/native-$m.summary"
  done
  kill "$NPID" 2>/dev/null
fi

RUN=$W/run; mkdir -p "$RUN"
TRACE=(-trace 'input_event_key_qcode' -trace 'input_event_abs' -trace 'virtio_gpu_cmd_res_flush'
       -trace 'virtio_gpu_update_cursor' -trace 'cocoa_present_direct' -trace 'cocoa_present_frame'
       -trace 'virtio_gpu_cmd_ctx_create' -trace 'virtio_gpu_cmd_ctx_submit'
       -trace 'cocoa_present_second' -trace 'cocoa_present_skips'
       -trace 'virtio_gpu_fence_ctrl' -trace 'virtio_gpu_fence_resp')
SMB=()
((HWC)) && { QENV+=(OMACVM_HW_CURSOR=1); SMB=(-smbios type=11,value=omacvm.hwcursor=1); }
# --app: the GPU and display part of what Runner.swift gives QEMU by default (gpuOffMainLoop,
# vkWindowsNoCopy); no sound card here, so not its audio thread.
if ((APP)); then
  QENV=(OMACVM_GPU_UNLOCKED=1 OMACVM_GL_TRIM=quarter OMACVM_VK_WINDOWS=iosurface
        ${QENV[@]+"${QENV[@]}"})
  SMB+=(-smbios type=11,value=omacvm.vkwindows=1 -smbios type=11,value=omacvm.notchpointer=1
        -smbios type=11,value=omacvm.vaexport=1)
fi
SMB+=(${XSMB[@]+"${XSMB[@]}"})
GPU="virtio-gpu-gl-pci,max_outputs=1,xres=1920,yres=1080,romfile="
[[ -n $VENUS ]] && GPU+=",blob=true,venus=true,hostmem=${VENUS}M"
echo "QEMU: $CPUS CPUs, $MEM MB, $GPU; environment: ${QENV[*]:-none}; smbios: ${XSMB[*]:-none}"
env OMACVM_PRODUCT_NAME="$NAME" OMACVM_SLIRP_HOST_PORTS=1 OMACVM_NOTCH=0 \
  OMACVM_TEST_SKIP_DISPLAYS="$SKIP" OMACVM_TEST_MAIN_DISPLAY="$VD" OMACVM_BACKGROUND=1 \
  OMACVM_TEST_POINTER=1 OMACVM_DISPLAY_SOCKET="$RUN/display" ${QENV[@]+"${QENV[@]}"} \
  "$QEMU" -name "$NAME" -machine virt,gic-version=3 -accel hvf \
  -cpu host,pmu=off -smp "$CPUS,sockets=1,cores=$CPUS,threads=1" -m "${MEM}M" -nodefaults \
  -action reboot=reset,shutdown=poweroff \
  -drive "if=pflash,format=raw,readonly=on,file=$FW" \
  -drive "if=pflash,format=raw,file=$VMD/efi-vars.fd" \
  -drive "if=none,id=disk,file=$VMD/disk.img,format=raw,cache=writeback,discard=unmap" \
  -device nvme,serial=omacvm,drive=disk,bootindex=0 \
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:22" -device virtio-net-pci,netdev=net0,romfile= \
  -device "$GPU" \
  -display "cocoa,gl=on,show-cursor=off,zoom-to-fit=on,full-screen=off,full-grab=on,immersive=off,swap-opt-cmd=off" \
  -device virtio-keyboard-pci,romfile= -device virtio-tablet-pci,romfile= \
  -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0 \
  ${SMB[@]+"${SMB[@]}"} "${TRACE[@]}" \
  -msg timestamp=on -serial none -monitor none -qmp "unix:$RUN/qmp,server=on,wait=off" \
  -device virtio-serial-pci,id=vser0 \
  -chardev "socket,id=disp0,path=$RUN/display,server=on,wait=off" \
  -device virtserialport,bus=vser0.0,nr=5,chardev=disp0,name=org.omacvm.display \
  > "$LOG" 2>&1 &
start=$(date +%s)

wait_desktop() {
  local i
  for i in $(seq 120); do
    gssh 'ls /run/user/*/hypr/*/.socket.sock' >/dev/null 2>&1 && return 0
    pgrep -f -- "$PAT" >/dev/null || { echo "QEMU exited:" >&2; tail -5 "$LOG" >&2; return 1; }
    sleep 2
  done
  return 1
}
wait_desktop || { echo "input-latency-vm: no desktop within 4 minutes" >&2; exit 1; }
echo "desktop up after $(( $(date +%s) - start )) s"
# STANDARDS 18a/25: nothing of this VM reaches the Mac (no clipboard port; Mac-link units off).
gssh 'for u in omacvm-gestures omacvm-notchcast; do systemctl disable --now $u >/dev/null 2>&1; done; true'
QPID=$(pgrep -f -- "$PAT" | head -1)

# --hw-cursor: this tree's omacvm_app.lua, then a config reload. (The VM copy needs OmacVM's
# aquamarine built and this tree's omacvm-app-host, which writes the mac-pointer.env the file reads:
# omacvm apply in a start with macPointer on, before the copy.)
if ((HWC)); then
  gssh 'source /etc/omacvm/env 2>/dev/null; U=${OMACVM_USER:-$(id -nu 1000)}
        install -o "$U" -g "$U" -m644 /dev/stdin "$(getent passwd "$U" | cut -d: -f6)/.config/hypr/omacvm_app.lua"
        X=/run/user/$(id -u "$U"); SIG=$(ls "$X/hypr" | head -1)
        grep -H . /run/omacvm/host.env
        sudo -u "$U" env XDG_RUNTIME_DIR=$X HYPRLAND_INSTANCE_SIGNATURE=$SIG hyprctl reload >/dev/null' \
    < "$R/src/app/guest/omacvm_app.lua"
  sleep 2
fi

# A terminal that fills the workspace, its cursor not blinking (the only change is the typed text).
gssh 'bash -s' <<'GUEST'
source /etc/omacvm/env 2>/dev/null
U=${OMACVM_USER:-$(id -nu 1000)}; X=/run/user/$(id -u "$U")
SIG=$(ls "$X/hypr" | head -1)
hc() { sudo -u "$U" env XDG_RUNTIME_DIR=$X HYPRLAND_INSTANCE_SIGNATURE=$SIG hyprctl "$@"; }
if command -v alacritty >/dev/null; then T="alacritty -o 'cursor.blinking=\"Never\"' -e bash --norc --noprofile"
elif command -v ghostty >/dev/null; then T="ghostty --cursor-style-blink=false -e bash --norc --noprofile"
else T="foot -o cursor.blink=no bash --norc --noprofile"; fi
echo "guest: terminal: $T"
# Started by Hyprland itself (its session's environment).
hc eval "hl.exec_cmd([[$T > /tmp/inputlat-term.log 2>&1]])" | head -2
for _ in 1 2 3 4 5 6; do
  sleep 1
  hc -j clients | grep -q '"class"' && break
done
cat /tmp/inputlat-term.log 2>/dev/null | head -5
echo "guest: $(hc -j clients | python3 -c 'import json,sys; print([c["class"] for c in json.load(sys.stdin)])')"
echo "guest: no_hardware_cursors $(hc getoption cursor:no_hardware_cursors 2>/dev/null | head -1)"
echo "guest: virtio-gpu driver: $(cat /run/omacvm/virtio-gpu 2>/dev/null || echo stock)"
GUEST
sleep 2
# --pause: S seconds with the VM up before the runs (to look at it by hand).
[[ $PAUSE =~ ^[0-9]+$ ]] && (( PAUSE > 0 )) && { echo "paused $PAUSE s (ssh port $PORT)"; sleep "$PAUSE"; }

# keybusy, qmpbusypointer: a counter in the terminal's lower right corner, written to its tty
# 125 times a second (the shell's cursor saved and put back), for the mode's run only.
busy() {   # start|stop
  if [[ $1 == start ]]; then
    gssh 'p=$(pgrep -f "^bash --norc --noprofile\$" | head -1); t=$(readlink /proc/$p/fd/0)
          [ -c "$t" ] || exit 1
          nohup bash -c "i=0; while :; do printf \"\\0337\\033[999;999H\\033[2D%02d\\0338\" \$((i++ % 100)) > $t; sleep 0.008; done" >/dev/null 2>&1 &
          echo $! > /tmp/inputlat-busy.pid' || echo "input-latency-vm: no terminal tty for the busy corner" >&2
    sleep 1
  else
    gssh 'kill $(cat /tmp/inputlat-busy.pid) 2>/dev/null; rm -f /tmp/inputlat-busy.pid' || true
  fi
}
for m in $MODES; do
  case $m in
    keybusy) busy start; REGION=0,0,0.7,0.7 "$W/inputlat" "$QPID" key "$COUNT" "$OUT/$m.jsonl" | tee "$OUT/$m.summary"; busy stop ;;
    qmpbusypointer) busy start; REGION=0,0,0.7,0.7 QMP=$RUN/qmp "$W/inputlat" "$QPID" pointer "$COUNT" "$OUT/$m.jsonl" | tee "$OUT/$m.summary"; busy stop ;;
    qmpkey) QMP=$RUN/qmp "$W/inputlat" "$QPID" key "$COUNT" "$OUT/$m.jsonl" | tee "$OUT/$m.summary" ;;
    qmppointer) QMP=$RUN/qmp "$W/inputlat" "$QPID" pointer "$COUNT" "$OUT/$m.jsonl" | tee "$OUT/$m.summary" ;;
    qmpkeymove) QMP=$RUN/qmp "$W/inputlat" "$QPID" keymove "$COUNT" "$OUT/$m.jsonl" | tee "$OUT/$m.summary" ;;
    key|pointer|keymove) "$W/inputlat" "$QPID" "$m" "$COUNT" "$OUT/$m.jsonl" | tee "$OUT/$m.summary" ;;
    *) echo "unknown mode $m" >&2 ;;
  esac
done

# The guest kernel's word on its GPU driver (warnings from the vblank timer show here).
gssh 'dmesg | grep -iE "virtio.gpu|vblank|\[drm\]" | tail -40' > "$OUT/guest-dmesg.txt" 2>&1
# Where the time goes: QEMU's trace against each event's post time and screen time.
# Stages (medians, ms): mac_to_qemu (the event posted -> QEMU's input layer),
# qemu_to_compositor (-> Hyprland's first GPU work after it: the terminal took
# the key and drew; for the pointer Hyprland draws it), split into qemu_to_client
# and client_to_compositor when the terminal draws on the GPU (foot draws on the
# CPU), compositor_to_flush (-> the frame's RESOURCE_FLUSH), flush_to_present
# (-> QEMU's present has the frame done on the Mac's GPU), present_to_screen
# (-> WindowServer shows it). The guest's GPU contexts are told apart by their
# names (the process that made them).
if ((NOBD)); then
  echo "input-latency-vm: no breakdown here (--no-breakdown); later: $0 --parse $OUT"
else
  breakdown "$OUT" "$MODES" | tee "$OUT/breakdown.json"
fi
if ((HWC)); then
  echo "QEMU, hardware cursor: $(grep -c 'virtio_gpu_update_cursor' "$LOG") cursor commands;" \
    "$(grep -oE "cocoa: the guest's pointer is the Mac's cursor now[^\"]*|omacvm-pointer: Mac cursor is [a-z' ()]*" "$LOG" | sort | uniq -c | tr '\n' ';')"
fi
echo "input-latency-vm: done (raw: $OUT)"
