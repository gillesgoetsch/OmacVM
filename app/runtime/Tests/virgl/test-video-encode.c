/* H.264 encoding through the VideoToolbox backend, the way the guest's VA-API driver
 * drives it: a video codec with the ENCODE entrypoint, an NV12 video buffer whose
 * planes are guest textures, then per frame BEGIN_FRAME, ENCODE_BITSTREAM (picture
 * description, coded-data buffer, feedback buffer) and END_FRAME.
 * Checks: the feedback says success with a size, the coded data is an Annex B access
 * unit, the first one starts with SPS and PPS and holds an IDR slice, later frames hold
 * slices, and the whole stream decodes again (VTDecompressionSession) to pictures close
 * to what went in (luma PSNR).
 * Runs on Apple's software OpenGL (soft-gl.h); the encoder is the Mac's media engine.
 * Skips when the Mac offers no hardware H.264 encoder.
 * OMACVM_TEST_H264_OUT=FILE also writes the stream (for ffprobe/ffplay). */
#include <CoreMedia/CoreMedia.h>
#include <OpenGL/OpenGL.h>
#include <VideoToolbox/VideoToolbox.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include "soft-gl.h"
#define VIRGL_RENDERER_UNSTABLE_APIS 1
#include "virglrenderer.h"
#include "virgl_hw.h"
#include "virgl_protocol.h"
#include "virgl_video_hw.h"

enum { W = 320, H = 240, FRAMES = 30 };
enum { TEST_PIPE_BUFFER = 0, TEST_PIPE_TEXTURE_2D = 2 };
/* guest numbering (Mesa >= 26): enum pipe_video_profile / entrypoint */
enum { G_AVC_HIGH = 11, G_ENTRYPOINT_ENCODE = 4 };
enum { PIC_P = 0, PIC_IDR = 3 };
enum { R_Y = 1, R_UV, R_DESC, R_CODED, R_FEED };

static CGLContextObj main_ctx;
static int failures;

static void check(int ok, const char *what)
{
   printf("%s: %s\n", ok ? "ok" : "FAIL", what);
   failures += !ok;
}

static void write_fence(void *cookie, uint32_t fence)
{
   (void)cookie;
   (void)fence;
}

static virgl_renderer_gl_context create_gl_context(void *cookie, int scanout,
                                                   struct virgl_renderer_gl_ctx_param *param)
{
   (void)cookie;
   (void)scanout;
   (void)param;
   /* QEMU (ui/cocoa) shares every context with its view's context. */
   return soft_gl_context(main_ctx);
}

static void destroy_gl_context(void *cookie, virgl_renderer_gl_context ctx)
{
   (void)cookie;
   CGLDestroyContext(ctx);
}

static int make_current(void *cookie, int scanout, virgl_renderer_gl_context ctx)
{
   (void)cookie;
   (void)scanout;
   return CGLSetCurrentContext(ctx) ? -1 : 0;
}

static struct virgl_renderer_callbacks callbacks = {
   .version = 1,
   .write_fence = write_fence,
   .create_gl_context = create_gl_context,
   .destroy_gl_context = destroy_gl_context,
   .make_current = make_current,
};

struct cmds {
   uint32_t dw[65536];
   unsigned n;
};

static void emit(struct cmds *c, uint32_t v)
{
   c->dw[c->n++] = v;
}

static int submit(struct cmds *c)
{
   int r = virgl_renderer_submit_cmd(c->dw, 1, c->n);
   c->n = 0;
   return r;
}

static void make_res(uint32_t handle, uint32_t target, uint32_t format, uint32_t bind,
                     uint32_t w, uint32_t h, void *backing, size_t size)
{
   struct virgl_renderer_resource_create_args a = {
      .handle = handle, .target = target, .format = format, .bind = bind,
      .width = w, .height = h, .depth = 1, .array_size = 1,
   };
   virgl_renderer_resource_create(&a, NULL, 0);
   if (backing) {
      static struct iovec iov[8];
      iov[handle] = (struct iovec){ backing, size };
      virgl_renderer_resource_attach_iov(handle, &iov[handle], 1);
   }
   virgl_renderer_ctx_attach_resource(1, handle);
}

/* plane upload: RESOURCE_INLINE_WRITE of a whole 2D level */
static void emit_plane(struct cmds *c, uint32_t handle, uint32_t w, uint32_t h, uint32_t bpp,
                       const uint8_t *data)
{
   uint32_t bytes = w * h * bpp, words = (bytes + 3) / 4;
   emit(c, VIRGL_CMD0(VIRGL_CCMD_RESOURCE_INLINE_WRITE, 0, 11 + words));
   emit(c, handle);
   emit(c, 0);
   emit(c, 0);
   emit(c, w * bpp);       /* stride */
   emit(c, 0);
   emit(c, 0);
   emit(c, 0);
   emit(c, 0);
   emit(c, w);
   emit(c, h);
   emit(c, 1);
   memset(&c->dw[c->n], 0, words * 4);
   memcpy(&c->dw[c->n], data, bytes);
   c->n += words;
}

