# Prebuilt VMs: shared values and helpers (sourced, Mac side, bash 3.2).

PREBUILT_REPO=gillesgoetsch/omacvm
PREBUILT_USER=omacvmuser            # the placeholder user an image is built with
PREBUILT_FULLNAME="OmacVM User"
PREBUILT_NAME=Omarchy               # the VM's name inside the archive
PREBUILT_DISK_GB=64                 # the image's disk; grown on install
# Features of the image build; omacvm build --prebuilt then applies the chosen ones.
PREBUILT_FEATURES="bridge=on wallpaper=on gestures=on scroll-momentum=off omanotch=off mac-clock=on camera=on battery=off idle-lock=on autologin=off thp-kernel=off"
UTM_DOCS=$HOME/Library/Containers/com.utmapp.UTM/Data/Documents

PREBUILT_CACHE=$HOME/Library/Caches/omacvm/prebuilt

# prebuilt_lookup TYPE: the newest image for this app with OmacVM's major
# version and a version up to this one (the first omacvm apply brings its
# guest side to this version). Sets PB_TAG, PB_MANIFEST (local file), PB_SIZE
# (bytes), PB_OMARCHY, PB_VERSION, PB_SOURCE (base URL or folder).
# $OMACVM_PREBUILT_SOURCE: a folder with the files (tests);
# $OMACVM_PREBUILT_TAG: only that release.
prebuilt_lookup() {
  local type=$1 version rel url name iv
  version=$(cat "$R/src/VERSION")
  mkdir -p "$PREBUILT_CACHE/$type"
  PB_VERSION=""
  if [[ -n ${OMACVM_PREBUILT_SOURCE:-} ]]; then
    read -r name iv < <(python3 "$R/src/prebuilt/manifest.py" local "$OMACVM_PREBUILT_SOURCE" "$version" "$type") || return 1
    [[ -n ${name:-} ]] || return 1
    PB_MANIFEST=$PREBUILT_CACHE/$type/$name
    cp "$OMACVM_PREBUILT_SOURCE/$name" "$PB_MANIFEST"
    PB_TAG=local; PB_SOURCE=$OMACVM_PREBUILT_SOURCE
  else
    rel=$(mktemp)
    curl -fsSL --max-time 20 -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/$PREBUILT_REPO/releases?per_page=100" -o "$rel" 2>/dev/null || { rm -f "$rel"; return 1; }
    if [[ -n ${OMACVM_PREBUILT_TAG:-} ]]; then
      python3 - "$rel" "$OMACVM_PREBUILT_TAG" > "$rel.one" <<'PY2'
import json, sys
print(json.dumps([r for r in json.load(open(sys.argv[1])) if r.get("tag_name") == sys.argv[2]]))
PY2
      mv "$rel.one" "$rel"
    fi
    read -r PB_TAG url iv < <(python3 "$R/src/prebuilt/manifest.py" release "$rel" "$version" "$type") || true
    rm -f "$rel"
    [[ -n ${url:-} ]] || return 1
    PB_MANIFEST=$PREBUILT_CACHE/$type/${url##*/}
    curl -fsSL --max-time 30 "$url" -o "$PB_MANIFEST" || return 1
    PB_SOURCE=${url%/*}
  fi
  [[ $(python3 "$R/src/prebuilt/manifest.py" get "$PB_MANIFEST" route) == "$type" ]] || return 1
  PB_VERSION=$(python3 "$R/src/prebuilt/manifest.py" get "$PB_MANIFEST" omacvm)
  PB_OMARCHY=$(python3 "$R/src/prebuilt/manifest.py" get "$PB_MANIFEST" omarchy)
  PB_SIZE=$(python3 "$R/src/prebuilt/manifest.py" get "$PB_MANIFEST" size)
  PB_BUNDLE=$(python3 "$R/src/prebuilt/manifest.py" get "$PB_MANIFEST" bundle)
  PB_DISK_GB=$(python3 "$R/src/prebuilt/manifest.py" get "$PB_MANIFEST" disk_gb)
  [[ $PB_VERSION == "${iv:-$PB_VERSION}" ]]
}

pb_gb() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1e9 }'; }

# prebuilt_download: every part into the cache, resumed, checked against the
# manifest's SHA-256. A part that fails its check is fetched again once.
prebuilt_download() {
  local dir name size sum try have
  dir=$(dirname "$PB_MANIFEST")
  while read -r name size sum; do
    for try in 1 2; do
      if [[ -n ${OMACVM_PREBUILT_SOURCE:-} ]]; then
        [[ -f $dir/$name && $(stat -f %z "$dir/$name") == "$size" ]] || cp -c "$PB_SOURCE/$name" "$dir/$name" 2>/dev/null || cp "$PB_SOURCE/$name" "$dir/$name"
      else
        have=$(stat -f %z "$dir/$name" 2>/dev/null || echo 0)
        (( have > size )) && { rm -f "$dir/$name"; have=0; }
        if (( have < size )); then
          curl -fL --retry 5 --retry-delay 3 -C - --progress-bar "$PB_SOURCE/$name" -o "$dir/$name" ||
            curl -fL --retry 5 --retry-delay 3 --progress-bar "$PB_SOURCE/$name" -o "$dir/$name" || true
        fi
      fi
      [[ $(shasum -a 256 "$dir/$name" 2>/dev/null | cut -d' ' -f1) == "$sum" ]] && break
      (( try == 1 )) || die "$name: checksum mismatch (download it again: rm '$dir/$name')"
      info "$name: checksum mismatch, downloading it again"
      rm -f "$dir/$name"
    done
    info "$name: checked ($(pb_gb "$size") GB)"
  done < <(python3 "$R/src/prebuilt/manifest.py" parts "$PB_MANIFEST")
}

# prebuilt_unpack DIR: the bundle into DIR (sparse files stay sparse).
prebuilt_unpack() {
  local dir; dir=$(dirname "$PB_MANIFEST")
  mkdir -p "$1"
  python3 "$R/src/prebuilt/manifest.py" parts "$PB_MANIFEST" | while read -r name _ _; do cat "$dir/$name"; done |
    zstd -dc --long=27 -q | tar -xSf - -C "$1"
  [[ -d $1/$PB_BUNDLE ]] || die "the image did not unpack ($1/$PB_BUNDLE missing)"
}

prebuilt_cleanup() {   # the downloaded parts (kept with OMACVM_PREBUILT_KEEP=1)
  [[ ${OMACVM_PREBUILT_KEEP:-0} == 1 ]] && return 0
  local dir; dir=$(dirname "$PB_MANIFEST")
  python3 "$R/src/prebuilt/manifest.py" parts "$PB_MANIFEST" | while read -r name _ _; do rm -f "$dir/$name"; done
}

# prebuilt_seed ISO: the answers for the VM's first boot, on a small ISO
# labelled OMACVM-SEED. Needs U FULL HASH HOST KB TZ_MAC LANG_VM TYPE (and
# SEED_DISPLAY, SEED_NET); the root key is ~/.ssh/omacvm.pub.
prebuilt_seed() {
  local d; d=$(mktemp -d)
  b() { printf '%s' "$1" | base64 | tr -d '\n'; }
  {
    echo "VERSION=$(b 1)"
    echo "USER=$(b "$U")"; echo "FULLNAME=$(b "$FULL")"; echo "HASH=$(b "$HASH")"
    echo "ROOT_KEY=$(b "$(cat "$KEY.pub")")"
    echo "HOSTNAME=$(b "$HOST")"; echo "KEYBOARD=$(b "$KB")"; echo "TIMEZONE=$(b "$TZ_MAC")"
    echo "LANG=$(b "$LANG_VM")"; echo "TYPE=$(b "$TYPE")"
    if [[ -n ${SEED_DISPLAY:-} ]]; then echo "DISPLAY=$(b "$SEED_DISPLAY")"; fi
    if [[ -n ${SEED_NET:-} ]]; then echo "NET=$(b "$SEED_NET")"; fi
  } > "$d/seed.env"
  rm -f "$1"
  hdiutil makehybrid -quiet -iso -joliet -default-volume-name OMACVM-SEED -o "$1" "$d" || die "could not make the seed image"
  chmod 600 "$1"
  rm -rf "$d"
}
