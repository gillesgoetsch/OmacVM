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
