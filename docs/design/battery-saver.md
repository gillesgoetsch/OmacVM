# Battery saver group: the VM window's battery-saving switches (3.5.0)

The experimental switches that save battery, packed into one card of the VM
window so they no longer crowd General and Display. Built in
`app/app/Sources/OmacVM/BatterySaverGroup.swift`; the rules in
`OmacVMFeatures/BatterySaver.swift` (`swift run features-tests`); the pictures
`page-4-battery-saver-closed`, `page-5-battery-saver-open` and
`popover-5-battery-saver` of `OmacVM --render-vm-window`.

## 1. Before the group

Eleven rows carried the `(experimental)` badge in 3.5.0's window:

| Row | Section today | Saves battery? | Takes effect |
|---|---|---|---|
| VM CPU clock saver | General | yes | at once |
| Prefer VP9 on YouTube | General (only Macs without AV1 decode, or when on) | yes | browser restart |
| Ghostty on the Mac's GPU | General | no (performance) | next VM start |
| HDR and 10-bit colour | Display (HDR Macs) | no (costs battery) | next VM start |
| HDR only in full screen | Display (HDR Macs) | yes | at once |
| Extra brightness | Display (XDR Macs) | no (costs battery) | at once |
| Pause drawing while hidden | Display | yes | at once |
| Fewer animations | Display | yes | at once |
| Pointer on its own layer | Display | yes | next VM start |
| Draw only what changed (tiles) | Display | yes | next VM start |
| Fast network | Sharing & Devices | no (network) | VM start |

Seven of the eleven are battery savers. They are scattered over General and Display,
between non-experimental rows. That is the overload the user names.

## 2. The design

