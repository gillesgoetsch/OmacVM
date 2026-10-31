#!/bin/bash
# omacvm check's "Ghostty" line (src/guest/check.sh, ghostty_line), OmacVM.app VMs: Ghostty needs
# OpenGL 4.3, the VM's GPU gives 4.1, so OmacVM's EGL vendor library starts it alone on Mesa's CPU
# renderer, or on Zink over Venus when the app asks for it (ADR 0064). No line without Ghostty; ok
# with glvnd's file and a library that has that part, naming the screensaver's offs; FAIL (Ghostty
# opens no window) without the file, without the library or with a library from before 3.2.14.
# With the app's marker (OMACVM_GLZINK=1): the next Ghostty on the Mac's GPU, WARN with an older
# library (Update VM) or after a lost Venus context (gl-zink-off); a running Ghostty's record
# (ghostty_running: only a live process named ghostty) says what Mesa took: zink ok, a fallback
# WARN. With a C compiler and the EGL and glvnd headers (Linux: libegl-dev, libglvnd-dev) also the
# library built from src/app/guest/omacvm_egl.c as install.sh builds it. The functions are taken
# from check.sh as they are.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
check="$here/../guest/check.sh"
egl="$here/../app/guest/omacvm_egl.c"
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-ghostty-check.XXXXXX")
trap 'rm -rf "$T"' EXIT
awk '/^ghostty_line\(\) \{/ || /^ghostty_running\(\) \{/ {on=1} on {print} on && /^}$/ {on=0}' "$check" > "$T/fn.sh"
grep -q '^ghostty_line()' "$T/fn.sh" && grep -q '^ghostty_running()' "$T/fn.sh" ||
  { echo "FAIL: no ghostty_line or ghostty_running in check.sh"; exit 1; }
