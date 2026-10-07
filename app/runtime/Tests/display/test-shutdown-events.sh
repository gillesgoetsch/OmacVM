#!/bin/bash
# No events into QEMU after the display's cleanup
# (omacvm-cocoa-shutdown-events.patch), checked in the patched ui/cocoa.m:
#   - cocoa_display_cleanup marks the display closed before it frees kbd;
#   - with_bql and bool_with_bql skip their block once it is closed;
#   - the cleanup does not destroy cbevent or release the pasteboard owner.
#   test-shutdown-events.sh <patched ui/cocoa.m>   (the runtime build)
#   test-shutdown-events.sh --self-test            (CI: the checks catch the old code)
set -uo pipefail

body() { awk -v h="$2" 'index($0, h) == 1 {on=1} on {print} on && /^}$/ {exit}' "$1"; }

problems() {
  local f=$1 clean wb bwb
  clean=$(body "$f" 'static void cocoa_display_cleanup(void)')
  wb=$(body "$f" 'static void with_bql(CodeBlock block)')
  bwb=$(body "$f" 'static bool bool_with_bql(BoolCodeBlock block)')
  [[ -n $clean && -n $wb && -n $bwb ]] || { echo "cleanup or the BQL helpers not found"; return; }
  awk '/cocoa_display_closed = true;/{c=NR} /qkbd_state_free/{k=NR} END{exit !(c && k && c < k)}' <<<"$clean" ||
    echo "the cleanup frees kbd without marking the display closed first"
  grep -q 'if (!cocoa_display_closed) {' <<<"$wb" || echo "with_bql runs its block after the cleanup"
  grep -q 'cocoa_display_closed ? false : block()' <<<"$bwb" || echo "bool_with_bql runs its block after the cleanup"
  ! grep -q 'qemu_event_destroy(&cbevent)' <<<"$clean" || echo "the cleanup destroys cbevent (a paste may wait on it)"
  ! grep -q '\[cbowner release\]' <<<"$clean" || echo "the cleanup releases the pasteboard owner (AppKit may still call it)"
}

if [[ ${1:-} == --self-test ]]; then
  T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-shutdown.XXXXXX")
  trap 'rm -rf "$T"' EXIT
  fail=0
  good() { cat <<'EOF'
static void with_bql(CodeBlock block)
{
    bool locked = bql_locked();
    if (!locked) {
        bql_lock();
    }
    if (!cocoa_display_closed) {
        block();
    }
    if (!locked) {
        bql_unlock();
    }
}
static bool bool_with_bql(BoolCodeBlock block)
{
    bool locked = bql_locked();
    bool val;
    if (!locked) {
        bql_lock();
    }
    val = cocoa_display_closed ? false : block();
    if (!locked) {
        bql_unlock();
    }
    return val;
}
static void cocoa_display_cleanup(void)
{
    if (!kbd) {
        return;
    }
    cocoa_display_closed = true;
    qemu_console_unregister_listener(&dcl);
    g_clear_pointer(&kbd, qkbd_state_free);
    qemu_event_set(&cbevent);
}
EOF
  }
  case_() {
    local p; p=$(problems "$3")
    if [[ $2 == ok && -z $p ]] || [[ $2 == fail && -n $p ]]; then echo "ok   $1${p:+ ($p)}"
    else echo "FAIL $1: want $2, got: ${p:-no problem}"; fail=1; fi
  }
  good > "$T/good.m"; case_ "the fixed code" ok "$T/good.m"
  good | sed '/cocoa_display_closed = true;/d' > "$T/a.m"; case_ "no closed mark (3.0.0 candidate crash)" fail "$T/a.m"
  good | sed 's/    if (!cocoa_display_closed) {/    {/' > "$T/b.m"; case_ "with_bql unguarded" fail "$T/b.m"
  good | sed 's/cocoa_display_closed ? false : block()/block()/' > "$T/c.m"; case_ "bool_with_bql unguarded" fail "$T/c.m"
  good | sed 's/    qemu_event_set(&cbevent);/    qemu_event_destroy(\&cbevent);/' > "$T/d.m"; case_ "cbevent destroyed" fail "$T/d.m"
  exit $fail
fi

[[ -f ${1:-} ]] || { echo "usage: $0 <patched ui/cocoa.m> | --self-test" >&2; exit 2; }
p=$(problems "$1")
if [[ -n $p ]]; then printf 'FAIL %s\n' "$p"; exit 1; fi
echo "ok   no events into QEMU after the display's cleanup"
