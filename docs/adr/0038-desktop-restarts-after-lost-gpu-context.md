# 0038: The desktop restarts by itself after a lost GPU context

Status: accepted, built (`gpu-auto-recovery`, 3.0.1). Builds on 0034 (the
GPU memory budget, which also names every lost context).

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
- Other apps are left alone: a browser restarts its GPU process itself;
  others draw black until they are restarted (`omacvm check` names them).
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
