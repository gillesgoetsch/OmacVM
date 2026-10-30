#!/bin/bash
# OmacVM.app: screenshots and screen sharing of HDR apps in an HDR VM (#579).
# Hyprland 0.56.2 and 0.57.0 make the SDR copy that screenshots (grim, Omarchy's
# screenshot and its frozen screen), colour picks (hyprpicker) and screen
# sharing (xdg-desktop-portal-hyprland) read with SDR white at 80 nits for
# windows drawn in HDR (PQ: Chrome, Chromium), which put it at
# 203: those came out 2.54 times too bright, light greys white. A window shared
# alone was cut at 80 nits the same way. OmacVM puts a fixed copy of the one
# shader file that does both (cm_helpers.glsl, changes marked "OmacVM") into
# /usr/local/share/hypr/shaders/. Hyprland reads it before the copy built into
# it, at its start and at `hyprctl reloadshaders`.
# Only while /usr/bin/Hyprland was built from the release the file was made for
# and carries each shader file it works with byte for byte (guard.py, one folder
# per release: 0.56.2/, 0.57.0/). Any other Hyprland reads its own copy: the bug
# may be back, nothing breaks; --status names the installed hyprland package
# (pacman's database) and the releases OmacVM has fixes for. pacman hooks take
# our file out before /usr/bin/Hyprland changes and put the new binary's
# release's file in after when it passes.
# Run as root inside the VM:
#   hypr-capture.sh                  in place when the installed Hyprland passes, else out
#   hypr-capture.sh --hook-pre       pacman, before /usr/bin/Hyprland changes: out
#   hypr-capture.sh --hook-post      pacman, after: as without an option
#   hypr-capture.sh --remove         out: Hyprland's own copy, until the next Update VM
#                                    or Hyprland update (the post hook puts it back)
#   hypr-capture.sh --status [USER]  "WORD<TAB>text" for omacvm check (ok, own, pkg,
#                                    other, missing, uncovered)
# A change reaches each running Hyprland of the installed binary at once
# (hyprctl reloadshaders as its user, not from the pre hook); one still running
# an older binary (updated, not logged in again) keeps the text it read at its
# start, which was checked then: log out and in before `hyprctl reloadshaders`
# there (it would read the new release's file). Never fails a pacman
# transaction or an apply: on any doubt our file goes out, and it exits 0.
# Hyprland reads each shader file by name from ~/.config/hypr/shaders, then
# /usr/share/hypr/shaders, then /usr/local/share/hypr/shaders, before its
# built-in copy. Another file of a name ours works with (the five in
# `original`): a package's in /usr/share or one beside ours keeps ours out (no
# mix of files that were not checked together); a person's own in ~/.config
# wins in their session, and --status says so.
# Tests: OMACVM_HC_ROOT (a fake root for every path), OMACVM_HC_HYPRCTL.
set -uo pipefail
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
R=${OMACVM_HC_ROOT:-}
BIN=$R/usr/bin/Hyprland
SHADERS=$R/usr/local/share/hypr/shaders
OURS=$SHADERS/cm_helpers.glsl
PKG=$R/usr/share/hypr/shaders                     # a package's shader files win over ours
STATE=$R/var/lib/omacvm/hypr-capture              # "<release folder> <sha256 of our file>"
PACDB=$R/var/lib/pacman/local                     # pacman's record of the installed packages
HYPRCTL=${OMACVM_HC_HYPRCTL:-hyprctl}

