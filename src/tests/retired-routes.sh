#!/bin/bash
# OmacVM 3.4.0 retired Parallels, UTM and VMware Fusion (src/lib/retired.sh).
# A VM OmacVM set up there before is listed as retired and refused (exit 2 for
# build, exit 3 with one text, or its JSON, for the rest), and never touched:
# no SSH, no start, no prlctl/utmctl/vmrun call but a listing, nothing read
# in UTM's container. update refuses one before the Mac step and skips them
# when it updates everything; uninstall still removes the old clipboard helper.
# A copy of this checkout with a stand-in Mac step, its own HOME, stand-ins for
# prlctl (it lists), ssh, open, osascript, utmctl and vmrun (they must not run),
# a Fusion library file and the UTM names OmacVM saw. No VM, nothing of this
# Mac's setup touched.
#   src/tests/retired-routes.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
T=$(mktemp -d); T=$(cd "$T" && pwd -P)
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
has() { [[ $2 == *"$1"* ]] && echo yes || echo "$2"; }

# The checkout, with a Mac step that only says it ran.
CO=$T/co; mkdir -p "$CO"
cp -R "$R/omacvm" "$R/src" "$CO/"
printf '#!/bin/bash\necho "MAC STEP $*" >> "%s/calls"\n' "$T" > "$CO/src/mac/install.sh"
H=$T/home; S="$H/Library/Application Support/omacvm"
mkdir -p "$S/known_hosts" "$T/bin" "$H/Library/Containers/com.utmapp.UTM/Data"
pin() { : > "$S/known_hosts/$1-$(printf %s "$2" | tr -c 'A-Za-z0-9._-' _)-$(printf %s "$2" | cksum | cut -d' ' -f1)"; }

# Parallels: "Old P" built by OmacVM (its description), "Pinned P" set up by
# it (a pin), "Windows" neither.
mkdir -p "$T/pvm/Old P.pvm" "$T/pvm/Pinned P.pvm" "$T/pvm/Windows.pvm"
echo '<Description>Omarchy (omarchy-mac) on Arch Linux ARM, built by OmacVM</Description>' > "$T/pvm/Old P.pvm/config.pvs"
echo '<Description>Windows 11</Description>' > "$T/pvm/Windows.pvm/config.pvs"
pin parallels "Pinned P"
cat > "$T/bin/prlctl" <<EOF
#!/bin/bash
echo "prlctl \$*" >> "$T/calls"
case "\$*" in
  "list -a -o name") printf 'NAME\nOld P\nPinned P   \nWindows\n' ;;
  "list -a -i "*) echo "Home: $T/pvm/\${4}.pvm/" ;;
  *) echo "FORBIDDEN prlctl \$*" >> "$T/calls"; exit 1 ;;
esac
EOF
# VMware Fusion: its library file; "Old F" marked by OmacVM, "Other F" not.
mkdir -p "$H/Library/Application Support/VMware Fusion" "$T/vmx"
printf 'displayName = "Old F"\nannotation = "built by OmacVM"\n' > "$T/vmx/f.vmx"
printf 'displayName = "Other F"\n' > "$T/vmx/o.vmx"
printf 'vmlist1.config = "%s"\nvmlist2.config = "%s"\n' "$T/vmx/f.vmx" "$T/vmx/o.vmx" > "$H/Library/Application Support/VMware Fusion/vmInventory"
# UTM: the names OmacVM saw; "Old U" has a pin, "Not ours" none.
printf 'Old U\nNot ours\n' > "$S/utm-vms"; pin utm "Old U"
# UTM's container must never be read: closed to everyone.
echo secret > "$H/Library/Containers/com.utmapp.UTM/Data/x"; chmod 000 "$H/Library/Containers/com.utmapp.UTM/Data" "$H/Library/Containers/com.utmapp.UTM"
for c in ssh ssh-keyscan open osascript utmctl vmrun; do
  printf '#!/bin/bash\necho "FORBIDDEN %s $*" >> "%s/calls"\nexit 1\n' "$c" "$T" > "$T/bin/$c"
