# 0043: The Mac's input methods in the VM: macOS composes, Fcitx5 inserts

Status: accepted, built (`mac-ime`: off by default, experimental,
OmacVM.app only; for 3.0.8: 3.0.7 is a notch-only hotfix of 3.0.6). Requested and scoped by @Vocllum in
[#273](https://github.com/gillesgoetsch/OmacVM/issues/273).

## Context

To type Chinese, Japanese or Korean in Omarchy today, you set up an input
method inside the VM (Fcitx5 with Mozc, Rime, Hangul, ...), with its own
switch key and candidate window. #273 asks for the Mac's own input methods
instead: focus a text field in the VM, type, the macOS candidate window
opens at the guest caret, the chosen text lands at the caret. Keys,
Cmd/Ctrl mapping and shortcuts stay as they are; no floating dialog, no
clipboard.

The issue names the four hard parts: AppKit needs a caret rectangle
(`firstRectForCharacterRange:`), the guest needs real preedit, commit,
cancel and focus (not typed-out characters), a native channel (no network),
and nothing that breaks the hardened runtime.

What the guest has (checked in the sources: Omarchy b83d3df, Hyprland
5a78b5e, Fcitx5 d82ac11, all from 2026-10):

- Omarchy runs Fcitx5 in every session (`omarchy-fcitx5.service`, packages
  `fcitx5`, `fcitx5-gtk`, `fcitx5-qt`), for its CapsLock compose sequences.
  `environment.d/10-omarchy-fcitx.conf` sets `QT_IM_MODULE=fcitx`,
  `XMODIFIERS=@im=fcitx`, `SDL_IM_MODULE=fcitx`; `GTK_IM_MODULE` is not
  set, so GTK uses text-input-v3.
- Hyprland speaks `zwp_input_method_v2` (with the keyboard grab and the
  popup surface), `zwp_text_input_v3` and `zwp_text_input_v1` (Chromium).
  It takes one input method per seat ("Cannot register 2 IMEs at once!",
  `InputMethodRelay.cpp`), and Fcitx5 already is that input method.
- Through input-method-v2 an input method never learns where the caret is.
  The app gives Hyprland a surface-local rectangle; Hyprland places the
  input method's popup next to it and tells the popup only its offset
  (`InputMethodPopup.cpp`). Fcitx5's Wayland frontend sets no cursor
  rectangle at all. Hyprland's IPC has no caret either.
- Fcitx5's other frontends do carry the caret: the D-Bus frontend (Qt
  through `fcitx5-qt`, GTK 3 and 4 through `fcitx5-gtk` when
  `GTK_IM_MODULE=fcitx`, kitty through its IBus mode) sends it relative to
  the window, with the scale (`SetCursorRectV2`, `CapabilityFlag::RelativeRect`);
  XIM (XWayland apps) sends it in root coordinates.
- Which Omarchy apps reach an input method at all: GTK 4 and 3 (Nautilus,
  ghostty, the launcher if GTK), Qt (QT_IM_MODULE), foot, alacritty and
  kitty (text-input-v3), XWayland apps (XIM). Chromium and Electron only
  with `--enable-wayland-ime`: Omarchy sets it for Obsidian, not in
  `chromium-flags.conf`. The same holds for a guest Fcitx5 engine today.

What the Mac side has: QEMU's `QemuCocoaView` (ui/cocoa.m) sends scancodes;
OmacVM's patches add the full-grab tap, the Cmd/Ctrl mapping, macOS's
system shortcuts and the globe key. The display port (`org.omacvm.display`,
omacvm-cocoa-displays.patch) is served inside QEMU's window code and
already knows where Hyprland put each output in logical pixels and which
Mac window shows it (the pointer mapping uses it).

## Options

Guest side:

1. Our own input-method-v2 client. Hyprland would refuse it while Fcitx5
   runs; stopping Fcitx5 loses Omarchy's compose key, XIM and the Qt path,
   and still gives no caret. No.
