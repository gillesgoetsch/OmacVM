#!/usr/bin/env python3
"""YouTube 4K in Firefox: which decoder plays it, how many frames it drops.

  firefox-video-bench.py [--port 9222] [--video ID] [--seconds 60] [--log FILE]

Firefox must run with --remote-debugging-port (WebDriver BiDi) and, for the
decoder name, with MOZ_LOG=FFmpegVideo:4,PlatformDecoderModule:4 into --log.
Prints one JSON line like video-bench.py.
"""
import http.server, importlib.util, json, os, re, sys, threading, time

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("bb", os.path.join(here, "browser-bench.py"))
bb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bb)


class BiDi(bb.DevTools):
    def cmd(self, method, **params):
        self.id += 1
        self._send(json.dumps({"id": self.id, "method": method, "params": params}))
        while True:
            m = self._recv()
            if m.get("id") == self.id:
                if m.get("type") == "error":
                    raise RuntimeError(f"{method}: {m.get('error')} {m.get('message')}")
                return m.get("result", {})

    def js(self, ctx, expr):
        r = self.cmd("script.evaluate", expression=expr, target={"context": ctx}, awaitPromise=True)
        v = r.get("result", {})
        if v.get("type") == "array":
            return [x.get("value") for x in v.get("value", [])]
        return v.get("value")


def arg(name, default):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


def main():
    port = int(arg("--port", 9222))
    video = arg("--video", "aqz-KE-bpKQ")
    seconds = int(arg("--seconds", 60))
    log = arg("--log", "")
    page = (f'<!doctype html><body style="margin:0;background:#000">'
            f'<iframe src="https://www.youtube-nocookie.com/embed/{video}?autoplay=1&mute=1&controls=0" '
            f'allow="autoplay; fullscreen" referrerpolicy="strict-origin-when-cross-origin" '
            f'style="border:0;width:100vw;height:100vh"></iframe>').encode()

    class Page(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers()
            self.wfile.write(page)

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    b = BiDi(f"ws://127.0.0.1:{port}/session")
    b.cmd("session.new", capabilities={})
    top = b.cmd("browsingContext.getTree")["contexts"][0]["context"]
    b.cmd("browsingContext.navigate", context=top, url=f"http://127.0.0.1:{srv.server_port}/", wait="complete")
    fr = None
    for _ in range(30):
        time.sleep(1)
        kids = b.cmd("browsingContext.getTree", root=top)["contexts"][0].get("children") or []
        kids = [k for k in kids if "youtube" in k.get("url", "")]
        if kids and b.js(kids[0]["context"], "!!document.querySelector('video') && !!document.getElementById('movie_player')"):
            fr = kids[0]["context"]
            break
    if fr is None:
        raise SystemExit("firefox-video-bench: no YouTube player")
    b.js(fr, "(() => { const p = document.getElementById('movie_player'); p.mute(); "
             "p.setPlaybackQualityRange && p.setPlaybackQualityRange('hd2160', 'hd2160'); p.playVideo(); })()")
    time.sleep(10)
    qs = "(() => { const q = document.querySelector('video').getVideoPlaybackQuality(); return [q.totalVideoFrames, q.droppedVideoFrames] })()"
    q0 = b.js(fr, qs) or [0, 0]
    time.sleep(seconds)
    q1 = b.js(fr, qs) or [0, 0]
    height = b.js(fr, "document.querySelector('video').videoHeight")
    codec = b.js(fr, "(() => { try { return document.getElementById('movie_player').getStatsForNerds().codecs } catch (e) { return '' } })()") or ""
    decoder = ""
    if log:
        text = ""
        for f in sorted(os.listdir(os.path.dirname(log) or ".")):
            if f.startswith(os.path.basename(log)):
                text += open(os.path.join(os.path.dirname(log) or ".", f), errors="replace").read()
        if re.search(r"VA-API FFmpeg init successful|VA-API.*(Got one|hw frame)", text):
            decoder = "ffmpeg VA-API"
        elif "dav1d" in text.lower():
            decoder = "dav1d"
        elif re.search(r"libvpx|VPXDecoder", text):
            decoder = "libvpx"
    frames, dropped = q1[0] - q0[0], q1[1] - q0[1]
    print(json.dumps({"test": "youtube-4k-firefox", "video": video, "decoder": decoder,
                      "hardware": decoder == "ffmpeg VA-API", "codec": codec,
                      "height": height, "fps": round(frames / seconds, 1) if seconds else None,
                      "dropped_pct": round(100 * dropped / frames, 1) if frames else None,
                      "seconds": seconds}))
    b.cmd("session.end")


if __name__ == "__main__":
    main()