# shellcheck disable=SC1091
source "$T/fn.sh"
fail=0
expect() {   # what, installed (1/0), json, library, want status ("" = no line), want text in the detail [marker zinkoff record]
  local got; got=$(ghostty_line "$2" "$3" "$4" "${7:-0}" "${8:-0}" "${9:-}")
  if [[ ${got%%$'\t'*} == "$5" && $got == *"$6"* ]]; then echo "ok   $1"
  else echo "FAIL $1: got '$got', want '$5' with '$6'"; fail=1; fi
}
echo '{"ICD": {"library_path": "/usr/local/lib/libEGL_omacvm.so.0"}}' > "$T/10_omacvm.json"
# stand-ins: a library with the Ghostty part names the variable it sets; an older one does not
printf 'ELF\0__egl_Main\0eglInitialize\0LIBGL_ALWAYS_SOFTWARE\0OMACVM_GLZINK=1\0' > "$T/new.so"
printf 'ELF\0__egl_Main\0eglInitialize\0LIBGL_ALWAYS_SOFTWARE\0' > "$T/cpu.so"
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
expect "3.2.14-3.2.16's library (CPU only), no marker: ok on the CPU" 1 "$T/10_omacvm.json" "$T/cpu.so" ok "draws on the VM's CPU"
# The app asks for the Mac's GPU (OMACVM_GLZINK=1 in host.env): the next Ghostty
expect "marker: the next Ghostty on the Mac's GPU" 1 "$T/10_omacvm.json" "$T/new.so" ok "the next Ghostty draws on the Mac's GPU (Zink over Venus" 1 0
expect "marker: says what a refused GPU command does" 1 "$T/10_omacvm.json" "$T/new.so" ok "close it (programs in it end)" 1 0
expect "marker, a lost Venus context in this boot: WARN, on the CPU until the VM starts again" 1 "$T/10_omacvm.json" "$T/new.so" warn "stays off the Mac's GPU until the VM starts again" 1 1
expect "gl-zink-off without the marker: as before, on the CPU, ok" 1 "$T/10_omacvm.json" "$T/new.so" ok "draws on the VM's CPU (Mesa's llvmpipe): it needs" 0 1
expect "marker, a library without the Zink part: WARN, Update VM" 1 "$T/10_omacvm.json" "$T/cpu.so" warn "this VM's EGL library is older: Update VM" 1 0
expect "marker, a library from before 3.2.14: FAIL as before" 1 "$T/10_omacvm.json" "$T/old.so" fail "opens no window" 1 0
expect "marker, not installed: no line" 0 "$T/10_omacvm.json" "$T/new.so" "" "" 1 0
# A running Ghostty: the library's record says what Mesa took
expect "running, asked zink, Mesa took zink: ok on the Mac's GPU" 1 "$T/10_omacvm.json" "$T/new.so" ok "draws on the Mac's GPU (Zink over Venus" 1 0 "4242 zink zink setting"
expect "running, asked zink, Mesa took swrast: WARN with Mesa's driver" 1 "$T/10_omacvm.json" "$T/new.so" warn "Zink did not start and Mesa took swrast" 1 0 "4242 zink swrast setting"
expect "running on llvmpipe without the marker: ok on the CPU" 1 "$T/10_omacvm.json" "$T/new.so" ok "draws on the VM's CPU (Mesa's llvmpipe)" 0 0 "4242 llvmpipe swrast nomarker"
expect "running on llvmpipe after a lost context: WARN" 1 "$T/10_omacvm.json" "$T/new.so" warn "a Vulkan app's GPU context was lost" 1 1 "4242 llvmpipe swrast zinkoff"
expect "running on llvmpipe, MESA_GL_VERSION_OVERRIDE set: ok, says why" 1 "$T/10_omacvm.json" "$T/new.so" ok "MESA_GL_VERSION_OVERRIDE is set" 1 0 "4242 llvmpipe swrast glversion"
expect "running with the person's own driver variable: ok, names it" 1 "$T/10_omacvm.json" "$T/new.so" ok "LIBGL_ALWAYS_SOFTWARE is set" 1 0 "4242 own virtio_gpu LIBGL_ALWAYS_SOFTWARE"
expect "a running Ghostty's record wins over the next start's answer" 1 "$T/10_omacvm.json" "$T/new.so" ok "draws on the VM's CPU (Mesa's llvmpipe)" 1 0 "4242 llvmpipe swrast nomarker"
# ghostty_running: the record only for a live process named ghostty
P=$T/proc; mkdir -p "$P/4242" "$P/4343"; echo ghostty > "$P/4242/comm"; echo foot > "$P/4343/comm"
run_is() {   # what, line, want
  local got; got=$(ghostty_running "$2" "$P")
  if [[ $got == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$got', want '$3'"; fail=1; fi
}
run_is "record of a running Ghostty: kept" "4242 zink zink setting" "4242 zink zink setting"
run_is "record of a pid that is not Ghostty (reused): none" "4343 zink zink setting" ""
run_is "record of a pid that is gone: none" "4444 zink zink setting" ""
run_is "a line of another form: none" "root:x:0:0:root:/root:/bin/bash" ""
run_is "an empty record: none" "" ""
run_is "a driver name with other characters: none" "4242 zink zi\$nk setting" ""
# the real library, built as install.sh builds it
if command -v cc >/dev/null && cc -shared -fPIC -O2 -fvisibility=hidden -Wl,-soname,libEGL_omacvm.so.0 \
     -o "$T/built.so" "$egl" -ldl 2>/dev/null; then
  expect "the library built from omacvm_egl.c: ok" 1 "$T/10_omacvm.json" "$T/built.so" ok "draws on the VM's CPU"
  expect "the library built from omacvm_egl.c, marker: the next Ghostty on the Mac's GPU" 1 "$T/10_omacvm.json" "$T/built.so" ok "the next Ghostty draws on the Mac's GPU" 1 0
else
  echo "skip the library built from omacvm_egl.c (no C compiler or no EGL/glvnd headers here)"
fi
grep -q 'ok "Ghostty"' "$check" && grep -q 'warn "Ghostty"' "$check" && grep -q 'bad "Ghostty"' "$check" &&
  grep -q 'ghostty_line "$gi" /etc/glvnd/egl_vendor.d/10_omacvm.json /usr/local/lib/libEGL_omacvm.so.0 "$gm" "$go" "$grec"' "$check" &&
  grep -q "grep -qx 'OMACVM_GLZINK=1' /run/omacvm/host.env" "$check" && grep -q '\[\[ -e /run/omacvm/gl-zink-off \]\]' "$check" &&
  grep -q 'ghostty_running "$(as_user head -c 200 "$RUN/omacvm/ghostty-gl"' "$check" ||
  { echo "FAIL: check.sh does not use ghostty_line (marker, gl-zink-off, the record read as the user) for its \"Ghostty\" line"; fail=1; }
(( fail == 0 )) && echo "ghostty-check: all passed"
exit $fail
