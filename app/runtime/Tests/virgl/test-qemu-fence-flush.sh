#!/bin/bash
# QEMU hands held virgl fences to the GPU (qemu-virtio-gpu-fence-flush-on-need.patch),
# checked in the patched hw/display/virtio-gpu-virgl.c. virglrenderer holds the glFlush
# of a fence while the same GL context goes on (virgl-fence-flush-on-need.patch); a held
# fence never signals on Apple's GL (test-fence-flush-gl.c), so QEMU must ask:
#   - before every command that is not SUBMIT_3D (it may read the held work: resource
#     flush to the display, transfers, scanout), and before the hop to ctx0;
#   - after the last command of the queue, a suspended command, or when the display
#     blocks the renderer (the guest can wait on any fence from then on).
#   test-qemu-fence-flush.sh <patched hw/display/virtio-gpu-virgl.c>
set -uo pipefail
f=$1
body() { awk -v h="$2" 'index($0, h) == 1 {on=1} on {print} on && /^}$/ {exit}' "$f"; }
one=$(body "$f" 'static void virgl_process_one_cmd(VirtIOGPU *g,')
outer=$(body "$f" 'void virtio_gpu_virgl_process_cmd(VirtIOGPU *g,')
bad=()
# before the hop: flush unless the command is a command buffer
pre=$(awk '/virgl_renderer_force_ctx_0\(\);/ {exit} {print}' <<<"$one")
grep -q 'if (cmd->cmd_hdr.type != VIRTIO_GPU_CMD_SUBMIT_3D) {' <<<"$pre" &&
  grep -q 'virgl_renderer_flush_fences();' <<<"$pre" ||
  bad+=("no flush before commands that are not SUBMIT_3D (or after the hop to ctx0)")
grep -q 'virgl_process_one_cmd(g, cmd);' <<<"$outer" || bad+=("process_cmd does not run the command")
after=$(awk '/virgl_process_one_cmd\(g, cmd\);/ {on=1; next} on {print}' <<<"$outer")
for want in '!QTAILQ_NEXT(cmd, next)' 'g->parent_obj.renderer_blocked' \
            '!cmd->finished && !(cmd->cmd_hdr.flags & VIRTIO_GPU_FLAG_FENCE)' \
            'virgl_renderer_flush_fences();'; do
  grep -qF "$want" <<<"$after" || bad+=("no flush where the queue ends or stops: $want")
done
if ((${#bad[@]})); then
  printf 'qemu fence flush: %s\n' "${bad[@]}" >&2
  exit 1
fi
echo "qemu fence flush: QEMU asks before other commands and where its queue ends"
