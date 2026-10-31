# What the build needs on the Mac, and installing it (sourced after mac.sh,
# setup.sh and ui.sh; macOS's bash 3.2). Every install asks first and shows the
# command; with --yes (YES=1) nothing is installed and the build stops with
# the command to run instead (exit 3), so scripts and agents decide themselves.
#   prereq_screen            the welcome: this Mac and what is there
#   ensure_xcode_tools       Xcode's command line tools (Swift, clang, git)
#   ensure_homebrew          Homebrew, on the PATH of this run
#   ensure_brew_tools        zstd, e2fsprogs, and an OpenSSL with SHA-512 passwords
#   ensure_vm_app TYPE       Parallels Desktop, UTM 5, VMware Fusion (waits for
#                            it) or OmacVM.app (downloaded for this OmacVM's version)

# An OpenSSL that can hash the password (macOS's own LibreSSL has no "passwd -6").
# Its input is a here-string, not printf in a pipe: an openssl that refuses (or is
# not there) exits before reading, and where SIGPIPE is ignored (a CI runner) bash 5's
# printf then said "write error: Broken pipe" on stderr, inside --plan --json's output.
sha512_openssl() {
  local o
  for o in openssl "$(brew --prefix openssl@3 2>/dev/null)/bin/openssl"; do
    "$o" passwd -6 -stdin <<<x >/dev/null 2>&1 && { echo "$o"; return 0; }
  done
  return 1
}

have_xcode_tools() { xcode-select -p >/dev/null 2>&1 && command -v swiftc >/dev/null; }
have_homebrew() {
  command -v brew >/dev/null && return 0
  # Installed, but this shell's PATH does not have it yet.
  local b
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x $b ]] && { eval "$("$b" shellenv)"; return 0; }
  done
  return 1
}
missing_brew_tools() {
  local m=""
  command -v zstd >/dev/null || m+=" zstd"
  command -v e2fsck >/dev/null || [[ -x $(brew --prefix e2fsprogs 2>/dev/null)/sbin/e2fsck ]] || m+=" e2fsprogs"
  sha512_openssl >/dev/null || m+=" openssl@3"
  echo "${m# }"
}
have_parallels() { [[ -d "/Applications/Parallels Desktop.app" && -x $PRLCTL ]]; }
have_utm5() { [[ -x $UTMCTL ]] && (( $(utm_major || echo 0) >= 5 )); }
have_fusion() {
  local v; v=$(fusion_version | cut -d. -f1)
  [[ -x $VMRUN && -x $FUSION_LIB/vmcli && $v =~ ^[0-9]+$ ]] && (( v >= 13 ))
}
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

ensure_homebrew() {
  have_homebrew && return 0
  prereq_install "Homebrew" '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  say "    Homebrew's installer asks for your Mac password and explains each step."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" < "$TTY" ||
    die "Homebrew's installer did not finish: see https://brew.sh, then run omacvm again"
  have_homebrew || die "Homebrew is installed but not found: open a new terminal, then run omacvm again"
  # omacvm in Homebrew's bin too, which every terminal has on its PATH.
  local here; here=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
  [[ -w $(brew --prefix)/bin ]] && ln -sf "$here/omacvm" "$(brew --prefix)/bin/omacvm"
  # Homebrew on the PATH of new terminals too (its installer only prints how).
  local line="eval \"\$($(command -v brew) shellenv)\""
  if ! grep -qsF "$line" "$HOME/.zprofile" && ask_yn "Put Homebrew on the PATH of new terminals (a line in ~/.zprofile)?" y; then
    printf '\n%s\n' "$line" >> "$HOME/.zprofile"
  fi
}

ensure_brew_tools() {
  local m; m=$(missing_brew_tools)
  [[ -z $m ]] && return 0
  (( DRY )) && return 0
  ensure_homebrew
  ui_spin "Installing from Homebrew: $m" brew install -q $m || needs_person "brew install $m failed: run it yourself, then omacvm again"
}

