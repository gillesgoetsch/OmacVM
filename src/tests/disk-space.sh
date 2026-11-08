#!/bin/bash
# Freeing disk space (src/guest/disk-space.sh) without a VM: omarchy-mac's 5
# update snapshots become KEEP (once) and the extra ones go at once, a number
# set by hand stays (also 5 after the change), the weekly trim is on, the
# trim runs after btrfs's cleaner, both together waited for at most a
# minute; omacvm apply runs it only after the VM side worked, never for a
# repair; omacvm check's "freeing disk space" line, and its "free space" line
# (a warning under Omarchy's update limit, 10 GiB free on /, #749).
# snapper, systemctl, btrfs, timeout and findmnt are stand-ins.
#   src/tests/disk-space.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
S=$R/src/guest/disk-space.sh
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
keep=$(sed -n 's/^KEEP=\([0-9][0-9]*\) .*/\1/p' "$S")
expect "the number kept: one constant" yes "$([[ -n $keep && $(grep -c '^KEEP=' "$S") == 1 ]] && echo yes)"
# snapper: set-config writes KEY=VALUE into the config ($SNAPPER_FAIL: fails)
cat > "$T/bin/snapper" <<'EOF'
#!/bin/bash
echo "snapper $*" >> "$CALLS"
[[ -z ${SNAPPER_FAIL:-} ]] || exit 1
[[ $1 == -c && $2 == root ]] || exit 2
if [[ $3 == set-config ]]; then
  shift 3
  for kv in "$@"; do
    k=${kv%%=*}
    sed "s/^$k=.*/$k=\"${kv#*=}\"/" "$OMACVM_SNAPPER_ROOT" > "$OMACVM_SNAPPER_ROOT.new" &&
      mv "$OMACVM_SNAPPER_ROOT.new" "$OMACVM_SNAPPER_ROOT"
  done
fi
exit 0
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
[[ $* == "is-enabled -q fstrim.timer" ]] && exit "${TIMER_OFF:-0}"
[[ $* == "start fstrim.service" && -n ${TRIM_STUCK:-} ]] && exec sleep 30
exit 0
EOF
# btrfs: the cleaner's wait ($CLEANER_SECONDS long; $CLEANER_STUCK: never
# ends); $NOT_BTRFS: / is not btrfs
cat > "$T/bin/btrfs" <<'EOF'
#!/bin/bash
echo "btrfs $*" >> "$CALLS"
[[ -z ${NOT_BTRFS:-} ]] || { echo "ERROR: not a btrfs filesystem: /" >&2; exit 1; }
[[ $* == "subvolume sync /" && -n ${CLEANER_STUCK:-} ]] && exec sleep 30
[[ $* == "subvolume sync /" ]] && sleep "${CLEANER_SECONDS:-0}"
exit 0
EOF
# timeout SECONDS COMMAND...: as coreutils' (macOS has none), $TIMEOUT_TEST
# seconds instead of SECONDS; no process left behind
cat > "$T/bin/timeout" <<'EOF'
#!/bin/bash
echo "timeout $*" >> "$CALLS"
lim=${TIMEOUT_TEST:-$1}; shift
"$@" & p=$!
n=0
while kill -0 "$p" 2>/dev/null; do
  (( n++ < lim * 10 )) || { kill "$p"; wait "$p"; exit 124; }
  sleep 0.1
