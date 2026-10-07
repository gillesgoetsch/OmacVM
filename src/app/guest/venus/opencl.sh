#!/bin/bash
# opencl.sh (as root, in an OmacVM.app VM): OpenCL on the Mac's GPU for a VM
# whose Graphics setting gives it Vulkan. The distro's rusticl (opencl-mesa)
# runs on Zink, which runs on Venus: no build, pacman installs and removes it.
# It works where the Mac's Vulkan driver is KosmicKrisp (OmacVM.app on macOS
# 26+). On MoltenVK (macOS 15) Zink refuses the device ("requires the
# nullDescriptor feature of robustness2"): there the feature vulkan's Mesa
# (venus/install.sh, with its MoltenVK patches) is the way.
#   opencl.sh          install opencl-mesa + clinfo, turn rusticl's Zink on
#   opencl.sh --off    turn it off again (the VM has OpenGL only now)
# Rusticl only lists drivers named in RUSTICL_ENABLE, so the switch is what
# gives apps the device; the package stays (pacman -Rns opencl-mesa removes it).
# Tests: src/tests/venus-driver.sh (offline).
set -euo pipefail
ENVF=${OMACVM_OPENCL_ENV:-/etc/environment.d/90-omacvm-opencl.conf}
OURS=${OMACVM_MESA_CLICD:-/etc/OpenCL/vendors/omacvm-rusticl.icd}
LOG=/var/log/omacvm-opencl.log

case ${1:-} in
  --off) rm -f "$ENVF"; exit 0 ;;
  "") ;;
  *) echo "usage: opencl.sh [--off]" >&2; exit 2 ;;
esac
# The vulkan feature's Mesa brings its own rusticl and switch.
if [[ -f $OURS ]]; then rm -f "$ENVF"; echo "OpenCL: OmacVM's Mesa (feature vulkan)"; exit 0; fi
(( EUID == 0 )) || { echo "opencl.sh: run as root" >&2; exit 1; }
"${OMACVM_PKG_ADD:-$(dirname "$0")/../../../guest/pkg-add}" opencl-mesa clinfo ||
  { echo "OpenCL: opencl-mesa not installed (see above)" >&2; exit 1; }
mkdir -p "$(dirname "$ENVF")"
echo RUSTICL_ENABLE=zink > "$ENVF"
echo "OpenCL: rusticl on Zink (Vulkan) for apps started after the next login"