/* a moving gradient with a square, so frames differ */
static void make_picture(int f, uint8_t *y, uint8_t *uv)
{
   for (int j = 0; j < H; j++)
      for (int i = 0; i < W; i++) {
         int v = (i + 2 * f) * 255 / (W + 60);
         if (i >= 40 + 4 * f && i < 100 + 4 * f && j >= 60 && j < 120)
            v = 235;
         y[j * W + i] = (uint8_t)(16 + v * 219 / 255);
      }
   for (int j = 0; j < H / 2; j++)
      for (int i = 0; i < W / 2; i++) {
         uv[(j * W / 2 + i) * 2] = (uint8_t)(100 + j / 2);
         uv[(j * W / 2 + i) * 2 + 1] = (uint8_t)(150 - i / 4);
      }
}

/* Annex B NAL unit types in the order they appear */
static int nal_types(const uint8_t *d, uint32_t n, int *types, int max)
{
   int k = 0;
   for (uint32_t i = 0; i + 4 < n && k < max; i++)
      if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 0 && d[i + 3] == 1) {
         types[k++] = d[i + 4] & 0x1f;
         i += 3;
      }
   return k;
}

/* --- decode back with VideoToolbox, compare luma --------------------------------- */
struct decoded {
   CVPixelBufferRef pix;
};

static void dec_cb(void *ref, void *frame_ref, OSStatus st, VTDecodeInfoFlags flags,
                   CVImageBufferRef img, CMTime pts, CMTime dur)
{
   (void)frame_ref;
   (void)flags;
   (void)pts;
   (void)dur;
   struct decoded *d = ref;
   if (st == noErr && img)
      d->pix = CVPixelBufferRetain(img);
}

static double psnr_y(CVPixelBufferRef pix, const uint8_t *y)
{
   double se = 0;
   CVPixelBufferLockBaseAddress(pix, kCVPixelBufferLock_ReadOnly);
   const uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(pix, 0);
   size_t row = CVPixelBufferGetBytesPerRowOfPlane(pix, 0);
   for (int j = 0; j < H; j++)
      for (int i = 0; i < W; i++) {
         double e = (double)base[j * row + i] - y[j * W + i];
         se += e * e;
      }
   CVPixelBufferUnlockBaseAddress(pix, kCVPixelBufferLock_ReadOnly);
   double mse = se / (W * H);
   return mse > 0 ? 10 * log10(255.0 * 255.0 / mse) : 99;
}

/* splits an access unit into NAL units (start codes removed) */
static int split_nals(const uint8_t *d, uint32_t n, const uint8_t **nal, size_t *len, int max)
{
   int k = 0;
   uint32_t i = 0;
   while (i + 4 <= n && k < max) {
      if (!(d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 0 && d[i + 3] == 1)) {
         i++;
         continue;
      }
      uint32_t s = i + 4, e = s;
      while (e + 4 <= n && !(d[e] == 0 && d[e + 1] == 0 && d[e + 2] == 0 && d[e + 3] == 1))
         e++;
      if (e + 4 > n)
         e = n;
      nal[k] = d + s;
      len[k++] = e - s;
      i = e;
   }
   return k;
}

