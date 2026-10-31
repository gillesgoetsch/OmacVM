#!/bin/bash
# VMware Fusion's vmwgfx fix for Hyprland (src/fusion/guest/hyprland-vmwgfx/): one patch per Hyprland release,
# the same change in each.
#  1. The releases Omarchy ships (RELEASES: stable and edge) each have a patch whose header names its release;
#     each patch applies to its tag's src/protocols/LinuxDMABUF.cpp (downloaded) and adds the same lines.
#  2. build-hyprland.sh's vmwgfx_patch picks each tag's own patch, and none for a file no patch fits; the script
#     then says "no vmwgfx fix for Hyprland <version> yet", records "<version> none" and exits 0 (the apply goes
#     on); omacvm check names the version. A failed download or build still exits 1.
#  3. Fusion's install.sh copies the folder for the pacman hook and removes the single file of 3.2.14 and older.
#  4. With "<version> none <source commit> <patch set>" in the state for this source and these patches, the script
#     says the same and exits 0 without the download; the patch set is the same word from any folder, and an empty
#     or missing folder does not stop the script; any other state (3.2.15's "<version> none" too), another commit or
#     patch set, or OMACVM_REBUILD_HYPRLAND=1 checks again; omacvm check takes both forms of the state.
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
expect "no patch fits: says which version" grep -qx '  no_fix' <<<"$nofix"
expect "no_fix names the version" grep -q '"build-hyprland: no vmwgfx fix for Hyprland $pkg yet: .*" >&2$' "$F/build-hyprland.sh"
expect "no patch fits: records it with the source commit and the patch set" grep -qF 'echo "$pkg none $commit $(patch_set)" > "$STATE"' <<<"$nofix"
expect "no patch fits: exit 0 (the apply goes on)" grep -qx '  exit 0' <<<"$nofix"
expect "a failed download still fails" grep -q 'cannot download Hyprland $commit" >&2; exit 1; }' "$F/build-hyprland.sh"
expect "a failed build still fails" grep -q 'the build failed, full log: $W/build.log" >&2; exit 1; }' "$F/build-hyprland.sh"
expect "omacvm check names the version when no patch fits" grep -qF '"no vmwgfx fix for Hyprland $hv yet (black screen at the next login): omacvm update brings one"' "$here/../guest/check.sh"

# --- 4: the skip when the state already says none for this source and these patches (offline)
sed -n '/^sum() {/p; /^patch_set() {/,/^}/p; /^none_recorded() {/,/^}/p' "$F/build-hyprland.sh" > "$T/skip.sh"
expect "build-hyprland.sh has patch_set and none_recorded" test "$(grep -c -E '^(patch_set|none_recorded)\(\) \{' "$T/skip.sh")" = 2
line_of() { grep -n -m1 -F "$1" "$F/build-hyprland.sh" | cut -d: -f1; }
skip_at=$(line_of 'if none_recorded; then no_fix; exit 0; fi')
expect "the skip says the same as a run that finds no patch, exit 0" test -n "$skip_at"
expect "the skip comes after the commit is known and before pkg-add and the download" \
  test "${skip_at:-0}" -gt "$(line_of 'commit=$("$stock" --version')" -a "${skip_at:-0}" -lt "$(line_of '"$here/../../guest/pkg-add"')" \
       -a "${skip_at:-0}" -lt "$(line_of 'git fetch -q --depth 1')"
