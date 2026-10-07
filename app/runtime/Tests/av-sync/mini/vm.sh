#!/bin/bash
# vm.sh start|stop|pid|log|qmp|ssh CMD|hexec CMD: the av-sync test VM on the Mac mini.
# Plain QEMU from a COPY of the OmacVM Test.app runtime (= v3.0.0's runtime) with the app's 3.0.0 options,
# real sound (SDL, the Mac's default output), full screen.
# Env: GFX opengl|vulkan (default opengl), PACE on|off (off = audioClassic's pace=off),
#      QOS ui|default (default = audioClassic's OMACVM_MAIN_LOOP_QOS=default), XRES/YRES.
set -u
W=/private/tmp/omacvm-avs
VM="OmacVM M-avs"; PORT=52493; KEY=$HOME/.ssh/omacvm
RT=$W/rt/runtime; FW=$W/rt/firmware/edk2-aarch64-code.fd
D="$HOME/omacvm-avs-vms/$VM"
SSH=(ssh -i "$KEY" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15
     -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1)
qpid() { pgrep -f "omacvm-avs/rt/runtime/bin/OmacVM -name $VM -machine" | head -1; }
case ${1:-} in
start)
  [ -n "$(qpid)" ] && { echo "already running"; exit 0; }
  GPUX=""; [[ ${GFX:-opengl} == vulkan ]] && GPUX=",blob=true,venus=true,hostmem=4G"
  HDA="hda-micro,bus=hda0.0,audiodev=snd0"; [[ ${PACE:-on} == off ]] && HDA="$HDA,pace=off"
  ENVX=(); [[ ${QOS:-ui} == default ]] && ENVX=(OMACVM_MAIN_LOOP_QOS=default)
  mkdir -p "$W/run" "$D/logs"
  [ -s "$D/logs/qemu-avs.log" ] && mv "$D/logs/qemu-avs.log" "$D/logs/qemu-avs.prev.log"
  echo "$(date +%T) start GFX=${GFX:-opengl} PACE=${PACE:-on} QOS=${QOS:-ui}" >> "$W/runs.log"
  env ${ENVX[@]+"${ENVX[@]}"} OMACVM_PRODUCT_NAME="$VM" OMACVM_NOTCH=0 nohup "$RT/bin/OmacVM" -name "$VM" \
    -machine virt,gic-version=3 -accel hvf -cpu host,pmu=off -smp 8,sockets=1,cores=8,threads=1 -m 8192M -nodefaults \
    -action reboot=reset,shutdown=poweroff \
    -drive "if=pflash,format=raw,readonly=on,file=$FW" -drive "if=pflash,format=raw,file=$D/efi-vars.fd" \
    -drive "if=none,id=disk,file=$D/disk.img,format=raw,cache=writeback,discard=unmap" \
    -device nvme,serial=omacvm,drive=disk,bootindex=0 \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:22" -device virtio-net-pci,netdev=net0,romfile= \
    -device "virtio-gpu-gl-pci,max_outputs=1,xres=${XRES:-1920},yres=${YRES:-1080},romfile=$GPUX" \
    -display "cocoa,gl=on,show-cursor=off,zoom-to-fit=on,full-screen=on,full-grab=on,immersive=on,swap-opt-cmd=off" \
    -device virtio-keyboard-pci,romfile= -device virtio-tablet-pci,romfile= \
    -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0 \
    -device virtio-balloon-pci,free-page-reporting=on \
    -audiodev sdl,id=snd0,timer-period=1000,out.buffer-count=8,in.voices=0 \
    -device intel-hda,id=hda0,romfile= -device "$HDA" \
    -msg timestamp=on -serial none -monitor none -qmp "unix:$W/run/qmp,server=on,wait=off" \
    -trace hda_audio_pace_forgive -trace hda_audio_full_recovery -trace audio_timer_delayed \
    > "$D/logs/qemu-avs.log" 2>&1 &
  sleep 2; [ -z "$(qpid)" ] && { echo "QEMU exited"; tail -5 "$D/logs/qemu-avs.log"; exit 1; }
  for _ in $(seq 100); do
    "${SSH[@]}" "ls /run/user/1000/hypr/*/.socket.sock" >/dev/null 2>&1 && { sleep 8; echo "session up"; exit 0; }
    [ -z "$(qpid)" ] && { echo "QEMU exited"; tail -5 "$D/logs/qemu-avs.log"; exit 1; }
    sleep 3
  done
  echo "timeout waiting for the session"; exit 1 ;;
stop)
  [ -z "$(qpid)" ] && exit 0
  "${SSH[@]}" systemctl poweroff >/dev/null 2>&1
  for _ in $(seq 60); do [ -z "$(qpid)" ] && exit 0; sleep 1; done
  kill "$(qpid)" 2>/dev/null; sleep 3; exit 0 ;;
pid) qpid ;;
log) echo "$D/logs/qemu-avs.log" ;;
ssh) shift; exec "${SSH[@]}" "$@" ;;
hexec)  # run a command inside the Hyprland session (the user's environment), detached
  shift; q=$(printf '%q ' "$@"); qq=$(printf '%q' "$q")
  exec "${SSH[@]}" "U=\$(stat -c %U /run/user/1000); SIG=\$(ls -t /run/user/1000/hypr | head -1);
    E=\"XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=\$SIG DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus\";
    r=\$(sudo -u \$U env \$E hyprctl dispatch exec $qq 2>&1);
    if [ \"\$r\" != ok ]; then echo \"hyprctl: \$r (fallback)\"; sudo -u \$U env \$E nohup sh -c $qq >/dev/null 2>&1 & fi; echo started" ;;
*) echo "usage: vm.sh start|stop|pid|log|ssh CMD|hexec CMD"; exit 2 ;;
esac
