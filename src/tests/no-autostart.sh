#!/bin/bash
# omacvm never starts a VM as a side effect, and never with the wrong app
# (2026-10-08: `omacvm features` without --vm started the person's VM
# "Omarchy" through an old "OmacVM Bench 2.9.1.app" that sorted before
# OmacVM.app). Stand-ins: a made-up OmacVM.app VM "Omarchy" (stopped) in a
# throwaway HOME, made-up apps, and an `open` that only writes down what it
# was asked to launch. No VM, no app, no hypervisor is touched.
#   src/tests/no-autostart.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT INT TERM
fail=0
check() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

H=$T/home; B=$T/bin; SYS=$T/Applications
mkdir -p "$H/Applications" "$B" "$SYS"
# open: what would have been launched, nothing else.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/opened"\nexit 0\n' "$T" > "$B/open"
# defaults: an app's Info.plist by its path (the made-up apps); no settings.
cat > "$B/defaults" <<'EOF'
#!/bin/bash
[[ $1 == read && $2 == */Contents/Info ]] && exec /usr/bin/defaults "$@"
exit 1
EOF
printf '#!/bin/bash\necho none\n' > "$B/swift"
printf '#!/bin/bash\nexit 0\n' > "$B/sleep"   # app_ip's wait for an address: at once
printf '#!/bin/bash\necho "$*" >> "%s/ssh"\nexit 255\n' "$T" > "$B/ssh"
# ps: the app launchers that are open (the file "launchers"), else the real one.
printf '#!/bin/bash\nif [[ "$*" == "-axo comm=" ]]; then cat "%s/launchers" 2>/dev/null; exit 0; fi\nexec /bin/ps "$@"\n' "$T" > "$B/ps"
chmod +x "$B"/*

mkapp() {   # NAME VERSION [ID]
  local a="$H/Applications/$1.app"
  mkdir -p "$a/Contents/Resources/scripts"
  : > "$a/Contents/Resources/scripts/create-vm.sh"
  /usr/bin/plutil -create xml1 "$a/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string "${3:-org.omacvm.app}" "$a/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleShortVersionString -string "$2" "$a/Contents/Info.plist"
}
V=$H/OmacVM/Omarchy
mkdir -p "$V"; : > "$V/disk.img"
printf "NAME='Omarchy'\nSSH_PORT='52399'\n" > "$V/vm.env"
echo 3.0.5 > "$V/omacvm-version"
echo "bridge=on gestures=off scroll-momentum=off omanotch=on" > "$V/features"

om() {   # ARGS...: omacvm in the throwaway HOME, the production identity
  env -u OMACVM_TEST_IDENTITY -u OMACVM_APP_RUNTIME -u OMACVM_APP_COPY HOME="$H" PATH="$B:$PATH" \
    OMACVM_SYSTEM_APPS="$SYS" \
    "$R/omacvm" "$@" < /dev/null 2>&1
}
started() { [[ -s $T/opened ]] && cat "$T/opened" | paste -sd'|' - || echo none; }

# The 01:48 setup: an old bench copy beside the installed app.
mkapp "OmacVM Bench 2.9.1" 2.9.1
mkapp OmacVM 3.0.5

# ---------- reading and listing never start a VM ----------
out=$(om features); rc=$?
check "features (no --vm): nothing started" none "$(started)"
check "features (no --vm): exit 0" 0 "$rc"
check "features (no --vm): says the VM is off" yes "$(grep -q 'VM is off' <<<"$out" && echo yes || echo "$out")"
check "features (no --vm): from the record (gestures off)" yes "$(grep -qE '^  off +gestures ' <<<"$out" && echo yes || echo "$out")"
check "features (no --vm): from the record (omanotch on)" yes "$(grep -qE '^  on +omanotch ' <<<"$out" && echo yes || echo "$out")"

out=$(om features --vm Omarchy); rc=$?
check "features --vm: nothing started" none "$(started)"
check "features --vm: exit 0, VM is off" "0 yes" "$rc $(grep -q 'VM is off' <<<"$out" && echo yes || echo no)"

out=$(om features --vm Omarchy --json); rc=$?
check "features --vm --json: nothing started" none "$(started)"
got=$(sed -n '/^{/,$p' <<<"$out" | python3 -c 'import json, sys
d = json.load(sys.stdin); f = {x["name"]: x["on"] for x in d["features"]}
print(d["vm"], d["running"], d["omacvm"], f["gestures"], f["omanotch"])' 2>&1)
check "features --vm --json: off, from the folder" "Omarchy False 3.0.5 False True" "$got"

out=$(om features --json)
check "features --json: nothing started" none "$(started)"

out=$(om check); rc=$?
check "check (no --vm): nothing started" none "$(started)"
check "check (no --vm): says the VM is off" yes "$(grep -q "'Omarchy' is off" <<<"$out" && echo yes || echo "$out")"
out=$(om check --vm Omarchy --json --mac-only)
check "check --vm --json: nothing started" none "$(started)"
out=$(om vms --json)
check "vms --json: nothing started" none "$(started)"
check "vms --json: lists it stopped" yes "$(grep -q '"name": "Omarchy", "type": "app", "state": "stopped"' <<<"$out" && echo yes || echo "$out")"

# ---------- changes: only a named VM is started ----------
out=$(om enable gestures --yes); rc=$?
check "enable (no --vm): nothing started" none "$(started)"
check "enable (no --vm): exit 3, says so" "3 yes" "$rc $(grep -q "'Omarchy' is off, and it was not named" <<<"$out" && echo yes || echo no)"
out=$(om apply --yes); rc=$?
check "apply (no --vm): nothing started" none "$(started)"
check "apply (no --vm): exit 3" 3 "$rc"

# Named: started, through the installed OmacVM.app, not the bench copy.
out=$(om enable gestures --vm Omarchy --yes)
check "enable --vm: started through OmacVM.app" "-n $H/Applications/OmacVM.app --args --start --vm Omarchy" "$(started)"
rm -f "$T/opened"

# Another copy is open: it would take the start request (main.swift hands it over).
echo "$H/Applications/OmacVM Bench 2.9.1.app/Contents/MacOS/OmacVM" > "$T/launchers"
out=$(om enable gestures --vm Omarchy --yes); rc=$?
check "another copy open: nothing started" none "$(started)"
check "another copy open: exit 3, names it" "3 yes" "$rc $(grep -q 'OmacVM Bench 2.9.1.app is open' <<<"$out" && echo yes || echo no)"
echo "$H/Applications/OmacVM.app/Contents/MacOS/OmacVM" > "$T/launchers"
out=$(om enable gestures --vm Omarchy --yes)
check "the same app open: started through it" "-n $H/Applications/OmacVM.app --args --start --vm Omarchy" "$(started)"
rm -f "$T/opened" "$T/launchers"

# Only an app older than the VM's OmacVM: never started with it.
rm -rf "$H/Applications/OmacVM.app"
out=$(om enable gestures --vm Omarchy --yes); rc=$?
check "older app only: nothing started" none "$(started)"
check "older app only: exit 3, says why" "3 yes" "$rc $(grep -q 'an older app never starts a newer VM' <<<"$out" && echo yes || echo no)"
rm -f "$T/opened"

# ---------- which app ----------
pick() {   # the app app_bundle picks (production identity, or test with "test")
  env -u OMACVM_APP_RUNTIME HOME="$H" PATH="$B:$PATH" OMACVM_SYSTEM_APPS="$SYS" \
    OMACVM_TEST_IDENTITY="$([[ ${1:-} == test ]] && echo 1)" /bin/bash -c \
    'source "$1/src/lib/app.sh"; app_bundle || echo none' _ "$R" 2>&1 | sed "s|^$H/Applications/||; s|^$SYS/|/Applications/|"
}
rm -rf "$H/Applications"/*.app
mkapp "OmacVM Bench 2.9.1" 2.9.1; mkapp "OmacVM 3.0.6 RC" 3.0.6; mkapp OmacVM 3.0.5
check "app: OmacVM.app over a bench copy and a newer RC" OmacVM.app "$(pick)"
rm -rf "$H/Applications/OmacVM.app"; mkapp Omarchy 3.0.4
check "app: a renamed install over copies" Omarchy.app "$(pick)"
rm -rf "$H/Applications/Omarchy.app"
check "app: copies only: the newest" "OmacVM 3.0.6 RC.app" "$(pick)"
mkapp "OmacVM Test" 3.0.6 org.omacvm.app.test
check "app: test identity: its own app" "OmacVM Test.app" "$(pick test)"
check "app: production never takes the test app" "OmacVM 3.0.6 RC.app" "$(pick)"
rm -rf "$H/Applications"/*.app
mkapp OmacVM 3.0.1; mkdir -p "$SYS"; mv "$H/Applications/OmacVM.app" "$SYS/"; mkapp OmacVM 3.0.5
check "app: the newer of ~/Applications and /Applications" OmacVM.app "$(pick)"

exit $fail
