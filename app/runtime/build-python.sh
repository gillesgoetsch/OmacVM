# shellcheck shell=bash
# Sourced by build-qemu-gpu-runtime.sh (and Tests/toolchain/test-build-python.sh).
#
# omacvm_build_python BIN_DIR: picks the python3 the runtime build runs and
# links it as BIN_DIR/python3 (the only file in BIN_DIR), so the build puts
# BIN_DIR first in PATH and nothing else changes: cc stays the one PATH had
# (/usr/bin/cc, whose xcrun shim finds the SDK). Prints the chosen path.
#
# - Python 3.11 or newer: QEMU's configure reads pythondeps.toml with tomllib;
#   3.9 (the Command Line Tools' and Xcode's) needs tomli, which mkvenv cannot
#   install offline (--disable-download).
# - Never Apple's /usr/bin/python3: a shim under SIP, macOS drops
#   DYLD_LIBRARY_PATH for it, so the virgl test binaries it starts would not
#   find libepoxy.
# None found: a message on stderr, return 1.
omacvm_build_python() {
  local dir=$1 name path version best=
  for name in python3 python3.14 python3.13 python3.12 python3.11; do
    path=$(command -v "$name" 2>/dev/null) || continue
    [[ $path == /* && $path != /usr/bin/* ]] || continue
    version=$("$path" -c 'import sys; print("%d %d" % sys.version_info[:2])' 2>/dev/null) || continue
    if [[ $version =~ ^3\ ([0-9]+)$ ]] && (( BASH_REMATCH[1] >= 11 )); then
      best=$path
      break
    fi
  done
  if [[ -z $best ]]; then
    echo "qemu-source-build: needs Python 3.11 or newer on PATH (python3, python3.14 ... python3.11; not Apple's /usr/bin/python3): QEMU's configure reads its dependency list with tomllib, and Python 3.9 would need tomli, which it cannot install offline. Homebrew: brew install python@3.13" >&2
    return 1
  fi
  mkdir -p "$dir" || return 1
  ln -sfn "$best" "$dir/python3" || return 1
  echo "$best"
}