mkdir -p "$T/a/hyprland-vmwgfx" "$T/b/usr/local/lib/omacvm/fusion/hyprland-vmwgfx" "$T/empty/hyprland-vmwgfx"
cp "$P"/*.patch "$T/a/hyprland-vmwgfx/"; cp "$P"/*.patch "$T/b/usr/local/lib/omacvm/fusion/hyprland-vmwgfx/"
# runs one of the functions as the script does (set -euo pipefail): SKIPDIR=... skipfn FUNCTION
skipfn() { (set -euo pipefail; here=$SKIPDIR; source "$T/skip.sh"; "$@"); }
set_a=$(SKIPDIR=$T/a skipfn patch_set)
expect "patch set: 16 hex digits" grep -qx '[0-9a-f]\{16\}' <<<"$set_a"
expect "patch set: the same from another folder" test "$(SKIPDIR=$T/b/usr/local/lib/omacvm/fusion skipfn patch_set)" = "$set_a"
expect "patch set: an empty folder does not stop the script" test -n "$(SKIPDIR=$T/empty skipfn patch_set)"
expect "patch set: a missing folder does not stop the script" test -n "$(SKIPDIR=$T/nowhere skipfn patch_set)"
cp -R "$T/a" "$T/c"; echo " " >> "$T/c/hyprland-vmwgfx/$(basename "$(ls "$P"/*.patch | head -1)")"
expect "patch set: a changed patch gives another" test "$(SKIPDIR=$T/c skipfn patch_set)" != "$set_a"
cp -R "$T/a" "$T/d"; cp "$(ls "$P"/*.patch | head -1)" "$T/d/hyprland-vmwgfx/9.99.9.patch"
expect "patch set: one more patch gives another" test "$(SKIPDIR=$T/d skipfn patch_set)" != "$set_a"
C=0123456789abcdef0123456789abcdef01234567
recorded() {   # STATE-TEXT [VAR=VALUE...]: none_recorded for Hyprland 0.58.0-1 at $C with the patches in $T/a
  local text=$1; shift
  if [[ -n $text ]]; then printf '%s\n' "$text" > "$T/state"; else rm -f "$T/state"; fi
  (unset OMACVM_REBUILD_HYPRLAND; for kv in "$@"; do export "${kv?}"; done
   STATE=$T/state pkg=0.58.0-1 commit=$C SKIPDIR=$T/a skipfn none_recorded)
}
not_recorded() { ! recorded "$@"; }
expect "skip: the same version, commit and patch set" recorded "0.58.0-1 none $C $set_a"
expect "no skip: 3.2.15's two-word state" not_recorded "0.58.0-1 none"
expect "no skip: another source commit" not_recorded "0.58.0-1 none fedcba9876543210fedcba9876543210fedcba98 $set_a"
expect "no skip: another patch set (an OmacVM update brought a patch)" not_recorded "0.58.0-1 none $C 0000000000000000"
expect "no skip: another version" not_recorded "0.57.0-2 none $C $set_a"
expect "no skip: a patched build's state" not_recorded "0.58.0-1 $(printf '%064d' 0)"
expect "no skip: no state" not_recorded ""
expect "no skip: OMACVM_REBUILD_HYPRLAND=1" not_recorded "0.58.0-1 none $C $set_a" OMACVM_REBUILD_HYPRLAND=1
# omacvm check's "Hyprland" line: both forms of the state name the version
sed -n '/^  vst=\$(cat \/var\/lib\/omacvm\/hyprland-vmwgfx/,/^  else bad "Hyprland"/p' "$here/../guest/check.sh" | sed 1d > "$T/check-hv.sh"
check_hv() {   # STATE-TEXT: what the check's Hyprland line says
  (ok() { echo "ok $2"; }; bad() { echo "FAIL $2"; }; hv=0.58.0-1; vst=$1; source "$T/check-hv.sh") 2>/dev/null
}
for st in "0.58.0-1 none" "0.58.0-1 none $C $set_a"; do
  expect "check: '$st' names the version" test "$(check_hv "$st")" = "FAIL no vmwgfx fix for Hyprland 0.58.0-1 yet (black screen at the next login): omacvm update brings one"
done
expect "check: another version's none is not this one's" grep -q '^FAIL 0.58.0-1 without the vmwgfx fix' <<<"$(check_hv "0.57.0-2 none $C $set_a")"
expect "check: 'nonesuch' is not none" grep -q '^FAIL 0.58.0-1 without the vmwgfx fix' <<<"$(check_hv "0.58.0-1 nonesuch")"

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
