# 0076: AirPlay speakers, AirPods' modes and balance in the VM's audio panel

Status: accepted, built, OmacVM.app only. Needs the app update and Update VM.
Seen working on macOS 27.2.1 only; the modes of AirPods are built on the
lists Accessibility gave and not yet tried in a VM; not built: a volume per
speaker while several play, see "Not built".

## Context

The audio panel (`omacvm.audio`) controls the Mac's sound through OmacVM
Bridge's `/audio`: CoreAudio's devices, volume and mute. CoreAudio knows a
device only while it is connected, so the panel never showed what macOS's
own Sound list also offers: AirPlay speakers and TVs. From the VM, the
Mac's sound should be as close as it gets to what macOS's Sound module
offers.

What macOS gives a program, tried on macOS 27.2.1 (2026-11-20):

- No public API routes the Mac's own sound output to an AirPlay device.
  AVRouting's system context (`AVOutputContext`) and MediaPlayer's
  `MPAVRoutingController` need Apple's entitlements, and AMFI kills a binary
  that claims them. Shortcuts and Music.app give no system route.
- Bonjour (`_airplay._tcp`) finds other devices than Control Center lists: a
  MacBook that receives AirPlay is found, and is not in the Sound list.
- Control Center's Sound list is readable through Accessibility. The module
  is `controlcenter-airplay`; its one custom action opens the list, whose
  rows are `AXCheckBox` with the identifier `sound-device-<name>` and the
  value 1 for the output that plays. An `AXPress` on a row does what a click
  does: the old output's checkmark goes at once, the speaker's comes when it
  is connected (0.3 to 0.4 s for a HomePod), and CoreAudio's default output
  becomes a device with the transport AirPlay about 70 ms later. With an
  AirPlay speaker playing, a press of one of the Mac's own outputs switches
  to it alone.
- With AirPods Pro as the output (captured 2026-11-20), everything of the
  AirPods in the list has their row's identifier: an `AXDisclosureTriangle`
  before the row (value 1 open, 0 closed; a press toggles it, and Control
  Center keeps it for its next opening), the row (its description also has
  the battery: the name comes from the identifier), then per group of modes
  an `AXHeading` (its title) and its options as `AXCheckBox` (title, value 1
  selected, `AXEnabled` 0 for one macOS shows but does not offer). Listening
  Mode has Transparency, Adaptive and Noise Cancellation, Spatial Audio only
  "Not Available" (not enabled; its value was 0 in one capture and 1 in
  the next), Conversation Awareness Off and On. With Adaptive selected,
  three `AXImage` of its level stand between the options. Titles follow the
  Mac's language, and nothing else tells the modes apart.
- A press of an option selects it within 0.5 s and rebuilds the list: every
  element read before is invalid (`kAXErrorInvalidUIElement`). Once, 2 s
  after a press of Adaptive, the window that had opened answered nothing at
  all; in the next round it did.
- The balance is public: CoreAudio's
  `kAudioHardwareServiceDeviceProperty_VirtualMainBalance` on the output
  device. A device has it only with a volume per channel. A display's
  speakers, a single built-in speaker and the AirPlay device had none, and
  System Settings › Sound shows no Balance slider for them either.

What Control Center costs, measured the same day:

- Its window can be moved through Accessibility (`AXPosition` is settable).
  Moved off every display right after it opens, the window server has it on
  a display for 12 to 34 ms (five rounds), and macOS puts it back at the menu
  bar at its next opening.
- While it is open, also off screen, Control Center has the Mac's keyboard:
  keys typed then reached neither TextEdit nor anything else, and neither
  `AXRaise`, `AXMain`, `AXFrontmost` nor an activation of the app in front
  gave them back. A click anywhere closes it. Once it is closed, the app in
  front has the keyboard again without a click.
- Over an app in a full-screen Space of its own that hides the menu bar, as
  OmacVM's QEMU does (`NSApplicationPresentationHideMenuBar`), all of this
  is the same, and no menu bar shows. Over one that only auto-hides it
  (TextEdit), macOS slides the menu bar in for the session. Tried with a
  test app, not with a VM: QEMU's own key tap may behave differently.
