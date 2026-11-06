#!/bin/bash
# The moves gate (src/release/release.sh step moves, from 3.4.0): the move
# matrix's rows (src/tests/e2e/move-45.sh) summed up, and the gate passes only
# when every row passed on three 4.0 VMs of different ages, "clean" on each,
# rows from two Macs with the last two clean moves passed on each (G6), one
# tested commit, and the move's files are the same in that commit and the
# release commit M. The newest run of a row counts. Then the image gate: step
# image takes only an image made at M (or at a commit whose image files are
# M's) and records that; publish takes only that image, unchanged, and
# uploads it before the app's release. No VM, no network: rows are written by
# hand, M is a commit in a throwaway git repo, the image a small stand-in
# signed with a throwaway key.
#   src/tests/move-45-gate.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
PY=$R/src/tests/e2e/move-45-result.py
fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
expect() { if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi; }

# A repo with the kit at commit C, then M (and M2: a move file changed).
G=$T/repo; mkdir -p "$G/src/tests/e2e" "$G/app/scripts"
cp "$R/src/tests/e2e/move-45.sh" "$R/src/tests/e2e/move-45-result.py" "$G/src/tests/e2e/"
echo v1 > "$G/app/scripts/move-vm.sh"; echo a > "$G/README"
gi() { git -C "$G" -c user.name=t -c user.email=t@t "$@"; }
gi init -q; gi add -A; gi commit -qm c; C=$(gi rev-parse HEAD)
echo b >> "$G/README"; gi commit -qam m; M=$(gi rev-parse HEAD)
echo v2 > "$G/app/scripts/move-vm.sh"; gi commit -qam m2; M2=$(gi rev-parse HEAD)

ROWS=$("$G/src/tests/e2e/move-45.sh" --rows | awk '{ print $1 }')
expect "the kit lists its rows" 21 "$(wc -l <<<"$ROWS" | tr -d ' ')"
expect "the kit lists the files a result is tied to" 1 "$("$G/src/tests/e2e/move-45.sh" --paths | grep -c '^app/scripts/move-vm.sh$')"

mkrow() {   # DIR ROW BASE OK [MAC] [COMMIT] [ENDED]: one run of a row, as move-45.sh writes it
  local f="$1/rows/$2-$3-${5:-mini}-${7:-0}.json"
  printf 'a check\t%s\tdetail\n' "$4" | MOVE45_MAC=${5:-mini} MOVE45_COMMIT=${6:-$C} python3 -I "$PY" row "$f" "$2" "$3" 5 >/dev/null
  [[ -n ${7:-} ]] && python3 -I -c 'import json,sys; p=sys.argv[1]; o=json.load(open(p)); o["ended"]=int(sys.argv[2]); json.dump(o, open(p,"w"))' "$f" "$7"
  return 0
}
full() {   # DIR: every row on base A (mini), clean on B and C (M1), a second clean move on the mini
  mkdir -p "$1/rows"
  local r; for r in $ROWS; do mkrow "$1" "$r" "M-mv-a300" 1 mini "" 100; done
  mkrow "$1" clean "M-mv-a308" 1 mini "" 200
  mkrow "$1" clean "M-mv-a308" 1 m1 "" 100; mkrow "$1" clean "M-mv-a40b" 1 m1 "" 200
}
sumrc() { "$G/src/tests/e2e/move-45.sh" --summary "$1" >/dev/null 2>&1; echo $?; }
gate() { python3 -I "$PY" gate "$1/result.json" "$2" "$G" >/dev/null 2>&1; echo $?; }
key() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))[sys.argv[2]]))' "$1/result.json" "$2"; }

D=$T/ok; full "$D"
expect "every row, three ages, two Macs: summary passes" 0 "$(sumrc "$D")"
expect "gate: passes for M (only README changed)" 0 "$(gate "$D" "$M")"
expect "gate: refused for M2 (move-vm.sh changed after the test)" 1 "$(gate "$D" "$M2")"
expect "gate: the result names the tested commit" "\"$C\"" "$(key "$D" commit)"
expect "two clean moves in a row on both Macs" '["m1", "mini"]' "$(key "$D" g6_macs)"

