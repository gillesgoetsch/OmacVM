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
| Geekbench 7 GPU | GPU compute | ✓ (Metal, OpenCL) | OmacVM.app only, see below |
| glmark2 | OpenGL ES in the VM, absolute score | ✗ no macOS build | ✓ |

**GPU compute runs only in OmacVM.app, and not released yet.** Geekbench's
GPU test needs Vulkan or OpenCL. Parallels, UTM and VMware Fusion offer
neither to a Linux guest, so `bench.sh` records "not available in this VM"
there. OmacVM.app's coming Vulkan path (Venus on MoltenVK, OpenCL through
rusticl) runs it: 45 % of the Mac, see the chart notes below.

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
| No screensaver | Omarchy's screensaver and lock off: `omacvm disable idle-lock --vm NAME`. It can start in the middle of a run otherwise |
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
