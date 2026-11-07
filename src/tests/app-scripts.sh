#!/bin/bash
# Every script OmacVM.app runs from its Contents/Resources/scripts is in the
# app: the ones its Swift code starts (launch(script:), Paths.scripts), the
# ones those run or source ($HERE/...), and the ones omacvm runs inside an
# installed app (src/). app/scripts/build-app.sh installs them (its
# "install -m755 ... Resources/scripts/" lines) and src/release/release.sh's
# APP_SCRIPTS names the same list (it compares a release app's scripts with
# M's). A script left out fails only in a built app: test apps packed by
# copying app/scripts/*.sh had it, so the move's card failed at once in a
# from-source build (move-vm.sh, 3.4.0).
#   src/tests/app-scripts.sh       the lists, from the source
#   src/tests/app-scripts.sh APP   also APP's own Contents/Resources/scripts (build-app.sh runs this)
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
APP=${1:-}
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
words() { tr ' ' '\n' | LC_ALL=C sort -u | grep . | tr '\n' ' ' | sed 's/ $//'; }

# What the app's Swift code starts (the test programs' sources left out).
swift=$(find "$R/app/app/Sources" -name '*.swift' ! -path '*-tests/*' -print0 |
  LC_ALL=C xargs -0 grep -h -E 'launch\(script:|Paths\.scripts' |
  LC_ALL=C grep -o -E '"[a-z0-9-]+\.sh"' | tr -d '"' | words)
# What omacvm runs inside an installed app (src/lib/app.sh, make-image.sh ...).
cli=$(find "$R/src" -name '*.sh' ! -path "$R/src/tests/*" -print0 |
  LC_ALL=C xargs -0 grep -h -o -E 'Resources/scripts/[a-z0-9-]+\.sh|APPSCRIPTS/[a-z0-9-]+\.sh|local script=[a-z0-9-]+\.sh|script=[a-z0-9-]+\.sh;' |
  LC_ALL=C grep -o -E '[a-z0-9-]+\.sh' | words)
# And what those run or source next to themselves, until nothing new comes.
need=$(echo "$swift $cli" | words)
while :; do
  more=$need
  for s in $need; do
    [[ -f $R/app/scripts/$s ]] || continue
    more="$more $(LC_ALL=C grep -o -E '\$HERE/[a-z0-9-]+\.sh' "$R/app/scripts/$s" | sed 's|.*/||' | tr '\n' ' ')"
  done
  more=$(echo "$more" | words)
  [[ $more == "$need" ]] && break
  need=$more
done
# The reading itself works: the app starts create-vm.sh, which sources vm-common.sh.
[[ " $swift " == *" create-vm.sh "* && " $need " == *" vm-common.sh "* ]] &&
  ok "read: the app starts $swift; omacvm runs ${cli:-none}; all with what they run: $need" ||
  bad "read: the scripts the app starts were not found in its sources ('$swift', '$need')"

# build-app.sh's install lines (as release-script.sh reads them) and release.sh's list.
# shellcheck disable=SC2016
installed=$(awk '/install -m755 "\$ROOT\/scripts\// { f = 1 } f { print; if (!/\\$/) exit }' "$R/app/scripts/build-app.sh" |
  grep -o '\$ROOT/scripts/[^"]*' | sed 's|.*/||' | words)
release=$(sed -n 's/^APP_SCRIPTS=(\(.*\))/\1/p' "$R/src/release/release.sh" | words)
[[ -n $installed ]] && ok "build-app.sh installs: $installed" || bad "build-app.sh: no install -m755 \"\$ROOT/scripts/...\" lines found"
for s in $need; do
  [[ -f $R/app/scripts/$s ]] || { bad "$s: the app runs it, but there is no app/scripts/$s"; continue; }
  [[ " $installed " == *" $s "* ]] && ok "$s: build-app.sh puts it into the app" ||
    bad "$s: the app runs it, but build-app.sh does not put it into Contents/Resources/scripts"
done
for s in $installed; do [[ -f $R/app/scripts/$s ]] || bad "build-app.sh installs $s, which is not in app/scripts"; done
[[ $release == "$installed" ]] && ok "release.sh APP_SCRIPTS = build-app.sh's list" ||
  bad "release.sh APP_SCRIPTS ($release) is not build-app.sh's list ($installed): a release app would not match M"

# A built app: every one of them there, as a file the app can run.
if [[ -n $APP ]]; then
  d=$APP/Contents/Resources/scripts
  for s in $need; do
    if [[ -f $d/$s && ! -L $d/$s && $(stat -f %Lp "$d/$s") == 755 ]]; then ok "app: $s"
    else bad "app: no $s in $d (or not a plain file at mode 755)"; fi
  done
fi
exit $fail
