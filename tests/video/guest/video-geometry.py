#!/usr/bin/env python3
"""video-geometry.py: where a hardware-decoded video's rows and columns land on the VM's screen, per app.
Run in an OmacVM.app VM as the desktop user in its Hyprland session (tests/video/video-geometry.sh does it).

  video-geometry.py clips DIR [WxH ...]        test-card clips (FFmpeg): H.264, HEVC, VP9 (8 and 10-bit), AV1
  video-geometry.py output [WxH]               Virtual-1 at that size, scale 1 (none: the mode display-sync set)
  video-geometry.py run APP MODE --clips DIR [--only NAME,...] [--chrome PATH]   one JSON line per clip
  video-geometry.py check FILE...              a verdict per line; exit 1 when one is wrong

The card: grey ground, white lines 2 rows high every 64 rows and 2 columns wide every 128 columns, the last 16 rows
8 blue then 8 red, the same for the last 16 columns. Shown exactly, the red band is 8 source rows and columns and
the lines sit where they are in the source (line ratio 1.0). Mesa rounds a VA-API surface's planes up to 16; an app
that samples them whole shows the band 8 + padding rows high (1080p: 16) and the picture squeezed (ratio 0.9926):
the strip OmacVM 3.2.10 and older showed below hardware-decoded video (ADR 0061).

APP: chrome (Google Chrome, VA-API through OmacVM's shim; --chrome PATH, flags from chrome-flags.conf plus
VIDEO_GEOMETRY_CHROME_FLAGS / VIDEO_GEOMETRY_CHROME_FEATURES), chromium (Arch's, V4L2 through omacvm-vdecd), firefox (VA-API), mpv
(--hwdec=vaapi, vo=gpu), mpvnext (vo=gpu-next), mpvsw (CPU decoding: the reference). MODE: fit (the output, aspect
kept) or 1to1 (the video's own size). Each line: decoder, rectangle, yratio/xratio (fitted line spacing over the
rectangle's), red_rows/red_cols (source rows/columns the red band covers), blue_rows/blue_cols, green pixels;
Chrome and Chromium: path, from the browser's log for that clip ("no ImageProcessor": the decoder's NV12 frames are
drawn as they are, as on Wayland with GL; "ImageProcessor": converted to RGB first).

check: exact = red 7.4 to 8.5 rows and columns (the band's first row blends) and the lines within half a source row
or column of their place (ratio 1 +- 0.5 / size, at least +- 0.001; a 1080p squeeze is 0.0074). A decoder surface
at the stream's coded size (H.264 when width or height is not a multiple of 16, HEVC when not a multiple of 8) must be
exact too: the app's EGL import says the picture's size (ADR 0063; 3.2.11 and older show the strip there). Known, not
counted as failures: Chromium's V4L2 decoder offers no HEVC; Chrome 154 stops answering below 360 rows on an M4 (it
decodes those on the CPU, and its libyuv crashes there on an M4; fixed in Chrome 155); an app not installed in the VM.
"""
import glob, http.server, importlib.util, json, os, re, shutil, signal, subprocess, sys, threading, time, urllib.request

here = os.path.dirname(os.path.abspath(__file__))


def arg(name, default):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


# ---- clips -----------------------------------------------------------------------------------------------------

ENC = {
    "h264": ("mp4", ["-c:v", "libx264", "-preset", "medium", "-profile:v", "high", "-pix_fmt", "yuv420p", "-g", "30",
                     "-crf", "8", "-movflags", "+faststart"]),
    "hevc": ("mp4", ["-c:v", "libx265", "-preset", "medium", "-pix_fmt", "yuv420p", "-tag:v", "hvc1",
                     "-x265-params", "log-level=error:keyint=30", "-crf", "8", "-movflags", "+faststart"]),
    "vp9": ("webm", ["-c:v", "libvpx-vp9", "-pix_fmt", "yuv420p", "-deadline", "good", "-cpu-used", "4",
                     "-row-mt", "1", "-b:v", "0", "-crf", "8", "-g", "30"]),
    "vp9p2": ("webm", ["-c:v", "libvpx-vp9", "-pix_fmt", "yuv420p10le", "-profile:v", "2", "-deadline", "good",
                       "-cpu-used", "4", "-row-mt", "1", "-b:v", "0", "-crf", "8", "-g", "30"]),
    "av1": ("mp4", ["-c:v", "libsvtav1", "-preset", "8", "-crf", "12", "-g", "30", "-pix_fmt", "yuv420p",
                    "-movflags", "+faststart"]),
}
SIZES = ["1920x1080", "1280x720", "640x360", "320x180", "854x480", "360x640", "1000x562", "1918x1078"]


