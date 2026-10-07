#!/bin/bash
# OmacVM's release keys on the Mac's command line (src/release/keys.py,
# release-key.sh, the CLI's OmacVM.app download in src/lib/app.sh), with
# throwaway keys: either shipped key signs, other keys and changed documents
# are refused, the Developer ID teams come from the signed document (missing,
# empty or another team: refused), a named spare is trusted from then on,
# a revoked one is not, junk in the kept folder changes nothing, test keys
# count nowhere inside a release app, and the fast network's root service
# trusts a Developer ID team only when a signed feed lists it, and runs an
# app's own daemon as root only then (or from the app's own copy of the
# script). No network beyond 127.0.0.1, no root.
#   src/tests/release-keys.sh
# OMACVM_TEST_DEVID_APP: a Developer ID signed org.omacvm.app (a release
# build) for the download that passes; OMACVM_TEST_DEVID_SIGN: a Developer ID
# Application identity, for a fake app's QEMU (the fast network part); each
# part is skipped without it.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
T=$(mktemp -d)
T=$(cd "$T" && pwd -P)
SERVER=""
trap '[[ -n $SERVER ]] && { kill "$SERVER"; wait "$SERVER"; } 2>/dev/null; rm -rf "$T"' EXIT
source "$R/src/tests/release-test-keys.sh"
KEYS=$R/src/release/keys.py

expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
verdict() { python3 "$KEYS" verify "$1" "$2" >/dev/null 2>&1 && echo good || echo refused; }   # KIND FILE

# doc FILE KIND [EXTRA-JSON-FIELDS] [KEY]: a small signed document.
doc() {
  printf '{"schema": 1, "kind": "%s", "version": "9.9.9", "devid_teams": ["722686Y34B"]%s}\n' "$2" "${3:-}" > "$1"
  sign_doc "$1" "${4:-}"
}

# ---- the real release key signs only inside a release run ----
# A stand-in `security` records whether the Keychain was asked at all.
mkdir -p "$T/fakebin"
printf '#!/bin/bash\ntouch "%s/keychain-read"\nexit 1\n' "$T" > "$T/fakebin/security"; chmod +x "$T/fakebin/security"
G=$T/relrepo
mkdir -p "$G/src/release"
cp "$R/src/release/release-key.sh" "$R/src/release/keys.py" "$R/src/release/sign.swift" "$G/src/release/"
echo 9.9.9 > "$G/src/VERSION"; echo '{}' > "$T/rel.json"
git -C "$G" init -q && git -C "$G" add -A && git -C "$G" -c user.name=t -c user.email=t@t commit -qm v
relsign() {   # [ENV...]: "asked" if the Keychain was read, else "refused" (the sign must fail either way here)
  rm -f "$T/keychain-read"
  env -u OMACVM_RELEASE_KEY_FILE -u OMACVM_RELEASE_RUN PATH="$T/fakebin:$PATH" "$@" "$G/src/release/release-key.sh" sign "$T/rel.json" >/dev/null 2>&1
  [[ -e $T/keychain-read ]] && echo asked || echo refused
}
expect "release key: no release run, Keychain not read" refused "$(relsign)"
expect "release key: release run of another version, not read" refused "$(relsign OMACVM_RELEASE_RUN=9.9.8)"
expect "release key: release run, clean tree at that version: read" asked "$(relsign OMACVM_RELEASE_RUN=9.9.9)"
echo x >> "$G/src/release/keys.py"
expect "release key: changed tracked file, not read" refused "$(relsign OMACVM_RELEASE_RUN=9.9.9)"
git -C "$G" checkout -q -- src/release/keys.py
git -C "$G" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two && git -C "$G" tag v9.9.9 HEAD~1
expect "release key: tag v9.9.9 on another commit, not read" refused "$(relsign OMACVM_RELEASE_RUN=9.9.9)"
git -C "$G" tag -f v9.9.9 HEAD >/dev/null
expect "release key: at the tag, read" asked "$(relsign OMACVM_RELEASE_RUN=9.9.9)"
rm -f "$T/keychain-read" "$T/m.json"
env -u OMACVM_RELEASE_KEY_FILE -u OMACVM_RELEASE_RUN PATH="$T/fakebin:$PATH" python3 "$R/src/release/manifest.py" build \
  --version 9.9.9 --commit abc --teams 722686Y34B --out "$T/m.json" >/dev/null 2>&1
