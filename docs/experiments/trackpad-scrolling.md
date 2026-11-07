# Experiment: two-finger scrolling through OmacVM Gestures

**Outcome: shipped in OmacVM 2.0 as "macOS-native scroll momentum"**
(feature `scroll-momentum`, called Glide in the code), experimental and off by
default: `omacvm enable scroll-momentum`. The state
of test 29 is what it does; the code is `src/gestures/guest/omacvm-gestures`
(`Glide`), `src/gestures/guest/omacvm_glide.lua` and the Mac helper. The test
switches below (`--scroll`, `OMACVM_SCROLL_*`) became the per-VM feature and
`OMACVM_GLIDE_*` (FILTER, BLEND, RAW_SCALE, POINT_UNITS, DISTANCE, TAU,
MAX_RATE, HOLD, DEBUG, RECORD); the wheel mode, the boosts and the
acceleration curves were dropped.

A record from before 3.4.0: the VM app it was tested in is no longer one
of OmacVM's routes; the feature works the same in OmacVM.app.

Developed on the branch `experiment/trackpad-scrolling`. Tested on the
production Parallels VM (Omarchy 4.0.3rc4, Hyprland 0.56.2, libinput 1.32.0,
Chromium 153) on a MacBook Pro M4 Max, macOS 15.7.4, Parallels Desktop 27.0.2.

## Goal

OmacVM Gestures' 3/4-finger swipes and pinch feel more responsive than
Parallels' own smooth scrolling. Try the same for two-finger scrolling, in all
directions, so that only one-finger pointer movement (and clicks) still come
from Parallels.

## Test log (2026-10-02)

### 1. Raw two-finger touches to the virtual touchpad

`omacvm-gestures --scroll`: every two-finger frame goes to the guest's virtual
Apple touchpad (not only pinches); macOS's scroll events from the built-in
trackpad, momentum included, are dropped so Parallels does not scroll as well.
libinput turns the touches into touchpad scrolling.

- Panning in every direction while zoomed in (Chromium): **excellent**.
- Normal scrolling: far too sensitive and accelerated; small inputs keep
  scrolling for about a second.

Guest touchpad settings at the time (Omarchy defaults): natural scrolling on,
tap-to-click off, scroll factor 0.4, adaptive acceleration.

### 2. Flat acceleration, scroll factor 0.25 for the virtual touchpad

`hl.device({ name = "apple-inc.-magic-trackpad-(omacvm)", accel_profile = "flat", scroll_factor = 0.25 })`

- Files (GTK): very close to macOS; long scrolls a bit slow.
- Chromium: still overshoots, gliding on for about a second.

Recording in the guest (evdev, timestamps) of a few short scrolls:

- Parallels' virtual mouse sent **no** scroll events: no double scrolling.
- Finger frames arrive evenly every 8 ms (125 Hz), no bursts; the touches end
  0.1-0.15 s after a short push. The overshoot happens after the last frame:
  it is **Chromium's own fling** (and its fling booster, which speeds up
  repeated swipes in the same direction). Chromium has no switch to tune it
  (`ExperimentalFlingAnimation` was tried and made it worse).

### 3. Custom acceleration curves (`scroll_points`)

A macOS-like curve (1:1 slow, up to 1.5x fast) for scrolling. Everything,
4-finger swipes included, became 3-5x too sensitive: libinput slows touchpad
motion by 0.297 ("magic slowdown") only in its built-in profiles; a custom
curve bypasses it. Rescaled by 0.297: still too sensitive overall. Reverted.

### 4. macOS's own scroll physics, replayed as a high-resolution wheel

