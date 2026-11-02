# 0069: Drag and drop of files from the Mac: QEMU opens, the app clones, the VM drops at the pointer

Status: accepted, built (`drag-drop`: off by default, experimental,
OmacVM.app only; for 3.3.0). Asked for by the user ("drag and drop file
functionality would be really nice ... as an option").

## Context

Files reach the VM today through the Mac folder (a shared folder at
`~/Mac`) or the clipboard (text and PNG only). Dropping a file from the
Finder onto the VM's window does nothing: QEMU's window is no drop target.

Hard parts: the drop is taken by QEMU (the window's process), so only QEMU
gets macOS's access to the dropped files; files can be large; the guest must
get them into the app under the pointer, not only somewhere on disk; the VM
is untrusted.

## Decision

Four layers, each with one job:

1. **QEMU's window** (`omacvm-cocoa-drop.patch`, rules in
   `omacvm-cocoa-drop-logic.patch`: `ui/omacvm-drop.h`): with
   `OMACVM_DROP_SOCKET` set (the switch on), every VM window registers for
   file URLs. `draggingEntered`/`draggingUpdated` answer copy only while the
   app said "ready", for 1-256 items and no folder (from the URL alone, no
   disk access on the main thread); the guest pointer follows the drag.
   `performDragOperation` takes the paths and returns at once; a serial
   background queue opens each with `O_NOFOLLOW`, keeps regular files only,
   and sends the descriptors in frames of at most 32 with `SCM_RIGHTS`.
   No path leaves QEMU.
2. **The app** (`OmacVMDrop`: `DropServer`, `DropStage`, `DropWire`):
   listens on the socket (only QEMU's pid may connect: `LOCAL_PEERPID`),
   stages each drop on its own queue into `<VM>/drop/<random id>/<name>` with
   `fclonefileat` (APFS: instant, copy-on-write) or a copy while 10 GB stay
   free, and tells the VM on the port `org.omacvm.drop` (nr 10). Folders and
   files are made with `O_NOFOLLOW`/`O_EXCL` from the open folder; names are
   checked (one component, no control characters, 255 bytes).
3. **The share**: `<VM>/drop` over virtio-9p, `readonly=on`, tag
   `omacvm-drop`, mounted `ro` at `/run/omacvm/drop` with `cache=loose`: safe
   because every drop folder is written whole before the VM hears of it,
   never changed, and looked up only by the id it was told.
4. **The VM** (`src/drop/guest`): `omacvm-drop` (user service) says hello
   every 15 s; QEMU takes drops only within the 45 s lease. Per drop it runs
   `omacvm-drop-at`: a transparent layer-shell overlay, a virtual-pointer
   press for a button serial, `start_drag` with `text/uri-list`
   (percent-encoded), the overlay's input region emptied, two tiny moves,
   release. The pointer is never placed by the helper: absolute
   virtual-pointer moves map over the whole layout (19 px off with
   Omanotch's hidden output); QEMU already put it under the Mac's. No taker,
   a locked screen, a late drop (> 1.5 s after the release) or a missing
   helper: `~/Downloads`, never overwriting. The answer (`app`, `downloads`,
   `failed`) is checked and logged by the app; staging of a drop that went
   to Downloads goes at once, the rest at VM stop.

Off means none of it: no port, no 9p device, no socket, QEMU registers no
drop types. The 9p device is the very last argument (after the Mac folder),
so switching moves no other PCI device (`DropPlan.finish`, `drop-tests`).

## Rejected

- Bytes over a virtio port (clipboard style): every byte copied twice, slow
  for big files; the share with clones is free.
- The guest agent's `guest-file-write`: slow (base64 per call), root writes
  into the user's home.
- The app walking dropped folders from a folder descriptor: opening entries
  under Desktop/Documents/iCloud there is a new access for macOS (a prompt).
  v1 takes files only; QEMU could walk folders later.
- VM to Mac drag out: needs an edge to drop on (none in full screen) and a
  guest-to-Mac file path; not now. The Mac folder covers it.

## Consequences

- One more port and, with the switch on, one more 9p device.
- A file opened from the share is read-only in the VM (the (i) text says it).
- On screen and not testable unattended: the real Finder drag, the pointer
  following it, iCloud files that are not downloaded yet (QEMU opens them
  off the main thread), Esc cancels. The hidden VM rows use QEMU's test hook
  (`OMACVM_DROP_TEST=1` in QEMU and the app's side: a `test-drop` line from
  the app runs the same path as `performDragOperation` after the pasteboard).
