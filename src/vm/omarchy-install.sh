#!/bin/bash
# Install Omarchy from omarchy-mac on the freshly booted base system. Runs as
# root in the VM (build.sh copies it with /root/omacvm.env); the
# installer itself runs as the desktop user, unattended, with a temporary
# password-less sudo that is removed again at the end.
#   OMARCHY_MAC_CHANNEL  rc (default) or stable, passed to `install.sh --channel`
set -euo pipefail
source /root/omacvm.env
U=$OMA_USER; H=$(getent passwd "$U" | cut -d: -f6)
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

# The Mac's proxy (#122): base-install.sh keeps it in the new system when the
# Mac has one. pacman here uses it, sudo keeps it (env_keep below) and the
# installer's unit gets it (systemd-run starts with a clean environment).
PROXY_ENV=/etc/environment.d/90-omacvm-proxy.conf
PROXY_VARS="http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY"
# shellcheck source=/dev/null
if [[ -s $PROXY_ENV ]]; then set -a; source "$PROXY_ENV"; set +a; fi
SETENV=()
for v in $PROXY_VARS; do [[ -z ${!v:-} ]] || SETENV+=(-E "$v=${!v}"); done

SUDOERS=/etc/sudoers.d/zz-omacvm-install WRAP_DIR=/usr/local/bin REAL_DIR=/usr/bin
# ---- install helpers (src/tests/proxy.sh runs this block) ----
# For the install only, removed again at the end: a password-less sudo that
# keeps the proxy variables, and pacman and git clone that try again after a
# failed download (a slow or dropped mirror or proxy connection: "Operation
# too slow"; pacman has no retry setting of its own). The wrappers sit in
# /usr/local/bin, ahead of /usr/bin on the PATH; pacman's own downloader,
# ParallelDownloads and the signature checks stay as they are.
install_helpers() {
  local t
  printf 'Defaults:%s verifypw=any\nDefaults:%s env_keep += "%s"\n%s ALL=(ALL:ALL) NOPASSWD: ALL\n' \
    "$U" "$U" "$PROXY_VARS" "$U" > "$SUDOERS"
  chmod 440 "$SUDOERS"
  for t in pacman git; do
    [[ -e $WRAP_DIR/$t ]] && continue   # not ours: left alone
    sed "s|@REAL@|$REAL_DIR/$t|" > "$WRAP_DIR/$t" <<'EOF'
#!/bin/bash
# OmacVM retry wrapper, only while Omarchy installs (omarchy-install.sh removes
# it): pacman that downloads (-S, -Sy, -Syu, not -Ss/-Si/-Sl/-Sg/-Sp/-Sc) and
# git clone run again after a failure, 3 tries; anything else runs once.
real=@REAL@
again=0 skip=0
case ${real##*/} in
  pacman)
    for a in "$@"; do
      case $a in
        --) break ;;
        --sync) again=1 ;;
        --search|--info|--list|--groups|--print|--print-format|--clean|--help|--version) again=0; break ;;
        --*) ;;
        -*S*) case ${a#-} in *[silgpch]*) again=0; break ;; *) again=1 ;; esac ;;
      esac
    done ;;
  git)
    for a in "$@"; do
      if (( skip )); then skip=0; continue; fi
      case $a in -C|-c|--git-dir|--work-tree|--namespace|--exec-path) skip=1 ;; -*) ;; clone) again=1; break ;; *) break ;; esac
    done ;;
esac
(( again )) || exec "$real" "$@"
wait=${OMACVM_RETRY_SECONDS:-10}
for try in 1 2 3; do
  "$real" "$@" && exit 0
  rc=$?
  (( try < 3 && rc <= 128 )) || exit "$rc"   # above 128: killed by a signal
  echo "OmacVM: ${real##*/} failed (exit $rc), try $((try + 1)) of 3 in $((try * wait)) s" >&2
  sleep $((try * wait))
done
EOF
    chmod 755 "$WRAP_DIR/$t"
  done
}
remove_helpers() {
  local t
  rm -f "$SUDOERS"
  for t in pacman git; do
    if grep -qs "OmacVM retry wrapper" "$WRAP_DIR/$t"; then rm -f "$WRAP_DIR/$t"; fi
  done
  return 0
}
# ---- end of the install helpers ----
install_helpers
trap remove_helpers EXIT