`omacvm-gestures --scroll` (current branch code): macOS's continuous scroll
events (trackpad, Magic Mouse; macOS's acceleration and momentum included)
go to the guest as point deltas (`W <dx> <dy>`), and the guest replays them on
a virtual high-resolution wheel, "OmacVM scroll (macOS)" (120 units per
`OMACVM_SCROLL_POINTS_PER_DETENT` points, default 40). Two-finger touches go
to the virtual touchpad only for pinch again. A wheel mouse still scrolls
through Parallels. The virtual touchpad's test settings were removed.

- 3- and 4-finger swipes: almost perfect.
- Files: fine, a bit nervous and fast.
- Chromium: still glides too much (now its smooth-scrolling animation of
  wheel steps, on top of macOS's momentum).
- Chromium pinch zoom: works well.
- Chromium pinch zoom, then two-finger panning: the worst, very buggy (when
  zoomed in, Chromium pans smoothly only with touchpad scrolling, not a wheel).

### 5. Chromium without smooth scrolling, slower wheel (in progress)

`--disable-smooth-scrolling` in `~/.config/chromium-flags.conf`;
`OMACVM_SCROLL_POINTS_PER_DETENT=60` (systemd drop-in
`/etc/systemd/system/omacvm-gestures.service.d/scroll-test.conf`).

- Chromium (with the flag): **very nice**, very close to macOS; slightly less
  clean than macOS's 120 Hz scrolling.
- Google Chrome reads its own `~/.config/chrome-flags.conf`, still had smooth
  scrolling on: glides too much.
- Pinch-zoomed page, two-finger panning: **impossible** with the wheel, in
  Chrome (expected in any Chromium-based browser: a wheel does not pan the
  zoomed viewport).

### 6. macOS's physics replayed as two virtual fingers (in progress)

`OMACVM_SCROLL_MODE=touch` in the guest (`wheel` stays the alternative):
macOS's deltas move two virtual fingers on the virtual touchpad
(`OMACVM_SCROLL_TOUCH_SCALE` touchpad units per point, start 4; the touchpad
is 100 units per mm), held down through macOS's momentum and lifted 60 ms
after the last delta, when the movement has died down. Near the touchpad's
edge they hold still for three frames, lift and start again in the middle.
Real finger frames (pinch, 3/4-finger swipes) take over the touchpad. Chrome
also got `--disable-smooth-scrolling` (original in
`chrome-flags.conf.before-omacvm-scroll-test`).

- **Very good**: Chrome and Chromium very close to macOS, zoomed panning works.
- Very small, slow scrolling (almost per pixel) does not respond, like a dead
  zone in the middle; macOS reacts there. Cause: libinput starts a two-finger
  scroll only after some movement, and with 60 ms the virtual fingers lifted
  in every pause of slow scrolling, so each small step had to cross that
  threshold again.

### 7. Virtual fingers stay down through pauses (in progress)

`OMACVM_SCROLL_TOUCH_HOLD` (default now 0.5 s): the fingers lift only after
half a second without scrolling, so slow, fine scrolling runs in one touch.
They are still by then, so lifting starts no fling.

- Very good, but really slow movement (about 1 mm/s) is still less sensitive
  than macOS: Chrome skips input.

Recording (guest: the received deltas, `libinput debug-events` on the virtual
touchpad): macOS sends slow scrolling as whole 1-point steps every 4-20 ms,
some of them sideways (macOS does that for its own apps too). libinput passes
**every** step on: a 1-point step becomes a finger scroll of 0.42, nothing is
swallowed. After the compositor's touchpad factor (0.4) a slow step reaches
Chrome as a fraction of a pixel, and Chrome drops part of such amounts.

### 8. Low-speed boost (in progress)

`OMACVM_SCROLL_SLOW_BOOST` (default 1.0): steps below 3 points get extra
movement, 1 -> 2, 2 -> 2.5, 3 and more unchanged (additive, so it always
rises with the input). Normal and fast scrolling stay exactly as macOS sends it.

- Worse: coarser, no more per-pixel scrolling. Boost off again (0).

Logging both of macOS's scroll fields and NSEvent's `scrollingDeltaY` (what
macOS's own apps use) in OmacVM Gestures: during slow scrolling all of them
carry **whole points only** (the fixed-point field is 0 for small movements).
macOS's scroll events have no finer data; macOS shows its 1-point steps at
120 Hz, 1 point = 1 pixel.

### 9. Hybrid: raw fingers while touching, macOS's momentum after (in progress)

Mac (`--scroll`): two-finger frames go to the guest as raw touches again; while
two fingers touch the built-in trackpad, macOS's scroll events are dropped;
after the lift only macOS's momentum goes, as `W` deltas. Other continuous
scrolling (Magic Mouse) still goes as `W` as a whole.

Guest (`OMACVM_SCROLL_MODE=touch`): the virtual fingers follow the raw
positions (hundredths of a millimetre). When two fingers lift, they stay down
for up to 0.15 s waiting for momentum; macOS's momentum then moves them on,
scaled so that the speed at the hand-over matches the fingers' last speed
(units/s against points/s of the first momentum steps); they lift 0.5 s after
the momentum has died down. Touchpad scroll factor for the virtual trackpad:
0.25 (acceleration stays the default, which suits the 3/4-finger swipes).

- **Overall awesome, at the macro level better than macOS.** Fast scrolling
  jumps and skips.
- Cause: Hyprland's log shows libinput's "kernel bug: Touch jump detected and
  discarded" for the virtual trackpad (40 times). Hand-over scales were 3-21
  touchpad units per point and momentum steps up to 45 points: several
  millimetres in one frame, which libinput drops as a jump. Long glides also
  ran off the 156 x 96 mm virtual touchpad.

### 10. Momentum in small, evenly timed steps; room for the glide (in progress)

- Momentum steps are queued and applied every 4 ms, at most 2 mm per step
  (a few milliseconds of extra delay in the glide only; the fingers stay direct).
- The virtual touchpad is 1 x 1 m; the real trackpad maps onto its middle
  156 x 96 mm, so fingers, pinch and swipes feel the same and a glide has room.
- At the edge the fingers stop and lift after the hold instead of letting go.

- Macro level great; no new touch-jump warnings (still 40): the skipping is
  gone.
- Long scrolling (several flicks in a row) often jumps back. Cause: fingers
  touching down during a glide reuse the trackpad's contact ids, so the new
  touch continued the glide's virtual touch and leapt back from where the
  glide had got to.

### 11. A new touch ends the glide's touch first (in progress)

When real fingers touch down while a glide runs, the glide's virtual fingers
lift first (pending momentum dropped), and the real fingers start a fresh touch.

- No more jumping back.
- Random pinch zooms while scrolling: raw fingers never keep their spacing
  exactly, and libinput sometimes reads the change as a pinch.
- Resting two fingers makes the page shiver: finger jitter of fractions of a
  millimetre, now passed on precisely, scrolls back and forth.

### 12. Scroll stays scroll, jitter filtered (in progress)

Guest, two-finger touches: the spacing is fixed at touch-down and only the
centre moves, through a One Euro filter (`OMACVM_SCROLL_FILTER`, min cutoff
1.5 Hz, beta 0.1, in millimetres: strong smoothing when still or slow, almost
none when fast). A clear spread (`OMACVM_SCROLL_PINCH_MM`, 6 mm, and more than
the centre has moved) switches the touch to raw fingers: a pinch.

- Much better. Still: random pinch zooms when scrolling slowly and carefully
  (the fingers drift apart a few millimetres over a long touch, and the
  accumulated spread looked like a pinch), and going from very slow to
  medium speed accelerates a bit too much (libinput's adaptive acceleration on
  the virtual touchpad).

### 13. Pinch is macOS's decision; flat acceleration (in progress)

- Mac: when macOS recognizes a pinch (NSEventTypeMagnify, which the event tap
  already sees and drops), the helper sends `P`; the guest switches the
  current two-finger touch to raw fingers only then. The spread-based guess is
  off (`OMACVM_SCROLL_PINCH_MM=0`).
- Guest: `accel_profile = "flat"` for the virtual trackpad again (scroll
  factor 0.25). To watch: whether 3/4-finger swipes still feel right with flat.
- Question from the test: take over the Mac's trackpad settings? Already: the
  pointer (macOS's cursor via Parallels) and the glide (macOS's momentum,
  macOS's scroll direction). Not yet: while the fingers touch, Omarchy's own
  natural-scrolling setting and speed apply. Candidate: read macOS's natural
  scrolling and Accessibility scrolling speed and set them for the virtual
  trackpad.

- Good overall, but still too fast; 3/4-finger swipes awesome with flat.
- Pinch zoom no longer works: macOS's signal arrives (logged), but libinput
  never turns a touch it already treats as a scroll into a pinch.
- To tidy: the helper sends `P` many times per pinch (229 log lines);
  harmless, the guest ignores repeats.

### 14. Pinch restarts the touch; slower (in progress)

- On `P` the guest lifts the virtual fingers and puts them down again with the
  raw positions: a new touch whose fingers spread, which libinput reads as a
  pinch from the start.
- Scroll factor for the virtual trackpad 0.18 (was 0.25); the glide follows,
  being matched to the finger speed.

- Speed: 0.18 still too fast; 0.12 very close; 20 % slower is right: 0.096.
- Pinch still did not work. The Mac log showed why: during a pinch macOS
  delivers generic gesture events (CGEvent type 29) at the event tap, not the
  magnify type 30 the helper waited for (that had appeared only once, by
  chance). The guest never got `P`; libinput saw only scrolling.

### 15. macOS's pinch via NSEvent (in progress)

The helper asks NSEvent for each gesture event's type (`ns_event_type` in
`scroll_ns.m`); NSEventTypeMagnify (30) means macOS recognized a pinch, and
then it sends `P`. Scroll factor 0.096.

- **Pinch zoom works again**, started by macOS's own recognition.
- Speed: 15 % slower again, 0.082: slow scrolling now very good, but fast
  scrolling far too slow; macOS accelerates much more.

### 16. Our own acceleration curve for the finger phase (in progress)

`OMACVM_SCROLL_ACCEL` ("V0 V1 GAIN", default "15 150 3"): the virtual centre
moves by the filtered finger movement times a gain for the smoothed finger
speed: 1 up to 15 mm/s (fine scrolling unchanged), smoothstep up to 3 at
150 mm/s (30 mm/s 1.07, 60 mm/s 1.5, 100 mm/s 2.4). The glide takes over the
accelerated speed (the hand-over matches what was sent). Scroll factor 0.082,
libinput acceleration flat.

- Very unnatural when scrolling fast: decelerating and accelerating within a
  swipe. The finger speed fluctuates within one stroke, and an instantaneous
  gain curve follows those fluctuations. Off again (gain 1).

### 17. libinput's adaptive acceleration at a low base speed (in progress)

Our curve off (`OMACVM_SCROLL_ACCEL=15 150 1`); the virtual trackpad back to
libinput's adaptive profile (smooth, built for this), scroll factor 0.1, the
low base speed confirmed for slow scrolling. In test 12 adaptive was "slow to
medium a bit too much", but at 0.25, when everything was far too fast.

- Slow scrolling perfect; a fast swipe from the top of a page to the bottom
  stays slow and looks animated. libinput's adaptive profile barely affects
  two-finger scrolling: raw finger movement has no acceleration worth the name.

### 18. macOS's own acceleration on the raw fingers (in progress)

- Mac: while the fingers touch, macOS's (dropped) scroll events now go to the
  guest as `A <dx> <dy>`: what macOS would scroll, with its acceleration.
- Guest: over 150 ms, macOS points per millimetre of finger movement, divided
  by the same ratio during slow scrolling (below 20 mm/s; calibrated as you
  scroll, `OMACVM_SCROLL_BASE` to preset), is the gain on the raw, filtered
  finger movement (low-passed, capped at 6, `OMACVM_SCROLL_ACCEL_MAX`).
  Direction and fineness from the fingers, the amount of acceleration from
  macOS. Debug: `accel:` lines.
- Virtual trackpad: flat, 0.082 (perfect for slow scrolling).

- Fast scrolling still "like dragging a stone on a rope through mud".
- The `accel:` log: while the fingers touch, macOS scrolls roughly 8-16 points
  per millimetre at every speed from 16 to 360 mm/s, so macOS barely
  accelerates during the touch (the gain stayed at 1). macOS's fast feel is
  its glide after the lift.
- Fast flicks hand over at up to 55,000 units/s (550 mm/s), but the momentum
  step limit allowed 500 mm/s: the excess queued and trickled out, the sluggish
  glide.
- libinput's touch-jump count had risen from 40 to 108 since test 11: leaving a
  two-finger scroll for three or four fingers switched the two existing fingers
  from their filtered virtual positions to the raw ones within one touch.

### 19. Faster glide limit; a clean touch when leaving two fingers (in progress)

- Momentum step limit 400 units (4 mm) per 4 ms = 1000 mm/s
  (`OMACVM_SCROLL_MAX_STEP`), under libinput's jump threshold (~20 mm/12 ms).
- When a two-finger scroll turns into three or more fingers, its virtual touch
  ends first and the raw fingers start a new one.
- The macOS-gain code stays in for now (gain about 1); remove when adopting.

- Better; fast scrolling should be faster still. Jump count 108 -> 118.
- Hyprland's log around the new jumps: "kernel bug: touch N ended and began in
  same frame" (a new touch replacing an old one was written in one frame) and
  jumps right at scroll start: finger frames arriving bunched over the network
  were written microseconds apart, and libinput normalizes movement to time,
  so a normal step looks like a leap.

### 20. Glide factor; paced frames; lift and new touch in separate frames (in progress)

- `OMACVM_SCROLL_GLIDE` (1.5): the glide carries 1.5 times macOS's momentum at
  the fingers' speed.
- The virtual touchpad writes the same fingers' frames at least 3 ms apart,
  coalescing bunched ones (positions are absolute, nothing is lost); a lift
  and a new touch go into two frames.

- Definitely fast now, but the curve is not macOS's: it only gets fast when
  scrolling really fast; macOS notices the speeding up much sooner.
- Jumps 64 -> 69, same-frame errors 524 -> 532 during the test: rare now (they
  were about one per scroll), not yet zero.
- Cause of the late response: the One Euro filter measured the finger's speed
  through a 1 Hz filter of its own, so it kept smoothing (and lagging) for a
  while after the finger sped up.

### 21. The filter notices speeding up sooner (in progress)

`OMACVM_SCROLL_FILTER` = "1.5 0.4 8": smoothing at rest unchanged (1.5 Hz),
opening with speed four times as strongly (beta 0.4), speed changes noticed
at 8 Hz instead of 1 Hz.

- Better; but fast scrolls run on too long after the lift: with the filter
  responding properly, the 1.5 glide factor (added while the filter still held
  fast scrolling back) carries too far. Glide back to 1.0, macOS's own
  (`OMACVM_SCROLL_GLIDE=1.0`).
- More natural, but a fast scroll covers only half the page that macOS does.
  So the touch phase is too slow at speed, not the glide.

macOS points per millimetre by finger speed (the `accel:` logs, medians):
under 10 mm/s 1.2, 10-30 0.5, 30-80 0.5, 80-160 7.4, 160-300 11.4, over 300
13.1. macOS accelerates about tenfold between slow and fast; test 18's base
calibration had been thrown off by macOS's whole points at slow speeds.

### 22. Slow: raw fingers; fast: macOS's own scroll; blended (in progress)

- The virtual centre moves by `(1 - w) * raw + w * macOS * POINT_UNITS`, `w` a
  smoothstep of the filter's finger speed between 30 and 80 mm/s
  (`OMACVM_SCROLL_BLEND`): pixel-fine raw fingers when slow, macOS's
  accelerated steps (its whole curve and how quickly it reacts) when fast.
- `OMACVM_SCROLL_POINT_UNITS` = 20 touchpad units per macOS point (test 6's
  scale, which felt right, at today's 0.082), also for the glide (fixed now,
  no velocity matching), so distances match macOS's.
- Debug: `blend:` lines.

- Better, but without macOS's ease-out at the end of a glide: macOS's momentum
  comes in whole points at irregular intervals, single small steps towards
  the end, and they were applied as they came.

### 23. A continuous, easing glide (in progress)

Each 4 ms tick moves the virtual fingers by a share of the pending glide
(`OMACVM_SCROLL_GLIDE_SHARE` 0.15, about 25 ms) instead of all of it: the same
distance, but a continuous movement that eases out exponentially.

- Very close, but in a side-by-side screen recording (macOS, Omarchy, twice
  each, the same scrolls) the scroll does not travel in a perfectly smooth
  ease-in and ease-out.

### Recording analysis (2026-10-02, `scroll-analysis/`)

Per-frame page movement at 60 fps over the full page width:

| | macOS | Omarchy (test 23) |
|---|---|---|
| fast flick, rise to full speed | about 5 frames (80 ms) | about 9 frames, bumpy: 60, 77, 53, 45, 49, 108 |
| peak speed | 8,000-13,800 px/s | capped: exactly 36.75 px per 120 Hz frame = 4,410 px/s |
| glide decay constant | 0.24 s | 0.25 s (matches: macOS's momentum) |
| tail roughness | 0.31 | 0.42 (3.5, 10, 6.5, 8, 4, 7, 2, 6 px) |
| distance of a fast scroll | 11,000-12,000 px | 5,000-6,000 px |

Causes: the glide's speed limit (1000 mm/s of virtual finger) at the then
scale; a mis-placed blend (between 30 and 80 mm/s macOS scrolls only ~0.5-1
point per mm, far less than the raw fingers, then jumps to 7-13 above
80 mm/s); and glide steps on a 4 ms clock against 120 Hz frames (2 or 3 steps
per frame).

### 24. Fixes from the analysis (in progress)

- Virtual finger movement at a quarter of the units (`OMACVM_SCROLL_RAW_SCALE`
  0.25, `OMACVM_SCROLL_POINT_UNITS` 5.5 = 1 macOS point per pixel), the
  compositor's scroll factor four times higher (0.328): the same slow
  scrolling, four times the headroom under libinput's jump limit (about
  17,600 px/s at `OMACVM_SCROLL_MAX_RATE` 100,000 units/s).
- Blend between 80 and 160 mm/s, where macOS's steps meet the raw fingers.
- The glide moves by the share matching the real time since the last tick
  (`OMACVM_SCROLL_GLIDE_TAU` 25 ms) on a 2 ms clock: the same movement in
  every 120 Hz frame.

- "This is so good!" Recordings 2 and 3 (`scroll-analysis/metrics.py`): the
  cap is gone, peaks 15,800-21,800 px/s on both, distances in the same range
  (matched big flicks: macOS 22,199 px/s, 8,727 px, decay 0.159 s; Omarchy
  21,813 px/s, 7,984 px, 0.155 s). Recording 2 showed regular empty frames on
  Omarchy (every ~8 frames, the VM's display output); recording 3 had none.

### Input recording (recording 4, `scroll-analysis/align.py`)

Trackpad frames and macOS's scroll events recorded on the Mac, the virtual
fingers in the guest, lined up with the video (offset +0.2 s):

- Glide decay: macOS 0.220 s, Omarchy 0.218 s: matches.
- Glide distance relative to the speed at the lift: macOS 0.58 s (median),
  Omarchy 0.93 s; medium flicks sped up after the lift (1,500-1,800 px/s at the
  lift, 1,850-2,900 px of glide). The fixed glide scale (1 point = 1 pixel)
  starts at macOS's internal speed, while at medium speeds the content moved
  slower during the touch (raw fingers).
- Touch phase: too few samples per speed band to tune on.

### 25. The glide continues at the content's speed (in progress)

Scale = virtual speed at the lift / macOS's first momentum speed (limited to
a quarter to four times `POINT_UNITS`): macOS's momentum gives the shape and
duration, the content does not speed up or slow down at the lift.

Recording 5 (with input):
- Glide distance per speed at the lift: macOS 0.71 s, Omarchy 0.40 s: matching
  the lift speed overshoots the other way (the last frames before a lift are
  slower: fingers slow down before lifting, and the filter lags).
- Touch phase, output px per finger mm (two recordings agree): Omarchy is 1.2-2
  times macOS's at 160 mm/s and more, where macOS's own steps are used (160-250:
  13.3 vs 6.6; 250-400: 8.7 vs 7.1; over 400: 14.3 vs 9.3). The point scale
  "1 point = 1 pixel" was computed, not measured; the production VM also runs
  at display scale 1.6, so a VM pixel looks smaller than a macOS pixel.

### 26. Measured point scale, fixed glide scale (in progress)

`OMACVM_SCROLL_POINT_UNITS` 3.6 (5.5 x 0.65, the median of the measured
bands), the glide back at that fixed scale (`OMACVM_SCROLL_GLIDE_MATCH=1`
keeps the matched variant): fast touch and glide as macOS's, seen on screen;
slow scrolling (raw fingers) unchanged. Expected glide distance per speed:
test 24's 0.93 x 0.65 = 0.60 (macOS 0.58-0.71).

Recording 6 and a better analysis (`transfer.py`): the earlier touch-phase
numbers were distorted by the virtual centre's jumps at touch restarts.
Counting only steps within one touch and converting units to on-screen pixels
by total distance (robust to the VM's display delay): 0.301 and 0.306 px per
unit in two recordings. With that, Omarchy's fast touch phase was 0.2-0.3x
macOS's, the opposite of the earlier conclusion. A sign check (macOS's steps
and the fingers agree 128 of 128 times) and a filter replay (the filter
follows a recorded 44.7 mm flick to 44.1 mm) ruled out the suspects; a fast
attack for the filter's speed estimate went in anyway.

### Recording 7: both systems at display scale 2

Per gesture (`trace.py`): a fast macOS scroll is ~6 % touch and ~94 % glide
(590 points while touching, 8,994 of momentum); Omarchy's glide is macOS's
momentum times the point scale, as designed. So distance hangs on one number,
on-screen pixels per macOS point: 1 virtual unit = 0.408 px at scale 2 (0.30 at
1.6), 3.6 units per point = 1.47 px on Omarchy against 1.0 on macOS; the glides
agree independently (distance per lift speed 0.87 s vs 0.65 s, 1.34x). About
10 % of a touch's macOS steps arrive just after the lift and were dropped.

### 27. Calibrated: 1 macOS point = 1 on-screen pixel (in progress)

- `OMACVM_SCROLL_POINT_UNITS` 2.45 (3.6 / 1.47).
- `OMACVM_SCROLL_RAW_SCALE` 0.184 (0.25 / 1.36): slow scrolling looks exactly
  as at scale 1.6, where it was "perfect".
- macOS steps arriving after the lift go into the glide.

Recording 8 (`glidecal.py`: on-screen glide pixels per macOS momentum point,
per glide, independent of the lift speed, which the VM's display delay skews):

| | median px per momentum point |
|---|---|
| macOS | 0.99 (1 point = 1 pixel: validates the method) |
| Omarchy | 0.99-1.11 (assuming 0-60 ms VM display delay) |

The glide, ~94 % of a fast scroll, now travels as far as macOS's within about
5-10 %; decay 0.22-0.25 s on both. Two Omarchy glides measured short (0.39,
0.59) were cut by the next touch.

"This really feels awesome."

### 28. Locked to this setup, relative for others

The tuning above is the reference: MacBook Pro 16" (trackpad 156 x 96 mm, read
from MultitouchSupport), natural scrolling and the default scrolling speed
(neither key set in macOS's preferences), VM display scale 2. Each factor of
the chain is then adjusted relative to it:

- Display scale: the virtual trackpad's scroll factor is `0.328 * 2 /
  omarchy_monitor_scale` in `monitors.lua`, next to Omarchy's own scaling
  value, so it follows Omarchy's scaling menu (logical pixels look
  scale/2 times as large).
- Trackpad size: the helper reads it (`MTDeviceGetSensorSurfaceDimensions`)
  and sends it with the scrolling direction on connect (`O <natural> <w> <h>`);
  the guest maps finger movement in real millimetres.
- Natural scrolling: macOS's own steps (fast touch, glide) already follow it;
  the raw finger movement gets the matching sign.
- Scrolling speed (Accessibility): macOS's own steps follow it; slow (raw)
  scrolling self-calibrates. At 40-120 mm/s the guest compares macOS points
  per finger millimetre with the reference, 6.74 (6.1-7.7 over five
  recordings), and moves a gain (0.5-2) towards the ratio after each touch,
  kept in `/var/lib/omacvm/scroll-calibration`. On the reference Mac it stays
  at about 1.

### 29. Chromium vs the rest (final)

Recording 9 (Chrome and Files side by side): "Chrome is perfect now, Files is
not: slower, without the same acceleration, and the system in general too";
"Slack is very smooth" (Electron, i.e. Chromium). Apps convert touchpad scroll
values differently, and everything had been tuned against Chrome. The Files
list in the recording was too short to measure (it hit its end), and a
synthetic in-VM measurement was dropped: on a desktop in use it captured the
wrong windows, including a login form; the screenshots were deleted.

Ratio from the user's own earlier judgement instead: test 2 ("Files very close
to macOS") had raw scrolling at 3.3 times today's Chrome-tuned value, converted
to the same display scale. Omarchy itself sets per-app touchpad speeds
(`o.window(..., { scroll_touchpad = ... })`, terminals 1.5), so:

- base scroll factor x3.3 (`0.328 * 3.3 * 2 / omarchy_monitor_scale`): GTK
  and the rest;
- `scroll_touchpad = 1 / 3.3` for Chromium-based windows (Chromium, Chrome,
  Brave, Edge, Vivaldi, Omarchy's web apps `chrome-*`, Slack, Discord,
  VS Code, Cursor, Obsidian, Signal, Spotify, 1Password, Teams, Figma,
  Electron): exactly as before for them.

Results: "much better, love it". This is the state that shipped as Glide.

## Candidate if the wheel cannot pan a zoomed page

Replay macOS's physics as **touchpad** movement instead of wheel steps: move
two virtual fingers on the virtual touchpad by macOS's scroll deltas, keep them
down through macOS's momentum and lift only when it has died down. Apps then
get touchpad scrolling (Chromium pans a zoomed page properly), but with near
zero speed at the lift, so Chromium and GTK add no fling of their own.

## Test changes on the production VM (resolved)

Adopted on 2026-10-02 through the feature itself (`omacvm enable glide`): the
test drop-in `/etc/systemd/system/omacvm-gestures.service.d/scroll-test.conf`
was removed, Chromium's and Chrome's flags files were restored from their
backups (Glide adds `--disable-smooth-scrolling` itself and remembers it), the
test block in `monitors.lua` gave way to `omacvm_glide.lua`, and the Mac helper
runs without test options again.
