Omarchy's own shell files, unchanged, for the offline tests of what OmacVM
patches in them (Omanotch's bar and background, the notifications, the display
panels, the night light indicator, the shell colours), finds by their shape
(the tray, for Omanotch's strip) or uses (`shell/Ui`: the
switch and tooltip of OmacVM.app's Extra brightness row):

- `omarchy-mac-ba546a61/`: https://github.com/omacom/omarchy-mac branch
  `quattro` at ba546a61 (2026-09-25), what OmacVM's VMs have.
- `omarchy-a06ec133/`: https://github.com/omacom/omarchy branch `quattro` at
  a06ec133 (2026-10-13), upstream's newer shell: a notch floor from
  display-cutouts.json, a bar thickness per screen, the wallpaper decoded at the
  display's size, `Commons.Color` (omacom/omarchy#14553).
- `omarchy-ac2690cd/`: https://github.com/omacom/omarchy tag `v4.5.0`
  (ac2690cd, 2026-11-05), Omarchy 4.5.0: each bar surface spans its screen,
  a widget pool per surface, the centre in three sections (centerBegin,
  center, centerEnd); the notifications ask the bar for its room through
  `Delivery.js` (here too); each bar's workspaces widget shows its own output's
  workspaces (`widgets/Workspaces.qml`).

Same paths as in Omarchy (`shell/plugins/...`). Omarchy's MIT licence: `LICENSE`.
