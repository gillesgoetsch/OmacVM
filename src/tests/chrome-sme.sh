#!/bin/bash
# omacvm check's "Google Chrome" line (src/guest/check.sh, chrome_sme_line and the
# block that calls it). Google Chrome 154 and older kills its tab on every video it
# decodes on the CPU when the VM's CPU has SME without SVE (Apple M4 and newer):
# libyuv's SME code was built for Armv9-A, so it starts with an SVE instruction
# (fixed in Chrome 155). WARN for Chrome 154 with SME; ok for 155 and newer, and
# without SME; no line without Chrome. Function and block are taken from check.sh
# as they are; Chrome's --version and /proc/cpuinfo are stand-ins.
#   src/tests/chrome-sme.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
check="$here/../guest/check.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-chrome-sme.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
# /proc/cpuinfo's Features: an M4 in an OmacVM.app VM (QEMU 11) and an M1.
M4="Features	: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm jscvt fcma lrcpc dcpop sha3 asimddp sha512 asimdfhm dit uscat ilrcpc flagm sb paca pacg dcpodp flagm2 frint i8mm bf16 bti afp rpres sme smei16i64 smef64f64 smei8i32 smef16f32 smeb16f32 smef32f32 sme2 smei16i32 smebi32i32"
M1="Features	: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm jscvt fcma lrcpc dcpop sha3 asimddp sha512 asimdfhm dit uscat ilrcpc flagm ssbs sb paca pacg dcpodp flagm2 frint"
WARN154="Google Chrome 154.0.8037.97 crashes on videos it decodes on the CPU on this Mac: update Chrome (155 or newer)"

# 1. The function alone.
awk '/^chrome_sme_line\(\) \{/ {on=1} on {print} on && /^}$/ {exit}' "$check" > "$T/fn.sh"
if [[ ! -s $T/fn.sh ]]; then echo "FAIL no chrome_sme_line in check.sh"; fail=1
else
  # shellcheck disable=SC1091
  source "$T/fn.sh"
  expect() {   # what, chrome --version, Features line, want
    local got; got=$(chrome_sme_line "$2" "$3")
    if [[ $got == "$4" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$got', want '$4'"; fail=1; fi
  }
  expect "Chrome 154 with SME (M4): WARN, update to 155" "Google Chrome 154.0.8037.97 " "$M4" "warn	$WARN154"
  expect "Chrome 156 with SME: ok" "Google Chrome 156.0.8078.73 " "$M4" "ok	156.0.8078.73"
  expect "Chrome 155 with SME (the first with libyuv's fix): ok" "Google Chrome 155.0.8059.39" "$M4" "ok	155.0.8059.39"
  expect "Chrome 154 without SME (M1): ok" "Google Chrome 154.0.8037.97 " "$M1" "ok	154.0.8037.97"
  expect "Chrome 140 with SME: WARN" "Google Chrome 140.0.7339.80" "$M4" \
    "warn	Google Chrome 140.0.7339.80 crashes on videos it decodes on the CPU on this Mac: update Chrome (155 or newer)"
  expect "only sme2 and smei16i64 listed, no plain sme: ok" "Google Chrome 154.0.8037.97" "Features	: fp asimd sme2 smei16i64" "ok	154.0.8037.97"
  expect "sme as the last word: WARN" "Google Chrome 154.0.8037.97" "Features	: fp asimd sme" "warn	$WARN154"
  expect "no Chrome (no --version): no line" "" "$M4" ""
  expect "an answer without a version: no line" "Trace/breakpoint trap" "$M4" ""
fi

# 2. The block in check.sh: Chrome found on the PATH or not, /proc/cpuinfo a stand-in.
sed -n '/^# Google Chrome 154 and older on a Mac with SME/,/^esac$/p' "$check" |
  sed -e "s|/proc/cpuinfo|$T/cpuinfo|" -e "s|/opt/google/chrome/google-chrome|$T/none/google-chrome|" > "$T/block"
if ! grep -q 'chrome_sme_line' "$T/block"; then echo "FAIL the \"Google Chrome\" block was not found in src/guest/check.sh"; fail=1
else
  mkdir -p "$T/bin" "$T/empty"
  # Only the tools the block needs are on the rows' PATH (no /usr/bin): a Chrome
  # the runner has installed never counts.
  for t in sed grep head; do ln -s "$(command -v $t)" "$T/empty/$t"; done
  # macOS has no timeout (the VM has GNU's): a stand-in that runs the command.
  if command -v timeout >/dev/null; then ln -s "$(command -v timeout)" "$T/empty/timeout"
  else printf '#!/bin/bash\nshift\nexec "$@"\n' > "$T/empty/timeout"; chmod +x "$T/empty/timeout"; fi
  row() {   # PATH: the line the block says
    env -i PATH="$1:$T/empty" /bin/bash -c 'ok() { echo "ok|$1|$2|${3:-}"; }; warn() { echo "warn|$1|$2|${3:-}"; }
      bad() { echo "fail|$1|$2"; }; skip() { echo "skip|$1|$2"; }
      source "$0"' "$T/block"
  }
  chrome() { printf '#!/bin/bash\n[[ $1 == --version ]] && echo "Google Chrome %s "\n' "$1" > "$T/bin/google-chrome-stable"; chmod +x "$T/bin/google-chrome-stable"; }
  want() {   # what, got, want
    if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fail=1; fi
  }
  printf 'processor\t: 0\nBogoMIPS\t: 48.00\n%s\n' "$M4" > "$T/cpuinfo"
  chrome 154.0.8037.97
  want "check: Chrome 154 on an M4: WARN, for a person" "$(row "$T/bin")" "warn|Google Chrome|$WARN154|human"
  chrome 156.0.8078.73
  want "check: Chrome 156 on an M4: ok" "$(row "$T/bin")" "ok|Google Chrome|156.0.8078.73|"
  printf 'processor\t: 0\nBogoMIPS\t: 48.00\n%s\n' "$M1" > "$T/cpuinfo"
  chrome 154.0.8037.97
  want "check: Chrome 154 on an M1 (no SME): ok" "$(row "$T/bin")" "ok|Google Chrome|154.0.8037.97|"
  rm -f "$T/bin/google-chrome-stable"
  want "check: no Chrome: no line" "$(row "$T/bin")" ""
fi
(( fail == 0 )) && echo "chrome-sme: all passed"
exit $fail
