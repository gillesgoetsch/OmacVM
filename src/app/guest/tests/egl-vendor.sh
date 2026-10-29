#!/bin/bash
# OmacVM's EGL vendor library (src/app/guest/omacvm_egl.c): Mesa's EGL with the app's video imports
# handed to the VA driver shim, only when the shim is loaded; fails open (no Mesa, another glvnd
# ABI) and stays out of the compositor. Runs against stand-ins for Mesa's EGL vendor library and
# the shim (egl-vendor.c), on Linux with the EGL and glvnd headers (libegl-dev, libglvnd-dev).
#   src/app/guest/tests/egl-vendor.sh [EGL_SOURCE]
# EGL_SOURCE: another omacvm_egl.c.
set -u
here=$(cd "$(dirname "$0")" && pwd)
src=${1:-$here/../omacvm_egl.c}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
mkdir -p "$T/mesa" "$T/dri"
cc -shared -fPIC -O2 -Wall -DSTUB_MESA -o "$T/mesa/libEGL_mesa.so.0" "$here/egl-vendor.c" || exit 1
cc -shared -fPIC -O2 -Wall -DSTUB_SHIM -o "$T/dri/omacvm_drv_video.so" "$here/egl-vendor.c" || exit 1
# as install.sh builds it, with the stand-in for Mesa's library
cc -shared -fPIC -O2 -Wall -Werror -fvisibility=hidden -Wl,-soname,libEGL_omacvm.so.0 \
  -DMESA_EGL="\"$T/mesa/libEGL_mesa.so.0\"" -o "$T/libEGL_omacvm.so.0" "$src" -ldl || exit 1
cc -shared -fPIC -O2 -Wall -Werror -fvisibility=hidden -DMESA_EGL="\"$T/none/libEGL_mesa.so.0\"" \
  -o "$T/nomesa.so" "$src" -ldl || exit 1
cc -O2 -Wall -o "$T/egl-vendor" "$here/egl-vendor.c" -ldl || exit 1
cp "$T/egl-vendor" "$T/Hyprland"

# run PROGRAM LIBRARY MODE
run() {
  local out
  out=$("$1" "$2" "$T/mesa/libEGL_mesa.so.0" "$T/dri/omacvm_drv_video.so" "$3" 2>&1)
  if [[ $? == 0 ]]; then
    echo "ok: $3"
  else
    echo "FAIL: $3"; fail=1
  fi
  sed 's/^/    /' <<< "$out"
}
run "$T/egl-vendor" "$T/libEGL_omacvm.so.0" main
run "$T/egl-vendor" "$T/nomesa.so" nomesa
run "$T/egl-vendor" "$T/libEGL_omacvm.so.0" abi1
run "$T/Hyprland" "$T/libEGL_omacvm.so.0" desktop
# the library exports only glvnd's entry point
syms=$(nm -D --defined-only "$T/libEGL_omacvm.so.0" | awk '$2 == "T" { print $3 }' | tr '\n' ' ')
if [[ $syms == "__egl_Main " ]]; then echo "ok: exports only __egl_Main"
else echo "FAIL: exports $syms"; fail=1; fi

# install.sh: built in the shim's block, the library before the JSON, the JSON gone first when it
# does not build; glvnd's JSON names the library by its full path
inst=$here/../install.sh
json=$here/../10-omacvm-egl.json
lib=$(sed -n 's/.*"library_path" *: *"\([^"]*\)".*/\1/p' "$json")
if [[ $lib == /usr/local/lib/libEGL_omacvm.so.0 ]] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$json"; then
  echo "ok: 10-omacvm-egl.json names $lib"
else echo "FAIL: 10-omacvm-egl.json (library_path '$lib')"; fail=1; fi
order=$(grep -n -E 'install .*libEGL_omacvm.so.0|install .*10_omacvm.json|rm -f .*10_omacvm.json|rm -f .*libEGL_omacvm.so.0' "$inst" | cut -d: -f1 | tr '\n' ' ')
read -r a b c d <<< "$order"
if [[ -n ${d:-} ]] && (( a < b && b < c && c < d )) &&
   grep -q 'install .*libEGL_omacvm.so.0' <<< "$(sed -n "${a}p" "$inst")" &&
   grep -q 'rm -f .*10_omacvm.json' <<< "$(sed -n "${c}p" "$inst")"; then
  echo "ok: install.sh: library then JSON; when it does not build, JSON then library"
else echo "FAIL: install.sh order of the library and the JSON (lines $order)"; fail=1; fi
(( fail )) && { echo "egl-vendor: FAILED"; exit 1; }
echo "egl-vendor: all ok"
