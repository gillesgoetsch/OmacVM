#!/bin/bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: macos/build-qemu-gpu-runtime.sh [--archive-dir DIR]

Build the pinned QEMU/VirGL source stack for macOS 15.0 with Try Omarchy's Cocoa identity,
dynamic-display, immersive-mode, pause-ownership, pinch-zoom, and ISO
keyboard patches, then relocate, sign, validate, and
atomically stage it at:
  macos/.build/qemu-gpu-runtime

The build is Apple-Silicon/HVF-only. It enables Cocoa+VirGL, SLIRP user
networking, SDL duplex audio, and virtio-9p folder sharing. All downloaded source archives and wheels are
immutable and checksum-pinned; scratch sources are removed on every exit.

It also builds the UEFI firmware with Omarchy's boot logo (build-edk2.sh);
OMACVM_FIRMWARE=qemu keeps QEMU's prebuilt firmware instead.

Set OMARCHY_RUNTIME_BUILD_JOBS to a positive integer to bound compilation.
Set OMACVM_RUNTIME_KOSMICKRISP=1 to add KosmicKrisp (build-kosmickrisp.sh), which
Venus uses on macOS 26 and newer; without it the runtime has MoltenVK only.
With --archive-dir, reuse already-downloaded pinned archives from DIR. Every
archive is copied into private scratch space and checksum-verified before use.
EOF
}

# Use the guarded array expansions below: Bash 3.2 treats an empty array as
# unbound under nounset, even when it has been initialized.
ninja_jobs=()
if [[ -n ${OMARCHY_RUNTIME_BUILD_JOBS:-} ]]; then
  [[ $OMARCHY_RUNTIME_BUILD_JOBS =~ ^[1-9][0-9]{0,5}$ ]] || {
    echo 'qemu-source-build: OMARCHY_RUNTIME_BUILD_JOBS must be a positive integer' >&2
    exit 64
  }
  ninja_jobs=(-j "$OMARCHY_RUNTIME_BUILD_JOBS")
fi

archive_cache=
while (($#)); do
  case "$1" in
    --archive-dir)
      (($# >= 2)) || { usage >&2; exit 64; }
      [[ -z $archive_cache ]] || { usage >&2; exit 64; }
      archive_cache=$2
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

native_dir=$(cd "$(dirname "$0")" && pwd -P)

# KosmicKrisp (Venus on macOS 26+, from a pinned Mesa commit) is opt-in:
# OMACVM_RUNTIME_KOSMICKRISP=1. Its build needs Homebrew LLVM and SPIR-V tools,
# so check the build machine before the long QEMU build. Without it the
# runtime has MoltenVK only.
# OMACVM_KOSMICKRISP_FROM=DIR: one built on another Mac (import-kosmickrisp.sh).
case ${OMACVM_RUNTIME_KOSMICKRISP:-0} in
  0) with_kosmickrisp=0 ;;
  1) if [[ -n ${OMACVM_KOSMICKRISP_FROM:-} ]]; then
       "$native_dir/import-kosmickrisp.sh" "$OMACVM_KOSMICKRISP_FROM" --stamp >/dev/null
     else
       "$native_dir/build-kosmickrisp.sh" --check
     fi
     with_kosmickrisp=1 ;;
  *) echo 'qemu-source-build: OMACVM_RUNTIME_KOSMICKRISP must be 0 or 1' >&2; exit 64 ;;
esac
texture_patch="$native_dir/patches/qemu-texture-borrowing-11.1.patch"
gpu_fix_patch="$native_dir/patches/qemu-gpu-spike-resolution-fix.patch"
identity_patch="$native_dir/patches/qemu-cocoa-product-identity.patch"
display_patch="$native_dir/patches/qemu-cocoa-dynamic-display.patch"
immersive_patch="$native_dir/patches/qemu-cocoa-immersive-mode.patch"
full_grab_patch="$native_dir/patches/qemu-cocoa-full-grab-focus.patch"
reenable_patch="$native_dir/patches/qemu-cocoa-full-grab-reenable.patch"
pause_ownership_patch="$native_dir/patches/qemu-cocoa-pause-ownership.patch"
pinch_patch="$native_dir/patches/qemu-cocoa-pinch-zoom.patch"
precise_scroll_patch="$native_dir/patches/qemu-cocoa-precise-scroll.patch"
iso_swap_patch="$native_dir/patches/qemu-cocoa-iso-section-grave-swap.patch"
injected_text_patch="$native_dir/patches/qemu-cocoa-injected-text.patch"
audio_device_patch="$native_dir/patches/qemu-sdl-audio-device-selection.patch"
audio_recovery_patch="$native_dir/patches/qemu-hda-full-ring-recovery.patch"
shared_folder_patch="$native_dir/patches/qemu-9p-guest-owner.patch"
memory_reclaim_patch="$native_dir/patches/qemu-hvf-free-page-reclaim.patch"
mapped_sections_patch="$native_dir/patches/qemu-hvf-mapped-sections.patch"
strchrnul_patch="$native_dir/patches/qemu-darwin-strchrnul-compat.patch"
usb_exact_bus_patch="$native_dir/patches/qemu-usb-host-exact-bus.patch"
slirp_patch="$native_dir/patches/libslirp-darwin-icmp-matching.patch"
udp_patch="$native_dir/patches/libslirp-ipv4-udp-translation.patch"
fence_poll_patch="$native_dir/patches/qemu-darwin-gpu-fence-poll.patch"
virgl_native_patch="$native_dir/patches/virgl-native-opengl.patch"
virgl_int_tex_patch="$native_dir/patches/virgl-texture-integer-samplers.patch"
virgl_videotoolbox_patch="$native_dir/patches/virgl-videotoolbox-decode.patch"
virgl_row_size_patch="$native_dir/patches/virgl-transfer-row-size.patch"
virgl_vt_encode_patch="$native_dir/patches/virgl-videotoolbox-encode.patch"
hidden_window_patch="$native_dir/patches/qemu-cocoa-hidden-for-tests.patch"
virgl_skip_draws_patch="$native_dir/patches/virgl-shader-failure-skip-draws.patch"
virgl_loss_report_patch="$native_dir/patches/virgl-context-loss-report.patch"
virgl_test_fault_patch="$native_dir/patches/virgl-test-shader-fault.patch"
virgl_null_variant_patch="$native_dir/patches/virgl-shader-variant-null-checks.patch"
virgl_shader_limits_patch="$native_dir/patches/virgl-shader-size-limits.patch"
virgl_venus_lost_patch="$native_dir/patches/virgl-venus-lost-context-fences.patch"
virgl_instance_id_patch="$native_dir/patches/virgl-core-instance-id.patch"
virgl_xfb_end_patch="$native_dir/patches/virgl-transform-feedback-end.patch"
virgl_so_checks_patch="$native_dir/patches/virgl-stream-output-checks.patch"
virgl_gl_error_patch="$native_dir/patches/virgl-gl-error-skip-command.patch"
virgl_buffer_checks_patch="$native_dir/patches/virgl-buffer-binding-checks.patch"
virgl_draw_checks_patch="$native_dir/patches/virgl-draw-range-checks.patch"
virgl_ubo_checks_patch="$native_dir/patches/virgl-uniform-buffer-checks.patch"
virgl_index_clamp_patch="$native_dir/patches/virgl-shader-index-clamp.patch"
virgl_vertex_format_patch="$native_dir/patches/virgl-vertex-format-checks.patch"
virgl_ubo_align_patch="$native_dir/patches/virgl-uniform-buffer-alignment.patch"
virgl_block_array_patch="$native_dir/patches/virgl-uniform-block-array.patch"
virgl_draw_error_patch="$native_dir/patches/virgl-draw-gl-error-check.patch"
virgl_vertex_unused_patch="$native_dir/patches/virgl-vertex-unused-first-input.patch"
virgl_memory_budget_patch="$native_dir/patches/virgl-resource-memory-budget.patch"
virgl_queue_flush_patch="$native_dir/patches/virgl-control-queue-flush.patch"
virgl_venus_robust_patch="$native_dir/patches/virgl-venus-robust-buffer-access.patch"
virgl_shader_core_glsl_version_patch="$native_dir/patches/virgl-shader-core-glsl-version.patch"
virgl_shader_shadow_lod_patch="$native_dir/patches/virgl-shader-shadow-lod-extension.patch"
virgl_shader_int_outputs_patch="$native_dir/patches/virgl-shader-integer-outputs.patch"
virgl_blitter_core_glsl_version_patch="$native_dir/patches/virgl-blitter-core-glsl-version.patch"
virgl_blitter_integer_msaa_patch="$native_dir/patches/virgl-blitter-integer-msaa.patch"
virgl_framebuffer_no_attachments_patch="$native_dir/patches/virgl-framebuffer-no-attachments.patch"
virgl_caps_sampler_limit_patch="$native_dir/patches/virgl-caps-sampler-limit.patch"
virgl_budget_loss_patch="$native_dir/patches/virgl-resource-budget-context-loss.patch"
virgl_venus_budget_patch="$native_dir/patches/virgl-venus-memory-budget.patch"
prepare_runtime="$native_dir/prepare-qemu-gpu-runtime.sh"
pinned_bottles="$native_dir/pinned-runtime-bottles.sh"

qemu_commit=c3d48b7d1e89604920e5b81b91140c2ad39a1943
qemu_root="qemu-$qemu_commit"
qemu_archive_name="$qemu_root.tar.gz"
qemu_url="https://gitlab.com/qemu-project/qemu/-/archive/$qemu_commit/$qemu_archive_name"
qemu_sha256=7563781d7dec46f11509801e027f852597235d29ca7afa44a07ed9d8b108b8cd

