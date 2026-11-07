#!/bin/bash
# OmacVM's icon (icon/omacvm.svg: the ⌘ key's loops around Omarchy's mark) as
# an .icns or a PNG, with macOS's own tools:
#   icon/make-icns.sh <out.icns>        (app bundles)
#   icon/make-icns.sh <out.png> [size]  (default 512)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?usage: make-icns.sh <out.icns|out.png> [size]}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
swift "$here/render.swift" "$here/omacvm.svg" "$T/1024.png" 1024
if [[ $OUT == *.png ]]; then
  sips -z "${2:-512}" "${2:-512}" "$T/1024.png" --out "$OUT" >/dev/null
  exit 0
fi
mkdir "$T/i.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$T/1024.png" --out "$T/i.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$T/1024.png" --out "$T/i.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$T/i.iconset" -o "$OUT"
