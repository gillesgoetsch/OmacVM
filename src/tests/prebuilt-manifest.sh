#!/bin/bash
# Prebuilt manifests and images are untrusted: a manifest not signed with a
# release key (throwaway test keys here) or bad values must fail the lookup
# (the build then happens here), nothing from a manifest may run as code on
# the Mac, and OmacVM.app's image gives a plain disk.img or nothing. Also the
# seed's file mode and the free-space check. No network, no VM:
# OMACVM_PREBUILT_SOURCE points at a temporary folder.
#   src/tests/prebuilt-manifest.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/prebuilt/lib.sh"
fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PREBUILT_CACHE=$T/cache
source "$R/src/tests/release-test-keys.sh"
export OMACVM_PREBUILT_SOURCE=$T/src
mkdir -p "$OMACVM_PREBUILT_SOURCE"
VERSION=$(cat "$R/src/VERSION")
M=$OMACVM_PREBUILT_SOURCE/omacvm-prebuilt-$VERSION-app.json
PWNED=$T/pwned
SUM=$(printf '%064d' 0)

expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# manifest KEY JSON-VALUE [SIGNING-KEY]: a good manifest with one value
# replaced ("null": left out), signed with test-key or SIGNING-KEY.
manifest() {
  python3 - "$M" "$VERSION" "$1" "$2" <<'PY'
import json, sys
m = {"format": 1, "kind": "prebuilt-manifest", "devid_teams": ["722686Y34B"],
     "route": "app", "omacvm": sys.argv[2], "omarchy": "4.5.0 (aarch64 stable)",
     "bundle": "Omarchy", "unpacked_kb": 7000000, "disk_gb": 64, "compression": "tar + zstd --long=27",
     "created": "2026-10-05T03:44:00Z", "size": 3600000000,
     "parts": [{"name": "omacvm-prebuilt-%s-app.tar.zst.part-aa" % sys.argv[2], "size": 3600000000, "sha256": "0" * 64}]}
if sys.argv[3]:
    m[sys.argv[3]] = json.loads(sys.argv[4])
    if m[sys.argv[3]] is None:
        del m[sys.argv[3]]
json.dump(m, open(sys.argv[1], "w"))
PY
  sign_doc "$M" "${3:-}"
}

lookup() { (prebuilt_lookup app 2>/dev/null && echo "found $PB_DISK_GB $PB_BUNDLE $PB_SIZE") || echo refused; }

manifest "" ""
expect "a good manifest" "found 64 Omarchy 3600000000" "$(lookup)"
expect "a good manifest: omarchy" "4.5.0 (aarch64 stable)" "$(python3 "$R/src/prebuilt/manifest.py" get "$M" omarchy)"
expect "a good manifest: parts" "omacvm-prebuilt-$VERSION-app.tar.zst.part-aa 3600000000 $SUM" \
  "$(python3 "$R/src/prebuilt/manifest.py" parts "$M")"

# The signature comes first: either release key, nothing else.
manifest "" "" spare-key
expect "signed with the spare key" "found 64 Omarchy 3600000000" "$(lookup)"
manifest "" "" stranger-key
expect "signed with another key: refused" refused "$(lookup)"
python3 "$R/src/prebuilt/manifest.py" parts "$M" >/dev/null 2>&1; expect "signed with another key: no parts" 1 $?
manifest "" ""
rm -f "$OMACVM_PREBUILT_SOURCE/$(basename "$M").sig"
expect "no signature: refused" refused "$(lookup)"
manifest "" ""
printf ' ' >> "$M"
expect "changed after signing: refused" refused "$(lookup)"
( unset OMACVM_RELEASE_TEST_KEYS; manifest "" ""; lookup ) > "$T/out"
expect "signed with a test key, checked with the shipped keys: refused" refused "$(cat "$T/out")"
while IFS='|' read -r what key value; do
  manifest "$key" "$value"
  expect "$what: refused" refused "$(lookup)"
done <<'EOF'
no kind|kind|null
the app's feed|kind|"app-feed"
the control centre's manifest|kind|"control-manifest"
no devid_teams|devid_teams|null
empty devid_teams|devid_teams|[]
a bad team|devid_teams|["722686y34b"]
next_spare_key not a key|next_spare_key|"bm90IGEga2V5"
EOF
manifest devid_teams '["722686Y34B", "ABCDE12345"]'
expect "two teams" "found 64 Omarchy 3600000000" "$(lookup)"