texture_patch_sha256=b20bdf9a7d7ccda5b86366ad9d09a3bf95308b98a06b1ece281344405bcc7ab9
gpu_fix_patch_sha256=b554e1ef9910d0891d69ee0fe84e479559c057dc28291e36e1524031808fc69f
identity_patch_sha256=5c9358c2858a74d6a678eacaae550a021f3e616c98c4e4e98c0e50bd869a0666
display_patch_sha256=1ce59350b6b8e6842bc0c9ca34c97f54cb75e85e2d7b35e5b483858654c4d693
immersive_patch_sha256=2462463932f7db0d659f754f7f9c182884564dbcd7d4b8e523f1b57f0bd9fe5b
full_grab_patch_sha256=d94aaa7b8b8b97eb25a5ace2b3a1268985e1b16e4e6201847b926b8ee709dbfb
reenable_patch_sha256=f6ed7e01e1554049aa3cf2964d1f4a851cb1735208f9ddc88eeb608d1b7fbaed
pause_ownership_patch_sha256=1a5729b36eb3e437395d41883a10c3c652df71d289d5df84d95aebd49c78a8f0
pinch_patch_sha256=37acb8895dddd35fc66812d0c49ec5fc697f9127e9e12ed2e60d17999bf32aee
precise_scroll_patch_sha256=54252b3b19358aa7e2c75d5f50775a7f488ef2d8b4db8723ba4768b56316a78f
iso_swap_patch_sha256=57f33a5fb08fb90a7813b13bb7037a13198e4d7db230085b1faa28b284cf2387
injected_text_patch_sha256=18d64d52f715d0cf1b2b6d1761059371e1859ee61faf3cc4800e2effc1ed4dd1
audio_device_patch_sha256=03aca71c26163c337338cc3b2013c35430690fc0e8b66c5ce92a42f59a9b3334
audio_recovery_patch_sha256=d1e93fd303777f424d7b11522fcf44bf726058901e85de3920c33e9083f301ea
shared_folder_patch_sha256=41247692501655393ae3a40f56915472ab29b6e89c5173e33db1f62cca56632f
memory_reclaim_patch_sha256=5d422130996b99145d017d4429df660a07c757388ef7d52cba389766c18b0acf
mapped_sections_patch_sha256=2991378d565faeaf114bb5948bfa9ad05c39b078e4e1f4c2a674c3283800fab0
fence_poll_patch_sha256=1ac407bdb617dfc52d004d0ebd0d07641d920f7d3a9756223c6426a207fb1499
virgl_native_patch_sha256=692ed73cf88780b4c0e04c56e3cfb21cec761768dea909d755624e07d82fc60c
virgl_int_tex_patch_sha256=5336df08e7096fb0e4b977ebedf36aac29c6c053df7edbdea7ff5e45273f57e4
virgl_videotoolbox_patch_sha256=de2061490594e835cec37a181995d9a0289bc763fee72e7d5fb35d60dcf29392
virgl_row_size_patch_sha256=c1994d82562625ba8211d1443423b23763b8932fbfe610a416ae6f556010da9f
virgl_vt_encode_patch_sha256=7c92879d7b06a4e06af1c47054d38d2f102bd94f8c264d75ba16eece59625fc7
hidden_window_patch_sha256=22d61f49590966a65f44cb5dd74e2e6254e80e6045f1686e5f379c617745d303
virgl_skip_draws_patch_sha256=7611495f5afd94b016c9cd7126a457bfdcb13f60df46b5a754cb3d584a4002f1
virgl_loss_report_patch_sha256=cfef9d4417fabb60cc559f970598fa7f7da069ff747ff652baddb922ca29905a
virgl_test_fault_patch_sha256=4b09b62f5d1ac73ff056a93891ca4041cfe6ee0f93f7b6bbbcee0fb7b3c94728
virgl_null_variant_patch_sha256=305d6fffe723fa32ffe3576c0e33c68b7358e142d88612817a175489aaa16832
virgl_shader_limits_patch_sha256=df6b333dbeb1fe43fd023551fac8ee2d75228f3866b5b1e456621614dc9c01c9
virgl_instance_id_patch_sha256=67de90babfec3f4abf2b1747f6637bd74e4cd5a2c2cdf0b44eaaeb0e33a6f0d6
virgl_so_checks_patch_sha256=bf9c4f1eeeda2542fec37d225717a93299b165b5820b3d1936651fc8aea62d64
virgl_xfb_end_patch_sha256=ebb035a13cf275be1809856ed79b68da12adebe232d88dadc59e8ccb371e2932
virgl_gl_error_patch_sha256=694dade0eebb88a8de81b45c9cfe48ca55eae5a93284fcb13eeb9a082cbfbc00
virgl_buffer_checks_patch_sha256=8ec68618b2688ede52afcd286283c80e84787bf2e4ccfa5899cff77a79835688
virgl_draw_checks_patch_sha256=308521bdb7ba297ce166a587abb10b590a5564739e600d53b71ce0a473e9b1e8
virgl_ubo_checks_patch_sha256=fdb2c662933bfee31c0f9f871cd69126e0261e1bab767e9334407da2da3b72ff
virgl_index_clamp_patch_sha256=cab18c535c5ed46d2d6c8785c7096c280288d9aff9f30b499c48487ad2c3d933
virgl_vertex_format_patch_sha256=dd1ad464871635c753622037d5f188af821028ade1093866f99e969e53a96ad6
virgl_ubo_align_patch_sha256=0087f49d9f64e497580bbb6174b92ef0990c85eea73afbc18ff34be2084a8f80
virgl_block_array_patch_sha256=8b9fb4870fbd4ee629d2802d10672406c7ad43bdf54ae558bd6427e6f5a4011c
virgl_draw_error_patch_sha256=9243046f78aa8eaa1c22591a3afeafe6a51ea092170ac8370d26ffa57e92c363
virgl_vertex_unused_patch_sha256=1c424509f19ebcd23c17a8fdb1984ddaa64e90e682959d5621236444aa1a2cc6
virgl_memory_budget_patch_sha256=3609979e8b4cb1b0ac14474e30d4ff063d63aebbeef83aba9ef6497bad5ae6ae
virgl_queue_flush_patch_sha256=7f468d955d47cfbf9df75578efddfab0f36256b9b092c8e992f6b78faf67991b
virgl_venus_robust_patch_sha256=1f877c60460374d0d0109089e70de8c0bb3f5d670404d1a0b1e76d426db80946
virgl_budget_loss_patch_sha256=32fca5ea3b3c76d147138935678bc5ca7ded2d17a5922993ba9f9a232caef2a4
virgl_venus_budget_patch_sha256=fdfc1667e0e9b267104fff8113e6754979d1f4d94c32776f29daab17147cf842
virgl_venus_lost_patch_sha256=c88ad7984c70a79e90c9685d39879f445f637ad1a99d5496976049d3fa494fdc
virgl_shader_core_glsl_version_patch_sha256=aa6a6c0055d3b5cdca09e26fba7f2b97a635696e60d9c00835e8edab09cb25c7
virgl_shader_shadow_lod_patch_sha256=c56fb4fa4637f5c634bce74be2a750b9ba321a7ed79cc16787dd579a71da1d92
virgl_shader_int_outputs_patch_sha256=79ab17b35d689f58736c853aa7cdc4a2d8b2e91897e9e4cccb8ebf584acc0d57
virgl_blitter_core_glsl_version_patch_sha256=aa73744e14d048435df10343839fc1962d079110a895c7c27ed8f6b67788a11e
virgl_blitter_integer_msaa_patch_sha256=eb113286234b36d976546c443df19d4faee76cd48448e77cc00b4e227277831e
virgl_framebuffer_no_attachments_patch_sha256=21d98c69877901238db0f50cc610e7156decaebf2e41775e11cd8dea539986f5
virgl_caps_sampler_limit_patch_sha256=ec779a77aab1384dd5f2c046e9d3238ee11c840dd19577bb6f96fb7e85ff2169
strchrnul_patch_sha256=ec1048dd0e8ebe53bf7e8a3bca9bf2f5f4336cd607d4cd077437470e9a32094a
usb_exact_bus_patch_sha256=5e39159171295c566d014a1ef2744130f80fa02b742c349fa47373b00ae697ec
udp_patch_sha256=95e8ee890be78cdce70b3ee54a8adac27be02421be08b986ae987c74ef8cec8c
slirp_patch_sha256=20f3d424c79929fb82d240d0ee06b99e9f93ecfb9460579dc414303820d59f90
slirp_source_root=libslirp-v4.9.4
slirp_archive_name="$slirp_source_root.tar.gz"
slirp_url="https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v4.9.4/$slirp_archive_name"
slirp_sha256=3998863b020aeda34bddc567097c6efba55a78cdf6eeee6bcd42c11ef23967da
meson_root=meson-1.9.0
meson_archive_name="$meson_root.tar.gz"
meson_url="https://github.com/mesonbuild/meson/releases/download/1.9.0/$meson_archive_name"
meson_sha256=cd27277649b5ed50d19875031de516e270b22e890d9db65ed9af57d18ebc498d
macos_deployment_target=15.0

keycodemap_commit=f5772a62ec52591ff6870b7e8ef32482371f22c6
keycodemap_root="keycodemapdb-$keycodemap_commit"
keycodemap_archive_name="$keycodemap_root.tar.gz"
keycodemap_url="https://gitlab.com/qemu-project/keycodemapdb/-/archive/$keycodemap_commit/$keycodemap_archive_name"
keycodemap_sha256=d014b53382dbb17b8196ad12f50de7f20d0ef1b9f7d54b0be51a6cbb14209195

dtc_commit=b6910bec11614980a21e46fbccc35934b671bd81
dtc_root="dtc-$dtc_commit"
dtc_archive_name="$dtc_root.tar.gz"
dtc_url="https://git.kernel.org/pub/scm/utils/dtc/dtc.git/snapshot/$dtc_archive_name"
dtc_sha256=e115f987eec23a1ba25150a46ced1675de3716072d3b4905afb3a9cda0f007c7

ninja_version=1.13.0
ninja_archive_name=ninja-1.13.0-py3-none-macosx_10_9_universal2.whl
ninja_url="https://files.pythonhosted.org/packages/3c/74/d02409ed2aa865e051b7edda22ad416a39d81a84980f544f8de717cab133/$ninja_archive_name"
ninja_sha256=fa2a8bfc62e31b08f83127d1613d10821775a0eb334197154c4d6067b7068ff1

virgl_version=1.0.42
setuptools_archive_name=setuptools-84.0.0-py3-none-any.whl
setuptools_url="https://files.pythonhosted.org/packages/95/9c/c510029fc6ef33a6275cd2c5d3cecd6613dfd6aa401d57c54f1c18852ccf/$setuptools_archive_name"
setuptools_sha256=51a52592b3b99e102b609654876bd65f19f999935166d1352678931132b0c670

# wheel 0.48 resolves `packaging` at install time and mkvenv runs offline, so
# the vendored set must carry it; no Mac ships it with the system Python.
packaging_archive_name=packaging-26.3-py3-none-any.whl
packaging_url="https://files.pythonhosted.org/packages/63/34/ba1c580383c9eada3711951fef0795c80b829a078d72188184bcab9dd527/$packaging_archive_name"
packaging_sha256=d7193f7c8e4e93f444fde0262bf90af30e16fa0ad0ad44cb553c87339b23cd1c

wheel_archive_name=wheel-0.48.0-py3-none-any.whl
wheel_url="https://files.pythonhosted.org/packages/2e/29/69cfbb602cd91690c55d38ba9fe53e6a7e76a6fa647bf38f19c138d25449/$wheel_archive_name"
wheel_sha256=3217dcc807155e45db462d7ef2431f5ddda0d7273b700d05a67b271ceb1287ab

pip_archive_name=pip-26.2.1-py3-none-any.whl
pip_url="https://files.pythonhosted.org/packages/f3/6e/1736e5b4ae2b778ef2f81c47d797de9f891d4d8acb047a24ca37a60294dd/$pip_archive_name"
pip_sha256=71138adf1f4ca900cdb7d289c21b7494329f2332b6d85f0e1c42108c0384ed3e

# Build the same renderer and patches as the 1.0.42 bottle, targeting 15.0.
# The published bottle targets Tahoe; lowering only QEMU's target is insufficient.
virgl_source_root=virglrenderer-1.3.0
virgl_archive_name="$virgl_source_root.tar.gz"
virgl_url="https://gitlab.freedesktop.org/virgl/virglrenderer/-/archive/1.3.0/$virgl_archive_name"
virgl_sha256=065bc56e89e6f631f96101cd62eba0748e48eb888b434edc86e89d05395e76f3
virgl_tap_root=homebrew-virglrenderer-1.0.42
virgl_tap_archive_name="$virgl_tap_root.tar.gz"
virgl_tap_url="https://codeload.github.com/startergo/homebrew-virglrenderer/tar.gz/refs/tags/v1.0.42"
virgl_tap_sha256=950273fbba46905b6112ee2bd0598c1da706c25319a7347058cbc52f04ba96dd
pyyaml_root=pyyaml-6.0.3
pyyaml_archive_name="$pyyaml_root.tar.gz"
pyyaml_url="https://files.pythonhosted.org/packages/05/8e/961c0007c59b8dd7729d542c61a4d537767a59645b82a0b521206e1e25c2/$pyyaml_archive_name"
pyyaml_sha256=d76623373421df22fb4cf8817020cbb7ef15c725b9d5e45f17e189bfc384190f

