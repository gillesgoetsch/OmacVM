#!/bin/bash
# Building behind a proxy (#122), offline: the Mac's proxy from scutil --proxy
# samples and the environment (src/lib/proxy.sh), the VM's proxy variables,
# the build's port list for QEMU (vm-common.sh with a stub QEMU), the new
# system's files (base-install.sh), the install's sudo drop-in, retry wrappers
# and systemd-run flags (omarchy-install.sh), and git and curl through a stub
# proxy with a clean environment as systemd-run gives it.
#   src/tests/proxy.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d -t omacvm-proxy)
PROXY_PID=""
trap '[[ -z $PROXY_PID ]] || kill "$PROXY_PID" 2>/dev/null; rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}
has() {   # WHAT NEEDLE HAYSTACK
  case $3 in *"$2"*) echo "ok   $1" ;; *) printf 'FAIL %s\n  no %s in: %s\n' "$1" "$2" "$3"; fail=1 ;; esac
}
unset http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY OMACVM_PROXY
source "$R/src/lib/proxy.sh"

# ---------- scutil --proxy samples ----------
cat > "$T/clash" <<'EOF'
<dictionary> {
  ExceptionsList : <array> {
    0 : *.local
    1 : 169.254/16
    2 : 10.0.0.0/8
  }
  FTPPassive : 1
  HTTPEnable : 1
  HTTPPort : 7890
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 1
  HTTPSPort : 7890
  HTTPSProxy : 127.0.0.1
  SOCKSEnable : 1
  SOCKSPort : 7891
  SOCKSProxy : 127.0.0.1
  __SCOPED__ : <dictionary> {
    en0 : <dictionary> {
      HTTPEnable : 1
      HTTPPort : 9999
      HTTPProxy : 10.9.9.9
    }
  }
}
EOF
cat > "$T/socks" <<'EOF'
<dictionary> {
  SOCKSEnable : 1
  SOCKSPort : 7897
  SOCKSProxy : localhost
}
EOF
cat > "$T/pac" <<'EOF'
<dictionary> {
  ProxyAutoConfigEnable : 1
  ProxyAutoConfigURLString : http://wpad.example/proxy.pac
}
EOF
cat > "$T/pac-http" <<'EOF'
<dictionary> {
  HTTPEnable : 1
  HTTPPort : 3128
  HTTPProxy : proxy.corp.example
  ProxyAutoConfigEnable : 1
  ProxyAutoConfigURLString : http://wpad.example/proxy.pac
}
EOF
cat > "$T/wpad" <<'EOF'
<dictionary> {
  ProxyAutoDiscoveryEnable : 1
}
EOF
cat > "$T/none" <<'EOF'
<dictionary> {
  ExceptionsList : <array> {
    0 : *.local
    1 : 169.254/16
  }
  FTPPassive : 1
}
EOF
cat > "$T/off" <<'EOF'
<dictionary> {
  HTTPEnable : 0
  HTTPPort : 7890
  HTTPProxy : 127.0.0.1
}
EOF
det() { OMACVM_PROXY_SCUTIL=$T/$1 proxy_detect; }

det clash
expect "scutil: HTTP" "http://127.0.0.1:7890" "$PROXY_HTTP"
expect "scutil: HTTPS (secure web proxy, an HTTP proxy too)" "http://127.0.0.1:7890" "$PROXY_HTTPS"
expect "scutil: SOCKS (names resolved by the proxy)" "socks5h://127.0.0.1:7891" "$PROXY_ALL"
expect "scutil: the per-interface copies are not read" "" "$(grep 9999 <<<"$PROXY_HTTP$PROXY_HTTPS$PROXY_ALL")"
expect "scutil: bypass list" ".local,169.254.0.0/16,10.0.0.0/8" "$PROXY_NO"
expect "scutil: source" "macOS's network settings" "$PROXY_FROM"
expect "scutil: loopback ports, each once" "7890,7891" "$(proxy_ports)"
g=$(proxy_guest_env 10.0.2.2)
expect "guest env: lines" "# The Mac's proxy when this VM was built (OmacVM, from macOS's network settings).
http_proxy=http://10.0.2.2:7890
HTTP_PROXY=http://10.0.2.2:7890
https_proxy=http://10.0.2.2:7890
HTTPS_PROXY=http://10.0.2.2:7890
all_proxy=socks5h://10.0.2.2:7891
ALL_PROXY=socks5h://10.0.2.2:7891
no_proxy=localhost,127.0.0.1,::1,10.0.2.2,.local,169.254.0.0/16,10.0.0.0/8
NO_PROXY=localhost,127.0.0.1,::1,10.0.2.2,.local,169.254.0.0/16,10.0.0.0/8" "$g"
expect "guest env: a VM network without the Mac's 127.0.0.1 gets nothing" "" "$(proxy_guest_env "")"

