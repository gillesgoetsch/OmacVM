/* H.264 and HEVC encoding through the VideoToolbox backend, the way the guest's VA-API driver
 * drives it: a video codec with the ENCODE entrypoint, an NV12 video buffer whose
 * planes are guest textures, then per frame BEGIN_FRAME, ENCODE_BITSTREAM (picture
 * description, coded-data buffer, feedback buffer) and END_FRAME.
 * Checks per codec: the feedback says success with a size, the coded data is an Annex B
 * access unit, the first one starts with its parameter sets (H.264: SPS, PPS; HEVC: VPS,
 * SPS, PPS) and holds an IDR slice, later frames hold slices, and the whole stream
 * decodes again (VTDecompressionSession) to pictures close to what went in (luma PSNR).
 * Guest input: nonsense rate control (zero or huge frame rates, bitrates, GOP, QP) still
 * encodes, also when the frame rate changes; a frame never ended gets failure feedback and
 * does not leak into the next; a second encode in one frame is refused (failure feedback
 * for it, the first keeps its output); a frame that fails, or whose coded-data resource is missing
 * or not a buffer, gets failure feedback; a coded-data buffer too small gets a
 * failure, not a cut frame; constant QP follows the guest's QP, also after a switch from
 * bitrate mode; codecs the host does not offer (too small, too large, HEVC
 * Main 10) encode nothing; at most 8 encoders are open at once, and one closed
 * makes room for the next; the guest's conditional rendering does not stop the
 * picture copy (Apple's software OpenGL copies either way: no proof for the GPU).
 * Runs on Apple's software OpenGL (soft-gl.h); the encoder is the Mac's media engine.
 * Skips a codec the Mac has no hardware encoder for.
 * OMACVM_TEST_H264_OUT=FILE / OMACVM_TEST_HEVC_OUT=FILE also write the streams. */
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
enum { G_AVC_HIGH = 11, G_HEVC_MAIN = 15, G_HEVC_MAIN_10 = 16, G_ENTRYPOINT_ENCODE = 4 };
enum { PIC_P = 0, PIC_IDR = 3 };
enum { R_Y = 1, R_UV, R_DESC, R_CODED, R_FEED, R_SMALL, R_TEX, R_FEED2, R_QUERY };
enum { BUF = 2 };   /* the video buffer's handle; codecs get 10, 11, ... */

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
      static struct iovec iov[16];
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

static int noise;   /* add grain, so the QP shows in the size */

/* a moving gradient with a square, so frames differ */
static void make_picture(int f, uint8_t *y, uint8_t *uv)
{
   for (int j = 0; j < H; j++)
      for (int i = 0; i < W; i++) {
         int v = (i + 2 * f) * 255 / (W + 60);
         if (i >= 40 + 4 * f && i < 100 + 4 * f && j >= 60 && j < 120)
            v = 235;
         if (noise) {
            uint32_t h = (uint32_t)(j * W + i) * 2654435761u ^ (uint32_t)f * 40503u;
            v += (int)((h >> 24) % 41) - 20;
            v = v < 0 ? 0 : v > 255 ? 255 : v;
         }
         y[j * W + i] = (uint8_t)(16 + v * 219 / 255);
      }
   for (int j = 0; j < H / 2; j++)
      for (int i = 0; i < W / 2; i++) {
         uv[(j * W / 2 + i) * 2] = (uint8_t)(100 + j / 2);
         uv[(j * W / 2 + i) * 2 + 1] = (uint8_t)(150 - i / 4);
      }
}

static int hevc;   /* the codec under test: 0 H.264, 1 HEVC */

static int nal_type(const uint8_t *nal)
{
   return hevc ? (nal[0] >> 1) & 0x3f : nal[0] & 0x1f;
}

/* slice NAL units: H.264 1 (non-IDR), 5 (IDR); HEVC 0-9 (trailing...), 19-21 (IDR, CRA) */
static int is_slice(int t)
{
   return hevc ? t <= 9 || (t >= 16 && t <= 21) : t == 1 || t == 5;
}

static int is_idr(int t)
{
   return hevc ? t == 19 || t == 20 : t == 5;
}

