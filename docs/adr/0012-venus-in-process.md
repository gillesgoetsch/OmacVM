# 0012: Venus render server as a thread of QEMU on macOS

Status: accepted. Built on `gpu-venus` (`virgl-darwin-venus-in-process.patch`,
`virgl-darwin-stream-sockets.patch`, meson `-Drender-server-worker=thread`),
not merged. Amended by [0065](0065-venus-checks-what-metal-aborts-on.md): Venus
has been on by default with Automatic on macOS 26+ since 3.0.13 (ADR 0035), so
vkr checks what the Mac's driver would end QEMU on.

## Context

On Linux, virglrenderer runs Venus in a separate `virgl_render_server`
process (forked, or one process per context) and shares memory with QEMU as
dma-bufs. On macOS:

- Venus device memory is a MoltenVK `MTLHeap` exported with
  `VK_EXT_external_memory_metal`. A Metal heap is an object pointer in one
  process; there is no fd to pass to another process.
- The proxy talks to the server over `AF_UNIX SOCK_SEQPACKET`, which macOS
  does not have (`socketpair: Protocol not supported`).
- virglrenderer forks the server whenever QEMU passes `RENDER_SERVER`, even
  when built with the thread worker.

## Options

1. Separate process, share memory as IOSurfaces or Mach ports. Big change in
   MoltenVK's export path and in vkr; not upstream anywhere.
2. Server as a thread in QEMU's process; the proxy's socket protocol stays,
   on stream sockets with fixed framing.
3. Call vkr directly without the proxy. Diverges from upstream's design.

## Decision

Option 2: force `in_process` on macOS, build with the thread worker, and
replace `SOCK_SEQPACKET` with `SOCK_STREAM` plus a length frame.

## Consequences

- Heaps are shared by pointer; blob mapping works (with the 16 KiB blob
  alignment and the HVF subregion fix).
- No process boundary between Venus and QEMU: a bug in vkr or MoltenVK can
  crash or compromise QEMU. Mitigation at the time: Venus off by default
  (hidden switch), QEMU keeps the hardened runtime; revisit option 1 if Venus
  becomes the default. It became the default with KosmicKrisp in 3.0.13; ADR
  0065 has vkr check guest values first and says when to revisit option 1.
- The proxy's fence fd is written from the server thread: the macOS
  `eventfd` stand-in must be writable from any fd ([0011](0011-async-fences.md)).
- Stream framing is a patch upstream could take as the non-Linux fallback.
