#!/bin/bash
# Offline checks for the sound-on-a-busy-Mac change (no VM, no QEMU build):
#  - the tone glitch detector finds made-up gaps and skips (app/runtime/Tests/audio/glitches.py)
#  - the launcher, QEMU's patches and omacvm check use the same switches and log lines
#    (OMACVM_MAIN_LOOP_QOS=default, hda-micro pace=off; "main loop QoS: ...", "HDA sound pacing on|off")
#  - a Mac audio device that does not answer: the playback-thread patch is built in, its
#    log lines match omacvm check's "sound" line, the test stub builds
#  - the sound's own thread: patch pinned and placed, launcher switch, log lines and check.sh agree
#  - playback buffers the Mac's output takes (#548): the size rules pass, patches placed, the
#    launcher's size file, log lines and check.sh's "sound buffers" line agree, the stub builds
#  - the guest: RTKit's drop-in without the canary is installed, and omacvm check tells a
#    real-time PipeWire from a demoted one
# Exit 0 when every check passes.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
P=$R/app/runtime/patches/qemu-darwin-main-loop-qos.patch
RUNNER=$R/app/app/Sources/OmacVM/Runner.swift
CHECK=$R/src/cmd/check.sh
FAIL=0; N=0
ok() { N=$((N + 1)); printf '  ok    %s\n' "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

check "glitch detector finds a gap, a skip and a repeat, none in a clean tone" \
  python3 "$R/app/runtime/Tests/audio/glitches.py" --selftest
check "patch is pinned in SHA256SUMS" grep -q " qemu-darwin-main-loop-qos.patch$" "$R/app/runtime/patches/SHA256SUMS"
check "runtime build applies the patch" grep -q "patches/qemu-darwin-main-loop-qos.patch" "$R/app/runtime/build-qemu-gpu-runtime.sh"
check "patch reads OMACVM_MAIN_LOOP_QOS=default" grep -q 'getenv("OMACVM_MAIN_LOOP_QOS")' "$P"
check "launcher sets OMACVM_MAIN_LOOP_QOS=default for audioClassic" \
  grep -q 'env\["OMACVM_MAIN_LOOP_QOS"\] = "default"' "$RUNNER"
HP=$R/app/runtime/patches/qemu-hda-no-catch-up.patch
check "pacing patch is pinned in SHA256SUMS" grep -q " qemu-hda-no-catch-up.patch$" "$R/app/runtime/patches/SHA256SUMS"
check "runtime build applies the pacing patch" grep -q "patches/qemu-hda-no-catch-up.patch" "$R/app/runtime/build-qemu-gpu-runtime.sh"
check "pacing is a codec property, on by default" grep -qF 'DEFINE_PROP_BOOL("pace", HDAAudioState, pace, true)' "$HP"
check "launcher turns pacing off for audioClassic" grep -qF 'audiodev=snd0\(Settings.audioClassic ? ",pace=off" : "")' "$RUNNER"
check "pacing patch logs its state" grep -qF 'info_report("OmacVM: HDA sound pacing %s"' "$HP"
for line in "main loop QoS: user-interactive" "main loop QoS: default" "main loop QoS: default (user-interactive refused)"; do
  check "QoS patch logs '$line'" grep -qF "OmacVM: $line" "$P"
done
# check.sh's verdict for each pair of log lines QEMU can write (its own case, run here).
verdict() {   # QOS_LINE PACING_LINE -> the status check.sh prints
  local miclog TYPE=app out
  miclog=$(mktemp); printf 'OmacVM: %s\nOmacVM: %s\n' "$1" "$2" | grep -v 'OmacVM: $' > "$miclog"
  ok() { echo "ok:$2"; }; warn() { echo "warn:$2"; }
  out=$(eval "$(sed -n '/^# Sound on a busy Mac/,/^fi$/p' "$CHECK")")
  rm -f "$miclog"; echo "$out"
}
check "check.sh: QoS + pacing on is ok" grep -q "^ok:QEMU's main loop at user-interactive QoS, sound card paced" <<<"$(verdict 'main loop QoS: user-interactive' 'HDA sound pacing on')"
check "check.sh: audioClassic is ok" grep -q "^ok:QEMU's own sound timing" <<<"$(verdict 'main loop QoS: default' 'HDA sound pacing off')"
check "check.sh: refused QoS warns" grep -q "^warn:" <<<"$(verdict 'main loop QoS: default (user-interactive refused)' 'HDA sound pacing on')"
check "check.sh: an old runtime prints nothing" test -z "$(verdict '' '')"
# The sound on its own real-time thread (qemu-audio-own-thread.patch, OMACVM_AUDIO_THREAD=1).
TP=$R/app/runtime/patches/qemu-audio-own-thread.patch
MODEL=$R/app/app/Sources/OmacVM/Model.swift
check "own-thread patch is pinned in SHA256SUMS" grep -q " qemu-audio-own-thread.patch$" "$R/app/runtime/patches/SHA256SUMS"
own_line=$(grep -n 'patches/qemu-audio-own-thread.patch"' "$R/app/runtime/build-qemu-gpu-runtime.sh" | cut -d: -f1)
nap_line=$(grep -n 'patches/omacvm-cocoa-no-app-nap.patch"' "$R/app/runtime/build-qemu-gpu-runtime.sh" | cut -d: -f1)
pace_line=$(grep -n 'patches/qemu-hda-no-catch-up.patch"' "$R/app/runtime/build-qemu-gpu-runtime.sh" | cut -d: -f1)
wd_line=$(grep -n 'patches/qemu-main-loop-stall-watchdog.patch"' "$R/app/runtime/build-qemu-gpu-runtime.sh" | cut -d: -f1)
check "runtime build applies it after pacing and the stall watchdog, before the App Nap patch" \
  test -n "$own_line" -a "${own_line:-0}" -gt "${pace_line:-0}" -a "${own_line:-0}" -gt "${wd_line:-0}" -a "${own_line:-0}" -lt "${nap_line:-0}"
check "own-thread patch reads OMACVM_AUDIO_THREAD" grep -qF 'g_getenv("OMACVM_AUDIO_THREAD")' "$TP"
check "launcher sets OMACVM_AUDIO_THREAD=1 for the own thread" grep -qF 'env["OMACVM_AUDIO_THREAD"] = "1"' "$RUNNER"
check "audioMainLoop and audioClassic switch the own thread off" grep -qF 'if audioClassic || d.bool(forKey: "audioMainLoop") { return false }' "$MODEL"
for line in 'sound path: %s' 'sound: own audio thread, %s'; do
  check "own-thread patch logs '$line'" grep -qF "\"OmacVM: $line" "$TP"
done
check "the thread never takes the BQL: DMA to RAM only off the BQL" grep -qF 'bool rt = !bql_locked();' "$TP"
# Its tick follows the streams (qemu-audio-tick-follows-stream.patch), not every 1 ms.
FP=$R/app/runtime/patches/qemu-audio-tick-follows-stream.patch
check "tick-follows-stream patch is pinned in SHA256SUMS" grep -q " qemu-audio-tick-follows-stream.patch$" "$R/app/runtime/patches/SHA256SUMS"
follow_line=$(grep -n 'patches/qemu-audio-tick-follows-stream.patch"' "$R/app/runtime/build-qemu-gpu-runtime.sh" | cut -d: -f1)
check "runtime build applies it right after the own thread" test -n "$follow_line" -a "${follow_line:-0}" -gt "${own_line:-0}" -a "${follow_line:-0}" -lt "${nap_line:-0}"
check "tick-follows-stream patch logs 'sound: audio tick every'" grep -qF '"OmacVM: sound: audio tick every %' "$FP"
check "the start line stays as check.sh reads it" grep -qF '"OmacVM: sound: own audio thread, %s, every %' "$FP"
check "OMACVM_AUDIO_THREAD_PERIOD_US still fixes the period" grep -qF 'audio_rt_period_fixed = true;' "$FP"
check "the period is clamped to 1-10 ms" grep -qE '^\+#define AUDIO_RT_PERIOD_MAX \(10 \* SCALE_MS\)' "$FP"
check "a stream ticks at a quarter of its shortest DMA entry, at most B_SIZE/8" grep -qF 'bytes = MIN((int64_t)entry / 4, (int64_t)(B_SIZE / 8));' "$FP"
check "the pacing burst grows with the period" grep -qF 'burst = hda_audio_pace_burst(st, bps);' "$FP"
check "the mixer keeps two backend buffers out of its share" grep -qF 'ring <= 2 * (size_t)frames' "$FP"
check "SDL says its open device's size" grep -qF 'qatomic_set(&sdl->hw.omacvm_frames, (int)sdl->open_frames);' "$FP"
path_verdict() {   # PATH_LINE THREAD_LINE PACING_LINE -> the status check.sh prints
  local miclog TYPE=app out
  miclog=$(mktemp); printf 'OmacVM: %s\n' "$@" | grep -v 'OmacVM: $' > "$miclog"
  ok() { echo "ok:$2"; }; warn() { echo "warn:$2"; }
  out=$(eval "$(sed -n '/^# Sound on a busy Mac/,/^fi$/p' "$CHECK")")
  rm -f "$miclog"; echo "$out"
}
check "check.sh: own thread at time-constraint is ok" grep -q "^ok:sound card and mixer on their own real-time thread (time-constraint)" \
  <<<"$(path_verdict 'sound path: own audio thread' 'main loop QoS: user-interactive' 'sound: own audio thread, time-constraint, every 1000 us' 'HDA sound pacing on')"
check "check.sh: own thread before any sound is ok" grep -q "^ok:.*no sound yet this start" \
  <<<"$(path_verdict 'sound path: own audio thread' 'main loop QoS: user-interactive' 'HDA sound pacing on')"
check "check.sh: own thread without real-time priority warns" grep -q "^warn:" \
  <<<"$(path_verdict 'sound path: own audio thread' 'sound: own audio thread, default priority, every 1000 us' 'HDA sound pacing on')"
check "check.sh: the main loop path (audioMainLoop) stays as before" grep -q "^ok:QEMU's main loop at user-interactive QoS, sound card paced" \
  <<<"$(path_verdict "sound path: QEMU's main loop" 'main loop QoS: user-interactive' 'HDA sound pacing on')"
# A Mac audio device that does not answer (qemu-sdl-audio-playback-thread.patch).
PP=$R/app/runtime/patches/qemu-sdl-audio-playback-thread.patch
BUILD=$R/app/runtime/build-qemu-gpu-runtime.sh
check "playback-thread patch is pinned in SHA256SUMS" grep -q " qemu-sdl-audio-playback-thread.patch$" "$R/app/runtime/patches/SHA256SUMS"
cap_line=$(grep -n 'patches/qemu-sdl-audio-capture-thread.patch"' "$BUILD" | cut -d: -f1)
play_line=$(grep -n 'patches/qemu-sdl-audio-playback-thread.patch"' "$BUILD" | cut -d: -f1)
check "runtime build applies it after the capture-thread patch" test -n "$play_line" -a -n "$cap_line" -a "${play_line:-0}" -gt "${cap_line:-0}"
check "QEMU's start no longer opens the playback device" grep -qF -- '-    sdl->devid = sdl_open(&req, &obt, 0, sdl->device_name,' "$PP"
check "playback opens run on a helper thread" grep -qF '"sdl-out-open", sdl_out_open_thread' "$PP"
for line in "does not answer" "works again"; do
  check "playback-thread patch logs 'the Mac's audio device $line'" grep -qF "OmacVM: sound: the Mac's audio device $line" "$PP"
done
stub=$(mktemp -d)
check "the wedged-device test stub builds" clang -dynamiclib -Wall -Werror -o "$stub/aqhang.dylib" \
  "$R/app/runtime/Tests/audio/wedged-output-start.c" -framework AudioToolbox
rm -rf "$stub"
sound() {   # QEMU's log lines -> the status of check.sh's "sound" line
  local miclog TYPE=app out
  miclog=$(mktemp); printf '%s\n' "$@" > "$miclog"
  ok() { echo "ok:$2"; }; warn() { echo "warn:$2"; }
  out=$(eval "$(sed -n "/^# A Mac audio device that does not answer/,/^fi$/p" "$CHECK")")
  rm -f "$miclog"; echo "$out"
}
NA="qemu-system-aarch64: OmacVM: sound: the Mac's audio device does not answer (no start within 3 s); the VM goes on without sound"
WA="qemu-system-aarch64: info: OmacVM: sound: the Mac's audio device works again"
check "check.sh: a device that does not answer warns with the fix" grep -q "^warn:Mac audio device not answering.*killall coreaudiod" <<<"$(sound "$NA")"
check "check.sh: one that works again is ok" grep -q "^ok:.*works again" <<<"$(sound "$NA" "$WA")"
check "check.sh: stuck again after that warns" grep -q "^warn:" <<<"$(sound "$NA" "$WA" "$NA")"
check "check.sh: a run without either line prints nothing" test -z "$(sound "OmacVM: HDA sound pacing on")"
# Playback buffers the Mac's output takes (#548: AirPods refused the own thread's 256-frame queue).
SP=$R/app/runtime/patches/qemu-sdl-audio-out-size.patch
SL=$R/app/runtime/patches/qemu-sdl-audio-out-size-logic.patch
for f in qemu-sdl-audio-out-size-logic.patch qemu-sdl-audio-out-size.patch; do
  check "$f is pinned in SHA256SUMS" grep -q " $f\$" "$R/app/runtime/patches/SHA256SUMS"
done
size_line=$(grep -n 'patches/qemu-sdl-audio-out-size.patch"' "$BUILD" | cut -d: -f1)
logic_line=$(grep -n 'patches/qemu-sdl-audio-out-size-logic.patch"' "$BUILD" | cut -d: -f1)
check "runtime build applies the size rules, then their wiring, after the playback-thread patch" \
  test -n "$size_line" -a -n "$logic_line" -a "${logic_line:-0}" -gt "${play_line:-0}" -a "${size_line:-0}" -gt "${logic_line:-0}"
check "runtime build checks the wiring" grep -qF 'Tests/audio/test-out-size.sh" "$source_dir/audio/sdlaudio.c"' "$BUILD"
check "the size rules pass their test" "$R/app/runtime/Tests/audio/test-out-size.sh"
check "QEMU reads the launcher's size file" grep -qF 'g_getenv("OMACVM_AUDIO_OUT_FRAMES_FILE")' "$SP"
check "the launcher hands QEMU the size file" grep -qF 'env["OMACVM_AUDIO_OUT_FRAMES_FILE"] = audioFramesFile' "$RUNNER"
check "the launcher picks the sound options for a wireless output at the start" \
  grep -qF 'Runner.audiodev(thread: audioThread, wireless: audioWireless, mic: Runner.micAllowed)' "$RUNNER"
for line in "playback buffers: %u frames" "the Mac's output did not start with" "the Mac's output refused every buffer" "the Mac's output changed: playback"; do
  check "out-size patch logs '$line'" grep -qF "OmacVM: sound: $line" "$SP"
done
# After every size was refused QEMU waits for a new size file: the app writes one after a coreaudiod restart (#569).
ALW=$R/app/app/Sources/OmacVM/AudioLatencyWatch.swift
check "the app listens for coreaudiod restarts" \
  grep -qF 'var r = Self.address(kAudioHardwarePropertyServiceRestarted)' "$ALW"
check "... adds the listener in start() and removes it in stop()" test "$(grep -cE 'AudioObject(Add|Remove)PropertyListenerBlock\(AudioObjectID\(kAudioObjectSystemObject\), &r, self.queue, self.restarted\)' "$ALW")" = 2
check "... and its handler writes the size file anew" \
  test -n "$(sed -n '/private func serviceRestarted()/,/^    }/p' "$ALW" | grep -F 'sizeFile.serviceRestarted()')"
check "the size file follows AudioSizeFile's rule" grep -qF 'sizeFile.needsWrite(minimum: minimum, device: id)' "$ALW"
stub=$(mktemp -d)
check "the refusing-start test stub builds" clang -dynamiclib -Wall -Werror -o "$stub/aqrefuse.dylib" \
  "$R/app/runtime/Tests/audio/refuse-small-start.c" -framework AudioToolbox
rm -rf "$stub"
buffers() {   # QEMU's log lines -> the status of check.sh's "sound buffers" line
  local miclog TYPE=app out
  miclog=$(mktemp); printf '%s\n' "$@" > "$miclog"
  ok() { echo "ok:$2"; }; warn() { echo "warn:$2"; }
  out=$(eval "$(sed -n "/^# Playback buffers the Mac's output takes/,/^fi$/p" "$CHECK")")
  rm -f "$miclog"; echo "$out"
}
OWN="qemu-system-aarch64: info: OmacVM: sound: playback buffers: 256 frames (the sound path's own)"
REF="qemu-system-aarch64: OmacVM: sound: the Mac's output did not start with 256-frame buffers (CoreAudio error (AudioQueueStart): -66681); trying 512 frames"
GOT="qemu-system-aarch64: info: OmacVM: sound: playback buffers: 512 frames (the Mac's output refused 256)"
ALL="qemu-system-aarch64: OmacVM: sound: the Mac's output refused every buffer size up to 512 frames; the VM goes on without sound"
WLS="OmacVM: sound: the Mac's output is wireless: the main loop path's queue on the own thread (44.1 kHz, 512 frames)"
check "check.sh: the path's own size is ok" grep -q "^ok:256 frames (the sound path's own)" <<<"$(buffers "$OWN")"
check "check.sh: a refused size that played larger is ok and says so" grep -q "^ok:512 frames (the Mac's output refused 256)" <<<"$(buffers "$OWN" "$REF" "$GOT")"
check "check.sh: every size refused warns with the way out" grep -q "^warn:.*restart the VM while it is connected" <<<"$(buffers "$OWN" "$REF" "$ALL")"
check "check.sh: every size refused after a wireless start does not advise a restart" \
  grep -q "^warn:.*started with the wireless output's buffers, a restart does not change them" <<<"$(buffers "$WLS" "$ALL")"
lacks() { ! grep -q "$1" <<<"$2"; }
check "check.sh: ... and not the restart of a wired start" lacks "restart the VM while" "$(buffers "$WLS" "$ALL")"
check "check.sh: playing again after that is ok" grep -q "^ok:512" <<<"$(buffers "$ALL" "$GOT")"
check "check.sh: a run without the lines prints nothing" test -z "$(buffers "OmacVM: HDA sound pacing on")"
# The guest: RTKit keeps PipeWire real-time after the VM was stopped (src/guest/sound/rtkit-no-canary.conf).
NC=$R/src/guest/sound/rtkit-no-canary.conf
GI=$R/src/guest/install.sh
GC=$R/src/guest/check.sh
check "RTKit drop-in clears ExecStart, then starts it without the canary" \
  test "$(grep '^ExecStart=' "$NC" | tr '\n' ' ')" = "ExecStart= ExecStart=/usr/lib/rtkit-daemon --no-canary "
check "guest install puts the drop-in under rtkit-daemon.service.d" \
  grep -qF 'install -Dm644 "$R/guest/sound/rtkit-no-canary.conf" /etc/systemd/system/rtkit-daemon.service.d/' "$GI"
rt_awk=$(grep -o "awk '\$2 ~ /^data-loop/[^']*'" "$GC")
prio() { eval "$rt_awk" && echo rt || echo normal; }   # ps -L -o cls=,comm= lines -> rt | normal
check "check.sh: a real-time data loop is ok" test "$(printf 'TS pipewire\nTS module-rt\nRR data-loop.0\n' | prio)" = rt
check "check.sh: a demoted data loop is not" test "$(printf 'TS pipewire\nTS module-rt\nTS data-loop.0\n' | prio)" = normal
check "check.sh: a real-time thread that is not the data loop does not count" test "$(printf 'RR pipewire\nTS data-loop.0\n' | prio)" = normal
echo "audio-timing: $((N - FAIL))/$N ok"
exit $(( FAIL > 0 ))
