#!/bin/bash
# The moves gate (src/release/release.sh step moves, from 3.4.0): the move
# matrix's rows (src/tests/e2e/move-45.sh) summed up, and the gate passes only
# when every row passed on three 4.0 VMs of different ages, "clean" on each,
# one tested commit, and the move's files are the same in that commit and the
# release commit M. No VM: rows are written by hand, M is a commit in a
# throwaway git repo.
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
expect "the kit lists its rows" 14 "$(wc -l <<<"$ROWS" | tr -d ' ')"
expect "the kit lists the files a result is tied to" 1 "$("$G/src/tests/e2e/move-45.sh" --paths | grep -c '^app/scripts/move-vm.sh$')"

mkrow() {   # DIR ROW BASE OK [MAC] [COMMIT]
  printf 'a check\t%s\tdetail\n' "$4" | MOVE45_COMMIT=${6:-$C} python3 -I "$PY" row "$1/rows/$2-$3.json" "$2" "$3" 5 >/dev/null
  [[ -n ${5:-} ]] && python3 -I -c 'import json,sys; p=sys.argv[1]; o=json.load(open(p)); o["mac"]=sys.argv[2]; json.dump(o, open(p,"w"))' "$1/rows/$2-$3.json" "$5"
  return 0
}
full() {   # DIR: every row on base A, clean on B and C, Macs mini + m1
  mkdir -p "$1/rows"
  local r; for r in $ROWS; do mkrow "$1" "$r" "M-mv-a300" 1 mini; done
  mkrow "$1" clean "M-mv-a308" 1 m1; mkrow "$1" clean "M-mv-a40b" 1 m1
}
sumrc() { "$G/src/tests/e2e/move-45.sh" --summary "$1" >/dev/null 2>&1; echo $?; }
gate() { python3 -I "$PY" gate "$1/result.json" "$2" "$G" >/dev/null 2>&1; echo $?; }

D=$T/ok; full "$D"
expect "every row, three ages: summary passes" 0 "$(sumrc "$D")"
expect "gate: passes for M (only README changed)" 0 "$(gate "$D" "$M")"
expect "gate: refused for M2 (move-vm.sh changed after the test)" 1 "$(gate "$D" "$M2")"
expect "gate: the result names the tested commit" "$C" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$D/result.json")"

D=$T/onefail; full "$D"; mkrow "$D" kill-commit "M-mv-a300" 0 mini
expect "one row failed: summary fails" 1 "$(sumrc "$D")"
expect "one row failed: gate refuses" 1 "$(gate "$D" "$M")"

D=$T/missing; full "$D"; rm "$D/rows/power-loss-M-mv-a300.json"
expect "a row never run: summary fails" 1 "$(sumrc "$D")"
expect "a row never run: named" '["power-loss"]' "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["missing_rows"]))' "$D/result.json")"

D=$T/twoages; full "$D"; rm "$D/rows/clean-M-mv-a40b.json"
expect "only two ages: summary fails" 1 "$(sumrc "$D")"

D=$T/twocommits; full "$D"; mkrow "$D" clean "M-mv-a40b" 1 m1 "$M"
expect "rows from two commits: summary fails" 1 "$(sumrc "$D")"

D=$T/bad; mkdir -p "$D"; echo '{"kind": "omacvm-e2e-cc-switches", "pass": true}' > "$D/result.json"
expect "another kind of result: gate refuses" 1 "$(gate "$D" "$M")"

# release.sh asks for the gate from 3.4.0 on, and publish wants it and the image.
expect "release.sh: step moves in the default steps" 1 "$(grep -c 'e2e moves publish after)' "$R/src/release/release.sh")"
expect "release.sh: the gate runs move-45-result.py" 1 "$(grep -c 'move-45-result.py" gate' "$R/src/release/release.sh")"
expect "release.sh: publish refuses 3.4.0+ without a prebuilt image" 1 "$(grep -c 'a \$VERSION app would build every new VM here' "$R/src/release/release.sh")"
exit $fail
