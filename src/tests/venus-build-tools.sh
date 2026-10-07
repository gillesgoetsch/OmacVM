#!/bin/bash
# The vulkan feature's Mesa build in the VM (src/app/guest/venus/install.sh)
# without a VM: the build tools a VM lacks come for the build and go after it,
# also when the build fails; then no Vulkan manifest is written (apply turns
# Vulkan on only with it). pacman, curl, meson and ninja are stand-ins; the
# script's /etc, /opt, /usr and /var go to a temporary folder.
#   src/tests/venus-build-tools.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin"
cat > "$T/bin/pacman" <<'EOF'
#!/bin/bash
echo "pacman $*" >> "$CALLS"
case $1 in
  -T) for p in "${@:2}"; do [[ " $MISSING " == *" $p "* ]] && echo "$p"; done; exit 0 ;;
  -Q) echo "llvm-libs 22.1.8-1" ;;
esac
exit 0
EOF
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
while (( $# )); do [[ $1 == -o ]] && : > "$2"; shift; done
EOF
cat > "$T/bin/sha256sum" <<'EOF'
#!/bin/bash
cat > /dev/null   # all of stdin: else the writer gets SIGPIPE (status 141)
[[ ${1:-} == -c ]] && exit 0
echo "0123456789abcdef0123  -"
EOF
cat > "$T/bin/tar" <<'EOF'
#!/bin/bash
mkdir -p "$2/mesa-26.2.4"
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/bin/patch"
# GNU install -D (macOS's has no -D): the last argument is the target.
cat > "$T/bin/install" <<'EOF'
#!/bin/bash
src=/dev/stdin
while (( $# > 1 )); do case $1 in -D*|-m*) ;; *) src=$1 ;; esac; shift; done
mkdir -p "$(dirname "$1")" && cat "$src" > "$1"
EOF
printf '#!/bin/bash\n[[ $MESON == ok ]]\n' > "$T/bin/meson"
cat > "$T/bin/ninja" <<'EOF'
#!/bin/bash
mkdir -p "$PFX/share/vulkan/icd.d"
echo '{"ICD": {"library_path": "libvulkan_virtio.so"}}' > "$PFX/share/vulkan/icd.d/virtio_icd.aarch64.json"
EOF
chmod +x "$T/bin/"*

run() {   # MISSING(build tools the VM lacks) MESON(ok|fail) -> sets OUT, CODE, CALLS file
  local V=$T/vm; rm -rf "$V"; mkdir -p "$V/venus" "$V/var/log"
  cp -R "$R/src/app/guest/venus/." "$V/venus/"
  sed -E "s#/(opt|etc|usr|var)/#$V/\1/#g" "$R/src/app/guest/venus/install.sh" > "$V/venus/install.sh"
  : > "$T/calls"
  OUT=$(CALLS=$T/calls MISSING=$1 MESON=$2 PFX=$V/opt/omacvm-mesa PATH="$T/bin:$PATH" OMACVM_WEBGPU_ROOT=$V \
    OMACVM_PKG_ADD="$R/src/guest/pkg-add" OMACVM_PKG_LOG=$T/pkg.log \
    bash "$V/venus/install.sh" --force 2>&1); CODE=$?
}
asdeps() { grep -- '--asdeps' "$T/calls" | sed 's/.*--asdeps //'; }
removed() { grep -- 'pacman -Rns' "$T/calls" | sed 's/.*--noconfirm //'; }

run "meson ninja rust rust-bindgen cbindgen" ok
expect "stock VM: build ok" 0 "$CODE"; [[ $CODE == 0 ]] || echo "$OUT"
expect "stock VM: missing tools installed as dependencies" "meson ninja rust rust-bindgen cbindgen" "$(asdeps)"
expect "stock VM: the same tools removed after the build" "meson ninja rust rust-bindgen cbindgen" "$(removed)"
expect "stock VM: Vulkan manifest written" yes "$([[ -f $T/vm/etc/vulkan/icd.d/omacvm_venus_icd.json ]] && echo yes)"
expect "stock VM: Chromium (WebGPU) launcher" yes "$([[ -f $T/vm/usr/local/bin/omacvm-chromium-webgpu ]] && echo yes)"
expect "stock VM: build folder gone" no "$([[ -e $T/vm/var/cache/omacvm/mesa-build ]] && echo yes || echo no)"
expect "Mesa's libraries are not removed" no \
  "$(removed | grep -qwE 'clang|libclc|spirv-llvm-translator|spirv-tools|llvm-libs' && echo yes || echo no)"

run "rust" fail
expect "build fails: status 1" 1 "$CODE"
expect "build fails: tools removed all the same" rust "$(removed)"
expect "build fails: no Vulkan manifest" no "$([[ -e $T/vm/etc/vulkan/icd.d/omacvm_venus_icd.json ]] && echo yes || echo no)"
expect "build fails: its log kept" yes "$([[ -f $T/vm/var/log/omacvm-mesa-build.log ]] && echo yes)"

run "" ok
expect "VM with all tools: build ok" 0 "$CODE"
expect "VM with all tools: nothing installed for the build" "" "$(asdeps)"
expect "VM with all tools: nothing removed" "" "$(removed)"

exit $fail
