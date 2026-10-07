#!/bin/bash
# UTM VMs on another drive (omacvm build --vm-type utm --vm-dir PATH).
# 1. The real src/cmd/build.sh --plan --json with stand-ins for swift (free
#    space), UTM's version and utmctl, in its own HOME: --vm-dir is taken for
#    UTM, the 30 GB check looks at that drive and not the Mac's disk, and a
#    prebuilt VM (which goes into UTM's library) is not used.
# 2. src/vm/utm.sh against a stand-in osascript, open and utmctl: utm_move
#    (export, delete UTM's copy, open the export), utm_add_live, utm_create
#    with no installer disk, the icon and sound card in a bundle outside UTM's
#    folder, and a build that goes on when UTM's settings cannot be written.
# No VM, no UTM, nothing of this Mac's setup touched.
#   src/tests/utm-vm-dir.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
T=$(mktemp -d)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home" "$T/drive" "$T/small"

expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# swift -e SCRIPT [DIR] or swift .../mac-free-gb.swift [DIR]: free GB of HOME's
# drive (no DIR, or DIR in HOME) or of DIR's ("small" has 20); any other swift
# (the notch check): no notch.
cat > "$T/bin/swift" <<'EOF'
#!/bin/bash
case $1 in -e) d=${3:-} ;; */mac-free-gb.swift) d=${2:-} ;; *) echo none; exit 0 ;; esac
if [[ -z $d || $d == "$HOME" || $d == "$HOME"/* ]]; then echo "$FREE_HOME"; elif [[ $d == */small* ]]; then echo 20; else echo 100; fi
EOF
cat > "$T/bin/defaults" <<'EOF'
#!/bin/bash
[[ "$*" == *UTM.app/Contents/Info* ]] && { echo 5.0.6; exit 0; }
exec /usr/bin/defaults "$@"
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/bin/utmctl"
chmod +x "$T/bin/"*

plan() {   # FREE_HOME ARGS... -> the plan's JSON or its last message, then "rc N"
  local free=$1 out rc; shift
  out=$(cd "$T" && HOME=$T/home PATH="$T/bin:$PATH" UTMCTL=$T/bin/utmctl FREE_HOME=$free \
    bash "$R/src/cmd/build.sh" --plan --json --vm-type utm --vm-name "U t" --cpus 2 --memory-gb 4 \
      --user t --full-name T --hostname h "$@" < /dev/null 2>&1)
  rc=$?
  printf '%s\nrc %s\n' "$out" "$rc"
}
field() { python3 -c 'import json, sys; d = json.loads(sys.stdin.read().rsplit("\nrc ", 1)[0]); print(eval(sys.argv[1]))' "$1" 2>/dev/null || echo "no JSON"; }

# A Mac with 20 GB free, the VM to a drive with 100: built there.
out=$(plan 20 --vm-dir "$T/drive")
expect "plan: --vm-dir taken for UTM" "rc 0" "$(tail -1 <<<"$out")"
expect "plan: the VM's folder is the drive" "$T/drive" "$(field 'd["vm"]["dir"]' <<<"$out")"
expect "plan: the command keeps --vm-dir" "yes" "$(field 'd["command"]' <<<"$out" | grep -qF -- "--vm-dir $T/drive" && echo yes)"
expect "plan: built here" "build" "$(field 'd["source"]' <<<"$out")"
# A trailing slash, as Finder's folder picker gives it.
expect "plan: --vm-dir with a trailing slash" "$T/drive" "$(plan 20 --vm-dir "$T/drive/" | field 'd["vm"]["dir"]')"

# The drive's free space counts, not the Mac's.
out=$(plan 100 --vm-dir "$T/small")
expect "plan: 20 GB on the drive is refused (needs a person)" "rc 3" "$(tail -1 <<<"$out")"
expect "plan: says it is the drive" "yes" "$(grep -q "only 20 GB free on" <<<"$out" && echo yes)"

