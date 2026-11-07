#!/bin/bash
# Google Chrome for Linux ARM in an Omarchy VM, for the browser benchmarks
# (Arch's Chromium is slower than Chrome, so it would not compare with the Mac).
# Arch Linux ARM has no Chrome package: this unpacks Google's own .deb to
# /opt/google/chrome, with a google-chrome-stable launcher that reads
# chrome-flags.conf. Run as root in the VM. Again to update.
set -euo pipefail
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
curl -fsSL -o "$d/chrome.deb" https://dl.google.com/linux/direct/google-chrome-stable_current_arm64.deb
cd "$d"
bsdtar -xf chrome.deb
rm -rf /opt/google/chrome
tar -xf data.tar.* -C / ./opt/google/chrome
# Google's launcher reads no flags file. This one reads /etc/chrome-flags.conf,
# then ~/.config/chrome-flags.conf, as Arch's chromium does (on another VM app,
# /etc/chrome-flags.conf has --ignore-gpu-blocklist). Unlike Arch's launcher it
# splits on whitespace only (no quotes) and skips only whole-line comments.
rm -f /usr/local/bin/google-chrome-stable
install -m755 /dev/stdin /usr/local/bin/google-chrome-stable <<'SH'
#!/bin/bash
flags=()
for f in /etc/chrome-flags.conf "${XDG_CONFIG_HOME:-$HOME/.config}/chrome-flags.conf"; do
  [[ -f $f ]] || continue
  while IFS= read -r l || [[ -n $l ]]; do
    [[ $l =~ ^[[:space:]]*(#|$) ]] && continue
    read -ra w <<< "$l"; flags+=("${w[@]}")
  done < "$f"
done
exec /opt/google/chrome/google-chrome "${flags[@]}" "$@"
SH
missing=$(ldd /opt/google/chrome/chrome | awk '/not found/ { print $1 }')
[[ -z $missing ]] || { echo "install-chrome: missing libraries: $missing" >&2; exit 1; }
/usr/local/bin/google-chrome-stable --version
