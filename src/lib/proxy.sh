# The Mac's proxy, for building a VM behind one (#122). Sourced by
# app/scripts/vm-common.sh and src/cmd/build.sh; macOS's bash 3.2.
#
# proxy_detect looks in the Mac's environment first (http_proxy, https_proxy,
# all_proxy, no_proxy, either case), else in macOS's network settings
# (scutil --proxy: Web proxy, Secure web proxy, SOCKS proxy, bypass list).
# It sets:
#   PROXY_HTTP PROXY_HTTPS PROXY_ALL  scheme://[user:password@]host:port, or empty
#   PROXY_NO                          the bypass list (comma separated), or empty
#   PROXY_FROM                        "the environment", "macOS's network settings" or empty
#   PROXY_NOTE                        a setting that was found and is not used (PAC, WPAD)
# OMACVM_PROXY=off: no proxy. OMACVM_PROXY_SCUTIL=FILE: scutil's output from FILE (tests).
#
# A proxy on the Mac's own 127.0.0.1 is reached from the VM through the Mac's
# address on the VM network (OmacVM.app: 10.0.2.2, the patched libslirp lets
# the port through, see proxy_ports); one on another host is used as it is.

proxy_none() { PROXY_HTTP="" PROXY_HTTPS="" PROXY_ALL="" PROXY_NO="" PROXY_FROM="" PROXY_NOTE=""; }

# _proxy_split URL [DEFAULT_SCHEME]: sets _ps (scheme) _pc (user:password@ or
# empty) _ph (host, IPv6 in brackets) _pp (port). Returns 1 when URL is no
# usable proxy (no host, a bad port, characters a shell or systemd would
# change: quotes, $, `, \, spaces).
_proxy_split() {
  local u=$1 rest hp
  case $u in ''|*[!A-Za-z0-9._~%+:@/\[\]-]*) return 1 ;; esac
  _ps=${2:-http}
  case $u in *://*) _ps=$(printf '%s' "${u%%://*}" | tr '[:upper:]' '[:lower:]'); rest=${u#*://} ;; *) rest=$u ;; esac
  case $_ps in socks) _ps=socks5h ;; http|https|socks4|socks4a|socks5|socks5h) ;; *) return 1 ;; esac
  rest=${rest%%/*}
  _pc=""
  case $rest in *@*) _pc=${rest%@*}@; hp=${rest##*@} ;; *) hp=$rest ;; esac
  case $hp in
    \[*\]:*) _ph=${hp%%]:*}]; _pp=${hp##*]:} ;;
    \[*\]) _ph=$hp; _pp="" ;;
    *:*:*) return 1 ;;   # IPv6 without brackets
    *:*) _ph=${hp%%:*}; _pp=${hp##*:} ;;
    *) _ph=$hp; _pp="" ;;
  esac
  [[ -n $_pp ]] || _pp=1080   # curl's default proxy port
  case $_ph in ''|'[]') return 1 ;; esac
  case $_pp in *[!0-9]*) return 1 ;; esac
  (( _pp >= 1 && _pp <= 65535 )) || return 1
  return 0
}

# _proxy_url URL [DEFAULT_SCHEME]: the URL as scheme://[cred@]host:port, or nothing.
_proxy_url() { _proxy_split "$@" && printf '%s://%s%s:%s' "$_ps" "$_pc" "$_ph" "$_pp"; }

# True for the Mac itself: 127.x, localhost, ::1, 0.0.0.0.
_proxy_loopback() {
  case $1 in 127.*|localhost|LOCALHOST|'[::1]'|::1|0.0.0.0) return 0 ;; esac
  return 1
}

# proxy_scutil_parse: scutil --proxy's output on stdin -> KEY=VALUE lines of the
# top-level keys only (the __SCOPED__ dictionaries repeat them per interface),
# and Exception=ITEM for each bypass entry.
proxy_scutil_parse() {
  awk '
    /<dictionary> \{|<array> \{/ { depth++; if (depth == 2 && $1 == "ExceptionsList") inex = 1; next }
    /^[[:space:]]*\}/ { if (depth == 2) inex = 0; depth--; next }
    depth == 1 && / : / { k = $1; sub(/^[^:]* : /, ""); print k "=" $0; next }
    depth == 2 && inex && / : / { sub(/^[^:]* : /, ""); print "Exception=" $0 }
  '
}

# _proxy_no_from_exceptions: Exception= lines -> a no_proxy list. "*.local"
# becomes ".local", "169.254/16" becomes "169.254.0.0/16" (curl 7.86+ reads CIDR).
_proxy_no_from_exceptions() {
  local e out="" ip bits
  while IFS= read -r e; do
    e=${e#Exception=}
    case $e in '*.'*) e=${e#\*} ;; esac
    case $e in
      */*) ip=${e%/*}; bits=${e#*/}
           while [[ $(tr -cd . <<<"$ip" | wc -c | tr -d ' ') -lt 3 ]]; do ip=$ip.0; done
           e=$ip/$bits ;;
    esac
    case $e in ''|*[!A-Za-z0-9._:/-]*) continue ;; esac
    out=${out:+$out,}$e
  done
  printf '%s' "$out"
}

