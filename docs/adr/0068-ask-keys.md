# 0068: Questions take the keys with the old "ignoring other apps" flag

Status: accepted, built (`app-ask-keys`, 3.2.19). Raw rows:
work/after-3218/ask-keys.

## Context

macOS 14 made `NSApp.activate()` a request: an app in front has to yield
first. OmacVM.app's questions came with no click in the launcher: a plug-in,
a lost desktop, a timeout, a click in QEMU's menu (the launcher only gets a
notification), `omacvm start`. Nothing yields then, so the question sat there
without the keys. In the on-screen `usb` row 3.2.17 and 3.2.18 both fail this
way: the VM stays in front, Return and Escape go to the VM.

## What macOS allows

A small app stood in for the launcher (background, floating alert), a second
app was really active, and nothing clicked. macOS 27.0 on a Mac mini, 26.6.2
and 15.8.2 on GitHub's runners, the same on all three:

| How | App active, alert key |
|---|---|
| `NSApp.activate()` | no |
| `NSRunningApplication.current.activate(options: [])` | no |
| the same with `.activateIgnoringOtherApps` | yes |
| `NSApp.activate(ignoringOtherApps: true)` | yes, also with `runModal` |
| `.nonactivatingPanel` on the alert | key, the other app stays in front |

From another process, `activate(options: [])` on the launcher was refused
too (27.0; that row hung on the runners). `runModal` does not activate by
itself: the alert shows at modal level, without the keys.

## Decision

`AskKeys` (OmacVMWindow) calls `NSApp.activate(ignoringOtherApps: true)`.

- A question from the VM's side (USB question and notices, USB list, lost
  desktop, why the VM started again, Features… problems, the update's shutdown
  timeout) takes the keys only with the VM, this app or no app in front. In
  front of another app the person keeps the keys; the window floats, a click
  answers it. USB asks only with the VM or the app in front anyway.
- A question about a start the person just asked for (start on another Mac,
  Mac setup, fast network) takes them always: the start waits for it, also
  from `omacvm start` in a terminal.
- Each of them floats on every Space and over a full-screen window, so that
  taking the keys does not move the person to another Space.
- USB's half second with the buttons off, now `AskKeys.hold`, also covers the
  lost-desktop question: until now Return typed into a VM could not reach it,
  and Return there restarts the desktop.

`showWindow` stays on `NSApp.activate()`: the app's window after a VM ended
asks nothing, so it can wait for the person.

## What was rejected

- A panel that takes keys without activating: QEMU stays active with its
  keyboard grab, and its window keeps the app menu.
- QEMU yielding on request, the way macOS wants it: a new channel into QEMU
  and a runtime rebuild for what one flag does, and only with QEMU in front.
  This is the way to go if macOS drops the flag.

## Consequences

The flag is deprecated since macOS 14 ("will have no effect"), yet works up to
27.0. If it stops working, questions go back to floating without the keys:
the behaviour before, and a click still answers them. The on-screen `usb` row
is what shows it. `AskKeys.hold` uses a run loop timer: a block on the main
queue never runs while `runModal` runs inside another such block (measured:
the buttons stayed off).