det socks
expect "scutil, SOCKS only: all_proxy" "socks5h://localhost:7897" "$PROXY_HTTP$PROXY_HTTPS$PROXY_ALL"
expect "scutil, SOCKS only: port" "7897" "$(proxy_ports)"
expect "scutil, SOCKS only: guest" "all_proxy=socks5h://10.0.2.2:7897" "$(proxy_guest_env 10.0.2.2 | grep '^all_proxy=')"

det pac
expect "scutil, PAC: no proxy" "" "$PROXY_HTTP$PROXY_HTTPS$PROXY_ALL$(proxy_guest_env 10.0.2.2)"
has "scutil, PAC: says it is not read" "does not read PAC files" "$PROXY_NOTE"
has "scutil, PAC: names the file" "http://wpad.example/proxy.pac" "$PROXY_NOTE"
has "scutil, PAC: says what to do" "set http_proxy and https_proxy" "$PROXY_NOTE"

det pac-http
expect "scutil, PAC and a fixed proxy: the fixed one" "http://proxy.corp.example:3128" "$PROXY_HTTP"
has "scutil, PAC and a fixed proxy: the PAC note too" "PAC" "$PROXY_NOTE"
expect "another host: no port to forward" "" "$(proxy_ports)"
expect "another host: the VM uses it as it is, on every route" "http_proxy=http://proxy.corp.example:3128" "$(proxy_guest_env "" | grep '^http_proxy=')"

det wpad
expect "scutil, WPAD: no proxy" "" "$PROXY_HTTP$PROXY_HTTPS$PROXY_ALL"
has "scutil, WPAD: says so" "WPAD" "$PROXY_NOTE"

det none
expect "scutil, nothing set: nothing" "||||" "$PROXY_HTTP|$PROXY_HTTPS|$PROXY_ALL|$PROXY_NO|$PROXY_FROM$PROXY_NOTE"
expect "nothing set: no guest env, no ports" "" "$(proxy_guest_env 10.0.2.2)$(proxy_ports)$(proxy_summary)"
det off
expect "scutil, a switched-off proxy: nothing" "" "$PROXY_HTTP"

# ---------- the Mac's environment ----------
got=$(export https_proxy='http://me:p%40ss@127.0.0.1:7897/' ALL_PROXY='socks5://[::1]:7898' no_proxy='.corp,10.1.0.0/16'
  OMACVM_PROXY_SCUTIL=$T/clash proxy_detect
  printf '%s|%s|%s|%s|%s' "$PROXY_HTTP" "$PROXY_HTTPS" "$PROXY_ALL" "$PROXY_NO" "$PROXY_FROM")