def clips(out, sizes):
    os.makedirs(out, exist_ok=True)
    meta = []
    for s in sizes:
        w, h = map(int, s.split("x"))
        vf = ["drawbox=x=0:y=0:w=iw:h=ih:color=0x404040:t=fill"]
        vf += [f"drawbox=x=0:y={y}:w=iw:h=2:color=white:t=fill" for y in range(64, h - 39, 64)]
        vf += [f"drawbox=x={x}:y=0:w=2:h=ih:color=white:t=fill" for x in range(128, w - 39, 128)]
        vf += ["drawbox=x=0:y=ih-16:w=iw:h=8:color=blue:t=fill", "drawbox=x=0:y=ih-8:w=iw:h=8:color=red:t=fill",
               "drawbox=x=iw-16:y=0:w=8:h=ih:color=blue:t=fill", "drawbox=x=iw-8:y=0:w=8:h=ih:color=red:t=fill",
               "format=yuv444p", "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv"]
        for v, (ext, enc) in ENC.items():
            f = f"{v}-{s}.{ext}"
            if not os.path.exists(os.path.join(out, f)):
                r = subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                                    "-i", f"color=c=black:s={w}x{h}:r=30:d=4", "-vf", ",".join(vf), *enc, "-an",
                                    os.path.join(out, f)])
                if r.returncode:
                    print(f"clip {f}: FFmpeg failed (encoder missing?)", file=sys.stderr)
                    continue
            meta.append({"name": f"{v}-{s}", "file": f, "codec": "vp9" if v.startswith("vp9") else v, "w": w, "h": h})
    json.dump(meta, open(os.path.join(out, "geo.json"), "w"))
    print(f"{len(meta)} clips in {out}")


# ---- screenshot analysis ---------------------------------------------------------------------------------------

def grab():
    out = subprocess.run(["grim", "-t", "ppm", "-"], capture_output=True, check=True).stdout
    # P6\n<w> <h>\n255\n
    m = re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", out)
    w, h = int(m.group(1)), int(m.group(2))
    return w, h, out[m.end():]


def px(img, x, y):
    w, h, d = img
    o = (y * w + x) * 3
    return d[o], d[o + 1], d[o + 2]


def cls(p):
    r, g, b = p
    if r > 180 and g > 180 and b < 100:
        return "Y"          # page / player background (yellow)
    if r > 170 and g > 170 and b > 170:
        return "W"
    if r > 140 and g < 110 and b < 110:
        return "R"
    if b > 140 and r < 110 and g < 130:
        return "B"
    if g > r + 40 and g > b + 40:
        return "G"
    if abs(r - 64) < 45 and abs(g - 64) < 45 and abs(b - 64) < 45:
        return "."
    return "?"


def bbox(img, seed):
    """The video's rectangle: from a point inside it outwards along its row and column to the background."""
    w, h, _ = img
    sx, sy = seed
    if cls(px(img, sx, sy)) == "Y":
        return None
    x0 = x1 = sx
    y0 = y1 = sy
    while x0 > 0 and cls(px(img, x0 - 1, sy)) != "Y": x0 -= 1
    while x1 < w - 1 and cls(px(img, x1 + 1, sy)) != "Y": x1 += 1
    while y0 > 0 and cls(px(img, sx, y0 - 1)) != "Y": y0 -= 1
    while y1 < h - 1 and cls(px(img, sx, y1 + 1)) != "Y": y1 += 1
    return x0, y0, x1, y1


def runs(seq):
    out, i = [], 0
    while i < len(seq):
        j = i
        while j < len(seq) and seq[j] == seq[i]:
            j += 1
        out.append((seq[i], i, j))      # class, start, end (exclusive)
        i = j
    return out


