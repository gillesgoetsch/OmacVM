#!/bin/bash
# sha512_openssl (src/lib/prereq.sh) finds an openssl with "passwd -6" and says
# nothing on stderr, also where SIGPIPE is ignored (a CI runner: its children
# inherit that) and an openssl exits before it reads its input (macOS's
# LibreSSL refuses -6 at once, a missing one fails at once). There, bash 5's
# printf in a pipe said "printf: write error: Broken pipe", and on omacvm-m1-3
# that line landed inside omacvm build --plan --json's output (utm-vm-dir.sh:
# "no JSON"). Here the probe's input comes late on purpose, as on a busy Mac.
# Stand-ins for openssl and brew; every bash found (macOS's 3.2 prints no such
# error, bash 5 does). No network, nothing installed.
#   src/tests/openssl-probe.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

mkdir -p "$T/bin" "$T/brew/opt/openssl@3/bin"
# macOS's openssl: no passwd -6, exits without reading.
printf '#!/bin/bash\necho "passwd: Unknown option: -6" >&2\nexit 1\n' > "$T/bin/openssl"
# Homebrew's: reads the password, prints a hash.
printf '#!/bin/bash\nread -r p\necho "\\$6\\$salt\\$hash"\n' > "$T/brew/opt/openssl@3/bin/openssl"
# brew --prefix openssl@3: BREW_HAS=1 that folder, else nothing (no Homebrew openssl).
printf '#!/bin/bash\n[[ ${BREW_HAS:-0} == 1 ]] && echo "%s/brew/opt/openssl@3"\n' "$T" > "$T/bin/brew"
chmod +x "$T/bin/openssl" "$T/bin/brew" "$T/brew/opt/openssl@3/bin/openssl"

cat > "$T/run.sh" <<EOF
# The probe's input late: the scheduler of a busy Mac can run it after openssl is gone.
printf() { [[ \$# == 1 && \$1 == x ]] && sleep 0.1; builtin printf "\$@"; }
source "$R/src/lib/prereq.sh"
sha512_openssl; echo "rc \$?"
EOF

# Every bash this Mac has: macOS's, the PATH's (bash 5 on the CI runners), GUEST_BASH, Homebrew's.
bashes=()
for b in /bin/bash "$(command -v bash)" "${GUEST_BASH:-}" /opt/homebrew/bin/bash; do
  [[ -n $b && -x $b ]] || continue
  b=$(cd "$(dirname "$b")" && pwd -P)/$(basename "$b")
  case " ${bashes[*]-} " in *" $b "*) ;; *) bashes+=("$b") ;; esac
done
new=0
for b in "${bashes[@]}"; do
  v=$("$b" -c 'echo ${BASH_VERSINFO[0]}')
  (( v >= 4 )) && new=1
  for has in 1 0; do
    out=$(BREW_HAS=$has PATH="$T/bin:$PATH" perl -e '$SIG{PIPE} = "IGNORE"; exec @ARGV' "$b" "$T/run.sh" 2> "$T/err")
    if (( has )); then
      expect "bash $v: Homebrew's openssl is the one" "$T/brew/opt/openssl@3/bin/openssl
rc 0" "$out"
    else
      expect "bash $v: none can: status 1" "rc 1" "$out"
    fi
    expect "bash $v, SIGPIPE ignored, Homebrew openssl $( ((has)) && echo there || echo missing): nothing on stderr" "" "$(cat "$T/err")"
  done
done
(( new )) || echo "note: no bash 4 or newer here: the write error this guards against cannot show"
exit $fail
