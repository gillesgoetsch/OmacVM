# 0033: OmacVM.app updates itself (own updater, signed feed, rollback)

Status: accepted, built and tested end to end (branch `app-self-update`).
Live from 3.0.0, the first release that carries the release keys
(`src/lib/release-key.pub`, `release-key-spare.pub`; who holds them:
[docs/release-keys.md](../release-keys.md)).

## Context

People who use only OmacVM.app never open a terminal, so `omacvm update`
does not reach them. The app should update itself, on by default, checking
once a week, with one switch that silences it completely (no checks, no
messages), shared with the control centre in Omarchy. It must never break a
working install:

- only OmacVM's own builds: a signed feed, a checksum, a Developer ID of a
  team the signed feed names (`devid_teams`) on the new app;
- never replace the bundle while a VM's QEMU runs from it (STANDARDS 20);
- if the new version does not start, the old one comes back by itself; the
  previous version stays for one step back.

Things that shape the choice: the app is built with SwiftPM and scripts (no
Xcode project); people install it under a name they pick, and a renamed
copy is signed again ad hoc (`Installer`, `omacvm update`); the VM's QEMU
lives inside the bundle; releases are not notarized yet.

## Options

1. **Sparkle 2.** The standard, well reviewed, with its UI and delta
   updates. Here: a framework with XPC services to embed and sign in a
   bundle assembled by a script. It checks the new app against the
   *installed* app's signature, which for a renamed ad hoc copy is just the
   bundle id; there is no hook to check the unpacked app against our team
   before it is installed. A renamed copy would get the release's name
   back. No rollback. Its settings are its own defaults, not the shared
   switch. About half of what follows would be ours anyway.
2. **A small updater of our own on Sparkle's model**: signed feed, download,
   verify, swap by a helper after the app quits; plus what OmacVM needs.
   About 600 lines of Swift and 130 of bash, no dependency, unit tests
   without Xcode.
3. **Only `omacvm update`** (exists): needs a terminal; no weekly check.

## Decision

Option 2.

**Feed.** Each GitHub release gets `OmacVM-appcast.json` (`"kind":
"app-feed"`, version, zip URL, length, SHA-256, minimum macOS, notes URL) and `OmacVM-appcast.json.sig`
(Ed25519 over the exact bytes, base64), made by `app/scripts/appcast.sh`
from `package-release.sh`. The app fetches both from
`releases/latest/download/` and checks the signature with CryptoKit against
`src/lib/release-key.pub` inside its signed bundle before it reads a field.
Fields are strict (types, version form, 64 hex, https or a test feed on
127.0.0.1); feed 64 KB and zip 2 GB at most. Only a version newer than the
running one is offered, so an old signed feed cannot downgrade.

**When.** 20 s after launch and hourly while the app runs, a check is made
when the last one is a week old (or in the future: the clock went back),
never while `update_checks` is false in
`~/Library/Application Support/omacvm/settings.json` (the control centre's
file). Automatic checks stay off metered and Low Data networks. "Check for
Updates…" in the app menu always works. A server answer, even a 404, starts
the week again, so there is no hourly retry while no release has a feed.

**Download and checks.** The zip goes to
`~/Library/Application Support/OmacVM/Updates/<bundle id>/<copy>/staged/`: size and
SHA-256 from the feed, then unpacked: exactly one app, our bundle id, the
version the feed named, `codesign --verify --deep --strict` with OmacVM's
Developer ID requirement on the app and on its QEMU (the part with the
Hypervisor entitlement), all with Security.framework. Anything off: deleted,
logged, nothing offered.

**Offer.** The window shows "OmacVM X is ready to install" with What's New,
Skip This Version and Update and Relaunch. With checks off nothing is shown.
While a VM runs the launcher has no window: the offer waits for the next
time the window opens. An update asked for while a VM runs or is being
built (`--update-now`, a script or later the control centre) waits and goes
in once nothing runs from the app: when the launcher's VM ends (shut down or
crashed), on a check every 30 s while the launcher is open (a VM started by
the CLI, or by a launcher that crashed, has no runner to report its end), and
at the next launch (the request is kept). A hidden `--update-now` launcher
does not stay behind to wait. When the waiting update goes in because the
user quit the app or shut the VM down, the new version only checks that it
starts and quits again (`--update-quiet`, opened in the background): no
window the user did not ask for. The next launch says it updated; a failed
start rolls back without opening anything either.

**Swap and rollback.** `update-swap.sh` runs from a copy outside the bundle
(bash reads scripts as it runs). It waits for the app to quit, refuses while
any process runs from inside the bundle, moves the app to `previous/` and the
new one into its place (renames on one volume; right after the first rename
it looks again, and if something was started in between, everything goes
back), and starts it with
`--update-check TOKEN`. The new app starts its QEMU with `--version` (that
loads every library) and writes `launch-TOKEN`: "ok", or "fail" and exits.
Without "ok" within 90 s the script stops whatever runs from the bundle, puts
the old app back, and the old app skips that version. 90 s, not 60: the first
launch of a new bundle can be slow (XProtect scans it; an 8 GB M1 under
memory pressure), and a false rollback is safe but skips a good version until
the next one (or Check for Updates… by hand, which offers it again). The version kept from
before stays aside until the new one has started. `previous/` gives one step
back (app menu: Go Back to X), with the same script and checks. A copy
installed under its own name keeps it: the new app gets the name and is
signed again ad hoc, as the installer does (checked before that, as
downloaded).

