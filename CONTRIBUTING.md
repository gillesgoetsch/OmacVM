# Contributing to OmacVM

OmacVM makes Omarchy feel at home on a Mac. Help is welcome, and a good bug
report counts as help. One that comes with a fix counts twice.

## Report a problem

1. Run `omacvm check` (add `--vm NAME` for another VM). It often names the fix.
2. Look at [docs/troubleshooting.md](docs/troubleshooting.md).
3. Still broken? [Open a bug](https://github.com/gillesgoetsch/omacvm/issues/new?template=bug.yml)
   with what happened, your route, versions and the `omacvm check` output.

If your OmacVM has `omacvm report` (or *Report a problem* in the control
centre), use it: it fills the same form and takes out personal data first.

Ideas go in a [feature request](https://github.com/gillesgoetsch/omacvm/issues/new?template=feature.yml).
Problems in Omarchy itself, also without a VM, belong to
[omarchy-mac](https://github.com/omacom/omarchy-mac/issues).

## Get the code

```bash
git clone https://github.com/gillesgoetsch/omacvm && cd omacvm
./omacvm --version
```

Run `./omacvm` from your clone. `./install.sh` in a clone links that clone
as your `omacvm` command, so the command on your PATH runs your changes.

You need an Apple Silicon Mac (M1 or newer), Xcode Command Line Tools, and
for UTM, Fusion and Parallels Homebrew's `zstd` and `e2fsprogs`.

## Where things are

| Path | What |
|---|---|
| `omacvm`, `src/cmd/` | The command and its subcommands (`build`, `apply`, `check`, ...) |
| `src/lib/` | Mac-side shell libraries (finding VMs, the four apps, signing) |
| `src/guest/` | The VM side: installer (`install.sh`) and checks (`check.sh`) |
| `src/<feature>/` | One folder per feature, `mac/` and `guest/` inside. The list: `src/features.tsv` |
| `app/` | OmacVM.app: Swift launcher, QEMU runtime and its patches |
| `docs/` | For users; `docs/notes/` for developers |

The full map, the architecture and the dead ends are in [AGENTS.md](AGENTS.md).
It's written for coding agents and reads fine for humans.

## Test your change

**Quick checks**, the same ones CI runs:

```bash
brew install shellcheck                                     # once
.github/shell-files.sh | tr '\n' '\0' | xargs -0 -n1 /bin/bash -n   # macOS's bash 3.2
.github/shell-files.sh | tr '\n' '\0' | xargs -0 shellcheck -S error -s bash
git ls-files -z '*.py' | xargs -0 python3 -m py_compile
(cd app/app && swift build)
src/gestures/mac/build.sh && src/bridge/mac/build.sh
src/omanotch/mac/test.sh
src/tests/vm-names.sh
src/tests/prebuilt-manifest.sh
src/tests/gestures-off.sh
```

The Mac side runs on macOS's `/bin/bash` 3.2: no `declare -A`, `mapfile`
or `${var,,}`.

**On a VM.** Use a test VM, not the one you live in:

| You changed | Test with |
|---|---|
| Build questions, options | `./omacvm build --plan --json --vm-type app\|utm\|fusion\|parallels`: builds nothing |
| VM side (`src/guest`, a feature's `guest/`) | `./omacvm apply --no-mac --vm "OmacVM Test-<topic>"`, then `./omacvm check --vm "OmacVM Test-<topic>"` |
| Mac helpers (Bridge, Gestures, Omanotch) | `src/mac/install.sh --omanotch` (replaces the installed ones), then `./omacvm check` |
| The build itself | `./omacvm build --no-mac --vm-type ROUTE --vm-name "OmacVM Test-<topic>"`: 30 to 70 minutes |
| OmacVM.app | `cd app && scripts/build-app.sh`, then open `app/dist/OmacVM.app` |

Per route:

- **OmacVM.app**: needs macOS 15. The first app build compiles QEMU; `src/`
  must be committed (the app carries it as committed).
- **UTM**: UTM 5 (`brew install --cask utm@beta`). UTM 4 paints black windows.
- **VMware Fusion**: Fusion 13 or newer, free with a Broadcom account. The build
  compiles a patched Hyprland, so it takes about 15 minutes longer.
- **Parallels**: Standard edition allows 4 CPUs and 8 GB per VM; the build
  stays within your licence.

`--no-mac` on `build` and `apply` leaves your Mac's installed helpers alone.
`OMACVM_HEADLESS=1` starts test VMs without a window (UTM, Fusion, and
Parallels Pro or trial).
Delete test VMs when you're done.

## Pull requests

- **One concern per PR.** A fix and a cleanup are two PRs.
- **CI must pass.** The `check` workflow runs on every PR.
- **Plain commits.** One change per commit. The first line says what changes
  for the user: `Gestures: pinch works again after sleep`. No essays, no
  marketing words. `git log` shows the style.
- **Say what you tested**: which route, which Mac, `omacvm check` before and
  after. Behaviour changes need a real VM.
- **A new feature** needs its line in `src/features.tsv`, the build question,
  its on/off in the VM installer, a check line and docs. The full list is in
  AGENTS.md, section 9. New features start off by default if they're
  experimental.
- **No personal data**: no user or host names, addresses, tokens or Wi-Fi
  names in code, logs or screenshots.
- **Code from others** keeps its licence; add it to
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). A patch to QEMU,
  virglrenderer or Mesa goes in `app/runtime/patches/`, one concern per patch,
  with a header: what, why, upstream status, which test covers it.
- **Coding agents are welcome.** Point yours at AGENTS.md. You still own and
  have tested every line it wrote.

## Where help is wanted

Look for [good first issue](https://github.com/gillesgoetsch/omacvm/labels/good%20first%20issue)
and [help wanted](https://github.com/gillesgoetsch/omacvm/labels/help%20wanted).
Labels `route:app`, `route:utm`, `route:fusion`, `route:parallels`, `gpu` and
`docs` say where an issue lives.

Most wanted:

- **Macs we don't have.** M1, M2, MacBook Air, 8 or 16 GB, 60 Hz displays
  without HDR. A build and an `omacvm check` from one of those helps a lot.
- **GPU.** Vulkan, video and display work on OmacVM.app (`app/runtime/`).
- **Docs.** If a step confused you, fix the page so it doesn't confuse the
  next person.

OmacVM runs on Apple Silicon only. Intel Macs are out of scope.

## How we write

Short and plain, like Omarchy: say what it does, not how great it is. One idea
per sentence. That goes for code comments, commits, PRs and docs.

## Licence

OmacVM is MIT. By contributing you agree your work is MIT licensed too.
