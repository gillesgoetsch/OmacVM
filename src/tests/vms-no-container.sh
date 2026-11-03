#!/bin/bash
# omacvm vms never waits on UTM's data container (src/lib/mac.sh utm_data):
# macOS (14+) holds a read of another app's container until someone answers
# its prompt, so a Bridge job or a script would hang. Stand-ins: a python3
# whose read of UTM's settings never returns, prlctl/utmctl/pgrep/defaults/
# swift that know no VM. Everything in a fake HOME; no VM, no UTM needed.
#   src/tests/vms-no-container.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'pkill -f "$T/" 2>/dev/null; rm -rf "$T"' EXIT INT TERM
fail=0
check() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

H=$T/home; B=$T/bin
mkdir -p "$H" "$B"
PY=$(command -v python3)
# python3: a read of UTM's container blocks (as macOS does while it asks) and
# leaves a mark; everything else is the real python3.
cat > "$B/python3" <<EOF
#!/bin/bash
for a in "\$@"; do
  if [[ \$a == *Library/Containers/com.utmapp.UTM/* ]]; then
    echo "\$\$" >> "$T/read"
    perl -MTime::HiRes=time -e 'printf "%.3f\n", time' >> "$T/read-at"
    [[ -n \${UTM_FIXTURE:-} ]] && exec "$PY" "\$1" "\$UTM_FIXTURE" "\${@:3}"
    exec sleep 60
  fi
done
exec "$PY" "\$@"
EOF
printf '#!/bin/bash\nexit 1\n' > "$B/defaults"
printf '#!/bin/bash\necho none\n' > "$B/swift"
printf '#!/bin/bash\n[[ "$*" == "-xq UTM" || "$*" == "-x UTM" ]] && exit 1\nexec /usr/bin/pgrep "$@"\n' > "$B/pgrep"
printf '#!/bin/bash\necho "$*" >> "%s/utmctl"\nexit 1\n' "$T" > "$B/utmctl"
chmod +x "$B"/*
# The clock to the millisecond: SECONDS counts the clock's whole seconds, so
# 0.1 s of work across a second's turn reads 1 (bash 3.2 and 5 alike).
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
since() { perl -e 'printf "%.2f\n", $ARGV[1] - $ARGV[0]' "$1" "${2:-$(now)}"; }   # FROM [TO]: seconds
below() { [[ -n $1 ]] && perl -e 'exit !($ARGV[0] < $ARGV[1])' "$1" "$2"; }      # SECONDS LIMIT
run() {   # ENV... -- vms.sh --json, in the fake HOME; the last line: took=SECONDS end=CLOCK
  local s e; s=$(now)
  env HOME="$H" PATH="$B:$PATH" PRLCTL=/nonexistent UTMCTL="$B/utmctl" "$@" "$R/src/cmd/vms.sh" --json < /dev/null
  e=$(now); echo "took=$(since "$s" "$e") end=$e"
}
SUP="$H/Library/Application Support/omacvm"

# An OmacVM.app VM (stopped), and UTM installed with a VM in its container.
mkdir -p "$H/OmacVM/Work"; : > "$H/OmacVM/Work/disk.img"; echo "NAME='Work'" > "$H/OmacVM/Work/vm.env"
mkdir -p "$H/Library/Containers/com.utmapp.UTM/Data/Library/Preferences"

# 1. UTM never used with OmacVM here: no UTM at all, only the app VM.
out=$(run)
check "UTM not used: app VM listed" yes "$(grep -q '"name": "Work", "type": "app", "state": "stopped"' <<<"$out" && echo yes)"
check "UTM not used: no UTM row" 0 "$(grep -c '"type": "utm"' <<<"$out")"
check "UTM not used: UTM's container not read" no "$([[ -e $T/read ]] && echo yes || echo no)"
check "UTM not used: utmctl not asked" no "$([[ -e $T/utmctl ]] && echo yes || echo no)"

# 2. UTM used before (OmacVM saw "Dev VM"), a script asks (no terminal):
# the names it saw, unknown, without reading UTM's data.
mkdir -p "$SUP"; echo "Dev VM" > "$SUP/utm-vms"
out=$(run)
check "UTM used, no person: row from OmacVM's own list" yes \
  "$(grep -q '"name": "Dev VM", "type": "utm", "state": "unknown", .*"note": "UTM data not readable"' <<<"$out" && echo yes || echo "$out")"
check "UTM used, no person: UTM's container not read" no "$([[ -e $T/read ]] && echo yes || echo no)"
check "UTM used, no person: app VM still listed" yes "$(grep -q '"name": "Work", "type": "app"' <<<"$out" && echo yes)"
check "valid JSON" ok "$(sed '$d' <<<"$out" | "$PY" -c 'import json,sys; json.load(sys.stdin); print("ok")' 2>&1)"

# 3. Asked for UTM (OMACVM_UTM=1) while macOS holds the read: back within 3 s
# of the read (it is cut at 2 s), the same row, and the stuck reader is gone.
# Counted from the read, not from the start: a busy runner took 4-8 s for all
# of it (CI 10-14 .. 10-28), the part before the read included.
out=$(run OMACVM_UTM=1)
end=$(sed -n 's/^took=.* end=//p' <<<"$out"); waited=$(since "$(head -1 "$T/read-at" 2>/dev/null)" "$end" 2>/dev/null)
check "read held back: vms --json back within 3 s of the read" yes "$(below "$waited" 3 && echo yes || echo "${waited:-no read} s")"
check "read held back: it was tried once" 1 "$(grep -c . "$T/read" 2>/dev/null)"
check "read held back: UTM row unknown (UTM data not readable)" yes \
  "$(grep -q '"name": "Dev VM", "type": "utm", "state": "unknown", .*"note": "UTM data not readable"' <<<"$out" && echo yes || echo "$out")"
check "read held back: reader killed" no "$(kill -0 "$(head -1 "$T/read")" 2>/dev/null && echo yes || echo no)"
check "read held back: OmacVM's list kept" "Dev VM" "$(cat "$SUP/utm-vms")"

# 4. Readable (macOS allowed it): UTM's registry, suspended and stopped, and
# OmacVM's list follows it.
rm -f "$T/read"
mkdir -p "$T/utm/A.utm" "$T/utm/B.utm"
for v in A B; do
  "$PY" -c 'import plistlib, sys; plistlib.dump({"Information": {"Name": sys.argv[2]}}, open(sys.argv[1], "wb"))' "$T/utm/$v.utm/config.plist" "Fixture $v"
done
"$PY" - "$T" <<'PY'
import plistlib, sys
t = sys.argv[1]
plistlib.dump({"Registry": {"1": {"Package": {"Path": f"{t}/utm/A.utm"}, "Suspended": True},
                            "2": {"Package": {"Path": f"{t}/utm/B.utm"}, "Suspended": False}}},
              open(f"{t}/utm.plist", "wb"))
PY
out=$(run OMACVM_UTM=1 UTM_FIXTURE="$T/utm.plist")
check "readable: suspended and stopped from UTM's registry" "Fixture A=suspended Fixture B=stopped" \
  "$(grep -o '"name": "Fixture [AB]", "type": "utm", "state": "[a-z]*"' <<<"$out" | sed 's/"name": "\([^"]*\)".*"state": "\([a-z]*\)"/\1=\2/' | sort | paste -sd' ' -)"
check "readable: no note" 0 "$(grep -c '"note": "UTM' <<<"$out")"
check "readable: OmacVM's list follows" "Fixture A Fixture B" "$(sort "$SUP/utm-vms" | paste -sd' ' -)"

# 5. The other readers give up at once without permission (no read at all).
rm -f "$T/read"
got=$(HOME=$H PATH="$B:$PATH" bash -c 'source "$1/src/lib/mac.sh"; source "$1/src/lib/vm.sh"
  now() { perl -MTime::HiRes=time -e '\''printf "%.3f\n", time'\''; }
  now; utm_bundle "Fixture A"; echo "bundle=$?"; vm_marked "Fixture A" utm; echo "marked=$?"
  utm_add_sound "Fixture A"; echo "sound=$?"; now' _ "$R" < /dev/null)
took=$(since "$(sed -n 1p <<<"$got")" "$(sed -n '$p' <<<"$got")")
check "no permission: utm_bundle/vm_marked fail, utm_add_sound skips, at once (under 1 s)" "bundle=1 marked=1 sound=0 yes" \
  "$(sed '1d;$d' <<<"$got" | paste -sd' ' -) $(below "$took" 1 && echo yes || echo "$took s")"
check "no permission: UTM's container not read" no "$([[ -e $T/read ]] && echo yes || echo no)"

# 6. The test identity lists only its own app's VMs.
out=$(run OMACVM_UTM=1 OMACVM_TEST_IDENTITY=1)
check "test identity: no UTM row" 0 "$(grep -c '"type": "utm"' <<<"$out")"

# 7. A command on an app VM (apply/check --vm Work --vm-type app) from a
# person at a terminal, with UTM used here: UTM's data is not read at all.
rm -f "$T/read"
got=$(HOME=$H PATH="$B:$PATH" PRLCTL=/nonexistent UTMCTL="$B/utmctl" bash -c 'source "$1/src/lib/mac.sh"; source "$1/src/lib/vm.sh"
  now() { perl -MTime::HiRes=time -e '\''printf "%.3f\n", time'\''; }
  UTM_TTY=1; VM=Work; TYPE=app; s=$(now); resolve_vm
  echo "type=$TYPE ip=${IP:-none} quick=$(perl -e '\''print $ARGV[1] - $ARGV[0] < 2 ? 1 : 0'\'' "$s" "$(now)")"' _ "$R" < /dev/null 2>&1)
check "app VM named: resolved without starting it, no 2 s UTM wait" "type=app ip=none quick=1" "$(tail -1 <<<"$got")"
check "app VM named: UTM's container not read" no "$([[ -e $T/read ]] && echo yes || echo no)"

(( fail )) && { echo "vms-no-container: FAILED"; exit 1; }
echo "vms-no-container: all passed"