**One folder per copy.** Two copies with one bundle id (OmacVM.app and a
renamed Omarchy.app, a copy on a USB disk) must not share a kept version, a
download or a swap result: one would delete the other's Go Back version.
Each copy has its own folder, `Updates/<bundle id>/<name>-<8 hex digits of
SHA-256 of its real path>/`, with its state as small files (`last-check`,
`skip`, `install-pending`, `app` = where the copy is) instead of the
defaults, which the copies share. A moved app starts a new folder; a folder
whose app has been gone for 30 days is removed by the next copy that starts.

**An app on another disk.** A rename is only atomic, and only a rename, on
one volume; across volumes `mv` copies and deletes, and a failure halfway
leaves no app. So `previous/` and `incoming/` live on the app's volume:
in the copy's folder when that is on the same volume (the usual case,
/Applications and ~/Library), else in `.omacvm-updates/<copy>/` next to the
app. The app copies the staged update there (a clone on APFS), checks the
copy (bundle id, version, Developer ID) and only then hands it to the
script, which refuses a work folder or a new app on another volume than the
app ("nothing moved"). The swap is then two renames on that volume, each
checked and undone on failure.

**Notarization** is not available yet. The app downloads with URLSession,
which sets no quarantine flag, so Gatekeeper does not assess the new app at
its first start (as with `omacvm update`'s curl). The trust comes from two
independent keys: the release key signs the feed, the Developer ID signs the
app. A stolen release key alone cannot ship code, a stolen Developer ID alone
cannot get into the feed. Once releases are notarized, a stapled-ticket check
becomes required from the version that adds it: a constant in the app, never
a field in the feed.

**Release keys** (decided 2026-10-05): two Ed25519 keys, main and spare, both
public halves in every copy; a document signed by either is valid. They sign
the app feed, the control centre's manifest and the prebuilt manifests. All
are JSON, so each carries a required `kind` (`app-feed`, `control-manifest`,
`prebuilt-manifest`) and each parser refuses the others. The main private
key lives in the release Mac's Keychain (`org.omacvm.release-key`) and in
1Password, the spare only in 1Password and offline; the release step signs
locally, where the Developer ID already lives. Not a GitHub Actions secret:
anyone who can change a workflow could then sign a manifest that makes Macs
check out another commit (0032), where the release key is the only guard.
Rotation: a signed feed may name a new spare (`next_spare_key`); the app keeps
that signed feed (not a bare key) and trusts the key from then on. Losing the
main key costs nothing but that rotation; losing both means one manual
update for everyone. Steps: [docs/release-keys.md](../release-keys.md).

**Developer ID team from the feed.** The team the new app must be signed by
is not built into the app: the signed feed names one to four
(`devid_teams`), and a missing or empty list refuses the update. A change of
Developer ID is a feed signed with our key that names the old and the new
team. The staged update keeps its signed feed and is checked against it again
at the next launch.

**Check Now and updates with a running VM** (3.0.2). The window has a
Check Now button next to the weekly switch; it works with weekly checks off
(a check by hand always does) and its result stays for the session. When
this launcher runs a VM, an update shuts it down cleanly (power button, then
the guest agent), installs, and the new app starts the VM again: one confirm
on the Mac ("Shut Down and Update"), or `u` in the VM's control centre
(`app-update`, ADR 0031). The state file `restart-vm` (VM folder, version,
time) names the VM; the new app, or the old one after a rollback or an
aborted swap, starts it once and only within 15 minutes, so a stray launch
never starts a VM by surprise. If the VM still runs after 3 minutes the
update stops and nothing is forced: the Mac asks, with OK as the default and
"Force Off and Update" as the second confirm. Quitting the app meanwhile
cancels it. It refuses while a check, another update, a build or a disk move
runs. While a VM runs, QEMU owns the menu bar and has no update item, so the
control centre is the way to update then (a menu item there needs a QEMU
patch: later). `update-swap.sh` is unchanged.

**Release channel.** A release is published as a pre-release first and its
zip tried by hand; installed apps see it only once it is marked latest.
Release builds ignore `OMACVM_APPCAST_URL` (see test hooks below), so the
update path itself is tested with test builds.

## Consequences

- The app updates only itself. Existing VMs keep their VM side until
  `omacvm update` or the control centre installs it; Mac helpers likewise.
  New VMs get the new app's copy.
- `omacvm update` still replaces the app when it is closed (same checks, no
  rollback). Both paths keep working side by side.
- Test hooks: `OMACVM_APPCAST_URL`, `OMACVM_APPCAST_KEY` (test keys, space-separated),
  `OMACVM_SETTINGS_DIR`, `OMACVM_COCOA_HIDDEN`; `build-app.sh --id` makes test
  builds that share nothing with an installed OmacVM. Only test builds read
  the first three: a build with the release id `org.omacvm.app` ignores them
  and `update-swap.sh` does not pass them on to it. Otherwise a process that
  can `launchctl setenv` could point the app at its own feed, and every local
  build is signed with the same Developer ID as a release.
- Tests: `swift run update-tests` (CI) and `app/scripts/dev/self-update-test.sh`
  (this Mac: weekly schedule, switch off, held back while a VM runs and
  applied after (quietly after a shutdown), rollback of two broken builds,
  one step back, a renamed copy with its own folder, an app on another disk
  (a disk image)). `--render-update-ui DIR` (test builds only) draws the
  window's update states, the app menu and the alerts into PNGs, light and
  dark, without showing a window.
- Not covered: delta updates (a full zip, about 13 MB, at most once a week),
  an install that needs an administrator (the app only updates where it can
  write: the folder and the bundle itself, which the swap renames; a copy
  owned by root or another admin says so once and checks nothing), copies run
  from a translocated or read-only place (it says so).
