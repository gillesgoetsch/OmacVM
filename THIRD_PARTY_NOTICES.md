# Third-party notices

OmacVM's own code is MIT (`LICENSE`). It reuses, with credit at the top of
each file taken from them:

- **try-omarchy** (github.com/omacom/try-omarchy), MIT, (c) Try Omarchy
  contributors, `app/runtime/LICENSE.try-omarchy`: OmacVM.app's QEMU build
  scripts and patches (`app/runtime`), `QMPConnection.swift`,
  `VMHostSleepController.swift`, `NativeBridgeSocket.swift` and
  `NativeClipboardBridge.swift` (`app/app/Sources/OmacVM`), and the VM's
  `omacvm-clipboard` and `omacvm-display-sync` (`src/app/guest`). Its release
  is also downloaded at build time as the temporary live system.
  The Mac's battery in the VM: the kernel module
  `src/battery/guest/module/omacvm-battery.c` (GPL-2.0-only, as its original
  file says), its `Makefile` and `dkms.conf`, the agent
  `src/battery/guest/omacvm-battery`, UPower's setting `90-omacvm-battery.conf`,
  and the Mac's side in `src/bridge/mac/battery.swift` and OmacVM.app's
  `HostBattery.swift` and `NativeBatteryBridge.swift`.
  The Mac's camera in the VM: `src/bridge/mac/camera.swift` (from
  `NativeCameraBridge.swift`; OmacVM.app uses it too), the VM's
  `src/camera/guest/omacvm-camera` (from `omarchy-native-camera-bridge`) and
  its v4l2loopback and udev settings.
  Its pull request #361 ("Full macOS notch support", themartiano) showed that
  AppKit's full-screen menu bar reservation decides whether a window covers
  the strip beside the notch; OmacVM.app's FullPanel answers that question
  (no code from the pull request).
- **UTM** (github.com/utmapp/UTM), Copyright © 2026 Turing Software, LLC,
  Apache License, Version 2.0: FullPanel in OmacVM 3.0.16-3.1.26 contained
  code adapted from UTM (Apache-2.0), from its
  `Platform/macOS/Display/VMDisplayWindow.swift` (UTM pull requests #7885 and
  #7910). Since #480 (@brianmerchant) FullPanel is rewritten and has no code
  from UTM. It still follows UTM's approach: the menu bar's backdrop made
  transparent with SkyLight, the menu bar held back with the app's
  presentation options ([ADR 0044](docs/adr/0044-fullpanel.md#replacement)).
- **omarchy-parallels** (github.com/vincenzopalazzo/omarchy-parallels), MIT,
  (c) Vincenzo Palazzo, `src/vm/live/LICENSE`: the live image builder in
  `src/vm/live`.
- **omarchy-arm-utm** (github.com/ggalancs/omarchy-arm-utm), MIT, by ggalancs:
  `src/utm/guest/omacvm-vdagent` is based on its Wayland SPICE agent, and
  `src/utm/guest/90-omacvm-utm.conf` comes from it.
- **Omarchy** (github.com/basecamp/omarchy), MIT, (c) David Heinemeier Hansson:
  the bar widgets in `src/bridge/plugins` and `src/workspaces/plugins` are
  derived from Omarchy's own, each with its `LICENSE`; OmacVM.app's display
  widget (`src/app/guest/monitor-widget`) is built in the VM from the
  installed Omarchy's own display panel, with its `LICENSE`; the icon
  (`src/icon/omacvm.svg`) uses Omarchy's mark; OmacVM.app's boot logo (the
  firmware's, and the window's while the VM starts) and the start animation
  are Omarchy's `logo.svg`.
- **JetBrains Mono** 2.305 (github.com/JetBrains/JetBrainsMono), SIL Open
  Font License 1.1, (c) 2020 The JetBrains Mono Project Authors,
  `app/fonts/OFL.txt`: the font of the Touch ID panel (`app/fonts`, bundled
  unchanged in OmacVM.app's Contents/Resources/fonts).
- **Omanotch** (`src/omanotch/`) has its own README and licence.
- **Textual** and what it needs (`src/control/vendor/`, the VM's control
  centre), unchanged wheels from PyPI, each with its licence inside
  (`*.dist-info/licenses/`): Textual 8.2.8 and Rich 15.0.0 (MIT, (c) Will
  McGugan), Pygments 2.21.0 (BSD-2-Clause, (c) the Pygments authors),
  markdown-it-py 4.2.0 (MIT, (c) ExecutableBookProject), mdit-py-plugins
  0.6.1 and mdurl 0.1.2 (MIT, (c) Vitaly Puzrin, Alex Kocharin and others),
  linkify-it-py 2.2.0 (MIT, (c) tsutsu3), platformdirs 4.12.4 (MIT, (c) the
  platformdirs developers), typing_extensions 4.16.0 (PSF-2.0).
- **Hyprland** (github.com/hyprwm/Hyprland), BSD-3-Clause, Copyright (c)
  2022-2026, vaxerski, `src/app/guest/hypr-capture/LICENSE.hyprland`: its
  shader file `cm_helpers.glsl` of v0.56.2 and of v0.57.0, each with two
  changes marked "OmacVM" (`src/app/guest/hypr-capture/0.56.2/`,
  `src/app/guest/hypr-capture/0.57.0/`), put into OmacVM.app's VMs for
  Hyprland to read in place of its own (screenshots and screen sharing of
  HDR windows, #579).
- In the VM, nothing else is bundled: Arch Linux ARM and Omarchy
  (omarchy-mac) come from their own servers, v4l2loopback too (built in the
  VM by DKMS, GPL-2.0), each package under its own licence.

What OmacVM.app ships (QEMU, edk2, QEMU's libraries) is listed in
[app/THIRD_PARTY_NOTICES.md](app/THIRD_PARTY_NOTICES.md).