done
wait "$p"
EOF
cat > "$T/bin/findmnt" <<'EOF'
#!/bin/bash
echo "$ROOT_OPTS"
EOF
chmod +x "$T/bin/"*
export PATH=$T/bin:$PATH CALLS=$T/calls OMACVM_SNAPPER_ROOT=$T/root OMACVM_SNAPPER_DONE=$T/lib/omacvm/update-snapshots
config() {   # NUMBER_LIMIT NUMBER_LIMIT_IMPORTANT: omarchy-mac's file
  printf '%s\n' '# Omarchy snapshots root only for pre-update recovery — kept to 5, no timeline' \
    'SUBVOLUME="/"' 'FSTYPE="btrfs"' '' 'NUMBER_CLEANUP="yes"' 'NUMBER_MIN_AGE="0"' \
    "NUMBER_LIMIT=\"$1\"" "NUMBER_LIMIT_IMPORTANT=\"$2\"" '' 'TIMELINE_CREATE="no"' > "$T/root"
}
limits() { grep -E '^NUMBER_LIMIT' "$T/root" | tr '\n' ' '; }
# calls: what ran, the trim's time limit as N (BOUND: the number)
run() {
  : > "$CALLS"; out=$(bash "$S" 2>&1); rc=$?
  BOUND=$(sed -n 's/^timeout \([0-9]*\) systemctl start fstrim.service$/\1/p' "$CALLS")
  calls=$(sed 's/^timeout [0-9]* systemctl/timeout N systemctl/' "$CALLS" | tr '\n' ';')
}
# The timer on, the cleaner (at most 60 s), a commit, then the trim, waited
# for with the rest of the minute.
TRIM="systemctl enable fstrim.timer;timeout 60 btrfs subvolume sync /;btrfs subvolume sync /;btrfs filesystem sync /;timeout N systemctl start fstrim.service;systemctl start fstrim.service;"

config 5 5; run
expect "omarchy-mac's 5: exit 0" 0 "$rc"
expect "omarchy-mac's 5: $keep kept" "NUMBER_LIMIT=\"$keep\" NUMBER_LIMIT_IMPORTANT=\"$keep\" " "$(limits)"
expect "omarchy-mac's 5: set, the extra snapshots go at once, timer on, the cleaner, a trim" \
  "snapper -c root set-config NUMBER_LIMIT=$keep NUMBER_LIMIT_IMPORTANT=$keep;snapper -c root cleanup number;$TRIM" "$calls"
expect "omarchy-mac's 5: says so" "update snapshots: the last $keep kept (were 5)" "$out"
expect "omarchy-mac's 5: done once, the number set noted" "$keep" "$(cat "$OMACVM_SNAPPER_DONE" 2>/dev/null)"
expect "the trim: the rest of the minute" yes "$( (( BOUND >= 59 && BOUND <= 60 )) && echo yes)"

run
expect "again: snapper untouched, timer, cleaner and trim only" "$TRIM" "$calls"
expect "again: says nothing" "" "$out"

config 3 3; run
expect "a number set by hand: stays" 'NUMBER_LIMIT="3" NUMBER_LIMIT_IMPORTANT="3" ' "$(limits)"
expect "a number set by hand: snapper untouched" "$TRIM" "$calls"

config 5 5; run
expect "5 set by hand after the change: stays" 'NUMBER_LIMIT="5" NUMBER_LIMIT_IMPORTANT="5" ' "$(limits)"
expect "5 set by hand after the change: snapper untouched" "$TRIM" "$calls"

rm -rf "${T:?}/lib" "$T/root"; run
expect "no snapper: only the cleaner and the trim" "$TRIM" "$calls"
expect "no snapper: exit 0" 0 "$rc"

NOT_BTRFS=1 run
expect "/ not btrfs (Omarchy by hand): the trim still" "$TRIM" "$calls"
expect "/ not btrfs: says nothing, exit 0" "|0" "$out|$rc"

# The cleaner takes 3 s: the trim gets what is left of the minute.
CLEANER_SECONDS=3 run
expect "a cleaner of 3 s: the trim waited for at most the rest" yes "$( (( BOUND >= 56 && BOUND <= 57 )) && echo yes)"
# The cleaner and the trim take longer than the wait (1 s here for 60):
# the trim still starts, right after the wait, and the script ends.
config 5 5; t0=$SECONDS
CLEANER_STUCK=1 TRIM_STUCK=1 TIMEOUT_TEST=1 run
expect "cleaner and trim slower than the wait: snapshots, the trim after the wait" \
  "snapper -c root set-config NUMBER_LIMIT=$keep NUMBER_LIMIT_IMPORTANT=$keep;snapper -c root cleanup number;$TRIM" "$calls"