D=$T/onefail; full "$D"; mkrow "$D" kill-commit "M-mv-a300" 0 mini "" 300
expect "one row failed (its newest run): summary fails" 1 "$(sumrc "$D")"
expect "one row failed: gate refuses" 1 "$(gate "$D" "$M")"
expect "one row failed: named with its Mac" '["kill-commit/M-mv-a300/mini"]' "$(key "$D" failed)"

D=$T/rerun; full "$D"; mkrow "$D" power-backup "M-mv-a300" 0 mini "" 50
expect "a row that failed and passed when run again: the newest run counts" 0 "$(sumrc "$D")"

D=$T/missing; full "$D"; rm "$D/rows/power-loss-M-mv-a300-mini-100.json"
expect "a row never run: summary fails" 1 "$(sumrc "$D")"
expect "a row never run: named" '["power-loss"]' "$(key "$D" missing_rows)"

D=$T/twoages; full "$D"; rm "$D/rows/clean-M-mv-a40b-m1-200.json" "$D/rows/clean-M-mv-a308-m1-100.json"
mkrow "$D" clean "M-mv-a300" 1 m1 "" 100; mkrow "$D" clean "M-mv-a300" 1 m1 "" 150
expect "only two ages: summary fails" 1 "$(sumrc "$D")"

D=$T/twocommits; full "$D"; mkrow "$D" clean "M-mv-a40b" 1 m1 "$M" 300
expect "rows from two commits: summary fails" 1 "$(sumrc "$D")"

D=$T/onemac; mkdir -p "$D/rows"
for r in $ROWS; do mkrow "$D" "$r" "M-mv-a300" 1 mini "" 100; done
mkrow "$D" clean "M-mv-a308" 1 mini "" 200; mkrow "$D" clean "M-mv-a40b" 1 mini "" 300
expect "every row on one Mac only: summary fails (two Macs)" 1 "$(sumrc "$D")"
expect "every row on one Mac only: gate refuses" 1 "$(gate "$D" "$M")"

D=$T/g6; full "$D"
mkrow "$D" clean "M-mv-a40b" 0 m1 "" 300; mkrow "$D" clean "M-mv-a40b" 1 m1 "" 400
expect "M1: its newest clean moves were FAIL then PASS: summary fails (G6)" 1 "$(sumrc "$D")"
expect "M1: G6 not met, the mini's is" '["mini"]' "$(key "$D" g6_macs)"
mkrow "$D" clean "M-mv-a308" 1 m1 "" 500
expect "M1: two passes in a row after that: summary passes" 0 "$(sumrc "$D")"

D=$T/onecleanm1; full "$D"; rm "$D/rows/clean-M-mv-a308-m1-100.json"
mkrow "$D" undo "M-mv-a308" 1 m1 "" 100
expect "one clean move on the M1 only: summary fails (G6)" 1 "$(sumrc "$D")"

D=$T/old; full "$D"; sumrc "$D" >/dev/null
python3 -I -c 'import json,sys; p=sys.argv[1]; o=json.load(open(p)); o["format"]=1; json.dump(o, open(p,"w"))' "$D/result.json"
expect "a result from the kit before (format 1): gate refuses" 1 "$(gate "$D" "$M")"
D=$T/bad; mkdir -p "$D"; echo '{"kind": "omacvm-e2e-cc-switches", "pass": true}' > "$D/result.json"
expect "another kind of result: gate refuses" 1 "$(gate "$D" "$M")"

