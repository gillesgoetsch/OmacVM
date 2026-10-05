# OmacVM.app's VMs, from the Mac (sourced by vm.sh; bash 3.2). The app keeps
# each VM in a folder with vm.env (NAME, SSH_PORT, ...) and disk.img; QEMU
# forwards the VM's SSH to 127.0.0.1:SSH_PORT, so its "IP" here is
# 127.0.0.1:PORT (gssh understands that).
#   app_list            NAME<TAB>app<TAB>running|stopped, one line per VM
#   app_dir NAME        the VM's folder
#   app_ip NAME         127.0.0.1:PORT while it runs (fast network: its vmnet address)
#   app_any_fast_network  one of the VMs has the fast network on
#   app_start NAME      start it in the app (its window opens)
#   app_other_running NAME  another app VM that runs, if any
#   app_bundle          the installed OmacVM.app (any name it was installed under)
#   app_create DIR KEY=VALUE...  a new VM in DIR through the app's own create
#                       script (the password on stdin), as when built in the app
#   app_published VERSION   that OmacVM release has OmacVM-VERSION.zip
#   app_install VERSION [APP]  download, check and install it (in /Applications,
#                       else ~/Applications; or in place of APP); prints the path
#   app_install_cmd VERSION    the same as one command, for a person to run
# omacvm apply writes guest-pointer ("omarchy") into the folder once the VM
# draws Omarchy's own pointer: the app hides the Mac's pointer only then.

# Where OmacVM.app is published: OmacVM-VERSION.zip (and .sha256) in each
# OmacVM release, the app's version the same as OmacVM's.
APP_DOWNLOADS=https://github.com/gillesgoetsch/omacvm/releases/download

app_vms_root() {
  local r
  r=$(defaults read org.omacvm.app vmsRoot 2>/dev/null)
  echo "${r:-$HOME/Library/Application Support/OmacVM/VMs}"
}

app_env() {   # DIR KEY: one value from vm.env (single quotes stripped)
  sed -n "s/^$2=//p" "$1/vm.env" 2>/dev/null | tail -1 | sed "s/^'\(.*\)'\$/\1/"
}

app_pid_dir() {   # DIR -> the PID of its QEMU (the disk is on its command line, commas
  # doubled); this user's processes only: another account could fake the line.
  ps -x -U "$(id -u)" -o pid=,args= 2>/dev/null | grep -F -- "file=${1//,/,,}/disk.img," |
    grep -v grep | awk '{ print $1; exit }'
}

app_running_dir() { [[ -n $(app_pid_dir "$1") ]]; }