- One round (open, list, close) takes about 1.0 s, a press of a HomePod
  about 1.5 s.

## Decision

OmacVM.app answers `GET` and `POST /omacvm/app/sound` on the VM's control
port itself (`SoundGuest`, as it answers `/omacvm/app/extra-brightness`,
ADR 0031), so it works with every Bridge:

- `GET`: `{"accessibility", "output", "balance"}`: whether macOS lets OmacVM
  use Accessibility, the output's CoreAudio UID and its balance (null: none).
  No Control Center.
- `POST {"read": true}`: + `"devices"`, every output of Control Center's
  list with its checkmark.
- `POST {"press": NAME}`: presses that row and answers the list once the
  row's checkmark changed. When the list moved and is as before again (the
  speaker did not connect), or after 15 s, it answers `unchanged`.
- A device with modes has `"modes": [{"title", "options": [{"title",
  "selected", "enabled"}]}]` in the list, macOS's groups in its own words,
  so whatever another headphone or a later macOS offers passes through. A
  read opens the closed disclosure of the device that plays first, as a
  click would; Control Center keeps it open from then on.
- `POST {"mode": {"device", "group", "option"}}`: finds the option by these
  three texts in the list as it is at that moment (after the device's row,
  under that heading: "Off" and "On" repeat), presses it, and answers the
  list once macOS has selected it, or `unchanged` after 5 s. One that macOS
  does not offer is refused (`no-option`), one that is selected already is
  not pressed. Each press and each wait reads the list again, and each read
  asks Control Center for its window again and moves a new one off screen.
- `POST {"balance": {"value": 0...1, "output": UID}}`: CoreAudio, only while
  that output plays: the Mac can switch outputs between the panel's drag and
  the write.
- `POST {"allow": true}`: asks macOS for Accessibility, which lists OmacVM
  there, and opens that list in System Settings. Only the person turns it on.

For a read or a press the app opens Control Center, moves it off screen,
opens the Sound list, and closes Control Center again on every way out
(`SoundPicker`). A Control Center that does not close keeps the Mac's
keyboard, so the app puts it back where macOS showed it, for the person to
close. It touches nothing while Control Center is open already (the person
uses it: "busy"). It finds elements by role and identifier only;
titles and action names follow the Mac's language.

The guest is untrusted: one exact path, a body of exactly one known key, a
device or an option only by the texts the list has at that moment, and every POST only while
this VM's window is the app in front, because a session takes the Mac's
keyboard for a second. The app asks who is in front again right before it
opens Control Center, and refuses a request that comes while a session runs,
for any VM ("busy"), instead of queueing it: a queue would run on after the
person left the VM. The route is the feature bridge's: with it off the app
answers as one without the route. There is no rate limit: a VM in front
that asks in a loop takes the keys from itself, until the person clicks
anywhere, which closes Control Center, and a VM in the background is
refused.

In the VM, `omacvm sound [read | press NAME | mode NAME GROUP OPTION |
balance PERCENT [OUTPUT] | allow] --json` asks the app, and the panel
(`Sound.qml`) runs it. Like the Sound module of Control Center, the panel
has one output list:

