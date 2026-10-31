# Releasing OmacVM

For maintainers. One script does a release, step by step:
`src/release/release.sh`. Each step checks what it made and stops at the
first problem; fix it and run the script again from that step.

## What a release carries

| File | For |
|---|---|
| `OmacVM-X.Y.Z.zip` + `.sha256` | OmacVM.app (Developer ID signed, notarized when the notary profile exists) |
| `OmacVM-appcast.json` + `.sig` | the app's own updates, and `omacvm build --vm-type app` / `omacvm update` when they download the app |
| `omacvm-manifest.json` + `.sig` | the control centre's update check (the Bridge) |
| release `prebuilt-X.Y.Z`: `omacvm-prebuilt-X.Y.Z-app.*` | the app's prebuilt VM (`make-image.sh app`), its manifest signed |

Installed apps and the Bridge read `releases/latest`, so a release is live for
them once it is the latest one. Users of 2.9.x update once with
`omacvm update` (it pulls the new command line from `main`, which downloads
the app through the signed feed); 2.9.x apps do not check by themselves.

## Before

- The release Mac: Apple Silicon, `gh` logged in, the Developer ID in the
  login keychain (`OMACVM_SIGN_ID` = its SHA-1), the release key in the
  Keychain ([release-keys.md](release-keys.md)).
- Notarization: once, `xcrun notarytool store-credentials omacvm --apple-id
  <id> --team-id <team>`. Without it the release goes out signed but not
  notarized (`OMACVM_RELEASE_UNNOTARIZED=1`), as 2.x did.
- KosmicKrisp: a release has it. A Mac without Xcode 26 and Homebrew's LLVM
  takes one built on a Mac that can (the Mac mini), from the same commit:
  there `app/runtime/build-kosmickrisp.sh`, then copy
  `app/runtime/.build/kosmickrisp/` here and set
  `OMACVM_KOSMICKRISP_FROM=<that folder>`. Its stamp must name this
  checkout's Mesa commit and build script, or it is refused. Without
  KosmicKrisp: `OMACVM_RUNTIME_KOSMICKRISP=0 OMACVM_RELEASE_NO_KOSMICKRISP=1`
  (MoltenVK only).
- The release text in `~/omacvm-work/release-X.Y.Z/release-text.md`
  (`OMACVM_RELEASE_NOTES`). Lines between `<!-- if-unnotarized -->` and
  `<!-- end-if -->` are dropped when the app is notarized. No "pending" left,
  in it, in the CHANGELOG section or in the README ("(pending #N)" marks an
  item whose PR is not merged yet; take the mark out when it is).

## Dry run

```bash
export OMACVM_SIGN_ID=<SHA-1> OMACVM_KOSMICKRISP_FROM=~/omacvm-work/release-X.Y.Z/kosmickrisp
src/release/release.sh --dry-run X.Y.Z check bump merge build notarize package verify image
src/release/release.sh --dry-run X.Y.Z rollback-prep
src/release/release.sh --dry-run X.Y.Z clean
```

Nothing leaves the Mac: the release commit is local, nothing is pushed,
merged, tagged or uploaded. The release key signs for real, and the notary
service is used for real when the profile exists. Output and the time of each
step: `~/omacvm-work/release-X.Y.Z/dry-run/` (`times.tsv`).

## Release

```bash
src/release/release.sh X.Y.Z
```

