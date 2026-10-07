# Final round: GPU and idle power, Mac vs the four VMs

One session on one quiet Mac: macOS itself (the baseline, 100 %), then
OmacVM.app, UTM, VMware Fusion and Parallels, one at a time. About 35 minutes
of GPU tests and 11 minutes of idle power per system.

## What runs

| Test | What it measures | Mac | VMs | Time per system |
|---|---|---|---|---|
| GPU throughput page ([`../gpu-throughput`](../gpu-throughput)) | pure GPU work in WebGL 2: a ray-march shader (headline), an ALU chain, blended fill. Offscreen at 1920x1080, so window size and vsync don't count. Each session runs it twice: GPU timer, then wall time (see below) | ✓ | ✓ | 4 min (3 sessions) |
| vkpeak ([`../vkpeak`](../vkpeak)) | Vulkan compute peak, fp32 / fp16 / int32 | ✓ (vkpeak's own MoltenVK 1.4.1) | a GPU Vulkan device only (OmacVM.app with Venus); else "not available" | 3 min |
| Geekbench 7 GPU | GPU compute, OpenCL and Vulkan | ✓ OpenCL and Metal | OpenCL (rusticl) and Vulkan (Venus) on a real GPU device only, never PoCL, llvmpipe or lavapipe | 6 min |
| vkmark | Vulkan drawing, score | ✗ no macOS version | a GPU Vulkan device only | 3 min |
| glmark2 2023.01 (one version everywhere) | OpenGL ES in the VM, score | ✗ no macOS version | ✓ | 5 min |
| WebGL Aquarium, 30,000 fish | 3D in the browser, fps | ✓ | ✓ | 2 min |
| Basemark Web 3.0 | browser graphics, with some JavaScript | ✓ | ✓ | 8 to 15 min |
| Idle power (`SystemPowerIn`) | the whole Mac, desktop idle | ✓ | ✓ | 11 min |

Each test runs 3 times; the table and chart use the median.

Geekbench is version 7 (the 2026-10-03 round's and OmacVM.app's 2026-10-04
GPU number): 6 and 7 scores don't compare. The Mac has no Vulkan in
Geekbench, so a VM's Vulkan score is shown against the Mac's Metal score, and
the chart says so.

### Timing the throughput page: one method per row

The page times a frame two ways ([index.html](../gpu-throughput/index.html)):

- **GPU timer** (`method=timer`, frames of 40 ms): GPU time from
  `EXT_disjoint_timer_query_webgl2`. The cleanest number where the browser
  has timer queries.
- **Wall time, long frames** (`method=wall`, frames of at least 80 ms): the
  clock around each draw. The waits around a frame (and a VM's sync path) add
  a fixed few ms; the page measures that cost and makes the frames longer
  until it is under 2 % of a frame.

Each session runs both. `summarize.py` then picks one method per row, the
same for every system: the GPU timer if every system has one and it holds up
(within -2 % and +10 % of the same system's long-frame wall time), else wall
time for everyone. The table, the JSON (`methods`, `validation`) and the
chart name the method. Never a timer number next to a wall-time number.

## The benchmark VMs

The round uses only VMs made for it, one per hypervisor, named:

| Hypervisor | VM name |
|---|---|
| OmacVM.app (the 2.9.0 release; a 3.0.0 RC as a second run if ready) | `Bench OmacVM` |
| UTM | `Bench UTM` |
| VMware Fusion | `Bench Fusion` |
| Parallels Desktop | `Bench Parallels` |

**Never** the user's own VMs: Parallels' "Omarchy" (production) and
"Omarchy ARM", OmacVM.app's "OmacVM Test", UTM's "Windows" on the Mac mini,
or anything on the mini. `vm.sh` refuses any name that does not start with
`Bench `, and refuses unless that VM is the one VM running on its
hypervisor (and, for OmacVM.app, the SSH port is that VM's).

Each VM: 16 CPUs, 48 GB, Google Chrome installed (pacman/AUR, or
`src/bench/install-chrome.sh`: fine here, these are our VMs), the screensaver
and lock off (`omacvm enable no-idle-lock --vm NAME`), the same dark wallpaper
as the Mac (the built-in display dims per zone, so a bright desktop draws
more power). On Fusion, `--ignore-gpu-blocklist` in `/etc/chrome-flags.conf`,
or Chrome draws in software and the page says "software renderer (check
Chrome flags)".

## Before the round: prepare each VM

Hours or at least a few minutes before, not in the round:

```bash
F=tests/bench/final-round
$F/vm.sh app       --vm "Bench OmacVM"    root@127.0.0.1:<port> --prepare
$F/vm.sh utm       --vm "Bench UTM"       root@<ip> --prepare
$F/vm.sh fusion    --vm "Bench Fusion"    root@<ip> --prepare
$F/vm.sh parallels --vm "Bench Parallels" root@<ip> --prepare
```

`--prepare` runs a full `pacman -Syu` in that VM, installs glmark2, vkmark,
vulkan-tools, clinfo, opencl-mesa, mesa-utils and vkpeak's build tools,
builds vkpeak and fetches Geekbench into the desktop user's
`~/.cache/omacvm-bench`, and records the versions (Mesa, OmacVM's own Mesa,
glmark2, vkmark, Chrome, kernel) in `/opt/omacvm-final-round/state`. If the
kernel was updated it says so: reboot the VM and prepare again. In the round,
`vm.sh` runs no pacman at all and refuses a VM whose versions changed since
(Mesa stays fixed for the whole round). Build heat is gone before the
numbers: give the Mac 10 minutes after the last prepare.

For OmacVM.app's Vulkan rows: the VM's Vulkan setting on and Mesa 26.2.4 or
newer in the guest (Arch Linux ARM's 26.2.3 fails, see
`src/app/guest/venus/install.sh`). Without it the rows say "not available"
with the reason.

## The Mac, before you start

All of it, or the numbers don't compare (the rules of the 2026-10-03/04
rounds, [docs/benchmarks](../../../docs/benchmarks/README.md#the-setup)). The
scripts check what they can and refuse otherwise:

- Charger connected, battery **not charging** (full, or held by macOS).
  Checked: `ExternalConnected = Yes`, `IsCharging = No`.
- Low Power Mode off, and the energy mode (`pmset -g | grep powermode`) left
  as it is for the whole round. Checked: the first script writes the mode to
  `round-state` next to the results and refuses later if it changed.
- Thermal state nominal. Checked (macOS's own state, and `pmset -g therm` is
  recorded).
- Nothing else running: no other VM app, **Parallels' service included**
  (`prl_disp_service`, `prl_naptd`; `omacvm apply` restarts it, so quit it
  again), Fusion's vmnet daemons, UTM, no second VM of the app under test,
  no agents, no test VMs, no bench lock held. Checked.
- External monitor unplugged, built-in display only, brightness 50 % (set by
  you; the scripts only read and record it). Automatic brightness off.
- Each VM in full screen on the built-in display. Checked: the guest at least
  3000 px wide, and Chrome's page 1728x1080 at 2x (on the Mac too) before the
  browser tests.
- The same Google Chrome version on the Mac and in every VM. Recorded;
  `summarize.py` warns when they differ.
- Order: macOS first, then OmacVM.app, UTM, VMware Fusion, Parallels. Quit
  each VM app (and its services) before the next.
- For idle power: start the script and don't touch the Mac (and don't poll it)
  until it prints the result.

`FINAL_ROUND_ALLOW_BUSY=1` runs anyway and marks every line "preliminary"
with the reasons; `summarize.py` leaves those lines out.

## Run it: one command

`round.sh` runs the whole round in the order below, inside a time budget
(default 3 hours), and writes the table and the chart at the end:

```bash
RC2_APP=~/Applications/"OmacVM 3.0.0 RC2.app" \
  tests/bench/final-round/round.sh --dir ~/bench/final-$(date +%Y%m%d)
```

- Order: macOS, OmacVM.app (`APP_291`), a second app build (`RC2_APP`,
  Vulkan rows: vkpeak, Geekbench, vkmark; its OpenGL rows only with time to
  spare), UTM, VMware Fusion, Parallels. Each VM: started, put in full screen
  on the built-in display (View > Full Screen when it does not start that
  way), checked at 3000 px or more, the Mac's wallpaper and no
  notifications, the GPU tests 3 times, idle power, stopped, its app quit.
- Budget: GPU steps first. The idle windows get one length for every system
  (5 to 10 minutes, from the budget); when the round runs late the idle rows
  of the last systems are left out (noted), never shortened. glmark2 runs its
  scenes at 5 s (`GLMARK2_DURATION`, the same in every VM).
- Before each step the preflight must pass (charger, not charging, thermal,
  quiet Mac, built-in display only); it waits up to 10 minutes, else the step
  is noted "refused" with the reason and the round goes on.
- It waits for 10 idle minutes first if someone used the Mac, holds the
  bench lock for the whole round, and stops if a VM that is not a "Bench"
  VM runs (it never touches the user's VMs).
- Resumable: the same command again skips what is done and retries what
  failed or was refused. Outputs in `--dir`: one `<step>.jsonl` per step,
  `round.log`, `steps.state`, `screen-<vm>.png` (the guest's screen at the
  start), `table.md`, `chart.json`, `gpu.svg`, `gpu.png`.
- `--plan` shows the steps and times, `--dry-run` walks the round with a
  simulated clock (nothing starts), `--fullscreen VM` checks one VM's full
  screen, `--summary` redraws the table and chart, `--prepare-rc2` (before
  the round) makes the RC2's Bench VM: a clone of "Bench OmacVM" with the
  Graphics setting on Vulkan and the RC2's Venus driver.

## Run it step by step

From a clone of OmacVM on the Mac (`~/.omacvm` or your checkout):

```bash
F=tests/bench/final-round; R=~/bench/final-$(date +%Y%m%d); mkdir -p $R

# 1. macOS
$F/mac.sh $R/mac.jsonl
$F/idle-power.sh mac --desktop "dark wallpaper" $R/mac.jsonl   # Terminal minimised

# 2. each VM, alone, in full screen; SSH as root with ~/.ssh/omacvm
OMACVM_APP=~/Applications/OmacVM.app \
$F/vm.sh app --vm "Bench OmacVM" root@127.0.0.1:<port> $R/app.jsonl
$F/idle-power.sh app --ssh root@127.0.0.1:<port> $R/app.jsonl
$F/vm.sh utm --vm "Bench UTM" root@<ip> $R/utm.jsonl
$F/idle-power.sh utm --ssh root@<ip> $R/utm.jsonl
$F/vm.sh fusion --vm "Bench Fusion" root@<ip> $R/fusion.jsonl
$F/idle-power.sh fusion --ssh root@<ip> $R/fusion.jsonl
$F/vm.sh parallels --vm "Bench Parallels" root@<ip> $R/parallels.jsonl
$F/idle-power.sh parallels --ssh root@<ip> $R/parallels.jsonl

# 3. table and chart (Geekbench's scores are read from its result pages in a
#    visible Chrome on the Mac, after the round)
$F/summarize.py $R/*.jsonl --fetch-geekbench --json $R/chart.json
src/bench/chart.py --panel gpu $R/chart.json $R/gpu.svg \
  "MacBook Pro M4 Max · macOS 15.7 · Google Chrome 154 · October 2026"
```

`OMACVM_APP` names the app build under test, so the lines record its version
(not whatever is in `~/Applications`).

The chart's rows: GPU throughput (headline, with the method), GPU compute
(vkpeak fp32, Geekbench OpenCL, Geekbench Vulkan against the Mac's Metal),
glmark2 and vkmark (VMs only: scores, bars against the best VM), Basemark.
`--aquarium` adds WebGL Aquarium as an optional row. The user sees the draft
before it becomes `docs/images/benchmarks.svg`.

## After the round: clean up

```bash
$F/vm.sh app --vm "Bench OmacVM" root@127.0.0.1:<port> --cleanup     # and the other three
rm -rf ~/.cache/omacvm-bench                                          # on the Mac: vkpeak's download
```

`--cleanup` removes `/opt/omacvm-final-round` and `~/.cache/omacvm-bench`
in the VM and lists the packages `--prepare` added; `--cleanup --packages`
also removes them (`pacman -Rns`).

## What each line holds

`{"target", "test", "preliminary", "preliminary_why", "result", "mac_state", "quiet", "at"}`:

- `result`: the test's own JSON. VM lines add `vm` (kernel, CPUs, memory,
  monitors and their widths, GL renderer, Vulkan devices, Chrome, Mesa,
  glmark2, vkmark, when prepared), `hypervisor` (name and version) and
  `vm_name`.
- `mac_state`: Mac model, macOS version, display mode, brightness (read only),
  charging, charger, battery %, energy mode, thermal state.
- `quiet`: other hypervisor processes, VMs of the target, Claude processes,
  the bench lock, load.

`summarize.py` leaves out of the medians, and lists apart with the reason:
lines marked preliminary, from a busy Mac, charging, on battery, in Low Power
Mode, not at thermal state nominal, after the energy mode changed, from a
guest narrower than 3000 px or with Chrome's page other than 1728x1080 at 2x;
page results that are unstable (CV 3 % or more), not linear at half and double
the work, fell back from the timer to wall time, ran at a frame target other
than 40 ms (timer), or whose fixed cost was 2 % of a frame or more (wall).
`--include-preliminary` keeps the lines for a draft; the JSON and the chart
then say "preliminary".

## Times

| Step | About |
|---|---|
| vm.sh --prepare | 5 to 10 min per VM (update, vkpeak build), before the round |
| mac.sh | 20 to 25 min (Basemark is most of it) |
| vm.sh | 30 to 35 min |
| idle-power.sh | 11 min (1 min settle, 10 min window) |
