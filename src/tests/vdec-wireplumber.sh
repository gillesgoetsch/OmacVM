#!/bin/bash
# Sound keeps working when WirePlumber meets Chromium's video decoder
# (omacvm-vdec) while no omacvm-vdecd is ready to open it: the module loaded
# while the desktop runs (omacvm apply turns Chromium video on, or builds it
# once a new kernel's headers are there), or WirePlumber starting while the
# daemon still waits for the GPU. A kernel update alone does not do it: DKMS
# builds the module during the update and it loads early at the next start.
# WirePlumber 0.5 hung on that V4L2 device and linked no sound;
# 50-omacvm-vdec.conf has it leave the decoder alone. And the decoder's
# device starts omacvm-vdecd when it comes late (70-omacvm-vdec.rules).
#   src/tests/vdec-wireplumber.sh                  offline: the rule matches the
#                                                  module's device, install.sh
#                                                  puts it in place before it
#                                                  loads the module, restarts
#                                                  WirePlumber once and not during
#                                                  a call, off removes it; the
#                                                  device starts the daemon
#   src/tests/vdec-wireplumber.sh --vm NAME [--vm-type TYPE]
#                                                  in a running OmacVM.app VM with
#                                                  chromium-video on and the user
#                                                  logged in: the decoder unloaded,
#                                                  WirePlumber started again, the
#                                                  decoder loaded without its
#                                                  daemon; a stream must be linked
#                                                  to the sound card before and
#                                                  after, and after WirePlumber
#                                                  starts again with the decoder
#                                                  there (the order at a VM start);
#                                                  loaded again, the device
#                                                  starts the daemon by itself
#   src/tests/vdec-wireplumber.sh --in-vm          the same, as root inside the VM
# Exits 1 when a check fails.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