expect "cleaner and trim slower than the wait: does not wait longer, exit 0" "yes|0" \
  "$( (( SECONDS - t0 <= 6 )) && echo yes)|$rc"
rm -rf "${T:?}/lib"

config 5 5; SNAPPER_FAIL=1 run
expect "snapper fails: no cleanup, the trim still" "snapper -c root set-config NUMBER_LIMIT=$keep NUMBER_LIMIT_IMPORTANT=$keep;$TRIM" "$calls"
expect "snapper fails: says so, exit 0" "update snapshots: could not set the number kept (snapper)|0" "$out|$rc"
expect "snapper fails: tried again next time" no "$([[ -e $OMACVM_SNAPPER_DONE ]] && echo yes || echo no)"

# omacvm apply (src/cmd/apply.sh): its own lines from the VM side to
# "finishing", with stand-ins. The update snapshots go only after the VM
# side worked: a failed or rolled back apply leaves them.
A=$R/src/cmd/apply.sh
expect "guest/install.sh does not run it" 0 "$(grep -c 'disk-space.sh' "$R/src/guest/install.sh")"
expect "apply.sh runs it once" 1 "$(grep -c 'bash $S/guest/disk-space.sh' "$A")"
blk=$(awk '/^if ! guest_install "\$\{FV\[@\]\}"/ {on = 1} on {print} on && /^step finish/ {exit}' "$A")
expect "apply.sh: the VM side block found" yes "$([[ $blk == *disk-space.sh* && $blk == *'exit 4'* ]] && echo yes)"
cat > "$T/apply" <<EOF
set -euo pipefail
guest_install() { echo "guest_install \$*" >> "\$CALLS"; [[ \$1 == new ]] && return "\$GI_RC"; return 0; }
gssh() { echo "gssh \$2" >> "\$CALLS"; [[ \$2 != *disk-space.sh* ]] || echo "update snapshots: the last 2 kept (were 5)"; }
what_failed() { :; }
step() { echo "step \$1" >> "\$CALLS"; }
log() { :; }
info() { echo "info \$*" >> "\$CALLS"; }
die() { echo "die" >> "\$CALLS"; exit 1; }
FV=(new); PREV=(old); GI_LOG=$T/gi.log; IP=vm; S=/usr/local/share/omacvm; VM=t; had=3.1.24; now=3.1.25; KNOWN=""; GI_ARGS=""
$blk
EOF
ap() { : > "$CALLS"; bash "$T/apply" > /dev/null 2>&1; rc=$?; calls=$(tr '\n' ';' < "$CALLS"); }
O=/usr/local/share/omacvm
GI_RC=0 ONLY="" TRANSACTION=0 ap
expect "apply: the VM side worked: then the snapshots and the trim, then finishing" \
  "guest_install new;gssh rm -rf $O.old;gssh bash $O/guest/disk-space.sh;info disk space: update snapshots: the last 2 kept (were 5);step finish;|0" "$calls|$rc"
GI_RC=1 ONLY="" TRANSACTION=0 ap
expect "apply: the VM side failed: the snapshots stay" "guest_install new;gssh rm -rf $O.old;die;|1" "$calls|$rc"
GI_RC=1 ONLY="" TRANSACTION=1 ap
expect "apply --transaction: rolled back: the snapshots stay" \
  "guest_install new;gssh test -d $O.old;step rollback;gssh set -e; rm -rf $O.failed; mv $O $O.failed; mv $O.old $O; rm -rf $O.failed;gssh grep -v '^#' $O/features.tsv | cut -f1;guest_install old;|4" "$calls|$rc"
GI_RC=0 ONLY=bridge TRANSACTION=0 ap
expect "apply --reinstall (a repair, --only): no snapshots, no trim" "guest_install new;gssh rm -rf $O.old;step finish;|0" "$calls|$rc"