One **Battery saver** group: a single card under its own section title, placed
**directly after the Display section** (its switches mostly change what is drawn, and
one depends on the Display card's HDR row just above). No new sidebar item in 3.5.0:
the sidebar's Display entry reaches it; if the card earns one later, a "Battery" item
with `NavIcon` (battery.100, green) slots in without moving anything.

The card holds:

1. A **master row** — title "Battery saver", badge `(experimental)` (same badge style
   as every experimental row), its own (i), a **disclosure chevron**, and a standard
   `RowSwitch`.
2. Seven **child rows**, shown when disclosed, indented 18 pt extra (their titles line
   up under the top row's title, after the chevron), separated by the same `RowDivider`
   hairline. Each child is today's row
   **unchanged**: same title, same subtitle logic, same (i) text, same `RowSwitch`,
   same disabled/note behaviour. Only the `(experimental)` badge is dropped on
   children — the group title carries it once, and every child's (i) text already says
   "Experimental". Less repeated noise, same honesty.

Child order — immediate and safe first, next-start last:

1. VM CPU clock saver
2. Pause drawing while hidden
3. Fewer animations
4. HDR only in full screen
5. Prefer VP9 on YouTube
6. Pointer on its own layer
7. Draw only what changed

The seven rows leave General and Display; both sections get visibly shorter.

### Rows that do NOT move

- **HDR and 10-bit colour** and **Extra brightness** stay in Display. They spend
  battery rather than save it; putting them under "Battery saver" would say the
  opposite of what they do.
- **Ghostty on the Mac's GPU** stays in General (performance, not power).
- **Fast network** stays in Sharing & Devices (network, not power).
- All four keep their `(experimental)` badge where they are. Experimental is a
  maturity mark, not a category; only the rows that share a *purpose* get packed.

### Hidden and blocked children

- **Prefer VP9 on YouTube**: shown only by today's rule (`YouTubeVP9.shown`) — a Mac
  whose media engine has no AV1 decoder (M1/M2), or anywhere while it is on.
- **HDR only in full screen**: shown only on a Mac with an HDR display
  (`Mac.hasHDRDisplay`), today's rule. With HDR off it stays visible but disabled
  with today's subtitle "Needs HDR and 10-bit colour." The master **never turns HDR
  on** to satisfy it — HDR costs battery.
- **Fewer animations**: OmacVM's own border setting, on Omarchy 4.0 and 4.5 alike; while
  the VM runs it is greyed only without the app's omacvm (as every VM feature row).
- **GPU safe mode**: VM CPU clock saver and Draw only what changed disabled with
  today's "Off while GPU safe mode is on."
- **Pointer on its own layer**: disabled while the macPointer default is set
  (today's rule).

A hidden child is out of every count. A blocked (disabled) child stays in the list
with its reason, counts in the denominator, and the master skips it.

## 3. State rules

Let *shown* = children visible on this Mac, *switchable* = shown and not disabled.

- **Master switch position**: ON when at least one shown child is on; OFF when none
  is. ("Battery saver is doing something" is the truth it shows.)
- **Master ON** (user flips it up): every switchable child turns on, through the same
  path as flipping it alone (Settings key, or the VP9/animations pending-switch /
  `omacvm enable` path). Blocked children stay off and keep saying why.
- **Master OFF** (user flips it down): every shown child that is on turns off,
  including one that is on but currently blocked (e.g. clock saver on, then GPU safe
  mode came — off still writes the key, as its own switch does today).
- **Mixed** (some on): the switch shows ON — macOS switches have no mixed visual, and
  a checkbox here would be foreign to the panel — and the subtitle carries the real
  state: "3 of 7 on." One flick from mixed gives all-off, the common bulk action;
  all-on is the flick after, or per child right below.
- **Disclosure**: chevron (chevron.right, rotates 90° when open, the standard
  DisclosureGroup motion — one of the few animations this panel has, keep it).
  Clicking the chevron or the title area toggles it; the switch only switches.
  Collapsed by default; state remembered app-wide (one defaults key, not per VM —
  it is window chrome, not a setting, so **no settings row for it**).
- **Refresh**: master and children follow `state.tick` exactly as the rows do today;
  `omacvm` or the control centre flipping a feature shows within seconds.

### Master subtitle (exact copy)

| State | Subtitle |
|---|---|
| all shown off | `Less battery use with the switches below, together or one by one.` |
| all shown on | `On. Some switches count from the next start of the VM.` |
| mixed | `3 of 7 on.` (live numbers: on-count of shown count) |
| VP9/animations busy | child's own busy spinner and note, as today; master unchanged |

The next-start sentence appears in the all-on subtitle only if a next-start child
(Pointer on its own layer, Draw only what changed) was just turned on by the master
and the VM is running or was running this session; on a stopped VM that was never
started it still holds, so keeping it unconditional is simpler and honest.

### Master (i) (exact copy)

> Experimental. One place for the switches that save battery. The switch at the top
> turns them all on or off together; each one below can also be switched alone, and
> its (i) says what it does, what it saved in measurements and what it trades.
> Switches this Mac cannot use are not shown. A switch that needs something first
> (HDR and 10-bit colour on) stays off and says what it needs, and the top switch
> never turns those needs on for it. VM CPU clock saver, Pause drawing
> while hidden, Fewer animations and HDR only in full screen work at once in a
> running VM; Prefer VP9 on YouTube counts when Chrome or Chromium next starts;
> Pointer on its own layer and Draw only what changed count from the next start of
> the VM. GPU safe mode turns some of them off; their lines say so.

### Child copy

Unchanged from today, verbatim — titles, subtitles, notes and (i) texts as in
`SettingsRows.swift`, `YouTubeVP9.swift` and `FewerAnimations.swift`. The only
change: no `(experimental)` badge after the child title.

## 4. Accessibility

- Master `RowSwitch` keeps the real label: `Toggle("Battery saver")`, labels hidden —
  VoiceOver reads "Battery saver, switch, on/off", then its hint "3 of 7 on" (a switch's
  value stays on/off in SwiftUI, so the count is the hint, `.accessibilityHint`). The
  render checks it from the window's accessibility tree.
- Disclosure: the chevron is a button that VoiceOver sees as a disclosure triangle,
  "Battery saver switches", expanded or collapsed (`accessibilityRepresentation` with a
  `DisclosureGroup`); the title opens and closes it too.
- Each child keeps its own labelled toggle and "About <topic>" (i) button exactly as
  today, so existing VoiceOver and keyboard paths do not change.
- Keyboard: every control in the group is in the normal Tab order (chevron, master
  (i), master switch, then per child: (i), switch). Space toggles; the (i) popover is
  already a focusable Button.
- The 18 pt child indent is decoration only; in the accessibility tree the seven rows
  follow the top row in the same card, each with its own label, (i) and switch.

## 5. Dark/light

Nothing new: the card is the existing `Card` (`Look.card`, `Look.cardBorder`,
`Look.hairline`), text colours are `.secondary`/`Look.orange`/`Look.red` as today,
and all follow the appearance already. The chevron uses `.secondary`.

## 6. ASCII mockup

Collapsed (nothing on), after the Display card:

```
  Battery
  ┌──────────────────────────────────────────────────────────────────────────┐
  │ >  Battery saver (experimental) (i)                              ( off)  │
  │    Less battery use with the switches below, together or one by one.    │
  └──────────────────────────────────────────────────────────────────────────┘
```

Disclosed, mixed, M1 Max (HDR display, no AV1 decode, HDR off):

```
  Battery
  ┌──────────────────────────────────────────────────────────────────────────┐
  │ v  Battery saver (experimental) (i)                              (on  )  │
  │    3 of 7 on.                                                            │
  ├──────────────────────────────────────────────────────────────────────────┤
  │      VM CPU clock saver (i)                                      (on  )  │
  │      Up to 3 W less on an M1 Max, little on a MacBook Air (M2);          │
  │      other Macs not measured. Can drop a rare video frame. Works         │
  │      at once.                                                            │
  ├──────────────────────────────────────────────────────────────────────────┤
  │      Pause drawing while hidden (i)                              (on  )  │
  │      Less battery while the VM's window cannot be seen. Sound and        │
  │      downloads keep running.                                             │
  ├──────────────────────────────────────────────────────────────────────────┤
  │      Fewer animations (i)                                        (on  )  │
  │      Less power while windows change focus: borders change colour at     │
  │      once.                                                               │
  ├──────────────────────────────────────────────────────────────────────────┤
  │      HDR only in full screen (i)                                 ( off)░ │
  │      Needs HDR and 10-bit colour.                                        │
  ├──────────────────────────────────────────────────────────────────────────┤
  │      Prefer VP9 on YouTube (i)                                   ( off)  │
  ├──────────────────────────────────────────────────────────────────────────┤
  │      Pointer on its own layer (i)                                ( off)  │
  │      Moving the pointer no longer redraws the VM's screen. From          │
  │      the next start of the VM.                                           │
  ├──────────────────────────────────────────────────────────────────────────┤
  │      Draw only what changed (i)                                  ( off)  │
  │      Small changes go to macOS as small squares, not as a whole          │
  │      new picture. From the next start of the VM.                        │
  └──────────────────────────────────────────────────────────────────────────┘

  ░ = disabled switch (greyed), reason in the line under it.
  This Mac shows 7 children, so the denominator is 7: the count is over SHOWN
  rows, blocked ones included (HDR only in full screen counts, off and greyed).
```

Same Mac, all on (master just flipped up; HDR still off):

```
  │ v  Battery saver (experimental) (i)                              (on  )  │
  │    5 of 7 on.                                                            │
```

(The blocked HDR-full-screen row and the macPointer-blocked pointer row, if any,
stay off; the master's flip never shows a false "all on". With no blocked rows the
subtitle is "On. Some switches count from the next start of the VM.")

On a Mac mini M4 (AV1 decode, no HDR display): VP9 and HDR only in full screen are
hidden; the group shows 5 children and counts "n of 5".

## 7. Rationale and rejected options

- **Rejected: a "mixed" checkbox master.** HIG-correct for mixed state, but every
  control in this panel is a switch; one checkbox would be the odd one out. The
  subtitle count carries the mixed state instead, in words VoiceOver also gets.
- **Rejected: master OFF when mixed.** A user who turned on three savers would see
  "Battery saver: off" — false. ON-when-any-on plus the count is truthful, and the
  likely bulk action from mixed (turn everything off) is one flick.
- **Rejected: new sidebar section in 3.5.0.** Six sidebar items are a calm list; the
  group lands via Display scrolling anyway. Revisit if the group grows.
- **Rejected: moving HDR/Extra brightness/Ghostty/Fast network into the group.**
  Packing by maturity instead of purpose would mislead — two of them cost battery.
- **Rejected: auto-turning HDR on for "HDR only in full screen".** The master would
  be spending battery to enable a saver. It waits and says what it needs.
- **Risk**: dropping child badges means a cropped screenshot of one child row lacks
  the experimental mark. Mitigated: every child (i) text says "Experimental", and the
  group header is at most six rows above. If the user wants belt-and-braces, the
  child badges can stay — purely additive.
- **Risk**: "3 of 7 on" invites "which 3?" — answered by the rows directly below the
  line, which is why the children live in the same card, not behind a sheet.

## 8. How it is built

- Reuse `SettingRow`, `RowSwitch`, `InfoButton`, `Card`, `RowDivider` as they are;
  the group is a new `BatterySaverGroup` view that owns the master row and wraps the
  seven existing row views with the indent. No new visual primitives.
- Children keep their own structs and state paths (`Settings.*` keys, PendingSwitch /
  `omacvm enable|disable` for VP9 and Fewer animations). The master reads the same
  sources and fans out writes; it must not add a second source of truth.
- Disclosure state: one `UserDefaults` bool (e.g. `batterySaverExpanded`), excluded
  from `SettingsDump` (window chrome, not a setting). Per the settings-on-page rule,
  every real switch already has its row here; the disclosure bool is not a switch.
- `--render-vm-window` draws it collapsed and disclosed-mixed (an M1 Max-like Mac),
  light and dark, and fails when the layout probes `battery-saver`,
  `trailing-battery-saver` or `battery-saver-disclosure` are missing or leave the window.
- `OmacVM --battery-saver on|off|status --vm NAME` runs the top switch without a window
  (the same reads and writes) and prints the group's state as JSON, for the e2e rows.
- The VM features go through `FeatureSwitch` (`FeatureSwitch.swift`), the same helper
  their own rows use: while the VM runs, one `omacvm enable|disable F...` for both (one
  apply transaction); the two rows show their spinner meanwhile (`groupBusy`).