/* Annex B NAL unit types in the order they appear */
static int nal_types(const uint8_t *d, uint32_t n, int *types, int max)
{
   int k = 0;
   for (uint32_t i = 0; i + 4 < n && k < max; i++)
      if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 0 && d[i + 3] == 1) {
         types[k++] = nal_type(d + i + 4);
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

static int dec_w, dec_h;   /* size of the last decoded picture */

/* luma PSNR of a decoded picture (at most W x H: a cropped stream is smaller)
 * against the top-left of the source picture */
static double psnr_y(CVPixelBufferRef pix, const uint8_t *y)
{
   double se = 0;
   int w = (int)CVPixelBufferGetWidth(pix), h = (int)CVPixelBufferGetHeight(pix);
   dec_w = w;
   dec_h = h;
   if (w > W || h > H)
      return 0;
   CVPixelBufferLockBaseAddress(pix, kCVPixelBufferLock_ReadOnly);
   const uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(pix, 0);
   size_t row = CVPixelBufferGetBytesPerRowOfPlane(pix, 0);
   for (int j = 0; j < h; j++)
      for (int i = 0; i < w; i++) {
         double e = (double)base[j * row + i] - y[j * W + i];
         se += e * e;
      }
   CVPixelBufferUnlockBaseAddress(pix, kCVPixelBufferLock_ReadOnly);
   double mse = se / (w * h);
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

static struct cmds *c;
static uint8_t y[W * H], uv[W * H / 2];
static union virgl_picture_desc desc;
static uint8_t coded[4 << 20], small[16];
static struct virgl_video_encode_feedback feed, feed2;
static uint8_t query_result[64];

static void create_codec(uint32_t handle, uint32_t profile, uint32_t w, uint32_t h)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_VIDEO_CODEC, 0, 8));
   emit(c, handle);
   emit(c, profile);
   emit(c, G_ENTRYPOINT_ENCODE);
   emit(c, 1);                    /* chroma 4:2:0 */
   emit(c, 41);
   emit(c, w);
   emit(c, h);
   emit(c, 1);
   submit(c);
}

struct rc {
   uint32_t method, bitrate, peak, fps_num, fps_den, gop, qp;
};

static const struct rc rc_normal = { 4, 2000000, 0, 30, 1, 30, 0 };
static uint32_t crop_right, crop_bottom;   /* in 2-pixel units, as in the guest's SPS */

/* One frame: upload picture f, encode it into DEST; 0 when the feedback says success. */
static int encode_frame(uint32_t codec, uint32_t profile, int f, const struct rc *rc,
                        uint32_t dest)
{
   make_picture(f, y, uv);
   emit_plane(c, R_Y, W, H, 1, y);
   emit_plane(c, R_UV, W / 2, H / 2, 2, uv);

   memset(&desc, 0, sizeof(desc));
   if (profile == G_AVC_HIGH) {
      struct virgl_h264_enc_picture_desc *d = &desc.h264_enc;
      d->base.profile = profile;
      d->base.entry_point = G_ENTRYPOINT_ENCODE;
      d->rate_ctrl[0].rate_ctrl_method = rc->method;
      d->rate_ctrl[0].target_bitrate = rc->bitrate;
      d->rate_ctrl[0].peak_bitrate = rc->peak;
      d->rate_ctrl[0].frame_rate_num = rc->fps_num;
      d->rate_ctrl[0].frame_rate_den = rc->fps_den;
      d->gop_size = rc->gop;
      d->quant_i_frames = d->quant_p_frames = rc->qp;
      d->picture_type = f == 0 ? PIC_IDR : PIC_P;
      d->seq.enc_frame_cropping_flag = crop_right || crop_bottom;
      d->seq.enc_frame_crop_right_offset = crop_right;
      d->seq.enc_frame_crop_bottom_offset = crop_bottom;
   } else {
      struct virgl_h265_enc_picture_desc *d = &desc.h265_enc;
      d->base.profile = profile;
      d->base.entry_point = G_ENTRYPOINT_ENCODE;
      d->rc.rate_ctrl_method = rc->method;
      d->rc.target_bitrate = rc->bitrate;
      d->rc.peak_bitrate = rc->peak;
      d->rc.frame_rate_num = rc->fps_num;
      d->rc.frame_rate_den = rc->fps_den;
      d->seq.intra_period = rc->gop;
      d->rc.quant_i_frames = d->rc.quant_p_frames = rc->qp;
      d->picture_type = f == 0 ? PIC_IDR : PIC_P;
      d->seq.conformance_window_flag = crop_right || crop_bottom;
      d->seq.conf_win_right_offset = crop_right;
      d->seq.conf_win_bottom_offset = crop_bottom;
   }
   memset(&feed, 0xaa, sizeof(feed));

   emit(c, VIRGL_CMD0(VIRGL_CCMD_BEGIN_FRAME, 0, 2));
   emit(c, codec);
   emit(c, BUF);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_ENCODE_BITSTREAM, 0, 5));
   emit(c, codec);
   emit(c, BUF);
   emit(c, dest);
   emit(c, R_DESC);
   emit(c, R_FEED);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_END_FRAME, 0, 2));
   emit(c, codec);
   emit(c, BUF);
   submit(c);
   return feed.stat == VIRGL_VIDEO_ENCODE_STAT_SUCCESS && feed.coded_size &&
          feed.coded_size <= sizeof(coded) ? 0 : -1;
}

