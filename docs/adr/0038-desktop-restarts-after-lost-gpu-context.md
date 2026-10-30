# 0038: The desktop restarts by itself after a lost GPU context

Status: accepted, built (`gpu-auto-recovery`, 3.0.1); amended in 3.2.15 (a
lost Chrome or Chromium gets a new GPU process: see the end). Builds on 0034
(the GPU memory budget, which also names every lost context).

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
With that runtime change (ADR 0034's 3.2.15 amendment) the same steps lost
nothing, and a Chrome lost at critical past its grace drew right again
about 2 s after the loss while critical still held.
After two ends in 95 s
(that restart, then one by hand) Chrome still drew with the GPU, but the
WebGL page's context stayed lost (Chrome blocks WebGL on a page after GPU
process crashes): the note's "may need a reload".

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
