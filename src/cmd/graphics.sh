#!/bin/bash
# omacvm graphics: OmacVM.app's Graphics setting of a VM.
#   omacvm graphics --vm NAME                     the setting, what it gives on this Mac
#   omacvm graphics --vm NAME opengl|vulkan|auto  change it (from the VM's next start)
#   --json   the setting as JSON (after a change: "changed": true)
#   --yes    never ask (the control centre's job)
# OpenGL: the VM's apps draw with OpenGL on the Mac's GPU (virgl). Vulkan: the
# same plus Vulkan on the Mac's GPU (Venus: KosmicKrisp on macOS 26 and newer
# when the app has it, else MoltenVK), once the VM has its Venus driver (until
# then OpenGL). Automatic: OpenGL on every Mac in 3.0.0. A running VM with
# Vulkan ahead builds its Venus driver now.
# Exit codes: 0 done, 1 failed, 2 usage.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
source "$R/src/lib/features.sh"
source "$R/src/lib/graphics.sh"
VM=""; TYPE=app; SET=""; JSON=0
usage() { echo "omacvm graphics: $*" >&2; exit 2; }
while (( $# )); do
  case $1 in
    --vm) [[ $# -ge 2 ]] || usage "--vm needs a name"; VM=$2; shift 2 ;;
    --vm-type) [[ $# -ge 2 ]] || usage "--vm-type needs a value"; TYPE=$2; shift 2 ;;
    --json) JSON=1; shift ;;
    --yes|-y) shift ;;
    -h|--help) sed -n '2,13s/^# \{0,1\}//p' "$0"; exit 0 ;;
    opengl|vulkan|auto) [[ -z $SET ]] || usage "one setting"; SET=$1; shift ;;
    *) usage "unknown option $1 (see --help)" ;;
  esac
done
[[ -n $VM ]] || usage "which VM? --vm NAME (omacvm vms lists them)"
[[ $TYPE == app ]] || usage "Graphics is OmacVM.app's setting (Parallels, UTM and VMware Fusion have their own)"
d=$(app_dir "$VM") || usage "no OmacVM.app VM named '$VM' (omacvm vms lists them)"

CHANGED=false; NOTE=""
# A choice made by hand tries Vulkan again after the app fell back (as the app does).
if [[ -n $SET ]] && graphics_fallback "$d" >/dev/null; then
  rm -f "$d/graphics-fallback"; CHANGED=true; NOTE="Vulkan is tried again from the VM's next start"
fi
if [[ -n $SET && $SET != "$(graphics_choice "$d")" ]]; then
  printf '%s\n' "$SET" > "$d/graphics.new" && mv -f "$d/graphics.new" "$d/graphics" ||
    die "could not write $d/graphics"
  CHANGED=true
  NOTE="from the VM's next start"
fi
# A running VM that gets Vulkan builds its Venus driver now (also when the
# setting stays: the control centre's repair).
if [[ -n $SET && $(graphics_wants "$d") == vulkan ]] && { $CHANGED || [[ ! -e $d/venus-ready ]]; }; then
  if ip=$(app_ip "$VM"); then
    vm_pin "$VM" app
    if (( ! JSON )); then log "the VM's Vulkan driver (the first time a few minutes)"; fi
    if gssh "$ip" "sed -i '/^OMACVM_GRAPHICS=/d' /etc/omacvm/env && echo OMACVM_GRAPHICS=vulkan >> /etc/omacvm/env &&
                   /usr/local/share/omacvm/app/guest/venus/vulkan-virtio.sh --want" < /dev/null >&2; then
      : > "$d/venus-ready"
      # OpenCL on it (an older guest side has no opencl.sh: omacvm apply brings it).
      gssh "$ip" "f=/usr/local/share/omacvm/app/guest/venus/opencl.sh; [ ! -x \$f ] || \$f" < /dev/null >&2 ||
        NOTE="${NOTE:+$NOTE; }OpenCL is not set up (see /var/log/omacvm-opencl.log in the VM)"
    else
      rm -f "$d/venus-ready"
      NOTE="${NOTE:+$NOTE; }its Vulkan driver did not build (the VM tries again at each start)"
    fi
  fi
fi

choice=$(graphics_choice "$d"); next=$(graphics_next_start "$d")
last=$(sed -n 's/^OmacVM: graphics: //p' "$d/logs/qemu.log" 2>/dev/null | tail -1) || last=""
ready=false; [[ -e $d/venus-ready ]] && ready=true
waiting=false; graphics_waiting_for_driver "$d" && waiting=true
summary=$(graphics_summary "$d")
if (( JSON )); then
  printf '{"vm": %s, "type": "app", "graphics": "%s", "title": "%s", "next_start": "%s", "summary": %s, "driver_ready": %s, "waiting_for_driver": %s, "this_start": %s, "changed": %s%s}\n' \
    "$(json_str "$VM")" "$choice" "$(graphics_title "$choice")" "$next" "$(json_str "$summary")" "$ready" "$waiting" \
    "$(json_str "$last")" "$CHANGED" "$([[ -n $NOTE ]] && printf ', "note": %s' "$(json_str "$NOTE")")"
else
  echo "'$VM': Graphics $(graphics_title "$choice")${NOTE:+ ($NOTE)}"
  echo "  next start: $summary"
  [[ -z $last ]] || echo "  last start: $last"
  [[ -n $SET ]] || echo "Change with: omacvm graphics --vm \"$VM\" opengl|vulkan|auto"
fi