# No --vm-dir and a full Mac: refused, with the way out.
out=$(plan 20)
expect "plan: no --vm-dir, 20 GB on the Mac: refused" "rc 3" "$(tail -1 <<<"$out")"
expect "plan: points at --vm-dir" "yes" "$(grep -q "20 GB free.*--vm-dir" <<<"$out" && echo yes)"
expect "plan: no --vm-dir, 100 GB: UTM's library" "UTM library" "$(plan 100 | field 'd["vm"]["dir"]')"

# A prebuilt UTM VM goes into UTM's library: with --vm-dir it is built.
expect "plan: --prebuilt with --vm-dir is built" "build" "$(plan 20 --prebuilt --vm-dir "$T/drive" | field 'd["source"]')"

# Not a folder; a VM of that name already there.
out=$(plan 100 --vm-dir "$T/none")
expect "plan: a missing folder is refused" "rc 3" "$(tail -1 <<<"$out")"
mkdir -p "$T/drive/U t.utm"
out=$(plan 100 --vm-dir "$T/drive")
expect "plan: an existing U t.utm is refused" "rc 2" "$(tail -1 <<<"$out")"
expect "plan: says which" "yes" "$(grep -q "U t.utm already exists" <<<"$out" && echo yes)"
rmdir "$T/drive/U t.utm"

# ---- src/vm/utm.sh with a stand-in UTM ----
# osascript: logs its arguments (one line each, a record per call) and acts as
# UTM's scripting: export makes the bundle, delete and update answer, the
# configuration has 2 drives after the update, open puts the VM in UTM's list.
# OSA_FAIL=export|delete|update|updateerr|open|openerr (open: ignored, as a UTM started
# by an Apple event did on the Mac mini; openerr: the scripting's open fails).
# utm_move runs under set -euo pipefail, as in build.sh.
mkdir -p "$T/fake"
cat > "$T/fake/osascript" <<'EOF'
#!/bin/bash
{ echo "--- call"; for a in "$@"; do echo "[$a]"; done; } >> "$OSA_LOG"
s="$*"
case $s in
  *"export (virtual machine"*)
    [[ ${OSA_FAIL:-} == export ]] && { echo "execution error: UTM got an error (-10000)"; exit 1; }
    b=${@: -1}; mkdir -p "$b/Data"; printf '<plist/>' > "$b/config.plist" ;;
  *"to delete (virtual machine"*)
    [[ ${OSA_FAIL:-} == delete ]] && { echo "execution error: no (-1728)"; exit 1; } ;;
  *"to open (POSIX file"*)
    # UTM opens it (listed from now on), unless it ignores the request.
    [[ ${OSA_FAIL:-} == openerr ]] && { echo "execution error: UTM got an error (-1708)"; exit 1; }
    [[ ${OSA_FAIL:-} == open ]] || echo "osa ${@: -1}" >> "$OSA_LOG.open"
    echo "missing value" ;;
  *"update configuration"*)
    [[ ${OSA_FAIL:-} == updateerr ]] && { echo "execution error: UTM got an error (-10000)"; exit 1; }
    [[ ${OSA_FAIL:-} == update ]] && echo 1 || echo 2 ;;
  *"make new virtual machine"*) echo "0A1B2C3D-0000-4000-8000-00000000ABCD" ;;
esac
exit 0
EOF
printf '#!/bin/bash\necho "$*" >> "$OSA_LOG.open"\n' > "$T/fake/open"
cat > "$T/fake/utmctl" <<'EOF'
#!/bin/bash
echo "UUID                                 Status   Name"
[[ -f $OSA_LOG.open ]] && echo "11111111-2222-3333-4444-555555555555 stopped  U t"
exit 0
EOF
printf '#!/bin/bash\nexit 1\n' > "$T/fake/pgrep"
chmod +x "$T/fake/"*

fresh() { rm -rf "$T/osa.log" "$T/osa.log.open" "$T/vms"; mkdir -p "$T/vms"; }

