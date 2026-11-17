#!/bin/bash
# Prefer VP9 on YouTube (feature youtube-vp9, src/youtube-vp9), no VM needed:
#  - crx3.py writes a CRX3 that it reads back: the id is sha256 of the key's
#    public part (first 16 bytes, 0-f as a-p), the signature checks out with
#    openssl, the same key and files give the same bytes, and a changed byte
#    in the zip or the header is refused;
#  - install.sh on/off/--status in a scratch root: the packed copy, its key
#    (root only) and <id>.json in Chrome's and Chromium's extensions folders;
#    on twice changes nothing; a copy named under an old id goes; other
#    extensions' files stay; off leaves nothing; half there = bad;
#  - the extension's files are the ones of its manifest version (Chrome takes
#    a new copy only with a new version: change the version with the files);
#  - the Mac offers it only without an AV1 decoder (tag no-av1), experimental,
#    off by default; the VM installer, the check and the parts know it.
# Runs on macOS (LibreSSL) and in CI's Linux job (OpenSSL, GNU tools, as in the VM).
#   src/tests/youtube-vp9.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
G=$R/src/youtube-vp9/guest
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-vp9.XXXXXX")
trap 'rm -rf "$T"' EXIT
crx3() { python3 -I "$G/crx3.py" "$@"; }
sha() { if command -v sha256sum >/dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

# ---------- crx3.py ----------
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$T/k.pem" 2>/dev/null
EXT=$R/src/vdec/guest/no-av1
id=$(crx3 pack "$T/k.pem" "$EXT" "$T/a.crx")
want=$(openssl pkey -in "$T/k.pem" -pubout -outform DER 2>/dev/null | sha | cut -c1-32 | tr 0-9a-f a-p)
expect "crx3: the id is sha256 of the public key, 0-f as a-p" "$want" "$id"
expect "crx3 id: the same id from the key alone" "$id" "$(crx3 id "$T/k.pem")"
expect "crx3 info: valid, its id and the manifest's version" "$id 1.0" "$(crx3 info "$T/a.crx")"
crx3 pack "$T/k.pem" "$EXT" "$T/b.crx" >/dev/null
expect "crx3: same key and files, same bytes" same "$(cmp -s "$T/a.crx" "$T/b.crx" && echo same || echo differ)"
expect "crx3: magic Cr24, version 3" "Cr24 3" "$(python3 -I -c 'import struct,sys; d=open(sys.argv[1],"rb").read(); print(d[:4].decode(), struct.unpack("<I", d[4:8])[0])' "$T/a.crx")"
# A changed byte: the last one (in the zip) and one in the signature.
python3 -I - "$T/a.crx" "$T/zip.crx" "$T/sig.crx" <<'PY'
import struct, sys
d = bytearray(open(sys.argv[1], "rb").read())
z = bytearray(d); z[-30] ^= 1; open(sys.argv[2], "wb").write(z)
n = struct.unpack("<I", d[8:12])[0]
s = bytearray(d); s[12 + n // 2] ^= 1; open(sys.argv[3], "wb").write(s)
PY
crx3 info "$T/zip.crx" >/dev/null 2>&1; expect "crx3 info: a changed zip is refused" 1 $?
crx3 info "$T/sig.crx" >/dev/null 2>&1; expect "crx3 info: a changed header is refused" 1 $?
printf 'Cr24\003\000\000\000\377\377\377\377' > "$T/big.crx"
crx3 info "$T/big.crx" >/dev/null 2>&1; expect "crx3 info: a header past the end is refused" 1 $?
crx3 info "$T/missing.crx" >/dev/null 2>&1; expect "crx3 info: no file, exit 1" 1 $?

# ---------- the extension's files per version ----------
# A change to the files needs a new "version" in manifest.json (and its line here).
ver=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$EXT/manifest.json")
files=$(cat "$EXT/manifest.json" "$EXT/no-av1.js" | sha)
case $ver in
  1.0) expect "no-av1 1.0: its files as packed for Chrome" 345fd82e "${files:0:8}" ;;
  *) expect "no-av1 $ver: a line here for the new version" "a line" "none" ;;