# The disk digest Undo is checked with: holes read as zeros (a sparse and a dense copy agree), one byte differs.
mkfile -n 30m "$T/s1" 2>/dev/null || dd if=/dev/zero of="$T/s1" bs=1 count=0 seek=30m 2>/dev/null
printf 'hello' | dd of="$T/s1" bs=1 seek=3000000 conv=notrunc 2>/dev/null
dd if="$T/s1" of="$T/s2" bs=1048576 2>/dev/null
cp "$T/s1" "$T/s3"; printf 'x' | dd of="$T/s3" bs=1 seek=20000000 conv=notrunc 2>/dev/null
dg() { python3 -I "$PY" digest "$1"; }
expect "digest: a sparse and a dense copy agree" "$(dg "$T/s1")" "$(dg "$T/s2")"
expect "digest: one byte changed differs" 1 "$([[ $(dg "$T/s1") != "$(dg "$T/s3")" ]] && echo 1 || echo 0)"

# release.sh asks for the gate from 3.4.0 on.
expect "release.sh: step moves in the default steps" 1 "$(grep -c 'e2e moves publish after)' "$R/src/release/release.sh")"
expect "release.sh: the gate runs move-45-result.py" 1 "$(grep -c 'move-45-result.py" gate' "$R/src/release/release.sh")"

# ---- the image gate, run: release.sh from a throwaway repo (its src/, git history C -> M, M3) ----
# C: the image's commit; M: README only changed (the image's files are M's); M3: a guest file changed.
X=$T/rel; mkdir -p "$X"; rsync -a --exclude tests "$R/src/" "$X/src/"; echo a > "$X/README"
gx() { git -C "$X" -c user.name=t -c user.email=t@t "$@"; }
gx init -q; gx config user.name t; gx config user.email t@t; gx add -A; gx commit -qm c; IC=$(gx rev-parse HEAD)
echo b >> "$X/README"; gx commit -qam m; IM=$(gx rev-parse HEAD)
echo "# changed" >> "$X/src/guest/install.sh"; gx commit -qam m3; IM3=$(gx rev-parse HEAD)
source "$R/src/tests/release-test-keys.sh"   # OMACVM_RELEASE_TEST_KEYS, $T/sign, sign_doc
H=$T/h; mkdir -p "$H"
B=omacvm-prebuilt-9.9.9-app
mkimg() {   # DIR COMMIT ["" = none]: a signed stand-in image for 9.9.9 (Omarchy 4.5) made at COMMIT
  rm -rf "$1"; mkdir -p "$1"; head -c 4096 /dev/urandom > "$1/$B.tar.zst.part-aa"
  python3 -I "$X/src/prebuilt/manifest.py" write "$1/$B.json" --route app --omacvm 9.9.9 --omarchy "4.5.0 (aarch64 stable)" \
    --bundle Omarchy --unpacked 10 --disk-gb 64 --teams '["722686Y34B"]' --commit "$2" "$1/$B.tar.zst.part-aa" >/dev/null
  sign_doc "$1/$B.json"; (cd "$1" && shasum -a 256 "$B.tar.zst.part-aa" "$B.json" "$B.json.sig" > "$B.sha256")
}
O=$T/out; RS=$O/release/state
rel() { HOME=$H OMACVM_RELEASE_OUT=$O OMACVM_RELEASE_NOTES=$T/notes.md "$X/src/release/release.sh" "$@" > "$T/rel.out" 2>&1 < /dev/null; }
st() { sed -n "s/^$1=//p" "$RS" | tail -1; }
echo "release text" > "$T/notes.md"
mkdir -p "$O/release"; printf 'M=%s\nE2E=pass\nE2E_M=%s\nMOVES=pass\nMOVES_M=%s\n' "$IM" "$IM" "$IM" > "$RS"
mkimg "$T/img-m" "$IM"
expect "image: one made at M is taken" 0 "$(OMACVM_RELEASE_IMAGE_FROM=$T/img-m rel 9.9.9 image; echo $?)"
expect "image: the state says it passed for M" "pass $IM" "$(st IMAGE) $(st IMAGE_M)"
mkimg "$T/img-c" "$IC"
expect "image: one made at a commit whose image files are M's is taken" 0 "$(OMACVM_RELEASE_IMAGE_FROM=$T/img-c rel 9.9.9 image; echo $?)"
mkimg "$T/img-none" ""
expect "image: one that names no commit is refused" 1 "$(OMACVM_RELEASE_IMAGE_FROM=$T/img-none rel 9.9.9 image; echo $?)"
expect "image: a refused image leaves no folder and no pass" "0 " "$([[ -e $O/release/prebuilt ]] && echo 1 || echo 0) $(st IMAGE)"
mkimg "$T/img-x" "$(printf '%040d' 7)"
expect "image: one made at a commit this repo does not have is refused" 1 "$(OMACVM_RELEASE_IMAGE_FROM=$T/img-x rel 9.9.9 image; echo $?)"
echo "M=$IM3" >> "$RS"
expect "image: one made at C for an M whose guest files differ is refused" 1 "$(OMACVM_RELEASE_IMAGE_FROM=$T/img-c rel 9.9.9 image; echo $?)"
grep -q "src/guest/install.sh" "$T/rel.out" && ok_="ok" || ok_="no"
expect "image: the refusal names the file" ok "$ok_"
echo "M=$IM" >> "$RS"

