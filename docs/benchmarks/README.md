# Benchmarks

How OmacVM measures the four ways (Parallels, UTM, VMware Fusion, OmacVM.app)
against the Mac itself, so anyone can run
the same tests and get numbers that compare. The results so far are at the
end. The tools are in [`src/bench/`](../../src/bench).

## What we measure

| Test | What it tells you | Mac | VMs |
|---|---|---|---|
| Geekbench 7 CPU | CPU, single-core and multi-core | ✓ | ✓ (Linux ARM preview) |
| Speedometer 3.1 | web apps: browser and CPU together | ✓ | ✓ |
| MotionMark 1.3.1 | 2D graphics drawn through the browser | ✓ | ✓ |
| WebGL Aquarium, 30,000 fish | 3D in the browser, frames per second | ✓ | ✓ |
| Basemark Web 3.0 | the GPU in the browser: WebGL, canvas, SVG, plus some JavaScript and page tests | ✓ | ✓ |
| Geekbench 7 GPU | GPU compute | ✓ (Metal, OpenCL) | only OmacVM.app with Venus, see below |
| WebGPU matmul (`browser-bench.py webgpu`) | GPU compute in the browser, GFLOPS | ✓ | only OmacVM.app with Venus |
| glmark2 | OpenGL ES in the VM, absolute score | ✗ no macOS build | ✓ |

**GPU compute needs Vulkan or OpenCL in the VM.** Parallels, UTM and VMware
Fusion offer neither to a Linux guest: Geekbench 7's Linux ARM preview lists
no GPU there, and `bench.sh` records that as "not available in this VM".
OmacVM.app with the vulkan feature (`omacvm enable vulkan`, experimental)
has both: OpenCL through
rusticl and WebGPU in Firefox and in the "Chromium (WebGPU)" launcher (ADR
0022). One locked batch on the M4 Max: Geekbench 7 GPU OpenCL 42486 in the
VM vs 95380 for the Mac's own OpenCL; WebGPU matmul 5071 GFLOPS in the VM's
Chromium vs 6038 in Chrome on the Mac. Geekbench 7 for Linux has no Vulkan
backend, so the VM has no Metal-like score.
The browser tests (MotionMark, WebGL Aquarium, Basemark Web 3.0) and glmark2
measure graphics, not compute. glmark2 has no Mac version, so it has no Mac
baseline: compare its score between the routes only.

## The setup

Do all of this, or the numbers won't compare:

