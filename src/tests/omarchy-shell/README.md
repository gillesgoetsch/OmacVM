Omarchy's own shell files, unchanged, for the offline tests of what OmacVM
patches in them (Omanotch's bar and background, the notifications, the display
panels, the night light indicator, the shell colours) or uses (`shell/Ui`: the
switch and tooltip of OmacVM.app's Extra brightness row):

- `omarchy-mac-ba546a61/`: https://github.com/omacom/omarchy-mac branch
  `quattro` at ba546a61 (2026-09-25), what OmacVM's VMs have.
- `omarchy-a06ec133/`: https://github.com/omacom/omarchy branch `quattro` at
  a06ec133 (2026-10-13), upstream's newer shell: a notch floor from
  display-cutouts.json, a bar thickness per screen, the wallpaper decoded at the
  display's size, `Commons.Color` (omacom/omarchy#14553).
- `omarchy-03ff1eff/`: https://github.com/omacom/omarchy tag `v4.5.0-rc1`
  (03ff1eff, 2026-10-20), Omarchy 4.5's first release candidate (branch
  omarchy-45 only: 4.5 is not supported yet). Its notifications ask the bar
  for its room in `Delivery.js`. Omanotch's bar patch has no 4.5 form yet, so
  `test_bar_patch.py` leaves this `Bar.qml` out.

Same paths as in Omarchy (`shell/plugins/...`). Omarchy's MIT licence: `LICENSE`.
