#!/bin/bash
# mkclip.sh OUTDIR [SECONDS]: A/V sync test clips. Every second: the whole picture white for 100 ms
# (6 frames at 60 fps) and a 1 kHz beep for 50 ms, both starting on the second. H.264+AAC (MP4) and
# VP9+Opus (WebM), 1280x720 60 fps, plus av.html that plays one full screen and logs dropped frames.
set -euo pipefail
O=$1; D=${2:-180}; mkdir -p "$O"
V="color=c=black:s=1280x720:r=60:d=$D,drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='lt(mod(t+0.0001,1),0.1)',format=yuv420p"
A="aevalsrc='0.7*sin(2*PI*1000*t)*lt(mod(t,1),0.05)|0.7*sin(2*PI*1000*t)*lt(mod(t,1),0.05)':s=48000:d=$D"
nice ffmpeg -loglevel error -y -f lavfi -i "$V" -f lavfi -i "$A" -c:v libx264 -profile:v high -preset veryfast -g 60 -bf 2 \
  -c:a aac -b:a 128k -movflags +faststart -shortest "$O/av-h264.mp4"
nice ffmpeg -loglevel error -y -f lavfi -i "$V" -f lavfi -i "$A" -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 1M -g 60 \
  -row-mt 1 -c:a libopus -b:a 128k -shortest "$O/av-vp9.webm"
cat > "$O/av.html" <<'H'
<!doctype html><meta charset=utf-8><title>av</title>
<style>html,body{margin:0;background:#000;height:100%;overflow:hidden}video{width:100vw;height:100vh;object-fit:fill;display:block}</style>
<video id=v autoplay loop playsinline></video>
<script>
const q = new URLSearchParams(location.search), v = document.getElementById('v');
v.src = q.get('src') || 'av-h264.mp4';
v.play().catch(e => console.log('AVSYNC play-error ' + e));
setInterval(() => { const p = v.getVideoPlaybackQuality();
  console.log(`AVSYNC t=${v.currentTime.toFixed(3)} dropped=${p.droppedVideoFrames} total=${p.totalVideoFrames} paused=${v.paused}`); }, 5000);
</script>
H
ls -la "$O"