# The payload from the review: bash arithmetic on "BASH_VERSINFO[$(cmd)0]" runs cmd.
for key in disk_gb size unpacked_kb; do
  rm -f "$PWNED"
  manifest "$key" "\"BASH_VERSINFO[\$(touch $PWNED)0]\""
  expect "$key with a command in it: refused" refused "$(lookup)"
  ( PB_DISK_GB=64; prebuilt_lookup app >/dev/null 2>&1; pb_disk_bigger 128 ) >/dev/null 2>&1
  expect "$key with a command in it: nothing ran" no "$([[ -e $PWNED ]] && echo yes || echo no)"
done
rm -f "$PWNED"
out=$( (PB_DISK_GB="BASH_VERSINFO[\$(touch $PWNED)0]"; pb_disk_bigger 128) 2>&1); rc=$?
expect "pb_disk_bigger with a command in PB_DISK_GB: dies" 1 "$rc"
expect "pb_disk_bigger with a command in PB_DISK_GB: nothing ran" no "$([[ -e $PWNED ]] && echo yes || echo no)"
expect "pb_disk_bigger 128 > 64" yes "$( (PB_DISK_GB=64; pb_disk_bigger 128) && echo yes || echo no)"
expect "pb_disk_bigger 64 > 64" no "$( (PB_DISK_GB=64; pb_disk_bigger 64) && echo yes || echo no)"

# Values that are not plain integers or safe names.
while IFS='|' read -r what key value; do
  manifest "$key" "$value"
  expect "$what: refused" refused "$(lookup)"
done <<'EOF'
disk_gb as a string|disk_gb|"64"
disk_gb as a float|disk_gb|64.0
disk_gb true|disk_gb|true
disk_gb 0|disk_gb|0
disk_gb too big|disk_gb|5000
disk_gb negative|disk_gb|-1
size as a string|size|"3600000000"
size 0|size|0
bundle ..|bundle|".."
bundle .|bundle|"."
bundle with a slash|bundle|"../../Library/x"
bundle empty|bundle|""
bundle with a space|bundle|"a b"
omacvm with more after it|omacvm|"2.8.0; touch x"
omacvm as a number|omacvm|2.8
omarchy with an escape|omarchy|"4.0\u001b]52;c;eA==\u0007"
omarchy too long|omarchy|"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
route not ours|route|"Other;x"
created odd|created|"$(date)"
EOF

# Parts: sizes must be plain integers too.
manifest parts '[{"name": "omacvm-prebuilt-'"$VERSION"'-app.tar.zst.part-aa", "size": "1e3", "sha256": "'"$SUM"'"}]'
python3 "$R/src/prebuilt/manifest.py" parts "$M" >/dev/null 2>&1; expect "a part size as a string: refused" 1 $?
manifest parts '[{"name": "../x", "size": 1, "sha256": "'"$SUM"'"}]'
python3 "$R/src/prebuilt/manifest.py" parts "$M" >/dev/null 2>&1; expect "a part name with a path: refused" 1 $?
manifest "" ""
python3 "$R/src/prebuilt/manifest.py" get "$M" parts >/dev/null 2>&1; expect "get of a key it does not check: refused" 1 $?

# A release list with an odd tag or URL is skipped, not printed.
cat > "$T/rel.json" <<EOF
[{"tag_name": "prebuilt-$VERSION x", "assets": [{"name": "omacvm-prebuilt-$VERSION-app.json", "browser_download_url": "https://github.com/a/b/c.json"}]},
 {"tag_name": "prebuilt-$VERSION", "assets": [{"name": "omacvm-prebuilt-$VERSION-app.json", "browser_download_url": "http://evil/c.json"}]}]
EOF
python3 "$R/src/prebuilt/manifest.py" release "$T/rel.json" "$VERSION" app >/dev/null 2>&1
expect "odd tags and URLs in the release list: none taken" 1 $?

