#!/bin/bash
# omacvm check's "Ghostty" line (src/guest/check.sh, ghostty_line), OmacVM.app VMs: Ghostty needs
# OpenGL 4.3, the VM's GPU gives 4.1, so OmacVM's EGL vendor library starts it alone on Mesa's CPU
# renderer (ADR 0064). No line without Ghostty; ok with glvnd's file and a library that has that
# part, naming the screensaver's offs; FAIL (Ghostty opens no window) without the file, without the
# library or with a library from before this change. With a C compiler and the EGL and glvnd headers
# (Linux: libegl-dev, libglvnd-dev) also the library built from src/app/guest/omacvm_egl.c as
# install.sh builds it. The function is taken from check.sh as it is.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
check="$here/../guest/check.sh"
egl="$here/../app/guest/omacvm_egl.c"
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-ghostty-check.XXXXXX")
trap 'rm -rf "$T"' EXIT
awk '/^ghostty_line\(\) \{/ {on=1} on {print} on && /^}$/ {exit}' "$check" > "$T/fn.sh"
[[ -s $T/fn.sh ]] || { echo "FAIL: no ghostty_line in check.sh"; exit 1; }
# shellcheck disable=SC1091
source "$T/fn.sh"
fail=0
expect() {   # what, installed (1/0), json, library, want status ("" = no line), want text in the detail
  local got; got=$(ghostty_line "$2" "$3" "$4")
  if [[ ${got%%$'\t'*} == "$5" && $got == *"$6"* ]]; then echo "ok   $1"
  else echo "FAIL $1: got '$got', want '$5' with '$6'"; fail=1; fi
}
echo '{"ICD": {"library_path": "/usr/local/lib/libEGL_omacvm.so.0"}}' > "$T/10_omacvm.json"
# stand-ins: a library with the Ghostty part names the variable it sets; an older one does not
printf 'ELF\0__egl_Main\0eglInitialize\0LIBGL_ALWAYS_SOFTWARE\0' > "$T/new.so"
printf 'ELF\0__egl_Main\0eglCreateImageKHR\0omacvm_va_dmabuf_imported_v1\0' > "$T/old.so"
expect "Ghostty not installed: no line" 0 "$T/10_omacvm.json" "$T/new.so" "" ""
expect "Ghostty not installed, no library: no line" 0 "$T/none.json" "$T/none.so" "" ""
expect "the library with the Ghostty part: ok, on the CPU, with the GPU-drawn terminals" 1 "$T/10_omacvm.json" "$T/new.so" ok "draws on the VM's CPU"
expect "ok names Alacritty and Kitty" 1 "$T/10_omacvm.json" "$T/new.so" ok "Alacritty and Kitty draw on the Mac's GPU"
expect "ok says the screensaver draws on the CPU too" 1 "$T/10_omacvm.json" "$T/new.so" ok "Omarchy's screensaver draws on the CPU too"
expect "ok names the screensaver's offs" 1 "$T/10_omacvm.json" "$T/new.so" ok "(off: omarchy-toggle-screensaver or omacvm enable no-idle-lock)"
expect "a library from before this change: FAIL, no window, omacvm apply" 1 "$T/10_omacvm.json" "$T/old.so" fail "opens no window"
expect "a library from before this change: FAIL says omacvm apply and the logout" 1 "$T/10_omacvm.json" "$T/old.so" fail "omacvm apply, then log out and in"
expect "no library (it did not build): FAIL with the workaround" 1 "$T/10_omacvm.json" "$T/none.so" fail "LIBGL_ALWAYS_SOFTWARE=1 ghostty"
expect "no glvnd file (glvnd skips the library): FAIL" 1 "$T/none.json" "$T/new.so" fail "opens no window"
# the real library, built as install.sh builds it
if command -v cc >/dev/null && cc -shared -fPIC -O2 -fvisibility=hidden -Wl,-soname,libEGL_omacvm.so.0 \
     -o "$T/built.so" "$egl" -ldl 2>/dev/null; then
  expect "the library built from omacvm_egl.c: ok" 1 "$T/10_omacvm.json" "$T/built.so" ok "draws on the VM's CPU"
else
  echo "skip the library built from omacvm_egl.c (no C compiler or no EGL/glvnd headers here)"
fi
grep -q 'ok "Ghostty"' "$check" && grep -q 'bad "Ghostty"' "$check" &&
  grep -q 'ghostty_line "$gi" /etc/glvnd/egl_vendor.d/10_omacvm.json /usr/local/lib/libEGL_omacvm.so.0' "$check" ||
  { echo "FAIL: check.sh does not use ghostty_line for its \"Ghostty\" line"; fail=1; }
(( fail == 0 )) && echo "ghostty-check: all passed"
exit $fail