angle_version=1.0.16
angle_archive_name=angle-1.0.16.arm64_sequoia.bottle.tar.gz
angle_url="https://github.com/startergo/homebrew-angle/releases/download/v1.0.16/$angle_archive_name"
angle_sha256=29fe2175b157a65f12879f9a12b5c8f94d0a76fafdf41ff009a2fdb4e9df525c

epoxy_version=1.0.5
epoxy_archive_name=libepoxy-1.0.5.arm64_sequoia.bottle.tar.gz
epoxy_url="https://github.com/startergo/homebrew-libepoxy/releases/download/v1.0.5/$epoxy_archive_name"
epoxy_sha256=109384a1d37edf207a9b9f3d8950710c00767635b3c7ff295e3af83611876ef2

die() {
  echo "qemu-source-build: $*" >&2
  exit 1
}

log() {
  echo "[qemu-source-build] $*"
}

[[ -f $pinned_bottles && ! -L $pinned_bottles ]] || {
  echo "qemu-source-build: missing pinned bottle manifest: $pinned_bottles" >&2
  exit 1
}
# shellcheck source=macos/pinned-runtime-bottles.sh
source "$pinned_bottles"

for tool in awk bash chmod curl ditto file grep install mkdir mktemp patch \
  pkg-config python3 rm sed shasum sw_vers tar uname; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool is unavailable: $tool"
done

[[ $(uname -s) == Darwin ]] || die "this source build requires macOS"
[[ $(uname -m) == arm64 ]] || die "this source build requires Apple Silicon (arm64)"
macos_major=$(sw_vers -productVersion | awk -F. '{ print $1 }')
[[ $macos_major =~ ^[0-9]+$ ]] || die "could not determine the macOS version"
((macos_major >= 15)) || die "the pinned GPU bottles require macOS 15 or newer"
[[ -f $identity_patch && ! -L $identity_patch ]] || \
  die "missing Cocoa product-identity patch: $identity_patch"
[[ -f $display_patch && ! -L $display_patch ]] || \
  die "missing dynamic-display patch: $display_patch"
[[ -f $immersive_patch && ! -L $immersive_patch ]] || \
  die "missing immersive-mode patch: $immersive_patch"
[[ -f $full_grab_patch && ! -L $full_grab_patch ]] || \
  die "missing Cocoa full-grab patch: $full_grab_patch"
[[ -f $reenable_patch && ! -L $reenable_patch ]] || \
  die "missing Cocoa full-grab re-enable patch: $reenable_patch"
[[ -f $pause_ownership_patch && ! -L $pause_ownership_patch ]] || \
  die "missing Cocoa pause-ownership patch: $pause_ownership_patch"
[[ -f $pinch_patch && ! -L $pinch_patch ]] || \
  die "missing Cocoa pinch-zoom patch: $pinch_patch"
[[ -f $precise_scroll_patch && ! -L $precise_scroll_patch ]] || \
  die "missing Cocoa precise-scroll patch: $precise_scroll_patch"
[[ -f $iso_swap_patch && ! -L $iso_swap_patch ]] || \
  die "missing Cocoa ISO Section/Grave swap patch: $iso_swap_patch"
[[ -f $audio_device_patch && ! -L $audio_device_patch ]] || \
  die "missing SDL audio-device patch: $audio_device_patch"
[[ -f $texture_patch && ! -L $texture_patch ]] || \
  die "missing texture-borrowing patch: $texture_patch"
[[ -f $shared_folder_patch && ! -L $shared_folder_patch ]] || \
  die "missing 9p shared-folder patch: $shared_folder_patch"
[[ -f $memory_reclaim_patch && ! -L $memory_reclaim_patch ]] || \
  die "missing HVF free-page reclaim patch: $memory_reclaim_patch"
[[ -f $mapped_sections_patch && ! -L $mapped_sections_patch ]] || \
  die "missing HVF mapped-sections patch: $mapped_sections_patch"
[[ -f $strchrnul_patch && ! -L $strchrnul_patch ]] || \
  die "missing Darwin strchrnul compatibility patch: $strchrnul_patch"
[[ -f $usb_exact_bus_patch && ! -L $usb_exact_bus_patch ]] || \
  die "missing USB exact-bus patch: $usb_exact_bus_patch"
[[ -x $prepare_runtime && ! -L $prepare_runtime ]] || \
  die "missing runtime preparation script: $prepare_runtime"
if [[ -n $archive_cache ]]; then
  [[ $archive_cache == /* ]] || die "--archive-dir must be an absolute path"
  [[ -d $archive_cache && ! -L $archive_cache ]] || \
    die "--archive-dir must name a regular directory: $archive_cache"
fi

work_dir=
# QEMU's configure refuses a folder with spaces (a home on "Macintosh SSD",
# say): then the scratch files go to macOS's temp folder.
scratch_root="$native_dir/.build/tmp"
if [[ $scratch_root == *[[:space:]]* ]]; then
  scratch_root=$(cd "${TMPDIR:-/private/tmp}" && pwd -P) || die "no temp folder: ${TMPDIR:-/private/tmp}"
  [[ $scratch_root != *[[:space:]]* ]] || die "build OmacVM from a folder without spaces in its path"
fi
remove_work_dir() {
  local path=$1
  [[ -n $path && ( -e $path || -L $path ) ]] || return 0
  [[ $path == "$scratch_root"/omarchy-qemu-source-build.* ]] || \
    die "refusing to remove unexpected scratch path: $path"
  rm -rf -- "$path"
}

cleanup() {
  local exit_status=$?
  trap - EXIT HUP INT TERM
  # OMACVM_RUNTIME_KEEP_WORK=1 (or OMACVM_RUNTIME_KEEP_SCRATCH=1) keeps the
  # sources and build trees (for rebuilding one library by hand while working
  # on a patch: ninja in place).
  if [[ -n $work_dir && ( ${OMACVM_RUNTIME_KEEP_WORK:-} == 1 || -n ${OMACVM_RUNTIME_KEEP_SCRATCH:-} ) ]]; then
    echo "[qemu-source-build] kept work dir: $work_dir" >&2
  else
    [[ -z $work_dir ]] || remove_work_dir "$work_dir" || true
  fi
  exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$scratch_root"
work_dir=$(mktemp -d "$scratch_root/omarchy-qemu-source-build.XXXXXX")
archive_dir="$work_dir/archives"
listing_dir="$work_dir/listings"
source_parent="$work_dir/source"
dependency_root="$work_dir/dependencies"
tool_root="$work_dir/tools"
mkdir -p "$archive_dir" "$listing_dir" "$source_parent" "$dependency_root" "$tool_root"

download_and_verify() {
  local label=$1
  local url=$2
  local expected_sha=$3
  local output=$4
  local actual_sha

  log "Downloading $label"
  curl --fail --location --silent --show-error \
    --proto '=https' --tlsv1.2 --retry 3 --retry-all-errors --connect-timeout 20 \
    --output "$output" "$url"
  actual_sha=$(shasum -a 256 "$output" | awk '{ print $1 }')
  [[ $actual_sha == "$expected_sha" ]] || \
    die "$label checksum mismatch: expected $expected_sha, got $actual_sha"
}

obtain_and_verify() {
  local label=$1
  local url=$2
  local expected_sha=$3
  local output=$4
  local cached
  local actual_sha

  if [[ -z $archive_cache ]]; then
    download_and_verify "$label" "$url" "$expected_sha" "$output"
    return
  fi

  cached="$archive_cache/${output##*/}"
  [[ -f $cached && ! -L $cached ]] || \
    die "archive cache is missing a regular ${output##*/}"
  actual_sha=$(shasum -a 256 "$cached" | awk '{ print $1 }')
  [[ $actual_sha == "$expected_sha" ]] || \
    die "$label cache checksum mismatch: expected $expected_sha, got $actual_sha"
  log "Using cached $label"
  install -m 0644 "$cached" "$output"
}

verify_file_sha() {
  local label=$1
  local path=$2
  local expected=$3
  local actual

  actual=$(shasum -a 256 "$path" | awk '{ print $1 }') || \
    die "could not hash $label"
  [[ $actual == "$expected" ]] || \
    die "$label checksum mismatch: expected $expected, got $actual"
}