# The local lookup by route (one regex for all).
for route in app; do
  touch "$OMACVM_PREBUILT_SOURCE/omacvm-prebuilt-$VERSION-$route.json"
  expect "local lookup: $route" "omacvm-prebuilt-$VERSION-$route.json $VERSION" \
    "$(python3 "$R/src/prebuilt/manifest.py" local "$OMACVM_PREBUILT_SOURCE" "$VERSION" "$route")"
done

# OmacVM.app's image: only <bundle>/disk.img comes out, as a plain file.
# archive NAME: packs $T/a (tar + zstd) as the only part of the manifest.
archive() {
  local part=omacvm-prebuilt-$VERSION-app.tar.zst.part-aa
  mkdir -p "$PREBUILT_CACHE/app"
  COPYFILE_DISABLE=1 tar -cf - -C "$T/a" . | zstd -q -c > "$PREBUILT_CACHE/app/$part"
  PB_MANIFEST=$PREBUILT_CACHE/app/m.json PB_BUNDLE=Omarchy
  printf '{"kind": "prebuilt-manifest", "devid_teams": ["722686Y34B"], "parts": [{"name": "%s", "size": %s, "sha256": "%s"}]}' "$part" \
    "$(stat -f %z "$PREBUILT_CACHE/app/$part")" "$SUM" > "$PB_MANIFEST"
  sign_doc "$PB_MANIFEST"
}
take() { rm -f "$T/disk.img"; (prebuilt_unpack_disk "$T/u" "$T/disk.img") >/dev/null 2>&1 && echo taken || echo refused; }
if command -v zstd >/dev/null; then
  echo secret > "$T/victim"
  rm -rf "$T/a"; mkdir -p "$T/a/Omarchy"; printf 'disk' > "$T/a/Omarchy/disk.img"; archive
  expect "app image: a plain disk.img is taken" taken "$(take)"
  expect "app image: its content" disk "$(cat "$T/disk.img" 2>/dev/null)"
  expect "app image: the work folder is gone" no "$([[ -e $T/u ]] && echo yes || echo no)"
  rm -rf "$T/a"; mkdir -p "$T/a/Omarchy"; ln -s "$T/victim" "$T/a/Omarchy/disk.img"; archive
  expect "app image: disk.img as a symlink is refused" refused "$(take)"
  expect "app image: the symlink's target is untouched" secret "$(cat "$T/victim")"
  expect "app image: no disk left" no "$([[ -e $T/disk.img || -L $T/disk.img ]] && echo yes || echo no)"
  rm -rf "$T/a"; mkdir -p "$T/a"; ln -s "$T" "$T/a/Omarchy"; archive
  expect "app image: the bundle as a symlink is refused" refused "$(take)"
  # A hard link to a file on the Mac (absolute, or out through ..): tar does
  # not make it, or it is refused after.
  for target in "$T/victim" ../../victim; do
    python3 - "$T/raw.tar" "$target" <<'PY'
import sys, tarfile
with tarfile.open(sys.argv[1], "w") as t:
    d = tarfile.TarInfo("Omarchy"); d.type = tarfile.DIRTYPE; d.mode = 0o755; t.addfile(d)
    h = tarfile.TarInfo("Omarchy/disk.img"); h.type = tarfile.LNKTYPE; h.linkname = sys.argv[2]; t.addfile(h)
PY
    zstd -q -c "$T/raw.tar" > "$PREBUILT_CACHE/app/omacvm-prebuilt-$VERSION-app.tar.zst.part-aa"
    expect "app image: disk.img as a hard link to $target is refused" refused "$(take)"
    expect "app image: hard link to $target: target untouched, one link" "secret 1" "$(cat "$T/victim") $(stat -f %l "$T/victim")"
  done
  rm -rf "$T/a"; mkdir -p "$T/a/Omarchy"; printf 'x' > "$T/a/Omarchy/other.img"; archive
  expect "app image: no disk.img is refused" refused "$(take)"
else
  echo "skip app image tests: no zstd"
fi

