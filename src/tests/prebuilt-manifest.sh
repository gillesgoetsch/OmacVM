#!/bin/bash
# Prebuilt manifests are untrusted: bad values must fail the lookup (the build
# then happens here) and nothing from a manifest may run as code on the Mac.
# No network, no VM: OMACVM_PREBUILT_SOURCE points at a temporary folder.
#   src/tests/prebuilt-manifest.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/prebuilt/lib.sh"
fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PREBUILT_CACHE=$T/cache
export OMACVM_PREBUILT_SOURCE=$T/src
mkdir -p "$OMACVM_PREBUILT_SOURCE"
VERSION=$(cat "$R/src/VERSION")
M=$OMACVM_PREBUILT_SOURCE/omacvm-prebuilt-$VERSION-parallels.json
PWNED=$T/pwned
SUM=$(printf '%064d' 0)

expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# manifest KEY JSON-VALUE: a good manifest with one value replaced.
manifest() {
  python3 - "$M" "$VERSION" "$1" "$2" <<'PY'
import json, sys
m = {"format": 1, "route": "parallels", "omacvm": sys.argv[2], "omarchy": "4.0.3 (omarchy-mac abc1234)",
     "bundle": "Omarchy.pvm", "unpacked_kb": 7000000, "disk_gb": 64, "compression": "tar + zstd --long=27",
     "created": "2026-10-05T03:44:00Z", "size": 3600000000,
     "parts": [{"name": "omacvm-prebuilt-%s-parallels.tar.zst.part-aa" % sys.argv[2], "size": 3600000000, "sha256": "0" * 64}]}
if sys.argv[3]:
    m[sys.argv[3]] = json.loads(sys.argv[4])
json.dump(m, open(sys.argv[1], "w"))
PY
}

lookup() { (prebuilt_lookup parallels 2>/dev/null && echo "found $PB_DISK_GB $PB_BUNDLE $PB_SIZE") || echo refused; }

manifest "" ""
expect "a good manifest" "found 64 Omarchy.pvm 3600000000" "$(lookup)"
expect "a good manifest: omarchy" "4.0.3 (omarchy-mac abc1234)" "$(python3 "$R/src/prebuilt/manifest.py" get "$M" omarchy)"
expect "a good manifest: parts" "omacvm-prebuilt-$VERSION-parallels.tar.zst.part-aa 3600000000 $SUM" \
  "$(python3 "$R/src/prebuilt/manifest.py" parts "$M")"

# The payload from the review: bash arithmetic on "BASH_VERSINFO[$(cmd)0]" runs cmd.
for key in disk_gb size unpacked_kb; do
  rm -f "$PWNED"
  manifest "$key" "\"BASH_VERSINFO[\$(touch $PWNED)0]\""
  expect "$key with a command in it: refused" refused "$(lookup)"
  ( PB_DISK_GB=64; prebuilt_lookup parallels >/dev/null 2>&1; pb_disk_bigger 128 ) >/dev/null 2>&1
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
route not ours|route|"Parallels;x"
created odd|created|"$(date)"
EOF

# Parts: sizes must be plain integers too.
manifest parts '[{"name": "omacvm-prebuilt-'"$VERSION"'-parallels.tar.zst.part-aa", "size": "1e3", "sha256": "'"$SUM"'"}]'
python3 "$R/src/prebuilt/manifest.py" parts "$M" >/dev/null 2>&1; expect "a part size as a string: refused" 1 $?
manifest parts '[{"name": "../x", "size": 1, "sha256": "'"$SUM"'"}]'
python3 "$R/src/prebuilt/manifest.py" parts "$M" >/dev/null 2>&1; expect "a part name with a path: refused" 1 $?
manifest "" ""
python3 "$R/src/prebuilt/manifest.py" get "$M" parts >/dev/null 2>&1; expect "get of a key it does not check: refused" 1 $?

# A release list with an odd tag or URL is skipped, not printed.
cat > "$T/rel.json" <<EOF
[{"tag_name": "prebuilt-$VERSION x", "assets": [{"name": "omacvm-prebuilt-$VERSION-parallels.json", "browser_download_url": "https://github.com/a/b/c.json"}]},
 {"tag_name": "prebuilt-$VERSION", "assets": [{"name": "omacvm-prebuilt-$VERSION-parallels.json", "browser_download_url": "http://evil/c.json"}]}]
EOF
python3 "$R/src/prebuilt/manifest.py" release "$T/rel.json" "$VERSION" parallels >/dev/null 2>&1
expect "odd tags and URLs in the release list: none taken" 1 $?

# No manifest value inside (( )) or $(( )) in the scripts that use them.
expect "no PB_ value in bash arithmetic" "" "$(grep -nE '\(\([^)]*\bPB_[A-Z_]+' "$R"/src/prebuilt/*.sh "$R"/src/cmd/build.sh "$R"/app/scripts/*.sh 2>/dev/null | grep -v '10#\$PB_DISK_GB' | grep -v '\bPB_OK\b')"

exit $fail
