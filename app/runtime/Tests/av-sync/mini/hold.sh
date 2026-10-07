#!/bin/bash
# hold.sh (ON the mini, nohup, holding the mini lock): the A/V matrix. Gives up (VM off, lock released) when a
# release lane waits. Watchdog 60 min. Then the fix (fix.sh) re-measured, when there.
cd /private/tmp/omacvm-avs; exec >> hold.log 2>&1
release() { ./vm.sh stop; grep -q '^av-sync ' ~/.omacvm-mini-vm.lock/owner 2>/dev/null && rm -rf ~/.omacvm-mini-vm.lock; echo "$(date +%T) released"; }
trap release EXIT
( sleep 3600; echo "$(date +%T) watchdog"; kill $$ ) &
prio() { grep -qE '^(release|fs-own-space)' ~/.omacvm-mini-vm.lock.wait 2>/dev/null && { echo "$(date +%T) release lane waits: stop"; exit 0; }; }
restart() { ./vm.sh stop; env "$@" ./vm.sh start || exit 1; }
mkdir -p out; ./outlat > out/outlat.txt 2>&1; cat out/outlat.txt
echo "$(date +%T) setup"; ./setup.sh || exit 1; ./vm.sh stop; prio
echo "$(date +%T) native Chrome reference"; ./native.sh native-h264 av-h264.mp4; ./native.sh native-vp9 av-vp9.webm
echo "$(date +%T) 3.0.0 default, opengl"; restart GFX=opengl
./run1.sh def-h264 av-h264.mp4; ./run1.sh def-vp9 av-vp9.webm
./run1.sh def-h264-sw av-h264.mp4 --disable-features=AcceleratedVideoDecoder
LOAD=gpu DUR=90 ./run1.sh def-h264-stall av-h264.mp4; prio
echo "$(date +%T) audioClassic, opengl"; restart GFX=opengl PACE=off QOS=default
./run1.sh classic-h264 av-h264.mp4
LOAD=gpu DUR=90 ./run1.sh classic-h264-stall av-h264.mp4; prio
echo "$(date +%T) 3.0.0 default, vulkan"; restart GFX=vulkan
./run1.sh vk-h264 av-h264.mp4; ./run1.sh vk-vp9 av-vp9.webm
prio; [ -x ./fix.sh ] && { echo "$(date +%T) the fix"; ./fix.sh; }
echo "$(date +%T) done"
