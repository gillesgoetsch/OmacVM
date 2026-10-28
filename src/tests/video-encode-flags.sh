#!/bin/bash
# Chrome's WebRTC encoder flags in an OmacVM.app VM (src/app/guest/omacvm-video-encode)
# against stand-ins: vainfo, the GPU's render node and browser-video-encode.py.
# Up to 3.0.18 Update VM's run without the VM's display took the flags out
# (vainfo offered nothing) and no start put them back.
#  - apply with an encoder: on; a GPU without one: off; no GPU (Update VM) or
#    vainfo failing: left alone;
#  - each start: put back what is missing while an encoder is offered, never
#    taken out; nothing when they are all there; no user in the env: nothing.
#  - the decode group (Chrome converts its decoded pictures, zero copy off,
#    3.2.11): written at every apply and put back at a start when missing,
#    whatever the GPU offers then (Update VM's run has none).
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/dri"
cat > "$T/bin/vainfo" <<'SH'
#!/bin/bash
case $(cat "$VAINFO_MODE") in
  encode) printf '      VAProfileH264Main               :\tVAEntrypointVLD\n      VAProfileH264Main               :\tVAEntrypointEncSlice\n' ;;
  decode) printf '      VAProfileH264Main               :\tVAEntrypointVLD\n' ;;
  fail) exit 1 ;;
esac
SH
cat > "$T/encode.py" <<'PY'
import os, sys
open(os.environ["CALLS"], "a").write(" ".join(sys.argv[1:]) + "\n")
state = os.environ["DECODE" if sys.argv[3:] == ["decode"] else "FLAGS"]
if sys.argv[2] == "check":
    sys.exit(0 if open(state).read().strip() == "on" else 1)
if sys.argv[2] in ("on", "off"):
    open(state, "w").write(sys.argv[2] + "\n")
PY
cat > "$T/bin/python3" <<SH
#!/bin/bash
exec "$(command -v python3)" "\$@"
SH
chmod +x "$T/bin/"*
printf 'OMACVM_VM_TYPE=app\nOMACVM_USER=alice\n' > "$T/env"
export VAINFO_MODE=$T/mode CALLS=$T/calls FLAGS=$T/flags DECODE=$T/decode OMACVM_DRI=$T/dri OMACVM_ENV=$T/env OMACVM_VIDEO_ENCODE_PY=$T/encode.py
S=$R/src/app/guest/omacvm-video-encode
fail=0
run() { PATH="$T/bin:$PATH" "$S" "$@"; }
gpu() { if [[ $1 == none ]]; then rm -f "$T/dri/renderD128"; else touch "$T/dri/renderD128"; echo "$1" > "$T/mode"; fi; }
t() { # WHAT EXPECTED_FLAGS EXPECTED_DECODE EXPECTED_CALLS
  local f d c; f=$(cat "$T/flags" 2>/dev/null || echo none); d=$(cat "$T/decode" 2>/dev/null || echo none)
  c=$(paste -sd';' "$T/calls" 2>/dev/null || true)
  if [[ $f == "$2" && $d == "$3" && $c == "$4" ]]; then echo "ok   $1"
  else echo "FAIL $1: flags $f, decode $d, calls '$c'" >&2; fail=1; fi
  : > "$T/calls"
}
: > "$T/calls"
echo on > "$T/flags"
gpu none; run apply alice >/dev/null
t "apply without the VM's GPU (Update VM): encoder flags left on, decode group written" on on "alice on decode"
gpu fail; run apply alice >/dev/null
t "apply, vainfo fails: encoder flags left alone, decode group written" on on "alice on decode"
gpu decode; run apply alice >/dev/null
t "apply, a GPU without an encoder (an older app): off" off on "alice on decode;alice off"
gpu encode; run apply alice >/dev/null
t "apply with an encoder: on" on on "alice on decode;alice on"
echo off > "$T/flags"   # what a 3.0.18 Update VM left
gpu encode; run boot >/dev/null
t "start with an encoder, flags missing (3.0.18's Update VM): put back" on on "alice check decode;alice check;alice on"
run boot >/dev/null
t "start, flags there: only checked, files not touched" on on "alice check decode;alice check"
echo off > "$T/flags"
gpu decode; run boot >/dev/null
t "start, no encoder offered: never taken out or added" off on "alice check decode"
echo off > "$T/decode"   # a VM updated before 3.2.11, or the line taken out
gpu none; OMACVM_BOOT_LOOKS=1 run boot >/dev/null
t "start without a render node: the decode group put back, encoder flags not touched" off on "alice check decode;alice on decode"
printf 'OMACVM_VM_TYPE=app\n' > "$T/env"; gpu encode; run boot >/dev/null
t "start, no user in /etc/omacvm/env: nothing" off on ""
out=$(run apply 2>&1) && { echo "FAIL apply without a user ran" >&2; fail=1; } || echo "ok   apply without a user: usage"
# The installer runs it at apply, the unit at each start.
grep -q 'omacvm-video-encode apply "\$U"' "$R/src/app/guest/install.sh" && grep -q 'systemctl enable omacvm-video-encode.service' "$R/src/app/guest/install.sh" &&
  grep -q '^ExecStart=/usr/local/bin/omacvm-video-encode boot$' "$R/src/app/guest/omacvm-video-encode.service" &&
  ! grep -q 'browser-video-encode.py "\$U" off' "$R/src/app/guest/install.sh" &&
  echo "ok   install.sh: apply through omacvm-video-encode, the unit at each start" ||
  { echo "FAIL install.sh wiring" >&2; fail=1; }
exit $fail