| Step | What it does |
|---|---|
| check | tools, keys, Developer ID, notary profile, KosmicKrisp, the release PR (`OMACVM_RELEASE_PR`, 77) open with CI green, CHANGELOG, README and release text without "pending" |
| bump | release commit on the PR's branch: `src/VERSION`, CHANGELOG heading; merges `main` in if it moved; pushes |
| merge | waits for CI, merges the PR with a merge commit M |
| build | `build-app.sh --release` in a worktree at M (or an app built at M on another Mac: below); build tests pass, OmacVMCommit = M, helpers signed and timestamped |
| notarize | `notarytool submit --wait`, staple, `spctl` says Notarized Developer ID |
| package | `package-release.sh` (zip, sha256, signed app feed), `manifest.py build --out` (signed control manifest, parts compared with the last release's) |
| verify | sha256; `keys.py app-feed`; the control manifest; `feed-check` (the app's own update code: signature, zip size and sha256, bundle id, version, Developer ID of the feed's team on the app and its QEMU); a changed feed is refused |
| image | `make-image.sh app build generalize package clean` (about 15-20 min, a headless VM, on the worktree's runtime build, or on the app's own runtime for an app from another Mac), or `OMACVM_RELEASE_IMAGE_FROM` (a signed image of this version, e.g. from the dry run) |
| e2e | the gate: `src/tests/e2e/cc-switches.sh` passed on the test Mac for a test identity build of M (every switch in the control centre, the fast network, Touch ID, Graphics, update checks, the app's window, the update from the release before; [src/tests/e2e/README.md](../src/tests/e2e/README.md)). Its `result.json` in `OUT/e2e/` (`OMACVM_RELEASE_E2E_RESULT`), or run it now with `OMACVM_E2E_SSH` + `OMACVM_E2E_ARGS`. `OMACVM_RELEASE_E2E_OVERRIDE="<why>"` goes without it and logs the reason; publish refuses otherwise |
| publish | tag M, `gh release create` with the six files (latest), then the image to `prebuilt-X.Y.Z` |
| after | downloads what GitHub serves and checks it again; `releases/latest` serves the new feed and manifest; the prebuilt lookup finds the image |

`merge`, `publish` and `rollback` ask before they change GitHub; `--yes`
skips the question.

The e2e gate takes 1-2 hours on the test Mac: start it as soon as M exists
(`release.sh X.Y.Z e2e` after `merge`, or `src/tests/e2e/remote.sh M OUT/e2e`
by hand) and build, package and the image meanwhile.

Before `publish`, every release also runs the on-screen test,
`src/tests/e2e/onscreen.sh` ([src/tests/e2e/README.md](../src/tests/e2e/README.md#on-screen-before-every-publish-onscreensh)),
on a test identity build of M (or `OmacVM-X.Y.Z.zip` relabeled with
`src/tests/e2e/relabel.sh`) on each macOS there is a test Mac for (macOS 15,
26, 27), with that Mac's VM lock held and nobody at it: the app's window
size, Update VM, a switch with the VM stopped, the VM's window around full
screen, the Mac's cursor over the VM, and nothing left running after stop
and quit. About 15 minutes per Mac. Its `result.json` goes into
`OUT/onscreen/<mac>/`; publish only when each says `pass`, or write down
why a row could not run (a macOS without a Mac, BLOCKED because someone
used it) in the release's notes for the maintainer. A FAIL stops the
release like a failed step.

After: close the PRs that shipped through the release PR, update the
README cells that waited for the release, remove the worktrees
(`release.sh X.Y.Z clean`).

### An app built on another Mac

The keys, the Developer ID and the notary profile stay on the release Mac.
Another Mac without them may build the app; the release Mac checks it,
signs it and does the rest:

1. On the release Mac: `release.sh X.Y.Z check bump merge` (M = the merge
   commit).
2. On the build Mac, at M: `OMACVM_SIGN_ID=- app/scripts/build-app.sh
   --release` (ad hoc; the runtime from source, `OMACVM_KOSMICKRISP_FROM` as
   for any release). Bring `app/dist/OmacVM.app` and the build's output into
   one folder on the release Mac, `DIR/OmacVM.app` and `DIR/build.log`, with
   the files' modes and links kept (`ditto`, `rsync -a`).
3. Before anything signs it, compare it with the previous release
   (`OmacVM-PREV.zip` from GitHub, its sha256 checked), file by file: each
   difference is a signature, a Mach-O UUID or build path, or a file the
   commits PREV..M changed. Anything else you let through goes into the
   release's notes with the reason.
4. `OMACVM_RELEASE_APP_FROM=DIR src/release/release.sh X.Y.Z build notarize
   package verify image e2e publish after`, DIR an absolute path (a relative
   one is refused). Step build does not build: it checks the app against M
   (bundle id, OmacVMCommit = M, the version, `Contents/Resources/omacvm` =
   `git archive M` file by file), copies it into the worktree and signs it
   with M's own `app/scripts/sign-app.sh` (build-app.sh's signing), then
   runs its usual checks. Nothing of the app runs before that. Nothing built
   a runtime in the worktree, so step image makes the VM with the app's own
   scripts and runtime (`make-image.sh` with `OMACVM_PREBUILT_APP`);
   `OMACVM_RELEASE_RUNTIME_FROM` beside `OMACVM_RELEASE_APP_FROM` is refused.

In a dry run M is bump's local commit: the other Mac builds that commit
(`--dry-run X.Y.Z check bump`, the build there, then `--dry-run X.Y.Z build
...` with `OMACVM_RELEASE_APP_FROM`).

## Rollback

Installed apps never go to an older version by themselves, so a broken
release is fixed by the next one (X.Y.Z+1). Until then:

```bash
src/release/release.sh X.Y.Z rollback-prep   # before publishing: the last release's feed, signed, kept
src/release/release.sh X.Y.Z rollback
```

1. X.Y.Z becomes a pre-release; the release before is `latest` again.
2. X.Y.Z's feed and manifest are removed: nothing installs it by itself any
   more (the command line needs the signed feed; the Bridge its manifest).
3. The release before gets its own signed feed, so apps see "up to date".
4. `main`: `git revert -m 1 M` in a PR, so `omacvm update` brings the old
   command line back to checkouts that follow `main`. Or fix forward.
   `install.sh`'s checkout follows the release tags and never goes back: it
   stays at X.Y.Z until X.Y.Z+1.
5. Prebuilt: `gh release edit prebuilt-X.Y.Z --draft` hides the image.

An app that updated itself to X.Y.Z (from 3.0.0 on) can go back with OmacVM › Go Back.