2. An Fcitx5 addon (a module, not an input method engine). It lives in the
   Fcitx5 that already runs: every frontend Fcitx5 has (Wayland IM v2,
   text-input-v1 for Chromium, D-Bus for Qt/GTK, XIM) works without new
   code, the keyboard engine and compose keep running, a guest engine
   (Mozc, Rime) still works next to it. It sees focus in and out, the
   caret rectangle where the frontend has one, and the field's kind
   (password, ...), and it can set the preedit and commit text on the
   focused input context. Compiled C++ against the VM's Fcitx5.
3. Fcitx5's Lua addons: no preedit or caret API, no file descriptor in the
   event loop. No.

Caret for apps that only speak text-input (Chromium, Electron, foot,
alacritty):

1. A Hyprland plugin that reads the caret box: the plugin ABI changes with
   every Hyprland release, and Omarchy updates Hyprland often. No.
2. Ask Hyprland upstream for the caret box in IPC or in the popup event:
   the clean fix; not posted (needs the maintainer's OK first).
3. Anchor on what the Mac already knows: the last click in the VM window
   if it came after the focus change, else the focused window's box (from
   Hyprland's IPC). The preedit itself is drawn by the app at the caret in
   every case; only the candidate list sits less exactly.

## Decision

Guest option 2, caret option 3 (and 2 later, with the OK), behind a new
feature `mac-ime` ("Mac input methods"): off by default, experimental,
`vm` side, app-only. Nothing changes while it is off.

### Channel

A virtio port `org.omacvm.ime` (`nr=8` on `vser0`: no PCI device moves),
only on a VM whose record says `mac-ime=on` at its start (MacLinks, from
the VM folder's `features`), so a VM with it off starts exactly as before:
no port, no socket, QEMU's window code never looks at a key for it.
Turning it on therefore needs one restart of the VM (apply and the check
say so; qemu.log's "Mac links" line has "Mac input methods on|off"). Its
socket is served by QEMU's window code (as `org.omacvm.display`, socket in
`OMACVM_IME_SOCKET`), because the window is where the keys and the input
context are. udev gives the port to the desktop user (`uaccess`, as the
clipboard's), the user Fcitx5 runs as.

JSON lines, at most 4 KiB a line (longer lines dropped), version in hello.
Numbers are checked as in the display port (finite, below 1e7); anything
else is dropped, never fatal.

Guest to Mac:

```
{"t":"hello","v":1}
{"t":"focus","on":true,"kind":"text","rect":[x,y,w,h],"exact":true}
{"t":"rect","rect":[x,y,w,h],"exact":true}
{"t":"focus","on":false}
{"t":"reset"}
```

`rect` in Hyprland's global logical pixels; `exact` false when only the
window's box is known. `kind` is `text` or `password` (Fcitx5's
`Password` or `Sensitive`). `reset`: the app reset its input context (a
click moved the caret); the Mac drops what was marked. Either side says
hello when it (re)connects; the guest answers the Mac's hello with hello
and its focus, and a guest hello resets the Mac's state (Fcitx5 restarted).

Mac to guest:

```
{"t":"hello","v":1}
{"t":"preedit","text":"にほn","cursor":3,"segs":[[0,2,1],[2,3,0]]}
{"t":"commit","text":"日本"}
{"t":"cancel"}
```

`cursor` and `segs` in Unicode code points; a segment `[start,end,1]` is
the clause being converted (highlight), `0` an underline.

### Guest: the Fcitx5 addon

`src/ime/guest/`: `omacvm-ime` addon (about 400 lines of C++), built in
the VM against the installed Fcitx5 when the feature goes on, rebuilt by
`omacvm apply` when Fcitx5's version changed, as a pacman package like
`omacvm-box64`. An addon that does not load leaves Fcitx5 as it was: no
hello, so the Mac never switches over. Rebuilt by `omacvm apply` when its
sources or Fcitx5's version changed (`build-info` in the package); the
check says when.

- Opens `/dev/virtio-ports/org.omacvm.ime` in Fcitx5's event loop, says
  hello.
- `InputContextFocusIn/Out`, `InputContextCursorRectChanged`,
  `InputContextCapabilityChanged`: sends focus and rect (debounced to one
  per frame). A relative rectangle gets the origin of Hyprland's focused
  window (`j/activewindow` on Hyprland's socket); any other (no rectangle:
  Wayland IM v2; X root coordinates: XIM, whose mapping to Hyprland's
  logical space depends on XWayland's scaling) sends the window's box with
  `exact:false`.
- preedit: `inputPanel().setClientPreedit()` with the segments and cursor,
  `updatePreedit()`; commit: `commitString()`; cancel: an empty preedit.
  Only on the input context that has the focus; a message for a context
  that lost it is dropped.
- With the feature on, `apply` also sets `GTK_IM_MODULE=fcitx` (so GTK
  apps, ghostty among them, give an exact caret) and adds
  `--enable-wayland-ime` to `chromium-flags.conf` and
  `electron-flags.conf`, each in a block marked as OmacVM's; off removes
  them. Both take effect at the next login; the check row says so.
  Fcitx5 itself runs without `GTK_IM_MODULE` (a drop-in for Omarchy's
  `omarchy-fcitx5.service` unsets it): with it, Fcitx5's Wayland check
  shows a tip to unset it (#357).

### Mac: QEMU's window (`omacvm-cocoa-ime.patch`)

`QemuCocoaView` implements `NSTextInputClient` with its own
`NSTextInputContext`. `-inputContext` returns nil, and every key goes as a
scancode exactly as now, unless all of these hold:

- the guest said hello on `org.omacvm.ime` (the feature is on in the VM),
- the guest's last word is focus on, kind `text`,
- the current input source is an input method
  (`TISCopyCurrentKeyboardInputSource`, `kTISPropertyInputSourceType` is
  `kTISTypeKeyboardInputMode`, `...InputMethodWithoutModes` or the method
  itself, `...InputMethodModeEnabled`; followed on
  `kTISNotifySelectedKeyboardInputSourceChanged`),
- the VM window has the keyboard (the key window, or the main window: on
  macOS 26 the candidate list is a window of the app's own process and can
  become the key window while it shows).

The context's `selectedKeyboardInputSource` is set to the Mac's current
source before each activation: an input context selects its remembered
source when activated, and ours is activated again as fields come and go,
which switched the Mac back to the plain layout right after the user picked
an input method (seen on the Air, macOS 26.6).

Then, in the key path (also for keys from the full-grab tap):

- A key with Cmd or Ctrl held, and every modifier change, goes as a
  scancode (shortcuts and Hyprland binds unchanged). Option and Shift go
  to the input method.
- Every other key goes to `[ctx handleEvent:]`. `setMarkedText:` sends
  preedit, `insertText:` sends commit, `unmarkText` and an empty marked
  text send cancel. `doCommandBySelector:` (Return, Backspace, arrows, Esc
  with nothing marked) sends that key's scancode. An `insertText:` that is
  the key's own character with nothing marked (an input method in its
  Latin mode) also goes as the scancode, so terminals and key repeat
  behave as typing.
- The key-up of a key the input method took is not sent.
- `firstRectForCharacterRange:` maps the guest rectangle through the
  displays layout (the inverse of the pointer mapping: output, scale,
  notch and full-screen offsets, the window of that output) to screen
  coordinates. `exact:false`: the last mouse-down in that window if newer
  than the focus change, else the window's box.
- `attributedSubstringForProposedRange:` returns parts of the marked text
  only (Kotoeri reads it back); the Mac never reads the guest's text. `validAttributesForMarkedText` names the clause and
  underline attributes only, so the input method marks its clauses.
- `unmarkText` commits the marked text as it is (AppKit's meaning).
- The guest's field gone (focus off, a password field, the guest closing
  the port): `discardMarkedText` and cancel. Only the keys gone (another
  input source, another window or app in front): the context is
  deactivated and the input method commits or keeps its text, as in a Mac
  app; a commit still reaches the field.
- Only the guest's field gone while the VM keeps the keyboard and the
  source is an input method (`omacvm_ime_off_later`): the context is
  deactivated 0.2 s later, and not when a field takes the focus again
  meanwhile. A terminal drops and takes its focus right after Enter, and
  some input methods (WeChat Input) go back to their first mode at each
  deactivate and activate (#357). Keys follow the guest's focus at once.
  Modifier keys still reach the input method in those 0.2 s, as while a
  field has the focus: a Shift tap in that moment can switch its mode.
- Shift also for macOS (#357, found by @Vocllum in #655;
  `omacvm-cocoa-ime-shift*.patch`, `ui/omacvm-ime-shift.h`). QEMU's
  full-grab tap deletes every key it gives the VM from macOS's event
  stream, so an input method that switches its mode on a lone Shift from a
  monitor on that stream (WeChat Input, from a reading of its binary)
  never saw Shift. While mac-ime gives keys to an input method (the
  conditions above, or the 0.2 s), a Shift change the VM and the input
  method had in the tap also goes on to macOS: the left or right Shift
  alone, never with Command, Control, Option or fn down, and a release
  when its press went on. Its copy comes back through the app's event
  queue and handleEvent drops it (time stamp and key code), so nothing
  gets it twice. What macOS sees while the VM has the keyboard is still
  nothing, except these Shift presses and releases; the keys between them
  stay deleted, so to macOS a Shift+letter chord looks like a lone Shift.
  With mac-ime off or a plain layout nothing changes. #655's first form
  (no modifier changes in the tap's mask) let every modifier change
  through for every user, so chords looked like lone or double modifier
  presses to macOS and other apps, and keys and modifiers came to QEMU on
  two paths with no order between them. `OMACVM_IME_SHIFT=0` turns it
  off; qemu.log says which at the start.
- Input source switching: while the conditions above hold except the
  input-method one, macOS's "Select the previous/next input source"
  shortcuts (symbolic hot keys 60 and 61, Ctrl+Space by default) and the
  globe key when System Settings says "Change Input Source" switch the
  Mac's input source (`TISSelectInputSource`) instead of going to the VM.
  QEMU's full-grab tap gets these keys before macOS while the VM has the
  keyboard (with or without omacvm-cocoa-system-shortcuts.patch's switch:
  seen on the Air, Control-Option-Space reached the VM with macOS keeping
  its shortcuts), and the globe key goes to the VM too
  (omacvm-cocoa-globe-key.patch), so without this the user could not
  switch to their input method inside the VM. A key macOS takes itself
  never reaches QEMU, so nothing switches twice.

### Where it shows

One row, same style as the other experimental ones, nothing new: the line
in `src/features.tsv` (summary as in the file)

```
mac-ime  off  vm  experimental,app-only  -  Mac input methods  type Chinese, Japanese and Korean in Omarchy with your Mac's own input methods and candidate window (OmacVM.app only)
```

gives the control centre's row (the app's Features… opens it), `omacvm
features` and `omacvm enable/disable mac-ime`. One switch row "Mac input
methods (experimental)" next to "Fast network (experimental)" in the app's
VM window (MacIMERow.swift): while the VM runs it runs the app's own
`omacvm enable|disable mac-ime --vm NAME`. While the VM is stopped (#316:
greyed out before, and the window is hidden while the VM runs, so a new
install could not switch it at all) it writes mac-ime into the VM's record
and a mac-ime-pending file; the next start has the port (or none) and runs
`omacvm apply --feature mac-ime=on|off` once the guest agent answers (the
pending file goes when that worked). A check row (addon built for the running Fcitx5, port open,
next-login settings in place). An entry in docs/features.md. No prompt, no
permission: AppKit's input context needs none.

## Consequences

- Works where a guest Fcitx5 engine works today, with the Mac's input
  method instead: Japanese (Kotoeri, Google Japanese Input), Chinese
  (Pinyin, Zhuyin, Cangjie, Wubi), Korean, and others that use marked text.
- Caret exact in Qt, GTK (with the GTK_IM_MODULE line) and kitty;
  window-anchored in Chromium, Electron, foot, alacritty and XWayland apps
  until Hyprland gives the caret (and XIM's coordinates are mapped). A floating GTK window with client-side shadows
  is off by the shadow's width.
- Text fields in layer surfaces (launcher, menus) anchor at the layer's
  box at best.
- macOS features that read the document (reconversion, context-aware
  prediction) do not work: the Mac never sees guest text.
- Input-method shortcuts with Ctrl (Kotoeri's Ctrl+J/K/L) go to the VM,
  as every Ctrl chord does now.
- Password fields stay on scancodes.
- A guest Fcitx5 engine keeps working: with a plain Mac layout keys go as
  scancodes and Fcitx5 composes as before.
- Fcitx5 updates may need the addon rebuilt; until then the feature is
  quietly off and the check says why.
- No new entitlement, no injection, no helper: AppKit and HIToolbox calls
  in QEMU's own process, signed as now.

## Security

- The guest sends only focus, a field kind and rectangles. The Mac uses
  them for one thing: where the candidate window goes, and whether keys go
  as text or as scancodes. A lying guest can misplace the candidate
  window or keep keys as scancodes; it cannot read Mac state or start
  anything.
- The Mac sends only text the user typed into this VM's window, while
  that window has the keyboard, never in a password field.
- In the VM the port belongs to the desktop user. A program of that user
  could open it before Fcitx5 and get the composed text, but the same
  program can already replace Fcitx5 as the input method and see every
  key: no new boundary.

## Tests

- Offline: the line parser and rectangle mapping as a host test (fuzzed
  lines, wrong types, huge numbers, the 4 KiB limit), the addon's message
  handling (`src/ime/tests/`), the patch in the build
  check. Which Shift goes on to macOS:
  `app/runtime/Tests/keys/test-ime-shift.sh` (a table, real CGEvents,
  the copies, the wiring; the rules before and #655's mask fail it).
- Real typing only on the MacBook Air (rule 61: no synthetic input on the
  Mac the user works on), test identity, test VM: Japanese (Kotoeri
  Romaji: preedit, Space conversion, clause moves, Return, Esc),
  Chinese Pinyin (candidates, full-width punctuation), Korean 2-set, in
  ghostty, a Qt app, Chromium with the flag, foot; Cmd chords, Hyprland
  binds and key repeat unchanged; the input-source shortcut and globe key;
  a password field; feature off byte-identical key path; two displays and
  the notch layout for the candidate position.

## Results (2026-10-08)

- Guest side in a real Omarchy VM (Fcitx5 5.1.23, Hyprland): the module
  builds in seconds, loads, opens the port; GTK4 (exact caret), foot and
  Chromium (window box) get preedit and commit; password fields are left
  alone.
- Typing on a MacBook Air (macOS 26.6, test app, `omacvm enable mac-ime` +
  one restart): Pinyin and 2-Set Korean commit into a GTK field; Control
  chords and password fields stay keys; input sources switch with
  Control-Option-Space in a text field.
- Review run on the Air (test app, `omacvm enable mac-ime` + restart):
  Kotoeri Romaji `nihon` + Return commits にほん in GTK and Chromium;
  Pinyin commit, Esc, Backspace while composing, focus moved to another
  window while composing (dropped, nothing of it in the next field);
  2-Set Korean with a Space between syllables keeps the order (한국 어);
  foot via `cat`; Ctrl+A and Cmd+Return (Super+Return) with Pinyin
  selected go to the VM. Feature off: no port, no socket, no module, keys
  as scancodes with Pinyin selected on the Mac.
- Kotoeri's candidate list + Return: with typed test keys (CGEvent) on the
  Air, Space shows the list with the reading and Return commits nothing
  until the input source changes. The same happens in a plain NSTextView
  and in a minimal NSTextInputClient fed by AppKit or by `handleEvent:`
  directly (a small probe app on the same Mac), so it is not this client;
  open: a check with real typing.
