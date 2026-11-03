#!/bin/bash
# The runtime build's python3 (build-python.sh): 3.11 or newer, never Apple's
# /usr/bin/python3, linked alone into a folder of its own, so a Mac with only
# the Command Line Tools keeps /usr/bin/cc (the CLT's clang first in PATH did
# not find the SDK: Hypervisor/Hypervisor.h) and does not get the CLT's
# Python 3.9 (QEMU's mkvenv wants tomli, offline). Stub pythons on a PATH of
# their own; then the build script's wiring. Reported by @Vocllum in #655.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
runtime=$(cd "$here/../.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-build-python.XXXXXX")
trap 'rm -rf "$work"' EXIT
# shellcheck source=../../build-python.sh
source "$runtime/build-python.sh"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# stub DIR NAME "MAJOR MINOR": a python that answers the version question, or fails ("x").
stub() {
  mkdir -p "$1"
  if [[ $3 == x ]]; then
    printf '#!/bin/bash\nexit 1\n' > "$1/$2"
  else
    printf '#!/bin/bash\necho "%s"\n' "$3" > "$1/$2"
  fi
  chmod +x "$1/$2"
}
# run NAME PATH: picks with that PATH into a fresh folder; sets got, rc, err, cc_before, cc_after, files.
run() {
  local out="$work/$1"
  mkdir -p "$out"
  cc_before=$(PATH=$2 command -v cc || true)
  rc=0
  got=$(PATH=$2 omacvm_build_python "$out/bin" 2>"$out/err") || rc=$?
  err=$(cat "$out/err")
  cc_after=$(PATH="$out/bin:$2" command -v cc || true)
  files=$(cd "$out/bin" 2>/dev/null && for f in *; do printf '%s ' "$f"; done || true)
  link=$(readlink "$out/bin/python3" 2>/dev/null || true)
}

# A Command Line Tools folder: its own cc and a Python 3.9; a Homebrew folder with 3.13.
clt=$work/clt; brew=$work/brew; tools=$work/tools
stub "$clt" python3 "3 9"; printf '#!/bin/bash\necho clt-clang\n' > "$clt/cc"; chmod +x "$clt/cc"
stub "$brew" python3.13 "3 13"
mkdir -p "$tools"; printf '#!/bin/bash\necho cc\n' > "$tools/cc"; chmod +x "$tools/cc"

run clt-only "$tools:$clt:/bin"
[[ $rc -ne 0 && -z $got && $err == *"3.11 or newer"* && $err == *tomli* ]] &&
  ok "only Python 3.9: a clear stop (3.11 or newer, tomli)" || bad "only Python 3.9: rc $rc, got '$got', err '$err'"

run clt-brew "$tools:$clt:$brew:/bin"
[[ $rc -eq 0 && $got == "$brew/python3.13" && $link == "$brew/python3.13" ]] &&
  ok "3.9 as python3, 3.13 later in PATH: python3.13" || bad "3.9 + 3.13: rc $rc, got '$got', link '$link'"
[[ $files == "python3 " && $cc_after == "$cc_before" && $cc_after == "$tools/cc" ]] &&
  ok "... the folder holds only python3; cc stays $tools/cc" || bad "... folder '$files', cc $cc_before -> $cc_after"

new=$work/new; stub "$new" python3 "3 12"; stub "$new" python3.13 "3 13"
run new-first "$new:$clt:/bin"
[[ $rc -eq 0 && $got == "$new/python3" ]] && ok "python3 3.12 first: that one" || bad "python3 3.12: got '$got'"

broken=$work/broken; stub "$broken" python3 x; stub "$broken" python3.11 "3 11"
run broken "$broken:/bin"
[[ $rc -eq 0 && $got == "$broken/python3.11" ]] && ok "a python3 that does not run is skipped (python3.11)" ||
  bad "broken python3: got '$got'"

old=$work/old; stub "$old" python3.11 "3 10"
run lies "$old:$clt:/bin"
[[ $rc -ne 0 ]] && ok "the version it reports counts, not its name" || bad "python3.11 reporting 3.10 was taken: '$got'"

later=$work/later; stub "$later" python3.14 "3 14"
run usr-bin "/usr/bin:$later:/bin"
[[ $rc -eq 0 && $got == "$later/python3.14" ]] && ok "Apple's /usr/bin/python3 first in PATH: never taken" ||
  bad "/usr/bin first: got '$got'"

# The build script: picks through the function, puts only that folder first.
script=$runtime/build-qemu-gpu-runtime.sh
grep -qxF 'source "$native_dir/build-python.sh"' "$script" && ok "the runtime build sources build-python.sh" ||
  bad "the runtime build does not source build-python.sh"
grep -qxF 'build_python=$(omacvm_build_python "$work_dir/python-bin") || exit 1' "$script" &&
  grep -qxF 'PATH="$work_dir/python-bin:$PATH"' "$script" &&
  ok "... and puts only its python-bin folder first in PATH" || bad "the runtime build does not use its python-bin folder"
# Fails on the old line (PATH="$(dirname "$real_python"):$PATH" after xcrun -f python3).
if grep -E '^[[:space:]]*(export[[:space:]]+)?PATH=' "$script" | grep -vF '$(dirname "$ninja")' |
   grep -vxF 'PATH="$work_dir/python-bin:$PATH"' | grep -q .; then
  bad "the runtime build puts another folder first in PATH"
else
  ok "... and no other folder (the private ninja's aside)"
fi
grep -qF 'xcrun -f python3' "$script" && bad "the runtime build still looks for the toolchain's python3" ||
  ok "... and does not reach for the toolchain's python3"
exit $fail
