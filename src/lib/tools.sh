# Apple's developer tools without Xcode's Command Line Tools (sourced; Mac
# side, bash 3.2). On a Mac without them, /usr/bin/python3, swift, git, clang,
# make and the rest are stubs: running one opens macOS's "install the command
# line developer tools?" window, and fails. OmacVM.app's route needs none of
# them: the app carries a python3 (Contents/Resources/python) and the small
# Swift programs the Mac side asks (Contents/Resources/tools, built by
# app/scripts/build-app.sh from the .swift files named below).
#   clt_has TOOL          the active developer folder has TOOL; never asks macOS
#   tools_app_resources   Contents/Resources of the OmacVM.app to take them from:
#                         the app this copy of OmacVM is part of (also its copies:
#                         OMACVM_APP_RUNTIME), else the installed one (app_bundle,
#                         when src/lib/app.sh is loaded)
#   tools_python          a python3 that runs here without asking (status 1: none)
#   tools_path            that python3 first on PATH (for python3 and #!/usr/bin/env
#                         python3), and no __pycache__ written (inside the signed
#                         app that would break its seal)
#   mac_tool NAME [ARG]   what src/*/NAME.swift prints: its app's built copy,
#                         else the checkout's source with Swift, falling back to
#                         the installed app if Swift is missing or fails
#                         mac-notch (src/display), mac-clock
#                         (src/clock), mac-free-gb (src/lib)
# OMACVM_STUB_BIN: where macOS's stubs are (/usr/bin; src/tests/no-clt.sh
# points it at stand-ins).
_TOOLS_SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
_TOOLS_STUBS=${OMACVM_STUB_BIN:-/usr/bin}

clt_has() {   # TOOL
  local d
  d=$(xcode-select -p 2>/dev/null) && [[ -n $d && -d $d ]] || return 1
  xcrun -f "$1" >/dev/null 2>&1
}

# The app this copy is part of: Contents/Resources/omacvm/src, or a copy of it
# made by apply-vm.sh or the app's omacvm (they set OMACVM_APP_RUNTIME).
_tools_own_resources() {
  local r=""
  if [[ ${OMACVM_APP_RUNTIME:-} == */Contents/Resources/runtime ]]; then r=${OMACVM_APP_RUNTIME%/runtime}
  elif [[ $_TOOLS_SRC == */Contents/Resources/omacvm/src ]]; then r=${_TOOLS_SRC%/omacvm/src}; fi
  [[ -n $r && -d $r ]] && echo "$r"
}

tools_app_resources() {
  local a
  _tools_own_resources && return 0
  declare -F app_bundle >/dev/null && a=$(app_bundle 2>/dev/null) && [[ -d $a/Contents/Resources ]] &&
    echo "$a/Contents/Resources"
}

tools_python() {
  local p r
  # Not macOS's stub: Homebrew's, the app's (tools_path ran), or any other.
  if p=$(command -v python3 2>/dev/null) && [[ $p != "$_TOOLS_STUBS/python3" ]]; then echo "$p"; return 0; fi
  if [[ $p == "$_TOOLS_STUBS/python3" ]] && clt_has python3; then echo "$p"; return 0; fi
  if r=$(tools_app_resources) && [[ -x $r/python/bin/python3 ]]; then echo "$r/python/bin/python3"; return 0; fi
  [[ -x /opt/homebrew/bin/python3 ]] && { echo /opt/homebrew/bin/python3; return 0; }
  return 1
}

tools_path() {
  local p
  export PYTHONDONTWRITEBYTECODE=1
  p=$(tools_python) || return 0
  [[ $(command -v python3 2>/dev/null) == "$p" ]] && return 0
  PATH=$(dirname "$p"):$PATH
  export PATH
}

mac_tool() {   # NAME [ARG...]
  local n=$1 r f out status=1
  shift
  if r=$(_tools_own_resources) && [[ -x $r/tools/$n ]]; then "$r/tools/$n" "$@"; return; fi
  for f in "$_TOOLS_SRC"/*/"$n.swift"; do
    if [[ -f $f ]] && clt_has swift; then
      # A checkout uses its own source first. Finding Swift does not mean it
      # can use the selected SDK; keep a failed answer out of the fallback's stdout.
      if out=$(swift "$f" "$@"); then printf '%s\n' "$out"; return 0
      else status=$?; fi
    fi
  done
  if r=$(tools_app_resources) && [[ -x $r/tools/$n ]]; then "$r/tools/$n" "$@"; return; fi
  return "$status"
}
