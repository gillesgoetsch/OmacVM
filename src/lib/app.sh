# OmacVM.app's VMs, from the Mac (sourced by vm.sh; bash 3.2). The app keeps
# each VM in a folder with vm.env (NAME, SSH_PORT, ...) and disk.img; QEMU
# forwards the VM's SSH to 127.0.0.1:SSH_PORT, so its "IP" here is
# 127.0.0.1:PORT (gssh understands that).
#   app_list            NAME<TAB>app<TAB>running|stopped, one line per VM
#   app_vms_root        where new VMs go (~/OmacVM by default)
#   app_vms_roots       every folder with VMs (older ones until their VMs move)
#   app_missing_drive DIR  the drive DIR needs, when it is not connected
#   app_dir NAME        the VM's folder
#   app_features_write DIR FEATURES  the VM's features, for the app's Mac links
#   app_links_stale DIR FEATURES on|off  links that differ from this start of the VM
#   app_ip NAME         127.0.0.1:PORT while it runs (fast network: its vmnet address)
#   app_any_fast_network  one of the VMs has the fast network on
#   app_start NAME      start it in the app (its window opens)
#   app_other_running NAME  another app VM that runs, if any
#   app_bundle          the installed OmacVM.app (any name it was installed under;
#                       the app whose bundled omacvm runs first, then
#                       ~/Applications, then /Applications)
#   app_create [--prebuilt] DIR KEY=VALUE...  a new VM in DIR through the app's
#                       own create script (the password on stdin), as when built
#                       in the app; --prebuilt: from a prebuilt image
#   app_has_prebuilt APP    that app can make a VM from a prebuilt image
#   app_prebuilt_lookup APP the image that app would use (its own version):
#                       sets PB_TAG PB_SIZE PB_OMARCHY PB_VERSION
#   app_published VERSION   that OmacVM release has OmacVM-VERSION.zip
#   app_install VERSION [APP]  download, check and install it (in ~/Applications,
#                       or in place of APP, /Applications too); prints the path
#   app_install_cmd VERSION    the same as one command, for a person to run
# omacvm apply writes guest-pointer ("omarchy") into the folder once the VM
# draws Omarchy's own pointer: the app hides the Mac's pointer only then.

# Where OmacVM.app is published: OmacVM-VERSION.zip (and .sha256) in each
# OmacVM release, the app's version the same as OmacVM's.
APP_DOWNLOADS=https://github.com/gillesgoetsch/omacvm/releases/download

# The app's settings (OMACVM_APP_ID: another bundle id, for tests only).
# The test identity (OMACVM_TEST_IDENTITY=1) is "OmacVM Test" (org.omacvm.app.test).
if [[ ${OMACVM_TEST_IDENTITY:-} == 1 ]]; then APP_ID=${OMACVM_APP_ID:-org.omacvm.app.test}
else APP_ID=${OMACVM_APP_ID:-org.omacvm.app}; fi
# The app app_bundle looks for: the test identity never finds (and updates or
# uses) the installed OmacVM.app or a copy with its id.
APP_BUNDLE_ID=org.omacvm.app
[[ ${OMACVM_TEST_IDENTITY:-} == 1 ]] && APP_BUNDLE_ID=org.omacvm.app.test

# Where new VMs go, as the app decides (app/app/Sources/OmacVM/VMsFolder.swift;
# src/tests/app-paths.sh checks that both agree): the folder set in the app,
# else ~/OmacVM (the app makes it on first use), unless that name is taken by
# something else: then the old place, ~/Library/Application Support/OmacVM/VMs.
APP_VMS_OLD="Library/Application Support/OmacVM/VMs"
app_vms_root() {
  local r new=$HOME/OmacVM
  r=$(defaults read "$APP_ID" vmsRoot 2>/dev/null)
  [[ -n $r ]] && { echo "${r%/}"; return; }
  app_vms_ours "$new" && { echo "$new"; return; }
  # Taken by something else (a file, ~/omacvm on a case-insensitive drive).
  [[ -e $new ]] && { echo "$HOME/$APP_VMS_OLD"; return; }
  echo "$new"
}

