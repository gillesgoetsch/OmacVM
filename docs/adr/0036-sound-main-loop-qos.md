# 0036: Sound on a busy Mac: QEMU's main loop at user-interactive QoS, no HDA catch-up

Status: accepted, built (`audio-crackle`). Hidden fallback `audioClassic`.

## Context

A user on a Mac mini (10 cores, VM with 8 vCPUs, Scarlett 2i2) heard the
sound crackle while listening to Spotify in the VM and moving around in it.
OmacVM.app's sound goes Intel HDA → QEMU's mixer → SDL → CoreAudio. Both
timers that move the sound (the HDA's DMA timer and the 1 ms audio timer)
run in QEMU's main loop, the thread that also runs virgl. SDL's own audio
thread already runs at a fixed high priority (SCHED_RR 47); the main loop
ran at the default QoS, on equal terms with the vCPU threads.

Measured on an M4 Max with the Mac's cores oversubscribed (8 busy vCPUs,
glmark2, 8 busy Mac threads), a tone through PipeWire's PulseAudio part,
10 minutes: the main loop ran 10-49 ms late about 3,500 times and 100+ ms
late 9 times; the tone broke 337 times. Two causes:

1. The Mac's scheduler: the main loop waits behind vCPU threads.
2. virgl's own work: new shaders stop the main loop for 50-80 ms. QEMU's
   93 ms ring keeps the Mac playing through it, but afterwards the HDA
   codec took the whole missed time of guest audio at once (wall-clock
   pacing plus sync corrections of up to five times real time). The guest
   saw its DMA position jump and PipeWire under-ran. Every stall had to be
   buffered twice: in QEMU and in the guest.

## Options

1. The main loop at user-interactive QoS (as AppKit's main thread).
2. Move the HDA and audio timers to their own thread: upstream's HDA code
   expects the BQL; a big change for one device.
3. Another backend (QEMU's CoreAudio driver): the same main loop feeds it,
   and it would drop the SDL patches (device follows the Mac, recording off
   the BQL).
4. More buffering in the guest (ALSA headroom 8192): rides out the stalls
   (337 → 15 breaks) but adds 128 ms to a round trip that is already about
   280 ms.
5. Fewer vCPUs than cores ("Best" = all cores): helps only when the Mac
   itself is busy and costs everyone CPU; the user's VM had 8 of 10.
6. The HDA codec stops catching up after a stall: the guest's audio is
   taken at most 1/32 faster than real time, the rest forgiven; QEMU's ring
   alone covers the stall.

## Decision

Options 1 and 6: `qemu-darwin-main-loop-qos.patch` and
`qemu-hda-no-catch-up.patch` (codec property `pace`, on).
`defaults write org.omacvm.app audioClassic -bool true` starts QEMU with
`OMACVM_MAIN_LOOP_QOS=default` and `pace=off`, as 2.9.1. QEMU logs both;
`omacvm check` shows them ("sound timing"). Option 4 stays a documented
fix for 2.9.x (troubleshooting finding 25).

## Consequences

- 10-minute runs, breaks in the tone: with the VM's GPU and the Mac busy
  12 → 2; with every core busy too, median 365 (2.9.0) → 120 (QoS) → 50
  (QoS and pacing). The spread between runs is large (other work on the
  Mac); the main loop's lateness (thousands of 10-49 ms delays → under 10)
  is the steady signal. Round trip unchanged (about 282 ms).
- After a stall QEMU's ring refills at 1/32 over real time (a 60 ms stall
  takes about 2 s); a second long stall inside that window can still empty
  it, which the Mac hears as a short gap.
- The main loop may take a P-core from a vCPU while it renders; it is one
  thread, and the guest's GPU work waits for it anyway.
- Remove the switch once a release has run without anyone needing it.

## 3.0.1: the guest side

The rest of the glitches under full load were put down to the VM's own
sound threads starved of CPU. Measured on a Mac mini M4 (VM with 8 CPUs):
with RTKit working, PipeWire's data loops already run real-time (SCHED_RR
20, RTKit's cap) and its main threads at nice -11, and a full load in the
VM leaves the tone almost clean (0 sink / 3 app xruns, 2 breaks at the
start in 5 minutes). They fall to normal priority only when RTKit's
watchdog demotes them: it takes a stretch of more than 10 s in which the
VM's threads did not run but its clock went on (QEMU stopped from
outside) for a runaway thread, demotes every real-time thread for the rest
of the session and refuses new ones for 5 minutes (`kill -STOP` of QEMU
for 15 s does it every time; a QMP stop does not). Breaks in 5 minutes:
real-time 2, 6, 2, 0; demoted 81 (the mini busy with two builds as well)
and 0. The VM's slices already give PipeWire its share of the CPUs, so
real-time matters when the Mac is busy too. With the drop-in, PipeWire
stayed real-time after a 15 s stop, a reboot and an RTKit restart.

Options: (1) RTKit without the watchdog (`--no-canary`); (2) Arch's
`realtime-privileges` and the realtime group, so PipeWire sets real-time
itself (gives every process of the user real-time up to 98 and needs a new
login); (3) a bigger quantum or headroom (adds latency, does not touch the
cause). Chosen: (1), a drop-in for `rtkit-daemon.service`. RTKit's other
limits stay (priority cap 20, RLIMIT_RTTIME); the kernel's fair server
keeps normal threads running next to real-time ones. `omacvm check` shows
"sound priority" (real-time or not). Undo: remove
`/etc/systemd/system/rtkit-daemon.service.d/90-omacvm-no-canary.conf`.
