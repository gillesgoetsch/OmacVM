# Prebuilt VMs: shared values and helpers (sourced, Mac side, bash 3.2).

PREBUILT_REPO=gillesgoetsch/omacvm
PREBUILT_USER=omacvmuser            # the placeholder user an image is built with
PREBUILT_FULLNAME="OmacVM User"
PREBUILT_NAME=Omarchy               # the VM's name inside the archive
PREBUILT_DISK_GB=64                 # the image's disk; grown on install
# Features of the image build; omacvm build --prebuilt then applies the chosen ones.
PREBUILT_FEATURES="bridge=on wallpaper=on gestures=on scroll-momentum=off omanotch=off mac-clock=on camera=on battery=off external-brightness=on no-idle-lock=off autologin=off thp-kernel=off"
UTM_DOCS=$HOME/Library/Containers/com.utmapp.UTM/Data/Documents

PREBUILT_CACHE=$HOME/Library/Caches/omacvm/prebuilt

# prebuilt_lookup TYPE: the newest image for this app with OmacVM's major
# version and a version up to this one (the first omacvm apply brings its
# guest side to this version). Sets PB_TAG, PB_MANIFEST (local file), PB_SIZE
# (bytes), PB_UNPACKED_KB, PB_OMARCHY, PB_VERSION, PB_SOURCE (base URL or folder).
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
    cp "$OMACVM_PREBUILT_SOURCE/$name.sig" "$PB_MANIFEST.sig" 2>/dev/null || rm -f "$PB_MANIFEST.sig"
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
    # Its signature (one of OmacVM's release keys): manifest.py checks it
    # before it gives out any value.
    curl -fsSL --max-time 30 "$url.sig" -o "$PB_MANIFEST.sig" || { rm -f "$PB_MANIFEST.sig"; return 1; }
    PB_SOURCE=${url%/*}
  fi
  # manifest.py get checks the signature, then the whole manifest, and fails
  # on anything odd. Each
  # step needs its own "|| return 1": callers use "prebuilt_lookup && ...",
  # where set -e is off.
  local route
  route=$(python3 "$R/src/prebuilt/manifest.py" get "$PB_MANIFEST" route) || return 1
  [[ $route == "$type" ]] || return 1
  PB_VERSION=$(python3 "$R/src/prebuilt/manifest.py" get "$PB_MANIFEST" omacvm) || return 1
  PB_OMARCHY=$(python3 "$R/src/prebuilt/manifest.py" get "$PB_MANIFEST" omarchy) || return 1
  PB_SIZE=$(python3 "$R/src/prebuilt/manifest.py" get "$PB_MANIFEST" size) || return 1
  PB_BUNDLE=$(python3 "$R/src/prebuilt/manifest.py" get "$PB_MANIFEST" bundle) || return 1
  PB_DISK_GB=$(python3 "$R/src/prebuilt/manifest.py" get "$PB_MANIFEST" disk_gb) || return 1
  PB_UNPACKED_KB=$(python3 "$R/src/prebuilt/manifest.py" get "$PB_MANIFEST" unpacked_kb) || return 1
  # And again here, so no manifest text can reach bash arithmetic or a path.
  [[ $PB_SIZE =~ ^[0-9]{1,15}$ && $PB_DISK_GB =~ ^[0-9]{1,4}$ && $PB_UNPACKED_KB =~ ^[0-9]{1,12}$ ]] || return 1
  [[ $PB_BUNDLE =~ ^[A-Za-z0-9._-]{1,64}$ && $PB_BUNDLE != . && $PB_BUNDLE != .. ]] || return 1
  [[ $PB_VERSION =~ ^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$ ]] || return 1
  [[ $PB_VERSION == "${iv:-$PB_VERSION}" ]]
}

# pb_disk_bigger GB: is GB more than the image's disk? PB_DISK_GB is checked
# to be digits only before it goes near bash arithmetic (a value like
# "a[$(cmd)]" there would run cmd).
pb_disk_bigger() {
  [[ $1 =~ ^[0-9]{1,6}$ && $PB_DISK_GB =~ ^[0-9]{1,4}$ ]] || die "bad disk size in the prebuilt manifest"
  (( 10#$1 > 10#$PB_DISK_GB ))
}

pb_gb() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1e9 }'; }

# prebuilt_space_ok DEST: room for the parts (in the cache) and the unpacked
# VM (in DEST), plus 2 GB. Says how much is missing and returns 1 if not.
prebuilt_space_ok() {
  local dest=$1 cache_kb dest_kb need_cache need_dest
  mkdir -p "$PREBUILT_CACHE"
  need_cache=$(( 10#$PB_SIZE / 1024 + 1 )); need_dest=$(( 10#$PB_UNPACKED_KB ))
  cache_kb=$(df -Pk "$PREBUILT_CACHE" | awk 'NR == 2 { print $4 }')
  dest_kb=$(df -Pk "$dest" | awk 'NR == 2 { print $4 }')
  [[ $cache_kb =~ ^[0-9]+$ && $dest_kb =~ ^[0-9]+$ ]] || return 0   # df said nothing useful: let it try
  if [[ $(stat -f %d "$PREBUILT_CACHE") == "$(stat -f %d "$dest")" ]]; then
    need_dest=$(( need_dest + need_cache )); need_cache=0
  fi
  if (( dest_kb < need_dest + 2097152 )); then
    echo "not enough free space on $(df -P "$dest" | awk 'NR == 2 { sub(/^([^ ]+ +){5}/, ""); print }'): $(pb_gb $(( (need_dest + 2097152) * 1024 ))) GB needed, $(pb_gb $(( dest_kb * 1024 ))) GB free" >&2
    return 1
  fi
  if (( need_cache && cache_kb < need_cache + 2097152 )); then
    echo "not enough free space for the download in $PREBUILT_CACHE: $(pb_gb $(( (need_cache + 2097152) * 1024 ))) GB needed, $(pb_gb $(( cache_kb * 1024 ))) GB free" >&2
    return 1
  fi
}

# prebuilt_download: every part into the cache, resumed, checked against the
# manifest's SHA-256. A part that fails its check is fetched again once.
prebuilt_download() {
  local dir name size sum try have
  dir=$(dirname "$PB_MANIFEST")
  while read -r name size sum; do
    [[ $size =~ ^[0-9]{1,15}$ ]] || die "bad part size in the prebuilt manifest"
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

# prebuilt_unpack DIR [MEMBER...]: the bundle into DIR (sparse files stay
# sparse); with MEMBERs only those paths. $ZSTD: OmacVM.app's own zstd (its
# users need no Homebrew).
prebuilt_unpack() {
  local dir to=$1; dir=$(dirname "$PB_MANIFEST"); shift
  mkdir -p "$to"
  python3 "$R/src/prebuilt/manifest.py" parts "$PB_MANIFEST" | while read -r name _ _; do cat "$dir/$name"; done |
    "${ZSTD:-zstd}" -dc --long=27 -q | tar -xSf - -C "$to" "$@" ||
    die "could not unpack the image (free disk space?)"
  [[ -d $to/$PB_BUNDLE ]] || die "the image did not unpack ($to/$PB_BUNDLE missing)"
}

# prebuilt_unpack_bundle WORK TYPE: the image's bundle into WORK (emptied
# first). Only <bundle>/ comes out of the archive, and bundlecheck.py then
# wants exactly the files that route's images hold, as plain files, and
# settings and disks that name nothing outside the bundle: a link or a path
# would have Parallels, UTM or Fusion use some other file on the Mac. Anything
# else: WORK goes and the image is not used.
prebuilt_unpack_bundle() {
  local u=$1 type=$2 msg
  [[ $PB_BUNDLE == "$PREBUILT_NAME$(case $type in (parallels) echo .pvm ;; (utm) echo .utm ;; (*) echo .vmwarevm ;; esac)" ]] ||
    die "the image's bundle is not $PREBUILT_NAME for $type: not used"
  rm -rf "$u"
  ( prebuilt_unpack "$u" "$PB_BUNDLE" ) || { rm -rf "$u"; exit 1; }   # it said why
  msg=$(python3 "$R/src/prebuilt/bundlecheck.py" "$type" "$u" "$PREBUILT_NAME" 2>&1) ||
    { rm -rf "$u"; die "the image is not used: $(printf '%s' "${msg:-the check failed}" | printable | head -c 300)"; }
}

# Text from the VM on its way to a terminal: colour codes out, then only
# printable ASCII and tabs (no other escape sequences: a guest could set the
# window title or the Mac's clipboard), lines cut at 240 characters. Line by
# line, so progress still shows as it comes. (OmacVM.app's scripts have the
# same in vm-common.sh.)
printable() {
  LC_ALL=C sed -l -e $'s/\x1b\\[[0-9;]*m//g' -e 's/[^[:print:][:blank:]]//g' -e 's/^\(.\{240\}\).*/\1/'
}

