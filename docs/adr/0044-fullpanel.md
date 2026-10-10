# 0044: Omanotch is the shared notch integration; FullPanel is OmacVM.app only, experimental

Status: accepted, built (FullPanel: off by default, experimental, OmacVM.app
only; next release after 3.0.15). Proposed with a working branch by
@brianmerchant in [#339](https://github.com/gillesgoetsch/OmacVM/issues/339).

## Context

On a MacBook with a notch, macOS keeps a full-screen window below the camera
housing and covers the strip beside it with the full-screen Space's menu
bar. Omanotch fills that strip on every route: a hidden `NOTCH` output in
the VM renders Omarchy's bar, notchcast streams it, and a small Mac app
draws it above the menu bar. UTM, VMware Fusion and Parallels enforce
macOS's full screen, so this is their only way to use the strip.

OmacVM.app runs its own QEMU and owns its window. #339 showed that its full
screen can cover the strip itself: AppKit's private full-screen frame is
hooked to the whole display, and that Space's menu bar is made transparent
(SkyLight), as UTM does on macOS 27. The guest then draws its own bar in
the strip, with no stream.

## Decision

- **Omanotch stays the default and the shared integration** for all four
  routes. Nothing in it is removed.
- **FullPanel is an addition for OmacVM.app**, experimental, off by default,
  per VM (the VM folder's `notch-mode` file, like Graphics): the app's
  switch "Use the notch area (experimental)" (only on a Mac with a notch,
  only with "Start in full screen"), `omacvm notch --vm NAME
  fullpanel|native`, the control centre's Notch area row.
- **One start, one mode.** The app decides at each start
  (`NotchArea.start`): FullPanel only with the setting, a full-screen start,
  a notch now, and the VM ready for it (`fullpanel-ready` from `omacvm
  apply`). Then QEMU gets `OMACVM_FULLPANEL=1`, the guest gets the camera
  housing in Mac points (SMBIOS `omacvm.fullpanel=LxRxHxWxD`, measured from
  the built-in screen at that start, so every MacBook gets its own height),
  and the VM gets no Omanotch link for that start. Its features keep
  Omanotch on, so the next native start has it again without any change.
- **QEMU:** a regular pinned patch pair
  (`omacvm-cocoa-fullpanel-logic.patch`: the rules, tested without a notch;
  `omacvm-cocoa-fullpanel.patch`: the wiring), applied after the other
  cocoa patches. Per window: only a window on a display with a camera
  housing; external displays keep normal full screen. Anything private that
  is missing or changed gives normal full screen, logged once.
- **Guest:** no second bar. Omanotch's bar patch (v20) has a FullPanel
  mode: on the built-in display's output, only while the app's layout says
  that output covers the whole display in full screen, the bar is the
  strip's height, split around the housing, and reserves the strip.
  notchcast's unit skips such a boot (`ExecCondition`).
- **Check:** `omacvm check` names the mode, and for FullPanel whether QEMU
  covers the strip and that Omanotch is idle.

## Not done, and why

- **No app-wide setting** (#339's branch had one): a VM moved to a Mac
  without a notch, or to the other route, must not change behaviour.
- **No build-time source transformer** for `ui/cocoa.m`: every QEMU change
  is a pinned patch with a test, as the others.
- **Not the default.** It uses private AppKit and SkyLight interfaces and
  has not been tested on enough MacBooks, Spaces transitions and display
  setups. If it holds up, it can be evaluated as the app's default later.

## Consequences

- Real tests need a notched MacBook (the Mac mini has none: there the
  rules, a made-up notch through `OMACVM_TEST_NOTCH_GEOMETRY` in test
  builds and a simulated guest cover the plumbing).
- A change of the Mac's display resolution while the VM runs keeps the
  housing measured at the start: restart the VM.
