# The 3.1 settings window: the design

`final.html` is the design the app's VM window follows (open it in a browser:
Auto / Light / Dark, the update banner on and off, click the icon, the
sections, the sheets). `shots/` has pictures of it. The app's own pictures:
`OmacVM --render-vm-window DIR` (CI keeps them as the run's artifacts).

Where the app differs from the page, on purpose:

- The escape combo's line reads "Takes you back to macOS."
- The update banner names the version found and the first line of its
  CHANGELOG; What's New shows that version's whole section (from 3.2.19 also
  the sections of the versions it skips, newest first).
- The icon has eight looks: OmacVM's own and three dark Omarchy themes
  (Tokyo Night, Catppuccin, Gruvbox) on the top row, four light ones below
  (Flexoki Light, Catppuccin Latte, Rosé Pine, Lupine).
- Magic Mouse swipe is 3 or 4 fingers, as OmacVM Gestures has it.
- Custom resources and the disk's new size use − / + (no sliders), and
  nothing says "applies at the next start": the whole window is for the next
  start.
- Controls are macOS's own (switches, segmented pickers, pop-up menus); the
  colours of text, lines and the accent are the system's.