fresh
out=$(HOME=$T/home PATH="$T/fake:$PATH" UTMCTL=$T/fake/utmctl OSA_LOG=$T/osa.log \
  bash -c 'set -euo pipefail; source "$1/src/lib/mac.sh"; source "$1/src/vm/utm.sh"; utm_move "U t" "$2"' _ "$R" "$T/vms" 2>&1; echo "rc $?")
expect "utm_move: done" "rc 0" "$(tail -1 <<<"$out")"
expect "utm_move: exported into the folder" "yes" "$(grep -qxF "[$T/vms/U t.utm]" "$T/osa.log" && echo yes)"
expect "utm_move: then UTM's copy deleted" "export delete" "$(grep -oE 'export \(virtual|to delete \(virtual' "$T/osa.log" | sed -e 's/^export.*/export/' -e 's/^to delete.*/delete/' | xargs)"
expect "utm_move: the export opened through UTM's scripting" "osa $T/vms/U t.utm" "$(cat "$T/osa.log.open")"

move() {   # OSA_FAIL -> output, rc
  HOME=$T/home PATH="$T/fake:$PATH" UTMCTL=$T/fake/utmctl OSA_LOG=$T/osa.log OSA_FAIL=$1 \
    bash -c 'set -euo pipefail; source "$1/src/lib/mac.sh"; source "$1/src/vm/utm.sh"; utm_move "U t" "$2"' _ "$R" "$T/vms" 2>&1
  echo "rc $?"
}
out=$(move "")
expect "utm_move: a bundle already there is not overwritten" "rc 1" "$(tail -1 <<<"$out")"
expect "utm_move: ... and nothing asked of UTM" "yes" "$(grep -q "U t.utm already exists" <<<"$out" && [[ $(grep -c -- '--- call' "$T/osa.log") == 3 ]] && echo yes)"
fresh
out=$(move export)
expect "utm_move: export fails: stops" "rc 1" "$(tail -1 <<<"$out")"
expect "utm_move: export fails: UTM's copy kept" "no delete" "$(grep -q 'to delete' "$T/osa.log" && echo delete || echo no delete)"
expect "utm_move: export fails: says why" "yes" "$(grep -q "UTM could not put the VM into $T/vms: execution error" <<<"$out" && echo yes)"
fresh
out=$(move open)
expect "utm_move: scripting's open ignored: LaunchServices' open, then listed" "rc 0|-a UTM $T/vms/U t.utm" "$(tail -1 <<<"$out")|$(cat "$T/osa.log.open")"
fresh
out=$(move openerr)
expect "utm_move: scripting's open fails: LaunchServices' open, then listed" "rc 0|-a UTM $T/vms/U t.utm" "$(tail -1 <<<"$out")|$(cat "$T/osa.log.open")"
fresh
out=$(move delete)
expect "utm_move: delete fails: stops, says what to do" "yes" "$(grep -q "delete 'U t' in UTM, then open $T/vms/U t.utm in UTM" <<<"$out" && [[ $(tail -1 <<<"$out") == "rc 1" ]] && echo yes)"

# utm_create with no installer disk: only the NVMe disk.
fresh
call() {   # CODE -> output, "rc N"
  HOME=$T/home PATH="$T/fake:$PATH" UTMCTL=$T/fake/utmctl OSA_LOG=$T/osa.log OSA_FAIL=${OSA_FAIL:-} \
    bash -c 'source "$1/src/lib/mac.sh"; source "$1/src/vm/utm.sh"; eval "$2"' _ "$R" "$1" 2>&1
  echo "rc $?"
}
out=$(call 'utm_create "U t" 2 4096 "" 65536')
expect "utm_create: no installer: done" "0A1B2C3D-0000-4000-8000-00000000ABCD|rc 0" "$(paste -sd'|' - <<<"$out")"
expect "utm_create: no installer: empty 4th argument" "[]" "$(sed -n '/--- call/,$p' "$T/osa.log" | grep -A0 '^\[65536\]' -B1 | head -1)"
expect "utm_create: no installer: the script leaves the VirtIO disk out then" "yes" "$(grep -qF "if (item 4 of argv) is not \"\" then set f to POSIX file (item 4 of argv)" "$T/osa.log" && echo yes)"