ensure_vm_app() {
  case $1 in
    parallels)
      have_parallels && return 0
      ensure_homebrew
      prereq_install "Parallels Desktop" "brew install --cask parallels"
      brew install --cask parallels || die "brew install --cask parallels failed: install it from https://www.parallels.com/products/desktop/, then run omacvm again"
      open -a "Parallels Desktop" 2>/dev/null || true
      say "    Parallels Desktop opens: follow its first steps (it may ask for your Mac password)." ;;
    utm)
      have_utm5 && return 0
      local v; v=$(defaults read /Applications/UTM.app/Contents/Info CFBundleShortVersionString 2>/dev/null || true)
      ensure_homebrew
      if [[ -n $v ]] && ! brew list --cask utm >/dev/null 2>&1; then
        # UTM 4 from the App Store or the website: not Homebrew's to replace.
        utm_install_help
        prereq_install "UTM 5" "quit UTM, move /Applications/UTM.app to the Trash (your VMs stay), then: brew install --cask utm@beta"
        die "move the old UTM to the Trash first, then run omacvm again"
      fi
      if [[ -n $v ]]; then
        prereq_install "UTM 5 (you have UTM $v)" "brew uninstall --cask utm && brew install --cask utm@beta"
        osascript -e 'quit app "UTM"' >/dev/null 2>&1 || true
        brew uninstall --cask utm || die "brew uninstall --cask utm failed"
      else
        prereq_install "UTM 5" "brew install --cask utm@beta"
      fi
      brew install --cask utm@beta || die "brew install --cask utm@beta failed: see https://github.com/utmapp/UTM/releases"
      open -a UTM 2>/dev/null || true ;;
    fusion)
      # Free, but Broadcom only hands it out after a sign-in: no Homebrew package.
      have_fusion && return 0
      fusion_install_help
      (( YES )) && needs_person "VMware Fusion is not installed (download it from Broadcom, see above)"
      open "https://support.broadcom.com/group/ecx/productdownloads?subfamily=VMware%20Fusion" 2>/dev/null || true
      ui_spin "Waiting for VMware Fusion in Applications (download it, drag it there)" bash -c '
        for _ in $(seq 1440); do [[ -d "/Applications/VMware Fusion.app" ]] && exit 0; sleep 5; done; exit 1' ||
        die "VMware Fusion is not in Applications yet: install it, then run omacvm again"
      open -a "VMware Fusion" 2>/dev/null || true
      say "    VMware Fusion opens: follow its first steps (it asks for your Mac password once)."
      have_fusion || needs_person "VMware Fusion 13 or newer is needed (found: $(fusion_version))" ;;
    app)
      have_omacvm_app && return 0
      local v a; v=$(cat "$R/src/VERSION")
      app_published "$v" || app_not_published "$v"
      prereq_install "OmacVM.app $v" "$(app_install_cmd "$v")"
      a=$(app_install "$v") || die "OmacVM.app was not installed (see above)"
      say "    Installed: $a" ;;
  esac
}

# Releases before OmacVM.app was published have no zip.
app_not_published() {   # VERSION
  needs_person "there is no OmacVM.app download for OmacVM $1 ($(app_zip_url "$1") with its signed update feed is missing): releases before the app have none. Run omacvm update for a newer OmacVM, or choose another app"
}

fusion_install_help() {
  say "    VMware Fusion is free, but Broadcom asks you to sign in to download it:"
  say "      1. support.broadcom.com: sign in (or create a free account)"
  say "      2. My Downloads > VMware Fusion > the newest version > download"
  say "      3. open the .dmg, drag VMware Fusion into Applications"
  say "      4. on its first start it asks for Accessibility: click OK and turn"
  say "         VMware Fusion on in System Settings > Privacy & Security > Accessibility"
}

# The welcome: this Mac, and what the build needs.
prereq_screen() {
  local model chip mark
  model=$(system_profiler SPHardwareDataType 2>/dev/null | sed -n 's/^ *Model Name: //p' | head -1)
  chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
  printf '\n  %s%s%s  ·  %s  ·  %s GB  ·  macOS %s%s\n' "$UB" "${model:-Mac}" "$UR" "${chip:-Apple Silicon}" "$mac_mem_gb" \
    "$(sw_vers -productVersion)" "$( [[ $NOTCH == notch ]] && echo "  ·  notch")" > "$TTY"
  for mark in "Xcode's command line tools|have_xcode_tools" "Homebrew|have_homebrew" \
              "Parallels Desktop|have_parallels" "UTM 5|have_utm5" "VMware Fusion|have_fusion" \
              "OmacVM.app|have_omacvm_app"; do
    if ${mark#*|}; then printf '  %s✓%s %s\n' "$UOK" "$UR" "${mark%%|*}" > "$TTY"
    elif [[ $mark == Xcode* ]] && _tools_own_resources >/dev/null; then
      printf '  %s·%s %s %s(not installed; OmacVM.app does not need them)%s\n' "$UD" "$UR" "${mark%%|*}" "$UD" "$UR" > "$TTY"
    else printf '  %s·%s %s %s(not installed)%s\n' "$UD" "$UR" "${mark%%|*}" "$UD" "$UR" > "$TTY"; fi
  done
}