log "system update"
pacman -Syu --noconfirm >/dev/null 2>&1 || true

log "omarchy-mac (channel ${OMARCHY_MAC_CHANNEL:-rc})"
{
  cat <<EOF
#!/bin/bash
set -o pipefail
cd ~
[[ -d ~/.local/share/omarchy/.git ]] || git clone https://github.com/omacom/omarchy-mac.git ~/.local/share/omarchy
cd ~/.local/share/omarchy
echo "omarchy-mac \$(cat version) \$(git rev-parse --short HEAD)"
EOF
  # Quoted for the shell: a name may hold quotes, $ or backticks.
  printf 'export OMARCHY_USER_NAME=%q\nexport OMARCHY_USER_EMAIL=%q\n' "$OMA_FULLNAME" "${OMA_EMAIL:-}"
  cat <<EOF
bash install.sh --channel ${OMARCHY_MAC_CHANNEL:-rc} < /dev/null
echo "INSTALL-EXIT=\$?"
EOF
} > "$H/.omacvm-install.sh"
chown "$U:$U" "$H/.omacvm-install.sh"; chmod +x "$H/.omacvm-install.sh"
L=/var/log/omacvm-omarchy-install.log
systemctl reset-failed omacvm-omarchy-install 2>/dev/null || true
systemd-run --uid="$U" --gid="$U" --unit=omacvm-omarchy-install -p WorkingDirectory="$H" \
  -E HOME="$H" -E USER="$U" -E LANG=en_US.UTF-8 -E TERM=xterm-256color ${SETENV[@]+"${SETENV[@]}"} \
  /bin/bash -c "$H/.omacvm-install.sh > '$H/.omacvm-install.log' 2>&1"
# The installer's output as it comes (OmacVM.app sends progress.sh first: then
# with its package progress), until the installer is done.
declare -F pac_progress >/dev/null || pac_progress() { sed -u 's/\x1b\[[0-9;]*m//g' | grep --line-buffered -E '^==>' || true; }
declare -F cache_watch >/dev/null || cache_watch() { :; }
# sed -u passes whole lines only, so cache_watch's lines never land in the
# middle of one (tail writes what it reads, also half lines).
{
  # 2>/dev/null on the subshell: no "Terminated" line when tail is stopped.
  ( tail -n +1 -F "$H/.omacvm-install.log" & echo $! > /run/omacvm-install-tail.pid; wait ) 2>/dev/null | sed -u '' &
  cache_watch /var/cache/pacman/pkg & w=$!
  while systemctl is-active -q omacvm-omarchy-install; do sleep 2; done
  sleep 1; kill "$w" 2>/dev/null || true
  kill "$(cat /run/omacvm-install-tail.pid 2>/dev/null)" 2>/dev/null ||
    pkill -f "tail .*-F $H/.omacvm-install.log" || true
} | pac_progress /dev/null
rm -f /run/omacvm-install-tail.pid
mv "$H/.omacvm-install.log" "$L"; rm -f "$H/.omacvm-install.sh"
grep -q 'INSTALL-EXIT=0' "$L" || { tail -30 "$L"; echo "omarchy-mac install failed, full log: $L" >&2; exit 1; }
# Omarchy turns on its firewall (deny inbound). This SSH session survives, the
# next ones from the Mac would not: let the Mac's VM network reach SSH. ufw may
# fail to apply the rule live right after the install ("problem running"); it
# is stored and active from the next boot, which is what counts.
net="${SSH_CLIENT%% *}"; net="${net%.*}.0/24"
ufw allow from "$net" to any port 22 proto tcp comment "omacvm: ssh from the Mac" >/dev/null 2>&1 || true
ufw show added 2>/dev/null | grep -q "omacvm: ssh from the Mac" || { echo "could not add the SSH firewall rule" >&2; exit 1; }
log "Omarchy installed ($(cat "$H/.local/share/omarchy/version" 2>/dev/null))"
