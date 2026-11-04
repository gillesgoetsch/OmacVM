#!/bin/bash
# OmacVM's own guest Mesa build (src/app/guest/mesa/build.sh) never installs
# over the Venus Mesa of a VM with Vulkan on (src/app/guest/venus/install.sh,
# /opt/omacvm-mesa): its default folder is another one, and a folder with the
# Venus build's files stops it before the download. curl, tar, patch, meson
# and ninja are stand-ins that only log their calls.
#   src/tests/guest-mesa-prefix.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
for t in curl sha256sum tar patch meson ninja; do
  printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\n' "$t" > "$T/bin/$t"
done
echo 'cat > /dev/null   # all of stdin: else the writer gets SIGPIPE' >> "$T/bin/sha256sum"
echo 'mkdir -p "$2/mesa-26.2.3"' >> "$T/bin/tar"
chmod +x "$T/bin/"*
export CALLS=$T/calls

venus=$(sed -n 's/^PREFIX=//p' "$R/src/app/guest/venus/install.sh")
gl=$(sed -n 's/^prefix=\${PREFIX:-\(.*\)}$/\1/p' "$R/src/app/guest/mesa/build.sh")
expect "the Venus Mesa's folder is read" /opt/omacvm-mesa "$venus"
expect "the GL build's default folder is read" /opt/omacvm-gl-mesa "$gl"
[[ -n $gl && $gl != "$venus" ]] && r=other || r=same
expect "the GL build's default folder is not the Venus Mesa's" other "$r"

run() {   # PREFIX -> CODE, OUT, the calls file
  : > "$CALLS"
  OUT=$(PATH="$T/bin:$PATH" PREFIX=$1 bash "$R/src/app/guest/mesa/build.sh" 2>&1); CODE=$?
}

# A Venus build's folder (its version stamp), then one with only its driver.
for marker in omacvm-mesa-version lib/libvulkan_virtio.so; do
  P=$T/venus-$(basename "$marker"); mkdir -p "$(dirname "$P/$marker")"; : > "$P/$marker"
  run "$P"
  expect "a folder with the Venus $marker: refused" 1 "$CODE"
  [[ $OUT == *"holds the Venus Mesa"* ]] && r=said || r="$OUT"
  expect "a folder with the Venus $marker: says why" said "$r"
  expect "a folder with the Venus $marker: nothing downloaded or built" 0 "$(wc -l < "$CALLS" | tr -d ' ')"
done

# An empty folder: the build goes on (download, check, patches, meson, ninja).
run "$T/gl"
expect "an empty folder: built" 0 "$CODE"
expect "an empty folder: downloads first" curl "$(head -1 "$CALLS" | cut -d' ' -f1)"
[[ $(grep -c '^meson setup build -Dprefix='"$T/gl"' ' "$CALLS") == 1 ]] && r=yes || r=no
expect "an empty folder: meson gets that folder" yes "$r"
expect "an empty folder: installs with ninja" "ninja -C build install" "$(tail -1 "$CALLS")"

exit $fail
