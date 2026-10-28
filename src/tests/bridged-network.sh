#!/bin/bash
# Behavioral networking contract with isolated command/installer stand-ins.
# No VM, network changes, administrator privileges or macOS tools needed.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
expect() { if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi; }
F=$T/repo
mkdir -p "$F/src/cmd" "$F/src/lib" "$F/src/net/mac" "$T/vm/logs"
cp "$R/src/cmd/network.sh" "$R/src/cmd/features.sh" "$F/src/cmd/"
cp "$R/src/lib/network.sh" "$R/src/lib/features.sh" "$F/src/lib/"
cp "$R/src/features.tsv" "$F/src/"
printf 'die() { echo "$*" >&2; exit 1; }\n' > "$F/src/lib/mac.sh"
: > "$F/src/lib/setup.sh"
cat > "$F/src/lib/vm.sh" <<'SH'
app_dir() { [[ $1 == 'Test VM' ]] && echo "$TEST_VM_DIR"; }
app_ip() { [[ ${APP_RUNNING:-1} == 1 ]] && echo 127.0.0.1:52222; }
resolve_vm() { echo 'must not resolve/start a VM here' >&2; exit 99; }
SH
cat > "$F/src/net/mac/install.sh" <<'SH'
#!/bin/bash
case " $* " in
  *' --interfaces '*) printf 'en0\nen7\n'; exit 0 ;;
  *' --status '*) echo ok; exit 0 ;;
esac
printf 'helper %s\n' "$*" >> "$CALLS"
if [[ ${TEST_NEED_ADMIN:-0} == 1 && ${OMACVM_ADMIN_PROMPT:-} == none ]]; then exit 3; fi
SH
cat > "$F/src/cmd/apply.sh" <<'SH'
#!/bin/bash
[[ ${OMACVM_NETWORK_PREPARE:-} == 1 ]] || exit 98
printf 'guest %s\n' "$*" >> "$CALLS"
exit "${TEST_GUEST_RC:-0}"
SH
chmod +x "$F/src/net/mac/install.sh" "$F/src/cmd/apply.sh"
export TEST_VM_DIR=$T/vm CALLS=$T/calls
: > "$CALLS"
printf 'mac=52:54:00:11:22:33\n' > "$T/vm/fast-network"
printf 'bridge=on fast-network=on future-feature=on\n' > "$T/vm/features"
printf 'untouched disk data\n' > "$T/vm/data.img"
cp "$T/vm/fast-network" "$T/fast-original"
cp "$T/vm/data.img" "$T/data-original"
cli() { bash "$F/src/cmd/network.sh" --vm 'Test VM' "$@"; }
status() { cli --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
rc() { local result=0; "$@" > "$T/out" 2> "$T/err" || result=$?; echo "$result"; }
expect 'default remains shared' shared "$(status network)"
expect 'read status never installs or prepares' '' "$(cat "$CALLS")"
expect 'interface list is structured' 'en0 en7' "$(bash "$F/src/cmd/network.sh" --interfaces --json | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["interfaces"]))')"
expect 'bridged requires explicit interface' 2 "$(rc cli bridged)"
expect 'reject unsupported interface' 2 "$(rc cli bridged --interface en8)"
expect 'reject injected interface' 2 "$(rc cli bridged --interface 'en0;false')"
expect 'invalid settings have no installation side effects' '' "$(cat "$CALLS")"
expect 'feature enable redirects before resolving or starting VM' 2 "$(rc bash "$F/src/cmd/features.sh" enable bridged-network --vm 'Test VM' --yes)"
expect 'stopped unprepared guest needs a person' 3 "$(rc env APP_RUNNING=0 bash "$F/src/cmd/network.sh" --vm 'Test VM' bridged --interface en0)"
expect 'stopped guest does not install a helper' '' "$(cat "$CALLS")"
expect 'administrator prompt none is needs-human' 3 "$(rc env TEST_NEED_ADMIN=1 OMACVM_ADMIN_PROMPT=none bash "$F/src/cmd/network.sh" --vm 'Test VM' bridged --interface en0)"
expect 'needs-human leaves shared configuration' shared "$(status network)"
expect 'needs-human does not prepare guest' 0 "$(grep -c '^guest ' "$CALLS" || true)"
expect 'guest preparation failure is propagated' 1 "$(rc env TEST_GUEST_RC=1 bash "$F/src/cmd/network.sh" --vm 'Test VM' bridged --interface en0)"
expect 'guest transaction rollback status is preserved' 4 "$(rc env TEST_GUEST_RC=4 bash "$F/src/cmd/network.sh" --vm 'Test VM' bridged --interface en0)"
expect 'guest failure leaves shared configuration' shared "$(status network)"
expect 'enable bridges successfully' 0 "$(rc cli bridged --interface en0 --json)"
expect 'setting reads bridged' bridged "$(status network)"
expect 'selected physical interface persisted' en0 "$(status interface)"
mac=$(status mac)
source "$R/src/lib/network.sh"
if network_mac_valid "$mac" && [[ $mac != 52:54:00:11:22:33 ]]; then echo 'ok   LAN MAC is valid and distinct'; else echo 'FAIL LAN MAC'; fail=1; fi
expect 'guest preparation precedes persisted selection' 1 "$(cat "$T/vm/bridged-network-ready")"
expect 'existing feature choices preserved' yes "$(grep -q 'bridge=on fast-network=on future-feature=on bridged-network=on' "$T/vm/features" && echo yes)"
expect 'repeat enable preserves identity' 0 "$(rc cli bridged --interface en0)"
expect 'repeat enable has stable MAC' "$mac" "$(status mac)"
expect 'switch physical interface succeeds while stopped and prepared' 0 "$(rc env APP_RUNNING=0 bash "$F/src/cmd/network.sh" --vm 'Test VM' bridged --interface en7)"
expect 'interface switch preserves LAN MAC' "$mac" "$(status mac)"
expect 'interface switch persisted' en7 "$(status interface)"
expect 'shared disables without starting VM' 0 "$(rc env APP_RUNNING=0 bash "$F/src/cmd/features.sh" disable bridged-network --vm 'Test VM')"
expect 'shared removes bridged file' no "$([[ -e $T/vm/bridged-network ]] && echo yes || echo no)"
expect 'shared marks feature off' yes "$(grep -q 'bridged-network=off' "$T/vm/features" && echo yes)"
expect 'retained identity re-enables without a boot' 0 "$(rc env APP_RUNNING=0 bash "$F/src/cmd/network.sh" --vm 'Test VM' bridged --interface en0)"
expect 'off then on retains stable LAN MAC' "$mac" "$(status mac)"
printf 'interface=en0\nmac=invalid\n' > "$T/vm/bridged-network"
expect 'malformed setting is an error, never shared fallback' 2 "$(rc cli --json)"
source "$R/src/lib/features.sh"
features_load
for ((i=0; i<${#FN[@]}; i++)); do FV[$i]=off; done
expect 'feature reconciliation rejects malformed setting' 2 "$(rc features_real '' "$T/vm")"
expect 'failed reconciliation retains invalid selection for explicit recovery' yes "$([[ -f $T/vm/bridged-network ]] && echo yes || echo no)"
expect 'shared recovers malformed setting' 0 "$(rc cli shared)"
cmp -s "$T/fast-original" "$T/vm/fast-network" && echo 'ok   fast-network preference/MAC untouched' || fail=1
cmp -s "$T/data-original" "$T/vm/data.img" && echo 'ok   VM data untouched' || fail=1
python3 "$R/src/tests/bridged-network.py" || fail=1
exit "$fail"