done
# launchctl: update asks which helpers are loaded (none here).
printf '#!/bin/bash\necho "launchctl $*" >> "%s/calls"\nexit 1\n' "$T" > "$T/bin/launchctl"
chmod +x "$T/bin/"*
: > "$T/calls"
om() {   # ARGS... -> OUT (stdout and stderr) and RC
  OUT=$(cd "$T" && HOME=$H PATH="$T/bin:$PATH" PRLCTL=$T/bin/prlctl OMACVM_APP_COPY=1 \
    OMACVM_APP_ID=org.omacvm.app.test.retired-fixture OMACVM_TEST_IDENTITY="" "$CO/omacvm" "$@" 2>&1 < /dev/null); RC=$?
}
jv() { python3 -c 'import json, sys
try: d = json.loads(sys.argv[1])
except Exception: print("no JSON: " + sys.argv[1][:200]); sys.exit()
print(" ".join(str(d.get(k)) for k in sys.argv[2:]))' "$@"; }

# Listing
om vms --json; out=$OUT
expect "vms --json: exit 0" 0 "$RC"
expect "vms --json: the retired VMs, and only OmacVM's" "Old F/fusion Old P/parallels Old U/utm Pinned P/parallels" \
  "$(python3 -c 'import json, sys; print(" ".join(sorted("%s/%s" % (v["name"], v["type"]) for v in json.loads(sys.argv[1])["vms"] if v.get("retired"))))' "$out" 2>&1)"
expect "vms --json: state retired, note" "retired retired in 3.4.0" \
  "$(python3 -c 'import json, sys; v = [v for v in json.loads(sys.argv[1])["vms"] if v["name"] == "Old P"][0]; print(v["state"], v["note"])' "$out" 2>&1)"
om vms; out=$OUT
expect "vms: one line each, retired" yes "$(has "retired in OmacVM 3.4.0" "$(grep "Old U" <<<"$out")")"

# build
om build --plan --json --vm-type parallels; out=$OUT
expect "build --vm-type parallels: exit 2" 2 "$RC"
expect "build --vm-type parallels: says why and how" yes "$(has "retired Parallels, UTM and VMware Fusion" "$out")"
om build --plan --json --vm-type fusion; expect "build --vm-type fusion: exit 2" 2 "$RC"
om build --plan --json --vm-type utm; expect "build --vm-type utm: exit 2" 2 "$RC"

# Commands on a retired VM: exit 3, the one text (JSON with --json).
TEXT="'Old P' is a Parallels VM. OmacVM 3.4.0 retired Parallels, UTM and VMware Fusion: OmacVM no longer changes or updates this VM"
for args in "apply --vm|Old P" "enable|gestures|--vm|Old P|--yes" "disable|gestures|--vm|Old P|--yes" "features|--vm|Old P" \
            "resources|--vm|Old P" "check|--vm|Old P" "graphics|--vm|Old P" "notch|--vm|Old P" "report|--vm|Old P|--print" \
            "update|--vm|Old P|--no-pull"; do
  IFS='|' read -r -a a <<<"$args"
  [[ ${a[0]} == "apply --vm" ]] && a=(apply --vm "Old P")
  om "${a[@]}"; out=$OUT
  expect "${a[0]} on a retired VM: exit 3" 3 "$RC"
  expect "${a[0]} on a retired VM: the text" yes "$(has "$TEXT" "$out")"
done
om apply --vm "Old P" --vm-type parallels; out=$OUT; expect "apply --vm-type parallels: exit 3" 3 "$RC"
for c in features check resources graphics; do
  om "$c" --vm "Old U" --json; out=$OUT
  expect "$c --json on a retired VM: exit 3" 3 "$RC"
  expect "$c --json: route-retired" "route-retired utm Old U 3.4.0" "$(jv "$out" error route vm retired_in)"
done
om features --vm "Old F" --vm-type fusion --json; out=$OUT; expect "features --vm-type fusion --json: exit 3, JSON" "3 route-retired" "$RC $(jv "$out" error)"
om apply --vm Windows; expect "a Parallels VM OmacVM did not set up: not ours (exit 2)" 2 "$RC"
om apply --vm "Not ours"; expect "a UTM name without a pin: not ours (exit 2)" 2 "$RC"

# update: one refused before anything (a control centre job of an old VM
# sends --vm-type and --transaction); all: the retired ones named and left.
: > "$T/calls"
OMACVM_PROGRESS=json om update --vm "Old P" --vm-type parallels --transaction --yes --no-pull; out=$OUT
expect "update job for a retired VM: exit 3" 3 "$RC"
expect "update job: the failed line for the control centre" yes "$(has '{"omacvm_failed": 1, "part": "", "text": "'"'Old P'"' is a Parallels VM: OmacVM 3.4.0 retired' "$out")"
expect "update job: no Mac step" 0 "$(grep -c "MAC STEP" "$T/calls")"
om update --no-pull; out=$OUT
expect "update: exit 0" 0 "$RC"
expect "update: the Mac step ran" 1 "$(grep -c "MAC STEP" "$T/calls")"
expect "update: each retired VM named" 4 "$(grep -c "retired in OmacVM 3.4.0, not updated" <<<"$out")"
expect "update: what stops serving them" yes "$(has "this Mac's OmacVM helpers no longer serve them" "$out")"

# Nothing was reached, started or read.
expect "no SSH, no start, no app scripting" "" "$(grep FORBIDDEN "$T/calls" | sort -u)"
expect "prlctl: listings only" "" "$(grep '^prlctl ' "$T/calls" | grep -v '^prlctl list -a -o name$' | grep -v '^prlctl list -a -i ')"
expect "retired.sh never names UTM's container" 0 "$(grep -c 'Containers' "$R/src/lib/retired.sh")"

# uninstall: the clipboard helper of 3.3 and older goes (its lines of
# uninstall.sh; the whole run would reset this Mac's permissions).
mkdir -p "$H/Library/LaunchAgents" "$H/.local/share/omacvm"
touch "$H/Library/LaunchAgents/org.omacvm.test.clip-in.plist" "$H/.local/share/omacvm/omacvm-clip-in"
sed -n '/^# The clipboard helper of the retired/,/omacvm-clip-in"$/p' "$R/src/mac/uninstall.sh" > "$T/clip.sh"
: > "$T/calls"
HOME=$H PATH="$T/bin:$PATH" OMACVM_TEST_IDENTITY="" R="$R/src" bash "$T/clip.sh"
expect "uninstall: clip-in unloaded" "launchctl bootout gui/$(id -u)/org.omacvm.test.clip-in" "$(cat "$T/calls")"
expect "uninstall: its LaunchAgent and program gone" "no no" \
  "$([[ -e $H/Library/LaunchAgents/org.omacvm.test.clip-in.plist ]] && echo yes || echo no) $([[ -e $H/.local/share/omacvm/omacvm-clip-in ]] && echo yes || echo no)"

exit $fail