# publish: nothing of GitHub is touched before these refusals (no gh, no git tag: they would fail here).
rm -rf "$O/release/prebuilt"
expect "publish: 3.4.0+ without an image is refused" 1 "$(rel 9.9.9 publish; echo $?)"
expect "publish: says why" 1 "$(grep -c 'would build every new VM here' "$T/rel.out")"
mkdir -p "$O/release/prebuilt"; cp "$T/img-m"/* "$O/release/prebuilt/"; echo "IMAGE=" >> "$RS"
expect "publish: an image folder that did not pass step image is refused" 1 "$(rel 9.9.9 publish; echo $?)"
expect "publish: says so" 1 "$(grep -c 'has not passed step image for M' "$T/rel.out")"
OMACVM_RELEASE_IMAGE_FROM=$T/img-m rel 9.9.9 image
echo "M=$IM3" >> "$RS"; printf 'E2E_M=%s\nMOVES_M=%s\n' "$IM3" "$IM3" >> "$RS"
expect "publish: an image that passed for an earlier M is refused" 1 "$(rel 9.9.9 publish; echo $?)"
echo "M=$IM" >> "$RS"; printf 'E2E_M=%s\nMOVES_M=%s\n' "$IM" "$IM" >> "$RS"
mkimg "$T/img-m2" "$IM"; cp "$T/img-m2/$B.json" "$T/img-m2/$B.json.sig" "$T/img-m2/$B.sha256" "$T/img-m2/$B.tar.zst.part-aa" "$O/release/prebuilt/"
expect "publish: an image changed after step image is refused" 1 "$(rel 9.9.9 publish; echo $?)"
expect "publish: says so" 1 "$(grep -c 'changed after step image' "$T/rel.out")"
# The order (dry run: the commands it would run): the image up and checked before the app's tag and release.
DS=$O/dry-run/state; mkdir -p "$O/dry-run"; printf 'M=%s\nE2E=pass\nE2E_M=%s\nMOVES=pass\nMOVES_M=%s\n' "$IM" "$IM" "$IM" > "$DS"
OMACVM_RELEASE_IMAGE_FROM=$T/img-m rel --dry-run 9.9.9 image
rel --dry-run 9.9.9 publish
expect "publish (dry run): an image that passed is published" 0 "$?"
up=$(grep -n 'make-image.sh app upload' "$T/rel.out" | head -1 | cut -d: -f1); app=$(grep -n 'gh release create v9.9.9' "$T/rel.out" | head -1 | cut -d: -f1)
expect "publish: the image goes up (and is checked) before the app's release" 1 "$([[ -n $up && -n $app ]] && (( up < app )) && echo 1 || echo 0)"

# ---- the image's parts against its SIGNED manifest, on every path and at publish ----
# swap DIR: another part-aa, and a .sha256 made again to match it (the manifest and its .sig unchanged).
swap() { head -c 4096 /dev/urandom > "$1/$B.tar.zst.part-aa"; (cd "$1" && shasum -a 256 "$B.tar.zst.part-aa" "$B.json" "$B.json.sig" > "$B.sha256"); }
printf 'M=%s\nE2E=pass\nE2E_M=%s\nMOVES=pass\nMOVES_M=%s\nIMAGE=\n' "$IM" "$IM" "$IM" > "$RS"
mkimg "$T/img-sw" "$IM"; swap "$T/img-sw"
expect "image: a signed image with a part swapped (its .sha256 made again) is refused" 1 "$(OMACVM_RELEASE_IMAGE_FROM=$T/img-sw rel 9.9.9 image; echo $?)"
expect "image: says the part is not the signed manifest's" 1 "$(grep -q 'signed manifest' "$T/rel.out" && echo 1)"
mkimg "$T/img-ex" "$IM"; head -c 10 /dev/urandom > "$T/img-ex/$B.tar.zst.part-ab"
expect "image: a part the signed manifest does not list is refused" 1 "$(OMACVM_RELEASE_IMAGE_FROM=$T/img-ex rel 9.9.9 image; echo $?)"
mkimg "$T/img-m" "$IM"
OMACVM_RELEASE_IMAGE_FROM=$T/img-m rel 9.9.9 image
expect "image: a good one passes again" "pass" "$(st IMAGE)"
cp -R "$O/release/prebuilt" "$T/passed"
swap "$O/release/prebuilt"
expect "publish: a part swapped after step image (.sha256 made again) is refused" 1 "$(rel 9.9.9 publish; echo $?)"
expect "publish: says the sums changed" 1 "$(grep -q 'changed after step image' "$T/rel.out" && echo 1)"
rm -rf "$O/release/prebuilt"; cp -R "$T/passed" "$O/release/prebuilt"
head -c 4096 /dev/urandom > "$O/release/prebuilt/$B.tar.zst.part-aa"
expect "publish: a part swapped after step image (.sha256 as it was) is refused" 1 "$(rel 9.9.9 publish; echo $?)"
expect "publish: says the part is not the signed manifest's" 1 "$(grep -q 'signed manifest' "$T/rel.out" && echo 1)"
rm -rf "$O/release/prebuilt"; cp -R "$T/passed" "$O/release/prebuilt"
(cd "$O/release/prebuilt" && shasum -a 256 "$B.json" "$B.json.sig" > "$B.sha256")
expect "publish: a .sha256 changed after step image is refused (IMAGE_SUM)" 1 "$(rel 9.9.9 publish; echo $?)"
expect "publish: says so" 1 "$(grep -c 'changed after step image' "$T/rel.out")"
rm -rf "$O/release/prebuilt"; cp -R "$T/passed" "$O/release/prebuilt"

# ---- publish for real against a stand-in gh (no network): the prebuilt release must be M's ----
# The stand-in keeps releases in $GHS/rel/TAG/ (TAG.target: its target commit); GHS_TARGET and
# GHS_TAGSHA change what GitHub says, GHS_BAD names a part GitHub serves other bytes for (same size),
# GHS_NODIGEST=1 leaves the assets' digests out (older uploads).
GHS=$T/ghs; mkdir -p "$T/bin" "$GHS/rel"
cat > "$T/bin/gh" <<'GH'
#!/bin/bash
S=$GHS; echo "gh $*" >> "$S/calls"
a=(); while (( $# )); do case $1 in -R) shift ;; *) a+=("$1") ;; esac; shift; done; set -- "${a[@]}"
case "$1 $2" in
  "release view") [[ -d $S/rel/$3 ]] ;;
  "release create") t=$3; shift 3; tg=main
    while (( $# )); do [[ $1 == --target ]] && tg=$2; [[ -f $1 ]] && { mkdir -p "$S/rel/$t"; cp "$1" "$S/rel/$t/"; }; shift; done
    mkdir -p "$S/rel/$t"; echo "$tg" > "$S/rel/$t.target" ;;
  "release upload") t=$3; shift 3; [[ -d $S/rel/$t ]] || exit 1
    for f; do [[ -f $f ]] || continue; cp "$f" "$S/rel/$t/"
      [[ ${f##*/} == "${GHS_BAD:-none}" ]] && python3 -I -c 'import sys; p=sys.argv[1]; b=bytearray(open(p,"rb").read()); b[0]^=0xff; open(p,"wb").write(b)' "$S/rel/$t/${f##*/}"; done; true ;;   # same size, other bytes: only the SHA-256 can tell
  "release download") t=$3; shift 3; d=.; p=()
    while (( $# )); do case $1 in -D) d=$2; shift ;; -p) p+=("$2"); shift ;; esac; shift; done
    for x in "${p[@]}"; do cp "$S/rel/$t/$x" "$d/" || exit 1; done ;;
  "api "*/releases/tags/*) t=${2##*/}; [[ -d $S/rel/$t ]] || exit 1
    python3 -I - "$S/rel/$t" "${GHS_TARGET-$(cat "$S/rel/$t.target")}" "${GHS_NODIGEST:-0}" <<'PY'
import hashlib, json, os, sys
d, target, nod = sys.argv[1:]
a = [{"name": n, "size": os.path.getsize(os.path.join(d, n)),
      "digest": None if nod == "1" else "sha256:" + hashlib.sha256(open(os.path.join(d, n), "rb").read()).hexdigest()}
     for n in sorted(os.listdir(d))]
print(json.dumps({"tag_name": os.path.basename(d), "target_commitish": target, "draft": False, "assets": a}))
PY
    ;;
  "api "*/commits/*) t=${2##*/}; [[ -f $S/rel/$t.target ]] || exit 1; echo "${GHS_TAGSHA:-$(cat "$S/rel/$t.target")}" ;;
  *) echo "gh stand-in: $*" >&2; exit 1 ;;
