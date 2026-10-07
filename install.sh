#!/bin/bash
# Get OmacVM: clone it to ~/.omacvm (or update it there), put the `omacvm`
# command on your PATH and start it, which asks what to do (no VM yet: it
# builds one). From GitHub in one line:
#   curl -fsSL https://raw.githubusercontent.com/gillesgoetsch/omacvm/main/install.sh | bash
# From a clone: ./install.sh (links that clone instead). --no-start: only install.
# A branch or tag instead of main (also switches an existing ~/.omacvm):
#   curl -fsSL https://raw.githubusercontent.com/gillesgoetsch/omacvm/main/install.sh | OMACVM_REF=<branch or tag> bash
set -euo pipefail
REPO=https://github.com/gillesgoetsch/omacvm.git
START=1
for a in "$@"; do
  case $a in
    --no-start) START=0 ;;
    *) echo "install.sh: unknown option $a" >&2; exit 2 ;;
  esac
done
# Characters, not bytes, for the spinner, ✓ and the box (a C locale, e.g. over
# SSH or with LANG unset, would cut them apart): a UTF-8 locale, which every
# Mac has.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;
  *) if [[ -n ${LC_ALL:-} ]]; then export LC_ALL=en_US.UTF-8; else export LC_CTYPE=en_US.UTF-8; fi ;;
esac
say() { printf '\033[1;32m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { echo "OmacVM needs an Apple Silicon Mac." >&2; exit 1; }

# Xcode's command line tools (git, and Swift for the build), the way Homebrew's
# own installer gets them: through macOS's software update, no window to find
# (asks for the Mac password); macOS's install window only if that finds none.
spin_until() {   # "message" test-command...: a spinner with the time until it succeeds
  local msg=$1 frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' t0=$SECONDS i=0 e; shift
  until "$@"; do
    e=$(( SECONDS - t0 ))
    (( e > 3600 )) && return 1
    printf '\r  %s %s %dm %02ds ' "${frames:i % 10:1}" "$msg" $(( e / 60 )) $(( e % 60 )) > /dev/tty 2>/dev/null
    i=$(( i + 1 )); sleep 0.2
  done
  printf '\r\033[2K' > /dev/tty 2>/dev/null
}
clt_ready() { xcode-select -p >/dev/null 2>&1 && /usr/bin/git --version >/dev/null 2>&1; }
install_clt() {
  local flag=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress label list
  say "Xcode's command line tools first (git, Swift), from macOS's software update"
  touch "$flag"
  list=$(mktemp)
  /usr/sbin/softwareupdate -l > "$list" 2>&1 &
  spin_until "Looking for them in software update" bash -c "! kill -0 $! 2>/dev/null"
  label=$(grep -B 1 -E 'Command Line Tools' "$list" | awk -F'*' '/^ *\*/ { print $2 }' |
          sed -e 's/^ *Label: //' -e 's/^ *//' | sort -V | tail -n1) || label=""
  rm -f "$list"
  if [[ -n $label ]]; then
    echo "    installing \"$label\" (your Mac password):"
    sudo /usr/sbin/softwareupdate -i "$label" < /dev/tty && sudo /usr/bin/xcode-select --switch /Library/Developer/CommandLineTools
  fi
  rm -f "$flag"
  if ! clt_ready; then
    echo "    software update did not install them: macOS's own installer window opens now, click Install"
    xcode-select --install >/dev/null 2>&1 || true
    spin_until "Waiting for Xcode's command line tools (click Install in macOS's window)" clt_ready ||
      { echo "Xcode's command line tools did not install: run xcode-select --install, then this again." >&2; exit 3; }
  fi
  echo "    Xcode's command line tools are installed"
}

# This checkout, when run from one; else ~/.omacvm.
here=""
if [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]]; then
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  [[ -x $here/omacvm && -f $here/src/VERSION ]] || here=""
fi
if [[ -z $here ]]; then
  here=$HOME/.omacvm
  # A fresh Mac: git (and Swift, for the build) come with Xcode's command line
  # tools; macOS's /usr/bin/git is only a stub that offers to install them.
  if ! xcode-select -p >/dev/null 2>&1 || ! /usr/bin/git --version >/dev/null 2>&1; then
    install_clt
  fi
  # A clone that failed half-way (no .git) is OmacVM's own leftover: start over.
  [[ -d $here && ! -d $here/.git ]] && rm -rf "$here"
  if [[ -d $here/.git && -n ${OMACVM_REF:-} ]]; then
    [[ -z $(git -C "$here" status --porcelain --untracked-files=no) ]] ||
      { echo "$here has local changes: not switching it to $OMACVM_REF" >&2; exit 1; }
    say "updating $here to $OMACVM_REF"
    if git -C "$here" ls-remote --exit-code origin "refs/heads/$OMACVM_REF" >/dev/null; then
      git -C "$here" fetch -q origin "+refs/heads/$OMACVM_REF:refs/remotes/origin/$OMACVM_REF"
      git -C "$here" checkout -q -B "$OMACVM_REF" --track "origin/$OMACVM_REF"
    else
      git -C "$here" fetch -q origin "+refs/tags/$OMACVM_REF:refs/tags/$OMACVM_REF"
      git -C "$here" checkout -q --detach "refs/tags/$OMACVM_REF"
    fi
  elif [[ -d $here/.git ]]; then say "updating $here"; git -C "$here" pull -q --ff-only
  else say "OmacVM -> $here"; git clone -q ${OMACVM_REF:+--branch "$OMACVM_REF"} "$REPO" "$here"; fi
