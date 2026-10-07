# OmacVM's versions, compared (bash 3.2; sourced by app.sh, so by every
# command, and by the omacvm entry script).
#   version_cmp A B      -1, 0 or 1: A is older than, the same as or newer than B.
#                        Numbers by value (3.0.10 is newer than 3.0.9; 3.0 is
#                        3.0.0); a label after them is a pre-release, older than
#                        the release (3.0.5-rc1 < 3.0.5, rc9 < rc10, beta < rc);
#                        "+build" is ignored; a leading v too. Status 2 (and
#                        nothing printed) when either is no version ("", "main").
#   version_lt A B       A is older than B (status 1 when either is no version)
#   omacvm_downgrade CMD VM HAD NOW
#                        the run must stop: VM has OmacVM HAD, newer than this
#                        omacvm's NOW, and --allow-downgrade (OMACVM_ALLOW_DOWNGRADE=1)
#                        was not given. Says why and what to run instead (stderr).
#   omacvm_app_newer NOW the installed OmacVM.app (app_bundle) is newer than NOW:
#                        prints "APP<TAB>VERSION"

version_cmp() {
  awk -v a="$1" -v b="$2" '
    # parse(S, NUM, LABEL): the numbers of S into NUM[1..n] (returned n, 0: no
    # version) and its pre-release label, split into digit and other runs,
    # into LABEL[1..LABEL[0]].
    function parse(s, num, lab,   n, i, x, t) {
      sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); sub(/^[vV]/, "", s)
      sub(/\+.*$/, "", s)
      if (!match(s, /^[0-9]+(\.[0-9]+)*/)) return 0
      n = split(substr(s, 1, RLENGTH), x, ".")
      for (i = 1; i <= n; i++) num[i] = x[i] + 0
      t = substr(s, RLENGTH + 1); lab[0] = 0
      while (t != "") {
        if (match(t, /^[0-9]+/) || match(t, /^[A-Za-z]+/)) {
          lab[++lab[0]] = substr(t, 1, RLENGTH); t = substr(t, RLENGTH + 1)
        } else t = substr(t, 2)   # . - _ ~ space and the like only separate
      }
      return n
    }
    function isnum(s) { return s ~ /^[0-9]+$/ }
    BEGIN {
      n = parse(a, x, la); m = parse(b, y, lb)
      if (!n || !m) exit 2
      for (i = 1; i <= (n > m ? n : m); i++) {
        p = (i <= n ? x[i] : 0); q = (i <= m ? y[i] : 0)
        if (p < q) { print -1; exit } if (p > q) { print 1; exit }
      }
      # The same numbers: a release is newer than its pre-releases.
      if (!la[0] && !lb[0]) { print 0; exit }
      if (!la[0]) { print 1; exit } if (!lb[0]) { print -1; exit }
      for (i = 1; i <= la[0] && i <= lb[0]; i++) {
        p = la[i]; q = lb[i]
        if (isnum(p) && isnum(q)) { p += 0; q += 0; if (p < q) { print -1; exit } if (p > q) { print 1; exit } continue }
        if (isnum(p)) { print -1; exit } if (isnum(q)) { print 1; exit }   # numbers before words
        p = tolower(p); q = tolower(q)
        if (p < q) { print -1; exit } if (p > q) { print 1; exit }
      }
      print (la[0] < lb[0] ? -1 : la[0] > lb[0] ? 1 : 0)
    }'
}

version_lt() { [[ $(version_cmp "$1" "$2") == -1 ]]; }

omacvm_app_newer() {   # NOW
  local a v
  declare -F app_bundle >/dev/null || return 1
  a=$(app_bundle) || return 1
  v=$(app_version "$a") || return 1
  version_lt "$1" "$v" || return 1
  printf '%s\t%s\n' "$a" "$v"
}

omacvm_downgrade() {   # CMD VM HAD NOW
  local cmd=$1 vm=$2 had now=$4 me how a av
  had=$(printf %s "$3" | tr -cd '[:alnum:].+_~-' | cut -c1-32)   # what the VM says: untrusted
  [[ -n $had && -n $now ]] && version_lt "$now" "$had" || return 1
  [[ ${OMACVM_ALLOW_DOWNGRADE:-} == 1 ]] && {
    printf 'omacvm %s: --allow-downgrade: %s goes back from OmacVM %s to %s\n' "$cmd" "$vm" "$had" "$now" >&2
    return 1
  }
  # Which omacvm this is: OmacVM.app's own copy runs from a temporary copy.
  me=${OMACVM_APP_CLI:-${R:+$R/omacvm}}
  if [[ $me == */Contents/Resources/omacvm/omacvm ]]; then
    how="update OmacVM.app first (Check Now in OmacVM on the Mac), or use an omacvm with OmacVM $had or newer"
  else
    how="run \`omacvm update\` first (it brings this omacvm up to date)"
    # update has pulled already: this checkout is as far as it goes (a branch,
    # a tag, local changes, or a main behind the VM's release).
    [[ $cmd != update ]] || how="use an omacvm with OmacVM $had or newer (this checkout did not move past $now)"
    if declare -F app_bundle >/dev/null && a=$(app_bundle) && av=$(app_version "$a") && ! version_lt "$av" "$had"; then
      how="use the omacvm of OmacVM.app ($a/Contents/Resources/omacvm/omacvm) or $how"
    fi
  fi
  printf 'omacvm %s: %s has OmacVM %s, this omacvm is %s%s: it does not go back to an older OmacVM, nothing was changed. To go on, %s. Going back on purpose: --allow-downgrade.\n' \
    "$cmd" "$vm" "$had" "$now" "${me:+ ($me)}" "$how" >&2
  return 0
}
