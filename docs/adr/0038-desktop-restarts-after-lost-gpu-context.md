# 0038: The desktop restarts by itself after a lost GPU context

Status: accepted, built (`gpu-auto-recovery`, 3.0.1); amended in 3.2.15 (a
lost Chrome or Chromium gets a new GPU process), 3.2.16 (a loss inside an
app's minute is told when it is over) and 3.2.17 (a lost Vulkan context is
counted and told): see the end. Builds on 0034 (the GPU
memory budget, which also names every lost context).

## Context

When virglrenderer on the Mac ends a GPU context of the VM (a refused
buffer when macOS is short of memory, an illegal command), that app draws
nothing from then on. For Hyprland that is the whole screen: black. Since
3.0.0 the app shows "The VM's desktop stopped drawing" and a button that
restarts the desktop session. The user asked for this to happen without a
click.

Nothing in the VM learns of the loss by itself:

- The VM's Mesa (Arch Linux ARM's) does not report resets. The Mac side
  can (`virgl-context-loss-report.patch`), but the guest half lives in our
  own Mesa (`src/app/guest/mesa`, PR #60), which no VM gets today (a
  product decision).
- Even when told, Hyprland 0.56 only stops ("Cannot continue until proper
  GPU reset handling is implemented"). The session would end the same way,
  so reset reporting would not save the apps either.
- The Mac knows exactly: QEMU writes every loss, with the app's name, to
  `logs/gpu-memory`, which the app already reads every 2 seconds.

## Decision

- The Mac decides, the VM acts. On a lost `Hyprland` context the app runs
  `omacvm-desktop-recover desktop graphics|memory` in the VM through the
  guest agent (as it already did for the button). The script writes down
  the apps that have a window (`hyprctl clients`, which still answers),
  logs to the journal, and restarts SDDM: autologin logs the user in again,
  or the login screen comes when autologin is off.
- The new session (Hyprland autostart, `omacvm-desktop-recover notify`)
  shows a notification: why, and which apps were closed, and that anything
  not saved in them is lost. Said plainly, because it is real data loss.
- A locked session stays locked. Autologin would otherwise bring back an
  unlocked desktop with nobody at the Mac (idle lock). The script notes
  whether Hyprland held a lock (`omarchy-hyprland-session-locked`), and the
  new session locks itself again (`omarchy-system-lock`, retried until
  Hyprland holds the lock, up to 30 s) before it shows the notification.
  For those few seconds the new desktop is unlocked. With autologin off,
  the user who just logged in is asked once more.
- Only a refusal counts as "nothing happened". When the agent does not
  answer within 2 s (likely when macOS is short of memory), the restart may
  be under way: the app neither tries again nor restarts SDDM directly, it
  asks, and the 10-minute count stays.
- At most once in 10 minutes. Lost again that soon means the cause is
  still there (macOS still short of memory, a cap too low): a loop of
  restarts would only close apps again and again. Then the app asks with
  the 3.0.0 alert, which stays as the fallback (also when the agent does
  not answer, and with `desktopAutoRestart` off).
- A lost shell (`quickshell`: Omarchy's bar and launcher) restarts only the
  shell (`omarchy-restart-shell`), at most once a minute. No app closes.
- Other apps are left alone: a browser restarts its GPU process itself
  (wrong with the VM's Mesa: see the 3.2.15 amendment); others draw black
  until they are restarted (`omacvm check` names them).
- VMs set up before 3.0.1 have no script: the app restarts SDDM directly
  there (no notification) until `omacvm apply` installs it.

## Consequences

- No black screen that needs a click. Mac mini, 5K at scale 1, a forced
  1400 MB cap and three WebGL browser windows: Hyprland lost, the app
  restarted the desktop 0.5 s after QEMU reported it, and the new desktop
  drew 1.9 s after the loss (2 to 3 s over two runs). Lost again within
  10 minutes, the app asked instead, and its button brought the desktop
  back in 2 s.
- The automatic restart closes apps the user may have wanted to save, also
  when nobody was looking at the screen (a build in a terminal ends too).
  A black desktop gave no way to save them either, short of SSH; the
  setting turns the automatic restart off for whoever prefers to decide.
- Real GPU reset handling inside Hyprland (keeping the apps) would need
  Hyprland and a reset-reporting Mesa; neither exists today.

## Amendment: a lost Chrome or Chromium gets a new GPU process (3.2.15)

"A browser restarts its GPU process itself" was wrong. The VM's Mesa does
not tell Chrome about the loss, so Chrome keeps drawing into the lost
context: its new buffers past the line are dropped (1x1 stand-ins, ADR
0034), and its windows go blank or flicker until it is quit. A Mac mini
(16 GB, 5K, 2026-10-30) at critical memory pressure lost Chrome's context
that way; the user restarted the whole VM ("chrome crashes and flickers
unusable").

Decision: for an app lost to the guard or to macOS's pressure, the app
already runs `omacvm-desktop-recover app NAME guard|pressure` (once a
minute per app at most). That now ends the app's GPU process: a process of
the desktop user whose name (`/proc/PID/comm`) is exactly NAME and that has
the argument `--type=gpu-process`: exactly that argument, or that word in a
command line of one string (Chromium's GPU process sets its process title,
its arguments joined with spaces). The guest kernel names a context after
the process that made it, and Chrome's GPU main thread keeps the process
name, so QEMU's "context 20 (chrome)" is that process. Chrome and Chromium
start a new GPU process by themselves (measured below); other
Chromium-based apps (Electron's, such as VS Code) have the same GPU process
and should too (not measured). Open tabs stay; the lost context's memory
comes back on the Mac when the old process is gone. Apps without a GPU
process (Firefox, mpv, a terminal) get the note only, as before; desktop and
shell names are never acted on, and nothing is matched as a pattern.

- At most once per app in 6 minutes and 3 times in an hour. Chrome counts
  an ended GPU process as a crash, and after 3 recent ones it falls back to
  its next GPU mode (software) for the rest of the session; it forgives one
  crash per full 5 minutes since the last (Chromium's
  `gpu_process_host.cc`). Once in 6 minutes never reaches that count by
  itself, and a crash of Chrome's own or a restart by hand on top still
  leaves room. The times are kept in root's own folder
  (`/run/omacvm-recover`, 0700, never through a link): root never writes
  into the user's `/run/omacvm`.
- Pages with live WebGL may be blocked after such a restart ("WebGL hit a
  snag"): Chrome blocks them when its GPU process did not end normally. The
  note says that a reload brings them back.
- With the 3.2.14 runtime, while macOS stays critical, every new big buffer
  of an app costs it its context (ADR 0034), so a new GPU process is lost
  again at its first window buffer, and the app tells each app at most once
  a minute: Chrome would sit blank again. From 3.2.15 QEMU judges growth at
  critical instead (ADR 0034's 3.2.15 amendment); both ship together. The
  note says to quit the app and open it again if it goes blank again.

Checked in a hidden test VM (M1 Max, 3.2.14's app and runtime, the VM's
monitor 5120x2880 at scale 2 like the user's 5K display, critical pressure
forced inside QEMU through its test hook, a WebGL page whose colour follows
the clock, the screen's pixel read every 0.25 s): with the VM's old script,
Chrome 156 and Chromium 153 stayed frozen on one frame for the 55 s
measured after the loss, their GPU process unchanged. With this script the
app's next look ran it, the GPU process was ended, and Chrome drew right
again 5.9 s after the loss (Chromium 2.9 s), its WebGL page got its context
back (a "restored" event), and Chrome kept the GPU (GPU compositing on).
The user's step by hand (`pkill -f -- 'chrome --type=gpu-process'`) brought
the old Chrome back 1.3 s after it. Restarted while QEMU still saw critical
(3.2.14's runtime), the new GPU process was lost again at once, and the app
did not tell the VM again within its minute: Chrome stayed blank, which is
why the runtime change at critical ships with this. The step by hand while
critical held did the same: its new GPU process was lost again at once.
After two ends in 95 s
(that restart, then one by hand) Chrome still drew with the GPU, but the
WebGL page's context stayed lost (Chrome blocks WebGL on a page after GPU
process crashes): the note's "may need a reload".
With that runtime change (ADR 0034's 3.2.15 amendment) A1h's steps (the
restart while critical held) lost nothing, and a Chrome lost at critical
past its grace drew right again about 2 s after the loss while critical
still held.

Not chosen:

- Shipping the reset-reporting guest Mesa (`mesa-virgl-reset-status.patch`,
  PR #60). Told about the reset, Chrome's GPU process ends itself and a new
  one starts: the same restart, for the cost of replacing every VM's GL
  driver (a build of Mesa in each VM) and of a new way for apps without
  robustness to end. It stays the long-term route, with upstream.
- Holding back the lost app's fences: stock virgl has one fence timeline for
  the whole VM, so Hyprland would stall too.
- Losing the biggest context instead (ADR 0034 rejected it because a lost
  context freed nothing until its app ended): a lost context's memory now
  comes back when its GPU process ends, but the renderer still does not know
  which context owns a resource until it is attached.

## Amendment: a loss inside an app's minute is told when the minute is over (3.2.16)

The app tells the VM about an app's lost context at most once a minute
per app. Until 3.2.16 a loss inside that minute was dropped: nothing kept
it, and QEMU's count of lost contexts had already moved past it, so the VM
was never told. In the rows of the 3.2.15 amendment (M1 Max, 3.2.14's app
and runtime, critical forced through QEMU's test hook) four losses of
Chrome came inside its minute and were never told: the second of R1mc, A1h
and A1c (a new GPU process, lost again at once) and R2's (about 43 s after
R1mc's note at 16:10:52; the VM's journal has no line for it). Chrome
stayed blank and no note said so.

Decision: `GPUMemoryNotice` keeps the newest such loss per app (its cause
and when the app saw it) and tells the VM when that app's minute is over:
60 to 66 s after the last note, as the app looks every 5 s, also when
nothing new was lost. Still one tell per app per minute: losses every 5 s
are told at 0, 60, 120 s as before; only a loss that is the last inside
its minute, an app that stays blank, is now told where it was dropped. A
desktop restart voids the kept losses: the session's apps closed, and a
late tell could end the GPU process of a Chrome opened again in the new
session. Apps told more than a minute ago are forgotten, so names from the
VM cannot grow the list. qemu.log says "NAME in the VM lost its GPU
context again within a minute of the last note: told when that minute is
over, unless the desktop restarts before then", then "NAME in the VM lost
its GPU context N s ago: ... (told now: a minute after the last note)".

The VM side is unchanged (`omacvm-desktop-recover app NAME WHY`). With
3.2.15's script a late tell restarts the app's GPU process only within the
script's limit (once per app in 6 minutes, 3 times an hour). A loss right
after such a restart is told inside those 6 minutes, so it gets the note
"NAME stopped drawing ... Then reload or restart NAME", not a second
restart: R2's Chrome would still not have been restarted, but the VM now
says that it stopped drawing. A VM with the script of 3.0.5 to 3.2.14
shows the same note a minute late; an older VM has no note. App update
only: the VM needs no update.

Known limits:

- The late tell comes 60 to 66 s after the previous one, not at once.
- A second context of the old GPU process lost between the app's look and
  the VM's end of that process would be told a minute later: a note while
  Chrome draws again. Not seen: every row lost one context per GPU process.
- An app quit and opened again inside the minute still gets the kept tell:
  a note, or a restart of its new GPU process only when the script's limit
  allows (not after a restart at the first tell).
- While the app's "desktop stopped drawing" window is up its looks wait;
  Restart voids the kept losses.
- A reboot inside the VM (the same QEMU, so the same app run) keeps the
  kept losses, while it empties the script's restart stamps in /run: a
  late tell can then end the GPU process of a Chrome opened just after the
  reboot, once.

Not chosen:

- No minute at all (the VM decides): a note per loss, with no limit on
  notes.
- The VM keeps a restart its limit refused and does it when the 6 minutes
  are over: Chrome blank for minutes anyway, and the user may have
  restarted it by then (a healthy GPU process ended, one more Chrome crash
  counted).
- The loss's age as a fourth argument, so the VM skips a tell when the
  app's GPU processes all started after the loss: a change to the VM's
  interface for rare cases its limit already bounds. Left for later.

Tests: `swift run desktop-tests` (looks every 5 s: a second loss 30 s
after the first is told at 60 s with its own time; three in a minute give
one tell; a loss every 5 s gives one tell a minute; a desktop restart
voids a kept loss; the desktop, the shell and other errors are never
kept). On 3.2.15's rule, through an adapter kept outside the repo, 6 of
these fail.

Checked in a hidden test VM (M1 Max, this change on 3.2.15's app and
runtime and 3.2.15's VM script, the VM's monitor 5120x2880 at scale 2,
critical with 40 MB left forced through QEMU's test hook, one 64 MB
texture in Chrome): Chrome's context was lost, the app told the VM 2.7 s
later at its next 5 s look and the VM ended Chrome's GPU process; the new
one was lost at its first window buffer (56 MB), 3.9 s after the first
loss and 1.2 s after the VM ended the old GPU process. The app said it
would tell that loss when the minute was over and told it 64.9 s after
the first tell (the VM's journal: 65.0 s); the VM did not restart Chrome
again ("restarted 1 min ago") and showed the note. Hyprland and the shell
lost nothing.

## Amendment: a lost Vulkan (Venus) context is counted and told (3.2.17)

Until 3.2.16 only GL (virgl) contexts counted. When vkr ended an app's
Venus context (a command the Mac's driver would abort on, ADR 0065, or
memory the budget refused), QEMU printed "venus context N (NAME) is lost"
and nothing else: `logs/gpu-memory` stayed at lost=0 (gpu_lost_delta 0 in
all four lose rows of the ghostty-gpu lane, 3.2.15 on an M4 and an M1 Max),
the app said nothing, and `omacvm check` did not name the app (the gap
noted in #624). Most Vulkan apps then end by themselves: the VM's Venus
driver aborts when it sees the ring's fatal status. A Ghostty drawn on the
Mac's GPU through Zink does not: it hangs with its windows (Hyprland's
"not responding"), and no new Ghostty window opens while it lives: Omarchy
starts Ghostty as one instance (`--gtk-single-instance=true`), so a new one
asks the frozen one over D-Bus and gives up ("Timeout was reached").

Decision:

- QEMU counts a Venus loss where it counts a GL one, from vkr's ring-fatal
  path (`virgl-venus-lost-context-count.patch`): the ring thread leaves the
  name and cause in the shared budget module, and the renderer thread, which
  owns the status file, writes it at its next poll: lost, lost_last,
  lost_recent, lost_recent_why `venus` (refused on the Mac) or `guard` (the
  budget had refused a Venus allocation of that context first: with the
  guest's asynchronous allocation the app's next use of that memory is what
  ends it), and a new list, lost_recent_kind (`gl` or `venus`).
- A context the guest was closing is not lost. When an app's process ends,
  the guest's kernel closes all its handles before it destroys the context;
  a handle vkr still uses (the ring's own buffer, a command stream being
  read, a reply being written) then ends the context, and the ring command
  that fails after it is a teardown. In the zink-venus rows a SIGKILL during
  Zink's teardown printed "is lost" that way (M1 Max qemu-k15.log line 130).
  vkr marks such a context closing before its fatal flag; the ring-fatal
  path then logs "ended while the guest closed it" and counts nothing.
- The app tells the VM through the same `GPUMemoryNotice` (once a minute per
  app, a loss inside the minute told when it is over) with a new verb,
  `omacvm-desktop-recover venus NAME venus|guard`. Not `app NAME venus`:
  the 3.2.15 and 3.2.16 scripts take any cause but `pressure` for a full
  graphics memory and end the app's GPU process (a Chromium with WebGPU
  would lose its GPU process for nothing). An older script answers the new
  verb with its usage (exit 2); the app waits 2 s for the exit (no answer
  in time: nothing more, as for the desktop) and says once in qemu.log that
  Update VM puts the note in.
- The VM ends nothing. The note says what happened; for `ghostty` it says
  to close the frozen Ghostty first (Terminate: the programs in it end; no
  new Ghostty window opens until then) and that the next one starts on the
  CPU (not one set to Zink by hand), and the script writes
  `/run/omacvm/gl-zink-off` (root's file in root's folder, one line "lost
  TIME WHY", never through a link): OmacVM's EGL library starts Ghostty on
  Zink only without that file (the experimental Zink path; without it
  Ghostty is on the CPU anyway, ADR 0064), so a refused Zink Ghostty cannot
  hang again and again before the VM restarts.
- `DesktopRecovery` never restarts the desktop or the shell for a Venus
  context, whatever its name (the desktop and the shell draw with GL).
- `omacvm check`'s "GPU contexts" names Venus losses too, marked
  "(Vulkan)".

Checked in hidden test VMs (Mac mini M4 and M1 Max, KosmicKrisp, 3.2.16's app
fe590bb0 against this change, a Ghostty 1.3.1 on Zink by hand, its context
ended on purpose by a test Vulkan layer that makes one image view vkr
refuses; work/ghostty-gpu/venus-loss in the lane's notes):

- 3.2.16 counted none of 8 such losses (vkcube, Ghostty): lost stayed 0, no
  note. With this change all 13 were counted within 0.3 s of QEMU's "is
  lost" line (12 in the same 0.2 s look), with the app's name, and told 0.5
  to 4.8 s later (the app looks every 5 s). The VM's note showed in Omarchy's popup; for
  Ghostty `/run/omacvm/gl-zink-off` was written (root, 0644, "lost TIME
  venus"). A VM with the 3.1.32 or 3.2.0 script answered the new verb with
  its usage, and the app logged "Update VM puts it in" once.
- vkcube ended by itself 0.5 to 0.6 s after its loss. The frozen Ghostty
  never received a typed line (60 s), its main thread waited in the
  kernel's `drm_syncobj_array_wait_timeout`, a SIGTERM ended it within 8 s
  every time (15 of 15), and its shell ended with it (10 of 10 looked at).
  Hyprland's not-responding dialog came 2.8 s after the loss (M1).
- A Ghostty started as Omarchy's launcher starts it (one instance, owning
  its D-Bus name) while the frozen one lived opened no window: it gave up
  with "Timeout was reached", or with "Remote peer disconnected" once the
  frozen one was ended (both Macs). Started after the frozen one ended, a
  new Ghostty opened in 0.53 to 0.56 s on llvmpipe, drew and took typing.
- No false counts: 60 Ghostty windows on Zink per build closed with
  SIGTERM, killed with SIGKILL 20 to 500 ms into Zink's teardown, or killed
  while drawing, counted nothing and showed no note; a Zink scroll run
  counted nothing. The race the zink-venus rows met once (M1 qemu-k15.log
  line 130) did not come back in these 120 ends, so the teardown rule is
  proven by `test-venus-robust.c` l-teardown (it fails with the patch taken
  out of the same tree, on KosmicKrisp and MoltenVK).
- tccd asked for nothing, no GPU fault, no crash report.

Not chosen:

- Hooking the count where the proxy marks a context lost (its fences
  signalled from then on, `virgl-venus-lost-context-fences.patch`): that
  happens only when a later fence submit fails, and its line appeared 0
  times in the six QEMU logs of the zink-venus rows, the four deliberate
  losses included.
- Ending the frozen Ghostty for the user: its shells and their programs
  would end without a word; Terminate is the user's.
- Making Ghostty survive the loss inside the guest's Venus driver (abort,
  or VK_ERROR_DEVICE_LOST to Zink): its windows would still never draw
  again and its shells would still be lost, and where it waits is not known
  yet.
