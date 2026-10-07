# Kernel modules through DKMS, for the guest installers (battery, camera,
# Chromium video). Sourced; the caller defines say(). From try-omarchy's
# battery installer (MIT), kept here once.
#   dkms_tools [PACKAGE...]      dkms, make, gcc (and PACKAGEs) from pacman;
#                                status 1 and a line when one is missing
#   kernel_headers KERNEL_PKG    the headers of that kernel's own version
#   dkms_source NAME VER STAMP FILE...
#                                FILEs are the module's source for DKMS, again
#                                when they changed: CHANGED=1 then, else 0
#   dkms_build NAME VER LOG      built for every kernel that has its headers
#   dkms_remove NAME             every version DKMS has, and the sources

dkms_tools() {
  local t
  "$(dirname "${BASH_SOURCE[0]}")/pkg-add" dkms make gcc "$@" || true
  for t in dkms make gcc; do
    command -v "$t" >/dev/null && continue
    say "not installed: pacman could not install $t (no network, or omarchy update first), then omacvm apply"
    return 1
  done
}

# Arch Linux ARM's headers must be the kernel's own version: from the
# repository when it has that version, else from pacman's cache. The
# memory-optimized kernel (linux-aarch64-thp) brings its own
# (kernel/build-thp-kernel.sh).
kernel_headers() {
  local k=$1 have want f
  have=$(pacman -Q "$k" 2>/dev/null | awk '{ print $2 }') || return 0
  [[ -n $have ]] || return 0
  [[ $(pacman -Q "$k-headers" 2>/dev/null | awk '{ print $2 }') == "$have" ]] && return 0
  want=$(pacman -Si "$k-headers" 2>/dev/null | awk '/^Version/ { print $3; exit }') || true
  if [[ $want == "$have" ]]; then
    pacman -S --needed --noconfirm "$k-headers" >/dev/null 2>&1 && return 0
  fi
  f=$(ls /var/cache/pacman/pkg/"$k-headers-$have"-*.pkg.tar.* 2>/dev/null | grep -v '\.sig$' | head -1) || true
  [[ -n $f ]] && pacman -U --noconfirm "$f" >/dev/null 2>&1 && return 0
  say "no $k-headers $have to build with (Arch Linux ARM has ${want:-none}): omarchy update, reboot, then omacvm apply"
}

dkms_remove() {
  local v
  for v in $(dkms status "$1" 2>/dev/null | sed -n "s#^$1/\([^,:]*\).*#\1#p" | sort -u); do
    dkms remove "$1/$v" --all >/dev/null 2>&1 || true
  done
  rm -rf "/usr/src/$1-"*
}

dkms_source() {
  local name=$1 ver=$2 stamp=$3 sum
  shift 3
  sum=$(cat "$@" | sha256sum | cut -c1-16)
  CHANGED=0
  if [[ $(cat "$stamp" 2>/dev/null) != "$sum" || ! -f /usr/src/$name-$ver/dkms.conf ]]; then
    CHANGED=1
    dkms_remove "$name"
    install -d "/usr/src/$name-$ver"
    install -m644 "$@" "/usr/src/$name-$ver/"
    dkms add "$name/$ver" >/dev/null
    install -Dm644 /dev/stdin "$stamp" <<<"$sum"
  fi
}

dkms_build() {
  local name=$1 ver=$2 log=$3 b k
  : > "$log"
  for b in /usr/lib/modules/*/build; do
    [[ -f $b/Makefile ]] || continue
    k=$(basename "$(dirname "$b")")
    dkms status -k "$k" "$name/$ver" 2>/dev/null | grep -q installed && continue
    if dkms install "$name/$ver" -k "$k" >> "$log" 2>&1; then say "module built for $k"
    else say "the module did not build for $k (log: $log)"; fi
  done
}