# prebuilt_unpack_disk WORK DEST: OmacVM.app's image is <bundle>/disk.img and
# nothing else. Only that path comes out of the archive (into WORK, emptied
# first), and only as a plain file with one link: a symbolic or hard link would
# have the grow and QEMU write to some other file on the Mac. Then it moves to
# DEST and WORK goes.
prebuilt_unpack_disk() {
  local u=$1 f
  rm -rf "$u"
  prebuilt_unpack "$u" "$PB_BUNDLE/disk.img"
  f=$u/$PB_BUNDLE/disk.img
  [[ $(cd "$u" && find . -mindepth 1 | LC_ALL=C sort | tr '\n' '|') == "./$PB_BUNDLE|./$PB_BUNDLE/disk.img|" ]] ||
    { rm -rf "$u"; die "the image holds something other than $PB_BUNDLE/disk.img: not used"; }
  [[ -d $u/$PB_BUNDLE && ! -L $u/$PB_BUNDLE && -f $f && ! -L $f && $(stat -f %l "$f") == 1 ]] ||
    { rm -rf "$u"; die "the image's disk.img is not a plain file: not used"; }
  mv "$f" "$2"
  rm -rf "$u"
}

prebuilt_cleanup() {   # the downloaded parts (kept with OMACVM_PREBUILT_KEEP=1)
  [[ ${OMACVM_PREBUILT_KEEP:-0} == 1 ]] && return 0
  local dir; dir=$(dirname "$PB_MANIFEST")
  python3 "$R/src/prebuilt/manifest.py" parts "$PB_MANIFEST" | while read -r name _ _; do rm -f "$dir/$name"; done
}

# prebuilt_seed ISO: the answers for the VM's first boot, on a small ISO
# labelled OMACVM-SEED. Needs U FULL HASH HOST KB TZ_MAC LANG_VM TYPE (and
# SEED_DISPLAY, SEED_NET); the root key is $KEY.pub. The answers hold the
# password hash: only the user can read them, from the first byte (umask), and
# the work folder goes however this ends (a subshell with its own trap).
prebuilt_seed() (
  umask 077
  d=$(mktemp -d) || die "could not make a folder for the seed"
  trap 'rm -rf "$d"' EXIT
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
  hdiutil makehybrid -quiet -iso -joliet -default-volume-name OMACVM-SEED -o "$1" "$d" ||
    { rm -f "$1"; die "could not make the seed image"; }
  chmod 600 "$1"
)
