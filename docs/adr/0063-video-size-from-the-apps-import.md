# 0063: Videos at the size the app imports them: an EGL vendor library hands the import to the VA shim

Status: accepted, built (`h264-edge`, 3.2.12), on with the 3.2.11 app's
`omacvm.valogical=1`; `OMACVM_VA_LOGICAL=0` in an app of the VM turns it off.
Notes, the investigation and the review: work/tracks/h264-coded-edge.md.

## Context

ADR 0061 has the Mac sample a video surface at the size the VA-API shim says.
That left out surfaces the decoder asks for larger than the picture, at the
stream's coded size: H.264 at every size that is not a multiple of 16 (1080p
in 1920x1088), HEVC at sizes that are not a multiple of 8 (1000x562 in
1000x568). Chrome on Wayland and mpv kept the strip there (H.264 1080p: red
band 15.75 rows instead of 8, the picture squeezed by 1080/1088).

The picture's size is in no VA-API call: libva has no crop for decoding (H.264
picture parameters give the size in macroblocks, HEVC the coded size), and
the apps send only slice NAL units, never an SPS. Measured with libva's trace
in Chrome 154 and FFmpeg 9.0.2: context and surfaces 1920x1088, four buffers
per picture (picture, IQ matrix, slice parameters, slice data). The size
exists only where the app shows the surface: its EGL dma-buf import of the
planes. Chrome on Wayland imports one NV12 image of 1920x1080 per frame, mpv
R8 1920x1080 and GR88 960x540. Mesa's virgl drops that size
(`virgl_drm_winsys.c`: the import's template is unused).

## Options

1. **A size guess** (1088 -> 1080, a table of 16:9 sizes): wrong for videos
   that really have 1088 rows, and for apps that import the whole surface and
   crop themselves.
2. **Read the SPS**: the apps never send it.
3. **On the Mac only**: the size never reaches the Mac.
4. **Patch the VM's Mesa** to pass the import's size: a Mesa build in every
   VM, replaced by each Omarchy update; the upstream route is a draft
   (work/upstream-drafts/virgl-dmabuf-import-size.md).
5. **LD_PRELOAD** of a wrapper: misses sandboxed and setuid processes, and
   breaks with any app that sets its own preload.
6. **A glvnd EGL vendor library in front of Mesa's** (chosen): glvnd's
   supported way into every EGL call, a file in `/etc/glvnd/egl_vendor.d`.

## Decision

Option 6, with the VA shim deciding.

- `src/app/guest/omacvm_egl.c` (`/usr/local/lib/libEGL_omacvm.so.0`,
  `/etc/glvnd/egl_vendor.d/10_omacvm.json`, before Mesa's `50_mesa.json`).
  Its `__egl_Main` checks glvnd's vendor ABI (major 0), loads
  `libEGL_mesa.so.0` and calls Mesa's `__egl_Main`, then swaps
  `getProcAddress` for `eglCreateImage` and `eglCreateImageKHR`. After Mesa
  made a dma-buf image in a video format (R8, R16, GR88, GR1616, NV12, P010)
  it calls the shim's `omacvm_va_dmabuf_imported_v1`, but only when the shim
  is loaded in that process (found among the loaded objects, `RTLD_NOLOAD`,
  the handle kept). No DRM file, log, config file or environment variable.
- It fails open: Mesa missing or another ABI major: `__egl_Main` is false and
  glvnd uses `50_mesa.json`. The desktop's own processes get false before
  Mesa loads and run Mesa alone, as before: Hyprland, Xwayland, Omarchy's
  shell (`quickshell`: the bar and Omarchy 4's lock screen), hyprlock and
  sddm-greeter.
- Mesa then loads as two glvnd vendors in other processes. glvnd lists the
  devices of every vendor without merging them (`QueryVendorDevices`), so
  each device would be listed twice; this library offers no
  `eglQueryDevicesEXT`, so the list stays Mesa's and displays opened on a
  device are Mesa's own (Hyprland's already were).
- The shim (only with `omacvm.valogical=1`): its `vaExportSurfaceHandle`
  hook records, for Mesa's own 4:2:0 surfaces, each plane's dma-buf (device,
  inode) and the Mac's resource, looked up on the VA display's own DRM file
  at the first export only (mpv exports every frame). An import is taken only
  when every plane is a known dma-buf of one surface at offset 0, R8/R16 on
  the Y plane, GR88/GR1616 on the UV plane, NV12/P010 on both (UV half of the
  image, rounded up), and no plane larger than Mesa's. A plane never declared
  counts as its whole texture, so a full-size import sends nothing; a size is
  sent (3.2.11's NOP payload) only when it changes, and recorded only after
  the send worked. Record, DRM file and send under one lock; `vaTerminate`
  clears the records under it before Mesa closes the display.
- Video processing from such a surface is scaled for the latest size, also
  from a VA import made before the EGL import (the owner's size is looked up
  when used). A converting `vaGetImage` reads an import at that size and cuts
  the region to it (FFmpeg asks for all 1088 rows; Mesa refuses a region past
  the import).

## Consequences

- Guest only, no runtime change: the 3.2.11 app's runtime takes these sizes
  as it takes the shim's own. An older app (no marker) or
  `OMACVM_VA_LOGICAL=0`: the shim sends nothing; the library still loads and
  passes everything through.
- A library in every EGL process but the desktop's own (the compositor,
  Xwayland, the shell with its lock screen, the login screen): kept to three
  calls at load and a format check per dma-buf import. A process is matched
  by its executable's name (`/proc/self/exe`).
- One size per resource on the Mac: if two importers in one process show the
  same surface at different sizes, the last one wins.
- Not reached, because the import happens in a process without the shim or
  outside EGL (as with 3.2.11): Firefox (decodes in its RDD process, shows the
  frames in another), mpv `vo=dmabuf-wayland` and anything else Hyprland
  samples, Chrome with out-of-process decoding or Wayland overlays, Vulkan
  importers, GBM-pixmap imports. A registry shared across processes would be
  the next step, only if one of them shows the strip.
- Off for one app: `__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json`;
  for the VM: delete `/etc/glvnd/egl_vendor.d/10_omacvm.json`.
- Tests: `src/app/guest/tests/va-shim-logical.sh` (Chrome's and mpv's import
  patterns, HEVC, what sends nothing, the converting `vaGetImage`, video
  processing, after `vaTerminate`), `src/app/guest/tests/egl-vendor.sh` (a
  stand-in Mesa and shim: what is handed on, fail-open, each skipped
  process, the device list), in a test VM `tests/video/video-geometry.sh`
  (H.264 and HEVC at their coded size must be exact; 3.2.11's guest fails).