# utm_add_live: the configuration must have 2 drives after.
fresh
expect "utm_add_live: 2 drives: done" "rc 0" "$(call 'utm_add_live "U t" /x/live.img' | tail -1)"
expect "utm_add_live: the image given to UTM" "yes" "$(grep -qxF '[/x/live.img]' "$T/osa.log" && echo yes)"
out=$(OSA_FAIL=update call 'utm_add_live "U t" /x/live.img')
expect "utm_add_live: still 1 drive: stops" "rc 1" "$(tail -1 <<<"$out")"
out=$(OSA_FAIL=updateerr call 'set -euo pipefail; utm_add_live "U t" /x/live.img')
expect "utm_add_live: UTM's error under set -e: says why" "yes" "$(grep -q "could not add the live installer disk: execution error" <<<"$out" && echo yes)"

# Icon and sound card in a bundle outside UTM's folder.
fresh
b="$T/vms/U t.utm"; mkdir -p "$b/Data"
plutil -create xml1 "$b/config.plist"
plutil -insert Information -json '{"Name": "U t"}' "$b/config.plist"
plutil -insert Sound -json '[]' "$b/config.plist"
out=$(HOME=$T/home PATH="$T/fake:$PATH" UTMCTL=$T/fake/utmctl OSA_LOG=$T/osa.log \
  bash -c 'source "$1/src/lib/mac.sh"; source "$1/src/vm/utm.sh"; utm_set_icon "U t" "$2" && utm_add_sound "U t" "$2"' _ "$R" "$b" 2>&1; echo "rc $?")
expect "bundle on the drive: icon + sound: done" "rc 0" "$(tail -1 <<<"$out")"
expect "bundle on the drive: icon file" "yes" "$([[ -s $b/Data/omacvm.png ]] && echo yes)"
expect "bundle on the drive: icon in config.plist" "omacvm.png true" "$(plutil -extract Information.Icon raw -o - "$b/config.plist") $(plutil -extract Information.IconCustom raw -o - "$b/config.plist")"
expect "bundle on the drive: sound card" '[{"Hardware":"intel-hda"}]' "$(plutil -extract Sound json -o - "$b/config.plist")"
expect "bundle on the drive: nothing in UTM's folder" "no" "$([[ -e $T/home/Library/Containers ]] && echo yes || echo no)"

# UTM's settings cannot be written (Terminal kept out of UTM's data): the
# build goes on and says so; written: nothing said.
printf '#!/bin/bash\necho "Could not write domain com.utmapp.UTM; exiting" >&2; exit 1\n' > "$T/fake/defaults"
chmod +x "$T/fake/defaults"
out=$(call 'set -e; utm_tune_app; echo "went on"')
expect "utm_tune_app: settings not writable: the build goes on" "yes" "$(grep -qx 'went on' <<<"$out" && [[ $(tail -1 <<<"$out") == "rc 0" ]] && echo yes)"
expect "utm_tune_app: settings not writable: says so, without defaults' own error" "yes" "$(grep -q "UTM's settings unchanged" <<<"$out" && ! grep -q "Could not write domain" <<<"$out" && echo yes)"
printf '#!/bin/bash\necho "$*" >> "$OSA_LOG.defaults"\n' > "$T/fake/defaults"
out=$(call 'utm_tune_app')
expect "utm_tune_app: settings written, nothing said" "rc 0" "$(paste -sd'|' - <<<"$out")"
expect "utm_tune_app: the three settings" "3" "$(wc -l < "$T/osa.log.defaults" | tr -d ' ')"

exit $fail
