#!/usr/bin/env python3
"""webrtc-summary.py RESULT.json...: webrtc-encode.sh results side by side, CPU per frame.

Hardware and software runs of the same call do different amounts of work (Chrome
sends more frames when encoding is cheap), so CPU in cores alone does not compare
them. Per run: the Mac's CPU (QEMU, which includes the VM's vCPUs, plus the
VideoToolbox encoder service; the VM's own CPU is part of QEMU's and is not added
again), frames encoded by all video senders, and pixels encoded. Then CPU per frame
and per megapixel. Medians per (source, encoder kind) over the runs given."""
import json, os, statistics, sys
from collections import defaultdict

runs = defaultdict(list)
for path in sys.argv[1:]:
    d = json.load(open(path))
    senders = d["result"].get("senders") or [d["result"]]
    frames = sum(s.get("framesEncoded", 0) for s in senders)
    mpx = sum(s.get("framesEncoded", 0) * s.get("width", 0) * s.get("height", 0) for s in senders) / 1e6
    secs = d["seconds"]
    mac_s = (d["qemu_cpu_cores"] + d["mac_vt_cpu_cores"]) * secs
    encs = sorted({s.get("encoder", "?") for s in senders})
    kind = "hardware" if d.get("hardware_encoder") else "software"
    # --hd runs: "hd" in the result, or (older results) "-hd-" in the file name
    hd = d.get("hd", "-hd-" in os.path.basename(path))
    runs[(d["source"] + ("-hd" if hd else ""), kind)].append({
        "encoders": encs,
        "sizes": sorted({f'{s.get("width")}x{s.get("height")}' for s in senders}),
        "fps": frames / secs,
        "guest_cores": d["guest_cpu_cores"],
        "qemu_cores": d["qemu_cpu_cores"],
        "vt_cores": d["mac_vt_cpu_cores"],
        "ms_per_frame": 1000 * mac_s / frames if frames else None,
        "ms_per_mpx": 1000 * mac_s / mpx if mpx else None,
    })

out = []
for (src, kind), rs in sorted(runs.items()):
    med = lambda k: round(statistics.median(r[k] for r in rs if r[k] is not None), 3)
    out.append({"source": src, "encoder": kind, "runs": len(rs),
                "encoders": sorted({e for r in rs for e in r["encoders"]}),
                "sizes": sorted({z for r in rs for z in r["sizes"]}),
                "frames_per_s": med("fps"), "guest_cpu_cores": med("guest_cores"),
                "qemu_cpu_cores": med("qemu_cores"), "mac_vt_cpu_cores": med("vt_cores"),
                "mac_cpu_ms_per_frame": med("ms_per_frame"),
                "mac_cpu_ms_per_megapixel": med("ms_per_mpx")})
print(json.dumps(out, indent=1))