esac
GH
chmod +x "$T/bin/gh"
# The worktree publish uploads from (make-image.sh at 9.9.9), and an origin for the tag.
WTX=$H/omacvm-rel-9.9.9-build; rm -rf "$WTX"; cp -R "$X" "$WTX"; echo 9.9.9 > "$WTX/src/VERSION"
git init -q --bare "$T/origin.git"; gx remote add origin "$T/origin.git"
for f in "$B-packages.txt" SOURCES.md; do echo x > "$O/release/prebuilt/$f"; done
mkdir -p "$O/release/files"; : > "$O/release/prebuilt-assets.txt"
pub() {   # [AT-COMMIT] [VAR=VALUE...]: publish with --yes against the stand-in (a prebuilt release already
  # there at AT-COMMIT when given); never the real gh: no token, an empty config, the stand-in first in PATH
  rm -rf "$GHS/rel" "$GHS/calls"; mkdir -p "$GHS/rel"; gx tag -d v9.9.9 >/dev/null 2>&1
  git -C "$T/origin.git" tag -d v9.9.9 >/dev/null 2>&1
  if [[ ${1:-} =~ ^[0-9a-f]{40}$ ]]; then mkdir -p "$GHS/rel/prebuilt-9.9.9"; echo "$1" > "$GHS/rel/prebuilt-9.9.9.target"; shift; fi
  env -u GH_TOKEN -u GITHUB_TOKEN GH_CONFIG_DIR=$T/ghcfg GHS=$GHS PATH="$T/bin:$PATH" "$@" \
    HOME=$H OMACVM_RELEASE_OUT=$O OMACVM_RELEASE_NOTES=$T/notes.md "$X/src/release/release.sh" --yes 9.9.9 publish > "$T/rel.out" 2>&1 < /dev/null
}
app_out() { grep -c 'release create v9.9.9' "$GHS/calls" 2>/dev/null; }
expect "publish (stand-in gh): a good image at M goes up, then the app" "0 1" "$(pub; echo $?) $(app_out)"
expect "publish: the prebuilt release is made at M" "$IM" "$(cat "$GHS/rel/prebuilt-9.9.9.target" 2>/dev/null)"
expect "publish: prebuilt-9.9.9 already there at another commit: refused, nothing uploaded, nothing of the app" "1 0 0" \
  "$(pub "$IC"; echo $?) $(app_out) $(ls "$GHS/rel/prebuilt-9.9.9" | grep -c part-aa)"