static int offered(uint32_t profile)
{
   uint32_t max_ver = 0, max_size = 0;
   int found = 0;
   virgl_renderer_get_cap_set(2, &max_ver, &max_size);
   union virgl_caps *caps = calloc(1, max_size > sizeof(*caps) ? max_size : sizeof(*caps));
   virgl_renderer_fill_caps(2, 2, caps);
   for (unsigned i = 0; i < caps->v2.num_video_caps && i < 32; i++)
      found |= caps->v2.video_caps[i].entrypoint == G_ENTRYPOINT_ENCODE &&
               caps->v2.video_caps[i].profile == profile;
   free(caps);
   return found;
}

/* decode a whole Annex B stream with VideoToolbox; lowest luma PSNR against ys */
static int decode_back(const uint8_t *stream, uint32_t stream_size, uint8_t (*ys)[W * H],
                       double *min_psnr)
{
   static const uint8_t *nal[4096];
   static size_t len[4096];
   int n = split_nals(stream, stream_size, nal, len, 4096);
   const uint8_t *ps[3] = { NULL, NULL, NULL };
   size_t ps_len[3] = { 0, 0, 0 };
   int first_ps = hevc ? 32 : 7, nps = hevc ? 3 : 2;
   for (int i = 0; i < n; i++) {
      int t = nal_type(nal[i]) - first_ps;
      if (t >= 0 && t < nps && !ps[t]) {
         ps[t] = nal[i];
         ps_len[t] = len[i];
      }
   }
   CMVideoFormatDescriptionRef fmt = NULL;
   OSStatus st;
   for (int i = 0; i < nps; i++)
      if (!ps[i])
         return 0;
   st = hevc ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(NULL, 3, ps, ps_len, 4, NULL, &fmt)
             : CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, ps, ps_len, 4, &fmt);
   if (st != noErr)
      return 0;
   int decoded = 0, frame = 0;
   struct decoded d = { 0 };
   VTDecompressionOutputCallbackRecord cb = { dec_cb, &d };
   VTDecompressionSessionRef dec = NULL;
   *min_psnr = 99;
   if (VTDecompressionSessionCreate(NULL, fmt, NULL, NULL, &cb, &dec) == noErr) {
      for (int i = 0; i < n; i++) {
         if (!is_slice(nal_type(nal[i])))
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
            if (p < *min_psnr)
               *min_psnr = p;
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
   return decoded;
}

static void test_codec(uint32_t handle, uint32_t profile, const char *name, const char *out_env)
{
   static uint8_t stream[8 << 20];
   static uint8_t ys[FRAMES][W * H];
   uint32_t stream_size = 0, bad = 0, sizes_ok = 1;
   int first_types[8] = { 0 }, first_n = 0, later_slices = 1;
   char line[160];

   hevc = profile != G_AVC_HIGH;
   if (!offered(profile)) {
      printf("skip: no hardware %s encoder offered\n", name);
      return;
   }
   snprintf(line, sizeof(line), "caps offer %s encoding", name);
   check(1, line);
   create_codec(handle, profile, W, H);

   for (int f = 0; f < FRAMES; f++) {
      if (encode_frame(handle, profile, f, &rc_normal, R_CODED)) {
         bad++;
         continue;
      }
      memcpy(ys[f], y, sizeof(y));
      int types[64];
      int k = nal_types(coded, feed.coded_size, types, 64);
      if (f == 0) {
         first_n = k < 8 ? k : 8;
         memcpy(first_types, types, first_n * sizeof(int));
      } else {
         int slice = 0;
         for (int i = 0; i < k; i++)
            slice |= is_slice(types[i]);
         later_slices &= slice;
      }
      if (stream_size + feed.coded_size > sizeof(stream)) {
         sizes_ok = 0;
         break;
      }
      memcpy(stream + stream_size, coded, feed.coded_size);
      stream_size += feed.coded_size;
   }

   snprintf(line, sizeof(line), "%s: %d frames encoded, feedback success with a size (%u failed)",
            name, FRAMES, bad);
   check(!bad && sizes_ok, line);
   int has_ps = hevc ? first_n >= 4 && first_types[0] == 32 && first_types[1] == 33 &&
                       first_types[2] == 34
                     : first_n >= 3 && first_types[0] == 7 && first_types[1] == 8;
   int has_idr = 0;
   for (int i = 0; i < first_n; i++)
      has_idr |= is_idr(first_types[i]);
   snprintf(line, sizeof(line), "%s: first access unit: %s, IDR slice", name,
            hevc ? "VPS, SPS, PPS" : "SPS, PPS");
   check(has_ps && has_idr, line);
   snprintf(line, sizeof(line), "%s: later access units hold slices", name);
   check(later_slices, line);
   snprintf(line, sizeof(line), "%s: stream of %u bytes for %d frames of %dx%d", name,
            stream_size, FRAMES, W, H);
   check(stream_size > 1000 && stream_size < 2000000, line);

   const char *out = getenv(out_env);
   if (out) {
      FILE *fp = fopen(out, "wb");
      if (fp) {
         fwrite(stream, 1, stream_size, fp);
         fclose(fp);
      }
   }

   double min_psnr = 0;
   int decoded = decode_back(stream, stream_size, ys, &min_psnr);
   snprintf(line, sizeof(line), "%s: %d of %d frames decode again, lowest luma PSNR %.1f dB",
            name, decoded, FRAMES, min_psnr);
   check(decoded == FRAMES && min_psnr > 30, line);

   /* Guest numbers out of any sensible range: clamped, every frame still encoded. */
   static const struct rc odd[] = {
      { 4, 0, 0, 0, 0, 0, 0 },                                /* nothing set */
      { 4, 0xffffffff, 0xffffffff, 0xffffffff, 1, 0xffffffff, 0 },
      { 4, 1, 0, 1, 1000000000, 1, 0 },                       /* 1 bit/s, 1 frame in 31 years */
      { 3, 2000000, 2000000, 1000000, 999999, 2, 0 },         /* CBR */
      { 0, 0, 0, 30, 1, 30, 999 },                            /* constant QP, QP 999 */
      { 0, 0, 0, 30, 1, 30, 0 },                              /* constant QP 0 */
   };
   int r;
   bad = 0;
   for (unsigned i = 0; i < sizeof(odd) / sizeof(odd[0]); i++)
      for (int f = 0; f < 4; f++)
         bad += encode_frame(handle, profile, f, &odd[i], R_CODED) != 0;
   snprintf(line, sizeof(line), "%s: nonsense rate control is clamped (%u of %u frames failed)",
            name, bad, (unsigned)(sizeof(odd) / sizeof(odd[0]) * 4));
   check(!bad, line);

   /* Random picture descriptions (profile and entrypoint kept, so they reach the
    * encoder): no crash, and the codec still works afterwards. */
   srand(1234);
   for (int f = 0; f < 200; f++) {
      uint8_t *b = (uint8_t *)&desc;
      make_picture(f, y, uv);
      emit_plane(c, R_Y, W, H, 1, y);
      emit_plane(c, R_UV, W / 2, H / 2, 2, uv);
      for (size_t i = 0; i < sizeof(desc); i++)
         b[i] = (uint8_t)rand();
      desc.base.profile = profile;
      desc.base.entry_point = G_ENTRYPOINT_ENCODE;
      emit(c, VIRGL_CMD0(VIRGL_CCMD_BEGIN_FRAME, 0, 2));
      emit(c, handle);
      emit(c, BUF);
      emit(c, VIRGL_CMD0(VIRGL_CCMD_ENCODE_BITSTREAM, 0, 5));
      emit(c, handle);
      emit(c, BUF);
      emit(c, R_CODED);
      emit(c, R_DESC);
      emit(c, R_FEED);
      emit(c, VIRGL_CMD0(VIRGL_CCMD_END_FRAME, 0, 2));
      emit(c, handle);
      emit(c, BUF);
      submit(c);
   }
   r = encode_frame(handle, profile, 3, &rc_normal, R_CODED);
   snprintf(line, sizeof(line), "%s: 200 random picture descriptions, then encodes again", name);
   check(r == 0, line);

   /* Frame rate changing during the stream (Chrome does): time stamps keep
    * increasing, every frame encodes. */
   bad = 0;
   for (int f = 0; f < 12; f++) {
      struct rc v = rc_normal;
      v.fps_num = f % 3 == 0 ? 15 : f % 3 == 1 ? 60 : 30;
      bad += encode_frame(handle, profile, f + 1, &v, R_CODED) != 0;
   }
   snprintf(line, sizeof(line), "%s: frame rate 15/60/30 by turns: all frames encode (%u failed)",
            name, bad);
   check(!bad, line);

   /* A frame begun and encoded but never ended: failure feedback when the next
    * frame begins; then a normal frame gets its own output only. */
   feed.stat = VIRGL_VIDEO_ENCODE_STAT_SUCCESS;
   feed.coded_size = 1234;
   make_picture(5, y, uv);
   emit_plane(c, R_Y, W, H, 1, y);
   emit_plane(c, R_UV, W / 2, H / 2, 2, uv);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BEGIN_FRAME, 0, 2));
   emit(c, handle);
   emit(c, BUF);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_ENCODE_BITSTREAM, 0, 5));
   emit(c, handle);
   emit(c, BUF);
   emit(c, R_CODED);
   emit(c, R_DESC);
   emit(c, R_FEED);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BEGIN_FRAME, 0, 2));
   emit(c, handle);
   emit(c, BUF);
   submit(c);
   snprintf(line, sizeof(line), "%s: a frame never ended: failure feedback at the next begin "
            "(stat %u, size %u)", name, feed.stat, feed.coded_size);
   check(feed.stat == VIRGL_VIDEO_ENCODE_STAT_FAILURE && feed.coded_size == 0, line);
   r = encode_frame(handle, profile, 6, &rc_normal, R_CODED);
   int types[64], k = r ? 0 : nal_types(coded, feed.coded_size, types, 64), slices = 0;
   for (int i = 0; i < k; i++)
      slices += is_slice(types[i]);
   snprintf(line, sizeof(line), "%s: a frame never ended, then one more: one picture's output "
            "(%d slices)", name, slices);
   check(r == 0 && slices == 1, line);

   /* Two encodes in one frame: the second is refused with failure feedback in
    * its own feedback buffer, the first gets its output. */
   make_picture(8, y, uv);
   emit_plane(c, R_Y, W, H, 1, y);
   emit_plane(c, R_UV, W / 2, H / 2, 2, uv);
   memset(&feed, 0xaa, sizeof(feed));
   feed2.stat = VIRGL_VIDEO_ENCODE_STAT_SUCCESS;
   feed2.coded_size = 1234;
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BEGIN_FRAME, 0, 2));
   emit(c, handle);
   emit(c, BUF);
   for (int i = 0; i < 2; i++) {
      emit(c, VIRGL_CMD0(VIRGL_CCMD_ENCODE_BITSTREAM, 0, 5));
      emit(c, handle);
      emit(c, BUF);
      emit(c, R_CODED);
      emit(c, R_DESC);
      emit(c, i ? R_FEED2 : R_FEED);
   }
   emit(c, VIRGL_CMD0(VIRGL_CCMD_END_FRAME, 0, 2));
   emit(c, handle);
   emit(c, BUF);
   submit(c);
   k = feed.stat == VIRGL_VIDEO_ENCODE_STAT_SUCCESS && feed.coded_size <= sizeof(coded) ?
       nal_types(coded, feed.coded_size, types, 64) : 0;
   slices = 0;
   for (int i = 0; i < k; i++)
      slices += is_slice(types[i]);
   snprintf(line, sizeof(line), "%s: two encodes in one frame: the first gets its output "
            "(%d slices), the second failure (stat %u, size %u)", name, slices, feed2.stat,
            feed2.coded_size);
   check(slices == 1 && feed2.stat == VIRGL_VIDEO_ENCODE_STAT_FAILURE && feed2.coded_size == 0,
         line);

   /* A frame that cannot be encoded (wrong profile in its description) gets
    * failure feedback, not the previous frame's result. */
   feed.stat = VIRGL_VIDEO_ENCODE_STAT_SUCCESS;
   feed.coded_size = 1234;
   make_picture(7, y, uv);
   emit_plane(c, R_Y, W, H, 1, y);
   emit_plane(c, R_UV, W / 2, H / 2, 2, uv);
   memset(&desc, 0, sizeof(desc));
   desc.base.profile = profile + 1;
   desc.base.entry_point = G_ENTRYPOINT_ENCODE;
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BEGIN_FRAME, 0, 2));
   emit(c, handle);
   emit(c, BUF);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_ENCODE_BITSTREAM, 0, 5));
   emit(c, handle);
   emit(c, BUF);
   emit(c, R_CODED);
   emit(c, R_DESC);
   emit(c, R_FEED);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_END_FRAME, 0, 2));
   emit(c, handle);
   emit(c, BUF);
   submit(c);
   snprintf(line, sizeof(line), "%s: a frame that fails: failure feedback (stat %u, size %u)",
            name, feed.stat, feed.coded_size);
   check(feed.stat == VIRGL_VIDEO_ENCODE_STAT_FAILURE && feed.coded_size == 0, line);

   /* A coded-data buffer too small for a key frame: failure, no partial frame. */
   r = encode_frame(handle, profile, 0, &rc_normal, R_SMALL);
   snprintf(line, sizeof(line), "%s: 16-byte coded buffer: failure feedback (stat %u, size %u)",
            name, feed.stat, feed.coded_size);
   check(r != 0 && feed.stat == VIRGL_VIDEO_ENCODE_STAT_FAILURE && feed.coded_size == 0, line);
   /* A texture as the coded-data buffer, or no such resource: refused before
    * encoding, with failure feedback. */
   r = encode_frame(handle, profile, 1, &rc_normal, R_TEX);
   snprintf(line, sizeof(line), "%s: texture as coded buffer: refused, failure feedback "
            "(stat %u)", name, feed.stat);
   check(r != 0 && feed.stat == VIRGL_VIDEO_ENCODE_STAT_FAILURE && feed.coded_size == 0, line);
   r = encode_frame(handle, profile, 1, &rc_normal, 999);
   snprintf(line, sizeof(line), "%s: unknown coded buffer: refused, failure feedback "
            "(stat %u)", name, feed.stat);
   check(r != 0 && feed.stat == VIRGL_VIDEO_ENCODE_STAT_FAILURE && feed.coded_size == 0, line);
   /* and the codec still works after both */
   r = encode_frame(handle, profile, 2, &rc_normal, R_CODED);
   snprintf(line, sizeof(line), "%s: encodes again afterwards", name);
   check(r == 0, line);

   emit(c, VIRGL_CMD0(VIRGL_CCMD_DESTROY_VIDEO_CODEC, 0, 1));
   emit(c, handle);
   submit(c);
}