def axis(classes, n_src, step, scale):
    """classes along the probe line inside the rectangle; source size n_src; lines every STEP (2 wide at k*STEP);
    scale = screen px per source row (rectangle / source size)."""
    rs = runs(classes)
    centres = [(s + e) / 2 for c, s, e in rs if c == "W" and e - s >= 1]
    src = [k * step + 1 for k in range(1, n_src) if k * step <= n_src - 40]
    res = {"lines": len(centres), "lines_expected": len(src)}
    if len(centres) == len(src) and len(src) >= 2:
        n = len(src)
        mx, my = sum(src) / n, sum(centres) / n
        a = sum((s - mx) * (c - my) for s, c in zip(src, centres)) / sum((s - mx) ** 2 for s in src)
        b = my - a * mx
        res["ratio"] = round(a / scale, 5)
        res["off"] = round(b / scale, 2)
    tail = [r for r in rs if r[0] != "?"]
    last = tail[-1] if tail else None
    res["red"] = round((last[2] - last[1]) / scale, 2) if last and last[0] == "R" else 0
    blue = [r for r in rs if r[0] == "B"]
    res["blue"] = round((blue[-1][2] - blue[-1][1]) / scale, 2) if blue else 0
    res["green"] = sum(1 for c in classes if c == "G")
    res["tail"] = "".join(f"{c}{e - s}" for c, s, e in rs[-4:])
    return res