# Every patch file is pinned in patches/SHA256SUMS: a changed patch, or one
# that is not listed, stops the build. After changing a patch on purpose:
#   (cd patches && shasum -a 256 *.patch > SHA256SUMS)
verify_patch_manifest() {
  local manifest="$native_dir/patches/SHA256SUMS" expected name path
  local listed=" "
  [[ -f $manifest ]] || die "patches/SHA256SUMS is missing"
  while read -r expected name; do
    [[ -n $name ]] || continue
    verify_file_sha "patch $name" "$native_dir/patches/$name" "$expected"
    listed+="$name "
  done < "$manifest"
  for path in "$native_dir"/patches/*.patch; do
    name=$(basename "$path")
    [[ $listed == *" $name "* ]] || die "patch not pinned in patches/SHA256SUMS: $name"
  done
}

validate_tar_root() {
  local label=$1
  local archive=$2
  local expected_root=$3
  local listing=$4
  local member

  tar -tzf "$archive" >"$listing" || die "$label is not a readable gzip tar archive"
  [[ -s $listing ]] || die "$label archive is empty"
  while IFS= read -r member; do
    member=${member#./}
    case "$member" in
      ""|/*|..|../*|*/..|*/../*) die "$label contains an unsafe path: $member" ;;
    esac
    case "$member" in
      "$expected_root"|"$expected_root/"|"$expected_root/"*) ;;
      *) die "$label contains a path outside $expected_root: $member" ;;
    esac
  done <"$listing"
}

slirp_archive="$archive_dir/$slirp_archive_name"
meson_archive="$archive_dir/$meson_archive_name"
qemu_archive="$archive_dir/$qemu_archive_name"
keycodemap_archive="$archive_dir/$keycodemap_archive_name"
dtc_archive="$archive_dir/$dtc_archive_name"
ninja_archive="$archive_dir/$ninja_archive_name"
virgl_archive="$archive_dir/$virgl_archive_name"
virgl_tap_archive="$archive_dir/$virgl_tap_archive_name"
pyyaml_archive="$archive_dir/$pyyaml_archive_name"
angle_archive="$archive_dir/$angle_archive_name"
epoxy_archive="$archive_dir/$epoxy_archive_name"
setuptools_archive="$archive_dir/$setuptools_archive_name"
wheel_archive="$archive_dir/$wheel_archive_name"
packaging_archive="$archive_dir/$packaging_archive_name"
pip_archive="$archive_dir/$pip_archive_name"

obtain_and_verify "libslirp source" "$slirp_url" "$slirp_sha256" "$slirp_archive"
obtain_and_verify "Meson" "$meson_url" "$meson_sha256" "$meson_archive"
obtain_and_verify "QEMU $qemu_commit" "$qemu_url" "$qemu_sha256" "$qemu_archive"
obtain_and_verify "keycodemapdb $keycodemap_commit" "$keycodemap_url" "$keycodemap_sha256" "$keycodemap_archive"
obtain_and_verify "dtc $dtc_commit" "$dtc_url" "$dtc_sha256" "$dtc_archive"
obtain_and_verify "Ninja $ninja_version" "$ninja_url" "$ninja_sha256" "$ninja_archive"
obtain_and_verify "virglrenderer source" "$virgl_url" "$virgl_sha256" "$virgl_archive"
obtain_and_verify "virglrenderer patches and regression tests" "$virgl_tap_url" "$virgl_tap_sha256" "$virgl_tap_archive"
obtain_and_verify "PyYAML source" "$pyyaml_url" "$pyyaml_sha256" "$pyyaml_archive"
obtain_and_verify "ANGLE $angle_version" "$angle_url" "$angle_sha256" "$angle_archive"
obtain_and_verify "libepoxy $epoxy_version" "$epoxy_url" "$epoxy_sha256" "$epoxy_archive"
while IFS=$'\t' read -r formula version archive_name archive_root archive_sha; do
  pinned_bottle_obtain \
    "$formula" "$formula $version" "$archive_sha" \
    "$archive_dir/$archive_name" "$archive_cache"
  pinned_bottle_validate_archive \
    "$formula $version" "$archive_dir/$archive_name" "$archive_root"
done < <(pinned_core_bottle_manifest)

obtain_and_verify "setuptools" "$setuptools_url" "$setuptools_sha256" "$setuptools_archive"
obtain_and_verify "wheel" "$wheel_url" "$wheel_sha256" "$wheel_archive"
obtain_and_verify "packaging" "$packaging_url" "$packaging_sha256" "$packaging_archive"
obtain_and_verify "pip" "$pip_url" "$pip_sha256" "$pip_archive"

validate_tar_root "QEMU $qemu_commit" "$qemu_archive" "$qemu_root" "$listing_dir/qemu.txt"
validate_tar_root "keycodemapdb" "$keycodemap_archive" "$keycodemap_root" "$listing_dir/keycodemapdb.txt"
validate_tar_root "dtc" "$dtc_archive" "$dtc_root" "$listing_dir/dtc.txt"
validate_tar_root "virglrenderer" "$virgl_archive" "$virgl_source_root" "$listing_dir/virglrenderer.txt"
validate_tar_root "virglrenderer patches" "$virgl_tap_archive" "$virgl_tap_root" "$listing_dir/virgl-tap.txt"
validate_tar_root "PyYAML" "$pyyaml_archive" "$pyyaml_root" "$listing_dir/pyyaml.txt"
validate_tar_root "ANGLE" "$angle_archive" "angle/$angle_version" "$listing_dir/angle.txt"
validate_tar_root "libepoxy" "$epoxy_archive" "libepoxy/$epoxy_version" "$listing_dir/libepoxy.txt"

validate_tar_root "libslirp source" "$slirp_archive" "$slirp_source_root" "$listing_dir/slirp.txt"
validate_tar_root "Meson" "$meson_archive" "$meson_root" "$listing_dir/meson.txt"
tar -xzf "$slirp_archive" -C "$source_parent"
tar -xzf "$meson_archive" -C "$tool_root"
verify_patch_manifest
verify_file_sha "Darwin ICMP reply matching patch" "$slirp_patch" "$slirp_patch_sha256"
patch -d "$source_parent/$slirp_source_root" -p1 -f -i "$slirp_patch"
verify_file_sha "IPv4 UDP reply translation patch" "$udp_patch" "$udp_patch_sha256"
patch -d "$source_parent/$slirp_source_root" -p1 -f -i "$udp_patch"
# OmacVM: the guest reaches the Mac's 127.0.0.1 only on the ports it may use.
patch -d "$source_parent/$slirp_source_root" -p1 -f -i "$native_dir/patches/omacvm-libslirp-host-ports.patch"
# Non-blocking UDP/ICMP sockets: a send the Mac cannot take at once is dropped
# instead of freezing the VM (Tests/net/test-slirp-udp-stall.sh).
patch -d "$source_parent/$slirp_source_root" -p1 -f -i "$native_dir/patches/libslirp-nonblocking-datagram-sockets.patch"
tar -xzf "$qemu_archive" -C "$source_parent"
tar -xzf "$virgl_archive" -C "$source_parent"
tar -xzf "$virgl_tap_archive" -C "$source_parent"
tar -xzf "$pyyaml_archive" -C "$tool_root"
# Use the pinned pure-Python YAML implementation for generated Gallium tables.
export PYTHONPATH="$tool_root/$pyyaml_root/lib"
export PYTHONNOUSERSITE=1
tar -xzf "$angle_archive" -C "$dependency_root"
tar -xzf "$epoxy_archive" -C "$dependency_root"
while IFS=$'\t' read -r formula version archive_name archive_root archive_sha; do
  tar -xzf "$archive_dir/$archive_name" -C "$dependency_root"
done < <(pinned_core_bottle_manifest)

source_dir="$source_parent/$qemu_root"
[[ -f $source_dir/configure && -f $source_dir/ui/cocoa.m ]] || \
  die "QEMU source archive is incomplete"

install -m 0644 "$setuptools_archive" "$wheel_archive" "$pip_archive" \
  "$packaging_archive" "$source_dir/python/wheels/"

mkdir -p "$source_dir/subprojects/keycodemapdb" "$source_dir/subprojects/dtc"
tar -xzf "$keycodemap_archive" -C "$source_dir/subprojects/keycodemapdb" --strip-components=1
tar -xzf "$dtc_archive" -C "$source_dir/subprojects/dtc" --strip-components=1

verify_file_sha "Try Omarchy texture-borrowing patch" "$texture_patch" "$texture_patch_sha256"
verify_file_sha "Try Omarchy GPU-resolution patch" "$gpu_fix_patch" "$gpu_fix_patch_sha256"
verify_file_sha "Try Omarchy Cocoa product-identity patch" \
  "$identity_patch" "$identity_patch_sha256"
verify_file_sha "Try Omarchy dynamic-display patch" "$display_patch" "$display_patch_sha256"
verify_file_sha "Try Omarchy Cocoa immersive-mode patch" \
  "$immersive_patch" "$immersive_patch_sha256"
verify_file_sha "Try Omarchy Cocoa full-grab patch" \
  "$full_grab_patch" "$full_grab_patch_sha256"
verify_file_sha "Try Omarchy Cocoa full-grab re-enable patch" \
  "$reenable_patch" "$reenable_patch_sha256"
verify_file_sha "Try Omarchy Cocoa pause-ownership patch" \
  "$pause_ownership_patch" "$pause_ownership_patch_sha256"
verify_file_sha "Try Omarchy Cocoa pinch-zoom patch" \
  "$pinch_patch" "$pinch_patch_sha256"
verify_file_sha "Try Omarchy Cocoa precise-scroll patch" \
  "$precise_scroll_patch" "$precise_scroll_patch_sha256"
verify_file_sha "Try Omarchy Cocoa ISO Section/Grave swap patch" \
  "$iso_swap_patch" "$iso_swap_patch_sha256"
verify_file_sha "Try Omarchy Cocoa injected-text patch" \
  "$injected_text_patch" "$injected_text_patch_sha256"
verify_file_sha "Try Omarchy SDL audio-device patch" \
  "$audio_device_patch" "$audio_device_patch_sha256"
verify_file_sha "Try Omarchy 9p shared-folder patch" \
  "$shared_folder_patch" "$shared_folder_patch_sha256"
verify_file_sha "Try Omarchy HVF free-page reclaim patch" \
  "$memory_reclaim_patch" "$memory_reclaim_patch_sha256"
verify_file_sha "Try Omarchy HVF mapped-sections patch" \
  "$mapped_sections_patch" "$mapped_sections_patch_sha256"
verify_file_sha "Try Omarchy Darwin GPU fence polling patch" \
  "$fence_poll_patch" "$fence_poll_patch_sha256"
verify_file_sha "Try Omarchy Darwin strchrnul compatibility patch" \
  "$strchrnul_patch" "$strchrnul_patch_sha256"
verify_file_sha "Try Omarchy USB exact-bus patch" \
  "$usb_exact_bus_patch" "$usb_exact_bus_patch_sha256"

log "Applying the exact render, identity, display, immersive, pause-ownership, audio, folder, Darwin compatibility, memory reclaim, pinch, precise-scroll, ISO keyboard, and USB exact-bus patches"
patch -d "$source_dir" -p1 -f -i "$texture_patch"
patch -d "$source_dir" -p1 -f -i "$gpu_fix_patch"
patch -d "$source_dir" -p1 -f -i "$identity_patch"
patch -d "$source_dir" -p1 -f -i "$display_patch"
patch -d "$source_dir" -p1 -f -i "$immersive_patch"
patch -d "$source_dir" -p1 -f -i "$full_grab_patch"
patch -d "$source_dir" -p1 -f -i "$reenable_patch"
patch -d "$source_dir" -p1 -f -i "$pause_ownership_patch"
verify_file_sha "Try Omarchy HDA full-ring recovery patch" \
  "$audio_recovery_patch" "$audio_recovery_patch_sha256"
patch -d "$source_dir" -p1 -f -i "$audio_device_patch"
patch -d "$source_dir" -p1 -f -i "$audio_recovery_patch"
# OmacVM: no catch-up after a stalled main loop (the guest's sound clock pauses;
# QEMU's ring covers the stall instead of the guest under-running).
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/qemu-hda-no-catch-up.patch"
patch -d "$source_dir" -p1 -f -i "$shared_folder_patch"
patch -d "$source_dir" -p1 -f -i "$strchrnul_patch"
patch -d "$source_dir" -p1 -f -i "$memory_reclaim_patch"
patch -d "$source_dir" -p1 -f -i "$mapped_sections_patch"
patch -d "$source_dir" -p1 -f -i "$fence_poll_patch"
patch -d "$source_dir" -p1 -f -i "$pinch_patch"
patch -d "$source_dir" -p1 -f -i "$precise_scroll_patch"
patch -d "$source_dir" -p1 -f -i "$iso_swap_patch"
patch -d "$source_dir" -p1 -f -i "$injected_text_patch"
patch -d "$source_dir" -p1 -f -i "$usb_exact_bus_patch"
# OmacVM: usb-host leaves a device the Mac uses alone (no reset: on macOS that
# re-enumerates it); the app's USB devices (docs/usb.md).
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/qemu-usb-host-busy-device.patch"
# OmacVM: a main loop stall > 2 s is logged with its place.
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/qemu-main-loop-stall-watchdog.patch"
# OmacVM: app name and icon from the launcher; Quit shuts the guest down;
# a borderless full screen (tests only: see omacvm-cocoa-fullscreen-own-space);
# the window keeps its size; full screen at the
# window's real size; modifiers only from input events; the recording device
# opens off the BQL.
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-identity.patch"
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-quit-powerdown.patch"
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-notch.patch"
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-window-size.patch"
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-fullscreen-size.patch"
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/qemu-cocoa-modifiers-input-only.patch"
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/qemu-sdl-audio-capture-thread.patch"
# OmacVM: the playback device opens and closes off the BQL too: a Mac audio
# device that does not answer no longer hangs the VM, it runs without sound.
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/qemu-sdl-audio-playback-thread.patch"
# OmacVM: the main loop (sound card timers, virgl) at user-interactive QoS, so a
# busy guest on a busy Mac no longer delays it and the sound stays clean.
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/qemu-darwin-main-loop-qos.patch"
# OmacVM: a window per Mac display in full screen (Virtual-2, Virtual-3, ...).
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-displays.patch"
# OmacVM tests: OMACVM_COCOA_HIDDEN=1 (no window), OMACVM_BACKGROUND=1 (window
# behind, never the focus); after the display patch, which has its own test mode.
verify_file_sha "Cocoa hidden-window patch" "$hidden_window_patch" "$hidden_window_patch_sha256"
patch -d "$source_dir" -p1 -f -i "$hidden_window_patch"
# OmacVM: outputs switched on or off together reach the guest (virtio-gpu).
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/qemu-virtio-gpu-display-event-race.patch"
# OmacVM: big buffers in fragmented guest memory attach (virtio-gpu).
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/qemu-virtio-gpu-mapping-entries.patch"
# OmacVM: no Dock, menu bar or hot corner from inside full screen (all displays);
# the pointer guard's maths in its own header, unit tested here.
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-pointer-guard.patch"
"$native_dir/Tests/display/test-pointer-guard.sh"
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-fullscreen-edges.patch"
# Test hook: real full screen on some displays only (OMACVM_TEST_ONLY_DISPLAYS).
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-test-only-displays.patch"
# OmacVM: full screen keeps its size over guest reboots (the display, not the view).
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-fullscreen-area.patch"
# OmacVM: QEMU's view context is flushed after surface texture work; guest mode
# changes left whole screen textures in GPU memory. Tested on Apple's software
# renderer with the patched with_gl_view_ctx(), no VM needed.
cocoa_view_flush_patch="$native_dir/patches/qemu-cocoa-gl-view-flush.patch"
cocoa_view_flush_patch_sha256=cf979033b462b39ed264c4899d2711f63674ae61ad091a3933832439fd3c285c
verify_file_sha "QEMU Cocoa view-context flush" \
  "$cocoa_view_flush_patch" "$cocoa_view_flush_patch_sha256"
patch -d "$source_dir" -p1 -f -i "$cocoa_view_flush_patch"
display_tests="$work_dir/display-tests"
mkdir -p "$display_tests"
awk '/^static void with_gl_view_ctx\(CodeBlock block\)$/,/^}$/' "$source_dir/ui/cocoa.m" \
  > "$display_tests/with-gl-view-ctx.inc"
grep -q 'glFlush();' "$display_tests/with-gl-view-ctx.inc" || \
  die "with_gl_view_ctx() in ui/cocoa.m has no glFlush (view-context flush patch)"
cc -fblocks -Wall -Werror -Wno-deprecated-declarations -I"$display_tests" \
  "$native_dir/Tests/display/test-gl-view-flush.c" -framework OpenGL \
  -o "$display_tests/test-gl-view-flush"
"$display_tests/test-gl-view-flush"
# OmacVM: 2D resources (the guest's dumb buffers: console, plymouth, dumb
# screens and cursors) are made with the SCANOUT bind, so the guest memory
# budget's display reserve covers them (test-resource-budget checks the reserve
# with this bind).
virgl_2d_scanout_patch="$native_dir/patches/qemu-virgl-2d-resource-scanout.patch"
virgl_2d_scanout_patch_sha256=24bbe264116db2cea635ba3c1218ec5bcd3a2a1db1cc5cb508f2918528aaec0a
verify_file_sha "QEMU virgl 2D resources as screens" \
  "$virgl_2d_scanout_patch" "$virgl_2d_scanout_patch_sha256"
patch -d "$source_dir" -p1 -f -i "$virgl_2d_scanout_patch"
grep -q 'args.bind = (1 << 1) | (1 << 18);' "$source_dir/hw/display/virtio-gpu-virgl.c" || \
  die "virgl_cmd_create_resource_2d does not make 2D resources as screens"
# OmacVM GPU (docs/architecture/graphics.md): fences reported by virglrenderer's
# sync thread (no 1 ms polling); blobs on 16 KiB host pages, so Venus memory
# maps into the guest; frames shown when the guest flushes, as IOSurfaces.
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/qemu-cocoa-gl-async-fence.patch"
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/qemu-virtio-gpu-blob-alignment.patch"
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/qemu-cocoa-gl-present-on-flush.patch"
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/qemu-cocoa-gl-present-iosurface.patch"
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/qemu-hvf-virgl-blob-subregion.patch"
# OmacVM: a small high PCI window right above RAM (highmem-mmio-size from
# 1 GiB), so M1/M2 (36-bit VM address space) get a Venus window of 1 GB and more.
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/qemu-virt-small-high-window.patch"
grep -q 'highmem-mmio-size cannot be smaller than 1 GiB' "$source_dir/hw/arm/virt.c" || \
  die "hw/arm/virt.c does not take a small highmem-mmio-size"
# Frames on the display's refresh: one per refresh, no judder.
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/qemu-cocoa-gl-present-vsync.patch"
# Colour-space tagged frames; 10-bit scanouts in half float; HDR (PQ) with EDR.
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/qemu-cocoa-gl-present-color.patch"
# macOS's own shortcuts go to the VM while it has the keyboard (and its logic's test).
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-shortcuts-logic.patch"
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-system-shortcuts.patch"
"$native_dir/Tests/keys/test-shortcuts.sh"
# Keys OmacVM's helpers post for macOS (the escape combo's Space shortcut) skip the guest.
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-keys-for-macos.patch"
grep -q 'if (omacvm_key_for_macos(event))' "$source_dir/ui/cocoa.m" || \
  die "ui/cocoa.m does not pass OmacVM's marked keys to macOS (keys-for-macos patch)"
# The escape combo passes QEMU's full-grab tap, so OmacVM Gestures gets it in any tap order.
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-escape-combo-tap.patch"
grep -q 'flags & kCGEventFlagMaskCommand, flags & kCGEventFlagMaskShift)) {' "$source_dir/ui/cocoa.m" || \
  die "ui/cocoa.m's event tap does not let the escape combo through (escape-combo-tap patch)"
# The VM's window takes the pointer without a click; the Mac's cursor hides only
# once the guest draws its own (and the logic's test).
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-pointer-start-logic.patch"
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-pointer-start.patch"
"$native_dir/Tests/display/test-pointer-start.sh"
grep -q 'omacvmTakePointer:event why:"motion over the VM"' "$source_dir/ui/cocoa.m" || \
  die "ui/cocoa.m does not take the pointer on motion (pointer-start patch)"
# Idle power: the refresh tick slows to 500 ms while it has nothing to do.
# Its rate logic, taken from the patched ui/cocoa.m, is tested on its own.
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/qemu-cocoa-idle-refresh.patch"
awk '/^#define COCOA_REFRESH_SLOW_MS/{f=1} f{print}
     f&&/^static void cocoa_refresh_tick\(bool pending\)$/{t=1} t&&/^}$/{exit}' \
  "$source_dir/ui/cocoa.m" > "$display_tests/idle-refresh.inc"
grep -q '^static void cocoa_refresh_tick(bool pending)$' "$display_tests/idle-refresh.inc" || \
  die "ui/cocoa.m has no cocoa_refresh_tick() (idle refresh patch)"
cc -Wall -Werror -I"$display_tests" "$native_dir/Tests/display/test-idle-refresh.c" \
  -o "$display_tests/test-idle-refresh"
"$display_tests/test-idle-refresh"
OMACVM_IDLE_REFRESH=0 "$display_tests/test-idle-refresh" off
# OmacVM: VM memory and graphics memory in the app menu (read when it opens).
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-graphics-memory.patch"
"$native_dir/Tests/display/test-gpu-memory-menu.sh"
# OmacVM: "Features…" in the app menu: the launcher opens the control centre
# in the VM (ControlCentreRoute.swift, src/control/guest/open.sh).
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-features-menu.patch"
grep -q '^    omacvm_add_features_item(menu);$' "$source_dir/ui/cocoa.m" || \
  die "ui/cocoa.m has no Features... item in the app menu (features-menu patch)"
# OmacVM: "Restart the Desktop…" in the app menu after Later on the app's
# "desktop stopped drawing" window (shown in the memory menu's update).
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-restart-desktop.patch"
"$native_dir/Tests/display/test-restart-desktop.sh"
grep -q '^    omacvm_restart_desktop_update();$' "$source_dir/ui/cocoa.m" || \
  die "ui/cocoa.m does not update Restart the Desktop when the menu opens (restart-desktop patch)"
# OmacVM: the start animation (OMACVM becomes Omarchy's logo), then Omarchy's
# logo until the guest's desktop, and instead of "Display output is not
# active."; the cells must be the firmware's logo, the animation's table the
# generator's, and its core must keep its timeline and tell the desktop apart.
# After the GPU present patches: it draws the still logo in their IOSurfaces too.
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-boot-splash.patch"
python3 "$native_dir/Tests/display/test-boot-splash-cells.py" "$source_dir/ui/omacvm-splash.h" || \
  die "the boot splash's logo is not the firmware's (test-boot-splash-cells.py)"
python3 "$native_dir/boot-logo/make-splash-morph.py" --check "$source_dir/ui/omacvm-splash.h" || \
  die "the start animation's table is not make-splash-morph.py's"
cc -Wall -Wextra -Werror -I"$source_dir/ui" "$native_dir/Tests/display/test-boot-splash-morph.c" \
  -o "$display_tests/test-boot-splash-morph"
"$display_tests/test-boot-splash-morph"
# The logo layer's fade into the desktop runs once ("opacity" in its no-action list).
awk '/NSDictionary \*none = @\{/ { on = 1 } on { print } on && /\};$/ { exit }' "$source_dir/ui/cocoa.m" |
  sed -e 's/.*NSDictionary \*none = //' -e 's/};$/}/' > "$display_tests/intro-actions.inc"
cc -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations -I"$display_tests" \
  "$native_dir/Tests/display/test-boot-splash-fade.m" -framework Foundation -framework QuartzCore \
  -framework OpenGL -o "$display_tests/test-boot-splash-fade"
"$display_tests/test-boot-splash-fade"
# OmacVM: full screen is always macOS's own, in a Space of its own (beside the
# notch too: Omanotch fills the strip); a display the escape combo moved off
# the VM's Space is not pulled back by the VM's other window.
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-fullscreen-own-space.patch"
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-head-key-same-space.patch"
"$native_dir/Tests/display/test-fullscreen-space.sh" "$source_dir/ui/cocoa.m" || \
  die "ui/cocoa.m: full screen without a Space of its own (test-fullscreen-space.sh)"
# OmacVM: no events into QEMU once the display is cleaned up (the crash on
# Quit/shutdown); a full-screen start shows nothing until it is there.
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-shutdown-events.patch"
"$native_dir/Tests/display/test-shutdown-events.sh" "$source_dir/ui/cocoa.m" || \
  die "ui/cocoa.m: events into QEMU after the display's cleanup (test-shutdown-events.sh)"
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-fullscreen-start.patch"
"$native_dir/Tests/display/test-fullscreen-start.sh" "$source_dir/ui/cocoa.m" || \
  die "ui/cocoa.m: a full-screen start shows its windowed frame (test-fullscreen-start.sh)"
# Experimental: the guest's pointer as the Mac's cursor (OMACVM_HW_CURSOR=1, the
# app's hidden macPointer setting), and its rules' test.
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-hw-cursor-logic.patch"
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-hw-cursor.patch"
"$native_dir/Tests/display/test-hw-cursor.sh"
grep -q 'omacvm_hwc_take(0, qemu_console_get_cursor(dcl->con), cocoaView,' "$source_dir/ui/cocoa.m" || \
  die "ui/cocoa.m does not hand the guest's pointer image to the Mac's cursor (hw-cursor patch)"
# Opt-in (OMACVM_GL_INPUT_FIRST=1): while input comes, the newest frame goes on screen.
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/qemu-cocoa-gl-present-input-first.patch"
# The globe key on its own goes to the VM (not Emoji & Symbols) while it has the keyboard.
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-globe-key.patch"
grep -q '^    omacvm_globe_init();$' "$source_dir/ui/cocoa.m" && grep -q 'if (omacvm_globe_event(event)) {' "$source_dir/ui/cocoa.m" || \
  die "ui/cocoa.m does not hand the globe key to the VM (globe-key patch)"
# OmacVM: no quit when AppKit's last window goes (a hidden full-screen run quit
# after a minute); a quit while the guest starts presses the power button again.
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-quit-clean.patch"
"$native_dir/Tests/display/test-quit-clean.sh" "$source_dir/ui/cocoa.m" || \
  die "ui/cocoa.m: quits by itself or presses the power button once (test-quit-clean.sh)"
# OmacVM: guest sizes that fit Omarchy's scale presets (full screen a few
# rows shorter, black at the bottom of a window that still fills the area,
# so Omanotch finds it; a window in 20 point steps); last of the cocoa
# patches, and its logic's test.
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-clean-size-logic.patch"
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-clean-size.patch"
"$native_dir/Tests/display/test-clean-size.sh"
grep -q 'OmacVMSize clean = omacvm_clean_size(' "$source_dir/ui/cocoa.m" || \
  die "ui/cocoa.m does not size the guest for Omarchy's scales (clean-size patch)"
grep -q '\[\[self window\] setContentSize:area\];' "$source_dir/ui/cocoa.m" || \
  die "ui/cocoa.m: the full-screen window must fill the area (Omanotch), clean-size patch"
grep -q 'full = isFullscreen && omacvm_present_layer() &&' "$source_dir/ui/cocoa.m" || \
  die "ui/cocoa.m: rows may be cut only with the IOSurface layer below a notch, clean-size patch"
# Touch ID's panel in the VM window's own process (OmacVM.app's dylib, ADR 0041).
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-touchid-panel.patch"
grep -q 'dlsym(handle, "omacvm_touchid_panel_start")' "$source_dir/ui/cocoa.m" || \
  die "ui/cocoa.m does not load the Touch ID panel (touchid-panel patch)"
# Accessibility taken away: the full-grab tap goes at once, never enabled again
# (issue #192: enabling it again held the Mac's keys).
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-tap-permission.patch"
"$native_dir/Tests/keys/test-tap-permission.sh" "$source_dir/ui/cocoa.m" || \
  die "ui/cocoa.m: the full-grab tap stays without Accessibility (test-tap-permission.sh)"
# A borderless window (the tests' full screen) has no shadow, so macOS 26 draws
# no light rim around the display; windowed again with its shadow.
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/omacvm-cocoa-borderless-no-rim.patch"
"$native_dir/Tests/display/test-borderless-rim.sh" "$source_dir/ui/cocoa.m" || \
  die "ui/cocoa.m: a borderless window keeps its shadow and macOS 26's rim (test-borderless-rim.sh)"
# OmacVM: held fences (virgl-fence-flush-on-need.patch) go to the GPU before every
# command that is not a command buffer and when the command queue ends.
patch -d "$source_dir" -p1 -f -i "$native_dir/patches/qemu-virtio-gpu-fence-flush-on-need.patch"
"$native_dir/Tests/virgl/test-qemu-fence-flush.sh" "$source_dir/hw/display/virtio-gpu-virgl.c" || \
  die "hw/display/virtio-gpu-virgl.c: held virgl fences are not handed to the GPU (test-qemu-fence-flush.sh)"

virgl_root="$dependency_root/virglrenderer/$virgl_version"
angle_root="$dependency_root/angle/$angle_version"
epoxy_root="$dependency_root/libepoxy/$epoxy_version"
glib_root="$dependency_root/$PINNED_GLIB_ROOT"
pixman_root="$dependency_root/$PINNED_PIXMAN_ROOT"
slirp_root="$dependency_root/$PINNED_LIBSLIRP_ROOT"
libusb_root="$dependency_root/$PINNED_LIBUSB_ROOT"
sdl2_root="$dependency_root/$PINNED_SDL2_ROOT"
sdl3_root="$dependency_root/$PINNED_SDL3_ROOT"
gettext_root="$dependency_root/$PINNED_GETTEXT_ROOT"
pcre2_root="$dependency_root/$PINNED_PCRE2_ROOT"
zstd_root="$dependency_root/$PINNED_ZSTD_ROOT"
lz4_root="$dependency_root/$PINNED_LZ4_ROOT"
xz_root="$dependency_root/$PINNED_XZ_ROOT"
for directory in \
  "$angle_root" "$epoxy_root" \
  "$glib_root" "$pixman_root" "$slirp_root" "$libusb_root" "$sdl2_root" "$sdl3_root" \
  "$gettext_root" "$pcre2_root" "$zstd_root" "$lz4_root" "$xz_root"; do
  [[ -d $directory && ! -L $directory ]] || die "missing extracted dependency: $directory"
done

# Bottle pkg-config files contain Homebrew relocation placeholders. Point only
# this private build at the verified extracted headers and libraries.
sed -i '' "s|@@HOMEBREW_CELLAR@@/libepoxy/$epoxy_version|$epoxy_root|g" \
  "$epoxy_root/lib/pkgconfig/epoxy.pc"
for pc_file in "$angle_root"/lib/pkgconfig/*.pc; do
  sed -i '' "s|^prefix=/opt/homebrew$|prefix=$angle_root|" "$pc_file"
done

for pc_file in "$glib_root"/lib/pkgconfig/*.pc; do
  sed -i '' \
    -e "s|@@HOMEBREW_CELLAR@@/$PINNED_GLIB_ROOT|$glib_root|g" \
    -e "s|@@HOMEBREW_PREFIX@@/opt/gettext|$gettext_root|g" \
    "$pc_file"
done
for pc_file in "$pixman_root"/lib/pkgconfig/*.pc; do
  sed -i '' "s|@@HOMEBREW_CELLAR@@/$PINNED_PIXMAN_ROOT|$pixman_root|g" "$pc_file"
done
for pc_file in "$slirp_root"/lib/pkgconfig/*.pc; do
  sed -i '' "s|@@HOMEBREW_CELLAR@@/$PINNED_LIBSLIRP_ROOT|$slirp_root|g" "$pc_file"
done
for pc_file in "$pcre2_root"/lib/pkgconfig/*.pc; do
  sed -i '' "s|@@HOMEBREW_CELLAR@@/$PINNED_PCRE2_ROOT|$pcre2_root|g" "$pc_file"
done
for pc_file in "$libusb_root"/lib/pkgconfig/*.pc; do
  sed -i '' "s|@@HOMEBREW_CELLAR@@/$PINNED_LIBUSB_ROOT|$libusb_root|g" "$pc_file"
done
sed -i '' \
  -e "s|^prefix=@@HOMEBREW_PREFIX@@$|prefix=$sdl2_root|" \
  -e "s|^libdir=@@HOMEBREW_PREFIX@@/lib$|libdir=$sdl2_root/lib|" \
  -e "s|^includedir=@@HOMEBREW_PREFIX@@/include$|includedir=$sdl2_root/include|" \
  "$sdl2_root/lib/pkgconfig/sdl2-compat.pc"

# sdl2-compat loads SDL3 by this exact @loader_path name. Keeping a private
# build-time copy beside SDL2 also makes any configure probes independent of
# globally installed libraries.
install -m 0755 "$sdl3_root/lib/libSDL3.0.dylib" "$sdl2_root/lib/libSDL3.dylib"

ditto -x -k "$ninja_archive" "$tool_root"
ninja="$tool_root/ninja-$ninja_version.data/scripts/ninja"
[[ -f $ninja && ! -L $ninja ]] || die "pinned Ninja wheel is missing its executable"
chmod 0755 "$ninja"

pkg_config_libdir="$virgl_root/lib/pkgconfig:$epoxy_root/lib/pkgconfig:$angle_root/lib/pkgconfig:$glib_root/lib/pkgconfig:$pixman_root/lib/pkgconfig:$slirp_root/lib/pkgconfig:$sdl2_root/lib/pkgconfig:$pcre2_root/lib/pkgconfig:$libusb_root/lib/pkgconfig"
private_libraries="$virgl_root/lib:$epoxy_root/lib:$angle_root/lib:$glib_root/lib:$pixman_root/lib:$slirp_root/lib:$sdl2_root/lib:$gettext_root/lib:$pcre2_root/lib:$libusb_root/lib"

require_private_pkg_version() {
  local package=$1
  local expected=$2
  local actual

  actual=$(env PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$pkg_config_libdir" \
    pkg-config --modversion "$package" 2>/dev/null) || \
    die "private dependency set is missing pkg-config dependency: $package $expected"
  [[ $actual == "$expected" ]] || \
    die "$package version mismatch: expected $expected, got $actual"
}

require_private_pkg_version glib-2.0 2.88.3
require_private_pkg_version pixman-1 0.46.4
require_private_pkg_version slirp 4.9.4
require_private_pkg_version sdl2 2.32.70
require_private_pkg_version epoxy 1.5.11
require_private_pkg_version libusb-1.0 1.0.30

# Keep the exact graphics fixes, including GLES dual-source output for Alacritty.
virgl_source="$source_parent/$virgl_source_root"
virgl_tap="$source_parent/$virgl_tap_root"
virgl_patches=(
  virglrenderer-debug-init-logging.patch
  virglrenderer-default-debug-log.patch
  virglrenderer-macos-unified.patch
  virglrenderer-venus-metal-func-ptrs.patch
  virglrenderer-gallium-endian.patch
  virglrenderer-macos-a8-swizzle.patch
  virglrenderer-corefoundation-link.patch
  virglrenderer-a8-shader-swizzle.patch
  virglrenderer-a8-shader-swizzle-texture.patch
  virglrenderer-a8-unpack-alignment.patch
  virglrenderer-bgra-upload-swizzle-core.patch
  virglrenderer-msaa-assertion-fix.patch
  virglrenderer-ignore-surface0-clear.patch
  virglrenderer-venus-errno-debug.patch
  virglrenderer-macos-profile-forcing.patch
  virglrenderer-macos-egl-profile.patch
  virglrenderer-texture-swizzle-core.patch
  virglrenderer-bgra-unified.patch
  virglrenderer-core-profile-frag-datalocation.patch
  virglrenderer-macos-core-profile-fixes.patch
  virglrenderer-gles-dual-source-output.patch
)
for virgl_patch in "${virgl_patches[@]}"; do
  patch -d "$virgl_source" -p1 -f -i "$virgl_tap/patches/$virgl_patch"
done
verify_file_sha "Native OpenGL browser compatibility patch" "$virgl_native_patch" "$virgl_native_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_native_patch"
# OmacVM: texture() on an integer sampler (usampler2D, isampler2D) gave a vec4 that the
# shader then could not convert: the host's GL refused the shader and the guest's
# GL context stopped for good (Chrome's GPU process hung in Basemark Web 3.0).
verify_file_sha "Integer sampler shader patch" "$virgl_int_tex_patch" "$virgl_int_tex_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_int_tex_patch"
# Video decode on the Mac's media engine: guest VA-API -> VideoToolbox.
verify_file_sha "VideoToolbox video decode patch" "$virgl_videotoolbox_patch" "$virgl_videotoolbox_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_videotoolbox_patch"
# No texture transfer moves more bytes per row in GL than the guest's buffers hold.
verify_file_sha "Transfer row size patch" "$virgl_row_size_patch" "$virgl_row_size_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_row_size_patch"
# Video encode (H.264, HEVC) on the Mac's media engine: guest VA-API -> VTCompressionSession.
verify_file_sha "VideoToolbox video encode patch" "$virgl_vt_encode_patch" "$virgl_vt_encode_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_vt_encode_patch"
# OmacVM: a shader the Mac's GL refuses skips its draws instead of stopping the guest's
# whole context, and a context that does stop tells the guest (GL context reset).
verify_file_sha "Refused shader patch" "$virgl_skip_draws_patch" "$virgl_skip_draws_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_skip_draws_patch"
verify_file_sha "Context loss report patch" "$virgl_loss_report_patch" "$virgl_loss_report_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_loss_report_patch"
# OmacVM: two guest inputs the fuzzer found that crashed QEMU or asked for 4 GiB.
verify_file_sha "Shader variant NULL checks" "$virgl_null_variant_patch" "$virgl_null_variant_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_null_variant_patch"
verify_file_sha "Shader size limits" "$virgl_shader_limits_patch" "$virgl_shader_limits_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_shader_limits_patch"
# OmacVM: a Venus context the render server ended no longer leaves the guest waiting
# on fences forever.
verify_file_sha "Venus lost context fences" "$virgl_venus_lost_patch" "$virgl_venus_lost_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_venus_lost_patch"
# OmacVM: shaders reading gl_InstanceID (instanced WebGL) compile on Apple's core profile.
verify_file_sha "Core gl_InstanceID patch" "$virgl_instance_id_patch" "$virgl_instance_id_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_instance_id_patch"
# OmacVM: transform feedback ends with its own program bound (a guest could crash
# QEMU in Apple's glEndTransformFeedback).
verify_file_sha "Transform feedback end patch" "$virgl_xfb_end_patch" "$virgl_xfb_end_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_xfb_end_patch"
# OmacVM: stream output registers from the guest are checked (the fuzzer aborted QEMU).
verify_file_sha "Stream output checks patch" "$virgl_so_checks_patch" "$virgl_so_checks_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_so_checks_patch"
# OmacVM: a GL error after a guest command no longer stops the context.
verify_file_sha "GL error skip patch" "$virgl_gl_error_patch" "$virgl_gl_error_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_gl_error_patch"
# OmacVM: the guest must not make the Mac's GPU read or write outside a buffer (a GPU
# fault resets the GPU; on 2026-10-04 that panicked macOS). Buffer bindings, draw
# ranges and uniform blocks are checked before any GL call.
verify_file_sha "Buffer binding checks" "$virgl_buffer_checks_patch" "$virgl_buffer_checks_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_buffer_checks_patch"
verify_file_sha "Draw range checks" "$virgl_draw_checks_patch" "$virgl_draw_checks_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_draw_checks_patch"
verify_file_sha "Uniform buffer checks" "$virgl_ubo_checks_patch" "$virgl_ubo_checks_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_ubo_checks_patch"
# OmacVM: array indexes a guest shader computes stay inside their arrays.
verify_file_sha "Shader index clamp" "$virgl_index_clamp_patch" "$virgl_index_clamp_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_index_clamp_patch"
# OmacVM: a GL call the Mac's GL refuses keeps older state the checks above never saw.
# Vertex formats and buffer offsets the GL would refuse are refused first, uniform block
# arrays are bound as declared, and a GL error while a draw is set up skips the draw.
verify_file_sha "Vertex format checks" "$virgl_vertex_format_patch" "$virgl_vertex_format_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_vertex_format_patch"
verify_file_sha "Uniform buffer alignment" "$virgl_ubo_align_patch" "$virgl_ubo_align_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_ubo_align_patch"
verify_file_sha "Uniform block arrays" "$virgl_block_array_patch" "$virgl_block_array_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_block_array_patch"
verify_file_sha "Draw GL error check" "$virgl_draw_error_patch" "$virgl_draw_error_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_draw_error_patch"
verify_file_sha "Unused first vertex input" "$virgl_vertex_unused_patch" "$virgl_vertex_unused_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_vertex_unused_patch"
# OmacVM: guest resources have a memory budget against a runaway guest (OMACVM_GPU_MEMORY_MB, default
# three quarters of the Mac's memory); below it virgl-darwin-memory-pressure.patch asks macOS.
verify_file_sha "Resource memory budget" "$virgl_memory_budget_patch" "$virgl_memory_budget_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_memory_budget_patch"
# OmacVM: QEMU's resource and transfer commands are flushed (Apple's GL keeps unflushed texture memory).
verify_file_sha "Control queue flush" "$virgl_queue_flush_patch" "$virgl_queue_flush_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_queue_flush_patch"
# OmacVM: Venus devices always get robust buffer access where the host device has it.
verify_file_sha "Venus robust buffer access" "$virgl_venus_robust_patch" "$virgl_venus_robust_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_venus_robust_patch"
# OmacVM: a resource the budget refused loses (and tells) the context that made it.
verify_file_sha "Budget context loss" "$virgl_budget_loss_patch" "$virgl_budget_loss_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_budget_loss_patch"
# OmacVM: Venus device memory and shm blobs count against the same budget.
verify_file_sha "Venus memory budget" "$virgl_venus_budget_patch" "$virgl_venus_budget_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_venus_budget_patch"
# Test runtimes only (tests/graphics/context-loss.sh): refuse marked shaders on demand.
if [[ ${OMACVM_RUNTIME_TEST_HOOKS:-} == 1 ]]; then
  log "Adding the test-only shader fault hook (OMACVM_RUNTIME_TEST_HOOKS=1)"
  verify_file_sha "Shader fault test hook" "$virgl_test_fault_patch" "$virgl_test_fault_patch_sha256"
  patch -d "$virgl_source" -p1 -f -i "$virgl_test_fault_patch"
fi
# OmacVM GPU: eventfd for the sync thread on macOS; Venus render server in process.
patch -d "$virgl_source" -p1 -f -i "$native_dir/patches/virgl-darwin-thread-sync.patch"
patch -d "$virgl_source" -p1 -f -i "$native_dir/patches/virgl-darwin-fence-wait.patch"
patch -d "$virgl_source" -p1 -f -i "$native_dir/patches/virgl-darwin-venus-in-process.patch"
patch -d "$virgl_source" -p1 -f -i "$native_dir/patches/virgl-fence-waiting-ctx.patch"
# OmacVM GPU: fences are polled when the sync thread cannot start.
patch -d "$virgl_source" -p1 -f -i "$native_dir/patches/virgl-thread-sync-fallback.patch"
# OmacVM Venus: the Vulkan loader and driver come from the app's runtime.
patch -d "$virgl_source" -p1 -f -i "$native_dir/patches/virgl-darwin-vulkan-beside.patch"
patch -d "$virgl_source" -p1 -f -i "$native_dir/patches/virgl-darwin-stream-sockets.patch"
patch -d "$virgl_source" -p1 -f -i "$native_dir/patches/virgl-darwin-venus-heap-check.patch"
patch -d "$virgl_source" -p1 -f -i "$native_dir/patches/virgl-darwin-venus-metal-entrypoints.patch"
patch -d "$virgl_source" -p1 -f -i "$native_dir/patches/virgl-darwin-venus-ext-table.patch"
patch -d "$virgl_source" -p1 -f -i "$native_dir/patches/virgl-darwin-venus-host-pages.patch"
# OmacVM Venus: a KosmicKrisp without a usable device falls back to MoltenVK.
patch -d "$virgl_source" -p1 -f -i "$native_dir/patches/virgl-darwin-kosmickrisp-fallback.patch"
# OmacVM: where virglrenderer and Apple's core profile disagree (ADR 0019). Each gap made
# one shader or draw stop the guest's whole GL context: the app drew black from then on.
verify_file_sha "Core profile GLSL version patch" "$virgl_shader_core_glsl_version_patch" "$virgl_shader_core_glsl_version_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_shader_core_glsl_version_patch"
verify_file_sha "Shadow lod extension patch" "$virgl_shader_shadow_lod_patch" "$virgl_shader_shadow_lod_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_shader_shadow_lod_patch"
verify_file_sha "Integer outputs patch" "$virgl_shader_int_outputs_patch" "$virgl_shader_int_outputs_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_shader_int_outputs_patch"
verify_file_sha "Blitter GLSL version patch" "$virgl_blitter_core_glsl_version_patch" "$virgl_blitter_core_glsl_version_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_blitter_core_glsl_version_patch"
verify_file_sha "Blitter integer multisample patch" "$virgl_blitter_integer_msaa_patch" "$virgl_blitter_integer_msaa_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_blitter_integer_msaa_patch"
verify_file_sha "Framebuffer without attachments patch" "$virgl_framebuffer_no_attachments_patch" "$virgl_framebuffer_no_attachments_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_framebuffer_no_attachments_patch"
verify_file_sha "Sampler limit patch" "$virgl_caps_sampler_limit_patch" "$virgl_caps_sampler_limit_patch_sha256"
patch -d "$virgl_source" -p1 -f -i "$virgl_caps_sampler_limit_patch"
# OmacVM GPU: the sync thread does not test fences while the render thread runs commands.
patch -d "$virgl_source" -p1 -f -i "$native_dir/patches/virgl-darwin-fence-wait-busy.patch"
# OmacVM GPU: guest GPU memory follows the Mac's memory pressure; status file for the app.
patch -d "$virgl_source" -p1 -f -i "$native_dir/patches/virgl-darwin-memory-pressure.patch"
# OmacVM Venus: MoltenVK cannot compile zero-initialized workgroup memory.
patch -d "$virgl_source" -p1 -f -i "$native_dir/patches/virgl-darwin-venus-moltenvk-zero-init.patch"
# OmacVM: a compositor's dma-buf import (a Vulkan window) no longer ends its context on macOS OpenGL.
patch -d "$virgl_source" -p1 -f -i "$native_dir/patches/virgl-set-type-without-egl.patch"
# OmacVM: a draw binds its GL program only when it changed (Apple's GL rebuilds its draw state
# on every glUseProgram; WebGL pages with one draw per object paid that on each draw).
patch -d "$virgl_source" -p1 -f -i "$native_dir/patches/virgl-use-program-cache.patch"
# OmacVM: a fence's glFlush (which ends Apple's Metal render pass) only when something
# needs the work: another GL context, QEMU between commands, or the fence is 2 ms old.
patch -d "$virgl_source" -p1 -f -i "$native_dir/patches/virgl-fence-flush-on-need.patch"
virgl_build="$virgl_source/build"
meson="$tool_root/$meson_root/meson.py"
# Optimize the graphics command path while retaining assertions and diagnostics.
log "Building optimized patched VirGL 1.3.0 for macOS $macos_deployment_target"
env MACOSX_DEPLOYMENT_TARGET="$macos_deployment_target" \
  PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$pkg_config_libdir" \
  DYLD_LIBRARY_PATH="$private_libraries" \
  PATH="$(dirname "$ninja"):$PATH" \
  CFLAGS="-I$angle_root/include -mmacosx-version-min=$macos_deployment_target -Werror=unguarded-availability-new" \
  OBJCFLAGS="-mmacosx-version-min=$macos_deployment_target -Werror=unguarded-availability-new" \
  LDFLAGS="-mmacosx-version-min=$macos_deployment_target -Wl,-headerpad_max_install_names" \
  python3 "$meson" setup "$virgl_build" "$virgl_source" \
    --prefix="$virgl_root" --libdir=lib --buildtype=debugoptimized -Db_ndebug=false --wrap-mode=nodownload \
    -Ddrm-renderers=[] -Dvenus=true -Drender-server-worker=thread -Dtests=false -Dvideo=true -Dtracing=none
"$ninja" ${ninja_jobs[@]+"${ninja_jobs[@]}"} -C "$virgl_build"
# These test the actual shader generator and blend-state transitions, without a VM.
env DYLD_LIBRARY_PATH="$private_libraries" \
  python3 "$virgl_tap/tests/run-driver-regressions.py" \
    "$virgl_build" "$work_dir/virgl-regressions" -- \
    "-L$epoxy_root/lib" -lepoxy \
    -framework Metal -framework CoreFoundation -lobjc \
    -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework OpenGL -framework IOSurface \
    "-Wl,-rpath,$epoxy_root/lib" "-Wl,-rpath,$angle_root/lib"
# Probe real format-selection code with controlled GL availability and failures.
env DYLD_LIBRARY_PATH="$private_libraries" \
  python3 "$native_dir/Tests/virgl/run-regressions.py" \
    "$virgl_build" "$work_dir/virgl-regressions" -- \
    "-L$epoxy_root/lib" -lepoxy \
    -framework Metal -framework CoreFoundation -lobjc \
    -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework OpenGL -framework IOSurface \
    "-Wl,-rpath,$epoxy_root/lib" "-Wl,-rpath,$angle_root/lib"
python3 "$meson" install -C "$virgl_build" --no-rebuild
require_private_pkg_version virglrenderer 1.3.0

# Build against the same pinned private GLib used by QEMU; never use host libraries.
slirp_build="$source_parent/$slirp_source_root/build"
meson="$tool_root/$meson_root/meson.py"
log "Building patched libslirp 4.9.4 for macOS $macos_deployment_target"
env MACOSX_DEPLOYMENT_TARGET="$macos_deployment_target" \
  PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$pkg_config_libdir" \
  DYLD_LIBRARY_PATH="$private_libraries" \
  PATH="$(dirname "$ninja"):$PATH" \
  CFLAGS="-mmacosx-version-min=$macos_deployment_target -Werror=unguarded-availability-new" \
  LDFLAGS="-mmacosx-version-min=$macos_deployment_target -Wl,-headerpad_max_install_names" \
  python3 "$meson" setup "$slirp_build" "$source_parent/$slirp_source_root" \
    --prefix="$slirp_root" --libdir=lib --buildtype=release --wrap-mode=nodownload
"$ninja" ${ninja_jobs[@]+"${ninja_jobs[@]}"} -C "$slirp_build"
# The explicit build above completed the test binaries using our private Ninja.
env DYLD_LIBRARY_PATH="$slirp_build:$private_libraries" \
  python3 "$meson" test -C "$slirp_build" --no-rebuild --print-errorlogs
python3 "$meson" install -C "$slirp_build" --no-rebuild

build_dir="$source_dir/build"
mkdir "$build_dir"
log "Configuring QEMU 11.1.1 (HVF-only, Cocoa/VirGL, SLIRP, SDL audio, virtio-9p, libusb) for macOS $macos_deployment_target and newer"
(
  cd "$build_dir"
  env MACOSX_DEPLOYMENT_TARGET="$macos_deployment_target" \
    PKG_CONFIG_PATH= \
    PKG_CONFIG_LIBDIR="$pkg_config_libdir" \
    DYLD_LIBRARY_PATH="$private_libraries" \
    DYLD_FALLBACK_LIBRARY_PATH="$private_libraries" \
    ../configure \
      --prefix="$work_dir/install" \
      --target-list=aarch64-softmmu \
      --without-default-features \
      --enable-system \
      --enable-hvf \
      --disable-tcg \
      --enable-cocoa \
      --enable-opengl \
      --enable-virglrenderer \
      --enable-pixman \
      --enable-slirp \
      --enable-fdt=internal \
      --enable-sdl \
      --audio-drv-list=sdl \
      --enable-virtfs \
      --enable-libusb \
      --disable-debug-info \
      --disable-werror \
      --disable-download \
      --disable-containers \
      --container-command=false \
      --extra-cflags="-mmacosx-version-min=$macos_deployment_target -Werror=unguarded-availability-new" \
      --extra-ldflags="-mmacosx-version-min=$macos_deployment_target" \
      --ninja="$ninja"
)

config_host="$build_dir/config-host.h"
[[ -f $config_host && ! -L $config_host ]] || die "QEMU configure did not create config-host.h"
if grep -Eq '^[[:space:]]*#define[[:space:]]+HAVE_STRCHRNUL([[:space:]]+1)?[[:space:]]*$' \
  "$config_host"; then
  die "QEMU incorrectly enabled the macOS 15.4-only strchrnul API"
fi
python3 - \
  "$build_dir/compile_commands.json" \
  "-mmacosx-version-min=$macos_deployment_target" \
  '-Werror=unguarded-availability-new' <<'PY'
import json
import shlex
import sys

path, deployment_flag, availability_flag = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as source:
        commands = json.load(source)
except (OSError, UnicodeError, json.JSONDecodeError) as error:
    raise SystemExit(f"qemu-source-build: cannot audit compile commands: {error}")
if not isinstance(commands, list) or not commands:
    raise SystemExit("qemu-source-build: compile command database is empty")
missing = []
for record in commands:
    if not isinstance(record, dict):
        missing.append("<invalid record>")
        continue
    arguments = record.get("arguments")
    if not isinstance(arguments, list):
        command = record.get("command")
        arguments = shlex.split(command) if isinstance(command, str) else []
    if deployment_flag not in arguments or availability_flag not in arguments:
        missing.append(str(record.get("file", "<unknown source>")))
if missing:
    examples = ", ".join(missing[:5])
    raise SystemExit(
        f"qemu-source-build: compatibility flags are missing from "
        f"{len(missing)} compile commands ({examples})"
    )
print(f"[qemu-source-build] Audited compatibility flags in {len(commands)} compile commands")
PY

log "Building qemu-system-aarch64"
env MACOSX_DEPLOYMENT_TARGET="$macos_deployment_target" \
  PKG_CONFIG_PATH= \
  PKG_CONFIG_LIBDIR="$pkg_config_libdir" \
  DYLD_LIBRARY_PATH="$private_libraries" \
  DYLD_FALLBACK_LIBRARY_PATH="$private_libraries" \
  "$ninja" ${ninja_jobs[@]+"${ninja_jobs[@]}"} -C "$build_dir" qemu-system-aarch64

qemu_binary="$build_dir/qemu-system-aarch64"
description=$(file -b "$qemu_binary")
[[ $description == *Mach-O* && $description == *arm64* ]] || \
  die "source build did not produce an arm64 Mach-O QEMU binary"

# OmacVM: the UEFI firmware (edk2) and its licence notes, for booting an
# installed system through GRUB. Our own build of the edk2 QEMU ships, with
# QEMU's flags and Omarchy's boot logo (build-edk2.sh); QEMU's prebuilt one
# (TianoCore logo) with OMACVM_FIRMWARE=qemu, or when our build or its boot
# test fails. .build/firmware/firmware-source says which one it is.
firmware_dir="$native_dir/.build/firmware"
rm -rf "$firmware_dir"; mkdir -p "$firmware_dir"
install -m 0644 "$source_dir/pc-bios/edk2-licenses.txt" "$firmware_dir/edk2-licenses.txt"
firmware=${OMACVM_FIRMWARE:-omacvm}
[[ $firmware == omacvm || $firmware == qemu ]] || die "OMACVM_FIRMWARE must be omacvm or qemu"
edk2_out="$work_dir/edk2"
if [[ $firmware == omacvm ]] && ! "$native_dir/build-edk2.sh" --qemu-source "$source_dir" --out "$edk2_out"; then
  log "The edk2 build failed: using QEMU's prebuilt firmware (TianoCore logo)"
  firmware=qemu
fi

kosmickrisp_args=()
if ((with_kosmickrisp)); then
  if [[ -n ${OMACVM_KOSMICKRISP_FROM:-} ]]; then
    "$native_dir/import-kosmickrisp.sh" "$OMACVM_KOSMICKRISP_FROM"
  else
    "$native_dir/build-kosmickrisp.sh" ${archive_cache:+--archive-dir "$archive_cache"}
  fi
  kosmickrisp_args=(--source-kosmickrisp "$native_dir/.build/kosmickrisp/libvulkan_kosmickrisp.dylib")
fi

log "Relocating, capability-gating, signing, and publishing the runtime"
"$prepare_runtime" \
  --source-qemu "$qemu_binary" \
  --source-slirp "$slirp_root/lib/libslirp.0.dylib" \
  --source-virgl "$virgl_root/lib/libvirglrenderer.1.dylib" \
  ${kosmickrisp_args[@]+"${kosmickrisp_args[@]}"} \
  --archive-dir "$archive_dir"

# A stalled UDP send on the Mac must not freeze the VM, and the stall
# watchdog must name the place (an idle QEMU without guest, a few seconds).
"$native_dir/Tests/net/test-slirp-udp-stall.sh" \
  "$native_dir/.build/qemu-gpu-runtime/bin/qemu-system-aarch64" || \
  die "the slirp UDP stall test failed"

# The firmware must show the logo and name the disk's boot entry as QEMU's
# does, with the QEMU it ships with (Tests/firmware/test-firmware.py).
if [[ $firmware == omacvm ]]; then
  if python3 "$native_dir/Tests/firmware/test-firmware.py" \
      "$native_dir/.build/qemu-gpu-runtime/bin/qemu-system-aarch64" \
      "$edk2_out/edk2-aarch64-code.fd" "$edk2_out/Logo.bmp"; then
    install -m 0644 "$edk2_out/edk2-aarch64-code.fd" "$firmware_dir/"
    echo "omacvm edk2-stable202408-omacvm (Omarchy boot logo, build-edk2.sh)" > "$firmware_dir/firmware-source"
  else
    log "The edk2 build's firmware test failed: using QEMU's prebuilt firmware (TianoCore logo)"
    firmware=qemu
  fi
fi
if [[ $firmware == qemu ]]; then
  bunzip2 -c "$source_dir/pc-bios/edk2-aarch64-code.fd.bz2" > "$firmware_dir/edk2-aarch64-code.fd"
  echo "qemu edk2-stable202408-prebuilt.qemu.org (QEMU's prebuilt, TianoCore logo)" > "$firmware_dir/firmware-source"
fi
log "Firmware: $(cat "$firmware_dir/firmware-source")"

# Mark a test runtime so build-app.sh never ships it.
if [[ ${OMACVM_RUNTIME_TEST_HOOKS:-} == 1 ]]; then
  : > "$native_dir/.build/qemu-gpu-runtime.test-hooks"
else
  rm -f "$native_dir/.build/qemu-gpu-runtime.test-hooks"
fi

log "Pinned patched runtime is ready; scratch source and archives will now be removed"
