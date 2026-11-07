# What the build needs on the Mac, and installing it (sourced after mac.sh,
# setup.sh and ui.sh; macOS's bash 3.2). Every install asks first and shows the
# command; with --yes (YES=1) nothing is installed and the build stops with
# the command to run instead (exit 3), so scripts and agents decide themselves.
#   prereq_screen            the welcome: this Mac and what is there
#   ensure_xcode_tools       Xcode's command line tools (Swift, clang, git)
#   ensure_vm_app            OmacVM.app (downloaded for this OmacVM's version)

have_xcode_tools() { xcode-select -p >/dev/null 2>&1 && command -v swiftc >/dev/null; }
have_omacvm_app() { app_bundle >/dev/null; }

# The installs: ask (or stop with the command under --yes), run, check.
prereq_install() {   # "what" "command" -> runs the command after asking
  if (( YES )); then
    printf '\033[1;31mneeds you:\033[0m %s is missing: %s\n' "$1" "$2" >&2; exit 3
  fi
  say "    $1 is missing. OmacVM can install it now:"
  say "      $2"
  ask_yn "Install $1?" y || { say "    Install it yourself, then run omacvm again."; exit 3; }
}

ensure_xcode_tools() {
  have_xcode_tools && return 0
  prereq_install "Xcode's command line tools" "xcode-select --install"
  xcode-select --install >/dev/null 2>&1 || true
  xcode_wait() { local i; for ((i = 0; i < 720; i++)); do have_xcode_tools && return 0; sleep 5; done; return 1; }
  ui_spin "Installing Xcode's command line tools (click Install in macOS's window)" xcode_wait ||
    die "Xcode's command line tools are not there after an hour: install them (xcode-select --install), then run omacvm again"
}

# The Swift compiler must actually build an AppKit app (OmacVM's Mac apps are
# built in the last step): command line tools older than macOS, or half
# updated, fail there after the long VM install. Tried once, up front.
swift_builds_apps() {
  local d; d=$(mktemp -d)
  printf 'import AppKit\nprint(NSApplication.shared.isRunning ? "" : "ok")\n' > "$d/t.swift"
  swiftc -o "$d/t" "$d/t.swift" >/dev/null 2>&1 && [[ $("$d/t" 2>/dev/null) == ok ]]
  local rc=$?; rm -rf "$d"; return $rc
}
ensure_swift_works() {
  ui_spin "Checking the Swift compiler (OmacVM builds two small Mac apps)" swift_builds_apps && return 0
  needs_person "Xcode's command line tools cannot build a Mac app on this macOS (often after a macOS update). Reinstall them: sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install, then run omacvm again"
}

ensure_vm_app() {
  have_omacvm_app && return 0
  local v a; v=$(cat "$R/src/VERSION")
  app_published "$v" || app_not_published "$v"
  prereq_install "OmacVM.app $v" "$(app_install_cmd "$v")"
  a=$(app_install "$v") || die "OmacVM.app was not installed (see above)"
  say "    Installed: $a"
}

# Releases before OmacVM.app was published have no zip.
app_not_published() {   # VERSION
  needs_person "there is no OmacVM.app download for OmacVM $1 ($(app_zip_url "$1") with its signed update feed is missing): releases before the app have none. Run omacvm update for a newer OmacVM"
}

# The welcome: this Mac, and what the build needs.
prereq_screen() {
  local model chip mark
  model=$(system_profiler SPHardwareDataType 2>/dev/null | sed -n 's/^ *Model Name: //p' | head -1)
  chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
  printf '\n  %s%s%s  ·  %s  ·  %s GB  ·  macOS %s%s\n' "$UB" "${model:-Mac}" "$UR" "${chip:-Apple Silicon}" "$mac_mem_gb" \
    "$(sw_vers -productVersion)" "$( [[ $NOTCH == notch ]] && echo "  ·  notch")" > "$TTY"
  for mark in "Xcode's command line tools|have_xcode_tools" "OmacVM.app|have_omacvm_app"; do
    if ${mark#*|}; then printf '  %s✓%s %s\n' "$UOK" "$UR" "${mark%%|*}" > "$TTY"
    elif [[ $mark == Xcode* ]] && _tools_own_resources >/dev/null; then
      printf '  %s·%s %s %s(not installed; OmacVM.app does not need them)%s\n' "$UD" "$UR" "${mark%%|*}" "$UD" "$UR" > "$TTY"
    else printf '  %s·%s %s %s(not installed)%s\n' "$UD" "$UR" "${mark%%|*}" "$UD" "$UR" > "$TTY"; fi
  done
}
