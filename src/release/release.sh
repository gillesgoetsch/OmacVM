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
#   notarize  Apple's notary service, then staple the ticket into the app
#   package   OmacVM-VERSION.zip + .sha256, OmacVM-appcast.json + .sig (the
#             app feed), omacvm-manifest.json + .sig (control centre)
#   verify    every file read back as the app, the command line and the Bridge
#             read them
#   image     the app's prebuilt VM (make-image.sh app), its manifest signed
#   publish   tag M, the GitHub release (latest), the prebuilt pre-release
#             (dry run: prints the commands only)
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
# OMACVM_RELEASE_IMAGE_FROM (a folder with a signed image of this version:
# used instead of building one), OMACVM_RELEASE_UNNOTARIZED=1 (release
# without notarization, as 2.x), OMACVM_RELEASE_FROM (dry run only: the
# commit to start from instead of the PR's head).
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
(( ${#STEPS[@]} )) || STEPS=(check bump merge build notarize package verify image publish after)

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
  w=$(gitr show "origin/$head:CHANGELOG.md" | awk -v h="## $VERSION (unreleased)" '$0 == h { f = 1; next } f && /^## / { exit } f')
  [[ -n $w ]] || fail "CHANGELOG on $head has no \"## $VERSION (unreleased)\""
  if grep -qi 'pending' <<<"$w"; then
    (( DRY )) && note "CHANGELOG $VERSION still marks items as pending" || fail "CHANGELOG $VERSION still marks items as pending"
  fi
  # README items marked "(pending #N)" (or "(pending, no PR yet ...)") until their PR is in.
  if gitr show "origin/$head:README.md" | grep -qi '(pending'; then
    (( DRY )) && note "README still marks items as pending" || fail "README still marks items as pending"
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
  (cd "$WT" && app/scripts/build-app.sh --release) > "$OUT/build.log" 2>&1 || die "build failed: $OUT/build.log"
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

step_image() {
  local img=$OUT/prebuilt base=omacvm-prebuilt-$VERSION-app
  if [[ -n ${OMACVM_RELEASE_IMAGE_FROM:-} ]]; then
    mkdir -p "$img"; cp -c "$OMACVM_RELEASE_IMAGE_FROM"/* "$img/"
    note "image from $OMACVM_RELEASE_IMAGE_FROM"
  else
    [[ -e $HOME/.omacvm-user-testing ]] && die "$HOME/.omacvm-user-testing is set: no VM now (or OMACVM_RELEASE_IMAGE_FROM)"
    [[ -x $WT/app/runtime/.build/qemu-gpu-runtime/bin/qemu-system-aarch64 ]] || die "no runtime in $WT: run build first"
    rm -rf "$img/vm"
    (cd "$WT" && OMACVM_PREBUILT_OUT=$OUT/prebuilt-out src/prebuilt/make-image.sh app build generalize package clean) \
      > "$OUT/image.log" 2>&1 || die "make-image.sh failed: $OUT/image.log"
    rm -rf "$img"; mv "$OUT/prebuilt-out/app" "$img"; rm -rf "$OUT/prebuilt-out"
  fi
  [[ -f $img/$base.json.sig ]] || die "no signed $base.json in $img"
  (cd "$img" && shasum -a 256 -c "$base.sha256" >/dev/null) || die "image sums do not match"
  local v; v=$(python3 "$R/src/prebuilt/manifest.py" get "$img/$base.json" omacvm) || die "the image manifest does not verify"
  [[ $v == "$VERSION" ]] || die "the image is for $v"
  [[ $(python3 "$R/src/prebuilt/manifest.py" get "$img/$base.json" route) == app ]] || die "the image is not route app"
  note "image ok: $(du -ch "$img"/$base.tar.zst.part-* | tail -1 | cut -f1) in $(ls "$img"/$base.tar.zst.part-* | wc -l | tr -d ' ') parts, Omarchy $(python3 "$R/src/prebuilt/manifest.py" get "$img/$base.json" omarchy)"
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
  local title=${OMACVM_RELEASE_TITLE:-OmacVM $VERSION}
  local nf; nf=$(notes_file)
  local assets=("$FILES/OmacVM-$VERSION.zip" "$FILES/OmacVM-$VERSION.zip.sha256" "$FILES/OmacVM-appcast.json"
    "$FILES/OmacVM-appcast.json.sig" "$FILES/omacvm-manifest.json" "$FILES/omacvm-manifest.json.sig")
  local imgcmd="(cd $WT && OMACVM_PREBUILT_OUT=$OUT/prebuilt-up OMACVM_PREBUILT_TARGET=$m src/prebuilt/make-image.sh app upload)"
  if (( DRY )); then
    note "dry run, would run:"
    note "  git tag -a $TAG -m 'OmacVM $VERSION' $m && git push origin $TAG"
    note "  gh release create $TAG ${assets[*]##*/} --verify-tag --latest --title '$title' --notes-file $nf"
    note "  $imgcmd"
    return
  fi
  ask "tag $TAG at $m and publish the release (latest)?"
  gitr tag -a "$TAG" -m "OmacVM $VERSION" "$m"
  gitr push -q origin "$TAG"
  gh release create "$TAG" -R "$GH_REPO" "${assets[@]}" --verify-tag --latest --title "$title" --notes-file "$nf"
  if [[ -d $OUT/prebuilt ]]; then
    mkdir -p "$OUT/prebuilt-up"; rm -rf "$OUT/prebuilt-up/app"; cp -cR "$OUT/prebuilt" "$OUT/prebuilt-up/app"
    eval "$imgcmd" || die "prebuilt upload failed (the app release is out; run publish's image part again)"
  else
    note "no image in $OUT/prebuilt: prebuilt-$VERSION not uploaded"
  fi
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
    check|bump|merge|build|notarize|package|verify|image|publish|after) fn=step_$s ;;
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