int main(void)
{
   setvbuf(stdout, NULL, _IONBF, 0);
   main_ctx = soft_gl_context(NULL);
   if (!main_ctx || CGLSetCurrentContext(main_ctx)) {
      printf("skip: no OpenGL context on this Mac\n");
      return 0;
   }
   soft_gl_require();
   static int cookie;
   if (virgl_renderer_init(&cookie, VIRGL_RENDERER_USE_VIDEO, &callbacks)) {
      printf("FAIL: virgl_renderer_init\n");
      return 1;
   }

   /* the host must list H.264 encoding, or there is nothing to test */
   uint32_t max_ver = 0, max_size = 0;
   virgl_renderer_get_cap_set(2, &max_ver, &max_size);
   union virgl_caps *caps = calloc(1, max_size > sizeof(*caps) ? max_size : sizeof(*caps));
   virgl_renderer_fill_caps(2, 2, caps);
   int offered = 0;
   for (unsigned i = 0; i < caps->v2.num_video_caps && i < 32; i++)
      offered |= caps->v2.video_caps[i].entrypoint == G_ENTRYPOINT_ENCODE &&
                 caps->v2.video_caps[i].profile == G_AVC_HIGH;
   free(caps);
   if (!offered) {
      printf("skip: no hardware H.264 encoder offered\n");
      return 0;
   }
   check(1, "caps offer H.264 High encoding");

   virgl_renderer_context_create(1, 4, "venc");
   static uint8_t y[W * H], uv[W * H / 2];
   static union virgl_picture_desc desc;
   static uint8_t coded[4 << 20];
   static struct virgl_video_encode_feedback feed;
   make_res(R_Y, TEST_PIPE_TEXTURE_2D, VIRGL_FORMAT_R8_UNORM,
            VIRGL_BIND_SAMPLER_VIEW | VIRGL_BIND_RENDER_TARGET, W, H, NULL, 0);
   make_res(R_UV, TEST_PIPE_TEXTURE_2D, VIRGL_FORMAT_R8G8_UNORM,
            VIRGL_BIND_SAMPLER_VIEW | VIRGL_BIND_RENDER_TARGET, W / 2, H / 2, NULL, 0);
   make_res(R_DESC, TEST_PIPE_BUFFER, VIRGL_FORMAT_R8_UNORM, VIRGL_BIND_CUSTOM,
            sizeof(desc), 1, &desc, sizeof(desc));
   make_res(R_CODED, TEST_PIPE_BUFFER, VIRGL_FORMAT_R8_UNORM, 0, sizeof(coded), 1,
            coded, sizeof(coded));
   make_res(R_FEED, TEST_PIPE_BUFFER, VIRGL_FORMAT_R8_UNORM, VIRGL_BIND_CUSTOM,
            sizeof(feed), 1, &feed, sizeof(feed));

   struct cmds *c = calloc(1, sizeof(*c));
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_VIDEO_CODEC, 0, 8));
   emit(c, 1);                    /* handle */
   emit(c, G_AVC_HIGH);
   emit(c, G_ENTRYPOINT_ENCODE);
   emit(c, 1);                    /* chroma 4:2:0 */
   emit(c, 41);
   emit(c, W);
   emit(c, H);
   emit(c, 1);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_VIDEO_BUFFER, 0, 6));
   emit(c, 2);                    /* handle */
   emit(c, VIRGL_FORMAT_Y8_U8V8_420_UNORM);
   emit(c, W);
   emit(c, H);
   emit(c, R_Y);
   emit(c, R_UV);
   check(submit(c) == 0, "codec and video buffer created");

   static uint8_t stream[8 << 20];
   uint32_t stream_size = 0, bad = 0, sizes_ok = 1;
   int first_types[8] = { 0 }, first_n = 0, later_slices = 1;
   static uint8_t ys[FRAMES][W * H];

   for (int f = 0; f < FRAMES; f++) {
      make_picture(f, y, uv);
      memcpy(ys[f], y, sizeof(y));
      emit_plane(c, R_Y, W, H, 1, y);
      emit_plane(c, R_UV, W / 2, H / 2, 2, uv);

      memset(&desc, 0, sizeof(desc));
      desc.h264_enc.base.profile = G_AVC_HIGH;
      desc.h264_enc.base.entry_point = G_ENTRYPOINT_ENCODE;
      desc.h264_enc.rate_ctrl[0].rate_ctrl_method = 4;   /* variable */
      desc.h264_enc.rate_ctrl[0].target_bitrate = 2000000;
      desc.h264_enc.rate_ctrl[0].frame_rate_num = 30;
      desc.h264_enc.rate_ctrl[0].frame_rate_den = 1;
      desc.h264_enc.gop_size = 30;
      desc.h264_enc.picture_type = f == 0 ? PIC_IDR : PIC_P;
      memset(&feed, 0, sizeof(feed));

      emit(c, VIRGL_CMD0(VIRGL_CCMD_BEGIN_FRAME, 0, 2));
      emit(c, 1);
      emit(c, 2);
      emit(c, VIRGL_CMD0(VIRGL_CCMD_ENCODE_BITSTREAM, 0, 5));
      emit(c, 1);
      emit(c, 2);
      emit(c, R_CODED);
      emit(c, R_DESC);
      emit(c, R_FEED);
      emit(c, VIRGL_CMD0(VIRGL_CCMD_END_FRAME, 0, 2));
      emit(c, 1);
      emit(c, 2);
      if (submit(c) || feed.stat != VIRGL_VIDEO_ENCODE_STAT_SUCCESS || !feed.coded_size ||
          feed.coded_size > sizeof(coded)) {
         bad++;
         continue;
      }
      int types[64];
      int k = nal_types(coded, feed.coded_size, types, 64);
      if (f == 0) {
         first_n = k < 8 ? k : 8;
         memcpy(first_types, types, first_n * sizeof(int));
      } else {
         int slice = 0;
         for (int i = 0; i < k; i++)
            slice |= types[i] == 1 || types[i] == 5;
         later_slices &= slice;
      }
      if (stream_size + feed.coded_size > sizeof(stream)) {
         sizes_ok = 0;
         break;
      }
      memcpy(stream + stream_size, coded, feed.coded_size);
      stream_size += feed.coded_size;
   }

   char line[160];
   snprintf(line, sizeof(line), "%d frames encoded, feedback success with a size (%u failed)",
            FRAMES, bad);
   check(!bad && sizes_ok, line);
   int has_sps = first_n >= 3 && first_types[0] == 7 && first_types[1] == 8;
   int has_idr = 0;
   for (int i = 0; i < first_n; i++)
      has_idr |= first_types[i] == 5;
   check(has_sps && has_idr, "first access unit: SPS, PPS, IDR slice");
   check(later_slices, "later access units hold slices");
   snprintf(line, sizeof(line), "stream of %u bytes for %d frames of %dx%d", stream_size,
            FRAMES, W, H);
   check(stream_size > 1000 && stream_size < 2000000, line);

   const char *out = getenv("OMACVM_TEST_H264_OUT");
   if (out) {
      FILE *fp = fopen(out, "wb");
      if (fp) {
         fwrite(stream, 1, stream_size, fp);
         fclose(fp);
      }
   }

   /* decode the stream again and compare each picture's luma with what went in */
   const uint8_t *nal[4096];
   size_t len[4096];
   int n = split_nals(stream, stream_size, nal, len, 4096);
   const uint8_t *ps[2] = { NULL, NULL };
   size_t ps_len[2] = { 0, 0 };
   for (int i = 0; i < n && (!ps[0] || !ps[1]); i++) {
      if ((nal[i][0] & 0x1f) == 7 && !ps[0]) {
         ps[0] = nal[i];
         ps_len[0] = len[i];
      }
      if ((nal[i][0] & 0x1f) == 8 && !ps[1]) {
         ps[1] = nal[i];
         ps_len[1] = len[i];
      }
   }
   CMVideoFormatDescriptionRef fmt = NULL;
   double min_psnr = 99;
   int decoded = 0;
   if (ps[0] && ps[1] &&
       CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, ps, ps_len, 4, &fmt) == noErr) {
      struct decoded d = { 0 };
      VTDecompressionOutputCallbackRecord cb = { dec_cb, &d };
      VTDecompressionSessionRef dec = NULL;
      if (VTDecompressionSessionCreate(NULL, fmt, NULL, NULL, &cb, &dec) == noErr) {
         int frame = 0;
         for (int i = 0; i < n; i++) {
            int t = nal[i][0] & 0x1f;
            if (t != 1 && t != 5)
               continue;
            /* one slice per frame here: AVCC sample of this NAL unit */
            uint8_t *avcc = malloc(len[i] + 4);
            avcc[0] = len[i] >> 24;
            avcc[1] = len[i] >> 16;
            avcc[2] = len[i] >> 8;
            avcc[3] = len[i];
            memcpy(avcc + 4, nal[i], len[i]);
            CMBlockBufferRef block = NULL;
            CMSampleBufferRef sample = NULL;
            size_t ssize = len[i] + 4;
            CMBlockBufferCreateWithMemoryBlock(NULL, avcc, ssize, kCFAllocatorMalloc, NULL, 0,
                                               ssize, 0, &block);
            CMSampleBufferCreateReady(NULL, block, fmt, 1, 0, NULL, 1, &ssize, &sample);
            d.pix = NULL;
            VTDecompressionSessionDecodeFrame(dec, sample, 0, NULL, NULL);
            VTDecompressionSessionWaitForAsynchronousFrames(dec);
            if (d.pix && frame < FRAMES) {
               double p = psnr_y(d.pix, ys[frame]);
               if (p < min_psnr)
                  min_psnr = p;
               decoded++;
               CVPixelBufferRelease(d.pix);
            }
            frame++;
            CFRelease(sample);
            CFRelease(block);
         }
         VTDecompressionSessionInvalidate(dec);
         CFRelease(dec);
      }
      CFRelease(fmt);
   }
   snprintf(line, sizeof(line), "%d of %d frames decode again, lowest luma PSNR %.1f dB",
            decoded, FRAMES, min_psnr);
   check(decoded == FRAMES && min_psnr > 30, line);

   virgl_renderer_context_destroy(1);
   for (uint32_t r = R_Y; r <= R_FEED; r++)
      virgl_renderer_resource_unref(r);
   free(c);
   virgl_renderer_cleanup(&cookie);
   printf("%s\n", failures ? "video encode: FAILED" : "video encode: all checks passed");
   return failures != 0;
}