def measure(W, H, topleft):
    for _ in range(3):
        subprocess.run(["omarchy-notification-dismiss"], capture_output=True)
    subprocess.run(["hyprctl", "dispatch", "movecursor", "4000", "4000"], capture_output=True)
    time.sleep(0.4)
    img = grab()
    seed = (min(W // 2, img[0] - 1), min(H // 2, img[1] - 1)) if topleft else (img[0] // 2, img[1] // 2)
    bb = bbox(img, seed)
    if not bb:
        return {"error": "no video on screen"}
    x0, y0, x1, y1 = bb
    rw, rh = x1 - x0 + 1, y1 - y0 + 1
    sx, sy = rw / W, rh / H
    xc = min(x1, x0 + int((64 + 0.5) * sx))           # between the first two vertical lines
    yc = min(y1, y0 + int((64 * (H // 128) + 32 + 0.5) * sy))   # mid-height, between two horizontal lines
    col = [cls(px(img, xc, y)) for y in range(y0, y1 + 1)]
    row = [cls(px(img, x, yc)) for x in range(x0, x1 + 1)]
    v, hz = axis(col, H, 64, sy), axis(row, W, 128, sx)
    return {"rect": [x0, y0, rw, rh], "screen": [img[0], img[1]],
            "yratio": v.get("ratio"), "yoff": v.get("off"), "red_rows": v["red"], "blue_rows": v["blue"],
            "xratio": hz.get("ratio"), "xoff": hz.get("off"), "red_cols": hz["red"], "blue_cols": hz["blue"],
            "green": v["green"] + hz["green"], "ylines": f'{v["lines"]}/{v["lines_expected"]}',
            "xlines": f'{hz["lines"]}/{hz["lines_expected"]}', "ytail": v["tail"], "xtail": hz["tail"]}


# ---- the page (browsers) ---------------------------------------------------------------------------------------

class Server:
    def __init__(self):
        self.clip = None
        self.mode = "1to1"
        self.size = (0, 0)
        srv = self

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path.startswith("/clip"):
                    path = srv.clip
                    size = os.path.getsize(path)
                    a, b = 0, size - 1
                    rng = self.headers.get("Range", "")
                    if rng.startswith("bytes="):
                        s, _, e = rng[6:].partition("-")
                        a = int(s) if s else 0
                        b = min(int(e), size - 1) if e else size - 1
                        self.send_response(206)
                        self.send_header("Content-Range", f"bytes {a}-{b}/{size}")
                    else:
                        self.send_response(200)
                    self.send_header("Content-Type", "video/webm" if path.endswith(".webm") else "video/mp4")
                    self.send_header("Accept-Ranges", "bytes")
                    self.send_header("Content-Length", str(b - a + 1))
                    self.end_headers()
                    with open(path, "rb") as f:
                        f.seek(a)
                        try:
                            self.wfile.write(f.read(b - a + 1))
                        except (BrokenPipeError, ConnectionResetError):
                            pass
                    return
                w, h = srv.size
                if srv.mode == "fit":
                    style = "display:block;width:100vw;height:100vh;object-fit:contain;background:#ff0"
                else:
                    style = f"display:block;width:{w}px;height:{h}px;background:#ff0"
                page = (f'<!doctype html><html style="background:#ff0"><body style="margin:0;background:#ff0;overflow:hidden">'
                            f'<video src="/clip?{int(time.time() * 1000)}" autoplay muted loop playsinline style="{style}">'
                            f'</video></body></html>').encode()
                self.send_response(200); self.send_header("Content-Type", "text/html")
                self.send_header("Cache-Control", "no-store"); self.end_headers()
                self.wfile.write(page)

            def log_message(self, *a):
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.httpd.server_port}/"


def flags_of(files):
    out = []
    for f in files:
        try:
            for line in open(os.path.expanduser(f)):
                line = line.strip()
                if line and not line.startswith("#"):
                    out += line.split()
        except OSError:
            pass
    return out


def kill(p):
    if p and p.poll() is None:
        try:
            os.killpg(p.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            p.wait(8)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()


def run():
    app, mode = sys.argv[2], sys.argv[3]
    clipdir = arg("--clips", "/tmp/video-geometry")
    only = [s for s in arg("--only", "").split(",") if s]
    out = open(arg("--out", "/dev/stdout"), "a")
    clips = json.load(open(os.path.join(clipdir, "geo.json")))
    if only:
        clips = [c for c in clips if any(s in c["name"] for s in only)]
    exe0 = {"chrome": arg("--chrome", "/opt/google/chrome/chrome"), "chromium": "/usr/bin/chromium",
            "firefox": "firefox"}.get(app, "mpv")
    if not shutil.which(exe0):
        print(json.dumps({"app": app, "mode": mode, "error": "not installed"}), file=out, flush=True)
        return
    srv = Server()
    srv.mode = mode
    proc, tab = None, None
    port = 9333
    log = f"/tmp/video-geometry-{app}.log"
    try:
        if app in ("chrome", "chromium"):
            spec = importlib.util.spec_from_file_location("vb", os.path.join(here, "video-bench.py"))
            vb = importlib.util.module_from_spec(spec); spec.loader.exec_module(vb)
            if app == "chrome":
                exe = [arg("--chrome", "/opt/google/chrome/chrome")]
                exe += flags_of(["/etc/chrome-flags.conf", "~/.config/chrome-flags.conf"])
                exe += os.environ.get("VIDEO_GEOMETRY_CHROME_FLAGS", "").split()
                # VIDEO_GEOMETRY_CHROME_FEATURES: more features into the last --enable-features (Chrome takes the last one)
                more = os.environ.get("VIDEO_GEOMETRY_CHROME_FEATURES", "")
                if more:
                    idx = [i for i, a in enumerate(exe) if a.startswith("--enable-features=")]
                    if idx:
                        exe[idx[-1]] += "," + more
                    else:
                        exe.append("--enable-features=" + more)
            else:
                exe = ["/usr/bin/chromium"]       # the launcher reads chromium-flags.conf itself
            ud = f"/tmp/video-geometry-ud-{app}"
            exe += [f"--remote-debugging-port={port}", f"--user-data-dir={ud}", "--no-first-run",
                    "--no-default-browser-check", "--password-store=basic", "--kiosk", "--autoplay-policy=no-user-gesture-required",
                    "--enable-logging=stderr", "--v=0", "--vmodule=video_decoder_pipeline=2,vaapi_video_decoder=2,gpu_init=1", "about:blank"]

            def start(mode_):
                p = subprocess.Popen(exe, stdout=open(log, mode_), stderr=subprocess.STDOUT, start_new_session=True)
                for _ in range(60):
                    time.sleep(0.5)
                    try:
                        tabs = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list"))
                        pages = [t for t in tabs if t.get("type") == "page"]
                        if pages:
                            t = vb.Tab(pages[0]["webSocketDebuggerUrl"])
                            t.call("Media.enable"); t.call("Page.enable")
                            return p, t
                    except OSError:
                        pass
                return p, None

            proc, tab = start("w")
            if not tab:
                print(json.dumps({"app": app, "error": "no DevTools"}), file=out, flush=True)
                return
        for c in clips:
            path = os.path.join(clipdir, c["file"])
            srv.clip, srv.size = path, (c["w"], c["h"])
            dec = ""
            res = {"app": app, "mode": mode, "clip": c["name"], "codec": c["codec"], "w": c["w"], "h": c["h"]}
            if tab:
                try:
                    tab.events = []
                    logpos = os.path.getsize(log) if os.path.exists(log) else 0
                    tab.call("Page.navigate", url=srv.url)
                    ok = False
                    for _ in range(40):
                        time.sleep(0.5)
                        t = tab.js("(() => { const v = document.querySelector('video'); return v ? v.currentTime : -1 })()")
                        if t and t > 1.2:
                            ok = True
                            break
                    time.sleep(1.0)
                    tab.call("Runtime.evaluate", expression="1")
                    props = {}
                    for e in tab.events:
                        if e["method"] == "Media.playerPropertiesChanged":
                            for p in e["params"]["properties"]:
                                props[p["name"]] = p["value"]
                    dec = props.get("kVideoDecoderName", "")
                    with open(log, errors="replace") as f:
                        f.seek(logpos)
                        new = f.read()
                    res["path"] = ("no ImageProcessor" if "No ImageProcessor needed" in new else
                                   "ImageProcessor" if "Initializing ImageProcessor" in new else "")
                    if not ok:
                        res["error"] = "not playing"
                except (OSError, TimeoutError, ValueError) as e:     # the browser stopped answering
                    res["error"] = f"browser stopped answering ({type(e).__name__}); started again"
                    kill(proc)
                    proc, tab = start("a")
                    print(json.dumps(res), file=out, flush=True)
                    if not tab:
                        return
                    continue
            elif app == "firefox":
                prof = "/tmp/video-geometry-ff"
                os.makedirs(prof, exist_ok=True)
                with open(os.path.join(prof, "user.js"), "w") as f:
                    for k, v in {"media.autoplay.default": 0, "media.autoplay.blocking_policy": 0,
                                 "browser.shell.checkDefaultBrowser": False, "browser.aboutwelcome.enabled": False,
                                 "datareporting.policy.dataSubmissionEnabled": False, "browser.startup.homepage_override.mstone": "ignore",
                                 "toolkit.telemetry.reportingpolicy.firstRun": False, "media.ffmpeg.vaapi.enabled": True,
                                 "browser.tabs.warnOnClose": False, "browser.sessionstore.resume_from_crash": False}.items():
                        f.write(f"user_pref({json.dumps(k)}, {json.dumps(v)});\n")
                env = dict(os.environ, MOZ_LOG="PlatformDecoderModule:5,FFmpegVideo:5,Dmabuf:5", MOZ_LOG_FILE="/tmp/video-geometry-moz.log")
                for g in glob.glob("/tmp/video-geometry-moz.log*"):
                    os.unlink(g)
                proc = subprocess.Popen(["firefox", "--kiosk", "--no-remote", "--profile", prof, srv.url],
                                        stdout=open(log, "a"), stderr=subprocess.STDOUT, env=env, start_new_session=True)
                time.sleep(float(arg("--wait", 9)))
                txt = ""
                for g in glob.glob("/tmp/video-geometry-moz.log*"):
                    txt += open(g, errors="replace").read()
                hw = re.findall(r"(?:VA-API|VAAPI|vaapi)[^\n]{0,80}", txt)
                dec = ("VA-API: " + hw[-1][:80]) if hw else "no VA-API line"
            elif app.startswith("mpv"):
                a = ["mpv", "--fs", "--no-config", "--ao=null", "--loop-file=inf", "--osc=no", "--osd-level=0",
                     "--background=color", "--background-color=#FFFF00", f"--log-file={log}"]
                a += {"mpv": ["--hwdec=vaapi", "--vo=gpu", "--gpu-api=opengl"],
                      "mpvnext": ["--hwdec=vaapi", "--vo=gpu-next", "--gpu-api=opengl"],
                      "mpvsw": ["--hwdec=no", "--vo=gpu", "--gpu-api=opengl"]}[app]
                if mode == "1to1":
                    a.append("--video-unscaled=yes")
                proc = subprocess.Popen(a + [path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                        start_new_session=True)
                time.sleep(4)
                txt = open(log, errors="replace").read() if os.path.exists(log) else ""
                m = re.findall(r"Using hardware decoding \((\w+)\)", txt)
                dec = ("hw " + m[-1]) if m else "software"
            res["decoder"] = dec
            try:
                res.update(measure(c["w"], c["h"], mode == "1to1" and not app.startswith("mpv")))
            except Exception as e:      # keep going with the other clips
                res["error"] = f"measure: {e}"
            if app == "firefox" or app.startswith("mpv"):
                kill(proc); proc = None
                time.sleep(1)
            print(json.dumps(res), file=out, flush=True)
    finally:
        kill(proc)




# ---- the output -------------------------------------------------------------------------------------------------

def output(size):
    """Virtual-1 at SIZE (a reduced-blanking 60 Hz modeline; virtio-gpu takes any), scale 1: larger than every clip,
    so lines 2 pixels wide stay visible when a video is fitted. Without SIZE: the mode display-sync set."""
    if size:
        w, h = map(int, size.split("x"))
        ht, vt = w + 160, h + 35
        mode = f"modeline {round(ht * vt * 60 / 1e6, 2)} {w} {w + 48} {w + 80} {ht} {h} {h + 3} {h + 9} {vt} +hsync -vsync"
    else:
        mode = "preferred"
        try:
            m = re.search(r'mode = "([^"]*)"', open(os.path.expandvars("$XDG_RUNTIME_DIR/omacvm/display-sync/Virtual-1.rule")).read())
            mode = m.group(1) if m else mode
        except OSError:
            pass
    subprocess.run(["hyprctl", "eval", f'hl.monitor({{ output = "Virtual-1", mode = "{mode}", position = "0x0", scale = "1" }})'],
                   capture_output=True)
    time.sleep(2)
    mons = json.loads(subprocess.run(["hyprctl", "-j", "monitors"], capture_output=True, text=True).stdout or "[]")
    print(" ".join(f'{m["name"]} {m["width"]}x{m["height"]}' for m in mons))


# ---- verdicts --------------------------------------------------------------------------------------------------

def known(d):
    """Why a row may be off without a fault here (None: it must be exact)."""
    app, codec, w, h = d.get("app", ""), d.get("codec", ""), d.get("w", 0), d.get("h", 0)
    if app == "chrome" and h < 360 and str(d.get("error", "")).startswith("browser stopped answering"):
        return "Chrome 154 stops on an M4 below 360 rows (CPU decoding, its libyuv; 3.2.10 too)"
    if app == "chromium" and codec in ("hevc", "av1") and d.get("error"):
        return "not offered by Chromium's V4L2 decoder"
    if app in ("chrome", "chromium") and d.get("error") == "not playing" and codec == "av1":
        return "AV1 not decoded here"
    if d.get("error") == "not installed":
        return "not installed in this VM"
    return None


def check():
    bad = 0
    for f in sys.argv[2:]:
        for l in open(f):
            if not l.startswith("{"):
                continue
            d = json.loads(l)
            yr, xr, rr, rc = d.get("yratio"), d.get("xratio"), d.get("red_rows"), d.get("red_cols")
            ty, tx = max(0.001, 0.5 / max(d.get("h") or 1, 1)), max(0.001, 0.5 / max(d.get("w") or 1, 1))
            exact = not d.get("error") and all(v is not None for v in (yr, xr, rr, rc)) and abs(yr - 1) <= ty \
                and abs(xr - 1) <= tx and 7.4 <= rr <= 8.5 and 7.4 <= rc <= 8.5
            why = None if exact else known(d)
            verdict = "exact" if exact else (f"known: {why}" if why else "WRONG")
            bad += verdict == "WRONG"
            path = f' [{d["path"]}]' if d.get("path") else ""
            print(f'{d.get("app",""):8} {d.get("mode",""):5} {d.get("clip",""):16} {str(d.get("decoder",""))[:20]:20} '
                  f'red {rr}/{rc} ratio {yr}/{xr} {d.get("error","")}{path}: {verdict}')
    print(f"video-geometry: {bad} wrong")
    return 1 if bad else 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "clips" and len(sys.argv) > 2:
        clips(sys.argv[2], sys.argv[3:] or SIZES)
    elif cmd == "output":
        output(sys.argv[2] if len(sys.argv) > 2 else "")
    elif cmd == "run" and len(sys.argv) > 3:
        run()
    elif cmd == "check":
        sys.exit(check())
    else:
        print(__doc__.split("\n\n")[1])
        sys.exit(2)
