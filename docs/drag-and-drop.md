# Drag and drop files into the VM

*Experimental, off by default (from 3.3).*

Drag files from the Finder (or the Desktop, or any app that drags files)
onto the VM's window and let go:

- over an app that takes files (a Files folder, a browser's upload field, an
  editor), the files go into that app, as if dropped from inside Omarchy;
- over the desktop or an app that takes none, they go into `~/Downloads`
  (a name already there gets " (2)", nothing is overwritten) and a notice
  says how many came.

## Switch it on

1. Open the VM's settings in OmacVM.app: **Sharing & Devices > Drag and drop
   files**. Or `omacvm enable drag-drop --vm NAME`, or the control centre.
2. Restart the VM once (shut it down, start it again). The VM's window takes
   drops from then on.

The first time, the VM builds a small helper (a few seconds). `omacvm check`
says what is missing in its "drag and drop" line.

## What it does and does not do

- **Files only, up to 256 at a time.** A folder in the drag, or more than 256
  files: the cursor shows that the window does not take it. Drag the files
  in a folder instead, or share the folder with **Mac folder**.
- **Copies, read-only.** The VM gets copies of just the files you drop
  (APFS clones when the file is on the VM's drive: instant and no extra
  space; a copy otherwise, only while the Mac keeps 10 GB free). The VM
  cannot change or delete the originals, and sees nothing else of the Mac.
- **An app that opens a dropped file directly** (an editor, an image viewer)
  opens the copy in `/run/omacvm/drop`, which is read-only: **Save** fails,
  use **Save As**. Files a Files folder copied, or that went into Downloads,
  are normal files.
- **How long the copies stay:** dropped into an app, until the VM stops (an
  upload may read them later); put into Downloads, the copy in the drop
  folder goes at once.
- **When it goes to Downloads instead:** no app under the pointer takes
  files, the screen is locked (nothing is ever drawn over the lock screen),
  or the drop reached the VM more than 1.5 s after you let go (a big copy
  from another drive: the pointer has moved on by then).
- **Not yet:** dragging from the VM out to the Mac (use **Mac folder**),
  Photos, Mail attachments and Safari images (they are not files yet when
  dragged), and an app's drop zone lighting up while you hover.

## How it works

1. QEMU's window (the VM's window) is a drop target only with the switch on.
   It takes a drop only while the VM's `omacvm-drop` service runs (it says
   hello every 15 s); before that the cursor shows no drop.
2. QEMU opens the dropped files itself, on a background thread (macOS lets
   the app you dropped on read them; files from the Desktop, Documents and a
   disk image opened with no permission prompt; an iCloud file that is not
   downloaded yet and USB drives are not checked yet), and hands the open
   files to OmacVM.app, never their paths.
3. OmacVM.app clones or copies them into the VM folder's `drop/<id>/`, which
   the VM sees read-only at `/run/omacvm/drop` (virtio-9p), and tells the
   VM over its own virtio port.
4. In the VM, `omacvm-drop` starts a drag from where the pointer is (QEMU
   already moved the VM's pointer under the Mac's) and lets go: the app
   there gets an ordinary Wayland drop of the files.

Logs: the VM's `logs/qemu.log` says per drop how many files, how big,
cloned or copied, and where they went in the VM; never their names.

Developers: [ADR 0069](adr/0069-drag-and-drop.md).