expect "manifest.py build --out outside a release run: refused, nothing written, Keychain not read" "2 no no" \
  "$? $([[ -e $T/m.json ]] && echo yes || echo no) $([[ -e $T/keychain-read ]] && echo yes || echo no)"

# ---- either key, nothing else ----
D=$T/doc.json
doc "$D" control-manifest
expect "signed with the main key" good "$(verdict control-manifest "$D")"
doc "$D" control-manifest "" spare-key
expect "signed with the spare key" good "$(verdict control-manifest "$D")"
doc "$D" control-manifest "" stranger-key
expect "signed with another key: refused" refused "$(verdict control-manifest "$D")"
doc "$D" control-manifest
printf ' ' >> "$D"
expect "a byte added after signing: refused" refused "$(verdict control-manifest "$D")"
doc "$D" control-manifest; rm -f "$D.sig"
expect "no signature: refused" refused "$(verdict control-manifest "$D")"
doc "$D" control-manifest; echo "bm90IGEgc2ln" > "$D.sig"
expect "garbage signature: refused" refused "$(verdict control-manifest "$D")"
doc "$D" app-feed
expect "another kind: refused" refused "$(verdict control-manifest "$D")"
expect "the shipped keys only (no test keys): refused" refused "$(OMACVM_RELEASE_TEST_KEYS="" verdict app-feed "$D")"
python3 "$KEYS" release-check "$D" >/dev/null 2>&1
expect "release-check: a test key is not a shipped key" 1 $?

# ---- the teams ----
while IFS='|' read -r what teams; do
  printf '{"schema": 1, "kind": "app-feed"%s}\n' "$teams" > "$D"; sign_doc "$D"
  expect "$what: refused" refused "$(verdict app-feed "$D")"
done <<'EOF'
no devid_teams|
empty devid_teams|, "devid_teams": []
devid_teams as a string|, "devid_teams": "722686Y34B"
a lower-case team|, "devid_teams": ["722686y34b"]
a team with a quote|, "devid_teams": ["722686Y3\"B"]
a team twice|, "devid_teams": ["722686Y34B", "722686Y34B"]
five teams|, "devid_teams": ["AAAAAAAAA1", "AAAAAAAAA2", "AAAAAAAAA3", "AAAAAAAAA4", "AAAAAAAAA5"]
EOF
printf '{"schema": 1, "kind": "app-feed", "devid_teams": ["722686Y34B", "ABCDE12345"]}\n' > "$D"; sign_doc "$D"
expect "two teams (a change of Developer ID)" good "$(verdict app-feed "$D")"

