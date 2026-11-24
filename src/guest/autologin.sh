# Autologin as SDDM sees it, whoever wrote the file (sourced by
# guest/install.sh and guest/check.sh; vm_probe in src/lib/vm.sh has the same
# rule inline, for VMs without OmacVM yet). SDDM reads
# /usr/lib/sddm/sddm.conf.d/*.conf, then /etc/sddm.conf.d/*.conf, then
# /etc/sddm.conf; the last User= of an [Autologin] section wins.
# SDDM_ROOT: another root, for tests.
SDDM_ROOT=${SDDM_ROOT:-}
OMACVM_AUTOLOGIN_CONF=$SDDM_ROOT/etc/sddm.conf.d/20-omacvm-autologin.conf

sddm_user_of() {   # FILE... -> the user they log in ("" none)
  cat "$@" 2>/dev/null | awk '/^[[:space:]]*\[/ { s = ($0 ~ /^[[:space:]]*\[Autologin\]/) }
    s && /^[[:space:]]*User[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); u = $0 }
    END { print u }'
}

sddm_autologin_user() {
  sddm_user_of "$SDDM_ROOT"/usr/lib/sddm/sddm.conf.d/*.conf "$SDDM_ROOT"/etc/sddm.conf.d/*.conf "$SDDM_ROOT"/etc/sddm.conf
}

# The files besides OmacVM's own in /etc/sddm.conf.d that log someone in
# (an Omarchy install, a migration), one per line.
sddm_autologin_others() {
  local f
  for f in "$SDDM_ROOT"/etc/sddm.conf.d/*.conf; do
    [[ -f $f && $f != "$OMACVM_AUTOLOGIN_CONF" ]] || continue
    [[ -n $(sddm_user_of "$f") ]] && echo "$f"
  done
  return 0
}

# SDDM's last user ([Last] User= in /var/lib/sddm/state.conf). Omarchy's login
# screen has no user field: it sends that user's name with the password.
# Omarchy's ISO writes it; a VM nobody has logged in to yet can have none (or
# the image's placeholder), and the screen then sends an empty name, so no
# password works (#837).
SDDM_STATE=$SDDM_ROOT/var/lib/sddm/state.conf

sddm_last_user() {
  awk '/^[[:space:]]*\[/ { s = ($0 ~ /^[[:space:]]*\[Last\]/) }
    s && /^[[:space:]]*User[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); u = $0 }
    END { print u }' "$SDDM_STATE" 2>/dev/null
}

sddm_is_user() {   # NAME: a user of this system (its own /etc/passwd)
  [[ -n $1 ]] && awk -F: -v n="$1" '$1 == n { f = 1 } END { exit !f }' "$SDDM_ROOT/etc/passwd" 2>/dev/null
}

# sddm_last_user_set USER: SDDM's last user becomes USER when it names no user
# of this system; the rest of the file stays (a Session= missing too gets
# Omarchy's session). Says what it changed. Nothing without SDDM's folder.
# The file is replaced by a rename: a link there is replaced, never followed.
sddm_last_user_set() {
  local u=$1 cur d t s sess=""
  cur=$(sddm_last_user)
  sddm_is_user "$cur" && return 0
  d=$(dirname "$SDDM_STATE")
  [[ -d $d && ! -L $d && ! -d $SDDM_STATE ]] || return 0
  for s in /usr/local/share/wayland-sessions/omarchy.desktop /usr/share/wayland-sessions/omarchy.desktop \
    /usr/share/wayland-sessions/hyprland-uwsm.desktop; do
    [[ -f $SDDM_ROOT$s ]] && { sess=$s; break; }
  done
  t=$(mktemp "$d/.state.conf.XXXXXX") || return 1
  { [[ ! -f $SDDM_STATE ]] || cat "$SDDM_STATE"; } | awk -v u="$u" -v sess="$sess" '
    function close_last() { if (inl) { if (!hs && sess != "") print "Session=" sess; if (!hu) print "User=" u; inl = 0 } }
    /^[[:space:]]*\[/ { close_last(); if ($0 ~ /^[[:space:]]*\[Last\]/) { inl = 1; seen = 1; hu = 0; hs = 0 } print; next }
    inl && /^[[:space:]]*User[[:space:]]*=/ { if (!hu) print "User=" u; hu = 1; next }
    inl && /^[[:space:]]*Session[[:space:]]*=[[:space:]]*[^[:space:]]/ { hs = 1 }
    inl && /^[[:space:]]*Session[[:space:]]*=[[:space:]]*$/ { next }
    { print }
    END { close_last(); if (!seen) { print "[Last]"; if (sess != "") print "Session=" sess; print "User=" u } }' > "$t" || { rm -f "$t"; return 1; }
  chmod 644 "$t"
  chown sddm:sddm "$t" 2>/dev/null || true
  mv -f "$t" "$SDDM_STATE" || { rm -f "$t"; return 1; }
  echo "login screen: Omarchy's login screen logs in as $u now (SDDM's last user named ${cur:-nobody})"
}
