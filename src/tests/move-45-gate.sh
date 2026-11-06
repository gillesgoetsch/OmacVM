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
expect "the kit lists its rows" 18 "$(wc -l <<<"$ROWS" | tr -d ' ')"
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
gx init -q; gx add -A; gx commit -qm c; IC=$(gx rev-parse HEAD)
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
rel() { HOME=$H OMACVM_RELEASE_OUT=$O OMACVM_RELEASE_NOTES=$T/notes.md "$X/src/release/release.sh" "$@" > "$T/rel.out" 2>&1; }
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

exit $fail