expect "environment wins over the settings" "|http://me:p%40ss@127.0.0.1:7897|socks5://[::1]:7898|.corp,10.1.0.0/16|the environment" "$got"
got=$(export https_proxy='http://me:p%40ss@127.0.0.1:7897/' ALL_PROXY='socks5://[::1]:7898'; proxy_detect; proxy_guest_env 10.0.2.2 | grep -E '^(https|all)_proxy=')
expect "environment: credentials kept, loopback (IPv6 too) to the Mac's address" "https_proxy=http://me:p%40ss@10.0.2.2:7897
all_proxy=socks5://10.0.2.2:7898" "$got"
got=$(export https_proxy='http://me:secret@127.0.0.1:7897'; proxy_detect; proxy_summary)
expect "summary hides credentials" "https http://***@127.0.0.1:7897 (from the environment)" "$got"
got=$(export http_proxy='127.0.0.1'; proxy_detect; echo "$PROXY_HTTP $(proxy_ports)")
expect "environment: no scheme, no port: http, 1080 (as curl)" "http://127.0.0.1:1080 1080" "$got"
got=$(export http_proxy='http://me:pa$$@127.0.0.1:7890'; proxy_detect; echo "${PROXY_HTTP:-none}|$PROXY_NOTE")
expect "environment: \$ in the value is refused (environment.d would expand it)" \
  "none|http_proxy is not a proxy address OmacVM can pass on: http://me:pa\$\$@127.0.0.1:7890" "$got"
got=$(export http_proxy='http://127.0.0.1:70000'; proxy_detect; echo "${PROXY_HTTP:-none}")
expect "environment: a bad port is refused" "none" "$got"
got=$(export http_proxy='ftp://127.0.0.1:21'; proxy_detect; echo "${PROXY_HTTP:-none}")
expect "environment: a scheme curl has no proxy for is refused" "none" "$got"
got=$(export http_proxy='http://127.0.0.1:7890' OMACVM_PROXY=off; proxy_detect; echo "${PROXY_HTTP:-none}$(proxy_ports)")
expect "OMACVM_PROXY=off: none" "none" "$got"

# ---------- vm-common.sh: the build's QEMU gets the proxy's port ----------
# A fake app layout (runtime/bin/OmacVM, firmware, omacvm/src) with a stub QEMU
# that writes down the port list it was given.
A=$T/app; mkdir -p "$A/scripts" "$A/runtime/bin" "$A/firmware" "$A/omacvm"
cp "$R/app/scripts/vm-common.sh" "$A/scripts/"; ln -s "$R/src" "$A/omacvm/src"
touch "$A/firmware/edk2-aarch64-code.fd"
cat > "$A/runtime/bin/OmacVM" <<EOF
#!/bin/bash
echo "\${OMACVM_SLIRP_HOST_PORTS-unset}" > "$T/qemu-ports"
sleep 5
EOF
chmod +x "$A/runtime/bin/OmacVM"
mkdir -p "$T/vm"
printf 'NAME=T\nCPUS=1\nMEM_MB=512\nDISK_GB=1\nSSH_PORT=1\nVM_USER=t\n' > "$T/vm/vm.env"
build_run() {   # [ENV=VALUE...]: proxy_setup + qemu_headless, the ports QEMU got; proxy_to_vm's file
  rm -f "$T/qemu-ports" "$T/to-vm"
  # shellcheck disable=SC2163  # "$@" is VAR=VALUE words
  ( export OMACVM_KEY=$T/key "$@"
    source "$A/scripts/vm-common.sh"
    vm_load "$T/vm" >/dev/null
    vssh() { cat > "$T/to-vm"; }
    proxy_setup > "$T/setup.out"
    qemu_headless live >/dev/null
    proxy_to_vm
    kill "$(cat "$PIDFILE")" 2>/dev/null )
  cat "$T/qemu-ports"
}
expect "build: the proxy's ports join OmacVM's" "47811,47830,47831,7890,7891" "$(build_run OMACVM_PROXY_SCUTIL="$T/clash")"
has "build: says which proxy" "==> proxy: http http://127.0.0.1:7890" "$(cat "$T/setup.out")"
expect "build: the live system gets the VM's variables" "$g" "$(cat "$T/to-vm")"
expect "build: no proxy, the ports as before" "47811,47830,47831" "$(build_run OMACVM_PROXY_SCUTIL="$T/none")"
expect "build: no proxy, nothing sent to the VM" "no" "$([[ -e $T/to-vm ]] && echo yes || echo no)"
expect "build: test VM without Mac ports: only the proxy's" "7890,7891" "$(build_run OMACVM_HOST_PORTS= OMACVM_PROXY_SCUTIL="$T/clash")"
expect "build: image builds take nothing of this Mac" "47811,47830,47831" "$(build_run OMACVM_CREATE_IMAGE=1 OMACVM_PROXY_SCUTIL="$T/clash")"
has "build: a PAC file is named in the output" "does not read PAC files" "$(build_run OMACVM_PROXY_SCUTIL="$T/pac" >/dev/null; cat "$T/setup.out")"