expect "publish: GitHub's target is empty: refused" "1 0" "$(pub GHS_TARGET=; echo $?) $(app_out)"
expect "publish: GitHub's target is a branch, not M: refused" "1 0" "$(pub GHS_TARGET=main; echo $?) $(app_out)"
expect "publish: the tag is at another commit than M: refused" "1 0" "$(pub GHS_TAGSHA=$IC; echo $?) $(app_out)"
expect "publish: GitHub serves other bytes for a part (its digest): refused" "1 0" "$(pub GHS_BAD=$B.tar.zst.part-aa; echo $?) $(app_out)"
expect "publish: says which part" 1 "$(grep -c "$B.tar.zst.part-aa" "$T/rel.out")"
expect "publish: no digests on GitHub: the parts are downloaded and checked, then the app" "0 1" "$(pub GHS_NODIGEST=1; echo $?) $(app_out)"
expect "publish: no digests and other bytes for a part: refused" "1 0" "$(pub GHS_NODIGEST=1 GHS_BAD=$B.tar.zst.part-aa; echo $?) $(app_out)"

# ---- the kit's held point (app-guards): the app itself must defer, not hand over to update-swap.sh ----
printf '%s\n' "2026-11-06T09:11:17Z app 3.3.1: install 3.3.2: copying and checking" \
  "2026-11-06T09:11:18Z app 3.3.1: install: handing over to update-swap.sh, quitting" \
  "2026-11-06T09:11:29Z swap: result: aborted a VM runs from OmacVM Test.app: the update waits until it is shut down" > "$T/ul-swap"
