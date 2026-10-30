#!/bin/bash
# VMware Fusion's vmwgfx fix for Hyprland (src/fusion/guest/hyprland-vmwgfx/): one patch per Hyprland release,
# the same change in each.
#  1. The releases Omarchy ships (RELEASES: stable and edge) each have a patch whose header names its release;
#     each patch applies to its tag's src/protocols/LinuxDMABUF.cpp (downloaded) and adds the same lines.
#  2. build-hyprland.sh's vmwgfx_patch picks each tag's own patch, and none for a file no patch fits; the script
#     then says "no vmwgfx fix for Hyprland <version> yet", records "<version> none" and exits 0 (the apply goes
#     on); omacvm check names the version. A failed download or build still exits 1.
#  3. Fusion's install.sh copies the folder for the pacman hook and removes the single file of 3.2.14 and older.
# Parts 1 and 2 download from github.com: skipped without, unless OMACVM_FUSION_STRICT=1 (CI), which fails.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
F=$here/../fusion/guest
P=$F/hyprland-vmwgfx
# Omarchy's Hyprland now: stable (pkgs.omarchy.org/stable) and edge (the dev channel). A new one: a patch first.
RELEASES="0.56.2 0.57.0"
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
expect() {   # WHAT CONDITION...
  local what=$1; shift
  if "$@"; then ok "$what"; else bad "$what"; fi
}
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-fusion-vmwgfx.XXXXXX")
trap 'rm -rf "$T"' EXIT

# --- 3: what install.sh and check.sh say (offline)
expect "install.sh copies every patch for the hook" grep -qF 'install -o root -g root -m644 "$here"/hyprland-vmwgfx/*.patch "$L/hyprland-vmwgfx/"' "$F/install.sh"
expect "install.sh removes the old single patch" grep -qF 'rm -f "$L/hyprland-vmwgfx-dmabuf.patch"' "$F/install.sh"
expect "no single patch left beside the script" test ! -e "$F/hyprland-vmwgfx-dmabuf.patch"
expect "the script uses vmwgfx_patch, not one file" grep -q '^if ! patch=$(vmwgfx_patch as_u); then$' "$F/build-hyprland.sh"
nofix=$(sed -n '/^if ! patch=$(vmwgfx_patch as_u); then$/,/^fi$/p' "$F/build-hyprland.sh")
expect "no patch fits: says which version" grep -q 'no vmwgfx fix for Hyprland $pkg yet' <<<"$nofix"
expect "no patch fits: records it for omacvm check" grep -qF 'echo "$pkg none" > "$STATE"' <<<"$nofix"
expect "no patch fits: exit 0 (the apply goes on)" grep -qx '  exit 0' <<<"$nofix"
expect "a failed download still fails" grep -q 'cannot download Hyprland $commit" >&2; exit 1; }' "$F/build-hyprland.sh"
expect "a failed build still fails" grep -q 'the build failed, full log: $W/build.log" >&2; exit 1; }' "$F/build-hyprland.sh"
expect "omacvm check names the version when no patch fits" grep -qF '"no vmwgfx fix for Hyprland $hv yet (black screen at the next login): omacvm update brings one"' "$here/../guest/check.sh"

# --- 1: each release's patch
for v in $RELEASES; do
  expect "a patch for Hyprland $v" test -f "$P/$v.patch"
done
for p in "$P"/*.patch; do
  v=$(basename "$p" .patch)
  expect "$v.patch: its header names its release" grep -q "Applies to Hyprland $v\.$" "$p"
  expect "$v.patch: changes LinuxDMABUF.cpp only" test "$(grep -c '^+++ ' "$p") $(grep -c '^+++ b/src/protocols/LinuxDMABUF.cpp$' "$p")" = "1 1"
done
# the lines each patch adds, the same in every one
added() { grep '^+' "$1" | grep -v '^+++ '; }
first=""; for p in "$P"/*.patch; do
  if [[ -z $first ]]; then first=$p; continue; fi
  expect "$(basename "$p") adds the same lines as $(basename "$first")" test "$(added "$p")" = "$(added "$first")"
done
fetch() {   # VERSION: the tag's LinuxDMABUF.cpp in $T/v$VERSION/src/protocols/
  mkdir -p "$T/v$1/src/protocols"
  curl -fsSL --retry 2 -o "$T/v$1/src/protocols/LinuxDMABUF.cpp" \
    "https://raw.githubusercontent.com/hyprwm/Hyprland/v$1/src/protocols/LinuxDMABUF.cpp" 2>/dev/null
}
vs=$(for p in "$P"/*.patch; do basename "$p" .patch; done)
applies() { (cd "$1" && git apply --check "$2" 2>/dev/null); }   # DIR PATCH (git apply works outside a repository)
applies_not() { ! applies "$@"; }
for v in $vs; do
  if ! fetch "$v"; then
    if [[ ${OMACVM_FUSION_STRICT:-} == 1 ]]; then bad "cannot download Hyprland v$v's LinuxDMABUF.cpp (parts 1 and 2)"
    else echo "skip: cannot download Hyprland v$v's LinuxDMABUF.cpp (parts 1 and 2)"; fi
    (( fail == 0 )) && echo "fusion-vmwgfx: all passed (offline parts only)"
    exit $fail
  fi
done
for v in $vs; do
  for p in "$P"/*.patch; do
    w=$(basename "$p" .patch)
    if [[ $w == "$v" ]]; then
      expect "$w.patch applies to v$v" applies "$T/v$v" "$p"
    else
      expect "$w.patch does not apply to v$v (the lines around the change moved)" applies_not "$T/v$v" "$p"
    fi
  done
done

# --- 2: build-hyprland.sh's pick, on each tag's file and on one no patch fits
sed -n '/^vmwgfx_patch() {/,/^}/p' "$F/build-hyprland.sh" > "$T/fn.sh"
expect "build-hyprland.sh has vmwgfx_patch" grep -q '^vmwgfx_patch() {' "$T/fn.sh"
# shellcheck disable=SC1091
here=$F source "$T/fn.sh"
pick() { (cd "$1" && here=$F vmwgfx_patch); }
picks_none() { ! pick "$1" >/dev/null; }
for v in $vs; do
  expect "on v$v: picks $v.patch" test "$(pick "$T/v$v")" = "$P/$v.patch"
done
mkdir -p "$T/other/src/protocols"
sed 's/drmCloseBufferHandle(PROTO::linuxDma->m_mainDeviceFD.get(), handle)/drmCloseBufferHandle(PROTO::linuxDma->m_mainDeviceFD.get(), handle, 0)/' \
  "$T/v${vs##*$'\n'}/src/protocols/LinuxDMABUF.cpp" > "$T/other/src/protocols/LinuxDMABUF.cpp"
expect "a release no patch fits: none picked" test -z "$(pick "$T/other")"
expect "a release no patch fits: vmwgfx_patch fails" picks_none "$T/other"

(( fail == 0 )) && echo "fusion-vmwgfx: all passed"
exit $fail