# The seed: mode 600 from the start, its work folder gone on every path.
mkdir -p "$T/tmp" "$T/seed"; ssh-keygen -q -t ed25519 -N "" -f "$T/key"
seed_vars() { U=anna FULL="Anna B" HASH='$6$salt$hash' HOST=omarchy KB=us TZ_MAC=UTC LANG_VM=en_US.UTF-8 TYPE=app KEY=$T/key; }
( seed_vars; TMPDIR=$T/tmp; umask 022; prebuilt_seed "$T/seed/seed.iso" ) >/dev/null 2>&1
expect "seed: made" yes "$([[ -s $T/seed/seed.iso ]] && echo yes || echo no)"
expect "seed: mode 600" 600 "$(stat -f %Lp "$T/seed/seed.iso" 2>/dev/null)"
expect "seed: no work folder left" "" "$(ls "$T/tmp")"
( seed_vars; TMPDIR=$T/tmp; prebuilt_seed "$T/nope/seed.iso" ) >/dev/null 2>&1
expect "seed: hdiutil fails: an error" 1 $?
expect "seed: hdiutil fails: no work folder left" "" "$(ls "$T/tmp")"

# Free space: an image bigger than the disk is refused with a message.
out=$( (PB_SIZE=1000 PB_UNPACKED_KB=999999999999; prebuilt_space_ok "$T") 2>&1); rc=$?
expect "free space: too little: refused" 1 "$rc"
expect "free space: too little: says so" yes "$([[ $out == "not enough free space"* ]] && echo yes || echo "$out")"
expect "free space: enough" 0 "$( (PB_SIZE=1000 PB_UNPACKED_KB=1000; prebuilt_space_ok "$T") >/dev/null 2>&1; echo $?)"

# make-image.sh's manifest carries OMACVM_REVOKED_KEYS like the app's feed (docs/release-keys.md).
S=$(cat "$T/stranger-key.pub")
head -c 10 /dev/zero > "$T/part-aa"
mw() { python3 "$R/src/prebuilt/manifest.py" write "$T/w.json" --route app --omacvm "$VERSION" --omarchy 4 --bundle Omarchy \
  --unpacked 1 --disk-gb 64 --teams '["722686Y34B"]' --next-spare-key "" "$@" "$T/part-aa" >/dev/null 2>&1; }
mw --revoked-keys "$S $S"
expect "manifest.py write: revoked_keys, once per key" "[\"$S\"]" "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get("revoked_keys")))' "$T/w.json")"
mw --revoked-keys ""
expect "manifest.py write: no revoked_keys when empty" None "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("revoked_keys"))' "$T/w.json")"
expect "manifest.py write: not a key refused" 1 "$(mw --revoked-keys bm90; echo $?)"
expect "make-image.sh passes OMACVM_REVOKED_KEYS" 1 "$(grep -c -- '--revoked-keys "${OMACVM_REVOKED_KEYS:-}"' "$R/src/prebuilt/make-image.sh")"

# The commit an image was made from (3.4.0 on; release.sh ties it to the release commit).
C40=0123456789abcdef0123456789abcdef01234567
mw --commit "$C40"
expect "manifest.py write: the commit" "\"$C40\"" "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get("commit")))' "$T/w.json")"
expect "manifest.py write: not a full commit id refused" 1 "$(mw --commit 0123abc; echo $?)"
mw --commit ""
expect "manifest.py write: no commit when empty" None "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("commit"))' "$T/w.json")"
manifest commit "\"$C40\""
expect "manifest.py get commit" "$C40" "$(python3 "$R/src/prebuilt/manifest.py" get "$M" commit)"
manifest "" ""
expect "manifest.py get commit: none in an older image" "" "$(python3 "$R/src/prebuilt/manifest.py" get "$M" commit)"
manifest commit '"main; rm -rf /"'
expect "manifest.py get: a commit that is no commit id fails the manifest" 1 "$(python3 "$R/src/prebuilt/manifest.py" get "$M" route >/dev/null 2>&1; echo $?)"
manifest "" ""