fi

# On the PATH, so "omacvm" works right away in this terminal too: Homebrew's
# bin when there is one, else /usr/local/bin (on macOS's default PATH; created
# with the Mac password if needed), else ~/.local/bin via ~/.zprofile.
bin=""
if command -v brew >/dev/null && [[ -w $(brew --prefix)/bin ]]; then bin=$(brew --prefix)/bin
elif [[ -d /usr/local/bin && -w /usr/local/bin ]]; then bin=/usr/local/bin
elif [[ ":$PATH:" == *":/usr/local/bin:"* ]] && { : < /dev/tty; } 2>/dev/null; then
  echo "    putting omacvm into /usr/local/bin (your Mac password, if macOS asks):"
  if sudo mkdir -p /usr/local/bin < /dev/tty && sudo ln -sf "$here/omacvm" /usr/local/bin/omacvm < /dev/tty; then
    bin=/usr/local/bin
  fi
fi
if [[ -z $bin ]]; then bin=$HOME/.local/bin; mkdir -p "$bin"; fi
[[ $bin == /usr/local/bin && ! -w $bin ]] || ln -sf "$here/omacvm" "$bin/omacvm"
say "omacvm $(cat "$here/src/VERSION") -> $bin/omacvm"
# An OmacVM.app with a newer OmacVM on this Mac (a branch or tag above, or a
# clone that is behind): its omacvm and this one would differ without a word.
if [[ -f $here/src/lib/version.sh ]] && newer=$(source "$here/src/lib/app.sh" && omacvm_app_newer "$(cat "$here/src/VERSION")"); then
  echo "    OmacVM.app ${newer#*$'\t'} on this Mac is newer than this omacvm: it does not change a VM that has a newer OmacVM."
  echo "    The app's own: ${newer%%$'\t'*}/Contents/Resources/omacvm/omacvm"
fi
case ":$PATH:" in
  *":$bin:"*) ;;
  *) # ~/.local/bin on the PATH of new terminals, and of this run.
     line='export PATH="$HOME/.local/bin:$PATH"'
     grep -qsF "$line" "$HOME/.zprofile" || printf '\n%s\n' "$line" >> "$HOME/.zprofile"
     export PATH="$bin:$PATH"
     echo "    $bin is on your PATH from now on (a line in ~/.zprofile)."
     echo "    In this terminal window, first run:  source ~/.zprofile   (or open a new window)" ;;
esac

if (( START )); then
  # Piped from curl, stdin is the script: the questions read the terminal.
  if { : < /dev/tty; } 2>/dev/null; then exec "$here/omacvm" < /dev/tty
  else echo "    run: omacvm"; fi
fi
