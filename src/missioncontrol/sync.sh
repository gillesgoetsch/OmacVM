#!/bin/bash
# OmacVM's copy of the Mac Mission Control plugin (feature mission-control)
# from its own repository, which stays the one source of it: OmacVM ships
# the files of one commit byte for byte and never edits them (a change the
# plugin needs goes to its repository first). For developers, not the VM:
#   sync.sh TAG            pin a released tag: its commit, the files, SHA256SUMS
#   sync.sh --commit SHA   pin a commit that is no tag yet (a release not out)
#   sync.sh --check        the pinned commit and tag as they are on GitHub, and
#                          the files here the same as at that commit
#   sync.sh --released     a PIN on stdin names a released tag (release.sh)
# Prints `git diff --stat` from the previous pin to the new one, for the pull
# request. Refuses a tag that no longer points at the pinned commit (--check)
# and a commit that is not the tag's.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
PIN=$here/PIN SUMS=$here/SHA256SUMS DEST=$here/plugin/mac.missioncontrol
FILES=(manifest.json MissionControl.qml Layout.js shadow.frag.qsb hypr/mac-mission-control.lua LICENSE)
usage() { echo "usage: sync.sh TAG | --commit SHA | --check | --released < PIN" >&2; exit 2; }
pin() { sed -n "s/^$1 //p" "$PIN" | head -n 1; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

# --released: the PIN on stdin names a released tag (release.sh's check
# step: a release never ships a commit before the plugin's release).
if [[ ${1:-} == --released ]]; then
  t=$(sed -n 's/^tag //p')
  [[ $t =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] && { echo "ok   the plugin is pinned at its release $t"; exit 0; }
  echo "the plugin is pinned at a commit that is no release (tag ${t:-none}): sync.sh TAG" >&2; exit 1
fi

REPO=$(pin repo); OLD=$(pin commit); OLD_TAG=$(pin tag)
[[ $REPO == https://github.com/gillesgoetsch/omarchy-mac-mission-control.git ]] || { echo "sync.sh: PIN names no known repo: $REPO" >&2; exit 1; }
TAG="" COMMIT=""
case ${1:-} in
  --check) TAG=$OLD_TAG COMMIT=$OLD; [[ $TAG == - ]] && TAG="" ;;
  --commit) [[ ${2:-} =~ ^[0-9a-f]{40}$ ]] || usage; COMMIT=$2 ;;
  -*|"") usage ;;
  *) [[ $1 =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || usage; TAG=$1 ;;
esac

# The tag as GitHub has it: an annotated tag's commit (^{}) or a light one's.
tag_commit() {
  local out c
  out=$(git ls-remote "$REPO" "refs/tags/$1" "refs/tags/$1^{}") || return 1
  c=$(awk -v t="refs/tags/$1^{}" '$2 == t { print $1 }' <<<"$out")
  [[ -n $c ]] || c=$(awk -v t="refs/tags/$1" '$2 == t { print $1 }' <<<"$out")
  [[ $c =~ ^[0-9a-f]{40}$ ]] && echo "$c"
}
if [[ -n $TAG ]]; then
  c=$(tag_commit "$TAG") || { echo "sync.sh: the plugin has no tag $TAG" >&2; exit 1; }
  if [[ -n $COMMIT && $c != "$COMMIT" ]]; then
    echo "sync.sh: tag $TAG points at $c now, the pin says $COMMIT: the tag moved; not taken" >&2; exit 1
  fi
  COMMIT=$c
fi

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
git clone --quiet --no-checkout "$REPO" "$W/repo"
git -C "$W/repo" cat-file -e "$COMMIT^{commit}" 2>/dev/null || { echo "sync.sh: $COMMIT is not in $REPO" >&2; exit 1; }
for f in "${FILES[@]}"; do
  mkdir -p "$W/files/$(dirname "$f")"
  git -C "$W/repo" show "$COMMIT:$f" > "$W/files/$f"
done
( cd "$W/files" && sha256 "${FILES[@]}" ) > "$W/SHA256SUMS"
# A tag says the release in its manifest: v1.0.1 has version 1.0.1.
if [[ -n $TAG ]]; then
  v=$(jq -r .version "$W/files/manifest.json")
  [[ $v == "${TAG#v}" ]] || { echo "sync.sh: tag $TAG has manifest version $v; not taken" >&2; exit 1; }
fi

if [[ ${1:-} == --check ]]; then
  if cmp -s "$W/SHA256SUMS" "$SUMS" && ( cd "$DEST" && sha256 -c --quiet "$SUMS" ) >/dev/null 2>&1 &&
     [[ $(cd "$DEST" && find . -type f | sed 's|^\./||' | LC_ALL=C sort) == "$(printf '%s\n' "${FILES[@]}" | LC_ALL=C sort)" ]]; then
    echo "ok   the copy is the plugin at ${OLD_TAG/#-/an untagged commit} ($COMMIT)"
  else
    echo "FAIL the copy here is not the plugin at $COMMIT: sync.sh ${OLD_TAG/#-/--commit $COMMIT}" >&2; exit 1
  fi
  exit 0
fi

rm -rf "$DEST"; mkdir -p "$DEST"
cp -R "$W/files/." "$DEST/"
cp "$W/SHA256SUMS" "$SUMS"
{ echo "# The Mac Mission Control plugin OmacVM ships (feature mission-control): the files of"
  echo "# this commit of its repository, byte for byte (SHA256SUMS). Never edited here: a change"
  echo "# goes to the plugin's repository, then src/missioncontrol/sync.sh pins the new tag."
  echo "repo $REPO"
  echo "tag ${TAG:--}"
  echo "commit $COMMIT"
} > "$PIN"
echo "pinned $( [[ -n $TAG ]] && echo "tag $TAG" || echo "untagged commit") $COMMIT ($(jq -r .version "$DEST/manifest.json"))"
[[ -z $TAG ]] && echo "note: not a released tag; pin one before a release (sync.sh TAG)"
if [[ -n $OLD && $OLD != "$COMMIT" ]] && git -C "$W/repo" cat-file -e "$OLD^{commit}" 2>/dev/null; then
  echo "changes since $OLD:"
  git -C "$W/repo" diff --stat "$OLD" "$COMMIT"
fi
