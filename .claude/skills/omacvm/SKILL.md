---
name: omacvm
description: Set up, change, update or troubleshoot OmacVM (Omarchy in an OmacVM.app VM on an Apple Silicon Mac) with the omacvm command. Use when someone wants an Omarchy VM built, its CPUs or memory changed, a feature switched (macOS-native scroll momentum, trackpad gestures, Bridge, Omanotch, wallpaper, idle lock, autologin, memory-optimized kernel), OmacVM added to an existing Omarchy VM, updated, or checked.
---

# OmacVM

Drive everything through `./omacvm` in this repository (or `omacvm` on the
PATH after `./install.sh`). Read `AGENTS.md` section 0 for the recipes and
sections 7-8 before fixing anything by hand.

## Rules

- Without a terminal `omacvm` never asks: pass options, read `--json`.
  Exit codes: 0 done, 1 failed, 2 usage (the message names what is missing),
  3 needs a person (the message says what).
- Only the person can: choose their Omarchy password, grant macOS permissions
  (Location Services, Accessibility, Input Monitoring). Hand these over
  (`needs_human` in the JSON); never work around them, never invent a password.
- macOS-native scroll momentum (`scroll-momentum`) is experimental and off by default: offer it, let the person decide.
- A build takes 10-30 minutes (`minutes` in the plan): run it in the background and follow its output.
- Do not edit `/usr/share/omarchy` or the user's macOS Spaces; do not put
  personal data into this repository.

## New VM

1. `./omacvm vms --json`; then
   `./omacvm build --plan --json --vm-type app [--vm-name NAME] [--feature scroll-momentum=on]`.
2. Show the plan (resources, features, `needs_human`), ask for the password
   and for changes.
3. Run the plan's `command` with `OMACVM_PASSWORD` set.
4. Hand over `needs_human`; when the person is logged in to Omarchy,
   `./omacvm check --vm NAME --json` until `"ok": true` (entries with
   `"needs_human": true` are theirs).

## Existing VM

- Features: `./omacvm features --vm NAME --json`, then
  `./omacvm enable|disable FEATURE... --vm NAME --yes`, then check.
  Listing (features, check, vms) never starts a VM: one that is off is
  shown from its folder ("running": false). enable, disable and apply start
  a stopped VM only when it is named with --vm.
- CPUs and memory: `./omacvm resources --vm NAME --json` (what it has, the
  limits, the tiers), then `./omacvm resources --vm NAME --resources TIER`
  or `--cpus N --memory-gb N`; a change applies on the next start. A `warning` (memory above the Mac's
  Best tier) goes to the person as it is; their setting stays theirs.
- Omarchy installed by hand: `./omacvm apply --vm NAME`; exit 3 prints one
  command for the person to run in the VM's terminal, then apply again.
- Update: `./omacvm update` (or `--vm NAME`).
- A retired Parallels, UTM or VMware Fusion VM (`"retired": true` in `vms
  --json`): commands on it exit 3 (`"error": "route-retired"`). Offer the move:
  `omacvm build`, then copy files over. Never add those routes back without the
  owner's explicit consent.
- Problems: `./omacvm check --vm NAME --json`, then `AGENTS.md` section 7.
