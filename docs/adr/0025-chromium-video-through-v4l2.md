# 0025: Chromium's video through a V4L2 decoder in the VM

Status: accepted, prototype built (`chromium-v4l2`), not merged. Builds on
0014 (VideoToolbox inside virglrenderer's video path), which it uses
unchanged.

## Context

Omarchy's browser is Arch Linux ARM's Chromium. Upstream Chromium builds
VA-API for Linux arm64 by default; Arch Linux ARM turns it off and builds the
V4L2 decoders instead, so the VA-API decoding that Google Chrome, Brave,
Firefox, mpv and FFmpeg use in an OmacVM.app VM never reaches Chromium. It
decodes on the CPU: YouTube 4K60 in VP9 takes about one core in the VM and
1.4 on the Mac. Chromium's V4L2 decoder is also off by default in such builds
(`AcceleratedVideoDecoder`).

What Chromium 153 does with a V4L2 decoder on Linux, read from its source and
seen in the VM:

- It opens `/dev/videoN`, prefers the stateful API, and for a stateful device
  always uses `V4L2StatefulVideoDecoder` (HEVC there is `NOTIMPLEMENTED`).
- The driver allocates the decoded-picture (CAPTURE) buffers; Chromium
  exports them (`EXPBUF`) and its compositor imports the dmabufs with EGL.
- Before the import it checks every plane against the dmabuf's size.
- With GL (as in the VM), the only formats it shows without an image
  processor are ARGB/XRGB; NV12 needs the `AcceleratedVideoDecodeLinuxZeroCopyGL`
  feature.
- AV1 is not compiled in (Chromium ties its AV1 hardware decoding to VA-API).

## Options

1. Chromium's VA-API path with flags, as for Chrome's encoder: not possible,
   it is not in the binary.
2. Build and ship our own Chromium with VA-API: hours of build per release,
   every release, and a package that fights pacman's.
3. Recommend Google Chrome: works today with no flags, but it is not
   Omarchy's browser and has no Arch Linux ARM package.
4. A virtio-media/virtio-video device in QEMU: the guest kernel has no driver
   for it, QEMU has no device, and the decoded pictures would need their own
   way into virgl's GPU buffers. Much new code on the Mac side, where the
   guest is untrusted.
5. A guest V4L2 stateless driver: Chromium parses, and our code translates
   V4L2's per-codec controls into VA-API's picture parameters (H.264, VP9,
   HEVC each).
6. A guest V4L2 stateful driver whose work a daemon does with FFmpeg's VA-API
   decoding.

## Decision

Option 6, everything in the VM, nothing new on the Mac:

- `omacvm-vdec`, a kernel module (DKMS, like the battery module): a V4L2
  stateful decoder that does no decoding. It passes each bitstream buffer to
  `/dev/omacvm-vdec` and takes the answers from there.
- `omacvm-vdecd`, a daemon: FFmpeg decodes with VA-API (Mesa's virgl driver,
  the VideoToolbox backend of 0014), and one GL pass turns each NV12 picture
  into ARGB in the app's CAPTURE buffer.
- The CAPTURE buffers are GBM buffers the daemon makes and hands to the
  module, so what Chromium exports is a virtio-gpu buffer. Buffers the module
  allocated could not be imported: that is why the kernel's own test decoder
  (visl) decodes but shows nothing.
- ARGB because Chromium shows only that with GL, and because one virtio-gpu
  buffer cannot hold both NV12 planes (an import at an offset gets the first
  plane: virgl ignores the offset). VA-API's own surfaces cannot be handed out
  either: in the VM they are one page long, and Chromium's size check fails.
- VA-API's video processing (a shader that the Mac's OpenGL rejects, which
  then poisons the guest's GL context) and `vaCopy` (not implemented) are not
  used; the GL pass replaces both.
- Chromium gets `AcceleratedVideoDecoder` in the last `--enable-features` of
  `~/.config/chromium-flags.conf` (Chromium keeps only the last one).
- YouTube sends AV1 whenever the browser can play it, and this Chromium
  plays AV1 only on the CPU: YouTube at 1080p never reached the decoder. A
  small extension (loaded like Omarchy's own, in the last
  `--load-extension`) tells YouTube that AV1 is not supported, so it sends
  VP9.
- The GPU pass is waited for with an EGL fence after the next decode is
  sent, not right away, so the Mac's GPU does not sit idle between frames.

## Consequences

- Arch Linux ARM's Chromium decodes H.264 and VP9 on the Mac's media engine,
  YouTube included (VP9 up to 4K60). Not covered: HEVC (Chromium's stateful
  decoder lacks it, so it is not offered), AV1 (not in this Chromium; on
  YouTube the extension avoids it, other sites may still send AV1, which
  stays on the CPU), 10-bit (ARGB is 8-bit; VP9 profile 2 stays on the CPU).
- Per frame one extra GPU pass and an ARGB picture (4 bytes a pixel) instead
  of NV12. The CAPTURE buffers are pinned VM memory: about 33 MB each at 4K,
  10 of them for one 4K video.
- A kernel module in the VM, rebuilt by DKMS for every kernel; without the
  headers for a new kernel Chromium falls back to the CPU until they come.
- The daemon parses video from web pages: it runs as its own user, without
  network, in a sandboxed service. One thread serves all videos; at most 8
  decoders are open at once (more fall back to the CPU).
- Failures end in a decode error, never a frozen video: one video that goes
  wrong (a picture under 64 px, a stream VA-API cannot take, VA-API
  refusing a video's first pictures, the GPU not finishing a picture within
  1 s) fails alone and Chromium plays it on the CPU. If the daemon dies or
  hangs (systemd's watchdog, 5 s), every open video gets a decode error and
  systemd starts the daemon again 2 s later.
- Only under Chromium's GL compositor. Chromium uses the V4L2 decoder under
  any compositor that is not GL, and no Vulkan compositor can draw its
  buffers on Venus: Graphite (the "Chromium (WebGPU)" launcher) has no
  dma-buf import in the VM's Dawn, and Ganesh on Vulkan (`--use-vulkan`)
  makes vkr on the Mac import a virgl resource it cannot (the Venus context
  is lost). In the launcher the first frame restarted the GPU process: the
  video stopped after its first frames (4 to 18 in the rows) and every page
  there lost its GPU state, not the decode error and CPU fallback above.
  From 3.2.15 the launcher decodes on the CPU
  (`--disable-accelerated-video-decode`); the normal Chromium entry keeps
  the decoder.
- The module and the daemon trust each other only as far as the protocol
  goes: the module checks every size, index and buffer the daemon hands in,
  never reuses a decoder id, bounds what it queues for the daemon, and a
  daemon of another build is refused (protocol version).
- If Arch Linux ARM builds Chromium with VA-API one day, Chromium uses VA-API
  directly and this can go; nothing here depends on that.

## Addendum (3.2.16): the module's own poll

Chromium 153 waits for the CAPTURE queue with one-shot polls (POLLIN|POLLPRI,
no timeout) and drops a poll that returns anything else without posting a
new one. The kernel's `v4l2_m2m_fop_poll` returns EPOLLERR while neither
queue has a buffer queued, and that is the normal state at the end of a
stream and at a size change: Chromium holds every CAPTURE buffer while the
daemon still owes the last pictures and the LAST buffer. Chromium's waits
were used up on EPOLLERR, the LAST was never seen, and playback stood
still there (a looped video never looped; 3.2.15 and older).

- Options: (a) the module's own poll around `v4l2_m2m_poll`, (b) a full
  rewrite of the poll (done lists, LAST handling), (c) a Chromium flag for
  another of its decoder paths. (c) swaps in Chromium code never tested
  with this device, and Arch's Chromium is a binary OmacVM does not build;
  (b) duplicates the kernel's logic for no gain.
- Decision: (a). Under the queues' lock, after `v4l2_m2m_poll` has
  registered its wait queues, EPOLLERR is cleared while a queue streams and
  the daemon has not failed the decoder; `inst_fail_all` wakes a sleeping
  poll. A failed decoder, or one with both queues off, still gets EPOLLERR,
  so "daemon gone = errors, not hangs" holds. Guest only: no protocol
  change, any app version.
- Test: `vdec-test --hold-all-at-eos` (3.2.15's module fails it, 9 of 9
  rounds; the fix passes them).

## Addendum (3.5.0): the per-video frame throttle

- Problem: 60 fps VP9 in Chrome/Chromium in the VM showed one frame twice and
  skipped the next, every third frame for seconds (MacBook Air: 0-3 % of the
  frames per minute, in bursts; AV1 from MP4 ~0). Not the decoder: the same
  with the media engine and with libvpx, and Chrome's traces showed the
  decoder 10-12 frames ahead. Chromium's compositor (viz) throttles each
  video's frame sink to the interval the video asks for
  (`OnBeginFrameThrottleVideo`, on by default) and keeps the first value
  unless it moves by more than 2 ms. The first value is the average length of
  the frames queued at the first draw; WebM timestamps are whole milliseconds
  (16/17/17), so that average is 16.667 over 3, 6 or 12 frames but 16.5 or
  16.75 over 4. With 16.75 on a 16.67 ms screen the video's renderer takes
  16.75 as its render interval, its cadence check fails (16.67 ms of drift
  in 3.3 s, below its 8 s floor) and it picks frames by coverage, which the
  1 ms jitter of the timestamps turns into repeat + skip pairs. Every dropped
  frame in the traces was such a pair, and only while the window was 16.75.
- Options: (a) `--disable-features=OnBeginFrameThrottleVideo` in Chromium's
  flags; (b) leave it to upstream (Chromium code, not ours); (c) make
  YouTube send MP4 (exact timestamps): VP9 comes only in WebM there.
- Decision: (a), in chromium-video, merged like its other two switches.
  chromium-video already makes Chromium's YouTube VP9, so every Chromium
  user in an OmacVM.app VM is on this path. Google Chrome is not managed
  (its flags are the user's).
- Cost: without the throttle a video's frame sink gets every BeginFrame. At
  60 fps on 60 Hz that is the same count (the throttle saves nothing there);
  a 30 fps video on 60 Hz, or 60 fps on 120 Hz, wakes the renderer's video
  compositor twice as often (30 -> 60 a second); the frames drawn and the
  video's surface commits stay the same (30 a second in the traces).
  MacBook Air, whole machine, one ABBA block of 120 s windows each: a 30 fps
  VP9 clip 3327 mW with the throttle, 3331 without; YouTube VP9 1080p60 5459
  with (94 and 141 frames dropped per window) and 5728 without (11 dropped;
  its second window void), with the guest's CPU time, context switches and
  IPIs the same in all four windows, so no cost beyond the spread of
  identical windows (about 300 mW on that row). Not measured: 60 fps on a
  120 Hz Mac (the M1 Max, where the video's wakeups double).
- Test: `src/tests/chromium-no-av1.sh` (merge into the user's or /etc's list,
  a line of its own, off restores, a switch the user set stays).
