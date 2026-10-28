#!/bin/bash
# Test for qemu-hvf-free-page-reclaim-reusable.patch (no VM): a free page
# report gives the old pages back to macOS (test-reclaim.c says how).
#   test-reclaim.sh [QEMU_SOURCE_DIR [WORK_DIR]] [--compressed SECONDS]
# With a source dir (the runtime build): the helper from the patched
# accel/hvf/hvf-all.c, and it must be wired in. Without (CI): the helper from
# the patch itself. Runs the patch's helper (must pass), the same with
# OMACVM_RECLAIM_REUSABLE=0 and main's helper up to 3.2.11 (both must fail:
# the test sees the leak), each with a stand-in for the hypervisor's map and,
# where this Mac lets a process make a VM, with a real one (--hv). Then
# --keeps: macOS keeping the pages (a refused or a skipped advice) stops the
# move aside for the run and writes the app's status file.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src= work= compressed=()
while (( $# )); do
  case $1 in
    --compressed) compressed=(--compressed "${2:?--compressed SECONDS}"); shift 2 ;;
    *) if [[ -z $src ]]; then src=$1; elif [[ -z $work ]]; then work=$1; else
         echo "usage: test-reclaim.sh [QEMU_SOURCE_DIR [WORK_DIR]] [--compressed SECONDS]" >&2; exit 2; fi
       shift ;;
  esac
done
work=${work:-$(mktemp -d "${TMPDIR:-/tmp}/omacvm-test-reclaim.XXXXXX")}
mkdir -p "$work"
begin='/* omacvm-reclaim: begin'
end='/* omacvm-reclaim: end */'
if [[ -n $src ]]; then
  f=$src/accel/hvf/hvf-all.c
  B=$begin E=$end awk 'index($0, ENVIRON["B"]) == 1 { on = 1 } on { print } on && $0 == ENVIRON["E"] { exit }' \
    "$f" > "$work/reclaim.inc"
  # Wired in: every report goes through the helper, no other replacement is
  # left, and the balloon closes each report for the counters.
  body=$(awk '/^void hvf_report_free_pages\(/ { on = 1 } on { print } on && /^}$/ { exit }' "$f")
  [[ $body == *"aside = omacvm_reclaim_backing(gpa, host, size, flags);"* &&
     $body == *"omacvm_reclaim_queue(aside, size, 0);"* ]] || \
    { echo "FAIL: hvf_report_free_pages() does not call omacvm_reclaim_backing and queue the old range"; exit 1; }
  [[ $body != *MAP_FIXED* && $body != *hv_vm_unmap* ]] || \
    { echo "FAIL: hvf_report_free_pages() still replaces the backing itself"; exit 1; }
  grep -q 'hvf_report_free_pages_done();' "$src/hw/virtio/virtio-balloon.c" || \
    { echo "FAIL: virtio-balloon.c does not call hvf_report_free_pages_done"; exit 1; }
  # The worker judges every release and stops the move aside when macOS keeps
  # the pages; its first line has the text the app looks for in the binary.
  work_fn=$(awk '/^static void \*omacvm_reclaim_work\(/ { on = 1 } on { print } on && /^}$/ { exit }' "$f")
  [[ $work_fn == *"left = omacvm_reclaim_release(it.aside, it.size, true, &before);"* &&
     $work_fn == *"if (!omacvm_reclaim_takes(&judge, before, left, why, sizeof(why))) {"* &&
     $work_fn == *"omacvm_reclaim_keeps(why);"* &&
     $work_fn == *'"OmacVM: free page reclaim gives the pages back to macOS "'* ]] || \
    { echo "FAIL: the worker does not judge its releases or lacks the marker line"; exit 1; }
else
  p=$here/../../patches/qemu-hvf-free-page-reclaim-reusable.patch
  B=$begin E=$end awk '{ l = $0; if (substr(l, 1, 1) != "+") { if (on) exit; next }; l = substr(l, 2) }
    index(l, ENVIRON["B"]) == 1 { on = 1 } on { print l } on && l == ENVIRON["E"] { exit }' "$p" > "$work/reclaim.inc"
fi
grep -q 'omacvm-reclaim: end' "$work/reclaim.inc" || \
  { echo "FAIL: no omacvm_reclaim_backing (omacvm-reclaim: begin ... end) in ${src:-the patch}"; exit 1; }
cat > "$work/hv.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.hypervisor</key><true/></dict></plist>
EOF
for v in patch main; do
  def=(); [[ $v == main ]] && def=(-DHELPER_MAIN)
  cc -O1 -Wall -Wextra -Werror -Wno-unused-parameter ${def[@]+"${def[@]}"} -I"$work" \
    "$here/test-reclaim.c" -framework Hypervisor -o "$work/test-$v"
  codesign -s - -f --entitlements "$work/hv.plist" "$work/test-$v" 2>/dev/null
done
fail=0
run() {   # WANT(pass|fail) BINARY [ENV=VALUE] [--hv]
  local want=$1 bin=$2 rc out; shift 2
  local envs=() args=()
  for a in "$@"; do [[ $a == *=* ]] && envs+=("$a") || args+=("$a"); done
  rc=0; out=$(env ${envs[@]+"${envs[@]}"} "$work/$bin" ${args[@]+"${args[@]}"} ${compressed[@]+"${compressed[@]}"} 2>&1) || rc=$?
  local what="$bin${envs[*]:+ ${envs[*]}}${args[*]:+ ${args[*]}}"
  if (( rc == 2 )) && [[ $out == *"SKIP --hv"* ]]; then
    echo "  $what: skipped, $(sed -n 's/.*SKIP --hv: //p' <<< "$out")"
  elif [[ $want == pass && $rc == 0 ]] || [[ $want == fail && $rc == 1 && $out == *"LEFT ON THE MAC"* ]]; then
    echo "  $what: ${want}ed as it should: $(grep '^test-reclaim: [0-9]' <<< "$out" | cut -d';' -f1-2 | cut -c15-)"
  else
    echo "FAIL $what (exit $rc, want $want):"; sed 's/^/    /' <<< "$out" | tail -12; fail=1
  fi
}
for hv in "" --hv; do
  run pass test-patch ${hv:+"$hv"}
  run fail test-patch OMACVM_RECLAIM_REUSABLE=0 ${hv:+"$hv"}
  run fail test-main ${hv:+"$hv"}
done
rc=0; out=$("$work/test-patch" --keeps 2>&1) || rc=$?
if (( rc == 0 )); then
  echo "  test-patch --keeps: passed as it should ($(grep -c '^  ok' <<< "$out") rows)"
else
  echo "FAIL test-patch --keeps (exit $rc):"; grep -v '^  ok' <<< "$out" | sed 's/^/    /' | tail -20; fail=1
fi
(( fail == 0 )) && echo "test-reclaim: all ok" || { echo "test-reclaim: FAILED"; exit 1; }