# ---------- base-install.sh: the new system keeps the proxy ----------
printf '%s\n' "$g" > "$T/proxy.env"
blk=$(awk '/^if \[\[ -s \$PROXY_ENV \]\]; then$/ { b = $0; on = 1; next }
           on == 1 && /log "the Mac.s proxy, kept/ { print b; on = 2 }
           on == 1 { on = 0 } on == 2 { print } on == 2 && /^fi$/ { exit }' "$R/src/vm/base-install.sh")
has "base-install.sh: the block is found" 'install -Dm644 "$PROXY_ENV" /mnt/etc/environment.d/90-omacvm-proxy.conf' "$blk"
# macOS's install has no -D (make the folders): GNU install's, for this run.
( log() { :; }; PROXY_ENV=$T/proxy.env
  install() { if [[ $1 == -D* ]]; then mkdir -p "$(dirname "${!#}")"; command install "-${1#-D}" "${@:2}"; else command install "$@"; fi; }
  eval "$(sed -n 's/^PROXY_VARS=/PROXY_VARS=/p' "$R/src/vm/base-install.sh")"
  mkdir -p "$T/mnt/etc/profile.d" "$T/mnt/etc/sudoers.d"
  eval "${blk//\/mnt/$T/mnt}" )
expect "new system: environment.d (desktop sessions)" "$g" "$(cat "$T/mnt/etc/environment.d/90-omacvm-proxy.conf")"
got=$(env -i /bin/bash -c ". '$T/mnt/etc/profile.d/omacvm-proxy.sh'; echo \"\$https_proxy|\$ALL_PROXY|\$no_proxy\"")
expect "new system: profile.d (shells)" "http://10.0.2.2:7890|socks5h://10.0.2.2:7891|localhost,127.0.0.1,::1,10.0.2.2,.local,169.254.0.0/16,10.0.0.0/8" "$got"
expect "new system: sudo keeps the variables" \
  'Defaults env_keep += "http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY"' \
  "$(cat "$T/mnt/etc/sudoers.d/05-omacvm-proxy")"
expect "new system: sudoers drop-in mode 440" "440" "$(stat -f %Lp "$T/mnt/etc/sudoers.d/05-omacvm-proxy")"
expect "base-install.sh and omarchy-install.sh keep the same variables" \
  "$(grep '^PROXY_VARS=' "$R/src/vm/base-install.sh")" "$(grep '^PROXY_VARS=' "$R/src/vm/omarchy-install.sh")"

# ---------- omarchy-install.sh: sudo drop-in, retry wrappers ----------
OI=$R/src/vm/omarchy-install.sh
helpers=$(awk '/^# ---- install helpers/ { on = 1 } on { print } /^# ---- end of the install helpers/ { exit }' "$OI")
mkdir -p "$T/bin" "$T/real"
for t in pacman git; do
  cat > "$T/real/$t" <<EOF
#!/bin/bash
# Stub: fails as long as $T/$t-fails says, counts its calls.
echo "\$*" >> "$T/$t-calls"
n=\$(cat "$T/$t-fails" 2>/dev/null || echo 0)
if (( n > 0 )); then echo \$((n - 1)) > "$T/$t-fails"; echo "error: failed retrieving file: Operation too slow" >&2; exit 1; fi
exit 0
EOF
  chmod +x "$T/real/$t"
done
(
  U=vocllum PROXY_VARS=$(sed -n 's/^PROXY_VARS="\(.*\)"$/\1/p' "$OI")
  SUDOERS=$T/sudoers WRAP_DIR=$T/bin REAL_DIR=$T/real
  eval "$helpers"
  install_helpers
)
expect "install sudo drop-in: password-less, keeps the proxy variables" 'Defaults:vocllum verifypw=any
Defaults:vocllum env_keep += "http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY"
vocllum ALL=(ALL:ALL) NOPASSWD: ALL' "$(cat "$T/sudoers")"
run() {   # TOOL FAILS ARGS...: exit code and number of calls
  local t=$1; echo "$2" > "$T/$t-fails"; rm -f "$T/$t-calls"; shift 2
  OMACVM_RETRY_SECONDS=0 "$T/bin/$t" "$@" 2>/dev/null
  echo "rc=$? calls=$(wc -l < "$T/$t-calls" | tr -d ' ')"
}
expect "pacman -Syu: a failed download is tried again" "rc=0 calls=2" "$(run pacman 1 -Syu --noconfirm)"
expect "pacman -S: 3 tries, then its exit code" "rc=1 calls=3" "$(run pacman 5 -S --noconfirm --needed git)"
expect "pacman --sync: tried again" "rc=0 calls=3" "$(run pacman 2 --sync --noconfirm yay)"
expect "pacman -Ss (search): once" "rc=1 calls=1" "$(run pacman 1 -Ss yay)"
expect "pacman -Si (info): once" "rc=1 calls=1" "$(run pacman 1 -Si yay)"
expect "pacman -Qi (local query): once" "rc=1 calls=1" "$(run pacman 1 -Qi yay)"
expect "pacman -Rns: once" "rc=1 calls=1" "$(run pacman 1 -Rns yay)"
expect "pacman: arguments passed as they are" "-S --noconfirm a b c" "$(run pacman 0 -S --noconfirm a b c >/dev/null; cat "$T/pacman-calls")"
expect "git clone: tried again" "rc=0 calls=2" "$(run git 1 clone https://aur.archlinux.org/yay.git)"
expect "git -C DIR clone: tried again" "rc=0 calls=3" "$(run git 2 -C /tmp clone https://aur.archlinux.org/yay.git)"
expect "git pull: once" "rc=1 calls=1" "$(run git 1 pull)"
expect "git -c clone.x=1 status: once" "rc=1 calls=1" "$(run git 1 -c clone.x=1 status)"
( SUDOERS=$T/sudoers WRAP_DIR=$T/bin; eval "$helpers"; remove_helpers )
expect "the install's end removes the drop-in and the wrappers" "" "$(ls "$T/bin"; ls "$T/sudoers" 2>/dev/null)"
printf '#!/bin/bash\necho mine\n' > "$T/bin/git"; chmod +x "$T/bin/git"
( U=u PROXY_VARS=x SUDOERS=$T/sudoers WRAP_DIR=$T/bin REAL_DIR=$T/real; eval "$helpers"; install_helpers; remove_helpers )
expect "a git in /usr/local/bin that is not ours stays as it is" "mine" "$("$T/bin/git")"
expect "  and pacman's wrapper still comes and goes" "git" "$(ls "$T/bin")"

# ---------- systemd-run: one -E per proxy variable ----------
setenv=$(awk '/^PROXY_ENV=/ { on = 1 } on { print } on && /^for v in \$PROXY_VARS/ { exit }' "$OI")
has "omarchy-install.sh: the installer's unit gets the flags" '${SETENV[@]+"${SETENV[@]}"}' "$(grep -A2 '^systemd-run ' "$OI")"
got=$(env -i /bin/bash -c "$(sed "s|^PROXY_ENV=.*|PROXY_ENV=$T/proxy.env|" <<<"$setenv")"'
  printf "%s\n" "${SETENV[@]}"')
want=$(for v in http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
  grep "^$v=" "$T/proxy.env" | while IFS= read -r l; do printf -- '-E\n%s\n' "$l"; done; done)
expect "systemd-run flags, one -E per variable" "$want" "$got"
got=$(env -i /bin/bash -c "$(sed "s|^PROXY_ENV=.*|PROXY_ENV=$T/nothing|" <<<"$setenv")"'
  echo "${#SETENV[@]}"')
expect "systemd-run flags: none without a proxy" "0" "$got"

# ---------- through a stub proxy, with systemd-run's clean environment ----------
# The Mac's proxy on 127.0.0.1 (here the "VM" reaches it as 127.0.0.1 too);
# a stub systemd-run that starts its command with only the -E variables, as a
# unit does; git clone (through the retry wrapper) and curl inside it.
cat > "$T/stub-proxy.py" <<'EOF'
import http.server, socketserver, sys
log, portfile = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def note(self):
        with open(log, "a") as f: f.write(f"{self.command} {self.path}\n")
    def do_CONNECT(self):
        self.note(); self.send_error(502, "stub proxy")
    def do_GET(self):
        self.note(); body = b"via the stub proxy\n"
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
s = socketserver.ThreadingTCPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(s.server_address[1]))
s.serve_forever()
EOF
python3 "$T/stub-proxy.py" "$T/proxy.log" "$T/proxy.port" & PROXY_PID=$!; disown
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s $T/proxy.port ]] && break; sleep 0.3; done
PORT=$(cat "$T/proxy.port" 2>/dev/null)
if [[ -z $PORT ]]; then echo "FAIL the stub proxy did not start"; fail=1; else
  ( export http_proxy=http://127.0.0.1:$PORT https_proxy=http://127.0.0.1:$PORT; proxy_detect
    proxy_guest_env 127.0.0.1 ) > "$T/e2e.env"
  cat > "$T/systemd-run" <<'EOF'
#!/bin/bash
# Stub: a unit's clean environment, only -E VAR=VALUE (and PATH, as systemd sets it).
vars=()
while (( $# )); do case $1 in -E) vars+=("$2"); shift 2 ;; --*=*|-p) [[ $1 == -p ]] && shift; shift ;; --*) shift ;; *) break ;; esac; done
exec env -i PATH="$STUB_PATH" "${vars[@]}" "$@"
EOF
  chmod +x "$T/systemd-run"
  rm -rf "${T:?}/bin"; mkdir -p "$T/bin" "$T/real2"
  ln -s "$(command -v git)" "$T/real2/git"; ln -s "$(command -v pacman 2>/dev/null || echo /usr/bin/false)" "$T/real2/pacman"
  ( U=u PROXY_VARS=x SUDOERS=$T/sudoers WRAP_DIR=$T/bin REAL_DIR=$T/real2; eval "$helpers"; install_helpers )
  got=$(env -i PATH=/usr/bin:/bin STUB_PATH="$T/bin:/usr/bin:/bin" /bin/bash -c "
    $(sed "s|^PROXY_ENV=.*|PROXY_ENV=$T/e2e.env|" <<<"$setenv")
    '$T/systemd-run' --uid=u --unit=x -p WorkingDirectory=/ -E HOME=$T -E OMACVM_RETRY_SECONDS=0 \${SETENV[@]+\"\${SETENV[@]}\"} \
      /bin/bash -c 'git clone -q https://aur.example.invalid/yay.git $T/yay >/dev/null 2>&1; echo git=\$?; curl -s http://mirror.example.invalid/core.db'")
  expect "in the unit: git fails through the proxy (it answers 502), curl gets its page" "git=128
via the stub proxy" "$got"
  expect "the proxy saw git's 3 tries and curl's request" "CONNECT aur.example.invalid:443
CONNECT aur.example.invalid:443
CONNECT aur.example.invalid:443
GET http://mirror.example.invalid/core.db" "$(cat "$T/proxy.log" 2>/dev/null)"
  rm -f "$T/proxy.log"
  got=$(env -i PATH=/usr/bin:/bin STUB_PATH="$T/bin:/usr/bin:/bin" /bin/bash -c "
    '$T/systemd-run' --unit=x -E HOME=$T /bin/bash -c 'curl -s -m 3 http://mirror.example.invalid/core.db >/dev/null; echo curl=\$?'")
  expect "without the -E flags the unit has no proxy (the failure of #122)" "no" \
    "$([[ -s $T/proxy.log ]] && echo yes || echo no)"
fi

exit $fail