sum() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
# names: the shader files ours works with (each release folder's `original`).
names() { { echo cm_helpers.glsl; grep -h '^file ' "$here"/*/original 2>/dev/null | cut -d' ' -f4; } | sort -u; }
# found DIR [BUT]: the first of those names in DIR (BUT not counted).
found() {
  local n
  while read -r n; do
    [[ $n != "${2:-}" ]] && [[ -e $1/$n || -L $1/$n ]] && { echo "$n"; return 0; }
  done < <(names)
  return 1
}
# installed: the hyprland package's version (pacman's database, read as a file:
# also inside a hook), no epoch; fails when not known. Only the entry named
# hyprland itself, not hyprland-guiutils, -protocols, -qtutils ...
installed() {
  local f
  for f in "$PACDB"/hyprland-*/desc; do
    [[ -f $f ]] || continue
    awk '$0 == "%NAME%" { getline; n = $0 } $0 == "%VERSION%" { getline; v = $0 }
         END { if (n != "hyprland" || v == "") exit 1; sub(/^[0-9]+:/, "", v); print v }' "$f" && return 0
  done
  return 1
}
# guard: the release folder that fits /usr/bin/Hyprland (guard.py), else fails
# with why on stderr (the end of "no OmacVM fix for ...").
guard() {
  [[ -r $BIN ]] || { echo "this Hyprland (no /usr/bin/Hyprland)" >&2; return 1; }
  command -v python3 >/dev/null || { echo "this Hyprland (python3 missing)" >&2; return 1; }
  local d=() f
  for f in "$here"/*/original; do [[ -f $f ]] && d+=("${f%/original}"); done
  (( ${#d[@]} )) || { echo "this Hyprland (no fix folder beside hypr-capture.sh)" >&2; return 1; }
  python3 -I "$here/guard.py" --installed "$(installed)" "$BIN" "${d[@]}"
}
# is_ours FILE: a file OmacVM put there: one it ships, the one it recorded, or
# one with its header (an older OmacVM's, also when the record is lost).
is_ours() {
  local s f; s=$(sum "$1"); [[ -n $s ]] || return 1
  for f in "$here"/*/cm_helpers.glsl; do [[ $s == "$(sum "$f")" ]] && return 0; done
  [[ $s == "$(cut -d' ' -f2 "$STATE" 2>/dev/null)" ]] && return 0
  head -n 12 "$1" 2>/dev/null | grep -q "^// OmacVM begin: Hyprland [0-9][0-9.]*'s src/render/shaders/glsl/cm_helpers.glsl "
}
# out: our file goes; true when that changed something. Never anyone else's.
out() {
  [[ -e $OURS || -L $OURS ]] || { rm -f "$STATE"; return 1; }
  is_ours "$OURS" || return 1
  rm -f "$OURS" "$STATE" || return 1
  return 0
}
# put FOLDER: FOLDER's file in place (written beside it, then renamed); true
# when that changed something. A file someone else put there stays.
put() {
  local src=$here/$1/cm_helpers.glsl tmp
  [[ -e $OURS || -L $OURS ]] && ! is_ours "$OURS" && return 1
  if [[ ! -L $OURS ]] && cmp -s "$src" "$OURS"; then
    echo "$1 $(sum "$OURS")" > "$STATE" 2>/dev/null
    return 1
  fi
  mkdir -p "$SHADERS" "$(dirname "$STATE")" || return 1
  tmp=$(mktemp "$SHADERS/.cm_helpers.glsl.XXXXXX" 2>/dev/null) || return 1
  if cat "$src" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$OURS"; then
    echo "$1 $(sum "$OURS")" > "$STATE"
    return 0
  fi
  rm -f "$tmp"; out; return 0
}
# as_uid UID CMD...: CMD as that user, without a login (as home-files.sh's home_run).
as_uid() {
  local u=$1; shift
  if (( EUID != 0 )); then "$@"; return; fi
  local g; g=$(id -g "$u" 2>/dev/null) || return 1
  setsid -w setpriv --reuid="$u" --regid="$g" --init-groups -- "$@"
}
# reload: each running Hyprland of the installed binary reads its shader files
# again (its lock file in $XDG_RUNTIME_DIR/hypr/<instance>/ names its pid). A
# Hyprland whose binary was replaced since its start ("(deleted)") is left alone.
reload() {
  local lock pid dir uid sig
  for lock in "$R"/run/user/*/hypr/*/hyprland.lock; do
    [[ -f $lock ]] || continue
    pid=$(head -n1 "$lock" 2>/dev/null)
    [[ $pid =~ ^[0-9]+$ ]] || continue
    [[ $(readlink "$R/proc/$pid/exe" 2>/dev/null) == /usr/bin/Hyprland ]] || continue
    dir=$(dirname "$lock"); sig=$(basename "$dir")
    uid=${dir#"$R"/run/user/}; uid=${uid%%/*}
    [[ $uid =~ ^[0-9]+$ ]] || continue
    if as_uid "$uid" timeout 5 env XDG_RUNTIME_DIR="/run/user/$uid" HYPRLAND_INSTANCE_SIGNATURE="$sig" \
         "$HYPRCTL" reloadshaders >/dev/null 2>&1; then
      echo "OmacVM: HDR captures: Hyprland $sig reads its shader files again"
    fi
  done
}
# apply: in place or out, as the installed Hyprland allows.
apply() {
  local folder why f changed=1
  if f=$(found "$PKG"); then
    out || changed=0
    echo "OmacVM: HDR captures: Hyprland's package ships its own shader files ($f); they are used"
  elif f=$(found "$SHADERS" cm_helpers.glsl); then
    out || changed=0
    echo "OmacVM: HDR captures: another $f is in $SHADERS; OmacVM's cm_helpers.glsl stays out"
  elif folder=$(guard 2>/dev/null); then
    put "$folder" || changed=0
    if [[ $(sum "$OURS") == "$(sum "$here/$folder/cm_helpers.glsl")" ]]; then
      echo "OmacVM: HDR captures: OmacVM's cm_helpers.glsl for Hyprland $folder in place"
    elif [[ -e $OURS || -L $OURS ]]; then
      echo "OmacVM: HDR captures: another cm_helpers.glsl is in $SHADERS; left as it is"
    else
      echo "OmacVM: HDR captures: OmacVM's cm_helpers.glsl could not be written to $SHADERS; Hyprland's own copy"
    fi
  else
    why=$(guard 2>&1 >/dev/null | tail -n1)
    out || changed=0
    echo "OmacVM: HDR captures: Hyprland's own copy: no OmacVM fix for ${why:-this Hyprland (not checked)}"
  fi
  (( changed )) && reload
  return 0
}
# own USER: the first of the names in USER's ~/.config/hypr/shaders (looked at
# as that user).
own() {
  local h uid n
  h=$(getent passwd "$1" | cut -d: -f6) && [[ -n $h ]] && uid=$(id -u "$1" 2>/dev/null) || return 1
  while read -r n; do
    as_uid "$uid" test -e "$R$h/.config/hypr/shaders/$n" 2>/dev/null && { echo "$n"; return 0; }
  done < <(names)
  return 1
}
# status [USER]: what omacvm check says.
status() {
  local u=${1:-} folder why f
  if [[ -n $u ]] && f=$(own "$u"); then
    printf 'own\tyour own ~/.config/hypr/shaders/%s is used (it comes before OmacVM'"'"'s)\n' "$f"
  elif f=$(found "$PKG"); then
    printf 'pkg\tHyprland'"'"'s package ships its own shader files (%s); they are used\n' "$f"
  elif f=$(found "$SHADERS" cm_helpers.glsl); then
    printf 'other\tanother %s in %s is used; OmacVM'"'"'s fix stays out\n' "$f" "$SHADERS"
  elif ! folder=$(guard 2>/dev/null); then
    why=$(guard 2>&1 >/dev/null | tail -n1)
    printf 'uncovered\tno OmacVM fix for %s: screenshots and screen sharing of HDR apps (Chrome) come out too bright while HDR is on\n' "${why:-this Hyprland (not checked)}"
  elif [[ -e $OURS && $(sum "$OURS") == "$(sum "$here/$folder/cm_helpers.glsl")" ]]; then
    printf 'ok\tscreenshots and screen sharing of HDR apps at SDR white (OmacVM'"'"'s cm_helpers.glsl for Hyprland %s)\n' "$folder"
  elif [[ -e $OURS ]] && ! is_ours "$OURS"; then
    printf 'other\tanother cm_helpers.glsl in %s is used, not OmacVM'"'"'s\n' "$SHADERS"
  else
    printf 'missing\tOmacVM'"'"'s fix for Hyprland %s is not in place: omacvm apply (Update VM)\n' "$folder"
  fi
}

case ${1:-} in
  "" | --hook-post) apply ;;
  --hook-pre) out && echo "OmacVM: HDR captures: OmacVM's cm_helpers.glsl out until Hyprland is checked again"; exit 0 ;;
  --remove) out && { echo "OmacVM: HDR captures: OmacVM's cm_helpers.glsl removed (back with the next Update VM or Hyprland update)"; reload; }; exit 0 ;;
  --status) status "${2:-}" ;;
  *) echo "usage: hypr-capture.sh [--hook-pre|--hook-post|--remove|--status [USER]]" >&2; exit 2 ;;
esac
exit 0