printf '%s\n' "2026-11-06T09:12:25Z app 3.3.1: --update-now: ready(\"3.3.2\")" \
  "2026-11-06T09:12:25Z app 3.3.1: install 3.3.2 deferred: the move to Omarchy 4.5 runs" > "$T/ul-def"
cat "$T/ul-def" "$T/ul-swap" > "$T/ul-both"; : > "$T/ul-none"
dv() { "$R/src/tests/e2e/move-45.sh" --deferred "$1" >/dev/null 2>&1; echo $?; }
expect "held point: handed over to update-swap.sh (09:11 on the mini) does not count" 1 "$(dv "$T/ul-swap")"
expect "held point: the app deferred it" 0 "$(dv "$T/ul-def")"
expect "held point: deferred, then handed over anyway: does not count" 1 "$(dv "$T/ul-both")"
expect "held point: nothing in update.log: does not count" 1 "$(dv "$T/ul-none")"
expect "the kit: disk-lock has a disk job refused while a move runs" 1 "$("$R/src/tests/e2e/move-45.sh" --rows | grep -c '^disk-lock .*while a move runs')"
expect "the kit: cuts before the switch run to done (kill-pre)" 1 "$("$R/src/tests/e2e/move-45.sh" --rows | grep -c '^kill-pre .*Update VM.*protect, initramfs, keyring, repos and download.*second update')"
expect "the kit: cuts after the switch run to done (kill-post)" 1 "$("$R/src/tests/e2e/move-45.sh" --rows | grep -c '^kill-post .*platform, mpv, vulkan, kernel, update, report.*second update')"
expect "the kit: a Resume that fails with no cut in its run is a FAIL" 1 "$(grep -c '"Resume (run $cycle) goes on with no cut in it" 0' "$R/src/tests/e2e/move-45.sh")"
expect "the kit: the guest check runs with the desktop up, before and after" 2 "$(grep -c 'desk_on; then' "$R/src/tests/e2e/move-45.sh")"

exit $fail