/* Bytes of 8 frames (an IDR, then P frames) under rate control RC; 0 if one failed. */
static uint32_t eight_frames(uint32_t handle, uint32_t profile, const struct rc *rc)
{
   uint32_t total = 0;
   for (int f = 0; f < 8; f++) {
      if (encode_frame(handle, profile, f, rc, R_CODED))
         return 0;
      total += feed.coded_size;
   }
   return total;
}

/* Constant QP follows the guest's QP: QP 18 gives clearly more bytes than QP 40,
 * also right after bitrate mode (no bitrate limit left over), and bitrate mode
 * after constant QP keeps to its bitrate again. */
static void test_cqp(uint32_t handle, uint32_t profile, const char *name)
{
   static const struct rc qp18 = { 0, 0, 0, 30, 1, 30, 18 }, qp40 = { 0, 0, 0, 30, 1, 30, 40 };
   static const struct rc low = { 4, 50000, 0, 30, 1, 30, 0 };
   char line[160];

   hevc = profile != G_AVC_HIGH;
   if (!offered(profile))
      return;
   create_codec(handle, profile, W, H);
   noise = 1;
   uint32_t a = eight_frames(handle, profile, &qp18);
   uint32_t b = eight_frames(handle, profile, &qp40);
   snprintf(line, sizeof(line), "%s: constant QP 18: %u bytes, QP 40: %u bytes", name, a, b);
   check(a && b && a > 2 * b, line);
   uint32_t lo = eight_frames(handle, profile, &low);
   uint32_t a2 = eight_frames(handle, profile, &qp18);
   uint32_t lo2 = eight_frames(handle, profile, &low);
   snprintf(line, sizeof(line), "%s: 50 kbit/s %u bytes, then QP 18 %u bytes, then 50 kbit/s "
            "%u bytes", name, lo, a2, lo2);
   check(lo && a2 && lo2 && a2 > a / 2 && a2 > 2 * lo && lo2 < a2 / 2, line);
   noise = 0;
   emit(c, VIRGL_CMD0(VIRGL_CCMD_DESTROY_VIDEO_CODEC, 0, 1));
   emit(c, handle);
   submit(c);
}