- CoreAudio's outputs as before, then after a divider what macOS lists
  beyond them: AirPlay speakers. A paired Bluetooth headset that is not
  connected (the Bridge's Bluetooth list has its name) stands among the
  outputs. Both are switched by a press.
- The panel asks for the list once each time it opens, as the Mac's own
  module does, and once more for the modes of Bluetooth headphones that play
  while it is open: when its last read was for another output, after a
  press of a row answered with a list, which may have their modes closed,
  and after a read whose answer names another output than the one it was
  for, as the Mac switched meanwhile; never on a timer. That second read
  waits until the Bridge and the app's last answer name the same output:
  the Bridge may report a switch after the app's answer, and a read before
  it would be for an output that no longer plays. While the two differ, the
  panel asks the app for its state. Until the answer it shows the list of
  the last opening. The cost: for about a second after the panel opens, the
  Mac's keyboard is Control Center's.
- The speaker's own row has the checkmark, as on the Mac. CoreAudio's one
  AirPlay device has a row only when nobody knows which speaker plays: with
  an app that has no list, and when AirPlay was picked on the Mac while the
  panel is open (the list's checkmarks belong to the output's CoreAudio UID
  they were read for, and AirPlay gets a new one each time it connects).
- The request on its way is the row's spinner; the checkmark is macOS's.
- The output that plays has its modes under its row, from a list read for
  it (so the panel reads the list once more for Bluetooth headphones that
  play while it is open, as above): per group macOS's title, quiet, and its
  options in one line on the edge of the row's name, as a segmented control
  without borders (Omarchy's Button), wrapped when they do not fit. The
  selected option has the fill and the weight of the output that plays; one
  macOS does not offer is dimmed and takes no press. A group shows only
  while macOS offers one of its options: Spatial Audio with only "Not
  Available" is a line nobody can use; the app still passes it on. A group
  is one stop of the cursor (h/l walk its options, Enter presses one). A
  press of the option the panel shows as selected goes to the app too, as
  the headphones may have switched since the read: it costs a session and
  presses nothing when macOS has it selected. The press on its way is the
  group's spinner, at the rows' checkmarks.
  Tried as renders against Control Center's own vertical list (every option
  a row: about 230 px for the three groups, and the input's slider below
  the fold), bordered cells of equal width (Omarchy's power profiles: "Noise
  Cancellation" shrinks and is cut) and one line per group with its value
  (compact, but a switch takes two clicks or steps through the modes
  between).
- BALANCE shows only for an output that has one.
- A read or a press that did not work says so in one line for a few seconds.

Without Accessibility for OmacVM, one row stands where the speakers would,
"Allow Accessibility for OmacVM", and opens the Mac's settings for it. It is
the permission the VM's keyboard tap already asks for (Keyboard access).

`OmacVM --sound GET | POST BODY | tree` runs the same code from a terminal:
what a VM would get, and Control Center's list as Accessibility gives it,
to send along when a macOS shows a list the app cannot read. The tree has
the names of the Mac's devices, which can be personal ("Anna's AirPods"):
replace them before the tree goes into an issue.

## Not built

- **A volume per speaker** while several AirPlay speakers play. Only one
  AirPlay speaker was there, so nobody has seen those sliders. A guess, not
  seen: as all of AirPods' modes carry their row's identifier, such a
  slider is probably an `AXSlider` with the speaker's identifier after its
  row. Several speakers at once need nothing more than a press each, but
  that too is untested. The capture that is missing: `OmacVM --sound tree`
  while two AirPlay speakers play.
- **Adaptive's level** (the three images between the options while
  Adaptive is selected): the list gives no control for it that this code
  knows.

## Consequences

- Control Center's identifiers are Apple's to change. A macOS without them
  answers "unsupported", and the panel says so; the rest of the panel works.
- macOS 15 to 26 are untested: the menu bar's extras moved to
  `com.apple.MenuBarAgent` in 26, and the app looks in both places.
- On a macOS whose list this code cannot read, each opening of the panel
  still opens Control Center, for up to about 3 s, before the app answers
  "unsupported".
- There is no switch of its own: it is part of the feature bridge. Without
  Accessibility for OmacVM the app never opens Control Center, but the
  VM's keyboard tap asks for the same permission.
- The read at every opening keeps the list fresh and costs the Mac's
  keyboard for a second each time. A first version read it only when it had
  no list, with a button to read it again; the read at every opening needs
  no button.
- Control Center names a row by the device's name alone. Of two devices
  with one name, a press reaches the first.
- The modes are found by their titles, which follow the Mac's language:
  the panel shows them as macOS words them, and the guest asks for one by
  those words. A read opens the AirPods' modes in Control Center, which
  the person sees there next time.
