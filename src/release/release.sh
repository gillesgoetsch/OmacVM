#!/bin/bash
# An OmacVM release, step by step (docs/releasing.md). Each step checks what
# it made and stops on the first problem; run it again from that step.
#
#   src/release/release.sh [--dry-run] [--yes] VERSION [STEP...]
#   src/release/release.sh VERSION rollback-prep | rollback | clean
#
# Steps (all of them, in this order, when none is given):
#   check     tools, the release key in the Keychain, the Developer ID, the
#             notary profile, the release PR and its CI, the release text
#   bump      the release commit on the PR's branch: src/VERSION and the
#             CHANGELOG heading (dry run: a local commit, nothing pushed)
#   merge     the release PR into main with a merge commit M (dry run: M is
#             the local commit)
#   build     build-app.sh --release in a worktree at M; build tests must pass
#             (or an app built at M on another Mac, checked and signed here:
#             OMACVM_RELEASE_APP_FROM)
#   notarize  Apple's notary service, then staple the ticket into the app
#   package   OmacVM-VERSION.zip + .sha256, OmacVM-appcast.json + .sig (the
#             app feed), omacvm-manifest.json + .sig (control centre)
#   verify    every file read back as the app, the command line and the Bridge
#             read them
#   image     the app's prebuilt VM (make-image.sh app), its manifest signed
#             (on the runtime build in the worktree, or on the app's own
#             runtime when the app came from OMACVM_RELEASE_APP_FROM)
#   e2e       the gate: the person's path end to end on the test Mac
#             (src/tests/e2e/cc-switches.sh) passed for a test identity
#             build of M; publish refuses without it
#   moves     (3.4.0 on) the move to Omarchy 4.5 on real 4.0 VMs with faults
#             (src/tests/e2e/move-45.sh) passed, its files as in M; publish
#             refuses without it, and without the prebuilt image (Omarchy 4.5)
#   publish   the prebuilt pre-release first (only an image that passed step
#             image for M, its parts still the signed manifest's; uploaded at
#             M, then checked on GitHub part by part), then tag M and the
#             GitHub release (latest) (dry run: prints the commands only)
#   after     download what GitHub serves and check it again
# Other commands:
#   rollback-prep  a signed feed for the release before (kept, not uploaded)
#   rollback       the release before is "latest" again, this one's feeds go
#   clean          remove this release's worktrees (keeps the output folder)
#
# --dry-run: nothing leaves this Mac (no push, merge, tag or upload); the
# release key and the notary service are used for real. --yes: no question
# before merge, publish and rollback (for a scripted run after the go).
# Output and times: ~/omacvm-work/release-VERSION/{dry-run,release}/
# (OMACVM_RELEASE_OUT). Settings: OMACVM_SIGN_ID (Developer ID, required),
# OMACVM_RELEASE_PR (77), OMACVM_NOTARY_PROFILE (omacvm),
# OMACVM_RELEASE_NOTES (release-text.md next to the output folders),
# OMACVM_RELEASE_TITLE, OMACVM_KOSMICKRISP_FROM (KosmicKrisp built on a Mac
# that can: app/runtime/import-kosmickrisp.sh), OMACVM_RELEASE_RUNTIME_FROM (a runtime/.build to
# start from; build-app.sh rebuilds it unless its inputs match),
# OMACVM_RELEASE_APP_FROM (an absolute path: a folder with OmacVM.app built
# at M on a Mac without the keys, and its build.log: checked against M and
# signed here, not built; step image then runs the image VM on that app's own
# runtime; docs/releasing.md says what is checked and what is trusted),
# OMACVM_RELEASE_IMAGE_FROM (a folder with an image of this version: used
# instead of building one; one made before the run comes unsigned, its parts
# are checked against its manifest and the key signs it here; from 3.4.0 its
# manifest's "commit" must be M or a commit whose image files, IMAGE_PATHS,
# are M's),
# OMACVM_RELEASE_UNNOTARIZED=1 (release
# without notarization, as 2.x), OMACVM_RELEASE_FROM (dry run only: the
# commit to start from instead of the PR's head). The e2e gate:
# OMACVM_RELEASE_E2E_RESULT (a result.json of cc-switches.sh, default
# OUT/e2e/result.json), or OMACVM_E2E_SSH + OMACVM_E2E_ARGS (run it on the
# test Mac now: src/tests/e2e/remote.sh), or OMACVM_RELEASE_E2E_OVERRIDE=
# "<why>" (publish without it; written to the output folder's
# e2e-override.log and said again at publish and after). The moves gate
# (3.4.0 on): OMACVM_RELEASE_MOVES_RESULT (move-45.sh --summary's
# result.json, default OUT/moves/result.json) or OMACVM_RELEASE_MOVES_OVERRIDE
# "<why>" (logged as the e2e override); OMACVM_RELEASE_NO_IMAGE="<why>"
# publishes 3.4.0 or later without a prebuilt image (new VMs then build here).
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
GH_REPO=gillesgoetsch/omacvm
die() { printf 'release.sh: %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

DRY=0; YES=0
while [[ ${1:-} == --* ]]; do
  case $1 in
    --dry-run) DRY=1 ;;
    --yes) YES=1 ;;
    *) die "unknown option $1" ;;
  esac
  shift