app_list() {
  local d n
  for d in "$(app_vms_root)"/*; do
    [[ -f $d/vm.env && -f $d/disk.img ]] || continue
    n=$(app_env "$d" NAME); [[ -n $n ]] || n=$(basename "$d")
    printf '%s\tapp\t%s\n' "$n" "$(app_running_dir "$d" && echo running || echo stopped)"
  done
}

app_dir() {
  local d
  for d in "$(app_vms_root)"/*; do
    [[ -f $d/vm.env ]] || continue
    [[ $(app_env "$d" NAME) == "$1" || $(basename "$d") == "$1" ]] && { echo "$d"; return 0; }
  done
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
  for d in "$(app_vms_root)"/*; do [[ -s $d/fast-network ]] && return 0; done
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
  # -n: a new launcher passes the request on when one already runs.
  open -n -b org.omacvm.app --args --start --vm "$1" || return 1
  app_ip "$1" 60
}

app_bundle() {   # in /Applications or ~/Applications, by its bundle id
  local a
  for a in /Applications/*.app "$HOME"/Applications/*.app; do
    [[ -f $a/Contents/Resources/scripts/create-vm.sh ]] || continue
    [[ $(defaults read "$a/Contents/Info" CFBundleIdentifier 2>/dev/null) == org.omacvm.app ]] && { echo "$a"; return 0; }
  done
  return 1
}

app_version() { defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null; }

app_free_port() {   # the VM's SSH port: free now, and in no other VM's vm.env
  local d p used=" "
  for d in "$(app_vms_root)"/*; do used+="$(app_env "$d" SSH_PORT) "; done
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
  local dir=$1 a kv v q="'"; shift
  a=$(app_bundle) || return 1
  mkdir -p "$dir"
  for kv in "$@"; do
    v=${kv#*=}; printf "%s='%s'\n" "${kv%%=*}" "${v//$q/$q\\$q$q}"
  done > "$dir/vm.env"
  /bin/bash "$a/Contents/Resources/scripts/create-vm.sh" "$dir"
}

app_zip_url() { echo "$APP_DOWNLOADS/v$1/OmacVM-$1.zip"; }   # VERSION
# The release app is signed with OmacVM's Developer ID (team 722686Y34B). The
# .sha256 comes from the same release, so it only shows the download is
# whole; this shows who made it.
APP_DEVID='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "722686Y34B"'

app_version_lt() {   # A B: A is older than B (2.10.0 is newer than 2.9.1)
  awk -v a="$1" -v b="$2" 'BEGIN { n = split(a, x, "."); m = split(b, y, ".")
    for (i = 1; i <= (n > m ? n : m); i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 }
    exit 1 }'
}

app_published() {   # VERSION: its checksum file is there (small; the zip is not fetched)
  curl -fsSL --max-time 30 -o /dev/null "$(app_zip_url "$1").sha256" 2>/dev/null
}

app_install_dir() {   # where a new OmacVM.app goes, as the app installs itself
  if [[ -w /Applications ]]; then echo /Applications; else echo "$HOME/Applications"; fi
}

app_install_cmd() {   # VERSION
  local u z; u=$(app_zip_url "$1"); z=OmacVM-$1.zip
  echo "cd \$(mktemp -d) && curl -fLO $u && curl -fLO $u.sha256 && shasum -a 256 -c $z.sha256 && ditto -x -k $z $(app_install_dir)"
}

# curl sets no quarantine attribute (a browser does), so Gatekeeper does not
# stop the app, notarized or not: the Developer ID check does that part.
app_install() {   # VERSION [APP]
  local v=$1 dest=${2:-} url tmp want got new name
  url=$(app_zip_url "$v")
  tmp=$(mktemp -d)
  curl -fsL --max-time 30 -o "$tmp/sum" "$url.sha256" ||
    { rm -rf "$tmp"; echo "no OmacVM.app $v to download ($url)" >&2; return 1; }
  printf 'Downloading OmacVM.app %s\n' "$v" >&2
  curl -fL --progress-bar -o "$tmp/OmacVM.zip" "$url" ||
    { rm -rf "$tmp"; echo "the download failed ($url)" >&2; return 1; }
  want=$(awk '{ print $1; exit }' "$tmp/sum")
  got=$(shasum -a 256 "$tmp/OmacVM.zip" | awk '{ print $1 }')
  [[ $want =~ ^[0-9a-f]{64}$ && $got == "$want" ]] ||
    { rm -rf "$tmp"; echo "the download does not match its checksum: not installed" >&2; return 1; }
  new=$tmp/x/OmacVM.app
  if ! ditto -x -k "$tmp/OmacVM.zip" "$tmp/x" || [[ ! -d $new ]] || [[ $(defaults read "$new/Contents/Info" CFBundleIdentifier 2>/dev/null) != org.omacvm.app ]] ||
     ! codesign --verify --deep --strict "$new" 2>/dev/null; then
    rm -rf "$tmp"; echo "the download holds no intact OmacVM.app: not installed" >&2; return 1
  fi
  codesign --verify -R="$APP_DEVID" "$new" 2>/dev/null ||
    { rm -rf "$tmp"; echo "the download is not signed with OmacVM's Developer ID (team 722686Y34B): not installed" >&2; return 1; }
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