/* Pictures padded the way encoders pad them, the SPS cropping 16 columns and 8
 * rows: the stream has the cropped size and shows the top-left of each picture.
 * Twice: GPU blit, and the CPU copy (OMACVM_VIDEO_COPY=1). */
static void test_crop(uint32_t handle, uint32_t profile, const char *name, int cpu)
{
   static uint8_t stream[2 << 20];
   static uint8_t ys[FRAMES][W * H];
   uint32_t stream_size = 0, bad = 0;
   char line[160];

   hevc = profile != G_AVC_HIGH;
   if (!offered(profile))
      return;
   if (cpu)
      setenv("OMACVM_VIDEO_COPY", "1", 1);
   crop_right = 8;
   crop_bottom = 4;
   create_codec(handle, profile, W, H);
   for (int f = 0; f < 10; f++) {
      if (encode_frame(handle, profile, f, &rc_normal, R_CODED) ||
          stream_size + feed.coded_size > sizeof(stream)) {
         bad++;
         continue;
      }
      memcpy(ys[f], y, sizeof(y));
      memcpy(stream + stream_size, coded, feed.coded_size);
      stream_size += feed.coded_size;
   }
   crop_right = crop_bottom = 0;
   unsetenv("OMACVM_VIDEO_COPY");
   double min_psnr = 0;
   dec_w = dec_h = 0;
   int decoded = decode_back(stream, stream_size, ys, &min_psnr);
   snprintf(line, sizeof(line), "%s, cropped picture (%s copy): %d of 10 frames decode at %dx%d "
            "(want %dx%d), lowest luma PSNR %.1f dB", name, cpu ? "CPU" : "GPU", decoded, dec_w,
            dec_h, W - 16, H - 8, min_psnr);
   check(!bad && decoded == 10 && dec_w == W - 16 && dec_h == H - 8 && min_psnr > 30, line);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_DESTROY_VIDEO_CODEC, 0, 1));
   emit(c, handle);
   submit(c);
}