# omacvm check's line, the block from guest/check.sh with the stand-ins.
blk=$(sed -n '/^# What the VM frees goes back to the Mac/,/^else ok "freeing disk space"/p' "$R/src/guest/check.sh" |
  sed -e "s#/etc/snapper/configs/root#$T/root#" -e "s#/var/lib/omacvm/update-snapshots#$OMACVM_SNAPPER_DONE#")
cat > "$T/check" <<EOF
ok()   { echo "ok|\$1|\$2"; }
bad()  { echo "FAIL|\$1|\$2"; }
warn() { echo "WARN|\$1|\$2"; }
$blk
EOF
chk() { bash "$T/check" 2>&1; }
config 2 2
expect "check: discard, timer, 2 snapshots" "ok|freeing disk space|discard, weekly trim; 2 update snapshots" \
  "$(ROOT_OPTS=rw,noatime,compress=zstd:1,ssd,discard=async,space_cache=v2,subvol=/@ chk)"
config 5 5
expect "check: omarchy-mac's 5 (no apply yet)" \
  "WARN|freeing disk space|discard, weekly trim; 5 update snapshots keep deleted system files (omacvm apply keeps fewer)" \
  "$(ROOT_OPTS=rw,discard=async chk)"
mkdir -p "${OMACVM_SNAPPER_DONE%/*}"; : > "$OMACVM_SNAPPER_DONE"
expect "check: 5 set by hand after the change" "ok|freeing disk space|discard, weekly trim; 5 update snapshots" \
  "$(ROOT_OPTS=rw,discard=async chk)"
rm -f "$T/root"
expect "check: no snapper, trim only" "ok|freeing disk space|weekly trim" "$(ROOT_OPTS=rw,nodiscard,ssd chk)"
expect "check: nothing trims" "FAIL|freeing disk space|nothing trims: deleted files keep their space (omacvm apply)" \
  "$(ROOT_OPTS=rw,nodiscard TIMER_OFF=1 chk)"

# omacvm check's "free space" line (#749): under Omarchy's update limit (10 GiB free on /,
# omarchy-update-requires-free-space) a warning a person acts on; df as Omarchy reads it.
blk=$(sed -n '/^# Omarchy.s update stops under 10 GiB free/,/^fi$/p' "$R/src/guest/check.sh")
cat > "$T/bin/df" <<'EOF'
#!/bin/bash
echo "df $*" >> "$CALLS"
printf '%s\n' "  Avail" "$DF_AVAIL"
EOF
chmod +x "$T/bin/df"
cat > "$T/free" <<EOF
ok()   { echo "ok|\$1|\$2|\${3:+1}"; }
warn() { echo "WARN|\$1|\$2|\${3:+1}"; }
$blk
EOF
free() { : > "$CALLS"; DF_AVAIL=$1 PATH="$T/bin:$PATH" bash "$T/free" 2>&1; }
G=1073741824
expect "free space: the block found" yes "$([[ $blk == *'10 * 1024 * 1024 * 1024'* ]] && echo yes)"
expect "free space: 9.0 GiB: warn, a person, says what to do" \
  "WARN|free space|9.0 GiB free on /, Omarchy's update needs 10 GiB: delete files in your home you no longer need, or give the VM a larger disk (VM window, Disk › Change… with the VM shut down)|1" \
  "$(free $((9 * G)))"
expect "free space: read as Omarchy's guard reads it" "df --output=avail --block-size=1 /" "$(free $((9 * G)) >/dev/null; cat "$CALLS")"
expect "free space: one byte under 10 GiB: warn" WARN "$(free $((10 * G - 1)) | cut -d'|' -f1)"
expect "free space: exactly 10 GiB: ok (Omarchy updates)" "ok|free space|10.0 GiB free on /|" "$(free $((10 * G)))"
expect "free space: 52.3 GiB: ok" "ok|free space|52.3 GiB free on /|" "$(free 56157381017)"
expect "free space: no number from df: no line" "" "$(free 'df: /: No such file')"

exit $fail
