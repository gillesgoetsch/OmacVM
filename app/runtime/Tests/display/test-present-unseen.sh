#!/bin/bash
# No frames drawn for a window that cannot be seen
# (omacvm-cocoa-present-unseen.patch), checked in the patched ui/cocoa.m:
#   - cocoa_gl_present returns at once while the window is out of sight
#     (macOS's occlusion state), keeping the frame dirty, unless
#     OMACVM_PRESENT_HIDDEN=1;
#   - the main window's occlusion is followed; when it shows again the newest
#     frame is drawn at once (present_bh), and qemu.log counts what was not;
#     from omacvm-cocoa-present-volatile.patch on, omacvmWindowSeen: hands the
#     occlusion's value to omacvmSight:, which does the rest: the checks
#     follow that call and read both bodies as one;
#   - with --self-test (CI): the checks fail on QEMU's code without the patch.
#   test-present-unseen.sh <patched ui/cocoa.m> | --self-test
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
body() { awk -v h="$2" 'index($0, h) == 1 {on=1} on {print} on && /^}$/ {exit}' "$1"; }
problems() {
  local m=$1 present seen sight
  present=$(body "$m" 'static bool cocoa_gl_present(void)')
  seen=$(body "$m" '- (void)omacvmWindowSeen:(NSNotification *)note')
  # Only this exact call: the occlusion's value, at the method's top level.
  if grep -qxF '    [self omacvmSight:seen];' <<<"$seen"; then
    sight=$(body "$m" '- (void)omacvmSight:(bool)seen')
    [[ -n $sight ]] || { echo "omacvmWindowSeen: calls omacvmSight:, which is not there"; return; }
    seen+=$'\n'$sight
  fi
  [[ -n $present ]] || { echo "no cocoa_gl_present"; return; }
  grep -q 'if (!qatomic_read(&omacvm_window_seen) && !always) {' <<<"$present" || echo "frames are drawn out of sight"
  grep -q 'getenv("OMACVM_PRESENT_HIDDEN")' <<<"$present" || echo "OMACVM_PRESENT_HIDDEN does not draw them anyway"
  # The skip comes before any GL work and keeps the frame dirty.
  awk '/omacvm_window_seen\) && !always\) \{/{s=NR} /gl_dirty = true;/{if (s && !d) d=NR} /CGLSetCurrentContext\(present_ctx\);/{c=NR}
       END{exit !(s && d && c && s < d && d < c)}' <<<"$present" || echo "the skip is not before the GL work, or the frame is not kept dirty"
  grep -q 'name:NSWindowDidChangeOcclusionStateNotification' "$m" && grep -q 'selector:@selector(omacvmWindowSeen:)' "$m" ||
    echo "the window's occlusion is not followed"
  [[ -n $seen ]] || { echo "no omacvmWindowSeen"; return; }
  grep -q 'NSWindowOcclusionStateVisible' <<<"$seen" && grep -q 'qatomic_set(&omacvm_window_seen, seen);' <<<"$seen" ||
    echo "the window's sight is not taken from its occlusion state"
  grep -q 'omacvm_present_seen_again();' <<<"$seen" && grep -q 'qemu_bh_schedule(present_bh);' "$m" ||
    echo "the newest frame is not drawn when the window shows again"
  grep -q 'frames not drawn' <<<"$seen" || echo "qemu.log does not count the frames not drawn"
}
if [[ ${1:-} == --self-test ]]; then
  T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-present-unseen.XXXXXX")
  trap 'rm -rf "$T"' EXIT
  printf 'static bool cocoa_gl_present(void)\n{\n    CGLSetCurrentContext(present_ctx);\n}\n' > "$T/old.m"
  if [[ -n $(problems "$T/old.m") ]]; then echo "ok   the checks fail on QEMU's code without the patch"; exit 0; fi
  echo "FAIL the checks pass on QEMU's code without the patch" >&2; exit 1
fi
m=${1:?usage: test-present-unseen.sh <patched ui/cocoa.m> | --self-test}
out=$(problems "$m")
if [[ -n $out ]]; then echo "test-present-unseen: $m: $out" >&2; exit 1; fi
echo "test-present-unseen: $m: wiring ok"