# Every folder with VMs, one per line: the one above first, then folders the
# app still uses for VMs that did not move (its otherVMsRoots), then the old
# place, whose VMs keep working there until they are moved.
app_vms_roots() {
  local r p i seen
  r=$(app_vms_root); echo "$r"; seen=("$r")
  p=$(defaults export "$APP_ID" - 2>/dev/null)
  for ((i = 0; i < 64; i++)); do
    r=$(plutil -extract "otherVMsRoots.$i" raw -o - - <<<"$p" 2>/dev/null) || break
    r=${r%/}
    [[ -n $r ]] && ! app_same_dir "$r" "${seen[@]}" && { echo "$r"; seen+=("$r"); }
  done
  # The old place holds the installed app's VMs from 2.9 and older: not the test identity's.
  [[ ${OMACVM_TEST_IDENTITY:-} == 1 ]] && return
  app_same_dir "$HOME/$APP_VMS_OLD" "${seen[@]}" || echo "$HOME/$APP_VMS_OLD"
}

# app_same_dir DIR DIR...: DIR is one of the others, by name or as the same
# folder on disk (another case of the name: the old place is often
# ~/Library/Application Support/omacvm/VMs on disk; macOS drives ignore case).
app_same_dir() {
  local d=$1 s; shift
  for s in "$@"; do [[ $d == "$s" || ( -e $d && $d -ef $s ) ]] && return 0; done
  return 1
}

app_vm_dirs() {   # every app VM folder (with vm.env), one per line
  local r d
  while IFS= read -r r; do
    # ls, not a glob: on macOS 26 a glob in a forked bash (this runs in a
    # process substitution) can see a folder on an external drive as empty
    # until a program it starts has read it (the removable-volume check).
    # macOS's own ls, without the colours a terminal may force (CLICOLOR_FORCE).
    while IFS= read -r d; do
      [[ -f $r/$d/vm.env ]] && echo "$r/$d"
    done < <(env -u CLICOLOR -u CLICOLOR_FORCE /bin/ls -1 "$r" 2>/dev/null)
  done < <(app_vms_roots)
}