proxy_detect() {
  proxy_none
  [[ ${OMACVM_PROXY:-} == off ]] && return 0
  local h=${http_proxy:-${HTTP_PROXY:-}} s=${https_proxy:-${HTTPS_PROXY:-}} a=${all_proxy:-${ALL_PROXY:-}}
  if [[ -n $h || -n $s || -n $a ]]; then
    PROXY_FROM="the environment"
    [[ -z $h ]] || PROXY_HTTP=$(_proxy_url "$h") || PROXY_NOTE="http_proxy is not a proxy address OmacVM can pass on: $h"
    [[ -z $s ]] || PROXY_HTTPS=$(_proxy_url "$s") || PROXY_NOTE="https_proxy is not a proxy address OmacVM can pass on: $s"
    [[ -z $a ]] || PROXY_ALL=$(_proxy_url "$a") || PROXY_NOTE="all_proxy is not a proxy address OmacVM can pass on: $a"
    PROXY_NO=${no_proxy:-${NO_PROXY:-}}
    case $PROXY_NO in *[!A-Za-z0-9._:/,*-]*) PROXY_NO="" ;; esac
    [[ -n $PROXY_HTTP$PROXY_HTTPS$PROXY_ALL ]] || PROXY_FROM=""
    return 0
  fi
  local out
  if [[ -n ${OMACVM_PROXY_SCUTIL:-} ]]; then out=$(proxy_scutil_parse < "$OMACVM_PROXY_SCUTIL")
  else out=$(scutil --proxy 2>/dev/null | proxy_scutil_parse); fi
  _pk() { sed -n "s/^$1=//p" <<<"$out" | head -1; }
  if [[ $(_pk HTTPEnable) == 1 && -n $(_pk HTTPProxy) ]]; then PROXY_HTTP=$(_proxy_url "$(_pk HTTPProxy):$(_pk HTTPPort)") || true; fi
  if [[ $(_pk HTTPSEnable) == 1 && -n $(_pk HTTPSProxy) ]]; then PROXY_HTTPS=$(_proxy_url "$(_pk HTTPSProxy):$(_pk HTTPSPort)") || true; fi
  if [[ $(_pk SOCKSEnable) == 1 && -n $(_pk SOCKSProxy) ]]; then PROXY_ALL=$(_proxy_url "socks5h://$(_pk SOCKSProxy):$(_pk SOCKSPort)") || true; fi
  if [[ $(_pk ProxyAutoConfigEnable) == 1 ]]; then
    PROXY_NOTE="macOS uses a proxy auto-config (PAC) file ($(_pk ProxyAutoConfigURLString)); OmacVM does not read PAC files: set http_proxy and https_proxy in the terminal you build from, or a fixed proxy in System Settings > Network"
  elif [[ $(_pk ProxyAutoDiscoveryEnable) == 1 && -z $PROXY_HTTP$PROXY_HTTPS$PROXY_ALL ]]; then
    PROXY_NOTE="macOS finds its proxy automatically (WPAD); OmacVM does not: set http_proxy and https_proxy in the terminal you build from, or a fixed proxy in System Settings > Network"
  fi
  if [[ -n $PROXY_HTTP$PROXY_HTTPS$PROXY_ALL ]]; then
    PROXY_FROM="macOS's network settings"
    PROXY_NO=$(grep '^Exception=' <<<"$out" | _proxy_no_from_exceptions)
  fi
  return 0
}

# proxy_summary: one line for the build's output, empty without a proxy.
proxy_summary() {
  local l=""
  [[ -z $PROXY_HTTP ]] || l="http $(_proxy_redact "$PROXY_HTTP")"
  [[ -z $PROXY_HTTPS ]] || l="${l:+$l, }https $(_proxy_redact "$PROXY_HTTPS")"
  [[ -z $PROXY_ALL ]] || l="${l:+$l, }all $(_proxy_redact "$PROXY_ALL")"
  [[ -z $l ]] || printf '%s (from %s)' "$l" "$PROXY_FROM"
}
_proxy_redact() { _proxy_split "$1" && printf '%s://%s%s:%s' "$_ps" "${_pc:+***@}" "$_ph" "$_pp"; }

# proxy_ports: the ports of the proxies on the Mac's 127.0.0.1, comma separated.
proxy_ports() {
  local u out=""
  for u in "$PROXY_HTTP" "$PROXY_HTTPS" "$PROXY_ALL"; do
    _proxy_split "$u" 2>/dev/null && _proxy_loopback "$_ph" || continue
    case ,$out, in *,"$_pp",*) ;; *) out=${out:+$out,}$_pp ;; esac
  done
  printf '%s' "$out"
}

# proxy_guest_env MAC_ADDR: the VM's proxy variables, KEY=VALUE lines (valid
# for environment.d, a shell's `set -a; .` and systemd-run -E). A proxy on the
# Mac's 127.0.0.1 becomes MAC_ADDR:port; with MAC_ADDR empty (a VM network
# that cannot reach the Mac's 127.0.0.1) it is left out. Nothing without a proxy.
proxy_guest_env() {
  local mac=$1 v u n g out="" no
  for v in http https all; do
    case $v in http) u=$PROXY_HTTP ;; https) u=$PROXY_HTTPS ;; all) u=$PROXY_ALL ;; esac
    _proxy_split "$u" 2>/dev/null || continue
    g=$_ph
    if _proxy_loopback "$_ph"; then [[ -n $mac ]] || continue; g=$mac; fi
    n="$_ps://$_pc$g:$_pp"
    out+="${v}_proxy=$n"$'\n'"$(tr '[:lower:]' '[:upper:]' <<<"$v")_PROXY=$n"$'\n'
  done
  [[ -n $out ]] || return 0
  # The VM's own addresses and the Mac's (OmacVM's helpers) never go through it.
  no="localhost,127.0.0.1,::1${mac:+,$mac}${PROXY_NO:+,$PROXY_NO}"
  printf '# The Mac'"'"'s proxy when this VM was built (OmacVM, from %s).\n%sno_proxy=%s\nNO_PROXY=%s\n' \
    "$PROXY_FROM" "$out" "$no" "$no"
}