/* The guest's conditional rendering is on and says "skip" (an occlusion query
 * with no samples): the copy into the encoder's picture is not rendering and
 * must still happen, so the stream shows the guest's pictures. */
static void test_render_condition(uint32_t handle, uint32_t profile, const char *name)
{
   static uint8_t stream[2 << 20];
   static uint8_t ys[FRAMES][W * H];
   uint32_t stream_size = 0, bad = 0;
   char line[160];

   hevc = profile != G_AVC_HIGH;
   if (!offered(profile))
      return;
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_QUERY, VIRGL_OBJ_QUERY_SIZE));
   emit(c, 40);
   emit(c, VIRGL_OBJ_QUERY_TYPE(0));   /* PIPE_QUERY_OCCLUSION_COUNTER */
   emit(c, 0);
   emit(c, R_QUERY);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BEGIN_QUERY, 0, 1));
   emit(c, 40);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_END_QUERY, 0, 1));
   emit(c, 40);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_RENDER_CONDITION, 0, VIRGL_RENDER_CONDITION_SIZE));
   emit(c, 40);
   emit(c, 0);                          /* condition: skip when no samples passed */
   emit(c, 0);                          /* PIPE_RENDER_COND_WAIT */
   submit(c);
   create_codec(handle, profile, W, H);
   for (int f = 0; f < 5; f++) {
      if (encode_frame(handle, profile, f, &rc_normal, R_CODED) ||
          stream_size + feed.coded_size > sizeof(stream)) {
         bad++;
         continue;
      }
      memcpy(ys[f], y, sizeof(y));
      memcpy(stream + stream_size, coded, feed.coded_size);
      stream_size += feed.coded_size;
   }
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_RENDER_CONDITION, 0, VIRGL_RENDER_CONDITION_SIZE));
   emit(c, 0);
   emit(c, 0);
   emit(c, 0);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_DESTROY_VIDEO_CODEC, 0, 1));
   emit(c, handle);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_DESTROY_OBJECT, VIRGL_OBJECT_QUERY, 1));
   emit(c, 40);
   submit(c);
   double min_psnr = 0;
   int decoded = decode_back(stream, stream_size, ys, &min_psnr);
   snprintf(line, sizeof(line), "%s: guest's conditional rendering on: %d of 5 frames decode, "
            "lowest luma PSNR %.1f dB", name, decoded, min_psnr);
   check(!bad && decoded == 5 && min_psnr > 30, line);
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
   if (!offered(G_AVC_HIGH) && !offered(G_HEVC_MAIN)) {
      printf("skip: no hardware video encoder offered\n");
      return 0;
   }

   virgl_renderer_context_create(1, 4, "venc");
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
   make_res(R_SMALL, TEST_PIPE_BUFFER, VIRGL_FORMAT_R8_UNORM, 0, sizeof(small), 1,
            small, sizeof(small));
   make_res(R_TEX, TEST_PIPE_TEXTURE_2D, VIRGL_FORMAT_R8_UNORM,
            VIRGL_BIND_SAMPLER_VIEW | VIRGL_BIND_RENDER_TARGET, 64, 64, NULL, 0);
   make_res(R_FEED2, TEST_PIPE_BUFFER, VIRGL_FORMAT_R8_UNORM, VIRGL_BIND_CUSTOM,
            sizeof(feed2), 1, &feed2, sizeof(feed2));
   make_res(R_QUERY, TEST_PIPE_BUFFER, VIRGL_FORMAT_R8_UNORM, VIRGL_BIND_CUSTOM,
            sizeof(query_result), 1, query_result, sizeof(query_result));

   c = calloc(1, sizeof(*c));
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_VIDEO_BUFFER, 0, 6));
   emit(c, BUF);
   emit(c, VIRGL_FORMAT_Y8_U8V8_420_UNORM);
   emit(c, W);
   emit(c, H);
   emit(c, R_Y);
   emit(c, R_UV);
   check(submit(c) == 0, "video buffer created");

   test_codec(10, G_AVC_HIGH, "H.264", "OMACVM_TEST_H264_OUT");
   test_codec(11, G_HEVC_MAIN, "HEVC", "OMACVM_TEST_HEVC_OUT");
   test_crop(12, G_AVC_HIGH, "H.264", 0);
   test_crop(13, G_AVC_HIGH, "H.264", 1);
   test_crop(14, G_HEVC_MAIN, "HEVC", 0);
   test_crop(15, G_HEVC_MAIN, "HEVC", 1);
   test_cqp(16, G_AVC_HIGH, "H.264");
   test_cqp(17, G_HEVC_MAIN, "HEVC");
   test_render_condition(18, G_AVC_HIGH, "H.264");

   /* Codecs the host does not offer: nothing is encoded with them. */
   static const struct { uint32_t profile, w, h; const char *what; } refused[] = {
      { G_AVC_HIGH, 8, 8, "H.264 8x8" },
      { G_AVC_HIGH, 4097, 2304, "H.264 4097x2304" },
      { G_AVC_HIGH, 4096, 2305, "H.264 4096x2305" },
      { G_HEVC_MAIN_10, W, H, "HEVC Main 10" },
      { 0xffff, W, H, "profile 0xffff" },
   };
   for (unsigned i = 0; i < sizeof(refused) / sizeof(refused[0]); i++) {
      char line[160];
      create_codec(20 + i, refused[i].profile, refused[i].w, refused[i].h);
      hevc = refused[i].profile != G_AVC_HIGH;
      snprintf(line, sizeof(line), "refused: %s encodes nothing", refused[i].what);
      check(encode_frame(20 + i, refused[i].profile, 0, &rc_normal, R_CODED) != 0 &&
            feed.stat != VIRGL_VIDEO_ENCODE_STAT_SUCCESS, line);
   }

   /* At most 8 encoders at once (each holds a media engine session): the 9th
    * encodes nothing; closing one makes room again. */
   hevc = 0;
   if (offered(G_AVC_HIGH)) {
      char line[160];
      int ok8 = 0;
      for (uint32_t h = 30; h < 38; h++) {
         create_codec(h, G_AVC_HIGH, W, H);
         ok8 += encode_frame(h, G_AVC_HIGH, 0, &rc_normal, R_CODED) == 0;
      }
      create_codec(38, G_AVC_HIGH, W, H);
      int ninth = encode_frame(38, G_AVC_HIGH, 0, &rc_normal, R_CODED) == 0;
      emit(c, VIRGL_CMD0(VIRGL_CCMD_DESTROY_VIDEO_CODEC, 0, 1));
      emit(c, 30);
      submit(c);
      create_codec(39, G_AVC_HIGH, W, H);
      int after = encode_frame(39, G_AVC_HIGH, 0, &rc_normal, R_CODED) == 0;
      snprintf(line, sizeof(line), "8 encoders open: %d of 8 encode, a 9th %s, after closing one "
               "a new one %s", ok8, ninth ? "encodes" : "is refused",
               after ? "encodes" : "is refused");
      check(ok8 == 8 && !ninth && after, line);
      for (uint32_t h = 31; h < 40; h++) {
         emit(c, VIRGL_CMD0(VIRGL_CCMD_DESTROY_VIDEO_CODEC, 0, 1));
         emit(c, h);
         submit(c);
      }
   }

   virgl_renderer_context_destroy(1);
   for (uint32_t r = R_Y; r <= R_QUERY; r++)
      virgl_renderer_resource_unref(r);
   free(c);
   virgl_renderer_cleanup(&cookie);
   printf("%s\n", failures ? "video encode: FAILED" : "video encode: all checks passed");
   return failures != 0;
}