# ---- a named spare: kept as the signed document, trusted from then on ----
"$T/sign" keygen "$T/next-key" > "$T/next-key.pub"
"$T/sign" keygen "$T/third-key" > "$T/third-key.pub"
STORE=$OMACVM_SETTINGS_DIR/release-keys
doc "$D" control-manifest "" next-key
expect "the new spare before it was named: refused" refused "$(verdict control-manifest "$D")"
doc "$T/naming.json" app-feed ", \"next_spare_key\": \"$(cat "$T/next-key.pub")\"" stranger-key
verdict app-feed "$T/naming.json" >/dev/null
expect "named by a stranger: nothing kept" 0 "$(ls "$STORE" 2>/dev/null | wc -l | tr -d ' ')"
doc "$T/naming.json" app-feed ", \"next_spare_key\": \"$(cat "$T/next-key.pub")\"" spare-key
expect "a feed naming a new spare (signed by the spare)" good "$(verdict app-feed "$T/naming.json")"
expect "kept: the document and its signature" 2 "$(ls "$STORE" 2>/dev/null | wc -l | tr -d ' ')"
expect "signed with the named spare: accepted from then on" good "$(verdict control-manifest "$D")"
doc "$T/naming2.json" control-manifest ", \"next_spare_key\": \"$(cat "$T/third-key.pub")\"" next-key
verdict control-manifest "$T/naming2.json" >/dev/null
doc "$D" control-manifest "" third-key
expect "the named spare names the next one: a chain" good "$(verdict control-manifest "$D")"
doc "$T/bad.json" app-feed ', "next_spare_key": "bm90IGEga2V5"'
expect "next_spare_key not a key: refused" refused "$(verdict app-feed "$T/bad.json")"
# The Swift side keeps the same files: OmacVM.app and the Bridge trust the same keys.
for f in "$STORE"/*.json; do
  python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
d = bytearray(open(p, "rb").read()); d[len(d) // 2] ^= 1
open(p, "wb").write(bytes(d))
PY
done
expect "kept documents changed on disk: the named keys are not trusted" refused "$(verdict control-manifest "$D")"
rm -rf "$STORE"; mkdir -p "$STORE"
cp "$T/next-key.pub" "$STORE/0123456789abcdef.json"; echo x > "$STORE/0123456789abcdef.json.sig"
doc "$D" control-manifest "" next-key
expect "a bare key file in the folder: not trusted" refused "$(verdict control-manifest "$D")"
rm -rf "$STORE"

# ---- a leaked named spare: revoked by a document a shipped key signed ----
"$T/sign" keygen "$T/other-key" > "$T/other-key.pub"
doc "$T/naming.json" app-feed ", \"next_spare_key\": \"$(cat "$T/next-key.pub")\"" spare-key
verdict app-feed "$T/naming.json" >/dev/null
doc "$T/naming2.json" control-manifest ", \"next_spare_key\": \"$(cat "$T/third-key.pub")\"" next-key
verdict control-manifest "$T/naming2.json" >/dev/null
doc "$D" control-manifest "" third-key
expect "before: the chain of named spares is trusted" good "$(verdict control-manifest "$D")"
doc "$T/r.json" app-feed ", \"revoked_keys\": [\"$(cat "$T/test-key.pub")\", \"$(cat "$T/spare-key.pub")\"]" next-key
verdict app-feed "$T/r.json" >/dev/null
doc "$D" control-manifest
expect "a named spare revoking the shipped keys: ignored" good "$(verdict control-manifest "$D")"
while IFS='|' read -r what field; do
  doc "$T/r.json" app-feed ", \"revoked_keys\": $field"
  expect "revoked_keys $what: refused" refused "$(verdict app-feed "$T/r.json")"
done <<EOF
empty|[]
as a string|"$(cat "$T/next-key.pub")"
not a key|["bm90IGEga2V5"]
twice the same|["$(cat "$T/next-key.pub")", "$(cat "$T/next-key.pub")"]
EOF
doc "$T/r.json" app-feed ", \"revoked_keys\": [\"$(cat "$T/next-key.pub")\"]" stranger-key
verdict app-feed "$T/r.json" >/dev/null
doc "$D" control-manifest "" next-key
expect "a revocation signed by a stranger: nothing changes" good "$(verdict control-manifest "$D")"
doc "$T/r.json" app-feed ", \"revoked_keys\": [\"$(cat "$T/next-key.pub")\"]"
expect "a feed revoking the leaked spare (signed by the main key)" good "$(verdict app-feed "$T/r.json")"
expect "the revoked spare: refused from then on" refused "$(verdict control-manifest "$D")"
doc "$D" control-manifest "" third-key
expect "the one it named: refused too" refused "$(verdict control-manifest "$D")"
doc "$T/n.json" app-feed ", \"next_spare_key\": \"$(cat "$T/next-key.pub")\""
verdict app-feed "$T/n.json" >/dev/null
doc "$D" control-manifest "" next-key
expect "the revoked key named again: still refused" refused "$(verdict control-manifest "$D")"
# A later release ships the spare as main: the old main's revocation no longer counts, the spare's does.
rotated="$(cat "$T/spare-key.pub") $(cat "$T/other-key.pub")"
expect "keys rotated: a revocation only the old main signed no longer counts" good "$(OMACVM_RELEASE_TEST_KEYS=$rotated verdict control-manifest "$D")"
doc "$T/r2.json" app-feed ", \"revoked_keys\": [\"$(cat "$T/next-key.pub")\"]" spare-key
verdict app-feed "$T/r2.json" >/dev/null
expect "the same revocation signed by the spare: kept too" 8 "$(ls "$STORE" | wc -l | tr -d ' ')"
expect "after the rotation the leaked key stays revoked" refused "$(OMACVM_RELEASE_TEST_KEYS=$rotated verdict control-manifest "$D")"
OMACVM_REVOKED_KEYS="$(cat "$T/next-key.pub") $(cat "$T/next-key.pub")" "$R/src/release/release-key.sh" revoked > "$T/field"
expect "release-key.sh revoked: the field, once per key" ", \"revoked_keys\": [\"$(cat "$T/next-key.pub")\"]" "$(cat "$T/field")"
expect "release-key.sh revoked: not a key refused" 1 "$(OMACVM_REVOKED_KEYS=bm90 "$R/src/release/release-key.sh" revoked >/dev/null 2>&1; echo $?)"
rm -rf "$STORE"

# ---- junk in the folder (names that sort first) counts toward nothing ----
mkdir -p "$STORE"
for i in 0 1 2 3 4 5 6 7 8 9; do
  n=000000000000000$i
  printf '{"kind": "app-feed", "next_spare_key": "%s"}' "$(cat "$T/other-key.pub")" > "$STORE/$n.json"
  cp "$T/doc.json.sig" "$STORE/$n.json.sig"
done
doc "$D" control-manifest "" other-key
expect "10 junk documents: their key is not trusted" refused "$(verdict control-manifest "$D")"
doc "$T/naming.json" app-feed ", \"next_spare_key\": \"$(cat "$T/next-key.pub")\"" spare-key
verdict app-feed "$T/naming.json" >/dev/null
doc "$D" control-manifest "" next-key
expect "10 junk documents first: a real one is still kept and trusted" good "$(verdict control-manifest "$D")"
rm -rf "$STORE"
# More junk than the old 256-file cap, on both sides of the real names: copies
# (skipped by name), a few named by their hash (checked and dropped), a pipe.
mkdir -p "$STORE"
printf '{"kind": "app-feed", "next_spare_key": "%s"}' "$(cat "$T/other-key.pub")" > "$T/junk.json"
for i in $(seq 0 299); do
  for n in $(printf '%016x ffffffff%08x' "$i" "$i"); do
    cp "$T/junk.json" "$STORE/$n.json"; cp "$T/doc.json.sig" "$STORE/$n.json.sig"
  done
done
for i in 1 2 3; do
  printf '{"kind": "app-feed", "version": "%s", "next_spare_key": "%s"}' "$i" "$(cat "$T/other-key.pub")" > "$T/junk.json"
  n=$(cat "$T/junk.json" "$T/doc.json.sig" | shasum -a 256 | cut -c1-16)
  cp "$T/junk.json" "$STORE/$n.json"; cp "$T/doc.json.sig" "$STORE/$n.json.sig"
done
mkfifo "$STORE/00000000000b0000.json" "$STORE/00000000000b0000.json.sig"
verdict app-feed "$T/naming.json" >/dev/null
verdict control-manifest "$T/naming2.json" >/dev/null
doc "$D" control-manifest "" third-key
expect "603 junk documents and a pipe around them: a chain of two named keys is kept and trusted" good "$(verdict control-manifest "$D")"
doc "$D" control-manifest "" other-key
expect "... and the junk's key is not" refused "$(verdict control-manifest "$D")"
rm -rf "$STORE"

# ---- test keys count nowhere inside a release app ----
fake() {   # BUNDLE-ID: a copy of keys.py and the shipped keys in an app bundle
  local a=$T/Fake-$1.app
  mkdir -p "$a/Contents/Resources/omacvm/src/release" "$a/Contents/Resources/omacvm/src/lib"
  cp "$KEYS" "$a/Contents/Resources/omacvm/src/release/"
  cp "$R"/src/lib/release-key*.pub "$a/Contents/Resources/omacvm/src/lib/"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $1" "$a/Contents/Info.plist" >/dev/null
  echo "$a/Contents/Resources/omacvm/src/release/keys.py"
}
doc "$D" app-feed
expect "test keys in a test build (org.omacvm.sutest): used" 0 "$(python3 "$(fake org.omacvm.sutest)" verify app-feed "$D" >/dev/null 2>&1; echo $?)"
expect "test keys in a release build (org.omacvm.app): ignored" 1 "$(python3 "$(fake org.omacvm.app)" verify app-feed "$D" >/dev/null 2>&1; echo $?)"

# ---- the CLI's download of OmacVM.app (src/lib/app.sh) ----
source "$R/src/lib/app.sh"
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
mkdir -p "$T/www"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$T/www" > "$T/server.log" 2>&1 &
SERVER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.3; done
APP_DOWNLOADS=http://127.0.0.1:$PORT
# release VERSION APP [TEAMS] [KEY]: the zip of APP and its signed feed, as appcast.sh makes them.
release() {
  local d=$T/www/v$1 z
  rm -rf "$d"; mkdir -p "$d"; z=$d/OmacVM-$1.zip
  ditto -c -k --keepParent "$2" "$z"
  printf '{"schema": 1, "kind": "app-feed", "version": "%s", "url": "%s", "length": %s, "sha256": "%s", "devid_teams": [%s]}\n' \
    "$1" "$APP_DOWNLOADS/v$1/OmacVM-$1.zip" "$(stat -f %z "$z")" "$(shasum -a 256 "$z" | cut -d' ' -f1)" "${3:-\"ABCDE12345\"}" \
    > "$d/OmacVM-appcast.json"
  sign_doc "$d/OmacVM-appcast.json" "${4:-}"
}
download() {   # VERSION: ok, or app_download's reason
  rm -rf "$T/dl"; mkdir -p "$T/dl"
  if app_download "$1" "$T/dl" > /dev/null 2> "$T/err"; then echo ok; else tr '\r' '\n' < "$T/err" | grep -E 'not installed|failed' | tail -1; fi
}
# An ad hoc signed org.omacvm.app (built from source), version 9.9.9.
A=$T/adhoc/OmacVM.app
mkdir -p "$A/Contents/MacOS"
cp /usr/bin/true "$A/Contents/MacOS/OmacVM"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string org.omacvm.app" -c "Add :CFBundleShortVersionString string 9.9.9" \
  -c "Add :CFBundleExecutable string OmacVM" "$A/Contents/Info.plist" >/dev/null
codesign --force --sign - "$A" 2>/dev/null
expect "no feed for the release: refused" yes "$([[ $(download 9.9.8) == "no signed update feed"* ]] && echo yes || echo "$(download 9.9.8)")"
release 9.9.9 "$A" "" stranger-key
expect "feed signed by another key: refused" yes "$([[ $(download 9.9.9) == *"does not check out"* ]] && echo yes || echo no)"
release 9.9.9 "$A" '"722686Y34B"'
cp "$T/www/v9.9.9/OmacVM-appcast.json" "$T/feed-9.9.9"
release 9.9.8 "$A"; cp "$T/feed-9.9.9" "$T/www/v9.9.8/OmacVM-appcast.json"
cp "$T/www/v9.9.9/OmacVM-appcast.json.sig" "$T/www/v9.9.8/"
expect "the feed of another version (replayed): refused" yes "$([[ $(download 9.9.8) == *"does not check out"* ]] && echo yes || echo no)"
release 9.9.9 "$A" '"722686Y34B"'
printf 'x' >> "$T/www/v9.9.9/OmacVM-9.9.9.zip"
expect "zip changed after the feed was signed: refused" yes "$([[ $(download 9.9.9) == *"checksum"* ]] && echo yes || echo no)"
release 9.9.9 "$A" '"722686Y34B"'
expect "an ad hoc app: refused (no team the feed names)" yes "$([[ $(download 9.9.9) == *"Developer ID the signed feed names (722686Y34B)"* ]] && echo yes || echo no)"
# ---- the fast network's root service: whose QEMU it trusts (src/net/mac/install.sh --trust) ----
# A copy of the scripts it needs, fetching feeds from the test server.
tree() {   # DIR: src/ under DIR
  mkdir -p "$1/src/net/mac" "$1/src/lib" "$1/src/release"
  cp "$R/src/net/mac/install.sh" "$R/src/net/mac/omacvm-netd.c" "$1/src/net/mac/"
  cp "$R"/src/lib/release-key*.pub "$R/src/lib/version.sh" "$1/src/lib/"
  cp "$KEYS" "$1/src/release/"
  sed "s|^APP_DOWNLOADS=.*|APP_DOWNLOADS=$APP_DOWNLOADS|" "$R/src/lib/app.sh" > "$1/src/lib/app.sh"
}
fakeapp() {   # APP SIGN-ID: an org.omacvm.app 9.9.9 whose QEMU and daemon are signed with SIGN-ID ("-": ad hoc)
  mkdir -p "$1/Contents/Resources/runtime/bin" "$1/Contents/Library/LaunchServices"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string org.omacvm.app" -c "Add :CFBundleShortVersionString string 9.9.9" "$1/Contents/Info.plist" >/dev/null
  echo 'int main(void) { return 0; }' | xcrun clang -x c -o "$1/Contents/Resources/runtime/bin/OmacVM" -
  cp "$1/Contents/Resources/runtime/bin/OmacVM" "$1/Contents/Library/LaunchServices/org.omacvm.netd"
  codesign --force --timestamp=none --sign "$2" --identifier org.omacvm.app.qemu "$1/Contents/Resources/runtime/bin/OmacVM" 2>/dev/null
  codesign --force --timestamp=none --sign "$2" --identifier org.omacvm.netd "$1/Contents/Library/LaunchServices/org.omacvm.netd" 2>/dev/null
}
# APP: whose QEMU an install would trust; then where its root daemon would come from.
trusts() { "$T/cli/src/net/mac/install.sh" --trust --app "$1" 2>/dev/null; }
trust() { trusts "$1" | head -1; }
daemon() { trusts "$1" | sed -n 2p; }
# A Mac without Xcode's Command Line Tools, and a sudo that only notes it was asked.
mkdir -p "$T/noclt"
printf '#!/bin/sh\nexit 1\n' > "$T/noclt/xcode-select"
printf '#!/bin/sh\ntouch "%s"\nexit 1\n' "$T/sudo-asked" > "$T/noclt/sudo"
chmod +x "$T/noclt/xcode-select" "$T/noclt/sudo"
tree "$T/cli"
feed99() {   # TEAMS [KEY]: the signed feed of release 9.9.9
  mkdir -p "$T/www/v9.9.9"
  printf '{"schema": 1, "kind": "app-feed", "version": "9.9.9", "url": "%s", "length": 1, "sha256": "%s", "devid_teams": [%s]}\n' \
    "$APP_DOWNLOADS/v9.9.9/OmacVM-9.9.9.zip" "$(printf '%064d' 0)" "$1" > "$T/www/v9.9.9/OmacVM-appcast.json"
  sign_doc "$T/www/v9.9.9/OmacVM-appcast.json" "${2:-}"
}
fakeapp "$T/adhoc-net/OmacVM.app" -
feed99 '"722686Y34B"'
expect "fast network, an ad hoc app: its exact build only" "exact build" "$(trust "$T/adhoc-net/OmacVM.app")"
expect "fast network, an ad hoc app from the command line: the daemon is built from this source, not taken from the app" \
  "daemon: source" "$(daemon "$T/adhoc-net/OmacVM.app")"
expect "... and without Xcode's tools: refused" "daemon: refused" "$(PATH=$T/noclt:$PATH daemon "$T/adhoc-net/OmacVM.app")"
out=$(PATH=$T/noclt:$PATH "$T/cli/src/net/mac/install.sh" --app "$T/adhoc-net/OmacVM.app" 2>&1); rc=$?
expect "... an install says why and stops before asking for root" "3 yes no" \
  "$rc $([[ $out == *"is not run as root"*"Fast Network button"* ]] && echo yes || echo no) $([[ -e $T/sudo-asked ]] && echo yes || echo no)"
tree "$T/adhoc-net/OmacVM.app/Contents/Resources/omacvm"
expect "fast network, an ad hoc app's own copy of the script (its button): the app's daemon, its exact build" "exact build daemon: app" \
  "$("$T/adhoc-net/OmacVM.app/Contents/Resources/omacvm/src/net/mac/install.sh" --trust --app "$T/adhoc-net/OmacVM.app" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
if [[ -n ${OMACVM_TEST_DEVID_SIGN:-} ]]; then
  N=$T/devid-net/OmacVM.app
  fakeapp "$N" "$OMACVM_TEST_DEVID_SIGN"
  NT=$(codesign -dv "$N/Contents/Resources/runtime/bin/OmacVM" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  rm -rf "$T/www/v9.9.9"
  expect "fast network, Developer ID app, no feed for its release: its exact build only" "exact build" "$(trust "$N")"
  feed99 '"0000000000", "ABCDE12345"'
  expect "fast network, a team the signed feed does not list (a fake app of another team): refused, exact build only" "exact build" "$(trust "$N")"
  feed99 "\"$NT\"" stranger-key
  expect "fast network, the team in a feed signed by another key: refused" "exact build" "$(trust "$N")"
  expect "... and its daemon is built from this source, not taken from the app" "daemon: source" "$(daemon "$N")"
  feed99 "\"0000000000\", \"$NT\"" spare-key
  expect "fast network, the team in the signed feed (spare key): the team" "team $NT" "$(trust "$N")"
  expect "... and the app's own daemon" "daemon: app" "$(daemon "$N")"
  rm -rf "$T/www/v9.9.9"
  tree "$N/Contents/Resources/omacvm"
  expect "fast network, the app's own copy of the script (its button): the team, no feed needed" "team $NT" \
    "$("$N/Contents/Resources/omacvm/src/net/mac/install.sh" --trust --app "$N" 2>/dev/null | head -1)"
  expect "fast network, another app's copy of the script: no feed, exact build only, daemon from source" "exact build daemon: source" \
    "$("$N/Contents/Resources/omacvm/src/net/mac/install.sh" --trust --app "$T/adhoc-net/OmacVM.app" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
else
  echo "skip the fast network's Developer ID checks (set OMACVM_TEST_DEVID_SIGN to a Developer ID Application identity)"
fi

if [[ -n ${OMACVM_TEST_DEVID_APP:-} ]]; then
  V=$(defaults read "$OMACVM_TEST_DEVID_APP/Contents/Info" CFBundleShortVersionString)
  TEAM=$(codesign -dv "$OMACVM_TEST_DEVID_APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  release "$V" "$OMACVM_TEST_DEVID_APP" "\"$TEAM\""
  expect "a Developer ID app of the team the feed names: downloaded and checked" ok "$(download "$V")"
  expect "... it is there" yes "$([[ -d $T/dl/x/OmacVM.app ]] && echo yes || echo no)"
  release "$V" "$OMACVM_TEST_DEVID_APP" "\"0000000000\", \"ABCDE12345\""
  expect "the same app, the feed names other teams: refused" yes "$([[ $(download "$V") == *"Developer ID the signed feed names"* ]] && echo yes || echo no)"
  release "$V" "$OMACVM_TEST_DEVID_APP" "\"0000000000\", \"$TEAM\"" spare-key
  expect "old and new team listed, signed with the spare: downloaded" ok "$(download "$V")"
else
  echo "skip the Developer ID app download (set OMACVM_TEST_DEVID_APP to a release build)"
fi

exit $fail