in_vm() {
  source /etc/omacvm/env
  local U=$OMACVM_USER uid daemon
  uid=$(id -u "$U")
  us() { runuser -u "$U" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
           DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" "$@"; }
  [[ -f /etc/systemd/system/omacvm-vdecd.service ]] || { echo "skip: chromium-video is not set up in this VM"; return 0; }
  us systemctl --user is-active -q wireplumber || { bad "WirePlumber does not run: log in to the VM first"; return; }
  # A silent stream for 4 s; linked = pw-dump has a link from it to an
  # Audio/Sink node.
  linked() {
    local p
    # (Not linked, it never drains: timeout ends it.)
    head -c 768000 /dev/zero | us timeout 6 pw-play --raw --format s16 --rate 48000 --channels 2 \
      -P '{ node.name = "omacvm-wp-test" }' - & p=$!
    sleep 2
    us pw-dump | python3 -c '
import json, sys
d = json.load(sys.stdin)
nodes = {o["id"]: o["info"]["props"] for o in d if o.get("type") == "PipeWire:Interface:Node"}
me = [i for i, p in nodes.items() if p.get("node.name") == "omacvm-wp-test"]
to = [o["info"]["input-node-id"] for o in d if o.get("type") == "PipeWire:Interface:Link"
      and o["info"]["output-node-id"] in me]
sinks = [nodes.get(i, {}).get("node.name", "?") for i in to if nodes.get(i, {}).get("media.class") == "Audio/Sink"]
print(sinks[0] if sinks else "")'
    wait "$p" 2>/dev/null
  }
  daemon=$(systemctl is-active omacvm-vdecd)
  systemctl stop omacvm-vdecd
  if [[ -e /sys/module/omacvm_vdec ]] && ! modprobe -r omacvm_vdec 2>/dev/null; then
    [[ $daemon == active ]] && systemctl start omacvm-vdecd
    echo "skip: an app has the decoder open (close Chromium's videos)"; return 0
  fi
  # The decoder without its daemon: the device would start it now
  # (70-omacvm-vdec.rules), so a runtime drop-in holds it down meanwhile.
  local hold=/run/systemd/system/omacvm-vdecd.service.d/zz-vdec-wireplumber-test.conf
  mkdir -p "${hold%/*}"
  printf '[Unit]\nConditionPathExists=/run/omacvm-vdec-test-never\n' > "$hold"
  # shellcheck disable=SC2064
  trap "rm -f '$hold'; systemctl daemon-reload" EXIT
  systemctl daemon-reload
  us systemctl --user restart wireplumber; sleep 2
  local s; s=$(linked)
  if [[ -n $s ]]; then ok "sound linked without the decoder ($s)"; else bad "sound not linked even without the decoder"; fi
  modprobe omacvm_vdec; udevadm settle 2>/dev/null; sleep 2
  s=$(linked)
  if [[ -n $s ]]; then ok "sound linked after the decoder came without its daemon ($s)"
  else bad "sound not linked after the decoder came: WirePlumber hangs on /dev/video* (is /etc/wireplumber/wireplumber.conf.d/50-omacvm-vdec.conf there?)"; fi
  # The order at a VM start: WirePlumber starts while the decoder is there
  # and its daemon is not ready yet (still starting, or waiting for the GPU).
  us systemctl --user restart wireplumber; sleep 2
  s=$(linked)
  if [[ -n $s ]]; then ok "sound linked when WirePlumber starts with the decoder there and no daemon ($s)"
  else bad "sound not linked when WirePlumber starts with the decoder there and no daemon (is /etc/wireplumber/wireplumber.conf.d/50-omacvm-vdec.conf there?)"; fi
  # Late again, now free to start: nobody but the device starts the daemon.
  rm -f "$hold"; systemctl daemon-reload
  systemctl stop omacvm-vdecd 2>/dev/null
  modprobe -r omacvm_vdec 2>/dev/null
  modprobe omacvm_vdec; udevadm settle 2>/dev/null
  local i st=inactive
  for ((i = 0; i < 20; i++)); do
    st=$(systemctl is-active omacvm-vdecd); [[ $st == active ]] && break; sleep 1
  done
  if [[ $st == active ]]; then
    for ((i = 0; i < 20; i++)); do [[ -s /run/omacvm-vdec/status ]] && break; sleep 1; done
    ok "the decoder's device started omacvm-vdecd ($( [[ -s /run/omacvm-vdec/status ]] && echo "ready: $(tr '\n' ' ' < /run/omacvm-vdec/status)" || echo "not ready within 20 s"))"
  else bad "omacvm-vdecd not started when the decoder came ($st; is TAG+=\"systemd\" in /etc/udev/rules.d/70-omacvm-vdec.rules?)"; fi
  [[ $daemon == active || $daemon == activating ]] && systemctl start omacvm-vdecd
  return 0
}

offline() {
  local G=$R/src/vdec/guest conf drv inst on_line wp_line mod_line
  conf=$G/50-omacvm-vdec.conf; inst=$G/install.sh
  drv=$(sed -n 's/^#define DRV "\(.*\)"$/\1/p' "$G/module/omacvm-vdec.c")
  # udev's ID_PATH of a platform device registered with id -1 = platform-<name>.
  if grep -q 'platform_device_register_simple(DRV, -1,' "$G/module/omacvm-vdec.c" &&
     grep -q "device.bus-path = \"platform-$drv\"" "$conf"; then
    ok "the rule matches the module's device (platform-$drv)"
  else bad "50-omacvm-vdec.conf does not match the module's device (platform-$drv)"; fi
  if grep -q 'device.disabled = true' "$conf"; then ok "the rule disables the device in WirePlumber"
  else bad "the rule does not set device.disabled"; fi
  grep -q '^WP=/etc/wireplumber/wireplumber.conf.d/50-omacvm-vdec.conf$' "$inst" &&
    ok "installed into WirePlumber's system folder" || bad "install.sh: WP= is not /etc/wireplumber/wireplumber.conf.d/50-omacvm-vdec.conf"
  on_line=$(grep -n 'install -Dm644 50-omacvm-vdec.conf "\$WP"' "$inst" | head -1 | cut -d: -f1)
  wp_line=$(grep -n '&& ! wp_restart; then$' "$inst" | head -1 | cut -d: -f1)
  mod_line=$(grep -n '^ *modprobe omacvm_vdec' "$inst" | head -1 | cut -d: -f1)
  if [[ -n $on_line && -n $wp_line && -n $mod_line ]] && (( on_line < wp_line && wp_line < mod_line )); then
    ok "install.sh puts the rule in place and restarts WirePlumber before it loads the module"
  else bad "install.sh must install the rule and run wp_restart before 'modprobe omacvm_vdec' (lines ${on_line:-none}, ${wp_line:-none}, ${mod_line:-none})"; fi
  grep -q 'try-restart wireplumber.service' "$inst" &&
    ok "a running WirePlumber is started again with the rule" || bad "install.sh does not restart a running WirePlumber"
  # Once: only when the rule is new; never during a call (in_call before it).
  if grep -q '^if ! cmp -s 50-omacvm-vdec.conf "\$WP"; then$' "$inst" &&
     sed -n '/^wp_restart() {$/,/^}$/p' "$inst" | grep -q '(( wp_new )) || return 0' &&
     sed -n '/^wp_restart() {$/,/^}$/p' "$inst" | grep -q 'in_call && return 1'; then
    ok "WirePlumber restarts only for a new rule, not during a call"
  else bad "install.sh: wp_restart must restart only for a new rule (wp_new) and not during a call (in_call)"; fi
  local rule=$G/70-omacvm-vdec.rules line
  line=$(grep -v '^#' "$rule" | grep 'KERNEL=="omacvm-vdec"')
  if [[ $line == *'SUBSYSTEM=="misc"'* && $line == *'TAG+="systemd"'* &&
        $line == *'ENV{SYSTEMD_WANTS}+="omacvm-vdecd.service"'* ]] &&
     grep -q "^ConditionPathExists=/dev/$drv$" "$G/omacvm-vdecd.service"; then
    ok "the decoder's device (/dev/$drv, misc) starts omacvm-vdecd when it comes"
  else bad "70-omacvm-vdec.rules: the misc device $drv must start omacvm-vdecd (TAG+=\"systemd\", SYSTEMD_WANTS)"; fi
  # off removes it: the rm list of the off branch names $WP.
  if sed -n '/^if \[\[ \$ON == off \]\]/,/^fi$/p' "$inst" | grep -q '"\$WP"'; then ok "off removes the rule"
  else bad "off does not remove the rule"; fi
}

case ${1:-} in
  "") offline ;;
  --in-vm) in_vm ;;
  --vm)
    # VM and TYPE are read by resolve_vm.
    VM=${2:-}
    # shellcheck disable=SC2034
    if [[ ${3:-} == --vm-type ]]; then TYPE=${4:-}; else TYPE=""; fi
    [[ -n $VM ]] || { sed -n '11,32s/^# \{0,1\}//p' "$0" >&2; exit 2; }
    source "$R/src/lib/mac.sh"
    source "$R/src/lib/vm.sh"
    resolve_vm
    [[ -n $IP ]] || { echo "vdec-wireplumber: '$VM' is not running" >&2; exit 1; }
    gssh "$IP" "bash -s -- --in-vm" < "$0"; exit $? ;;
  *) sed -n '11,32s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
esac
exit $fail