app_missing_drive() {   # DIR -> the drive it needs when that is not connected
  # (a stale empty /Volumes/NAME folder counts as not connected)
  local v
  [[ $1 == /Volumes/?* ]] || return 1
  v=${1#/Volumes/}; v=${v%%/*}
  [[ -d /Volumes/$v && $(stat -f %d "/Volumes/$v") != "$(stat -f %d /Volumes)" ]] && return 1
  echo "$v"
}
app_vms_ours() {   # DIR: a folder under exactly that name, no git clone
  [[ -d $1 && ! -e $1/.git ]] && ls -1 "$(dirname "$1")" 2>/dev/null | grep -xF -- "$(basename "$1")" >/dev/null   # no -q: pipefail
}

app_env() {   # DIR KEY: one value from vm.env (single quotes stripped)
  sed -n "s/^$2=//p" "$1/vm.env" 2>/dev/null | tail -1 | sed "s/^'\(.*\)'\$/\1/"
}

app_pid_dir() {   # DIR -> the PID of its QEMU (the disk is on its command line, commas
  # doubled); this user's processes only: another account could fake the line.
  # The app writes the folder as it is on disk, which can differ in case from
  # DIR (~/Library/Application Support/omacvm/VMs): any case matches, then the
  # disk on the line must be DIR's disk itself. The pattern goes to awk in its
  # environment, not its arguments: awk's own line in ps would match.
  local pid f
  while IFS=$'\t' read -r pid f; do
    f=${f//,,/,}
    [[ $f == "$1/disk.img" || ( -e $f && $f -ef $1/disk.img ) ]] && { echo "$pid"; break; }
  done < <(ps -x -U "$(id -u)" -o pid=,args= 2>/dev/null | OMA_PAT="file=${1//,/,,}/disk.img," awk '
    { i = index(tolower($0), tolower(ENVIRON["OMA_PAT"]))
      if (i) print $1 "\t" substr($0, i + 5, length(ENVIRON["OMA_PAT"]) - 6) }')
  return 0
}

app_running_dir() { [[ -n $(app_pid_dir "$1") ]]; }

app_list() {
  local d n
  while IFS= read -r d; do
    [[ -f $d/disk.img ]] || continue
    n=$(app_env "$d" NAME); [[ -n $n ]] || n=$(basename "$d")
    printf '%s\tapp\t%s\n' "$n" "$(app_running_dir "$d" && echo running || echo stopped)"
  done < <(app_vm_dirs)
}

# app_features_write DIR "bridge=on gestures=off ...": the VM's features, its
# record (src/lib/features.sh), which the app reads at each start of the VM
# (MacLinks.swift: a feature that is off gets nothing of the Mac). vm.env's
# FEATURES (the setup's choice, for the first apply) goes once the record is
# there: a second list would only go stale. Status 0 if they changed.
app_features_write() {
  local same=0
  if [[ $(cat "$1/features" 2>/dev/null) == "$2" ]]; then same=1
  else printf '%s\n' "$2" > "$1/features.tmp" && mv -f "$1/features.tmp" "$1/features" || return 1; fi
  if [[ -f $1/vm.env ]] && grep -q '^FEATURES=' "$1/vm.env"; then
    grep -v '^FEATURES=' "$1/vm.env" > "$1/vm.env.tmp" && mv -f "$1/vm.env.tmp" "$1/vm.env"
  fi
  return $same
}

# app_links_stale DIR "bridge=on gestures=off ..." on|off: the Mac links the
# app took at this start of the VM (its "Mac links" line in qemu.log) against
# the features. "on": the features that are on but closed to the VM until its
# next start; "off": the ones that are off but still served. As "Bridge,
# camera"; nothing for an app from before the line. A feature not named is on.
app_links_stale() {
  local l x k n v out=""
  l=$(sed -n 's/^OmacVM: Mac links: //p' "$1/logs/qemu.log" 2>/dev/null | tail -1)
  [[ -n $l ]] || return 0
  for x in omanotch:Omanotch gestures:Gestures bridge:Bridge battery:battery camera:camera touch-id:Touch\ ID; do
    k=${x%%:*} n=${x#*:} v=on
    [[ " $2 " == *" $k=off "* ]] && v=off
    # Touch ID is off unless named on (its port is there only then); an app
    # whose line does not name it never serves it.
    if [[ $k == touch-id ]]; then
      [[ " $2 " == *" $k=on "* ]] || v=off
      [[ ", $l, " == *", Touch ID "* ]] || l+=", Touch ID off"
    fi
    [[ $v == "$3" && ", $l, " != *", $n $3, "* ]] && out+="${out:+, }$n"
  done
  echo "$out"
}

app_dir() {
  local d
  while IFS= read -r d; do
    [[ $(app_env "$d" NAME) == "$1" || $(basename "$d") == "$1" ]] && { echo "$d"; return 0; }
  done < <(app_vm_dirs)
  return 1
}

# The fast network (feature fast-network): the app writes which network each
# start took to logs/network ("vmnet", or "slirp" and why); the VM's MAC
# address is in its fast-network file. On vmnet the VM has an address of its
# own (macOS's DHCP server hands it out), and SSH goes there (port 22), its
# host key checked as always.
app_net() { awk 'NR == 1 { print $1 }' "$1/logs/network" 2>/dev/null; }   # DIR -> vmnet|slirp
app_vmnet_ip() {   # DIR -> the VM's address on vmnet's network (lease_ip, src/lib/mac.sh)
  local m
  m=$(sed -n 's/^mac=//p' "$1/fast-network" 2>/dev/null)
  [[ -n $m ]] && m=$(lease_ip "$m") && [[ $m =~ ^192\.168\.77\.[0-9]+$ ]] && echo "$m"
}

app_any_fast_network() {   # one of this user's app VMs has the fast network on
  local d
  while IFS= read -r d; do [[ -s $d/fast-network ]] && return 0; done < <(app_vm_dirs)
  return 1
}

app_ip() {   # NAME [seconds]: only when that QEMU itself holds the port (not
  # whatever else listens there), or its vmnet address
  local d p i pid ip
  d=$(app_dir "$1") || return 1
  p=$(app_env "$d" SSH_PORT); [[ $p =~ ^[0-9]+$ ]] || return 1
  for ((i = 0; i <= ${2:-0}; i += 2)); do
    pid=$(app_pid_dir "$d")
    if [[ -n $pid && $(app_net "$d") == vmnet ]]; then
      ip=$(app_vmnet_ip "$d") && { echo "$ip"; return 0; }
    elif [[ -n $pid ]] && lsof -nP -a -p "$pid" -iTCP@127.0.0.1:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "127.0.0.1:$p"; return 0
    fi
    sleep 2
  done
  return 1
}

app_other_running() {   # NAME -> another app VM that runs (the app runs one at a time)
  # No early exit in awk: app_list would get SIGPIPE and pipefail fail the test.
  app_list | awk -F'\t' -v n="$1" '$1 != n && $3 == "running" && !f { print $1; f = 1 } END { exit !f }'
}

app_start() {
  # -n: a new launcher passes the request on when one already runs. The app
  # app_bundle finds, not any copy LaunchServices knows (an older one, say).
  local a
  if a=$(app_bundle); then open -n "$a" --args --start --vm "$1" || return 1
  else open -n -b org.omacvm.app --args --start --vm "$1" || return 1; fi
  app_ip "$1" 60
}

app_bundle() {   # the app whose own copy of omacvm runs, else in ~/Applications, else /Applications, by its bundle id
  local a
  # OmacVM.app's bundled omacvm (and its apply-vm.sh) set OMACVM_APP_RUNTIME
  # to the app's runtime: that app, wherever it is (another drive, Downloads).
  if [[ ${OMACVM_APP_RUNTIME:-} == */Contents/Resources/runtime ]]; then
    a=${OMACVM_APP_RUNTIME%/Contents/Resources/runtime}
    [[ -f $a/Contents/Resources/scripts/create-vm.sh &&
       $(defaults read "$a/Contents/Info" CFBundleIdentifier 2>/dev/null) == "$APP_BUNDLE_ID" ]] && { echo "$a"; return 0; }
  fi
  for a in "$HOME"/Applications/*.app /Applications/*.app; do
    [[ -f $a/Contents/Resources/scripts/create-vm.sh ]] || continue
    [[ $(defaults read "$a/Contents/Info" CFBundleIdentifier 2>/dev/null) == "$APP_BUNDLE_ID" ]] && { echo "$a"; return 0; }
  done
  return 1
}

app_version() { defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null; }

app_free_port() {   # the VM's SSH port: free now, and in no other VM's vm.env
  local d p used=" "
  while IFS= read -r d; do used+="$(app_env "$d" SSH_PORT) "; done < <(app_vm_dirs)
  for ((p = 52222; p < 52422; p++)); do
    [[ $used == *" $p "* ]] && continue
    nc -z -G1 127.0.0.1 "$p" >/dev/null 2>&1 || { echo "$p"; return 0; }
  done
  return 1
}

# vm.env as the app writes it (single quotes, so the app reads it back too).
# KEY=VALUE: NAME CPUS MEM_MB DISK_GB SSH_PORT VM_USER VM_FULLNAME VM_HOSTNAME
# VM_TZ VM_LANG KEYBOARD FEATURES ("bridge=on wallpaper=on ...").
app_create() {
  local script=create-vm.sh dir a kv v q="'"
  [[ $1 == --prebuilt ]] && { script=prebuilt-vm.sh; shift; }
  dir=$1; shift
  a=$(app_bundle) || return 1
  mkdir -p "$dir"
  for kv in "$@"; do
    v=${kv#*=}; printf "%s='%s'\n" "${kv%%=*}" "${v//$q/$q\\$q$q}"
  done > "$dir/vm.env"
  # The downloads go to the drive of the VMs folder, as in the app.
  OMACVM_VMS_ROOT=$(dirname "$dir") /bin/bash "$a/Contents/Resources/scripts/$script" "$dir"
}

app_has_prebuilt() { [[ -f $1/Contents/Resources/scripts/prebuilt-vm.sh ]]; }

# Asks the app's own script, so omacvm build offers the image the app then
# downloads (the app looks with its version, not this omacvm's).
app_prebuilt_lookup() {
  local out
  out=$(OMACVM_VMS_ROOT=$(app_vms_root) /bin/bash "$1/Contents/Resources/scripts/prebuilt-vm.sh" --lookup 2>/dev/null < /dev/null) || return 1
  read -r PB_TAG PB_SIZE PB_OMARCHY PB_VERSION <<<"$out"
  [[ $PB_TAG =~ ^[A-Za-z0-9._-]{1,80}$ && $PB_SIZE =~ ^[0-9]{1,15}$ && $PB_OMARCHY =~ ^[!-~]{1,80}$ &&
     ${PB_VERSION:-} =~ ^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$ ]]
}

app_zip_url() { echo "$APP_DOWNLOADS/v$1/OmacVM-$1.zip"; }   # VERSION
APP_KEYS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../release/keys.py
# Who made the download: the release's update feed (OmacVM-appcast.json),
# signed with OmacVM's release key (main or spare, src/release/keys.py),
# gives the zip's SHA-256 and the Developer ID teams it may be signed by.
app_devid() {   # TEAM...: Developer ID Application of one of the teams, issued by Apple
  local t ou=""
  for t in "$@"; do ou+="${ou:+ or }certificate leaf[subject.OU] = \"$t\""; done
  echo "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and ($ou)"
}

app_version_lt() {   # A B: A is older than B (2.10.0 is newer than 2.9.1)
  awk -v a="$1" -v b="$2" 'BEGIN { n = split(a, x, "."); m = split(b, y, ".")
    for (i = 1; i <= (n > m ? n : m); i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 }
    exit 1 }'
}

app_published() {   # VERSION: its signed update feed is there (small; the zip is not fetched)
  curl -fsSL --max-time 30 -o /dev/null "$APP_DOWNLOADS/v$1/OmacVM-appcast.json.sig" 2>/dev/null
}

app_install_dir() { echo "$HOME/Applications"; }   # where a new OmacVM.app goes, as the app installs itself

app_install_cmd() {   # VERSION
  local u z; u=$(app_zip_url "$1"); z=OmacVM-$1.zip
  echo "cd \$(mktemp -d) && curl -fLO $u && curl -fLO $u.sha256 && shasum -a 256 -c $z.sha256 && ditto -x -k $z \"$(app_install_dir)\""
}

# curl sets no quarantine attribute (a browser does), so Gatekeeper does not
# stop the app, notarized or not: the Developer ID check does that part.
# app_download VERSION DIR: the release's OmacVM.app into DIR/x/OmacVM.app,
# checked: the signed feed first (nothing of the release is used before it
# checks out), then the zip against its SHA-256 and size, then the app: our
# bundle id and the feed's version, intact, and signed with a Developer ID of
# a team the feed names.
app_download() {
  local v=$1 tmp=$2 url want len got new feed teams_line teams=()
  url=$(app_zip_url "$v")
  if ! curl -fsL --max-time 30 -o "$tmp/feed.json" "$APP_DOWNLOADS/v$v/OmacVM-appcast.json" ||
     ! curl -fsL --max-time 30 -o "$tmp/feed.json.sig" "$APP_DOWNLOADS/v$v/OmacVM-appcast.json.sig"; then
    echo "no signed update feed for OmacVM.app $v ($APP_DOWNLOADS/v$v/OmacVM-appcast.json): not installed" >&2; return 1
  fi
  feed=$(python3 "$APP_KEYS" app-feed "$tmp/feed.json" "$v") ||
    { echo "the update feed of OmacVM.app $v does not check out: not installed" >&2; return 1; }
  read -r want len teams_line <<<"$feed"
  read -r -a teams <<<"$teams_line"
  [[ $want =~ ^[0-9a-f]{64}$ && $len =~ ^[0-9]{1,10}$ && ${#teams[@]} -ge 1 ]] ||
    { echo "the update feed of OmacVM.app $v names no Developer ID team: not installed" >&2; return 1; }
  printf 'Downloading OmacVM.app %s\n' "$v" >&2
  curl -fL --progress-bar -o "$tmp/OmacVM.zip" "$url" || { echo "the download failed ($url)" >&2; return 1; }
  got=$(shasum -a 256 "$tmp/OmacVM.zip" | awk '{ print $1 }')
  [[ $got == "$want" && $(stat -f %z "$tmp/OmacVM.zip") == "$len" ]] ||
    { echo "the download does not match the signed feed's checksum: not installed" >&2; return 1; }
  new=$tmp/x/OmacVM.app
  if ! ditto -x -k "$tmp/OmacVM.zip" "$tmp/x" || [[ ! -d $new ]] || [[ $(defaults read "$new/Contents/Info" CFBundleIdentifier 2>/dev/null) != org.omacvm.app ]] ||
     [[ $(defaults read "$new/Contents/Info" CFBundleShortVersionString 2>/dev/null) != "$v" ]] ||
     ! codesign --verify --deep --strict "$new" 2>/dev/null; then
    echo "the download holds no intact OmacVM.app $v: not installed" >&2; return 1
  fi
  codesign --verify -R="$(app_devid "${teams[@]}")" "$new" 2>/dev/null ||
    { echo "the download is not signed with a Developer ID the signed feed names (${teams[*]}): not installed" >&2; return 1; }
}

app_install() {   # VERSION [APP]
  local v=$1 dest=${2:-} tmp new name
  tmp=$(mktemp -d)
  app_download "$v" "$tmp" || { rm -rf "$tmp"; return 1; }
  new=$tmp/x/OmacVM.app
  if [[ -n $dest ]]; then
    # Installed under its own name (the app offers that): keep it, signed
    # again ad hoc as the app does when it installs itself.
    name=$(defaults read "$dest/Contents/Info" CFBundleName 2>/dev/null)
    if [[ -n $name && $name != OmacVM ]]; then
      /usr/libexec/PlistBuddy -c "Set :CFBundleName $name" -c "Set :CFBundleDisplayName $name" "$new/Contents/Info.plist" &&
        codesign --force --sign - --identifier org.omacvm.app -r='designated => identifier "org.omacvm.app"' "$new" 2>/dev/null ||
        { rm -rf "$tmp"; echo "could not keep the name $name" >&2; return 1; }
    fi
  else
    dest=$(app_install_dir)/OmacVM.app
    mkdir -p "$(dirname "$dest")"
    [[ ! -e $dest ]] || { rm -rf "$tmp"; echo "$dest is there but is not a complete OmacVM.app: move it away first" >&2; return 1; }
  fi
  # Next to the old one first, then swapped: never a half-copied app.
  rm -rf "$dest.new" "$dest.old"
  ditto "$new" "$dest.new" || { rm -rf "$tmp" "$dest.new"; echo "could not write $(dirname "$dest")" >&2; return 1; }
  # Each step checked: a failed first mv must not move the new app into the
  # old one (that breaks its signature); a failed second mv puts the old back.
  if [[ -e $dest ]] && ! mv "$dest" "$dest.old"; then
    rm -rf "$tmp" "$dest.new"; echo "could not move $dest aside: not updated" >&2; return 1
  fi
  if ! mv "$dest.new" "$dest"; then
    [[ ! -e $dest.old ]] || mv "$dest.old" "$dest" || echo "the old app is at $dest.old" >&2
    rm -rf "$tmp" "$dest.new"; echo "could not put the new app at $dest: not updated" >&2; return 1
  fi
  rm -rf "$dest.old" "$tmp"
  # So that open -b org.omacvm.app finds it right away.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest" >/dev/null 2>&1 || true
  echo "$dest"
}