# From 3.4.0 new VMs are Omarchy 4.5 (manifest.py OMARCHY_FLOOR): an app at
# 3.4.0 or later takes no image from before prebuilt-3.4.0 and no manifest
# below Omarchy 4.5; older apps are as before. Fixed versions, not src/VERSION.
fit() { python3 "$R/src/prebuilt/manifest.py" fits "$1" "$2" && echo yes || echo no; }
expect "fits: 3.4.0 app, Omarchy 4.5.0" yes "$(fit 3.4.0 "4.5.0 (aarch64 stable)")"
expect "fits: 3.4.0 app, Omarchy 4.10" yes "$(fit 3.4.0 "4.10.1 (aarch64 stable)")"
expect "fits: 3.4.0 app, Omarchy 5.0" yes "$(fit 3.4.0 "5.0.0")"
expect "fits: 3.4.0 app, omarchy-mac 4.0" no "$(fit 3.4.0 "4.0.3rc4 (omarchy-mac ba546a61f)")"
expect "fits: 3.4.1 app, Omarchy 4.4" no "$(fit 3.4.1 "4.4.9")"
expect "fits: 3.4.0 app, no version" no "$(fit 3.4.0 "unknown")"
expect "fits: 3.4.0 app, 45.0 is not 4.5" yes "$(fit 3.4.0 "45.0")"
expect "fits: 3.4.0 app, 4.50 is not 4.5" yes "$(fit 3.4.0 "4.50")"
expect "fits: 3.3.1 app, omarchy-mac 4.0" yes "$(fit 3.3.1 "4.0.3rc4 (omarchy-mac ba546a61f)")"
expect "fits: bad app version refused" no "$(fit 3.4 "4.5.0" 2>/dev/null)"
F=$T/floor; mkdir -p "$F"
for v in 3.0.0 3.0.8 3.3.0; do touch "$F/omacvm-prebuilt-$v-app.json"; done
loc() { python3 "$R/src/prebuilt/manifest.py" local "$F" "$1" app 2>/dev/null || echo none; }
expect "floor: 3.3.1 app takes prebuilt-3.3.0" "omacvm-prebuilt-3.3.0-app.json 3.3.0" "$(loc 3.3.1)"
expect "floor: 3.4.0 app takes no 4.0 image" none "$(loc 3.4.0)"
touch "$F/omacvm-prebuilt-3.4.0-app.json" "$F/omacvm-prebuilt-3.5.0-app.json"
expect "floor: 3.4.2 app takes prebuilt-3.4.0" "omacvm-prebuilt-3.4.0-app.json 3.4.0" "$(loc 3.4.2)"
expect "floor: 3.3.1 app never takes prebuilt-3.4.0" "omacvm-prebuilt-3.3.0-app.json 3.3.0" "$(loc 3.3.1)"
python3 - "$T/rel-floor.json" <<'PY2'
import json, sys
u = "https://github.com/gillesgoetsch/omacvm/releases/download/%s/%s"
rel = [{"tag_name": "prebuilt-" + v, "published_at": "2026-11-0%dT00:00:00Z" % i,
        "assets": [{"name": "omacvm-prebuilt-%s-app.json" % v, "browser_download_url": u % ("prebuilt-" + v, "omacvm-prebuilt-%s-app.json" % v)}]}
       for i, v in enumerate(["3.0.0", "3.0.8", "3.4.0"], 1)]
json.dump(rel, open(sys.argv[1], "w"))
PY2
rel() { python3 "$R/src/prebuilt/manifest.py" release "$T/rel-floor.json" "$1" app 2>/dev/null | awk '{ print $1, $3 }' || true; }
expect "floor (releases): 3.4.0 app takes prebuilt-3.4.0" "prebuilt-3.4.0 3.4.0" "$(rel 3.4.0)"
expect "floor (releases): 3.3.1 app takes prebuilt-3.0.8" "prebuilt-3.0.8 3.0.8" "$(rel 3.3.1)"
expect "lib.sh: the lookup asks manifest.py fits" 1 "$(grep -c 'manifest.py" fits "$version" "$PB_OMARCHY" || return 1' "$R/src/prebuilt/lib.sh")"

# No manifest value inside (( )) or $(( )) in the scripts that use them, except
# behind 10# (then a value with letters is an error, never an expression).
expect "no PB_ value in bash arithmetic" "" "$(grep -nE '\(\([^)]*\bPB_[A-Z_]+' "$R"/src/prebuilt/*.sh "$R"/src/cmd/build.sh "$R"/app/scripts/*.sh 2>/dev/null |
  sed -E -e 's/10#\$PB_[A-Z_]+//g' -e 's/PB_OK//g' | grep -E '\(\([^)]*\bPB_[A-Z_]+')"

exit $fail
