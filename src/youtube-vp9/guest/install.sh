#!/bin/bash
# Prefer VP9 on YouTube (feature youtube-vp9: experimental, off by default,
# offered only on Macs whose media engine has no AV1 decoder; docs/video-decode.md).
# Run as root inside the VM: ./install.sh on|off|--status
#   on:  OmacVM's no-AV1 extension (src/vdec/guest/no-av1: on youtube.com AV1
#        is "not supported", so YouTube sends VP9, which the Mac's media
#        engine decodes) as an external extension of Google Chrome and
#        Chromium: a packed copy (crx3.py) in /usr/local/lib/omacvm and a file
#        <id>.json naming it in /usr/share/google-chrome/extensions and
#        /usr/share/chromium/extensions. That is Chrome's own way to add an
#        extension on Linux: no policy (no "Managed by your organization"),
#        no command-line switch, the user can remove it in chrome://extensions.
#        The browser adds it at its next start.
#   off: all of it goes (the browser removes the extension at its next start).
#   --status: "ok ID" (on and complete), "none" (nothing of it), or
#        "bad WHAT" (half there); for guest/check.sh.
# The key that signs the copy is made here once (/var/lib/omacvm, root only)
# and kept while on, so the id stays and an apply changes nothing (same key,
# same files = the same bytes). Off removes it: a later on gets a new id, so
# an extension the user removed in chrome://extensions comes back only when
# they switch this on again.
# Chrome takes a new copy only with a new version: a change to the
# extension's files needs a new "version" in its manifest.json
# (src/tests/youtube-vp9.sh pins the files per version).
# OMACVM_ROOT (tests): a scratch folder in front of every path written.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=${OMACVM_ROOT:-}
EXT=$(cd ../../vdec/guest/no-av1 && pwd)
CRX_PATH=/usr/local/lib/omacvm/youtube-vp9.crx   # as the browsers read it
CRX=$ROOT$CRX_PATH
KEY=$ROOT/var/lib/omacvm/youtube-vp9.pem
DIRS=("$ROOT/usr/share/google-chrome/extensions" "$ROOT/usr/share/chromium/extensions")
say() { echo "  Prefer VP9 on YouTube: $*"; }
crx3() { python3 -I ./crx3.py "$@"; }

# The JSON files that name our copy (whatever their id).
ours() {
  local d
  for d in "${DIRS[@]}"; do
    [[ -d $d ]] && grep -lsF "\"$CRX_PATH\"" "$d"/*.json || true
  done
}

json() {   # VERSION
  printf '{\n  "external_crx": "%s",\n  "external_version": "%s"\n}\n' "$CRX_PATH" "$1"
}

status() {
  local id ver d f bad="" left
  left=$(ours)
  if [[ ! -e $CRX && ! -e $KEY && -z $left ]]; then echo none; return 0; fi
  [[ -f $KEY ]] || { echo "bad its key is missing"; return 0; }
  read -r id ver < <(crx3 info "$CRX" 2>/dev/null) || { echo "bad its packed extension is missing or broken"; return 0; }
  [[ $id == "$(crx3 id "$KEY" 2>/dev/null)" ]] || { echo "bad the packed extension is not signed by its key"; return 0; }
  for d in "${DIRS[@]}"; do
    f=$d/$id.json
    [[ -f $f && $(cat "$f") == "$(json "$ver")" ]] || bad="${bad:+$bad, }${d#"$ROOT"}/$id.json"
  done
  [[ -z $bad ]] || { echo "bad not named in $bad"; return 0; }
  for f in $left; do
    [[ $(basename "$f") == "$id.json" ]] || { echo "bad an old copy is still named: ${f#"$ROOT"}"; return 0; }
  done
  echo "ok $id"
}

case ${1:-} in
  --status) status; exit 0 ;;
  off)
    left=$(ours)
    [[ -e $CRX || -e $KEY || -n $left ]] || exit 0
    for f in $left; do rm -f "$f"; done
    rm -f "$CRX" "$KEY"
    say "off (Chrome and Chromium remove the extension at their next start)"
    exit 0 ;;
  on) ;;
  *) echo "usage: install.sh on|off|--status" >&2; exit 2 ;;
esac

command -v openssl >/dev/null || { say "openssl is missing (pacman -S openssl)"; exit 1; }
install -d -m 755 "$(dirname "$CRX")" "${DIRS[@]}"
# /var/lib/omacvm holds other features' state too: made if missing, its mode
# left as it is (the key itself is root only).
[[ -d $(dirname "$KEY") ]] || install -d -m 755 "$(dirname "$KEY")"
if [[ ! -s $KEY ]]; then
  (umask 077; openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$KEY.new" 2>/dev/null)
  mv -f "$KEY.new" "$KEY"
fi
chmod 600 "$KEY"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
id=$(crx3 pack "$KEY" "$EXT" "$T/x.crx")
ver=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$EXT/manifest.json")
new=0
if ! cmp -s "$T/x.crx" "$CRX"; then
  install -m 644 "$T/x.crx" "$CRX.new"
  mv -f "$CRX.new" "$CRX"
  new=1
fi
json "$ver" > "$T/x.json"
for d in "${DIRS[@]}"; do
  if ! cmp -s "$T/x.json" "$d/$id.json"; then
    install -m 644 "$T/x.json" "$d/.$id.json.new"
    mv -f "$d/.$id.json.new" "$d/$id.json"
    new=1
  fi
done
# A copy named under another id (an older key): only ours, by its path.
for f in $(ours); do [[ $(basename "$f") == "$id.json" ]] || { rm -f "$f"; new=1; }; done
if (( new )); then say "on (Chrome and Chromium add it at their next start)"; else say "on"; fi