esac

# ---------- install.sh in a scratch root ----------
export OMACVM_ROOT=$T/root
mkdir -p "$OMACVM_ROOT"
CH=$OMACVM_ROOT/usr/share/google-chrome/extensions CR=$OMACVM_ROOT/usr/share/chromium/extensions
CRX=$OMACVM_ROOT/usr/local/lib/omacvm/youtube-vp9.crx KEY=$OMACVM_ROOT/var/lib/omacvm/youtube-vp9.pem
expect "status before: none" none "$("$G/install.sh" --status)"
"$G/install.sh" off >/dev/null; expect "off with nothing there: exit 0, nothing made" "0 0" "$? $(find "$OMACVM_ROOT" -type f | wc -l | tr -d ' ')"
mkdir -p "$CH" "$OMACVM_ROOT/var/lib/omacvm"; chmod 755 "$OMACVM_ROOT/var/lib/omacvm"; printf '{"external_update_url": "https://clients2.google.com/service/update2/crx"}\n' > "$CH/aaaabbbbccccddddeeeeffffgggghhhh.json"
out=$("$G/install.sh" on); expect "on: exit 0" 0 $?
expect "on: says the browsers add it at their next start" "  Prefer VP9 on YouTube: on (Chrome and Chromium add it at their next start)" "$out"
st=$("$G/install.sh" --status); id=${st#ok }
expect "status: ok with the key's id" "ok $(crx3 id "$KEY")" "$st"
expect "the packed copy is valid, signed by the key" "$id 1.0" "$(crx3 info "$CRX")"
want_json=$'{\n  "external_crx": "/usr/local/lib/omacvm/youtube-vp9.crx",\n  "external_version": "1.0"\n}'
expect "Chrome's file: the copy's path as the VM sees it, the version" "$want_json" "$(cat "$CH/$id.json" 2>/dev/null)"
expect "Chromium's file: the same" "$want_json" "$(cat "$CR/$id.json" 2>/dev/null)"
perm() { if stat -c %a "$1" >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }
expect "the key: root only (600); /var/lib/omacvm keeps its mode (other features' state)" "600 755" "$(perm "$KEY") $(perm "$(dirname "$KEY")")"
expect "the copy and the files: readable by all (644)" "644 644 644" "$(perm "$CRX") $(perm "$CH/$id.json") $(perm "$CR/$id.json")"
cp "$CRX" "$T/before.crx"
out=$("$G/install.sh" on)
expect "on again: nothing new" "  Prefer VP9 on YouTube: on" "$out"
expect "on again: the same copy (same key)" same "$(cmp -s "$CRX" "$T/before.crx" && echo same || echo differ)"
expect "on and on again: no temporary files left" 0 "$(find "$OMACVM_ROOT" -name '*.new' | wc -l | tr -d ' ')"
# Half there: Chromium's file gone, then a wrong version.
rm "$CR/$id.json"
expect "status: Chromium's file missing = bad" "bad not named in /usr/share/chromium/extensions/$id.json" "$("$G/install.sh" --status)"
"$G/install.sh" on >/dev/null
expect "on puts it back" "ok $id" "$("$G/install.sh" --status)"
sed 's/"1.0"/"0.9"/' "$CH/$id.json" > "$T/j" && cat "$T/j" > "$CH/$id.json"
expect "status: an old version named = bad" "bad not named in /usr/share/google-chrome/extensions/$id.json" "$("$G/install.sh" --status)"
"$G/install.sh" on >/dev/null
# A copy named under another id (a key from before): ours by its path, so it goes.
printf '{"external_crx": "/usr/local/lib/omacvm/youtube-vp9.crx", "external_version": "1.0"}\n' > "$CR/oooooooooooooooooooooooooooooooo.json"
expect "status: an old id still named = bad" "bad an old copy is still named: /usr/share/chromium/extensions/oooooooooooooooooooooooooooooooo.json" "$("$G/install.sh" --status)"
"$G/install.sh" on >/dev/null
expect "on removes the old id's file" "ok $id no" "$("$G/install.sh" --status) $( [[ -e $CR/oooooooooooooooooooooooooooooooo.json ]] && echo yes || echo no)"
rm "$KEY"
expect "status: the key gone = bad" "bad its key is missing" "$("$G/install.sh" --status)"
"$G/install.sh" on >/dev/null
nid=$("$G/install.sh" --status); nid=${nid#ok }
expect "a new key: a new id, the old id's files gone" "yes no no" \
  "$( [[ $nid != "$id" && -f $CH/$nid.json ]] && echo yes || echo no) $( [[ -e $CH/$id.json ]] && echo yes || echo no) $( [[ -e $CR/$id.json ]] && echo yes || echo no)"
out=$("$G/install.sh" off); expect "off: exit 0" 0 $?
expect "off: says the browsers remove it at their next start" "  Prefer VP9 on YouTube: off (Chrome and Chromium remove the extension at their next start)" "$out"
expect "off: none" none "$("$G/install.sh" --status)"
expect "off: only the other extension's file is left" "$CH/aaaabbbbccccddddeeeeffffgggghhhh.json" "$(find "$OMACVM_ROOT" -type f)"
expect "off again: silent" "" "$("$G/install.sh" off)"
"$G/install.sh" bogus >/dev/null 2>&1; expect "a wrong word: usage, exit 2" 2 $?
unset OMACVM_ROOT

# ---------- the Mac side and the wiring ----------
line=$(grep '^youtube-vp9	' "$R/src/features.tsv")
IFS=$'\t' read -r _ def sides tags needs title _ <<<"$line"
expect "features.tsv: off, VM side, experimental + app-only + no-av1, needs nothing" "off vm experimental,app-only,no-av1 -" "$def $sides $tags $needs"
expect "features.tsv: its title" "Prefer VP9 on YouTube" "$title"
# OMACVM_MAC_AV1 answers for the Mac (mac-av1.swift asks VideoToolbox).
avail() {
  OMACVM_MAC_AV1=$1 bash -c 'source "$1/src/lib/features.sh"; features_load; i=$(feature_index youtube-vp9)
    if feature_available "$i"; then echo yes; else echo "no: $REASON"; fi
    j=$(feature_index chromium-video); feature_available "$j" && echo other-yes' _ "$R" | tr '\n' ' '
}
expect "a Mac without AV1 decoding: offered" "yes other-yes " "$(avail no)"
expect "a Mac that decodes AV1: not offered, says why; other features as before" \
  "no: needs a Mac without an AV1 decoder (this one decodes AV1 itself) other-yes " "$(avail hw)"
expect "not known (no answer from the tool): offered" "yes other-yes " "$(avail maybe)"
expect "mac-av1.swift asks VideoToolbox for AV1" 1 "$(grep -c 'VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)' "$R/src/youtube-vp9/mac-av1.swift")"
expect "build-app.sh builds mac-av1 into the app's tools" 1 "$(grep -c 'youtube-vp9/mac-av1; do' "$R/app/scripts/build-app.sh")"
expect "the VM installer runs its on and off" 2 "$(grep -c '"$R/youtube-vp9/guest/install.sh" o[nf]' "$R/src/guest/install.sh")"
expect "omacvm check has its line, for the control centre" 1 "$(grep -c '^  FEATURE=youtube-vp9$' "$R/src/guest/check.sh")"
expect "an update part of its own" "youtube-vp9	youtube-vp9/**" "$(grep '^youtube-vp9	' "$R/src/release/parts.tsv")"
expect "build: it goes on after the build" 1 "$(grep -c '^    youtube-vp9) \[\[ \$2 == off \]\] || usage' "$R/src/cmd/build.sh")"
exit $fail