| | |
|---|---|
| Mac | MacBook Pro M4 Max, macOS 15.7.4 (ours; use yours and say which) |
| Each VM | 16 CPUs, 48 GB memory. On Parallels that needs Pro or the trial: Standard stops at 4 CPUs and 8 GB |
| One VM at a time | the VM under test runs alone. Quit the other VM apps, Parallels' background service included: `pgrep -l prl_` should print nothing while you test UTM or Fusion |
| Full screen | the VM app in full screen on the built-in display. `bench.sh` also starts Chrome full screen, on the Mac without the toolbar, so the page is the same size everywhere (1728x1080 at 2x on a 16" MacBook Pro). In a VM that also has an external display (Parallels, Fusion), Chrome must open on the built-in one: move the focus there first (`hyprctl dispatch focusmonitor Virtual-1`) |
| No screensaver | Omarchy's screensaver and lock off: `omacvm enable no-idle-lock --vm NAME`. It can start in the middle of a run otherwise |
| Google Chrome everywhere | Google Chrome on the Mac and in the VM. Arch's Chromium is much slower than Chrome (Parallels: 35.4 with Chromium 153 vs about 45 with Chrome), so it would not compare |
| Chrome's flags | in a VM, `bench.sh` starts Chrome with the flags in `/etc/chrome-flags.conf` and Omarchy's `~/.config/chrome-flags.conf`. On Fusion one of them must have `--ignore-gpu-blocklist` (OmacVM puts it in `/etc`), or Chrome draws in software ([why](../troubleshooting.md#2-fusion-browsers-draw-everything-in-software)) |
| Runs | 3 of each test (`bench.sh`'s default), report the median. Single runs land within 2 to 3 % of each other. The published [results](#results) say where they are single runs |

## Run it

### On the Mac

You need Google Chrome and Geekbench 7 in `/Applications`.

```bash
cd ~/.omacvm                      # or your clone of OmacVM
src/bench/bench.sh ~/bench/mac.jsonl
```

### In a VM

OmacVM copies its tools into the VM, so they are in
`/usr/local/share/omacvm/bench/` after `omacvm update` (or `omacvm apply`).

1. Install Google Chrome for Linux ARM (Arch Linux ARM has no package; this
   unpacks Google's own `.deb` to `/opt/google/chrome`). Run it again to update:

   ```bash
   sudo /usr/local/share/omacvm/bench/install-chrome.sh
   ```

2. For glmark2 and the renderer line, also install `glmark2` and `mesa-utils`
   with pacman.
3. Put the VM in full screen, open a terminal in Omarchy (as your desktop user,
   in the session, not over SSH) and run:

   ```bash
   /usr/local/share/omacvm/bench/bench.sh \
     --only geekbench,speedometer,motionmark,aquarium,basemark,gpu,glmark2 ~/fusion.jsonl
   ```

   glmark2 is not in the default list, hence `--only`. Leave the VM alone until
   it prints `results:`. Chrome opens and closes by itself.

4. Copy the file to the Mac. Name it after the route (`parallels`, `utm`,
   `fusion`, `app` for OmacVM.app), because the report and chart use the file
   names (OmacVM.app's SSH is `-P 52222 root@127.0.0.1`):

   ```bash
   scp -i ~/.ssh/omacvm root@<vm-ip>:/home/<user>/fusion.jsonl ~/bench/
   ```

### Options

```text
bench.sh [--runs N] [--only geekbench,speedometer,motionmark,aquarium,basemark,gpu,glmark2] [OUT.jsonl]
```

Each result is one JSON line: host, OS, test, run, value, and the browser
version or Geekbench link. `browser-bench.py` prints the page size and, for
Basemark, the link to the result on Basemark's site (Powerboard), where each
run is also public.

### GPU check for OmacVM.app

A quick check that the app's GPU path still works after a change to its
runtime (QEMU, virglrenderer, their patches). With the VM running and its
desktop user logged in, on the Mac:

```bash
app/scripts/gpu-check.sh ~/Library/Application\ Support/OmacVM/VMs/<name> [RUNS]
```

It installs Google Chrome in the VM when missing, runs WebGL Aquarium and
Basemark Web 3.0 there (`bench.sh --only aquarium,basemark`), and fails when
either gives no number or when the VM's `logs/qemu.log` shows a shader or GPU
command the Mac refused. One refused shader stops that GL context in the VM
for good: that was Basemark's hang at test 5 in 2.6.0
([finding 23](../troubleshooting.md#23-app-chrome-hangs-in-basemark-web-30-the-screen-flickers)).
Each runtime build also compiles the shaders of that case with the Mac's
OpenGL (`app/runtime/Tests/virgl/test-integer-sampler-shader.c`).

### GPU panel (final round)

The README chart's GPU panel comes from
[`tests/bench/final-round`](../../tests/bench/final-round/README.md): the
runbook and the scripts for the Mac and each VM. Two of its tests are new:

- [`tests/bench/gpu-throughput`](../../tests/bench/gpu-throughput/index.html):
  pure GPU work in WebGL 2, no network. One draw per frame into a fixed
  1920x1080 offscreen target, so the window size and vsync don't count; each
  frame waits for the GPU before and after its draw (`gl.finish()`). Two ways
  to time it: GPU time from Chrome's timer queries (frames of 40 ms), or wall
  time of long frames (80 ms or more, made longer until the fixed cost of the
  waits is under 2 % of a frame). Each system runs both; one row uses one
  method for every system: the GPU timer where every system has a timer that
  agrees with its own wall time, else wall time for all. The table and the
  chart say which. Headline: a ray-march shader; also an ALU score (GFLOPS)
  and a fill score (Gpixels/s). `run.py` runs it and prints JSON.
- [`tests/bench/vkpeak`](../../tests/bench/vkpeak/vkpeak.sh): Vulkan compute
  peak with [vkpeak](https://github.com/nihui/vkpeak) (MIT, downloaded or
  built at run time, pinned). On the Mac through vkpeak's own MoltenVK 1.4.1;
  in OmacVM.app through Venus. A VM with no GPU Vulkan device (none, or only
  lavapipe) gets "not available".
- Geekbench 7 GPU (OpenCL, Vulkan; the Mac: OpenCL, Metal), vkmark and
  glmark2 run in the same round; Geekbench only on a real GPU device, never
  PoCL or llvmpipe. glmark2 and vkmark have no macOS version: the panel shows
  their scores between the VMs.

## Power draw and battery life

How much power the whole Mac draws while Omarchy runs in a VM, against the
same work on macOS, and what that means for the battery. Run on the Mac:

```bash
src/bench/power-suite.sh ~/bench/power-mac.jsonl                      # macOS itself
src/bench/power-suite.sh --vm root@<vm-ip> ~/bench/power-fusion.jsonl  # one VM doing the work
```

| Load | What runs |
|---|---|
| idle | nothing: the desktop as you leave it |
| light | Chrome scrolling a long text page, like reading (`src/bench/pages/reading.html`) |
| video | YouTube 4K in Chrome (`video-bench.py`, below) |
| cpu | every CPU core busy |
| gpu | WebGL Aquarium with 30,000 fish in Chrome |

- **The number** comes from the battery's own telemetry (`power.sh`, no sudo):
  `AccumulatedSystemLoad` over `SystemLoadAccumulatorCount` in
  `AppleSmartBattery`, the average draw of the whole Mac, display included.
  macOS updates it about every 45 seconds, so each window starts and ends on an
  update (3 minutes plus up to a minute).
- **Battery life** is the battery's capacity over that draw: for this MacBook
  Pro 16" M4 Max, 100 Wh. On the charger the numbers are the same: the Mac
  reports what the system uses, not what the charger delivers.
- **Keep it quiet:** only the VM under test runs, its app in full screen on the
  built-in display, the same brightness for every run, no other apps, Bluetooth
  and Wi-Fi as usual. Don't touch the Mac while it measures. An agent running
  the tests must not poll during the windows either.

## YouTube 4K

```bash
src/bench/video-bench.py --port 9222 --seconds 60   # Chrome started with --remote-debugging-port=9222
```

It plays a 4K video (YouTube's embed player inside a small local page, which
YouTube needs), and reads from Chrome's media events which decoder plays it:
`VideoToolboxVideoDecoder` on the Mac and `VaapiVideoDecoder` in a VM mean
hardware; `Dav1dVideoDecoder`, `VpxVideoDecoder` or `FFmpegVideoDecoder` mean
the CPU. It also reports the resolution, frames per second and dropped frames.
On the Mac: AV1 3840x2160 at 60 fps in hardware, 0 % dropped.

## Report and chart

On the Mac, with all files in one folder:

```bash
cd ~/bench
~/.omacvm/src/bench/report.py mac.jsonl parallels.jsonl utm.jsonl fusion.jsonl app.jsonl --json results.json
~/.omacvm/src/bench/chart.py ~/.omacvm/docs/benchmarks/chart.json ~/.omacvm/docs/images/benchmarks.svg \
  "MacBook Pro M4 Max · macOS 15.7 · Google Chrome 154 · October 2026"
```

- `report.py` prints a Markdown table: the median of each test, and each route
  as a share of the first file (the Mac).
- `chart.py` draws the bar chart for the README and
  [compare.md](../compare.md): OmacVM.app first, then UTM, VMware Fusion and
  Parallels, each as a share of the Mac (the dashed line at 100 %). Five
  rows: Geekbench 7 multi-core, Speedometer 3.1, WebGL Aquarium, Basemark Web
  3.0 and Geekbench 7 GPU (OpenCL). Tests without a Mac value
  (glmark2, vkmark) and MotionMark (no stable result) are left out.
- The chart's input is [`chart.json`](chart.json): the medians from
  `results.json` with the GPU rounds added. CPU and Speedometer come from the
  2026-10-03 round, Aquarium and Basemark from the 2026-10-04 GPU round, both
  in [Results](#results). Numbers from a build that is not released yet are
  listed under `"unreleased"`; the chart stripes those bars and tags them.
- GPU compute in the chart: OmacVM.app with Vulkan in the VM (Venus on
  MoltenVK, OpenCL through rusticl), not released yet. Geekbench 7 GPU OpenCL,
  one locked batch on 2026-10-04: Mac 95,380
  ([252722](https://browser.geekbench.com/v7/gpu/252722)), OmacVM.app 42,486
  ([252731](https://browser.geekbench.com/v7/gpu/252731)), 45 %. Parallels, UTM
  and Fusion offer no OpenCL or Vulkan to the VM.
- OmacVM.app's Basemark has no full-screen run yet (2157 in a window, not
  comparable), so its bar is empty. The 2.9.0 candidate (not released) gives
  the same Aquarium as before on a quiet Mac, 21 to 23 fps in a window.

**About Geekbench.** The free version uploads every result to
browser.geekbench.com and prints only a link. `bench.sh` saves the link;
`report.py` opens each link in a visible Chrome window on the Mac and reads the
scores from the page. Geekbench's site turns away plain downloads, so curl
does not work. Your results are public on Geekbench's site.

## Results

2026-10-03, MacBook Pro 16" M4 Max, macOS 15.7.4, 16 CPUs and 48 GB per VM, in
full screen on the built-in display (3456x2160 at 120 Hz), Google Chrome 154,
OmacVM 2.3.0. Parallels Desktop 27.0.2 (Pro trial), UTM 5.0.6, VMware Fusion
26.0.1, OmacVM.app (preview, QEMU 11.1.1 from try-omarchy). Speedometer is
the median of 3 runs; Geekbench, MotionMark and glmark2 are single runs, so a
median of 3 may differ a little.

| | Mac | Parallels | UTM | VMware Fusion | OmacVM.app |
|---|---|---|---|---|---|
| Geekbench 7 single-core (single run) | 3267 | 3164 | 2944 | 3054 | 3183 |
| Geekbench 7 multi-core (single run) | 27290 | 26218 | 24414 | 27037 | 26984 |
| Speedometer 3.1 (median of 3) | 62.9 | 42.4 | 32.9 | 44.4 | 43.8 |
| MotionMark 1.3.1 (single run) | 5865 | no stable result | no stable result | 2368 | no stable result |
| glmark2 (single run) | no macOS version | 7306 | 964 | 1813 | 1017 |
| Geekbench 7 GPU | 207885 (Metal) | ✗ | ✗ | ✗ | ✗ |
| YouTube 4K decoder | AV1, hardware | VP9, CPU | VP9, CPU | VP9, CPU (1.6 % dropped) | VP9, CPU |

Power draw of the whole Mac (W), 3 minutes per load, brightness 50 %:

| | Mac | Parallels | UTM | VMware Fusion | OmacVM.app |
|---|---|---|---|---|---|
| Idle | 6.1 | 5.7 | (15.2) | 5.5 | 6.2 |
| Reading (light) | 6.6 | 7.3 | (19.3) | 5.9 | 6.8 |
| YouTube 4K (SDR) | 8.0 | 24.2 | 39.2 | 20.4 | 21.3 |
| Every core busy | 75.3 | 72.2 | 61.3 | 73.9 | 71.0 |
| WebGL Aquarium, 30,000 fish | 35.6 | 27.4 | 29.1 | 37.3 | 27.2 |

Notes:

- The VMs' idle can be a little below the Mac's: on the Mac the desktop and
  Terminal showed, in the VMs Omarchy's dark desktop, and this Mac's mini-LED
  display draws less for dark content.
- The WebGL row is not a GPU efficiency number: each route draws a different
  number of frames per second.
- An HDR video would make the Mac's own run unfair: macOS drives the display
  brighter for HDR. `video-bench.py` uses an SDR video (16.4 W with HDR on the
  Mac, 8.0 W with SDR).
- UTM's idle and reading numbers (in brackets) don't hold: a later check
  showed about 5 W at idle, also with an app open. Something was probably
  still busy in the VM during our run. They are being measured again
  ([#32](https://github.com/gillesgoetsch/omacvm/issues/32),
  [finding 15](../troubleshooting.md#15-utm-idle-power-is-being-measured-again)).
- MotionMark: [finding 16](../notes/findings.md#16-motionmark-gives-no-stable-result).

### GPU (2026-10-04)

The same Mac, macOS 15.7.4, Google Chrome 154, OmacVM 2.6.0 (release
candidate). One VM at a time in full screen on the built-in display (3456x2160
at 120 Hz), the Mac otherwise idle, display brightness at its lowest (it does
not change these numbers). An external display (3840x2400, 60 Hz, on its own
power) was connected: in full screen, Parallels and Fusion give the VM a second
monitor for it. Chrome ran on the built-in display's monitor everywhere, the
page 1728x1080 at 2x (OmacVM.app: 1728x1085). Median of 3 runs; the share of
the Mac in brackets.

| | Mac | Parallels | UTM | VMware Fusion | OmacVM.app |
|---|---|---|---|---|---|
| Basemark Web 3.0 | 3247 | 2446 (75 %) | 2182 (67 %) | 2522 (78 %) | not measured yet |
| WebGL Aquarium, 30,000 fish (fps) | 107.7 | 26.7 (25 %) | 28.1 (26 %) | 40.6 (38 %) | 23.9 (22 %) |
| Geekbench 7 GPU, Metal | 204241 | ✗ | ✗ | ✗ | ✗ |
| Geekbench 7 GPU, OpenCL | 117456 | ✗ | ✗ | ✗ | ✗ |

Each run:

| | Basemark Web 3.0 | WebGL Aquarium (fps) |
|---|---|---|
| Mac | 3248, 3118, 3247 | 107.7, 108.5, 106.8 |
| Parallels | 2586, 2446, 2423 | 21.9, 28.2, 26.7 |
| UTM | 2182, 2174, 2780 | 25.0, 28.6, 28.1 |
| VMware Fusion | 2478, 2578, 2522 | 38.9, 40.6, 40.9 |
| OmacVM.app | no result (3 tries, before the fix) | 16.8, 24.1, 23.9 |

Notes:

- **Geekbench GPU in a VM: not available.** Geekbench 7's Linux ARM preview
  has no GPU test: `--gpu-list` lists nothing and `--gpu Vulkan` or
  `--gpu OpenCL` only prints the help. No VM offers OpenCL, and none offers
  Vulkan either (Fusion: `vulkaninfo` finds no driver; UTM's Vulkan is off in
  OmacVM's setup). Tried once in each VM.
- Basemark mixes GPU tests (WebGL, canvas, SVG) with JavaScript and page tests,
  so it is not a pure GPU number. Each result is public on Basemark's
  Powerboard; `browser-bench.py` prints its link.
- WebGL Aquarium on the Mac: 108 fps on a 120 Hz display, so close to the
  display's limit. The VMs are far below it.
- OmacVM.app: Basemark never finished in 3 tries (up to 15 minutes each). It stays
  in its Geometry Stress Test, Chrome's page at full CPU. OmacVM.app's test VM
  has 8 CPUs and 16 GB, the others 16 and 48. Cause and fix:
  [finding 23](../troubleshooting.md#23-app-chrome-hangs-in-basemark-web-30-the-screen-flickers).
  With the fix it finishes: 2157 in one run in the app's window (page
  1920x1200 at 2x, the other test VMs paused), not comparable with the table.
  The full-screen run for the table is still to do.
- Chrome must open on the built-in display's monitor: on Fusion it first
  opened on the external one (page 1920x1200, 60 Hz) and gave 41 to 43 fps and
  Basemark 2072 to 2596. Those runs are not in the table.

### OmacVM.app 2.9.0 release candidate (2026-10-05)

RC2 (gpu-2.9.0 at 5586df7) against the runtime of the released 2.8.0, on the
same MacBook, in turns (2.8.0, RC2, RC2, 2.8.0), benchmark lock held for each
session. A throwaway app VM (8 CPUs, 16 GB), its window on the built-in
display, not full screen; another test VM (about one core) kept running.
Median of 6 runs (Aquarium: the first run of each session is a warm-up and
left out), range in brackets.

| | 2.8.0 | 2.9.0 RC2 |
|---|---|---|
| glmark2 short set | 1,124 (1,113-1,138) | 2,856 (2,706-2,970) |
| WebGL Aquarium, 30,000 fish (fps) | 19.9 (19.4-21.0) | 19.0 (18.8-19.1) |
| Basemark Web 3.0 | 2,482 (2,224-2,748) | 2,669 (2,339-2,871) |
| QEMU CPU during the session | 106 % | 130 % |
| testufo on a virtual 120 Hz display, new frames a second | 88.8-90.6 | 116.6-119.6 |

The chart in the README shows RC2's Aquarium against the Mac's full-screen
numbers above, tagged "2.9.0 RC", because it is not taken the same way. RC2's
Basemark is not in the chart: in a window it came out above the other apps'
full-screen numbers, and that is not a fair comparison (the page size was not
recorded; see the 2157 run above). The release run in full screen, with the
VM alone, fills both.

## Fast network (OmacVM.app)

QEMU's user network (libslirp, the default) against the fast network (vmnet
through `omacvm-netd`, `omacvm enable fast-network`), same VM and same QEMU,
one after the other on the Mac mini M4 (macOS 27, 16 GB; VM 6 CPUs / 6 GB,
text mode, no other VM running), 2026-10-05. iperf3 20 s, single runs. CPU:
process CPU time over the run, 100% = one core; the fast network adds
`omacvm-netd`'s. Scripts: `measure-mini.sh` in the track notes (the same
tests as the MacBook measurement of 2026-10-04).

| Test | User network (slirp) | Fast network (vmnet) |
|---|---|---|
| VM → Mac, 1 stream | 3.0 Gbit/s, QEMU 189% | **7.2 Gbit/s**, QEMU 158% + netd 105% |
| VM → Mac, 4 streams | 3.1 Gbit/s, 190% | **6.7 Gbit/s**, 167% + 106% |
| Mac → VM, 1 stream | **12.2 Gbit/s**, 174% | 9.5 Gbit/s, 125% + 57% |
| Mac → VM, 4 streams | **19.6 Gbit/s**, 279% | 8.6 Gbit/s, 171% + 64% |
| Mac connects in, Mac → VM, 4 streams | **19.1 Gbit/s** (port forward) | 8.6 Gbit/s (the VM's own address) |
| Mac connects in, VM → Mac, 4 streams | 3.0 Gbit/s | **6.7 Gbit/s** |
| CPU per Gbit/s, VM → Mac | 0.63 cores | **0.37 cores** |
| TCP connect VM → Mac, median (min..max) | 0.13 ms (0.11..0.17) | 0.17 ms (0.13..0.24) |
| Small HTTP request VM → Mac, median | 0.34 ms | 0.47 ms |
| ping VM → Mac | 0.19 ms | 0.35 ms |
| TCP connect to 1.1.1.1, median | 3.8 ms | 3.2 ms |
| IPv6 to the internet | works (NAT) | works (vmnet's NAT66) |
| Idle CPU | QEMU 3% | QEMU 2%, netd 0% |

- The fast network more than doubles VM → Mac, slirp's weak side (one QEMU
  thread does all of TCP/IP), at 40% less CPU per Gbit/s. Mac → VM is slower
  than slirp on this Mac but still about 9 Gbit/s, about where Parallels' own
  vmnet network was on the MacBook (7.7 to 8.7 Gbit/s). Internet speed does
  not change: the link is the limit on both.
- The MacBook measurement of the user network (busier Mac, other VMs
  running) was slower and less steady: VM → Mac 1.7 Gbit/s, Mac → VM 3.3 to
  6.7, connect latency 4.5 ms median with spikes to 33 ms. The fast network
  is not measured on the MacBook yet (its service needs an administrator's
  password).
- A bigger MTU (9000 on the vmnet interface and the VM) changed nothing
  (7.5 / 9.6 Gbit/s): the Mac's side of the network stays at 1500.
- A QEMU hub between the network card and vmnet (to swap networks while the
  VM runs) cost a quarter of VM → Mac: 7.1 → 5.3 Gbit/s, Mac → VM unchanged
  (A/B on the mini, same VM headless, iperf3 10 s, single runs, no bench lock).
  The fallback therefore plugs in a second card instead. With it, in the
  app (display on, a UTM VM running beside it): 6.9 / 6.3 Gbit/s VM → Mac,
  9.5 / 8.8 Mac → VM (1 / 4 streams).

## Graphics: Automatic (2026-10-05)

What OmacVM.app's Graphics setting picks when it is Automatic
([ADR 0035](../adr/0035-graphics-setting.md)). With Vulkan on, the VM gets the
Venus device next to virgl; the question was whether a Vulkan path is faster
for the work people do: OpenGL apps through Zink (GL on Vulkan), Chrome's
WebGL through ANGLE on Vulkan, and Vulkan apps themselves. The Venus device
itself costs OpenGL nothing (MacBook, locked ABBA, gpu-next: glmark2 2,816 vs
2,898, Aquarium 20.0 vs 19.9 fps).

**macOS 15 (MacBook Pro M4 Max, Venus on MoltenVK 1.4.2).** One test VM, 8
CPUs and 16 GB, headless, the 3.0.0 runtime, under the bench lock, median of 3.
One test Mesa (26.2.4 with OmacVM's five patches) for virgl and Zink:

| | virgl (OpenGL) | Vulkan path |
|---|---|---|
| glmark2 2023.01, quick set, full screen | 3,780 (Arch's Mesa 26.2.3: 3,731) | Zink on Venus: OpenGL ES 2.0 only, every scene crashes |
| WebGL Aquarium 30k, Chrome 154 | 19.4 fps (ANGLE on GL, Wayland) | ANGLE on Vulkan: Chrome's GPU process does not start (ES 2.0 only, Chrome needs 3.0): no WebGL |
| Basemark Web 3.0, WebGL 2 pages | not measured (Basemark not run; the WebGL 2 page rows came out empty, a harness bug, see below) | no WebGL on either Vulkan path |
| vkmark, full screen, Vulkan apps | - | 387 (software present, see below) |

MoltenVK has no `VK_EXT_provoking_vertex`, transform feedback or geometry
shaders, so ANGLE and Zink stop at ES 2.0: on macOS 15 a Vulkan path cannot
carry OpenGL or WebGL at all, so the choice does not need the WebGL 2 number.
The empty WebGL 2 rows: the A/B harness ran the page's runner from `/root` as
the desktop user, who cannot read it, and dropped the error (fixed in the
harness; one run after the fix on the same kind of VM gave a full result on
OpenGL, unlocked, not used here).

**macOS 26 and newer (Mac mini M4, macOS 27, KosmicKrisp),** from the
kosmickrisp track (unlocked, median of 3 unless said; tracks/kosmickrisp.md).
These rows compare drivers and paths one by one; none of them compares a VM
with Vulkan on against the same VM with OpenGL only, and what the Venus device
costs the OpenGL desktop was measured on macOS 15 only (above: nothing):

| | OpenGL path | Vulkan path |
|---|---|---|
| vkmark 800x600 | - | KosmicKrisp 840 vs MoltenVK 650 on the same Mac (+29 %) |
| glmark2-es2 off-screen, one guest Mesa | virgl 592 | Zink on KosmicKrisp 558 (ES 2.0 only) |
| WebGL Aquarium 30k, Chrome 154 | 21.9 fps (ANGLE on GL) | 26.9 fps (ANGLE on Vulkan: X11, Chrome flags and a test Mesa with a patch; no Graphics setting gives this) |
| Basemark Web 3.0 | 1,654 | 1,511 (ANGLE on Vulkan) |

The 3.0.0 build on that mini (2026-10-05, unlocked) picked Vulkan on
KosmicKrisp under Automatic and gave the same picture: Aquarium 30k 18.9 fps
on ANGLE on GL against 26.9-27.0 on ANGLE on Vulkan (X11, flags); vkpeak
fp32 3.9 TFLOPS (MacBook M4 Max on MoltenVK: 15.8).

KosmicKrisp also has `nullDescriptor`, `robustBufferAccess2` and `logicOp`,
which MoltenVK lacks. With Vulkan on, OpenGL stays on virgl (Zink is slower
and ES 2.0 only) and Chrome keeps ANGLE on GL, so on macOS 26 and newer
Vulkan adds Vulkan apps on the better driver and changes nothing else.

**What Vulkan on costs the desktop on KosmicKrisp (2026-10-06).** The same
VM started twice, once with OpenGL only and once with Vulkan on (the Venus
device, a 4 GB host memory window and `omacvm.vkwindows=1`, as the 3.0.1
app starts it), in full screen at 5120x2880 on the Mac mini M4 (macOS 27,
the 3.0.0 runtime, mini lock held, no other VM; 6 CPUs, 8 GB):

| Mac mini M4, macOS 27 | OpenGL only | Vulkan on |
|---|---|---|
| glmark2 2023.01, full screen, 3 s scenes (median of 3) | 847 | 841 (99 %) |
| WebGL Aquarium 30k, Chrome 154, full screen (median of 3) | 18.9 fps | 18.8 fps (99 %) |
| GPU throughput page, Chrome (wall time): fill / ALU | 136.5 Gpixels/s / 3,720 GFLOPS | 136.5 / 3,725 |
| QEMU at the idle desktop: CPU / memory | 1.1 % / 3.6 GB | 1.0 % / 4.2 GB |
| Contexts lost, Mac GPU restarts | 0, 0 | 0, 0 |
| vkcube, vkmark full screen | - | runs through the GPU path; 310 |

Chrome stays on ANGLE on GL (virgl) with Vulkan on, and OpenGL apps stay on
virgl, so the desktop draws the same. QEMU's memory differed by less than
1 GB either way (after the runs: 3.8 GB with OpenGL, 3.4 GB with Vulkan).

MacBook Air M2 (8 GB, macOS 26.6, KosmicKrisp): a 4 GB VM in full screen on
the built-in display (2940x1846 in both modes), the 3.0.1 runtime with the
small PCI window (1 GB host memory window), Vulkan first, then OpenGL:

| MacBook Air M2, macOS 26 | OpenGL only | Vulkan on |
|---|---|---|
| glmark2 2023.01, full screen, 3 s scenes (median of 3) | 1,846 | 1,876 (102 %) |
| WebGL Aquarium 30k, Chrome 155 (1 run) | 11.7 fps | 14.8 fps |
| QEMU at the idle desktop: CPU / memory | 10.8 % / 3.5 GB | 10.5 % / 3.8 GB |
| The Mac's free memory after the runs | 62 % | 43 % (no new swap) |
| Contexts lost, Mac GPU restarts | 0, 0 | 0, 0 |
| vkcube, vkmark full screen | - | runs through the GPU path; 803 |

An earlier pass on the Air had a different guest resolution per boot, so its
OpenGL/Vulkan pair is left out (Vulkan on worked the same way there: vkmark
820, nothing lost). Why Aquarium came out faster with Vulkan on was not
looked into; it is one run each.

**Automatic = Vulkan on macOS 26 and newer from 3.0.2** (KosmicKrisp in the
app; OpenGL on macOS 15 and before, where Venus runs on MoltenVK). 3.0.0 and
3.0.1 kept Automatic on OpenGL until this A/B. One constant turns it back
(`Graphics.autoVulkan`, `GRAPHICS_AUTO_VULKAN`).

Vulkan windows: a Venus image handed to Hyprland as a dma-buf cannot be
imported by its OpenGL context on the Mac. Until 3.0.0 RC that import ended
Hyprland's context (black desktop), so app VMs presented through a CPU copy
(Mesa's software WSI, `MESA_VK_WSI_DEBUG=sw`). Now the Mac fills a GL texture
from the image (virgl-set-type-without-egl.patch) and Vulkan apps keep Mesa's
normal present path. vkmark (7 scenes x 5 s, mailbox, M4 Max, macOS 15,
MoltenVK, bench lock, median of 3, test window hidden):

| | normal WSI (now) | software WSI (before) |
|---|---|---|
| window 800x600 | 865 | 336 |
| full screen 2592x1458 | 678 | 65 |

These count the app's frames. The frames the screen shows are capped by the
display's refresh; that was not measured here (the hidden test window paces
Hyprland at ~12 Hz for both paths). With vkmark's headless output, no window:
4,700-5,200.

3.0.0 sent `omacvm.vkwindows=1` only with MoltenVK (macOS 15); with
KosmicKrisp Vulkan windows went through the CPU copy (vkmark full screen on
a Mac mini M4 at 5K, macOS 27: 203; another run, not the table's scene set).
3.0.1 sends it with KosmicKrisp too. Mac mini M4, macOS 27, KosmicKrisp,
Mesa's normal WSI, 2026-10-06: vkcube windowed and full screen at 5K; then
10 minutes of vkmark (shading and texture, 20 s each) in turns full screen
at 5120x2880 (8 runs: 252-272) and in a 1280x800 window (7 runs:
1279-1777), with vkcube in a window the whole time. No context lost, the
desktop answered and showed at the end, QEMU's memory stayed at 2.7-2.9 GB.

## GPU compute with Venus (2026-10-04)

OmacVM.app with Venus only (the other routes have no Vulkan or OpenCL in the
VM, see above). The VM runs OmacVM's guest Mesa (ADR 0022). Two Macs:

- **MacBook Pro M4 Max**, macOS 15.7.4, Venus on MoltenVK 1.4.2. Test VM with
  8 CPUs and 16 GB, in a window. Locked batches under the bench lock (other
  test VMs paused; one VM of another track could not be paused and ran
  beside it): WebGPU from batch L2, Geekbench and saxpy from L2/L3 a few
  minutes later, ffmpeg from the earlier batch L1 (guest Mesa before the
  global-loads and OPAQUE_FD patches; two such VMs ran beside it).
- **Mac mini M4** (10 GPU cores), macOS 27.0, Venus on KosmicKrisp. Test VM
  with 6 CPUs and 8 GB. No bench lock (another agent's builds ran on the mini),
  so these are indications.

WebGPU matmul is `browser-bench.py webgpu` (f32, 2048x2048, GFLOPS, checked
against the CPU). In the VM Chromium runs from the "Chromium (WebGPU)" launcher
(Arch's Chromium 153; Google Chrome 154 gave the same adapter with the same
flags, `omacvm-chrome-webgpu` passes them to it); the default Chromium gets
no hardware adapter in a VM.
Median of 3; the Mac's own number in brackets where the same batch has one.

| | M4 Max, MoltenVK | M4 mini, KosmicKrisp |
|---|---|---|
| WebGPU matmul, Chromium in the VM | 5071 (Mac Chrome 6038: 84 %) | 1148 (mini Chrome 1614: 71 %) |
| WebGPU matmul, Firefox 157 in the VM | 665 (Mac Firefox 319: 208 %) | 167 |
| WebGPU computeBoids, Firefox / Chromium (fps) | 59.9 / 60 (36.4 in the locked batch) | 59.9 / 60.0 |
| Geekbench 7 GPU OpenCL (single run) | 42486 (Mac OpenCL 95380: 45 %) | 18973 (mini OpenCL 35240: 54 %, earlier that day) |
| OpenCL saxpy, 16M floats (GB/s) | 387-444 | 101 |
| ffmpeg 4K `nlmeans`, OpenCL vs the VM's CPUs (fps) | 1.07 vs 0.33 (8 CPUs) | 1.13 vs 0.37 (6 CPUs) |

Each run, M4 Max batch:

| | WebGPU matmul 2048 (GFLOPS) |
|---|---|
| Mac, Chrome 154 | 6434, 6038, 4600 |
| VM, Chromium 153 (launcher) | 5144, 5071, 5018 |
| Mac, Firefox 157 | 285, 333, 319 |
| VM, Firefox 157 | 667, 650, 665 |

Notes:

- Firefox in the VM beats Firefox on the Mac: on the Mac Firefox's WebGPU
  (wgpu) writes Metal shaders itself, in the VM it writes SPIR-V and the
  Vulkan driver translates it, and that translation is faster for this kernel.
  Chrome (Dawn) is fast on both.
- The Mac's GPU speed moved a lot between batches (Chrome 2048: 3885 in an
  earlier locked batch, 6188 in an unlocked one): compare within a row.
- Geekbench 7 runs every OpenCL workload and all pass validation. The VM loses
  most where a workload launches many small kernels: each launch crosses the
  Venus ring (Background Blur 18301 vs 61273, Face Tracking 24606 vs 91731).
- Results: [VM](https://browser.geekbench.com/v7/gpu/252731),
  [Mac](https://browser.geekbench.com/v7/gpu/252722),
  [mini VM](https://browser.geekbench.com/v7/gpu/252849).
- clpeak sizes its work by the number of compute units, and Zink reports one
  (Vulkan has no such query): fp32 1.5 TFLOPS as reported, 8.9 with the count
  forced to 40 (test only), Mac OpenCL 15.6-16.1.
- ffmpeg's `nlmeans_opencl` runs many small kernels, and the mini and the
  M4 Max are about equal: most likely the VM's latency per launch decides it,
  not the GPU (not measured per launch).
- Stability: 63 rounds over 36 minutes on the M4 Max and 24 rounds over 15
  minutes on the mini (OpenCL, Firefox and Chromium WebGPU, ffmpeg OpenCL),
  no failure.