done
VERSION=${1:-}
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 2; }
shift
STEPS=("$@")
(( ${#STEPS[@]} )) || STEPS=(check bump merge build notarize package verify image e2e moves publish after)
# OMACVM_RELEASE_APP_FROM: an absolute path only; a relative one would name
# another folder for each folder release.sh is run from. The app brings its
# own runtime: none from OMACVM_RELEASE_RUNTIME_FROM beside it.
if [[ -n ${OMACVM_RELEASE_APP_FROM:-} ]]; then
  [[ $OMACVM_RELEASE_APP_FROM == /* ]] || die "OMACVM_RELEASE_APP_FROM must be an absolute path, not $OMACVM_RELEASE_APP_FROM"
  [[ -z ${OMACVM_RELEASE_RUNTIME_FROM:-} ]] ||
    die "OMACVM_RELEASE_APP_FROM brings the app's own runtime: unset OMACVM_RELEASE_RUNTIME_FROM"
fi

# release-key.sh signs with the Keychain's release key only inside this run.
export OMACVM_RELEASE_RUN=$VERSION
BASE=${OMACVM_RELEASE_OUT:-$HOME/omacvm-work/release-$VERSION}
if (( DRY )); then OUT=$BASE/dry-run; WT=$HOME/omacvm-rel-$VERSION-dry
else OUT=$BASE/release; WT=$HOME/omacvm-rel-$VERSION-build; fi
BUMP=$HOME/omacvm-rel-$VERSION-bump
FILES=$OUT/files
NOTES=${OMACVM_RELEASE_NOTES:-$BASE/release-text.md}
PR=${OMACVM_RELEASE_PR:-77}
PROFILE=${OMACVM_NOTARY_PROFILE:-omacvm}
TAG=v$VERSION
APP=$WT/app/dist/OmacVM.app
mkdir -p "$OUT" "$FILES"
STATE=$OUT/state

get() { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | tail -1; }
put() { echo "$1=$2" >> "$STATE"; }
ask() {   # the steps that change GitHub, unless --yes
  (( YES )) && return 0
  local a; read -r -p "release.sh: $1 [y/N] " a; [[ $a == y || $a == Y ]] || die "stopped"
}
gitr() { git -C "$R" "$@"; }
runs_in() {   # PATH: a process runs from there (not grep: it would find itself)
  local procs; procs=$(ps -ax -o args=)
  [[ $procs == *"$1"* ]]
}

# ---------- steps ----------

step_check() {
  local n=0 w
  fail() { printf '    FAIL %s\n' "$*"; n=$((n + 1)); }
  [[ $(uname -m) == arm64 ]] || fail "not an Apple Silicon Mac"
  for t in gh git python3 swift zstd shasum ditto codesign xcrun; do command -v "$t" >/dev/null || fail "no $t"; done
  gh auth status >/dev/null 2>&1 || fail "gh is not logged in"
  [[ -n ${OMACVM_SIGN_ID:-} ]] || fail "OMACVM_SIGN_ID is not set (the Developer ID's SHA-1)"
  if [[ -n ${OMACVM_SIGN_ID:-} ]]; then
    "$R/src/release/release-key.sh" team >/dev/null 2>&1 && note "Developer ID: team $("$R/src/release/release-key.sh" team)" ||
      fail "OMACVM_SIGN_ID is not a Developer ID Application identity here"
  fi
  # The release key: only that the item is there (-w would print it).
  security find-generic-password -s org.omacvm.release-key -a omacvm >/dev/null 2>&1 && note "release key: in the Keychain" ||
    fail "no release key in the Keychain (service org.omacvm.release-key; docs/release-keys.md)"
  [[ -f $R/src/lib/release-key.pub && -f $R/src/lib/release-key-spare.pub ]] || fail "no src/lib/release-key*.pub"
  # A release runtime has KosmicKrisp: built here, or brought from a Mac that
  # can build it (Xcode 26: the Mac mini), OMACVM_KOSMICKRISP_FROM.
  if [[ ${OMACVM_RUNTIME_KOSMICKRISP:-1} == 1 ]]; then
    if [[ -n ${OMACVM_KOSMICKRISP_FROM:-} ]]; then
      "$R/app/runtime/import-kosmickrisp.sh" "$OMACVM_KOSMICKRISP_FROM" --stamp >/dev/null &&
        note "KosmicKrisp from $OMACVM_KOSMICKRISP_FROM (stamp ok for this checkout)" || fail "OMACVM_KOSMICKRISP_FROM is not usable"
    elif "$R/app/runtime/build-kosmickrisp.sh" --check >/dev/null 2>&1; then
      note "KosmicKrisp: this Mac builds it"
    else
      fail "this Mac cannot build KosmicKrisp: OMACVM_KOSMICKRISP_FROM=DIR (built on the mini) or OMACVM_RUNTIME_KOSMICKRISP=0 (MoltenVK only)"
    fi
  else
    note "OMACVM_RUNTIME_KOSMICKRISP=0: the app has MoltenVK only"
  fi
  if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    note "notary profile $PROFILE: works"; put NOTARY 1
  else
    put NOTARY 0
    if (( DRY )) || [[ ${OMACVM_RELEASE_UNNOTARIZED:-} == 1 ]]; then
      note "no notary profile $PROFILE: the app will not be notarized (xcrun notarytool store-credentials $PROFILE)"
    else
      fail "no notary profile $PROFILE (xcrun notarytool store-credentials $PROFILE), or OMACVM_RELEASE_UNNOTARIZED=1"
    fi
  fi
  gitr fetch -q origin
  local head state
  head=$(gh pr view "$PR" -R "$GH_REPO" --json headRefName -q .headRefName 2>/dev/null) || fail "no PR #$PR"
  state=$(gh pr view "$PR" -R "$GH_REPO" --json state -q .state 2>/dev/null || true)
  [[ $state == OPEN ]] || fail "PR #$PR is $state"
  put HEAD_BRANCH "$head"
  note "release PR #$PR: $head at $(gitr rev-parse --short "origin/$head")"
  if ! gh pr checks "$PR" -R "$GH_REPO" >/dev/null 2>&1; then
    (( DRY )) && note "PR #$PR: CI not green (or still running)" || fail "PR #$PR: CI not green (gh pr checks $PR)"
  fi
  # awk reads to the end: an early exit would end git show with SIGPIPE, and
  # pipefail would stop the check (the CHANGELOG is larger than a pipe).
  w=$(gitr show "origin/$head:CHANGELOG.md" | awk -v h="## $VERSION (unreleased)" '$0 == h { f = 1; next } f && /^## / { f = 0 } f')
  [[ -n $w ]] || fail "CHANGELOG on $head has no \"## $VERSION (unreleased)\""
  if grep -qi 'pending' <<<"$w"; then
    (( DRY )) && note "CHANGELOG $VERSION still marks items as pending" || fail "CHANGELOG $VERSION still marks items as pending"
  fi
  # README items marked "(pending #N)" (or "(pending, no PR yet ...)") until their PR is in.
  if gitr show "origin/$head:README.md" | grep -i '(pending' >/dev/null; then   # not -q: see SIGPIPE above
    (( DRY )) && note "README still marks items as pending" || fail "README still marks items as pending"
  fi
  # The Mission Control plugin goes out at one of its released tags, never a
  # commit before its release (src/missioncontrol/sync.sh TAG).
  if gitr cat-file -e "origin/$head:src/missioncontrol/PIN" 2>/dev/null &&
     ! gitr show "origin/$head:src/missioncontrol/PIN" | "$R/src/missioncontrol/sync.sh" --released >/dev/null 2>&1; then
    (( DRY )) && note "src/missioncontrol/PIN on $head is no released plugin tag" ||
      fail "src/missioncontrol/PIN on $head is no released plugin tag (src/missioncontrol/sync.sh TAG)"
  fi
  if [[ -f $NOTES ]]; then
    grep -qi 'pending' "$NOTES" && { (( DRY )) && note "release text still marks items as pending" || fail "release text still has pending items ($NOTES)"; }
  else
    (( DRY )) && note "no release text at $NOTES yet" || fail "no release text at $NOTES"
  fi
  local prev; prev=$(gh release view -R "$GH_REPO" --json tagName -q .tagName 2>/dev/null || true)
  note "latest release now: ${prev:-none}"; put PREV "${prev#v}"
  [[ -e $HOME/.omacvm-user-testing ]] && note "$HOME/.omacvm-user-testing is set: the image step will not start a VM"
  (( n == 0 )) || die "check: $n problem(s)"
}

step_bump() {
  local head; head=$(get HEAD_BRANCH); [[ -n $head ]] || die "run the check step first"
  local dir=$BUMP; (( DRY )) && dir=$WT
  [[ -e $dir ]] && die "$dir exists: release.sh $VERSION clean (dry run) or remove it"
  gitr fetch -q origin
  # OMACVM_RELEASE_FROM: a dry run of another branch (what the PR will hold).
  local from="origin/$head"; (( DRY )) && from=${OMACVM_RELEASE_FROM:-$from}
  gitr worktree add -q --detach "$dir" "$from"
  echo "$VERSION" > "$dir/src/VERSION"
  sed -i '' "s/^## ${VERSION//./\\.} (unreleased)\$/## $VERSION/" "$dir/CHANGELOG.md"
  [[ $(git -C "$dir" diff --numstat | awk '{ a += $1; d += $2 } END { print a + 0, d + 0 }') == "2 2" ]] ||
    die "the release commit should change two lines (src/VERSION, CHANGELOG heading): $(git -C "$dir" diff --stat)"
  git -C "$dir" commit -q -am "Release $VERSION" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
  if ! git -C "$dir" merge-base --is-ancestor origin/main HEAD; then
    git -C "$dir" merge -q --no-edit origin/main || die "main does not merge cleanly into $head: fix it on the branch, then run bump again"
  fi
  put BUMPED "$(git -C "$dir" rev-parse HEAD)"
  if (( DRY )); then
    put M "$(git -C "$dir" rev-parse HEAD)"
    note "local release commit $(git -C "$dir" rev-parse --short HEAD) (not pushed)"
  else
    git -C "$dir" push -q origin "HEAD:$head"
    note "pushed $(git -C "$dir" rev-parse --short HEAD) to $head"
  fi
}

step_merge() {
  if (( DRY )); then note "dry run: M = $(get M) (local); real run: gh pr merge $PR --merge"; return; fi
  local bumped; bumped=$(get BUMPED); [[ -n $bumped ]] || die "run bump first"
  log "waiting for CI on #$PR"
  # The PR must show the release commit first, else --watch reads the last run.
  local i
  for ((i = 0; i < 60; i++)); do
    [[ $(gh pr view "$PR" -R "$GH_REPO" --json headRefOid -q .headRefOid) == "$bumped" ]] && break; sleep 5
  done
  sleep 20
  gh pr checks "$PR" -R "$GH_REPO" --watch --fail-fast >/dev/null || die "CI failed on #$PR"
  ask "merge #$PR into main (a merge commit)?"
  gh pr ready "$PR" -R "$GH_REPO" >/dev/null 2>&1 || true
  gh pr merge "$PR" -R "$GH_REPO" --merge
  gitr fetch -q origin
  local m; m=$(gitr rev-parse origin/main)
  [[ $(gitr rev-parse "$m^2" 2>/dev/null) == "$bumped" ]] || die "origin/main ($m) is not the merge of the release commit $bumped"
  put M "$m"
  [[ -e $WT ]] && die "$WT exists"
  gitr worktree add -q --detach "$WT" "$m"
  note "M = $m"
}

# The parts build-app.sh copies into the app from git at M that app_from
# compares with M: its "git archive ... omacvm src CHANGELOG.md" into
# Resources/omacvm, and its "install -m755 ... Contents/Resources/scripts/" of
# these app/scripts files (not the fonts and licence files it also copies). release-script.sh builds its stand-in app from build-app.sh's own
# lines, so a change there that is not made here too fails CI.
APP_ARCHIVE=(omacvm src CHANGELOG.md)
APP_SCRIPTS=(create-vm.sh prebuilt-vm.sh apply-vm.sh vm-common.sh update-vm.sh update-swap.sh move-vm.sh)
# The app's links outside Resources/omacvm: build-app.sh's (QEMU started under
# the app's name) and python's own.
APP_LINKS='./Contents/MacOS/OmacVM-VM -> ../Resources/runtime/bin/OmacVM
./Contents/Resources/python/bin/python3 -> python3.13'
# A folder's tree, one line per entry: type, mode, a file's sha256 or a link's
# target, path. Equal lists: the same names, bytes, modes and types.
tree_list() { (cd "$1" && find . -mindepth 1 -print | LC_ALL=C sort | while IFS= read -r f; do
  if [[ -L $f ]]; then echo "l $(stat -f %Lp "$f") $f -> $(readlink "$f")"
  elif [[ -d $f ]]; then echo "d $(stat -f %Lp "$f") $f"
  else echo "f $(stat -f %Lp "$f") $(shasum -a 256 < "$f" | cut -d' ' -f1) $f"; fi; done); }

# OMACVM_RELEASE_APP_FROM=DIR: OmacVM.app put together at M on another Mac (one
# without the keys), unsigned or ad hoc, with that build's log (DIR/OmacVM.app,
# DIR/build.log). Before anything signs it: its shape, id, commit and version;
# what step build and package-release.sh would refuse only after signing; and
# what build-app.sh copies from git, file by file against M. Then M's own
# sign-app.sh signs it. These checks catch mistakes; the binaries are trusted as
# the build Mac's own: step image runs its QEMU and tools here
# (docs/releasing.md, "An app built on another Mac").
app_from() {   # DIR M
  local from=$1 m=$2 a c p t x om=0 sc=0
  a=$from/OmacVM.app; c=$a/Contents; p=$c/Info.plist
  [[ -d $c && ! -L $a && -f $from/build.log ]] || die "OMACVM_RELEASE_APP_FROM: no OmacVM.app (a folder, not a link) or build.log in $from"
  # Its shape first, before anything reads a file: only files, folders and
  # links (a FIFO would hang shasum and ditto); outside omacvm (compared below)
  # only the two links above, so no path sign-app.sh signs leads out of the app;
  # nothing writable by group or others, no setuid or setgid. A copy over a
  # drive or share that drops links or modes stops here.
  x=$(cd "$a" && find . ! -type f ! -type d ! -type l -print) || die "OMACVM_RELEASE_APP_FROM: cannot read $a"
  [[ -z $x ]] || die "OMACVM_RELEASE_APP_FROM: not a file, folder or link: ${x%%$'\n'*}"
  x=$(cd "$a" && find . -type l ! -path './Contents/Resources/omacvm/*' -print | LC_ALL=C sort | while IFS= read -r f; do echo "$f -> $(readlink "$f")"; done) || die "OMACVM_RELEASE_APP_FROM: cannot read $a"
  [[ $x == "$APP_LINKS" ]] || die "OMACVM_RELEASE_APP_FROM: the app's links are not the two it should have (lost or changed in the copy?): ${x:-none}"
  x=$(cd "$a" && find . ! -type l \( -perm -0020 -o -perm -0002 -o -perm -4000 -o -perm -2000 \) -print) || die "OMACVM_RELEASE_APP_FROM: cannot read $a"
  [[ -z $x ]] || die "OMACVM_RELEASE_APP_FROM: writable by group or others, or setuid/setgid: ${x%%$'\n'*}"
  [[ $(/usr/libexec/PlistBuddy -c "Print OmacVMCommit" "$p") == "$m" ]] || die "OMACVM_RELEASE_APP_FROM: the app is not M"
  [[ $(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$p") == "$VERSION" ]] || die "OMACVM_RELEASE_APP_FROM: the app is not $VERSION"
  [[ $(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$p") == org.omacvm.app ]] || die "OMACVM_RELEASE_APP_FROM: the app is not org.omacvm.app"
  # Refused later anyway, but only after signing (step build) or notarizing
  # (package-release.sh); a plain build (no --release) at M fails here.
  grep -qw FAIL "$from/build.log" && die "OMACVM_RELEASE_APP_FROM: a build test failed there: grep -n FAIL $from/build.log"
  [[ -z $(git -C "$WT" status --porcelain) ]] || die "OMACVM_RELEASE_APP_FROM: $WT has changes (the signing and its entitlements come from it)"
  [[ ${OMACVM_RELEASE_NO_KOSMICKRISP:-0} == 1 || ( -f $c/Resources/runtime/lib/libvulkan_kosmickrisp.dylib && -s $c/Resources/licenses/LICENSE.mesa-kosmickrisp.txt ) ]] ||
    die "OMACVM_RELEASE_APP_FROM: the app has no KosmicKrisp (or no licence notice for it): build it with --release (or OMACVM_RELEASE_NO_KOSMICKRISP=1)"
  [[ $(cat "$c/Resources/firmware/firmware-source" 2>/dev/null) == omacvm* || ${OMACVM_FIRMWARE:-} == qemu ]] ||
    die "OMACVM_RELEASE_APP_FROM: the app has QEMU's firmware, not OmacVM's (or OMACVM_FIRMWARE=qemu)"
  # What build-app.sh copies from git, made here the same way from M:
  # omacvm (git archive, COMMIT, go-w) and the scripts (mode 755; git has some
  # at 644).
  t=$(mktemp -d "${TMPDIR:-/tmp}/app-from.XXXXXX"); mkdir "$t/omacvm" "$t/s"
  git -C "$WT" archive "$m" "${APP_ARCHIVE[@]}" | tar -x -C "$t/omacvm" || { rm -rf "$t"; die "git archive of M failed"; }
  echo "$m" > "$t/omacvm/COMMIT"; chmod -R go-w "$t/omacvm"
  git -C "$WT" archive "$m" "${APP_SCRIPTS[@]/#/app/scripts/}" | tar -x -C "$t/s" || { rm -rf "$t"; die "git archive of M's app/scripts failed (${APP_SCRIPTS[*]})"; }
  chmod 755 "$t/s/app/scripts"/*
  [[ $(tree_list "$t/omacvm") == "$(tree_list "$c/Resources/omacvm")" ]] && om=1
  [[ $(tree_list "$t/s/app/scripts") == "$(tree_list "$c/Resources/scripts")" ]] && sc=1
  rm -rf "$t"
  (( om )) || die "OMACVM_RELEASE_APP_FROM: its omacvm is not git archive M"
  (( sc )) || die "OMACVM_RELEASE_APP_FROM: its scripts are not M's app/scripts at mode 755"
  rm -rf "$APP"; mkdir -p "$(dirname "$APP")"
  ditto "$a" "$APP"
  cp "$from/build.log" "$OUT/build.log"
  note "app from $from (built elsewhere at M; checked against M); signing it here"
  (cd "$WT" && app/scripts/sign-app.sh "$APP" org.omacvm.app) >> "$OUT/build.log" 2>&1 || die "signing failed: $OUT/build.log"
}

step_build() {
  local m; m=$(get M); [[ -n $m && -d $WT ]] || die "no M or no $WT: run bump/merge first"
  [[ $(git -C "$WT" rev-parse HEAD) == "$m" ]] || die "$WT is not at M"
  # Never over a bundle that runs (STANDARDS 20).
  runs_in "$APP/Contents/" && die "something runs from $APP"
  if [[ -n ${OMACVM_RELEASE_RUNTIME_FROM:-} && ! -d $WT/app/runtime/.build ]]; then
    cp -cR "$OMACVM_RELEASE_RUNTIME_FROM" "$WT/app/runtime/.build" && rm -rf "$WT/app/runtime/.build/tmp"
    note "runtime from $OMACVM_RELEASE_RUNTIME_FROM (build-app.sh rebuilds it unless its inputs match)"
  fi
  [[ -n ${OMACVM_SIGN_ID:-} ]] || die "OMACVM_SIGN_ID is not set"
  if [[ -n ${OMACVM_RELEASE_APP_FROM:-} ]]; then
    app_from "$OMACVM_RELEASE_APP_FROM" "$m"
  else
    (cd "$WT" && app/scripts/build-app.sh --release) > "$OUT/build.log" 2>&1 || die "build failed: $OUT/build.log"
  fi
  grep -qw FAIL "$OUT/build.log" && die "a build test failed: grep -n FAIL $OUT/build.log"
  local p=$APP/Contents/Info.plist
  [[ $(/usr/libexec/PlistBuddy -c "Print OmacVMCommit" "$p") == "$m" ]] || die "OmacVMCommit is not M"
  [[ $(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$p") == "$VERSION" ]] || die "the app is not $VERSION"
  [[ $(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$p") == org.omacvm.app ]] || die "the app is not org.omacvm.app"
  codesign --verify --deep --strict "$APP" || die "the app's signature does not verify"
  local h team; team=$("$R/src/release/release-key.sh" team "$APP")
  for h in "$APP"/Contents/Helpers/*.app; do
    # Into a variable first: grep -q would end codesign early (pipefail).
    local info; info=$(codesign -dv "$h" 2>&1)
    [[ $info == *"TeamIdentifier=$team"* ]] || die "$(basename "$h") is not team $team"
    [[ $info == *$'\nTimestamp='* ]] || die "$(basename "$h") has no timestamp"
  done
  if grep -q 'QEMU (from source)' "$OUT/build.log"; then note "runtime built from source, build tests passed"
  else note "runtime from the cache (its inputs match; no build tests ran this time)"; fi
  note "app $VERSION, OmacVMCommit $m, team $team, $(du -sh "$APP" | cut -f1)"
  # Step image reads it: an app from another Mac has the only runtime of M.
  put APP_FROM "${OMACVM_RELEASE_APP_FROM:-}"
}

step_notarize() {
  [[ -d $APP ]] || die "no $APP: run build first"
  if [[ $(get NOTARY) != 1 ]]; then
    put NOTARIZED 0
    note "skipped: no notary profile $PROFILE (the release text keeps the Open Anyway line)"
    return
  fi
  local z=$OUT/notarize.zip id status
  rm -f "$z"; ditto -c -k --keepParent "$APP" "$z"
  log "notarizing (Apple's service, usually 2-15 min)"
  xcrun notarytool submit "$z" --keychain-profile "$PROFILE" --wait --timeout 60m --output-format json > "$OUT/notary.json" ||
    die "notarytool submit failed: $OUT/notary.json"
  id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$OUT/notary.json")
  status=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$OUT/notary.json")
  xcrun notarytool log "$id" --keychain-profile "$PROFILE" "$OUT/notary-log.json" >/dev/null 2>&1 || true
  [[ $status == Accepted ]] || die "notarization: $status (log: $OUT/notary-log.json)"
  xcrun stapler staple "$APP" >/dev/null || die "stapler staple failed"
  xcrun stapler validate "$APP" >/dev/null || die "stapler validate failed"
  codesign --verify --deep --strict "$APP" || die "the signature broke after stapling"
  spctl -a -vv -t exec "$APP" 2>&1 | grep -q 'Notarized Developer ID' || die "spctl does not say Notarized Developer ID"
  rm -f "$z"; put NOTARIZED 1
  note "notarized ($id), stapled, spctl: Notarized Developer ID"
}

step_package() {
  local m; m=$(get M)
  [[ -d $APP ]] || die "no $APP: run build first"
  (cd "$WT" && app/scripts/package-release.sh) > "$OUT/package.log" 2>&1 || die "package-release.sh failed: $OUT/package.log"
  local d=$WT/app/dist prev
  [[ -f $d/OmacVM-appcast.json.sig ]] || die "no signed app feed (package.log)"
  # The control centre's manifest: parts keep the release they last changed
  # in, from the latest release's signed manifest (none before 3.0.0).
  prev=$(get PREV); rm -f "$OUT/previous-manifest.json"*
  local pargs=()
  if [[ -n $prev ]] && gh release download "v$prev" -R "$GH_REPO" -p 'omacvm-manifest.json*' -D "$OUT/prevm" --clobber >/dev/null 2>&1 &&
     python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import keys; keys.load(sys.argv[2], "control-manifest")' \
       "$R/src/release" "$OUT/prevm/omacvm-manifest.json" 2>/dev/null; then
    pargs=(--previous "$OUT/prevm/omacvm-manifest.json"); note "control manifest: parts compared with v$prev's"
  else
    note "control manifest: no signed manifest in v${prev:-?}, every part starts at $VERSION"
  fi
  (cd "$WT" && python3 src/release/manifest.py build --version "$VERSION" --commit "$m" --app "$APP" \
     ${pargs[@]+"${pargs[@]}"} --out app/dist/omacvm-manifest.json) >> "$OUT/package.log" 2>&1 || die "manifest.py build failed: $OUT/package.log"
  rm -f "$FILES"/*
  cp -c "$d/OmacVM-$VERSION.zip" "$d/OmacVM-$VERSION.zip.sha256" "$d/OmacVM-appcast.json" "$d/OmacVM-appcast.json.sig" \
    "$d/omacvm-manifest.json" "$d/omacvm-manifest.json.sig" "$FILES/"
  ls -l "$FILES" | awk 'NR > 1 { printf "    %10d  %s\n", $5, $9 }'
}

step_verify() {
  local f=$FILES n=0
  vfail() { printf '    FAIL %s\n' "$*"; n=$((n + 1)); }
  (cd "$f" && shasum -a 256 -c "OmacVM-$VERSION.zip.sha256" >/dev/null) && note "zip sha256 ok" || vfail "zip sha256"
  # The command line (omacvm build --vm-type app, omacvm update): keys.py.
  python3 "$R/src/release/keys.py" app-feed "$f/OmacVM-appcast.json" "$VERSION" > "$OUT/keys-app-feed.txt" &&
    note "keys.py app-feed ok: $(tr '\n' ' ' < "$OUT/keys-app-feed.txt")" || vfail "keys.py app-feed"
  # The Bridge (control centre): the same rules in keys.py; commit = M.
  python3 - "$R/src/release" "$f/omacvm-manifest.json" "$VERSION" "$(get M)" <<'PY' && note "control manifest ok (signature, kind, version, commit)" || vfail "control manifest"
import sys; sys.path.insert(0, sys.argv[1]); import keys
m = keys.load(sys.argv[2], "control-manifest")
assert m["version"] == sys.argv[3] and m["commit"] == sys.argv[4], (m["version"], m["commit"])
assert len(m["parts"]) > 10
PY
  # The app itself (OmacVMUpdate, as Updater checks a download).
  (cd "$R/app/app" && swift build -c release --product feed-check >/dev/null 2>&1) || vfail "feed-check does not build"
  if "$R/app/app/.build/release/feed-check" "$f/OmacVM-appcast.json" "$f/OmacVM-$VERSION.zip" "$VERSION" "$R/src/lib" \
       "$(get PREV)" "$VERSION" > "$OUT/feed-check.txt" 2>&1; then
    note "feed-check (the app's own checks) ok"; sed 's/^/      /' "$OUT/feed-check.txt" | grep -E 'an app at|teams'
  else
    vfail "feed-check:"; sed 's/^/      /' "$OUT/feed-check.txt"
  fi
  # A feed signed by another key must be refused (the check is not a no-op).
  cp "$f/OmacVM-appcast.json" "$OUT/tampered.json"; sed -i '' 's/"length": /"length": 1/' "$OUT/tampered.json"
  cp "$f/OmacVM-appcast.json.sig" "$OUT/tampered.json.sig"
  python3 "$R/src/release/keys.py" app-feed "$OUT/tampered.json" "$VERSION" >/dev/null 2>&1 && vfail "keys.py took a changed feed" || note "a changed feed is refused (keys.py)"
  "$R/app/app/.build/release/feed-check" "$OUT/tampered.json" "$f/OmacVM-$VERSION.zip" "$VERSION" "$R/src/lib" >/dev/null 2>&1 &&
    vfail "feed-check took a changed feed" || note "a changed feed is refused (feed-check)"
  rm -f "$OUT/tampered.json"*
  [[ $(get NOTARIZED) == 1 ]] && note "notarized and stapled" || note "not notarized"
  (( n == 0 )) || die "verify: $n problem(s)"
}

# What goes into a prebuilt image (its guest side, the scripts that make and
# generalize it): an image made at another commit counts for M only while
# these are the same there (3.4.0 on; the manifest's "commit").
IMAGE_PATHS=(src app/scripts ':(exclude)src/tests')
# IMAGE_SUM: the manifest, its signature and the sums file as step image passed them.
image_sum() { cat "$1/$2.json" "$1/$2.json.sig" "$1/$2.sha256" 2>/dev/null | shasum -a 256 | cut -c1-64; }
# image_parts DIR BASE: DIR's part files are exactly the SIGNED manifest's (names, sizes, SHA-256);
# the unsigned .sha256 alone is not enough (made again, it matches any part).
image_parts() { python3 "$R/src/prebuilt/manifest.py" check "$1/$2.json" "$1" >&2; }

step_image() {
  local img=$OUT/prebuilt base=omacvm-prebuilt-$VERSION-app m
  m=$(get M); [[ -n $m ]] || die "no M: run merge first"
  put IMAGE ""   # publish takes an image only after this step passed for M
  # A failed step leaves no image folder behind (publish would see one).
  ifail() { rm -rf "$img"; die "$@"; }
  if [[ -n ${OMACVM_RELEASE_IMAGE_FROM:-} ]]; then
    rm -rf "$img"; mkdir -p "$img"; cp -c "$OMACVM_RELEASE_IMAGE_FROM"/* "$img/" || ifail "could not copy $OMACVM_RELEASE_IMAGE_FROM"
    note "image from $OMACVM_RELEASE_IMAGE_FROM"
    if [[ ! -f $img/$base.json.sig ]]; then
      # Made before this run (the release key signs only inside one): its parts must be the
      # manifest's and its values this release's, then the key signs it here (in the worktree at M).
      python3 -I - "$img" "$base" "$VERSION" <<'PY2' || ifail "the staged image does not match its manifest or $VERSION"
import hashlib, json, os, sys
d, base, v = sys.argv[1:]
m = json.load(open(os.path.join(d, base + ".json")))
assert m.get("kind") == "prebuilt-manifest" and m.get("route") == "app" and m.get("omacvm") == v, "kind/route/version"
names = sorted(x for x in os.listdir(d) if x.startswith(base + ".tar.zst.part-"))
assert names == sorted(p["name"] for p in m["parts"]), "parts"
for p in m["parts"]:
    f = os.path.join(d, p["name"]); h = hashlib.sha256()
    with open(f, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    assert os.path.getsize(f) == p["size"] and h.hexdigest() == p["sha256"], p["name"]
print("    staged image: %d parts match the manifest" % len(names))
PY2
      "$WT/src/release/release-key.sh" sign "$img/$base.json" || ifail "the release key did not sign the staged image's manifest"
      (cd "$img" && shasum -a 256 "$base".tar.zst.part-* "$base.json" "$base.json.sig" > "$base.sha256")
      note "staged image signed in this release run"
    fi
  else
    [[ -e $HOME/.omacvm-user-testing ]] && die "$HOME/.omacvm-user-testing is set: no VM now (or OMACVM_RELEASE_IMAGE_FROM)"
    # An app from another Mac (step build with OMACVM_RELEASE_APP_FROM) leaves
    # no runtime build in $WT: the image VM runs on the app's own runtime
    # (make-image.sh OMACVM_PREBUILT_APP), never on a runtime build left there.
    local own=
    if [[ -n $(get APP_FROM) ]]; then
      [[ -x $APP/Contents/Resources/runtime/bin/OmacVM ]] || die "no runtime in $APP: run build first"
      own=$APP; note "the image VM runs on the app's own runtime (the app came from $(get APP_FROM))"
    else
      [[ -x $WT/app/runtime/.build/qemu-gpu-runtime/bin/qemu-system-aarch64 ]] || die "no runtime in $WT: run build first"
    fi
    rm -rf "$img/vm"
    (cd "$WT" && OMACVM_PREBUILT_APP=$own OMACVM_PREBUILT_OUT=$OUT/prebuilt-out src/prebuilt/make-image.sh app build generalize package clean) \
      > "$OUT/image.log" 2>&1 || ifail "make-image.sh failed: $OUT/image.log"
    rm -rf "$img"; mv "$OUT/prebuilt-out/app" "$img"; rm -rf "$OUT/prebuilt-out"
  fi
  [[ -f $img/$base.json.sig ]] || ifail "no signed $base.json in $img"
  image_parts "$img" "$base" || ifail "the image's parts are not those of its signed manifest"
  (cd "$img" && shasum -a 256 -c "$base.sha256" >/dev/null) || ifail "image sums do not match"
  local v; v=$(python3 "$R/src/prebuilt/manifest.py" get "$img/$base.json" omacvm) || ifail "the image manifest does not verify"
  [[ $v == "$VERSION" ]] || ifail "the image is for $v"
  [[ $(python3 "$R/src/prebuilt/manifest.py" get "$img/$base.json" route) == app ]] || ifail "the image is not route app"
  python3 "$R/src/prebuilt/manifest.py" fits "$VERSION" "$(python3 "$R/src/prebuilt/manifest.py" get "$img/$base.json" omarchy)" ||
    ifail "the image's Omarchy is too old for $VERSION (from 3.4.0: 4.5 or later; manifest.py OMARCHY_FLOOR)"
  if moves_needed; then
    # 3.4.0 on: the image is M's (made at M, or at a commit whose image files are M's).
    local c d; c=$(python3 "$R/src/prebuilt/manifest.py" get "$img/$base.json" commit) || ifail "the image manifest does not verify"
    [[ -n $c ]] || ifail "the image names no commit it was made from: make it again at M (make-image.sh records it)"
    if [[ $c != "$m" ]]; then
      gitr cat-file -e "$c^{commit}" 2>/dev/null || ifail "the image was made from $c, which this repository does not have: make it again at M"
      d=$(gitr diff --name-only "$c" "$m" -- "${IMAGE_PATHS[@]}") || ifail "git diff $c $m failed"
      [[ -z $d ]] || ifail "the image was made from ${c:0:12}; M differs in what goes into the image ($(echo $d | cut -c1-300)): make it again at M"
      note "image made from ${c:0:12}: its files are M's"
    else
      note "image made from M"
    fi
  fi
  put IMAGE pass; put IMAGE_M "$m"; put IMAGE_SUM "$(image_sum "$img" "$base")"
  note "image ok: $(du -ch "$img"/$base.tar.zst.part-* | tail -1 | cut -f1) in $(ls "$img"/$base.tar.zst.part-* | wc -l | tr -d ' ') parts, Omarchy $(python3 "$R/src/prebuilt/manifest.py" get "$img/$base.json" omarchy)"
}

# The gate (src/tests/e2e/README.md): the person's path end to end for M, or
# an override that is written down.
e2e_override() {
  local why=$OMACVM_RELEASE_E2E_OVERRIDE
  [[ ${#why} -ge 10 ]] || die "OMACVM_RELEASE_E2E_OVERRIDE: say why in a sentence (it is logged)"
  printf '%s\t%s\tM=%s\tby %s\t%s\n' "$(date '+%F %T')" "$VERSION" "$(get M)" "$(id -un)" "$why" >> "$OUT/e2e-override.log"
  put E2E "override"; put E2E_M "$(get M)"
  printf '\n    !!! E2E GATE OVERRIDDEN for %s: %s\n    !!! (logged in %s)\n\n' "$VERSION" "$why" "$OUT/e2e-override.log"
}

step_e2e() {
  local m; m=$(get M); [[ -n $m ]] || die "no M: run merge first"
  if [[ -n ${OMACVM_RELEASE_E2E_OVERRIDE:-} ]]; then e2e_override; return; fi
  local r=${OMACVM_RELEASE_E2E_RESULT:-$OUT/e2e/result.json}
  if [[ ! -f $r && -n ${OMACVM_E2E_SSH:-} ]]; then
    log "e2e on the test Mac ($OMACVM_E2E_SSH), 1-2 h"
    "$R/src/tests/e2e/remote.sh" "$m" "$OUT/e2e" | tee "$OUT/e2e.log" || true
    r=$OUT/e2e/result.json
  fi
  [[ -f $r ]] || die "no e2e result for M ($r): run src/tests/e2e/cc-switches.sh on the test Mac with a test identity build of $m (src/tests/e2e/README.md), set OMACVM_E2E_SSH + OMACVM_E2E_ARGS, or OMACVM_RELEASE_E2E_OVERRIDE=\"<why>\""
  python3 - "$r" "$m" <<'PY' || die "the e2e gate did not pass for M ($r)"
import json, sys
o = json.load(open(sys.argv[1]))
print(f"    e2e: {o.get('counts')} in {o.get('seconds', 0) // 60} min, commit {str(o.get('commit'))[:12]}, steps {o.get('only')}")
for st, status, detail in o.get("not_ok", [])[:20]:
    print(f"      {status:7} {st}: {detail[:200]}")
assert o.get("kind") == "omacvm-e2e-cc-switches", "not a cc-switches result"
assert o.get("commit") == sys.argv[2], f"tested {o.get('commit')}, not M {sys.argv[2]}"
assert o.get("only") == "all", "not every step ran"
assert o.get("pass") is True, "not passed"
PY
  put E2E pass; put E2E_M "$m"
  note "e2e gate passed for M"
}

# From 3.4.0 (Omarchy 4.5): the move matrix for M (src/tests/e2e/move-45.sh).
moves_needed() { [[ $(printf '%s\n' "$VERSION" 3.4.0 | sort -t. -k1,1n -k2,2n -k3,3n | head -1) == 3.4.0 ]]; }
step_moves() {
  moves_needed || { note "moves: not needed before 3.4.0"; return; }
  local m; m=$(get M); [[ -n $m ]] || die "no M: run merge first"
  if [[ -n ${OMACVM_RELEASE_MOVES_OVERRIDE:-} ]]; then
    local why=$OMACVM_RELEASE_MOVES_OVERRIDE
    [[ ${#why} -ge 10 ]] || die "OMACVM_RELEASE_MOVES_OVERRIDE: say why in a sentence (it is logged)"
    printf '%s\t%s\tM=%s\tby %s\tmoves: %s\n' "$(date '+%F %T')" "$VERSION" "$m" "$(id -un)" "$why" >> "$OUT/e2e-override.log"
    put MOVES override; put MOVES_M "$m"
    printf '\n    !!! MOVES GATE OVERRIDDEN for %s: %s\n\n' "$VERSION" "$why"; return
  fi
  local r=${OMACVM_RELEASE_MOVES_RESULT:-$OUT/moves/result.json}
  [[ -f $r ]] || die "no move matrix result ($r): src/tests/e2e/move-45.sh on the test Macs, then --summary (or OMACVM_RELEASE_MOVES_OVERRIDE=\"<why>\")"
  python3 -I "$R/src/tests/e2e/move-45-result.py" gate "$r" "$m" "$R" || die "the moves gate did not pass for M ($r)"
  put MOVES pass; put MOVES_M "$m"
}

notes_file() {   # the release text, without the unnotarized lines once notarized
  if [[ $(get NOTARIZED) == 1 ]]; then
    sed '/<!-- if-unnotarized -->/,/<!-- end-if -->/d' "$NOTES"
  else
    grep -v -E '<!-- (if-unnotarized|end-if) -->' "$NOTES"
  fi > "$OUT/release-notes.md"
  echo "$OUT/release-notes.md"
}

step_publish() {
  local m; m=$(get M); [[ -n $m ]] || die "no M"
  local gate; gate=$(get E2E)
  [[ $(get E2E_M) == "$m" ]] || gate=""   # a pass (or override) for an earlier M does not count
  case $gate in
    pass) note "e2e gate: passed for M" ;;
    override) note "e2e gate: OVERRIDDEN ($(tail -1 "$OUT/e2e-override.log" | cut -f5))" ;;
    *) if (( DRY )); then note "dry run: the e2e gate has not passed (a real publish stops here)"
       else die "the e2e gate has not passed for M: release.sh $VERSION e2e (or OMACVM_RELEASE_E2E_OVERRIDE=\"<why>\" release.sh $VERSION e2e)"; fi ;;
  esac
  if moves_needed; then
    local mv; mv=$(get MOVES); [[ $(get MOVES_M) == "$m" ]] || mv=""
    case $mv in
      pass) note "moves gate: passed for M" ;;
      override) note "moves gate: OVERRIDDEN" ;;
      *) if (( DRY )); then note "dry run: the moves gate has not passed (a real publish stops here)"
         else die "the moves gate has not passed for M: release.sh $VERSION moves"; fi ;;
    esac
  fi
  # The image: only one that passed step image for M, unchanged since; from 3.4.0 one is needed
  # (or OMACVM_RELEASE_NO_IMAGE with a reason). It goes up and is checked BEFORE the app's
  # release: a 3.4.0 app never goes out without its Omarchy 4.5 image.
  local img=$OUT/prebuilt base=omacvm-prebuilt-$VERSION-app have=0
  if [[ -d $img ]]; then
    [[ $(get IMAGE) == pass && $(get IMAGE_M) == "$m" ]] || die "the image in $img has not passed step image for M: release.sh $VERSION image"
    [[ $(image_sum "$img" "$base") == "$(get IMAGE_SUM)" ]] || die "the image's manifest or sums changed after step image: release.sh $VERSION image"
    image_parts "$img" "$base" || die "the image's parts are not those of its signed manifest: release.sh $VERSION image"
    (cd "$img" && shasum -a 256 -c "$base.sha256" >/dev/null) || die "image sums do not match"
    python3 "$R/src/prebuilt/manifest.py" get "$img/$base.json" route >/dev/null || die "the image manifest does not verify"
    have=1; note "image: passed step image for M"
  elif moves_needed; then
    if [[ -n ${OMACVM_RELEASE_NO_IMAGE:-} ]]; then note "!!! no prebuilt image: ${OMACVM_RELEASE_NO_IMAGE} (new VMs build here)"
    elif (( DRY )); then note "dry run: no prebuilt image in $img (a real publish stops here)"
    else die "no prebuilt image in $img: a $VERSION app would build every new VM here (step image, or OMACVM_RELEASE_NO_IMAGE=\"<why>\")"; fi
  fi
  local title=${OMACVM_RELEASE_TITLE:-OmacVM $VERSION}
  local nf; nf=$(notes_file)
  local assets=("$FILES/OmacVM-$VERSION.zip" "$FILES/OmacVM-$VERSION.zip.sha256" "$FILES/OmacVM-appcast.json"
    "$FILES/OmacVM-appcast.json.sig" "$FILES/omacvm-manifest.json" "$FILES/omacvm-manifest.json.sig")
  local imgcmd="(cd $(printf %q "$WT") && OMACVM_PREBUILT_OUT=$(printf %q "$OUT/prebuilt-up") OMACVM_PREBUILT_TARGET=$m src/prebuilt/make-image.sh app upload)"
  if (( DRY )); then
    note "dry run, would run:"
    (( have )) && note "  $imgcmd" && note "  then check prebuilt-$VERSION on GitHub against $img (image_published)"
    note "  git tag -a $TAG -m 'OmacVM $VERSION' $m && git push origin $TAG"
    note "  gh release create $TAG ${assets[*]##*/} --verify-tag --latest --title '$title' --notes-file $nf"
    return
  fi
  ask "upload prebuilt-$VERSION, then tag $TAG at $m and publish the release (latest)?"
  if (( have )); then
    mkdir -p "$OUT/prebuilt-up"; rm -rf "$OUT/prebuilt-up/app"; cp -cR "$img" "$OUT/prebuilt-up/app"
    eval "$imgcmd" || die "prebuilt upload failed: nothing of the app is published (run publish again)"
    image_published "$img" "$base" || die "prebuilt-$VERSION on GitHub is not the image that passed: nothing of the app is published"
    note "prebuilt-$VERSION uploaded and checked"
  fi
  gitr tag -a "$TAG" -m "OmacVM $VERSION" "$m"
  gitr push -q origin "$TAG"
  gh release create "$TAG" -R "$GH_REPO" "${assets[@]}" --verify-tag --latest --title "$title" --notes-file "$nf"
}

# image_published DIR BASE: prebuilt-$VERSION on GitHub serves exactly DIR's image at M: the manifest,
# its signature and sums byte for byte; every part of the signed manifest there with its size and
# SHA-256 (GitHub's asset digest, or the part downloaded when GitHub gives none), no other part; the
# release's target and its tag both M.
image_published() {
  local d=$1 base=$2 m t tagc; m=$(get M); t=$(mktemp -d)
  gh release download "prebuilt-$VERSION" -R "$GH_REPO" -D "$t" -p "$base.json" -p "$base.json.sig" -p "$base.sha256" >/dev/null 2>&1 ||
    { note "prebuilt-$VERSION: could not download its manifest"; rm -rf "$t"; return 1; }
  local f; for f in "$base.json" "$base.json.sig" "$base.sha256"; do
    cmp -s "$t/$f" "$d/$f" || { note "prebuilt-$VERSION: $f differs from $d"; rm -rf "$t"; return 1; }
  done
  python3 "$R/src/prebuilt/manifest.py" parts "$d/$base.json" > "$t/parts" || { rm -rf "$t"; return 1; }
  gh api "repos/$GH_REPO/releases/tags/prebuilt-$VERSION" > "$OUT/prebuilt-release.json" 2>/dev/null ||
    { note "prebuilt-$VERSION: GitHub does not answer for it"; rm -rf "$t"; return 1; }
  tagc=$(gh api "repos/$GH_REPO/commits/prebuilt-$VERSION" -q .sha 2>/dev/null) || tagc=""
  python3 -I - "$OUT/prebuilt-release.json" "$t/parts" "$m" "$tagc" "$base" "prebuilt-$VERSION" "$GH_REPO" "$t" <<'PY2'
import hashlib, json, os, subprocess, sys
rel, parts, m, tagc, base, tag, repo, tmp = sys.argv[1:]
r = json.load(open(rel))
bad = []
target = str(r.get("target_commitish") or "")
if target != m:
    bad.append("its target is %r, not M %s" % (target[:40], m[:12]))
if tagc != m:
    bad.append("its tag is at %s, not M" % (tagc[:12] or "no commit"))
if r.get("draft"):
    bad.append("it is a draft")
assets = {str(a.get("name")): a for a in r.get("assets") or []}
want = [l.split() for l in open(parts) if l.strip()]
names = {w[0] for w in want}
bad += ["%s is not in the manifest" % n for n in sorted(assets) if n.startswith(base + ".tar.zst.part-") and n not in names]
for n, size, digest in want:
    a = assets.get(n)
    if a is None:
        bad.append("%s is missing" % n)
    elif a.get("size") != int(size):
        bad.append("%s is %s bytes, want %s" % (n, a.get("size"), size))
    elif a.get("digest"):
        if a["digest"] != "sha256:" + digest:
            bad.append("%s: GitHub's digest is not the signed manifest's" % n)
    else:   # no digest from GitHub (older answers): the part itself
        f = os.path.join(tmp, n)
        if subprocess.run(["gh", "release", "download", tag, "-R", repo, "-D", tmp, "-p", n, "--clobber"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0 or not os.path.isfile(f):
            bad.append("%s: could not download it" % n)
            continue
        h = hashlib.sha256()
        with open(f, "rb") as fh:
            for b in iter(lambda: fh.read(1 << 20), b""):
                h.update(b)
        os.remove(f)
        if h.hexdigest() != digest:
            bad.append("%s: SHA-256 is not the signed manifest's" % n)
if bad:
    sys.exit("    prebuilt on GitHub: " + "; ".join(bad))
print("    prebuilt on GitHub: %d parts as the signed manifest, at M %s" % (len(want), m[:12]))
PY2
  local rc=$?; rm -rf "$t"; return $rc
}

step_after() {
  if (( DRY )); then note "dry run: nothing published to check"; return; fi
  local d; d=$(mktemp -d); trap 'rm -rf "$d"' RETURN
  gh release download "$TAG" -R "$GH_REPO" -D "$d" -p 'OmacVM-*' -p 'omacvm-manifest.json*' >/dev/null
  (cd "$d" && shasum -a 256 -c "OmacVM-$VERSION.zip.sha256" >/dev/null) || die "downloaded zip: sha256"
  "$R/app/app/.build/release/feed-check" "$d/OmacVM-appcast.json" "$d/OmacVM-$VERSION.zip" "$VERSION" "$R/src/lib" > "$OUT/after-feed-check.txt" ||
    die "downloaded feed: $OUT/after-feed-check.txt"
  # What installed apps and the Bridge fetch: releases/latest.
  local u=https://github.com/$GH_REPO/releases/latest/download
  curl -fsSL "$u/OmacVM-appcast.json" -o "$d/latest.json" && cmp -s "$d/latest.json" "$FILES/OmacVM-appcast.json" ||
    die "releases/latest does not serve this feed yet"
  curl -fsSL "$u/omacvm-manifest.json" -o "$d/latest-m.json" && cmp -s "$d/latest-m.json" "$FILES/omacvm-manifest.json" ||
    die "releases/latest does not serve this control manifest"
  [[ $(gh release view -R "$GH_REPO" --json tagName -q .tagName) == "$TAG" ]] || die "$TAG is not the latest release"
  if gh release view "prebuilt-$VERSION" -R "$GH_REPO" >/dev/null 2>&1; then
    (cd "$WT" && app/scripts/prebuilt-vm.sh --lookup) && note "prebuilt lookup ok" || die "prebuilt-vm.sh --lookup finds no image"
  fi
  [[ $(get E2E) == override ]] && note "!!! published WITHOUT the e2e gate: $OUT/e2e-override.log"
  note "published files check out; releases/latest = $TAG"
}

# ---------- rollback ----------

rollback_prep() {   # a signed feed for the release before, ready to upload
  local prev; prev=$(get PREV); [[ -n $prev ]] || prev=$(gh release view -R "$GH_REPO" --json tagName -q .tagName); prev=${prev#v}
  [[ $prev != "$VERSION" ]] || die "the latest release is already $VERSION: set PREV=<version> in $STATE"
  local d=$OUT/rollback; rm -rf "$d"; mkdir -p "$d"
  gh release download "v$prev" -R "$GH_REPO" -D "$d" -p "OmacVM-$prev.zip" -p "OmacVM-$prev.zip.sha256" >/dev/null
  (cd "$d" && shasum -a 256 -c "OmacVM-$prev.zip.sha256" >/dev/null) || die "v$prev zip: sha256"
  "$R/app/scripts/appcast.sh" "$d/OmacVM-$prev.zip" > "$d/appcast.log" 2>&1 || die "appcast.sh failed: $d/appcast.log"
  python3 "$R/src/release/keys.py" app-feed "$d/OmacVM-appcast.json" "$prev" >/dev/null || die "keys.py refuses the v$prev feed"
  (cd "$R/app/app" && swift build -c release --product feed-check >/dev/null 2>&1)
  "$R/app/app/.build/release/feed-check" "$d/OmacVM-appcast.json" "$d/OmacVM-$prev.zip" "$prev" "$R/src/lib" > "$d/feed-check.txt" 2>&1 ||
    note "feed-check: $(grep FAIL "$d/feed-check.txt" | tr '\n' ' ') (a 2.x app carries no release keys; the feed itself is what counts)"
  put PREV "$prev"
  note "v$prev feed signed and checked: $d/OmacVM-appcast.json(.sig) (not uploaded)"
}

rollback() {
  local prev; prev=$(get PREV); [[ -n $prev ]] || die "no PREV in $STATE: run rollback-prep first"
  local d=$OUT/rollback
  [[ -f $d/OmacVM-appcast.json.sig ]] || die "no v$prev feed: run rollback-prep first"
  (( DRY )) && { note "dry run, would: mark $TAG pre-release (v$prev latest again), remove its feeds, upload v$prev's feed"; return; }
  ask "roll back: v$prev becomes latest again, $TAG's feeds are removed?"
  # 1. Installed apps and the Bridge read releases/latest: v$prev again.
  gh release edit "$TAG" -R "$GH_REPO" --prerelease --latest=false
  # 2. Nothing installs $VERSION by itself any more (the command line needs
  #    its signed feed; the Bridge its manifest). The zip stays for anyone
  #    who wants it.
  for a in OmacVM-appcast.json OmacVM-appcast.json.sig omacvm-manifest.json omacvm-manifest.json.sig; do
    gh release delete-asset "$TAG" "$a" -R "$GH_REPO" -y || true
  done
  # 3. v$prev's own feed: apps of this version see "up to date".
  gh release upload "v$prev" -R "$GH_REPO" --clobber "$d/OmacVM-appcast.json" "$d/OmacVM-appcast.json.sig"
  [[ $(gh release view -R "$GH_REPO" --json tagName -q .tagName) == "v$prev" ]] || die "v$prev is not latest: gh release edit v$prev --latest"
  note "done. main still has $VERSION: revert it with a PR (docs/releasing.md, Rollback 4), or fix forward with $VERSION+1"
  note "prebuilt: gh release edit prebuilt-$VERSION -R $GH_REPO --draft   (hides the image from omacvm build --prebuilt)"
}

clean() {
  local w
  for w in "$WT" "$BUMP"; do
    [[ -d $w ]] || continue
    runs_in "$w/" && die "something runs from $w"
    gitr worktree remove --force "$w" && note "removed $w"
  done
}

# ---------- run ----------
TIMES=$OUT/times.tsv
for s in "${STEPS[@]}"; do
  case $s in
    check|bump|merge|build|notarize|package|verify|image|e2e|moves|publish|after) fn=step_$s ;;
    rollback-prep) fn=rollback_prep ;;
    rollback|clean) fn=$s ;;
    *) die "unknown step $s" ;;
  esac
  log "$s"
  t0=$(date +%s)
  "$fn"
  t=$(( $(date +%s) - t0 ))
  printf '%s\t%s\t%ss\n' "$(date +%H:%M:%S)" "$s" "$t" >> "$TIMES"
  note "$s: $((t / 60))m$((t % 60))s"
done
