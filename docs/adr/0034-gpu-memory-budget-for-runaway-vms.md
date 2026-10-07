# 0034: The GPU memory budget stops a runaway VM, never a desktop

Status: accepted, amended twice (dynamic; the desktop's reserve, 3.0.5: see the end). Built on `fractional-scale`
(`app/runtime/patches/virgl-resource-memory-budget.patch`,
`app/runtime/patches/virgl-darwin-memory-pressure.patch`).

## Context

A VM's textures and buffers live in the Mac's memory. 2.9.0 added a budget
for them (standards section 4: no guest-controlled allocation without a
limit) at a quarter of the Mac's memory. A resource past the budget is
refused; the guest's driver is not told, so the app that wanted it loses its
GPU context. When that app is Hyprland, the VM goes black until it restarts.

On a 16 GB Mac mini with a 5K display, picking scale 1.6 did exactly that:
4 GB was reached. Measured (QEMU's log, Omarchy with Chromium): 1.6 GB at
5K, 2.0 GB at 6K, 3.1 GB at 8K, and while a scale changes every
screen-sized buffer is made again, so the highest use is 2.6, 3.4 and 6.2 GB.
More apps, more memory. The user wants every display to work, 6K and 8K
too, "no artificial limits".

## Options

1. Keep a quarter. 5K with apps, 6K and 8K break on 16 GB Macs.
2. No budget. A VM that makes textures in a loop fills the Mac's memory.
3. A budget only a runaway VM reaches: three quarters of the Mac's memory.
4. Size it from the displays (largest display × N buffers). Needs a guess
   at N per app; a browser alone can pass any such guess.

## Decision

Option 3. The default is three quarters of the Mac's memory (12 GB on
16 GB, 6 GB on 8 GB, 48 GB on 64 GB); `OMACVM_GPU_MEMORY_MB` still sets
another, 0 turns it off. Screens and cursors keep their 256 MB reserve
past it. QEMU's log notes each new peak in 512 MB steps, and `omacvm check`
shows the peak and says when the budget was reached.

## Consequences

- A real desktop no longer reaches the budget, at 8K and any scale.
- A runaway VM can now take three quarters of the Mac's memory before it is
  stopped, on top of the VM's own memory: macOS compresses and swaps before
  that. Still bounded; the Mac does not run out.
- A refused resource still costs the app its GPU context. Telling the guest
  (reset status for a robust compositor) is separate work.
- The peaks in the log show what VMs really need; if they ever come near,
  this record is replaced.

## Amendment: dynamic, from macOS's memory pressure (same branch)

Any fixed number is wrong somewhere: three quarters lets an 8 GB Mac with a
4 GB VM take 10 GB, and "a VM with a lot going on will hit any hard limit
eventually" (the user). So below the runaway guard nothing is fixed: QEMU
follows macOS's memory pressure (dispatch source, and
`kern.memorystatus_vm_pressure_level` when a big resource is made). Normal:
everything goes through. Warn: Apple's GL frees what it holds for deleted
resources, the app asks the VM to drop its file cache, and a new resource of
16 MB or more is refused only if it is bigger than all the free, inactive and
purgeable memory macOS has left (a first version kept a sixteenth of the
Mac's memory free; the user would rather swap than see a black desktop, so
only what cannot fit at all is refused). Critical: new
big resources are refused, after a glFinish and three more looks over
100 ms (within a second of the last refusal after one look: each wait holds
QEMU's main loop, so the whole VM). Screens, cursors and small resources are never refused for pressure.

Rejected: sizing a budget from the displays and the VM's memory (option 4
plus the VM's RAM): the VM's RAM is mostly not resident (free page
reporting), and 8K at a scale change needs 6.2 GB for a moment, which such a
budget on a 16 GB Mac would refuse.

Consequence: a refusal still costs the app its GPU context, and Hyprland
cannot recover from that (it aborts on a reported reset; stock guest Mesa
does not report one). The app shows a message with a desktop restart
instead of a black window. Guest Mesa reporting resets (gpu-robust's
`mesa-virgl-reset-status.patch`, PR #60) would let browsers recover by
themselves; Hyprland would then stop (whether start-hyprland starts it again
is not tested).

In 3.0.0 this meets two patches from `gpu-robust` (merged in rc-3.0.0):
Venus (Vulkan) memory counts against the same budget
(`virgl-venus-memory-budget.patch`, one shared atomic counter), and a GL
resource the budget refused loses the context that attaches it at once
(`virgl-resource-budget-context-loss.patch`). The pressure check covers GL
resources only and runs before the budget charge; a pressure refusal does not
mark the resource for that immediate loss (the context is lost at its first
use, as before). Venus allocations stop at the budget, not at the pressure.
The bytes in use in QEMU's log and the status file include Venus memory.

## Amendment: the desktop keeps the guard's last part (3.0.5)

On a MacBook Air M2 with 8 GB (2026-10-06) a browser with big WebGL pages
filled the 6 GB guard while macOS still said "normal" (it had swapped 2 GB
and was fine). The guard then refused whichever resource came next: often
Hyprland's, so the VM went black, and since 3.0.1 the app restarts the
desktop, which closes every app. The guard did its job (the VM stopped
growing), but hit the wrong process.

Options: (1) a smaller guard on small Macs: the browser still gets there
first, only sooner; (2) lose the context that holds the most: the
renderer does not know which context owns a resource until it is
attached, and a lost context frees nothing until the app ends; (3) keep
the guard's last part for the desktop and let apps stop below it.

Decision: option 3 (`virgl-gpu-guard-desktop-reserve.patch`, rules in
`src/virgl_gpu_guard.h`). The reserve is a sixteenth of the Mac's memory,
512 MB to 2 GB, at most a quarter of the guard (8 GB Mac: apps 5.5 GB of
6 GB). The desktop's contexts are named by their process (the guest's
kernel names a context after it): Hyprland, quickshell and the lock
screen, hyprlock (it starts when the apps' share may already be full,
and a lock screen that stops drawing leaves the VM locked). The guest
chooses that name, so an app could claim it, but the reserve stays inside
the guard. The guest's kernel makes a resource before it says for which
context and attaches it right after, so a resource past the apps' share is
made "for the desktop only" and the first GL context that attaches it
decides: the desktop keeps it, an app's context is lost at once and told.
Its memory comes back at once; the handle keeps an empty 1x1 stand-in
(`virgl-gpu-guard-dropped-placeholder.patch`), because the app may already
have handed the buffer to Hyprland, and a command of Hyprland's that names a
missing resource would lose Hyprland too (3.0.3 did that with refused handles).
macOS's memory pressure follows the same path: a big resource macOS has no
room for is for the desktop only; the desktop's own resources wait only for
the guard. Venus memory is an app's. QEMU's status file says why each
context was lost (guard, pressure, error); the app's window and the VM's
notes use it, and an app lost to the guard or to pressure gets a note in
the VM ("chromium stopped drawing").

Consequences: on any Mac the desktop has room for a few more screens'
worth of buffers (a 5K offscreen buffer is 21 MB, a 6K one 81 MB) after
apps are stopped; the app that took the memory is the one that stops. The
resource that cost the app its context gives its memory back at once, and so
does anything the lost app makes past its share afterwards: the VM's stock
Mesa is not told about the loss, and a lost Chromium went on making 5K
buffers in a loop (in a first version they stayed and filled the desktop's
part). Still bounded by the guard.

Checked in a VM (MacBook Pro, 3.0.3 runtime, guard set to 3 GB, Chromium
windows of WebGL pages with 512 MB of textures, then a scale change with the
memory full): with 3.0.3's virglrenderer Hyprland and quickshell lost their
contexts and the screen went black; with this patch only Chromium was lost,
the desktop took up to 140 MB of its part for the scale change, and a new
Chromium window drew after the old ones were closed.
